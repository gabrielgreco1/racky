import RackyProtocol
import Foundation
import GRDB

// Records de persistência (colunas do schema `v1_initial`). Ficam internos: a API pública só expõe tipos de domínio.

enum RowCodec {
    static func ms(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }
    static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
    static func ms(_ d: Date?) -> Int64? { d.map { ms($0) } }
    static func date(_ ms: Int64?) -> Date? { ms.map { date($0) } }

    static func id(_ s: String, table: String) throws -> UUID {
        guard let u = UUID(uuidString: s) else { throw StoreError.invalidRow(table: table, detail: "bad uuid \(s)") }
        return u
    }
    static func id(_ s: String?, table: String) throws -> UUID? { try s.map { try id($0, table: table) } }

    static func enumValue<E: RawRepresentable>(_ raw: String, _ type: E.Type, table: String) throws -> E where E.RawValue == String {
        guard let v = E(rawValue: raw) else { throw StoreError.invalidRow(table: table, detail: "bad \(E.self) \(raw)") }
        return v
    }

    static func json<T: Encodable>(_ v: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(v), as: UTF8.self)
    }
    static func decode<T: Decodable>(_ type: T.Type, _ s: String, table: String) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: Data(s.utf8)) }
        catch { throw StoreError.invalidRow(table: table, detail: "bad json: \(error)") }
    }
}

struct ProjectRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "project"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var id: String
    var name: String
    var kind: String
    var rootPath: String
    var gitRemoteUrl: String?
    var defaultBranch: String?
    var worktreeRoot: String?
    var branchPrefix: String?
    var defaultProfileId: String?
    var color: String?
    var source: String
    var importSourceId: String?
    var sortIndex: Int
    var createdAt: Int64
    var archivedAt: Int64?

    init(_ p: Project) {
        id = p.id.uuidString; name = p.name; kind = p.kind.rawValue; rootPath = p.rootPath
        gitRemoteUrl = p.gitRemoteURL; defaultBranch = p.defaultBranch; worktreeRoot = p.worktreeRoot
        branchPrefix = p.branchPrefix; defaultProfileId = p.defaultProfileID?.uuidString; color = p.color
        source = p.source.rawValue; importSourceId = p.importSourceID; sortIndex = p.sortIndex
        createdAt = RowCodec.ms(p.createdAt); archivedAt = RowCodec.ms(p.archivedAt)
    }

    func domain() throws -> Project {
        Project(
            id: try RowCodec.id(id, table: "project"), name: name,
            kind: try RowCodec.enumValue(kind, ProjectKind.self, table: "project"), rootPath: rootPath,
            gitRemoteURL: gitRemoteUrl, defaultBranch: defaultBranch, worktreeRoot: worktreeRoot,
            branchPrefix: branchPrefix, defaultProfileID: try RowCodec.id(defaultProfileId, table: "project"),
            color: color, source: try RowCodec.enumValue(source, RecordSource.self, table: "project"),
            importSourceID: importSourceId, sortIndex: sortIndex,
            createdAt: RowCodec.date(createdAt), archivedAt: RowCodec.date(archivedAt))
    }
}

struct WorktreeRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "worktree"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var id: String
    var projectId: String
    var path: String
    var branch: String
    var baseRef: String?
    var isMain: Bool
    var createdByApp: Bool
    var source: String
    var createdAt: Int64
    var lastSeenAt: Int64?
    var archivedAt: Int64?

    init(_ w: Worktree) {
        id = w.id.uuidString; projectId = w.projectID.uuidString; path = w.path; branch = w.branch
        baseRef = w.baseRef; isMain = w.isMain; createdByApp = w.createdByApp; source = w.source.rawValue
        createdAt = RowCodec.ms(w.createdAt); lastSeenAt = RowCodec.ms(w.lastSeenAt); archivedAt = RowCodec.ms(w.archivedAt)
    }

    func domain() throws -> Worktree {
        Worktree(
            id: try RowCodec.id(id, table: "worktree"), projectID: try RowCodec.id(projectId, table: "worktree"),
            path: path, branch: branch, baseRef: baseRef, isMain: isMain, createdByApp: createdByApp,
            source: try RowCodec.enumValue(source, RecordSource.self, table: "worktree"),
            createdAt: RowCodec.date(createdAt), lastSeenAt: RowCodec.date(lastSeenAt), archivedAt: RowCodec.date(archivedAt))
    }
}

struct SessionRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "session"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var id: String
    var kind: String
    var projectId: String?
    var worktreeId: String?
    var folderPath: String
    var managedFolder: Bool
    var title: String
    var statusNote: String?
    var statusNoteAuthor: String?
    var statusNoteAt: Int64?
    var unread: Bool
    var lastViewedAt: Int64?
    var lifecycle: String
    var sortIndex: Int
    var createdAt: Int64
    var lastActiveAt: Int64?
    var archivedAt: Int64?
    var subagentComputers: String
    var subagentHarness: String

    init(_ s: Session) {
        subagentComputers = s.subagentComputers.rawValue
        subagentHarness = s.subagentHarness.rawValue
        id = s.id.uuidString; kind = s.kind.rawValue; projectId = s.projectID?.uuidString
        worktreeId = s.worktreeID?.uuidString; folderPath = s.folderPath; managedFolder = s.managedFolder
        title = s.title; statusNote = s.statusNote?.text; statusNoteAuthor = s.statusNote?.author
        statusNoteAt = RowCodec.ms(s.statusNote?.at); unread = s.unread; lastViewedAt = RowCodec.ms(s.lastViewedAt)
        lifecycle = s.lifecycle.rawValue; sortIndex = s.sortIndex; createdAt = RowCodec.ms(s.createdAt)
        lastActiveAt = RowCodec.ms(s.lastActiveAt); archivedAt = RowCodec.ms(s.archivedAt)
    }

    func domain() throws -> Session {
        var note: StatusNote?
        if let text = statusNote { note = StatusNote(text: text, author: statusNoteAuthor ?? "user", at: RowCodec.date(statusNoteAt) ?? Date(timeIntervalSince1970: 0)) }
        return Session(
            id: try RowCodec.id(id, table: "session"), kind: try RowCodec.enumValue(kind, SessionKind.self, table: "session"),
            projectID: try RowCodec.id(projectId, table: "session"), worktreeID: try RowCodec.id(worktreeId, table: "session"),
            folderPath: folderPath, managedFolder: managedFolder, title: title, statusNote: note, unread: unread,
            lastViewedAt: RowCodec.date(lastViewedAt),
            lifecycle: try RowCodec.enumValue(lifecycle, SessionLifecycle.self, table: "session"),
            sortIndex: sortIndex, createdAt: RowCodec.date(createdAt), lastActiveAt: RowCodec.date(lastActiveAt),
            archivedAt: RowCodec.date(archivedAt),
            subagentComputers: SubagentComputersMode(rawValue: subagentComputers) ?? .off,
            subagentHarness: SubagentHarness(rawValue: subagentHarness) ?? .claude)
    }
}

struct TabRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "tab"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var id: String
    var sessionId: String
    var title: String
    var titleLocked: Bool
    var sortIndex: Int
    var layoutJson: String
    var focusedTerminalId: String?
    var createdAt: Int64
    var closedAt: Int64?

    init(_ t: Tab) throws {
        id = t.id.uuidString; sessionId = t.sessionID.uuidString; title = t.title; titleLocked = t.titleLocked
        sortIndex = t.sortIndex; layoutJson = try RowCodec.json(t.layout); focusedTerminalId = t.focusedTerminalID?.uuidString
        createdAt = RowCodec.ms(t.createdAt); closedAt = RowCodec.ms(t.closedAt)
    }

    func domain() throws -> Tab {
        Tab(
            id: try RowCodec.id(id, table: "tab"), sessionID: try RowCodec.id(sessionId, table: "tab"), title: title,
            titleLocked: titleLocked, sortIndex: sortIndex, layout: try RowCodec.decode(PaneLayout.self, layoutJson, table: "tab"),
            focusedTerminalID: try RowCodec.id(focusedTerminalId, table: "tab"),
            createdAt: RowCodec.date(createdAt), closedAt: RowCodec.date(closedAt))
    }
}

struct TerminalRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "terminal"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var id: String
    var tabId: String
    var provider: String
    var profileId: String?
    var title: String
    var titleSource: String
    var cwd: String
    var addDirsJson: String
    var launchSpecJson: String
    var resolvedArgvJson: String?
    var envKeysJson: String
    var coldLog: Bool
    var ptySessionId: String?
    var daemonMajor: Int?
    var currentRunId: String?
    var nativeConversationId: String?
    var state: String
    var exitCode: Int?
    var exitSignal: Int?
    var lastMessage: String?
    var fontSize: Double?
    var createdAt: Int64
    var startedAt: Int64?
    var endedAt: Int64?
    var deletedAt: Int64?

    init(_ t: Terminal) throws {
        id = t.id.uuidString; tabId = t.tabID.uuidString; provider = t.provider.rawValue
        profileId = t.profileID?.uuidString; title = t.title; titleSource = t.titleSource.rawValue; cwd = t.cwd
        addDirsJson = try RowCodec.json(t.addDirs); launchSpecJson = try RowCodec.json(t.launchSpec)
        resolvedArgvJson = try t.resolvedArgv.map { try RowCodec.json($0) }
        envKeysJson = try RowCodec.json(t.envKeys); coldLog = t.coldLog; ptySessionId = t.ptySessionID
        daemonMajor = t.daemonMajor; currentRunId = t.currentRunID?.uuidString
        nativeConversationId = t.nativeConversationID; state = t.state.rawValue; exitCode = t.exitCode
        exitSignal = t.exitSignal; lastMessage = t.lastMessage.map { String($0.prefix(500)) }; fontSize = t.fontSize
        createdAt = RowCodec.ms(t.createdAt); startedAt = RowCodec.ms(t.startedAt); endedAt = RowCodec.ms(t.endedAt)
        deletedAt = RowCodec.ms(t.deletedAt)
    }

    func domain() throws -> Terminal {
        let spec = try RowCodec.decode(LaunchSpec.self, launchSpecJson, table: "terminal")
        return Terminal(
            id: try RowCodec.id(id, table: "terminal"), tabID: try RowCodec.id(tabId, table: "terminal"),
            provider: try RowCodec.enumValue(provider, TerminalProvider.self, table: "terminal"),
            profileID: try RowCodec.id(profileId, table: "terminal"), title: title,
            titleSource: try RowCodec.enumValue(titleSource, TitleSource.self, table: "terminal"), cwd: cwd,
            addDirs: try RowCodec.decode([String].self, addDirsJson, table: "terminal"), launchSpec: spec,
            resolvedArgv: try resolvedArgvJson.map { try RowCodec.decode(ResolvedArgv.self, $0, table: "terminal") },
            envKeys: try RowCodec.decode([String].self, envKeysJson, table: "terminal"), coldLog: coldLog,
            ptySessionID: ptySessionId, daemonMajor: daemonMajor, currentRunID: try RowCodec.id(currentRunId, table: "terminal"),
            nativeConversationID: nativeConversationId,
            state: try RowCodec.enumValue(state, TerminalProcessState.self, table: "terminal"),
            exitCode: exitCode, exitSignal: exitSignal, lastMessage: lastMessage, fontSize: fontSize,
            createdAt: RowCodec.date(createdAt), startedAt: RowCodec.date(startedAt), endedAt: RowCodec.date(endedAt),
            deletedAt: RowCodec.date(deletedAt))
    }
}

struct LaunchProfileRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "launch_profile"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var id: String
    var name: String
    var provider: String
    var model: String?
    var effort: String?
    var permissionMode: String?
    var addDirsJson: String
    var extraArgsJson: String
    var envJson: String
    var scope: String
    var projectId: String?
    var isDefault: Bool
    var source: String
    var createdAt: Int64
    var updatedAt: Int64

    init(_ p: LaunchProfile) throws {
        id = p.id.uuidString; name = p.name; provider = p.provider.rawValue; model = p.model; effort = p.effort
        permissionMode = p.permissionMode; addDirsJson = try RowCodec.json(p.addDirs)
        extraArgsJson = try RowCodec.json(p.extraArgs); envJson = try RowCodec.json(p.env); scope = p.scope.rawValue
        projectId = p.projectID?.uuidString; isDefault = p.isDefault; source = p.source.rawValue
        createdAt = RowCodec.ms(p.createdAt); updatedAt = RowCodec.ms(p.updatedAt)
    }

    func domain() throws -> LaunchProfile {
        LaunchProfile(
            id: try RowCodec.id(id, table: "launch_profile"), name: name,
            provider: try RowCodec.enumValue(provider, TerminalProvider.self, table: "launch_profile"),
            model: model, effort: effort, permissionMode: permissionMode,
            addDirs: try RowCodec.decode([String].self, addDirsJson, table: "launch_profile"),
            extraArgs: try RowCodec.decode([String].self, extraArgsJson, table: "launch_profile"),
            env: try RowCodec.decode([String: String].self, envJson, table: "launch_profile"),
            scope: try RowCodec.enumValue(scope, LaunchProfileScope.self, table: "launch_profile"),
            projectID: try RowCodec.id(projectId, table: "launch_profile"), isDefault: isDefault,
            source: try RowCodec.enumValue(source, RecordSource.self, table: "launch_profile"),
            createdAt: RowCodec.date(createdAt), updatedAt: RowCodec.date(updatedAt))
    }
}
