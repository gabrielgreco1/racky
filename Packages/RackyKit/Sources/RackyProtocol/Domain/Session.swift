import Foundation

/// 08 §0.4: `worktree` · `checkout` · `folder` · `clean`.
public enum SessionKind: String, Codable, Sendable, CaseIterable {
    case worktree, checkout, folder, clean
    /// `worktree` e `checkout` exigem `worktreeID`.
    public var requiresWorktree: Bool { self == .worktree || self == .checkout }
}

/// Ciclo de vida da sessão (01 §6.1). `sleeping` é v1.1 e fica fora da Fatia 1.
/// Só `active` e `archived` são persistidos; os demais vivem em memória.
public enum SessionLifecycle: String, Codable, Sendable, CaseIterable {
    case creating, failedToCreate, active, archived, missing, deleted
    public var isPersistable: Bool { self == .active || self == .archived }
}

/// Atributo por sessão "Subagent computers" (F12, 07 §4): se o Claude pai da sessão recebe, por lançamento, o MCP do app, a skill de
/// orquestração e os slots de worker, e com que consentimento ele cria computadores.
public enum SubagentComputersMode: String, Codable, Sendable, CaseIterable {
    /// Nada é injetado: subagentes comuns, sem computador.
    case off
    /// Injeta tudo; `boxes_reserve` espera a decisão do usuário (Allow / Allow for this session / Deny).
    case ask
    /// Injeta tudo; `boxes_reserve` cria direto.
    case full

    public var isOn: Bool { self != .off }
    public var title: String {
        switch self { case .off: "Off"; case .ask: "Ask"; case .full: "Full access" }
    }
}

/// Quem executa os subagentes da sessão (spec subagent-harness): `claude` = subagentes nativos (Agent/Task + `racky-worker-N`); `codex` e
/// `opencode` = cada subagente é uma sessão separada daquele CLI (worker do app, `agent_spawn`); `mixed` = o pai escolhe por tarefa.
public enum SubagentHarness: String, Codable, Sendable, CaseIterable {
    case claude, codex, opencode, mixed

    public var title: String {
        switch self { case .claude: "Claude"; case .codex: "Codex"; case .opencode: "OpenCode"; case .mixed: "Mixed" }
    }
    /// Workers de app (CLI separado) são o padrão da sessão? `claude` e `mixed` usam o nativo quando o pai não pede outro.
    public var usesAppWorkers: Bool { self == .codex || self == .opencode }
    /// O CLI do worker quando `agent_spawn` não diz qual: o da sessão; `mixed` cai em Codex.
    public var defaultWorker: WorkerHarness {
        switch self { case .claude: .claude; case .codex, .mixed: .codex; case .opencode: .opencode }
    }
}

/// CLI de um worker de app (`agent_spawn(harness:)`).
public enum WorkerHarness: String, Codable, Sendable, CaseIterable {
    case claude, codex, opencode
    public var title: String {
        switch self { case .claude: "Claude"; case .codex: "Codex"; case .opencode: "OpenCode" }
    }
}

public struct StatusNote: Codable, Hashable, Sendable {
    public var text: String
    public var author: String
    public var at: Date
    public init(text: String, author: String, at: Date = Date()) {
        self.text = text; self.author = author; self.at = at
    }
}

/// Unidade de trabalho da sidebar: diretório + terminais (01 §5.3).
public struct Session: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var kind: SessionKind
    public var projectID: UUID?
    public var worktreeID: UUID?
    public var folderPath: String
    public var managedFolder: Bool
    public var title: String
    public var statusNote: StatusNote?
    public var unread: Bool
    public var lastViewedAt: Date?
    public var lifecycle: SessionLifecycle
    public var sortIndex: Int
    public var createdAt: Date
    public var lastActiveAt: Date?
    public var archivedAt: Date?
    /// "Subagent computers" (F12). Padrão `off`; novas sessões herdam o padrão de Settings › Computers.
    public var subagentComputers: SubagentComputersMode
    /// Quem roda os subagentes (spec subagent-harness). Padrão `claude`; novas sessões herdam Settings › Computers.
    public var subagentHarness: SubagentHarness

    public init(
        id: UUID = .v7(), kind: SessionKind, projectID: UUID? = nil, worktreeID: UUID? = nil,
        folderPath: String, managedFolder: Bool = false, title: String, statusNote: StatusNote? = nil,
        unread: Bool = false, lastViewedAt: Date? = nil, lifecycle: SessionLifecycle = .active,
        sortIndex: Int = 0, createdAt: Date = Date(), lastActiveAt: Date? = nil, archivedAt: Date? = nil,
        subagentComputers: SubagentComputersMode = .off, subagentHarness: SubagentHarness = .claude
    ) {
        self.subagentComputers = subagentComputers
        self.subagentHarness = subagentHarness
        self.id = id; self.kind = kind; self.projectID = projectID; self.worktreeID = worktreeID
        self.folderPath = folderPath; self.managedFolder = managedFolder; self.title = title
        self.statusNote = statusNote; self.unread = unread; self.lastViewedAt = lastViewedAt
        self.lifecycle = lifecycle; self.sortIndex = sortIndex; self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt; self.archivedAt = archivedAt
    }

    /// Mesma regra do CHECK do schema (R1 K-81); validada antes de gravar.
    public var isStructurallyValid: Bool {
        (kind.requiresWorktree == (worktreeID != nil)) && ((kind == .clean) == (projectID == nil))
    }
}
