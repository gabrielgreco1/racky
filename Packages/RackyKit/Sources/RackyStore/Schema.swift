import GRDB

/// Migração nomeada. Migração publicada nunca é editada (08 AR-320).
struct StoreMigration: Sendable {
    let id: String
    let run: @Sendable (Database) throws -> Void
}

enum StoreMigrations {
    /// `v1_initial`: só as tabelas da Fatia 1 mais `setting` e `ui_state` (08 AR-311).
    /// `agent_run` e demais tabelas entram em `v2_activity` e seguintes (publicada: nunca editar).
    static let v1Initial = StoreMigration(id: "v1_initial") { db in
        try db.execute(sql: """
        CREATE TABLE project (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            kind TEXT NOT NULL CHECK (kind IN ('git','folder')),
            root_path TEXT NOT NULL UNIQUE,
            git_remote_url TEXT,
            default_branch TEXT,
            worktree_root TEXT,
            branch_prefix TEXT,
            default_profile_id TEXT REFERENCES launch_profile(id) ON DELETE SET NULL,
            color TEXT,
            source TEXT NOT NULL DEFAULT 'manual' CHECK (source IN ('manual','imported')),
            import_source_id TEXT,
            sort_index INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL,
            archived_at INTEGER
        ) STRICT;

        CREATE TABLE launch_profile (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            provider TEXT NOT NULL CHECK (provider IN ('claude','codex','opencode','shell','custom')),
            model TEXT,
            effort TEXT,
            permission_mode TEXT,
            add_dirs_json TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(add_dirs_json)),
            extra_args_json TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(extra_args_json)),
            env_json TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(env_json)),
            scope TEXT NOT NULL DEFAULT 'global' CHECK (scope IN ('global','project')),
            project_id TEXT REFERENCES project(id) ON DELETE CASCADE,
            is_default INTEGER NOT NULL DEFAULT 0 CHECK (is_default IN (0,1)),
            source TEXT NOT NULL DEFAULT 'manual' CHECK (source IN ('manual','imported')),
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        ) STRICT;

        CREATE TABLE worktree (
            id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
            path TEXT NOT NULL UNIQUE,
            branch TEXT NOT NULL,
            base_ref TEXT,
            is_main INTEGER NOT NULL DEFAULT 0 CHECK (is_main IN (0,1)),
            created_by_app INTEGER NOT NULL DEFAULT 0 CHECK (created_by_app IN (0,1)),
            source TEXT NOT NULL DEFAULT 'manual' CHECK (source IN ('manual','imported')),
            created_at INTEGER NOT NULL,
            last_seen_at INTEGER,
            archived_at INTEGER
        ) STRICT;
        CREATE INDEX worktree_project ON worktree(project_id);

        CREATE TABLE session (
            id TEXT PRIMARY KEY NOT NULL,
            kind TEXT NOT NULL CHECK (kind IN ('worktree','checkout','folder','clean')),
            project_id TEXT REFERENCES project(id) ON DELETE RESTRICT,
            worktree_id TEXT REFERENCES worktree(id) ON DELETE RESTRICT,
            folder_path TEXT NOT NULL,
            managed_folder INTEGER NOT NULL DEFAULT 0 CHECK (managed_folder IN (0,1)),
            title TEXT NOT NULL,
            status_note TEXT,
            status_note_author TEXT,
            status_note_at INTEGER,
            unread INTEGER NOT NULL DEFAULT 0 CHECK (unread IN (0,1)),
            last_viewed_at INTEGER,
            lifecycle TEXT NOT NULL DEFAULT 'active' CHECK (lifecycle IN ('active','archived')),
            sort_index INTEGER NOT NULL DEFAULT 0,
            pinned INTEGER NOT NULL DEFAULT 0 CHECK (pinned IN (0,1)),
            created_at INTEGER NOT NULL,
            last_active_at INTEGER,
            archived_at INTEGER,
            CHECK (((kind IN ('worktree','checkout')) = (worktree_id IS NOT NULL))
                   AND ((kind = 'clean') = (project_id IS NULL)))
        ) STRICT;
        CREATE INDEX session_project ON session(project_id, archived_at);

        CREATE TABLE tab (
            id TEXT PRIMARY KEY NOT NULL,
            session_id TEXT NOT NULL REFERENCES session(id) ON DELETE CASCADE,
            title TEXT NOT NULL,
            title_locked INTEGER NOT NULL DEFAULT 0 CHECK (title_locked IN (0,1)),
            sort_index INTEGER NOT NULL DEFAULT 0,
            layout_json TEXT NOT NULL CHECK (json_valid(layout_json)),
            focused_terminal_id TEXT,
            created_at INTEGER NOT NULL,
            closed_at INTEGER
        ) STRICT;
        CREATE INDEX tab_session ON tab(session_id);

        CREATE TABLE terminal (
            id TEXT PRIMARY KEY NOT NULL,
            tab_id TEXT NOT NULL REFERENCES tab(id) ON DELETE CASCADE,
            provider TEXT NOT NULL CHECK (provider IN ('claude','codex','opencode','shell','custom')),
            profile_id TEXT REFERENCES launch_profile(id) ON DELETE SET NULL,
            title TEXT NOT NULL,
            title_source TEXT NOT NULL DEFAULT 'auto' CHECK (title_source IN ('user','osc','auto')),
            cwd TEXT NOT NULL,
            add_dirs_json TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(add_dirs_json)),
            launch_spec_json TEXT NOT NULL CHECK (json_valid(launch_spec_json)),
            resolved_argv_json TEXT CHECK (resolved_argv_json IS NULL OR json_valid(resolved_argv_json)),
            env_keys_json TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(env_keys_json)),
            cold_log INTEGER NOT NULL DEFAULT 1 CHECK (cold_log IN (0,1)),
            pty_session_id TEXT,
            daemon_major INTEGER,
            current_run_id TEXT,
            native_conversation_id TEXT,
            state TEXT NOT NULL DEFAULT 'not_started' CHECK (state IN
                ('not_started','launching','running','exited','killed','failed_to_start','interrupted','container_stopped')),
            exit_code INTEGER,
            exit_signal INTEGER,
            last_message TEXT CHECK (last_message IS NULL OR length(last_message) <= 500),
            font_size REAL,
            created_at INTEGER NOT NULL,
            started_at INTEGER,
            ended_at INTEGER,
            deleted_at INTEGER
        ) STRICT;
        CREATE INDEX terminal_tab ON terminal(tab_id);
        CREATE INDEX terminal_pty ON terminal(pty_session_id);

        CREATE TABLE setting (
            key TEXT PRIMARY KEY NOT NULL,
            value_json TEXT NOT NULL CHECK (json_valid(value_json)),
            updated_at INTEGER NOT NULL
        ) STRICT;

        CREATE TABLE ui_state (
            key TEXT PRIMARY KEY NOT NULL,
            value_json TEXT NOT NULL CHECK (json_valid(value_json)),
            updated_at INTEGER NOT NULL
        ) STRICT;
        """)
    }

    /// `v3_computers` (Fatia 3, 08 §3.2): computadores no modo leve, fila, perfis de browser, pedidos de ajuda e proxies.
    /// Colunas `owner_run_id`, `help_request.run_id` e `proxy.secret_id` ficam sem FK, como `batch_id` (R1 D-06).
    /// Sem colunas de limite ou orçamento no proxy (P13).
    static let v3Computers = StoreMigration(id: "v3_computers") { db in
        try db.execute(sql: """
        CREATE TABLE proxy (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL UNIQUE,
            preset TEXT NOT NULL DEFAULT 'custom' CHECK (preset IN ('custom','zyte')),
            scheme TEXT NOT NULL CHECK (scheme IN ('http','https','socks5')),
            host TEXT NOT NULL,
            port INTEGER NOT NULL CHECK (port BETWEEN 1 AND 65535),
            username TEXT,
            secret_id TEXT,
            geo TEXT,
            api_mode INTEGER NOT NULL DEFAULT 0 CHECK (api_mode IN (0,1)),
            is_default INTEGER NOT NULL DEFAULT 0 CHECK (is_default IN (0,1)),
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        ) STRICT;

        CREATE TABLE browser_profile (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL UNIQUE,
            volume TEXT NOT NULL,
            sites_json TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(sites_json)),
            locked_by_computer_id TEXT REFERENCES computer(id) ON DELETE SET NULL,
            created_at INTEGER NOT NULL,
            last_used_at INTEGER
        ) STRICT;

        CREATE TABLE computer (
            id TEXT PRIMARY KEY NOT NULL,
            owner_run_id TEXT,
            session_id TEXT REFERENCES session(id) ON DELETE SET NULL,
            name TEXT NOT NULL,
            mode TEXT NOT NULL DEFAULT 'light' CHECK (mode IN ('light','isolated')),
            display TEXT NOT NULL CHECK (display IN ('http','headless','desktop')),
            persistent INTEGER NOT NULL DEFAULT 0 CHECK (persistent IN (0,1)),
            proxy_id TEXT REFERENCES proxy(id) ON DELETE SET NULL,
            browser_profile_id TEXT REFERENCES browser_profile(id) ON DELETE SET NULL,
            image_ref TEXT,
            image_digest TEXT,
            network_name TEXT,
            runtime_container_id TEXT,
            egress_container_id TEXT,
            work_container_id TEXT,
            api_port INTEGER,
            vnc_port INTEGER,
            egress_admin_port INTEGER,
            generation INTEGER NOT NULL DEFAULT 0,
            state TEXT NOT NULL DEFAULT 'queued' CHECK (state IN
                ('queued','provisioning','ready','in_use','stopped','failed','removing','removed','orphan')),
            created_at INTEGER NOT NULL,
            last_used_at INTEGER,
            expires_at INTEGER,
            removed_at INTEGER
        ) STRICT;
        CREATE INDEX computer_state ON computer(state);

        CREATE TABLE computer_queue (
            id TEXT PRIMARY KEY NOT NULL,
            computer_id TEXT NOT NULL UNIQUE REFERENCES computer(id) ON DELETE CASCADE,
            position INTEGER NOT NULL,
            requested_at INTEGER NOT NULL,
            reason TEXT NOT NULL DEFAULT 'memory'
        ) STRICT;
        CREATE INDEX computer_queue_position ON computer_queue(position);

        CREATE TABLE help_request (
            id TEXT PRIMARY KEY NOT NULL,
            computer_id TEXT NOT NULL REFERENCES computer(id) ON DELETE CASCADE,
            run_id TEXT,
            kind TEXT NOT NULL CHECK (kind IN ('captcha','login','mfa','download','choice','permission','other')),
            reason TEXT NOT NULL,
            state TEXT NOT NULL DEFAULT 'open' CHECK (state IN
                ('open','taken_over','resolved','declined','cancelled','expired')),
            created_at INTEGER NOT NULL,
            resolved_at INTEGER
        ) STRICT;
        CREATE INDEX help_request_computer ON help_request(computer_id, state);

        CREATE TABLE proxy_usage (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            proxy_id TEXT NOT NULL REFERENCES proxy(id) ON DELETE CASCADE,
            computer_id TEXT REFERENCES computer(id) ON DELETE SET NULL,
            period_start INTEGER NOT NULL,
            requests INTEGER NOT NULL DEFAULT 0,
            bytes INTEGER NOT NULL DEFAULT 0,
            cost_micros INTEGER,
            updated_at INTEGER NOT NULL
        ) STRICT;
        -- Único por (proxy, computador, período); linhas sem computador (agregado, ou computador removido) podem repetir: somar.
        CREATE UNIQUE INDEX proxy_usage_key ON proxy_usage(proxy_id, computer_id, period_start) WHERE computer_id IS NOT NULL;
        """)
    }

    /// `v2_activity` (Fatia 2, 08 AR-311): atividade de agentes, atenção, inbox, catálogo, segredos, importação e métricas.
    /// `agent_event` ganha `event_id` (chave de idempotência do helper, única por execução) e `at_ns` (ordem de ocorrência
    /// em nanossegundos, para eventos fora de sequência); `at` segue em ms conforme AR-310.
    static let v2Activity = StoreMigration(id: "v2_activity") { db in
        try db.execute(sql: """
        CREATE TABLE agent_run (
            id TEXT PRIMARY KEY NOT NULL,
            terminal_id TEXT REFERENCES terminal(id) ON DELETE SET NULL,
            parent_run_id TEXT REFERENCES agent_run(id) ON DELETE CASCADE,
            root_run_id TEXT NOT NULL,
            kind TEXT NOT NULL CHECK (kind IN ('main','native_subagent','teammate','app_worker_light','app_worker_isolated')),
            harness TEXT NOT NULL CHECK (harness IN ('claude','codex','opencode','shell','custom')),
            agent_type TEXT,
            provider_session_id TEXT,
            provider_agent_id TEXT,
            mode TEXT CHECK (mode IS NULL OR mode IN ('light','isolated')),
            batch_id TEXT,
            status TEXT NOT NULL CHECK (status IN
                ('starting','idle','working','needs_input','waiting_on_subagents','done','failed','blocked','interrupted','unknown','stalled')),
            status_kind TEXT CHECK (status_kind IS NULL OR status_kind IN ('question','permission','other')),
            estimated INTEGER NOT NULL DEFAULT 0 CHECK (estimated IN (0,1)),
            status_reason TEXT,
            subtitle TEXT,
            started_at INTEGER NOT NULL,
            last_event_at INTEGER,
            ended_at INTEGER
        ) STRICT;
        CREATE INDEX agent_run_parent ON agent_run(parent_run_id);
        CREATE INDEX agent_run_terminal ON agent_run(terminal_id);
        CREATE INDEX agent_run_status ON agent_run(status);

        CREATE TABLE agent_event (
            run_id TEXT NOT NULL REFERENCES agent_run(id) ON DELETE CASCADE,
            seq INTEGER NOT NULL,
            event_id TEXT NOT NULL,
            type TEXT NOT NULL,
            payload_json TEXT NOT NULL CHECK (json_valid(payload_json) AND length(payload_json) <= 16384),
            at INTEGER NOT NULL,
            at_ns INTEGER NOT NULL,
            PRIMARY KEY (run_id, seq)
        ) STRICT;
        CREATE UNIQUE INDEX agent_event_event_id ON agent_event(run_id, event_id);
        CREATE INDEX agent_event_order ON agent_event(run_id, at_ns, seq);
        CREATE INDEX agent_event_at ON agent_event(at);

        CREATE TABLE attention (
            id TEXT PRIMARY KEY NOT NULL,
            kind TEXT NOT NULL,
            priority INTEGER NOT NULL CHECK (priority BETWEEN 1 AND 3),
            source_kind TEXT NOT NULL,
            source_id TEXT NOT NULL,
            reason TEXT,
            payload_json TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(payload_json)),
            created_at INTEGER NOT NULL,
            seen_at INTEGER,
            resolved_at INTEGER
        ) STRICT;
        CREATE INDEX attention_resolved ON attention(resolved_at);

        CREATE TABLE inbox_event (
            id TEXT PRIMARY KEY NOT NULL,
            session_id TEXT REFERENCES session(id) ON DELETE CASCADE,
            kind TEXT NOT NULL,
            payload_json TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(payload_json)),
            created_at INTEGER NOT NULL,
            read_at INTEGER
        ) STRICT;

        CREATE TABLE catalog_item (
            id TEXT PRIMARY KEY NOT NULL,
            source TEXT NOT NULL CHECK (source IN ('claude','codex','agents','opencode','plugin')),
            kind TEXT NOT NULL CHECK (kind IN ('agent','skill','plugin','mcp','instructions')),
            path TEXT NOT NULL,
            name TEXT NOT NULL,
            description TEXT,
            content_hash TEXT,
            clients_json TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(clients_json)),
            discovered_at INTEGER NOT NULL,
            missing_at INTEGER
        ) STRICT;

        CREATE TABLE secret (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL UNIQUE,
            default_env_name TEXT,
            ciphertext BLOB NOT NULL,
            nonce BLOB NOT NULL,
            key_version INTEGER NOT NULL,
            note TEXT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            last_used_at INTEGER
        ) STRICT;

        CREATE TABLE secret_binding (
            secret_id TEXT NOT NULL REFERENCES secret(id) ON DELETE CASCADE,
            target_kind TEXT NOT NULL CHECK (target_kind IN ('profile','session','computer','proxy')),
            target_id TEXT NOT NULL,
            env_name TEXT NOT NULL,
            PRIMARY KEY (secret_id, target_kind, target_id, env_name)
        ) STRICT;

        CREATE TABLE import_run (
            id TEXT PRIMARY KEY NOT NULL,
            source TEXT NOT NULL CHECK (source IN ('racky_json','other','racky_cli')),
            source_path TEXT NOT NULL,
            source_fingerprint TEXT,
            dry_run INTEGER NOT NULL DEFAULT 0 CHECK (dry_run IN (0,1)),
            status TEXT NOT NULL,
            summary_json TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(summary_json)),
            started_at INTEGER NOT NULL,
            finished_at INTEGER
        ) STRICT;

        CREATE TABLE metric (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            value REAL NOT NULL,
            unit TEXT,
            tags_json TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(tags_json)),
            at INTEGER NOT NULL
        ) STRICT;
        CREATE INDEX metric_name_at ON metric(name, at);
        """)
    }

    /// `v4_vault_catalog` (T2-10): metadados do Vault (`secret`, 01 §5.13) e do catálogo por referência
    /// (`catalog_item`, 06 §4.1). Só `ALTER TABLE ADD COLUMN`; as tabelas de `v2_activity` ficam como publicadas.
    /// `catalog_item.id` = hash de fonte + caminho; `missing_at` marca o item cuja origem sumiu (nunca apagamos o histórico).
    static let v4VaultCatalog = StoreMigration(id: "v4_vault_catalog") { db in
        try db.execute(sql: """
        ALTER TABLE secret ADD COLUMN kind TEXT NOT NULL DEFAULT 'envVar'
            CHECK (kind IN ('proxyCredential','envVar','claudeSetupToken','codexBoxIdentity','githubPAT','boxMasterKey'));
        ALTER TABLE secret ADD COLUMN scope TEXT NOT NULL DEFAULT 'global' CHECK (scope IN ('global','project'));
        ALTER TABLE secret ADD COLUMN delivery TEXT NOT NULL DEFAULT 'profileEnv'
            CHECK (delivery IN ('sidecarOnly','profileEnv','boxFileReadOnly'));
        ALTER TABLE secret ADD COLUMN expires_at INTEGER;
        ALTER TABLE secret ADD COLUMN imported_from TEXT;

        ALTER TABLE catalog_item ADD COLUMN scope TEXT NOT NULL DEFAULT 'user' CHECK (scope IN ('user','project','plugin'));
        ALTER TABLE catalog_item ADD COLUMN mtime INTEGER;
        ALTER TABLE catalog_item ADD COLUMN frontmatter_json TEXT CHECK (frontmatter_json IS NULL OR json_valid(frontmatter_json));
        ALTER TABLE catalog_item ADD COLUMN parse_error TEXT;
        ALTER TABLE catalog_item ADD COLUMN shadowed_by TEXT;
        CREATE INDEX catalog_item_name ON catalog_item(kind, name);
        """)
    }


    /// `v5_proxy_ext` (T3-02, 07 §2.6): campos do `ProxyProfile` que `v3_computers` não tem (encadeada após `v4_vault_catalog`). Tabela 1:1 em vez de ALTER, para não
    /// tocar nas tabelas publicadas. Continua sem teto de orçamento (P13): preço é informativo.
    /// `secret_storage`: `vault` = item do Vault (T2-10).
    static let v5ProxyExt = StoreMigration(id: "v5_proxy_ext") { db in
        try db.execute(sql: """
        CREATE TABLE proxy_ext (
            proxy_id TEXT PRIMARY KEY NOT NULL REFERENCES proxy(id) ON DELETE CASCADE,
            secret_storage TEXT NOT NULL DEFAULT 'vault' CHECK (secret_storage IN ('vault','file')),
            geo_json TEXT CHECK (geo_json IS NULL OR json_valid(geo_json)),
            render_endpoint TEXT,
            ca_pem TEXT,
            price_per_request_micros INTEGER CHECK (price_per_request_micros IS NULL OR price_per_request_micros >= 0),
            price_per_render_micros INTEGER CHECK (price_per_render_micros IS NULL OR price_per_render_micros >= 0)
        ) STRICT;
        """)
    }


    /// `v6_agent_tree` (T3-04, 07 §4, CS-307, CS-320): árvore pai -> filhos da orquestração (cada slot de worker do pai, com o computador
    /// reservado para ele e a correlação com o `agent_run` do filho nativo) e as mensagens do pai aos filhos que ele criou (P12).
    /// Encadeada após `v5_proxy_ext`; tabelas novas, nada existente é tocado. Os ids de pai e filho são as identidades MCP do lançamento
    /// (texto, sem FK dura: o `agent_run` do pai nasce com o primeiro hook e a árvore precisa existir antes).
    static let v6AgentTree = StoreMigration(id: "v6_agent_tree") { db in
        try db.execute(sql: """
        CREATE TABLE orchestration_child (
            id TEXT PRIMARY KEY NOT NULL,
            parent_id TEXT NOT NULL,
            parent_run_id TEXT,
            slot INTEGER NOT NULL CHECK (slot >= 1),
            agent_type TEXT NOT NULL,
            computer_name TEXT,
            batch_id TEXT,
            run_id TEXT,
            provider_agent_id TEXT,
            state TEXT NOT NULL DEFAULT 'idle' CHECK (state IN ('idle','reserved','claimed','released','ended','expired')),
            created_at INTEGER NOT NULL,
            reserved_at INTEGER,
            claimed_at INTEGER,
            released_at INTEGER,
            ended_at INTEGER,
            UNIQUE (parent_id, slot)
        ) STRICT;
        CREATE INDEX orchestration_child_parent ON orchestration_child(parent_id, state);
        CREATE INDEX orchestration_child_computer ON orchestration_child(computer_name);

        CREATE TABLE agent_message (
            id TEXT PRIMARY KEY NOT NULL,
            parent_id TEXT NOT NULL,
            child_id TEXT NOT NULL REFERENCES orchestration_child(id) ON DELETE CASCADE,
            text TEXT NOT NULL CHECK (length(text) BETWEEN 1 AND 16000),
            delivery TEXT NOT NULL CHECK (delivery IN ('pty','inbox','queued')),
            created_at INTEGER NOT NULL,
            delivered_at INTEGER
        ) STRICT;
        CREATE INDEX agent_message_child ON agent_message(child_id, delivered_at);
        """)
    }

    /// `v7_subagent_computers` (F12): atributo por sessão "Subagent computers" (`off`/`ask`/`full`). Encadeada após `v6_agent_tree`;
    /// só acrescenta uma coluna com padrão `off`, então sessões antigas seguem sem computadores.
    static let v7SubagentComputers = StoreMigration(id: "v7_subagent_computers") { db in
        try db.execute(sql: """
        ALTER TABLE session ADD COLUMN subagent_computers TEXT NOT NULL DEFAULT 'off' CHECK (subagent_computers IN ('off','ask','full'));
        """)
    }

    /// `v8_orchestration_identity`: o que um app reiniciado precisa para reconhecer pais e filhos que seguiram vivos (adoção de computadores).
    /// Guarda só o SHA-256 das capabilities de lançamento (o valor puro vive nos argumentos do Claude e do helper, nunca aqui) e o que o
    /// pai sabia da sessão (título, modo, proxy). Colunas novas e tabela nova: linhas antigas ficam sem hash e simplesmente não são adotadas.
    static let v8OrchestrationIdentity = StoreMigration(id: "v8_orchestration_identity") { db in
        try db.execute(sql: """
        ALTER TABLE orchestration_child ADD COLUMN capability_hash TEXT;
        CREATE TABLE orchestration_parent (
            id TEXT PRIMARY KEY NOT NULL,
            parent_run_id TEXT,
            session_id TEXT,
            session_title TEXT NOT NULL DEFAULT '',
            mode TEXT NOT NULL CHECK (mode IN ('off','ask','full')),
            proxy TEXT,
            capability_hash TEXT NOT NULL,
            created_at INTEGER NOT NULL
        ) STRICT;
        """)
    }

    /// `v9_orchestration_pool`: o que falta para um Codex pai cujos workers compartilham o servidor `racky_worker` (identidade por thread)
    /// seguir valendo depois de reiniciar o app: CLI do pai, id + hash (só o hash) da capability do pool e a thread já ligada a cada slot.
    static let v9OrchestrationPool = StoreMigration(id: "v9_orchestration_pool") { db in
        try db.execute(sql: """
        ALTER TABLE orchestration_parent ADD COLUMN provider TEXT NOT NULL DEFAULT 'claude';
        ALTER TABLE orchestration_parent ADD COLUMN pool_id TEXT;
        ALTER TABLE orchestration_parent ADD COLUMN pool_capability_hash TEXT;
        ALTER TABLE orchestration_child ADD COLUMN bound_thread TEXT;
        """)
    }

    /// `v10_datasets`: tabelas que os subagentes de uma sessão preenchem (Datasets v1). `dataset` guarda o esquema (colunas e chave em JSON);
    /// `dataset_row` guarda uma linha por chave (SHA-256 da chave canônica), com a proveniência (computador, run, request id, confiança)
    /// e se a linha é válida. Só tabelas novas: nada de v1-v9 muda. Apagar a sessão apaga os datasets e as linhas (cascata).
    static let v10Datasets = StoreMigration(id: "v10_datasets") { db in
        try db.execute(sql: """
        CREATE TABLE dataset (
            id TEXT PRIMARY KEY NOT NULL,
            session_id TEXT NOT NULL REFERENCES session(id) ON DELETE CASCADE,
            name TEXT NOT NULL,
            columns TEXT NOT NULL,
            key TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            UNIQUE (session_id, name)
        ) STRICT;
        CREATE INDEX dataset_session ON dataset(session_id, updated_at);

        CREATE TABLE dataset_row (
            dataset_id TEXT NOT NULL REFERENCES dataset(id) ON DELETE CASCADE,
            row_key TEXT NOT NULL,
            data TEXT NOT NULL,
            valid INTEGER NOT NULL CHECK (valid IN (0,1)),
            error TEXT,
            computer TEXT,
            run_id TEXT,
            request_id TEXT,
            source_url TEXT,
            source_host TEXT,
            trust TEXT CHECK (trust IN ('observed','reported','none')),
            request_method TEXT,
            request_status INTEGER,
            request_ms INTEGER,
            error_kind TEXT,
            first_seen INTEGER NOT NULL,
            last_seen INTEGER NOT NULL,
            seen_count INTEGER NOT NULL DEFAULT 1,
            PRIMARY KEY (dataset_id, row_key)
        ) STRICT;
        CREATE INDEX dataset_row_seen ON dataset_row(dataset_id, last_seen);
        CREATE INDEX dataset_row_first ON dataset_row(dataset_id, first_seen);
        """)
    }

    /// `v11_subagent_harness` (spec subagent-harness): quem roda os subagentes da sessão (`claude` nativo, `codex`, `opencode`, `mixed`) e, em
    /// cada filho, o CLI do worker de app (NULL = nativo), o terminal dele e um título curto da tarefa. Só colunas novas com padrão.
    static let v11SubagentHarness = StoreMigration(id: "v11_subagent_harness") { db in
        try db.execute(sql: """
        ALTER TABLE session ADD COLUMN subagent_harness TEXT NOT NULL DEFAULT 'claude' CHECK (subagent_harness IN ('claude','codex','opencode','mixed'));
        ALTER TABLE orchestration_child ADD COLUMN harness TEXT CHECK (harness IS NULL OR harness IN ('claude','codex','opencode'));
        ALTER TABLE orchestration_child ADD COLUMN worker_terminal_id TEXT;
        ALTER TABLE orchestration_child ADD COLUMN title TEXT;
        """)
    }

    static let all: [StoreMigration] = [
        v1Initial, v2Activity, v3Computers, v4VaultCatalog, v5ProxyExt, v6AgentTree, v7SubagentComputers, v8OrchestrationIdentity, v9OrchestrationPool,
        v10Datasets, v11SubagentHarness,
    ]

    static func migrator(_ migrations: [StoreMigration]) -> DatabaseMigrator {
        var m = DatabaseMigrator()
        for migration in migrations { m.registerMigration(migration.id, migrate: migration.run) }
        return m
    }
}
