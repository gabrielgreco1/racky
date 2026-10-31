import RackyPlatform
import RackyProtocol
import Foundation
import GRDB

/// Persistência SQLite (GRDB 7) da Fatia 1 (00 T2; 08 §3). Toda escrita é `async` e roda fora do main;
/// a UI só observa (`snapshots()`) e nunca grava. Estado transitório (layout, ui_state) usa debounce de 300 ms.
public actor RackyStore {
    public nonisolated let paths: StorePaths
    /// Avisos produzidos durante a abertura (corrupção, versão mais nova, migração).
    public nonisolated let openNotices: [StoreNotice]
    /// Avisos que surgem depois da abertura (por exemplo corrupção em tempo de execução).
    public nonisolated let noticeUpdates: AsyncStream<StoreNotice>
    public private(set) var mode: StoreAccessMode

    nonisolated let writer: any DatabaseWriter
    private nonisolated let noticeContinuation: AsyncStream<StoreNotice>.Continuation
    nonisolated let clock: @Sendable () -> Date
    private nonisolated let debounce: Duration
    private nonisolated let log = LogFacade(.app, category: "store")

    private struct Pending {
        var generation: Int
        var work: @Sendable (Database) throws -> Void
    }
    private var pending: [String: Pending] = [:]
    private var generation = 0
    /// Quantidade de transações de escrita feitas pelo debounce (para testes e métricas).
    public private(set) var debouncedWriteCount = 0

    init(paths: StorePaths, writer: any DatabaseWriter, mode: StoreAccessMode, notices: [StoreNotice],
         clock: @escaping @Sendable () -> Date, debounce: Duration) {
        self.paths = paths; self.writer = writer; self.mode = mode; self.openNotices = notices
        self.clock = clock; self.debounce = debounce
        (noticeUpdates, noticeContinuation) = AsyncStream.makeStream(of: StoreNotice.self)
    }

    // MARK: - Abertura

    /// Abre (ou cria) o banco: verifica integridade, recupera de corrupção, faz backup e migra.
    /// Roda fora do main. Nunca lança por corrupção ou versão mais nova; devolve um store utilizável com avisos.
    @concurrent
    public static func open(
        paths: StorePaths = .default(), clock: @escaping @Sendable () -> Date = { Date() },
        debounce: Duration = .milliseconds(300)
    ) async throws -> RackyStore {
        try await open(paths: paths, clock: clock, debounce: debounce, migrations: StoreMigrations.all)
    }

    @concurrent
    static func open(
        paths: StorePaths, clock: @escaping @Sendable () -> Date, debounce: Duration, migrations: [StoreMigration]
    ) async throws -> RackyStore {
        let prepared = try prepare(paths: paths, now: clock(), migrations: migrations)
        return RackyStore(paths: paths, writer: prepared.writer, mode: prepared.mode, notices: prepared.notices,
                             clock: clock, debounce: debounce)
    }

    private struct Prepared {
        var writer: any DatabaseWriter
        var mode: StoreAccessMode
        var notices: [StoreNotice]
    }

    private static func prepare(paths: StorePaths, now: Date, migrations: [StoreMigration]) throws -> Prepared {
        let fm = FileManager.default
        let log = LogFacade(.app, category: "store")
        try paths.createDirectories()
        var notices: [StoreNotice] = []
        let dbPath = paths.databaseFile

        // 1. Integridade antes da primeira consulta da UI (AR-331).
        if fm.fileExists(atPath: dbPath.path) {
            let size = (try? fm.attributesOfItem(atPath: dbPath.path)[.size] as? Int) ?? 0
            if size == 0 {
                try fm.removeItem(at: dbPath)
            } else if !(try Backups.passes(dbPath, pragma: "quick_check")) {
                notices.append(try Backups.recover(paths, now: now))
            }
        }
        if !fm.fileExists(atPath: dbPath.path) {
            fm.createFile(atPath: dbPath.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }

        // 2. Banco de versão mais nova: somente leitura, nunca apaga (AR-322).
        let migrator = StoreMigrations.migrator(migrations)
        let known = Set(migrations.map(\.id))
        let probe = try Backups.readerQueue(dbPath)
        let applied = try probe.read { try migrator.appliedIdentifiers($0) }
        try probe.close()
        if !Set(applied).isSubset(of: known) {
            notices.append(.newerDatabase(suggestedBackup: Backups.newestPreMigration(paths)))
            return Prepared(writer: try Backups.readerQueue(dbPath), mode: .readOnly, notices: notices)
        }

        // 3. Backup pré-migração e migração (AR-321).
        var config = Configuration()
        config.busyMode = .timeout(5)
        config.prepareDatabase { db in try db.execute(sql: "PRAGMA synchronous = NORMAL") }
        let pool = try DatabasePool(path: dbPath.path, configuration: config)
        let pendingIDs = migrations.map(\.id).filter { !applied.contains($0) }
        do {
            if !applied.isEmpty, let first = pendingIDs.first {
                _ = try Backups.preMigration(pool, paths: paths, migrationID: first, now: now)
            }
            try migrator.migrate(pool)
        } catch {
            try? pool.close()
            log.error("migration failed: \(error)")
            notices.append(.migrationFailed(message: String(describing: error)))
            return Prepared(writer: try Backups.readerQueue(dbPath), mode: .readOnly, notices: notices)
        }

        // 4. Backup diário (AR-330) e permissões (AR-301).
        do { try Backups.dailyIfNeeded(pool, paths: paths, now: now) } catch { log.error("daily backup failed: \(error)") }
        for suffix in ["", "-wal", "-shm"] {
            let p = dbPath.path + suffix
            if fm.fileExists(atPath: p) { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p) }
        }
        return Prepared(writer: pool, mode: .readWrite, notices: notices)
    }

    /// Backup diário sob demanda (o app chama no boot e a cada 24 h). Retorna o arquivo criado, se houve.
    @discardableResult
    public func backupDailyIfNeeded() async throws -> URL? {
        guard mode == .readWrite else { return nil }
        return try Backups.dailyIfNeeded(writer, paths: paths, now: clock())
    }

    /// Descarrega escritas pendentes e fecha o banco.
    public func close() async throws {
        try await flush()
        try writer.close()
    }

    // MARK: - Acesso

    func write<T: Sendable>(_ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        guard mode == .readWrite else { throw StoreError.readOnly }
        do {
            return try await writer.write(body)
        } catch {
            if Backups.isDamage(error) { enterRuntimeReadOnly() }
            throw error
        }
    }

    func read<T: Sendable>(_ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        do {
            return try await writer.read(body)
        } catch {
            if Backups.isDamage(error) { enterRuntimeReadOnly() }
            throw error
        }
    }

    /// Corrupção em tempo de execução: o estado em memória da UI continua, nada mais é gravado; o próximo boot recupera.
    private func enterRuntimeReadOnly() {
        guard mode == .readWrite else { return }
        mode = .readOnly
        log.publicError("database damaged at runtime; switching to read-only")
        noticeContinuation.yield(.runtimeCorruption)
    }

    // MARK: - Observação (snapshots imutáveis para a UI)

    /// Emite um snapshot inicial e outro a cada mudança. A UI consome no MainActor; nenhuma View grava.
    public nonisolated func snapshots() -> AsyncThrowingStream<StoreSnapshot, Error> {
        let observation = ValueObservation.tracking { db in try Self.fetchSnapshot(db) }.removeDuplicates()
        let values = observation.values(in: writer)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await value in values { continuation.yield(value) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func snapshot() async throws -> StoreSnapshot {
        try await read { try Self.fetchSnapshot($0) }
    }

    private static func fetchSnapshot(_ db: Database) throws -> StoreSnapshot {
        StoreSnapshot(
            projects: try ProjectRecord.order(Column("sort_index"), Column("created_at")).fetchAll(db).map { try $0.domain() },
            worktrees: try WorktreeRecord.order(Column("created_at")).fetchAll(db).map { try $0.domain() },
            sessions: try SessionRecord.order(Column("sort_index"), Column("created_at")).fetchAll(db).map { try $0.domain() },
            tabs: try TabRecord.order(Column("sort_index"), Column("created_at")).fetchAll(db).map { try $0.domain() },
            terminals: try TerminalRecord.filter(Column("deleted_at") == nil).order(Column("created_at")).fetchAll(db).map { try $0.domain() },
            profiles: try LaunchProfileRecord.order(Column("name")).fetchAll(db).map { try $0.domain() })
    }

    // MARK: - Projetos e worktrees

    public func save(_ project: Project) async throws {
        let r = ProjectRecord(project)
        try await write { try r.save($0) }
    }

    public func projects(includeArchived: Bool = false) async throws -> [Project] {
        try await read { db in
            var q = ProjectRecord.order(Column("sort_index"), Column("created_at"))
            if !includeArchived { q = q.filter(Column("archived_at") == nil) }
            return try q.fetchAll(db).map { try $0.domain() }
        }
    }

    public func project(id: UUID) async throws -> Project? {
        let key = id.uuidString
        return try await read { try ProjectRecord.fetchOne($0, key: key)?.domain() }
    }

    public func archiveProject(id: UUID, at date: Date? = nil) async throws {
        let key = id.uuidString, ms = RowCodec.ms(date ?? clock())
        try await write { try $0.execute(sql: "UPDATE project SET archived_at = ? WHERE id = ?", arguments: [ms, key]) }
    }

    /// Falha (FK) se ainda houver sessões do projeto: arquive o projeto ou apague as sessões antes. Nunca toca em arquivos.
    public func deleteProject(id: UUID) async throws {
        let key = id.uuidString
        try await write { _ = try ProjectRecord.deleteOne($0, key: key) }
    }

    public func save(_ worktree: Worktree) async throws {
        let r = WorktreeRecord(worktree)
        try await write { try r.save($0) }
    }

    public func worktrees(projectID: UUID) async throws -> [Worktree] {
        let key = projectID.uuidString
        return try await read { db in
            try WorktreeRecord.filter(Column("project_id") == key).order(Column("created_at")).fetchAll(db).map { try $0.domain() }
        }
    }

    public func deleteWorktree(id: UUID) async throws {
        let key = id.uuidString
        try await write { _ = try WorktreeRecord.deleteOne($0, key: key) }
    }

    // MARK: - Sessões, tabs e terminais

    private static func validate(_ session: Session) throws {
        guard session.lifecycle.isPersistable else {
            throw StoreError.invalidModel("session lifecycle \(session.lifecycle.rawValue) is not persisted")
        }
        guard session.isStructurallyValid else {
            throw StoreError.invalidModel("session kind \(session.kind.rawValue) inconsistent with project/worktree")
        }
    }

    private static func validate(_ tab: Tab) throws {
        guard tab.layout.isValid else { throw StoreError.invalidModel("invalid pane layout") }
    }

    public func save(_ session: Session) async throws {
        try Self.validate(session)
        let r = SessionRecord(session)
        try await write { try r.save($0) }
    }

    public func sessions(includeArchived: Bool = false) async throws -> [Session] {
        try await read { db in
            var q = SessionRecord.order(Column("sort_index"), Column("created_at"))
            if !includeArchived { q = q.filter(Column("archived_at") == nil) }
            return try q.fetchAll(db).map { try $0.domain() }
        }
    }

    public func session(id: UUID) async throws -> Session? {
        let key = id.uuidString
        return try await read { try SessionRecord.fetchOne($0, key: key)?.domain() }
    }

    public func markSessionViewed(id: UUID, at date: Date? = nil) async throws {
        let key = id.uuidString, ms = RowCodec.ms(date ?? clock())
        try await write { try $0.execute(sql: "UPDATE session SET unread = 0, last_viewed_at = ? WHERE id = ?", arguments: [ms, key]) }
    }

    /// `Mark as Unread` (03 §2.6) e o não lido que nasce de `done`, `failed` e BEL (06 §3.6).
    public func setSessionUnread(id: UUID, unread: Bool) async throws {
        let key = id.uuidString
        try await write { try $0.execute(sql: "UPDATE session SET unread = ? WHERE id = ?", arguments: [unread ? 1 : 0, key]) }
    }

    /// "Subagent computers" da sessão (F12). Só a coluna: nada mais da sessão muda.
    public func setSubagentComputers(sessionID: UUID, mode: SubagentComputersMode) async throws {
        let key = sessionID.uuidString
        try await write { try $0.execute(sql: "UPDATE session SET subagent_computers = ? WHERE id = ?", arguments: [mode.rawValue, key]) }
    }

    /// "Subagents run as" da sessão (spec subagent-harness). Vale para o próximo `agent_spawn`; nada mais da sessão muda.
    public func setSubagentHarness(sessionID: UUID, harness: SubagentHarness) async throws {
        let key = sessionID.uuidString
        try await write { try $0.execute(sql: "UPDATE session SET subagent_harness = ? WHERE id = ?", arguments: [harness.rawValue, key]) }
    }

    /// Apaga o registro (e tabs/terminais em cascata). Arquivos em disco nunca são tocados aqui.
    public func deleteSession(id: UUID) async throws {
        let key = id.uuidString
        try await write { _ = try SessionRecord.deleteOne($0, key: key) }
    }

    public func save(_ tab: Tab) async throws {
        try Self.validate(tab)
        let r = try TabRecord(tab)
        try await write { try r.save($0) }
    }

    public func tabs(sessionID: UUID, includeClosed: Bool = false) async throws -> [Tab] {
        let key = sessionID.uuidString
        return try await read { db in
            var q = TabRecord.filter(Column("session_id") == key).order(Column("sort_index"), Column("created_at"))
            if !includeClosed { q = q.filter(Column("closed_at") == nil) }
            return try q.fetchAll(db).map { try $0.domain() }
        }
    }

    public func tab(id: UUID) async throws -> Tab? {
        let key = id.uuidString
        return try await read { try TabRecord.fetchOne($0, key: key)?.domain() }
    }

    public func save(_ terminal: Terminal) async throws {
        let r = try TerminalRecord(terminal)
        try await write { try r.save($0) }
    }

    public func terminals(tabID: UUID, includeDeleted: Bool = false) async throws -> [Terminal] {
        let key = tabID.uuidString
        return try await read { db in
            var q = TerminalRecord.filter(Column("tab_id") == key).order(Column("created_at"))
            if !includeDeleted { q = q.filter(Column("deleted_at") == nil) }
            return try q.fetchAll(db).map { try $0.domain() }
        }
    }

    public func terminal(id: UUID) async throws -> Terminal? {
        let key = id.uuidString
        return try await read { try TerminalRecord.fetchOne($0, key: key)?.domain() }
    }

    /// Terminais em um estado de processo (reconciliação no boot, por exemplo `running` → `interrupted`).
    public func terminals(in state: TerminalProcessState) async throws -> [Terminal] {
        let raw = state.rawValue
        return try await read { db in
            try TerminalRecord.filter(Column("state") == raw && Column("deleted_at") == nil).fetchAll(db).map { try $0.domain() }
        }
    }

    /// Cria sessão, tabs e terminais numa única transação (criar sessão abre um terminal, P9).
    public func saveBundle(session: Session, tabs: [Tab], terminals: [Terminal]) async throws {
        try Self.validate(session)
        for t in tabs { try Self.validate(t) }
        let sr = SessionRecord(session)
        let trs = try tabs.map(TabRecord.init)
        let ters = try terminals.map(TerminalRecord.init)
        try await write { db in
            try sr.save(db)
            for t in trs { try t.save(db) }
            for t in ters { try t.save(db) }
        }
    }

    // MARK: - Perfis

    public func save(_ profile: LaunchProfile) async throws {
        let r = try LaunchProfileRecord(profile)
        try await write { try r.save($0) }
    }

    public func profiles() async throws -> [LaunchProfile] {
        try await read { try LaunchProfileRecord.order(Column("name")).fetchAll($0).map { try $0.domain() } }
    }

    public func deleteProfile(id: UUID) async throws {
        let key = id.uuidString
        try await write { _ = try LaunchProfileRecord.deleteOne($0, key: key) }
    }

    // MARK: - setting e ui_state

    public func setting<T: Decodable & Sendable>(_ key: String, as type: T.Type = T.self) async throws -> T? {
        try await keyValue(table: "setting", key: key, as: type)
    }

    public func setSetting<T: Encodable & Sendable>(_ key: String, _ value: T) async throws {
        let json = try RowCodec.json(value), ms = RowCodec.ms(clock())
        try await write { try Self.upsertKeyValue($0, table: "setting", key: key, json: json, ms: ms) }
    }

    public func uiState<T: Decodable & Sendable>(_ key: String, as type: T.Type = T.self) async throws -> T? {
        try await keyValue(table: "ui_state", key: key, as: type)
    }

    public func setUIState<T: Encodable & Sendable>(_ key: String, _ value: T) async throws {
        let json = try RowCodec.json(value), ms = RowCodec.ms(clock())
        try await write { try Self.upsertKeyValue($0, table: "ui_state", key: key, json: json, ms: ms) }
    }

    private func keyValue<T: Decodable & Sendable>(table: String, key: String, as type: T.Type) async throws -> T? {
        let json: String? = try await read { try String.fetchOne($0, sql: "SELECT value_json FROM \(table) WHERE key = ?", arguments: [key]) }
        return try json.map { try RowCodec.decode(T.self, $0, table: table) }
    }

    private static func upsertKeyValue(_ db: Database, table: String, key: String, json: String, ms: Int64) throws {
        try db.execute(
            sql: "INSERT INTO \(table)(key, value_json, updated_at) VALUES (?, ?, ?) ON CONFLICT(key) DO UPDATE SET value_json = excluded.value_json, updated_at = excluded.updated_at",
            arguments: [key, json, ms])
    }

    // MARK: - Persistência com debounce (layout e estado transitório)

    /// Layout só é gravado no fim do gesto (chame `setLayout`) ou, durante o gesto, com debounce de 300 ms. Nunca a cada frame.
    public func scheduleLayout(tabID: UUID, layout: PaneLayout, focusedTerminalID: UUID?) throws {
        guard mode == .readWrite else { throw StoreError.readOnly }
        guard layout.isValid else { throw StoreError.invalidModel("invalid pane layout") }
        let json = try RowCodec.json(layout), key = tabID.uuidString, focus = focusedTerminalID?.uuidString
        schedule(key: "tab-layout:\(key)") { db in
            try db.execute(sql: "UPDATE tab SET layout_json = ?, focused_terminal_id = ? WHERE id = ?", arguments: [json, focus, key])
        }
    }

    public func scheduleUIState<T: Encodable & Sendable>(_ key: String, _ value: T) throws {
        guard mode == .readWrite else { throw StoreError.readOnly }
        let json = try RowCodec.json(value), ms = RowCodec.ms(clock())
        schedule(key: "ui-state:\(key)") { try Self.upsertKeyValue($0, table: "ui_state", key: key, json: json, ms: ms) }
    }

    /// Configuração do usuário com debounce de 300 ms (03 §14.1 regra 6): vários toques seguidos num stepper viram uma escrita.
    public func scheduleSetting<T: Encodable & Sendable>(_ key: String, _ value: T) throws {
        guard mode == .readWrite else { throw StoreError.readOnly }
        let json = try RowCodec.json(value), ms = RowCodec.ms(clock())
        schedule(key: "setting:\(key)") { try Self.upsertKeyValue($0, table: "setting", key: key, json: json, ms: ms) }
    }

    /// Grava o layout agora (fim do gesto), cancelando qualquer escrita pendente do mesmo tab.
    public func setLayout(tabID: UUID, layout: PaneLayout, focusedTerminalID: UUID?) async throws {
        guard layout.isValid else { throw StoreError.invalidModel("invalid pane layout") }
        pending["tab-layout:\(tabID.uuidString)"] = nil
        let json = try RowCodec.json(layout), key = tabID.uuidString, focus = focusedTerminalID?.uuidString
        try await write { try $0.execute(sql: "UPDATE tab SET layout_json = ?, focused_terminal_id = ? WHERE id = ?", arguments: [json, focus, key]) }
    }

    private func schedule(key: String, work: @escaping @Sendable (Database) throws -> Void) {
        generation += 1
        let gen = generation
        pending[key] = Pending(generation: gen, work: work)
        let delay = debounce
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            await self?.flushIfCurrent(key: key, generation: gen)
        }
    }

    private func flushIfCurrent(key: String, generation gen: Int) async {
        guard let p = pending[key], p.generation == gen else { return }
        pending[key] = nil
        do {
            try await write(p.work)
            debouncedWriteCount += 1
        } catch {
            log.error("debounced write failed: \(error)")
        }
    }

    /// Grava agora tudo que está pendente, numa única transação (⌘Q, troca de sessão).
    public func flush() async throws {
        guard !pending.isEmpty else { return }
        let works = pending.values.map(\.work)
        pending.removeAll()
        try await write { db in for w in works { try w(db) } }
        debouncedWriteCount += 1
    }
}
