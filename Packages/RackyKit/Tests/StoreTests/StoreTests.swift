import RackyProtocol
import Foundation
import GRDB
import Testing
@testable import RackyStore

@Suite struct MigrationTests {
    @Test func emptyDatabaseGetsAllTablesFromTheFullMigrationChain() async throws {
        let home = try TempHome(); defer { home.remove() }
        let store = try await home.openStore()
        #expect(store.openNotices.isEmpty)
        #expect(await store.mode == .readWrite)
        try await store.close()
        let tables = try tableNames(at: home.paths.databaseFile)
        #expect(tables == [
            "agent_event", "agent_message", "agent_run", "attention", "browser_profile", "catalog_item", "computer", "computer_queue", "dataset", "dataset_row", "grdb_migrations",
            "help_request", "import_run", "inbox_event", "launch_profile", "metric", "orchestration_child", "orchestration_parent", "project", "proxy", "proxy_ext", "proxy_usage", "secret",
            "secret_binding", "session", "setting", "tab", "terminal", "ui_state", "worktree",
        ])
        let ids = try { () throws -> [String] in
            var c = Configuration(); c.readonly = true
            let q = try DatabaseQueue(path: home.paths.databaseFile.path, configuration: c)
            return try q.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations") }
        }()
        #expect(ids == ["v1_initial", "v2_activity", "v3_computers", "v4_vault_catalog", "v5_proxy_ext", "v6_agent_tree", "v7_subagent_computers", "v8_orchestration_identity", "v9_orchestration_pool", "v10_datasets", "v11_subagent_harness"])
    }

    @Test func schemaIsStrictAndRejectsInconsistentSessions() async throws {
        let home = try TempHome(); defer { home.remove() }
        let store = try await home.openStore()
        let pool = store.writer
        // CHECK do schema (R1 K-81): sessão clean não pode ter projeto.
        let p = Fixture.project()
        try await store.save(p)
        await #expect(throws: DatabaseError.self) {
            try await pool.write { db in
                try db.execute(sql: "INSERT INTO session(id, kind, project_id, folder_path, title, created_at) VALUES (?, 'clean', ?, '/x', 't', 0)",
                               arguments: [UUID().uuidString, p.id.uuidString])
            }
        }
        await #expect(throws: DatabaseError.self) {
            try await pool.write { db in
                try db.execute(sql: "INSERT INTO session(id, kind, folder_path, title, created_at) VALUES (?, 'worktree', '/x', 't', 0)", arguments: [UUID().uuidString])
            }
        }
        // STRICT: tipo errado em coluna INTEGER é rejeitado.
        await #expect(throws: DatabaseError.self) {
            try await pool.write { db in
                try db.execute(sql: "INSERT INTO setting(key, value_json, updated_at) VALUES ('k', '1', 'not-a-number')")
            }
        }
        // json_valid
        await #expect(throws: DatabaseError.self) {
            try await pool.write { db in
                try db.execute(sql: "INSERT INTO setting(key, value_json, updated_at) VALUES ('k2', '{oops', 1)")
            }
        }
        try await store.close()
    }

    @Test func pendingMigrationCreatesBackupBeforeApplying() async throws {
        let home = try TempHome(); defer { home.remove() }
        let v1 = try await home.openStore(day: 0)
        let project = Fixture.project()
        try await v1.save(project)
        try await v1.close()
        #expect(home.backups.filter { $0.hasPrefix("pre-migration-") }.isEmpty, "banco novo não tem o que salvar")

        let v2 = try await home.openStore(day: 1, migrations: StoreMigrations.all + [Fixture.v2Test])
        #expect(v2.openNotices.isEmpty)
        try await v2.close()
        let pre = home.backups.filter { $0.hasPrefix("pre-migration-v2_test-") }
        #expect(pre.count == 1)
        let backupURL = home.paths.backupsDirectory.appendingPathComponent(pre[0])
        #expect(try rowCount(at: backupURL, table: "project") == 1, "backup tem os dados de N-1")
        #expect(!(try tableNames(at: backupURL)).contains("agent_run_test"), "backup é anterior à migração")
        #expect((try tableNames(at: home.paths.databaseFile)).contains("agent_run_test"))
        #expect(try rowCount(at: home.paths.databaseFile, table: "project") == 1, "dados preservados")
    }

    @Test func failedMigrationRollsBackAndOpensReadOnly() async throws {
        let home = try TempHome(); defer { home.remove() }
        let v1 = try await home.openStore()
        try await v1.save(Fixture.project())
        try await v1.close()

        let store = try await home.openStore(day: 1, migrations: StoreMigrations.all + [Fixture.v2Broken])
        #expect(await store.mode == .readOnly)
        guard case .migrationFailed = store.openNotices.first else { Issue.record("expected migrationFailed"); return }
        #expect(try await store.projects().count == 1, "banco intocado e legível")
        await #expect(throws: StoreError.readOnly) { try await store.save(Fixture.project(2)) }
        try await store.close()
        #expect(!(try tableNames(at: home.paths.databaseFile)).contains("half_done"), "rollback da transação")
        #expect(home.backups.contains { $0.hasPrefix("pre-migration-v2_broken-") })
    }

    @Test func newerDatabaseOpensReadOnlyAndIsNeverModified() async throws {
        let home = try TempHome(); defer { home.remove() }
        let newer = try await home.openStore(day: 0, migrations: StoreMigrations.all + [Fixture.v2Test])
        try await newer.save(Fixture.project())
        try await newer.close()
        let before = try Data(contentsOf: home.paths.databaseFile)

        let store = try await home.openStore(day: 1)  // app "antigo": só conhece v1_initial
        #expect(await store.mode == .readOnly)
        guard case .newerDatabase = store.openNotices.first else { Issue.record("expected newerDatabase"); return }
        #expect(store.openNotices.first?.bannerText == "Database was created by a newer Racky")
        #expect(try await store.projects().count == 1, "leitura funciona")
        await #expect(throws: StoreError.readOnly) { try await store.save(Fixture.project(2)) }
        await #expect(throws: StoreError.readOnly) { try await store.setSetting("k", 1) }
        try await store.close()
        #expect(try Data(contentsOf: home.paths.databaseFile) == before, "nunca apaga nem altera")
        #expect(!FileManager.default.fileExists(atPath: home.paths.dbDirectory.appendingPathComponent("corrupt-x").path))
    }

    @Test func newerDatabaseSuggestsPreMigrationBackup() async throws {
        let home = try TempHome(); defer { home.remove() }
        let v1 = try await home.openStore(day: 0)
        try await v1.save(Fixture.project())
        try await v1.close()
        let v2 = try await home.openStore(day: 1, migrations: StoreMigrations.all + [Fixture.v2Test])
        try await v2.close()
        let old = try await home.openStore(day: 2)
        guard case .newerDatabase(let suggested) = old.openNotices.first else { Issue.record("expected newerDatabase"); return }
        #expect(suggested?.lastPathComponent.hasPrefix("pre-migration-v2_test-") == true)
        try await old.close()
    }
}

@Suite struct RoundTripTests {
    @Test func everySliceOneEntityRoundTrips() async throws {
        let home = try TempHome(); defer { home.remove() }
        let store = try await home.openStore()
        let project = Fixture.project(), wt = Fixture.worktree(project)
        let profile = Fixture.profile(project: project)
        try await store.save(project)
        try await store.save(wt)
        try await store.save(profile)

        let wtSession = Fixture.worktreeSession(project, wt)
        var tab = Tab(sessionID: wtSession.id, title: "Claude", layout: .leaf(Pane(content: .terminal(.v7()))), createdAt: Fixture.t0)
        let (layout, terms) = Fixture.layoutAndTerminal(tabID: tab.id)
        tab.layout = layout
        tab.focusedTerminalID = terms[0].id
        try await store.saveBundle(session: wtSession, tabs: [tab], terminals: terms)
        let clean = Fixture.cleanSession()
        try await store.save(clean)
        let folder = Session(kind: .folder, projectID: project.id, folderPath: "/f", title: "folder", createdAt: Fixture.t0)
        try await store.save(folder)
        let checkout = Session(kind: .checkout, projectID: project.id, worktreeID: wt.id, folderPath: "/c", title: "checkout", createdAt: Fixture.t0)
        try await store.save(checkout)

        try await store.setSetting("terminal.fontSize", 13.5)
        try await store.setUIState("sidebar", ["width": 280, "collapsed": 0])

        try await store.close()
        let reopened = try await home.openStore(day: 0)
        #expect(try await reopened.project(id: project.id) == project)
        #expect(try await reopened.worktrees(projectID: project.id) == [wt])
        #expect(try await reopened.profiles() == [profile])
        #expect(try await reopened.session(id: wtSession.id) == wtSession)
        #expect(try await reopened.session(id: clean.id) == clean)
        #expect(try await reopened.session(id: folder.id) == folder)
        #expect(try await reopened.session(id: checkout.id) == checkout)
        #expect(try await reopened.tab(id: tab.id) == tab)
        let readTerms = try await reopened.terminals(tabID: tab.id)
        #expect(readTerms == terms)
        #expect(readTerms[0].launchSpec.initialPrompt == "hello")
        #expect(try await reopened.setting("terminal.fontSize", as: Double.self) == 13.5)
        #expect(try await reopened.uiState("sidebar", as: [String: Int].self) == ["width": 280, "collapsed": 0])
        #expect(try await reopened.setting("missing", as: Int.self) == nil)
        try await reopened.close()
    }

    @Test func updatesAreUpsertsAndFiltersWork() async throws {
        let home = try TempHome(); defer { home.remove() }
        let store = try await home.openStore()
        var p = Fixture.project()
        try await store.save(p)
        p.name = "renamed"
        try await store.save(p)
        #expect(try await store.projects().map(\.name) == ["renamed"])
        try await store.archiveProject(id: p.id, at: Fixture.t0)
        #expect(try await store.projects().isEmpty)
        #expect(try await store.projects(includeArchived: true).count == 1)

        let clean = Fixture.cleanSession()
        try await store.save(clean)
        try await store.markSessionViewed(id: clean.id, at: Fixture.t0.addingTimeInterval(5))
        let viewed = try #require(try await store.session(id: clean.id))
        #expect(!viewed.unread && viewed.lastViewedAt == Fixture.t0.addingTimeInterval(5))
        try await store.close()
    }

    @Test func invalidModelsAreRejectedBeforeWriting() async throws {
        let home = try TempHome(); defer { home.remove() }
        let store = try await home.openStore()
        let p = Fixture.project()
        try await store.save(p)
        let badKind = Session(kind: .clean, projectID: p.id, folderPath: "/x", title: "t")
        await #expect(throws: StoreError.self) { try await store.save(badKind) }
        let creating = Session(kind: .clean, folderPath: "/x", title: "t", lifecycle: .creating)
        await #expect(throws: StoreError.self) { try await store.save(creating) }
        let dup = Pane(content: .terminal(.v7()))
        let badLayout = PaneLayout.split(axis: .horizontal, ratio: 0.5, first: .leaf(dup), second: .leaf(Pane(content: dup.content)))
        let s = Fixture.cleanSession()
        try await store.save(s)
        await #expect(throws: StoreError.self) { try await store.save(Tab(sessionID: s.id, title: "t", layout: badLayout)) }
        try await store.close()
    }

    @Test func deletingSessionCascadesAndDeletingProjectWithSessionsFails() async throws {
        let home = try TempHome(); defer { home.remove() }
        let store = try await home.openStore()
        let project = Fixture.project(), wt = Fixture.worktree(project)
        try await store.save(project); try await store.save(wt)
        let session = Fixture.worktreeSession(project, wt)
        let tab = Tab(sessionID: session.id, title: "t", layout: .leaf(Pane(content: .terminal(.v7()))))
        let term = Terminal(tabID: tab.id, provider: .shell, title: "zsh", cwd: "/", launchSpec: LaunchSpec(provider: .shell))
        try await store.saveBundle(session: session, tabs: [tab], terminals: [term])
        await #expect(throws: DatabaseError.self) { try await store.deleteProject(id: project.id) }
        try await store.deleteSession(id: session.id)
        #expect(try await store.tab(id: tab.id) == nil)
        #expect(try await store.terminal(id: term.id) == nil)
        try await store.deleteProject(id: project.id)
        #expect(try await store.worktrees(projectID: project.id).isEmpty)
        try await store.close()
    }

    @Test func terminalsByStateSupportBootReconciliation() async throws {
        let home = try TempHome(); defer { home.remove() }
        let store = try await home.openStore()
        let s = Fixture.cleanSession()
        let tab = Tab(sessionID: s.id, title: "t", layout: .leaf(Pane(content: .terminal(.v7()))))
        var running = Terminal(tabID: tab.id, provider: .claude, title: "c", cwd: "/", launchSpec: LaunchSpec(provider: .claude), state: .running)
        let idle = Terminal(tabID: tab.id, provider: .shell, title: "z", cwd: "/", launchSpec: LaunchSpec(provider: .shell))
        try await store.saveBundle(session: s, tabs: [tab], terminals: [running, idle])
        #expect(try await store.terminals(in: .running).map(\.id) == [running.id])
        running.state = .interrupted
        try await store.save(running)
        #expect(try await store.terminals(in: .running).isEmpty)
        #expect(try await store.terminals(in: .interrupted).count == 1)
        try await store.close()
    }

    @Test func filePermissionsAreOwnerOnly() async throws {
        let home = try TempHome(); defer { home.remove() }
        let store = try await home.openStore()
        try await store.save(Fixture.project())
        func perms(_ url: URL) throws -> Int { (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1 }
        #expect(try perms(home.paths.dbDirectory) == 0o700)
        #expect(try perms(home.paths.backupsDirectory) == 0o700)
        #expect(try perms(home.paths.databaseFile) == 0o600)
        for b in home.backups { #expect(try perms(home.paths.backupsDirectory.appendingPathComponent(b)) == 0o600) }
        try await store.close()
    }
}

@Suite struct BackupTests {
    @Test func dailyBackupIsCreatedOncePerDayAndKeepsSeven() async throws {
        let home = try TempHome(); defer { home.remove() }
        for day in 0..<9 {
            let s = try await home.openStore(day: day)
            _ = try await s.backupDailyIfNeeded()  // segunda chamada no mesmo dia não cria outro
            try await s.close()
        }
        let daily = home.backups.filter { $0.hasPrefix("daily-") }
        #expect(daily.count == 7)
    }

    @Test func preMigrationBackupsKeepFive() async throws {
        let home = try TempHome(); defer { home.remove() }
        var migrations = StoreMigrations.all
        let first = try await home.openStore(day: 0)
        try await first.save(Fixture.project())
        try await first.close()
        for n in 2...8 {
            migrations.append(StoreMigration(id: "v\(n)_test") { db in
                try db.execute(sql: "CREATE TABLE t\(n) (id TEXT PRIMARY KEY NOT NULL) STRICT")
            })
            let s = try await home.openStore(day: n, migrations: migrations)
            try await s.close()
        }
        #expect(home.backups.filter { $0.hasPrefix("pre-migration-") }.count == 5)
    }
}

@Suite struct CorruptionTests {
    @Test(arguments: [true, false])
    func corruptedFileIsMovedAndLatestBackupRestored(wholeFile: Bool) async throws {
        let home = try TempHome(); defer { home.remove() }
        let store = try await home.openStore(day: 0)
        let project = Fixture.project()
        try await store.save(project)
        for i in 0..<40 { try await store.save(Fixture.project(100 + i)) }  // várias páginas para a corrupção parcial pegar dados
        // O backup do dia foi criado no open (vazio); refaz com os dados.
        try FileManager.default.removeItem(at: home.paths.backupsDirectory.appendingPathComponent(home.backups[0]))
        #expect(try await store.backupDailyIfNeeded() != nil)
        try await store.close()
        try home.corruptMainFile(wholeFile: wholeFile)

        let recovered = try await home.openStore(day: 0)
        #expect(await recovered.mode == .readWrite, "a UI continua funcional")
        guard case .restoredFromBackup(_, let corruptPath) = recovered.openNotices.first else {
            Issue.record("expected restoredFromBackup, got \(recovered.openNotices)"); return
        }
        #expect(FileManager.default.fileExists(atPath: corruptPath.path), "arquivo corrompido preservado em db/corrupt-<ts>/")
        #expect(corruptPath.deletingLastPathComponent().lastPathComponent.hasPrefix("corrupt-"))
        #expect(recovered.openNotices.first?.bannerText.hasPrefix("Restored from the backup of ") == true)
        #expect(try await recovered.project(id: project.id) == project, "dados do backup")
        try await recovered.save(Fixture.project(999))  // e continua gravando
        try await recovered.close()
    }

    @Test func noValidBackupStartsEmptyWithBanner() async throws {
        let home = try TempHome(); defer { home.remove() }
        let store = try await home.openStore()
        try await store.save(Fixture.project())
        try await store.close()
        for b in home.backups { try FileManager.default.removeItem(at: home.paths.backupsDirectory.appendingPathComponent(b)) }
        try home.corruptMainFile(wholeFile: true)

        let recovered = try await home.openStore()
        guard case .recoveredEmpty(let corruptPath) = recovered.openNotices.first else {
            Issue.record("expected recoveredEmpty, got \(recovered.openNotices)"); return
        }
        #expect(FileManager.default.fileExists(atPath: corruptPath.path), "Reveal Corrupt File aponta para um arquivo existente")
        #expect(try await recovered.projects().isEmpty)
        try await recovered.save(Fixture.project())
        #expect(try await recovered.projects().count == 1)
        try await recovered.close()
    }

    @Test func invalidNewestBackupFallsBackToOlderValidOne() async throws {
        let home = try TempHome(); defer { home.remove() }
        let s0 = try await home.openStore(day: 0)
        let keep = Fixture.project(1)
        try await s0.save(keep)
        try await s0.close()
        // Backup bom e antigo; backup ruim e novo.
        let good = home.paths.backupsDirectory.appendingPathComponent("daily-good.sqlite")
        let bad = home.paths.backupsDirectory.appendingPathComponent("daily-bad.sqlite")
        for b in home.backups { try FileManager.default.removeItem(at: home.paths.backupsDirectory.appendingPathComponent(b)) }
        let reopen = try await home.openStore(day: 3)
        try await reopen.close()
        try FileManager.default.copyItem(at: home.paths.databaseFile, to: good)
        try Data(repeating: 0x41, count: 9000).write(to: bad)
        try home.setModified("daily-good.sqlite", to: Date(timeIntervalSince1970: 1_000))
        try home.setModified("daily-bad.sqlite", to: Date(timeIntervalSince1970: 2_000))
        for b in home.backups where b != "daily-good.sqlite" && b != "daily-bad.sqlite" {
            try FileManager.default.removeItem(at: home.paths.backupsDirectory.appendingPathComponent(b))
        }
        try home.corruptMainFile(wholeFile: true)

        let recovered = try await home.openStore(day: 3)
        guard case .restoredFromBackup(let date, _) = recovered.openNotices.first else {
            Issue.record("expected restoredFromBackup, got \(recovered.openNotices)"); return
        }
        #expect(date == Date(timeIntervalSince1970: 1_000))
        #expect(try await recovered.project(id: keep.id) == keep)
        try await recovered.close()
    }

    @Test func healthyDatabaseIsNeverTouchedByRecovery() async throws {
        let home = try TempHome(); defer { home.remove() }
        let s = try await home.openStore()
        try await s.save(Fixture.project())
        try await s.close()
        let again = try await home.openStore()
        #expect(again.openNotices.isEmpty)
        #expect(try await again.projects().count == 1)
        let corruptDirs = ((try? FileManager.default.contentsOfDirectory(atPath: home.paths.dbDirectory.path)) ?? []).filter { $0.hasPrefix("corrupt-") }
        #expect(corruptDirs.isEmpty)
        try await again.close()
    }
}

@Suite struct PersistenceDebounceTests {
    static func prepare(_ store: RackyStore) async throws -> (Tab, Terminal) {
        let s = Fixture.cleanSession()
        let tab = Tab(sessionID: s.id, title: "t", layout: .leaf(Pane(content: .terminal(.v7()))))
        let term = Terminal(tabID: tab.id, provider: .shell, title: "z", cwd: "/", launchSpec: LaunchSpec(provider: .shell))
        try await store.saveBundle(session: s, tabs: [tab], terminals: [term])
        return (tab, term)
    }

    @Test func burstOfLayoutUpdatesCoalescesIntoOneWrite() async throws {
        let home = try TempHome(); defer { home.remove() }
        let store = try await home.openStore(debounce: .milliseconds(80))
        let (tab, _) = try await Self.prepare(store)
        var last = tab.layout
        for i in 1...20 {
            let a = Pane(content: .terminal(.v7())), b = Pane(content: .terminal(.v7()))
            last = PaneLayout.leaf(a).splitting(paneID: a.id, axis: .horizontal, ratio: 0.1 + Double(i) * 0.04, inserting: b) ?? last
            try await store.scheduleLayout(tabID: tab.id, layout: last, focusedTerminalID: nil)
        }
        #expect(try await store.tab(id: tab.id)?.layout == tab.layout, "nada gravado durante o gesto")
        try await Task.sleep(for: .milliseconds(500))
        #expect(await store.debouncedWriteCount == 1)
        #expect(try await store.tab(id: tab.id)?.layout == last)
        try await store.close()
    }

    @Test func flushWritesPendingImmediatelyAndSetLayoutCancelsPending() async throws {
        let home = try TempHome(); defer { home.remove() }
        let store = try await home.openStore(debounce: .seconds(30))
        let (tab, term) = try await Self.prepare(store)
        let a = Pane(content: .terminal(term.id)), b = Pane(content: .terminal(.v7()))
        let split = try #require(PaneLayout.leaf(a).splitting(paneID: a.id, axis: .vertical, inserting: b))
        try await store.scheduleLayout(tabID: tab.id, layout: split, focusedTerminalID: term.id)
        try await store.scheduleUIState("sidebar.width", 300)
        #expect(try await store.uiState("sidebar.width", as: Int.self) == nil)
        try await store.flush()
        #expect(try await store.tab(id: tab.id)?.layout == split)
        #expect(try await store.tab(id: tab.id)?.focusedTerminalID == term.id)
        #expect(try await store.uiState("sidebar.width", as: Int.self) == 300)
        #expect(await store.debouncedWriteCount == 1, "um flush = uma transação")

        // Fim do gesto grava direto e descarta o pendente do mesmo tab.
        let other = PaneLayout.leaf(Pane(content: .terminal(term.id)))
        try await store.scheduleLayout(tabID: tab.id, layout: split, focusedTerminalID: nil)
        try await store.setLayout(tabID: tab.id, layout: other, focusedTerminalID: nil)
        try await store.flush()
        #expect(try await store.tab(id: tab.id)?.layout == other)
        try await store.close()
    }

    @Test func closeFlushesPendingWrites() async throws {
        let home = try TempHome(); defer { home.remove() }
        let store = try await home.openStore(debounce: .seconds(30))
        try await store.scheduleUIState("k", "v")
        try await store.close()
        let again = try await home.openStore()
        #expect(try await again.uiState("k", as: String.self) == "v")
        try await again.close()
    }
}

@Suite struct ObservationTests {
    @Test(.timeLimit(.minutes(1)))
    func snapshotsStreamEmitsInitialAndEveryChange() async throws {
        let home = try TempHome(); defer { home.remove() }
        let store = try await home.openStore()
        var iterator = store.snapshots().makeAsyncIterator()
        let initial = try await iterator.next()
        #expect(initial == StoreSnapshot())

        let p = Fixture.project()
        try await store.save(p)
        var seen = try await iterator.next()
        while let s = seen, s.projects.isEmpty { seen = try await iterator.next() }
        #expect(seen?.projects == [p])

        let session = Fixture.cleanSession()
        try await store.save(session)
        seen = try await iterator.next()
        while let s = seen, s.sessions.isEmpty { seen = try await iterator.next() }
        #expect(seen?.sessions == [session])
        try await store.close()
    }
}

@Suite struct FullMigrationChainTests {
    @Test func v1DatabaseUpgradesThroughEveryMigrationToCurrent() async throws {
        #expect(StoreMigrations.all.map(\.id) == ["v1_initial", "v2_activity", "v3_computers", "v4_vault_catalog", "v5_proxy_ext", "v6_agent_tree", "v7_subagent_computers", "v8_orchestration_identity", "v9_orchestration_pool", "v10_datasets", "v11_subagent_harness"])
        let home = try TempHome(); defer { home.remove() }
        let v1 = try await home.openStore(day: 0, migrations: [StoreMigrations.v1Initial])
        let project = Fixture.project()
        try await v1.save(project)
        try await v1.close()

        let current = try await home.openStore(day: 1)
        #expect(current.openNotices.isEmpty)
        #expect(await current.mode == .readWrite)
        #expect(try await current.project(id: project.id)?.name == project.name)
        try await current.close()
        let tables = try tableNames(at: home.paths.databaseFile)
        for table in ["agent_run", "secret", "computer", "proxy_usage"] { #expect(tables.contains(table), "\(table) ausente após a cadeia") }
        #expect(home.backups.contains { $0.hasPrefix("pre-migration-v2_activity-") })
    }
}
