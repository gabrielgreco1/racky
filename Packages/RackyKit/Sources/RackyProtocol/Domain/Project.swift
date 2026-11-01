import Foundation

public enum ProjectKind: String, Codable, Sendable, CaseIterable { case git, folder }
public enum RecordSource: String, Codable, Sendable, CaseIterable { case manual }

/// Repositório Git ou pasta raiz que agrupa sessões (01 §5.2). Remover nunca apaga arquivos.
public struct Project: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: ProjectKind
    public var rootPath: String
    public var gitRemoteURL: String?
    public var defaultBranch: String?
    public var worktreeRoot: String?
    public var branchPrefix: String?
    public var defaultProfileID: UUID?
    public var color: String?
    public var source: RecordSource
    public var importSourceID: String?
    public var sortIndex: Int
    public var createdAt: Date
    public var archivedAt: Date?

    public init(
        id: UUID = .v7(), name: String, kind: ProjectKind = .git, rootPath: String,
        gitRemoteURL: String? = nil, defaultBranch: String? = nil, worktreeRoot: String? = nil,
        branchPrefix: String? = nil, defaultProfileID: UUID? = nil, color: String? = nil,
        source: RecordSource = .manual, importSourceID: String? = nil, sortIndex: Int = 0,
        createdAt: Date = Date(), archivedAt: Date? = nil
    ) {
        self.id = id; self.name = name; self.kind = kind; self.rootPath = rootPath
        self.gitRemoteURL = gitRemoteURL; self.defaultBranch = defaultBranch
        self.worktreeRoot = worktreeRoot; self.branchPrefix = branchPrefix
        self.defaultProfileID = defaultProfileID; self.color = color; self.source = source
        self.importSourceID = importSourceID; self.sortIndex = sortIndex
        self.createdAt = createdAt; self.archivedAt = archivedAt
    }
}

/// Worktree de um projeto (01 §5.4). Campos derivados (git, pr) não são persistidos.
public struct Worktree: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var projectID: UUID
    public var path: String
    public var branch: String
    public var baseRef: String?
    public var isMain: Bool
    public var createdByApp: Bool
    public var source: RecordSource
    public var createdAt: Date
    public var lastSeenAt: Date?
    public var archivedAt: Date?

    public init(
        id: UUID = .v7(), projectID: UUID, path: String, branch: String, baseRef: String? = nil,
        isMain: Bool = false, createdByApp: Bool = false, source: RecordSource = .manual,
        createdAt: Date = Date(), lastSeenAt: Date? = nil, archivedAt: Date? = nil
    ) {
        self.id = id; self.projectID = projectID; self.path = path; self.branch = branch
        self.baseRef = baseRef; self.isMain = isMain; self.createdByApp = createdByApp
        self.source = source; self.createdAt = createdAt; self.lastSeenAt = lastSeenAt
        self.archivedAt = archivedAt
    }
}
