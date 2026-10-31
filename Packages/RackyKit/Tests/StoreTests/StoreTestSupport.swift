import RackyProtocol
import Foundation
import GRDB
@testable import RackyStore

/// Diretório temporário isolado por teste (nunca toca em `~/Library/Application Support/Racky`).
struct TempHome {
    let paths: StorePaths
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("racky-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = StorePaths(root: root)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    var backups: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: paths.backupsDirectory.path)) ?? []).sorted()
    }

    func openStore(day: Int = 0, debounce: Duration = .milliseconds(300),
                   migrations: [StoreMigration] = StoreMigrations.all) async throws -> RackyStore {
        let now = Self.date(day: day)
        return try await RackyStore.open(paths: paths, clock: { now }, debounce: debounce, migrations: migrations)
    }

    static func date(day: Int) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + Double(day) * 86_400) }

    /// Sobrescreve bytes do arquivo principal (banco fechado) para simular corrupção.
    func corruptMainFile(wholeFile: Bool) throws {
        let url = paths.databaseFile
        var data = try Data(contentsOf: url)
        if wholeFile {
            data = Data((0..<max(data.count, 8192)).map { _ in UInt8.random(in: 0...255) })
        } else {
            let start = min(4096, data.count / 2)
            for i in start..<data.count { data[i] = 0xFF }
        }
        try data.write(to: url)
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }

    func setModified(_ name: String, to date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: paths.backupsDirectory.appendingPathComponent(name).path)
    }
}

enum Fixture {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func project(_ n: Int = 1) -> Project {
        Project(name: "repo\(n)", rootPath: "/Users/x/repo\(n)", gitRemoteURL: "git@example.com:x/repo\(n).git",
                defaultBranch: "main", worktreeRoot: "/Users/x/wt", branchPrefix: "alex/", color: "blue",
                importSourceID: "import-\(n)", sortIndex: n, createdAt: t0, archivedAt: nil)
    }

    static func worktree(_ p: Project) -> Worktree {
        Worktree(projectID: p.id, path: "\(p.rootPath)-wt", branch: "feat/x", baseRef: "origin/main", isMain: false,
                 createdByApp: true, source: .manual, createdAt: t0, lastSeenAt: t0.addingTimeInterval(10))
    }

    static func cleanSession() -> Session {
        Session(kind: .clean, folderPath: "/Users/x/Racky/sessions/quiet-harbor", managedFolder: true, title: "quiet-harbor",
                statusNote: StatusNote(text: "ready", author: "user", at: t0), unread: true, lastViewedAt: t0,
                sortIndex: 2, createdAt: t0, lastActiveAt: t0.addingTimeInterval(60))
    }

    static func worktreeSession(_ p: Project, _ w: Worktree) -> Session {
        Session(kind: .worktree, projectID: p.id, worktreeID: w.id, folderPath: w.path, title: "Fix pagination", createdAt: t0)
    }

    static func layoutAndTerminal(tabID: UUID) -> (PaneLayout, [Terminal]) {
        let t1 = Terminal(tabID: tabID, provider: .claude, title: "Claude", cwd: "/x",
                          launchSpec: LaunchSpec(provider: .claude, model: "opus", extraArgs: ["--verbose"], initialPrompt: "hello"),
                          resolvedArgv: ResolvedArgv(executable: ["claude"], prompt: ["hello"]), envKeys: ["PATH"],
                          nativeConversationID: "native-1", state: .running, createdAt: t0, startedAt: t0)
        let t2 = Terminal(tabID: tabID, provider: .shell, title: "zsh", cwd: "/x", launchSpec: LaunchSpec(provider: .shell), createdAt: t0)
        let p1 = Pane(content: .terminal(t1.id)), p2 = Pane(content: .terminal(t2.id))
        let layout = PaneLayout.leaf(p1).splitting(paneID: p1.id, axis: .horizontal, ratio: 0.4, inserting: p2) ?? .leaf(p1)
        return (layout, [t1, t2])
    }

    static func profile(project: Project? = nil) -> LaunchProfile {
        LaunchProfile(name: "Claude · Skip permissions", provider: .claude, model: "opus", effort: "high",
                      permissionMode: "bypassPermissions", addDirs: ["/a"], extraArgs: ["--x"], env: ["K": "v"],
                      scope: project == nil ? .global : .project, projectID: project?.id, isDefault: true,
                      createdAt: t0, updatedAt: t0)
    }

    /// Migração de teste que simula uma fatia futura.
    static let v2Test = StoreMigration(id: "v2_test") { db in
        try db.execute(sql: "CREATE TABLE agent_run_test (id TEXT PRIMARY KEY NOT NULL) STRICT")
    }

    static let v2Broken = StoreMigration(id: "v2_broken") { db in
        try db.execute(sql: "CREATE TABLE half_done (id TEXT PRIMARY KEY NOT NULL) STRICT")
        try db.execute(sql: "THIS IS NOT SQL")
    }
}

func tableNames(at url: URL) throws -> [String] {
    var config = Configuration()
    config.readonly = true
    let q = try DatabaseQueue(path: url.path, configuration: config)
    defer { try? q.close() }
    return try q.read { try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name") }
}

func rowCount(at url: URL, table: String) throws -> Int {
    var config = Configuration()
    config.readonly = true
    let q = try DatabaseQueue(path: url.path, configuration: config)
    defer { try? q.close() }
    return try q.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
}


extension RackyStore {
    /// `true` quando o schema já tem `session.subagent_computers` (v7). Testes de migração sobre cadeias antigas gravam a sessão por SQL.
    func hasSubagentColumn() async throws -> Bool {
        try await writer.read { db in try db.columns(in: "session").contains { $0.name == "subagent_computers" } }
    }

    /// Grava uma sessão num banco anterior à v7 (sem a coluna nova): só o que os testes de migração conferem.
    func savePreV7(_ session: Session) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "INSERT INTO session (id, kind, folder_path, managed_folder, title, unread, sort_index, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                arguments: [session.id.uuidString, session.kind.rawValue, session.folderPath, session.managedFolder, session.title, session.unread, session.sortIndex,
                            Int64(session.createdAt.timeIntervalSince1970 * 1000)])
        }
    }
}
