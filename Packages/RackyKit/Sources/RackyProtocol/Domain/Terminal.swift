import Foundation

/// `custom` = "Custom Command": argv livre em `LaunchSpec.customArgv`, sem estado de agente (06 §2).
public enum TerminalProvider: String, Codable, Sendable, CaseIterable {
    case claude, codex, opencode, shell, custom
    public var isAgent: Bool { self == .claude || self == .codex || self == .opencode }
    /// "Subagent computers" (computador por subagente) vale para os três agentes; cada um recebe a injeção do seu CLI.
    public var supportsSubagentComputers: Bool { isAgent }
}

/// Estado do processo do terminal (01 §6.2; nomes de 08 §0.4). `daemonUnavailable` é só estado de UI.
public enum TerminalProcessState: String, Codable, Sendable, CaseIterable {
    case notStarted = "not_started"
    case launching
    case running
    case exited
    case killed
    case failedToStart = "failed_to_start"
    case interrupted
    case containerStopped = "container_stopped"
}

public enum TitleSource: String, Codable, Sendable { case user, osc, auto }

/// Lançamento declarativo (01 §5.7), salvo antes do processo nascer. Fatia 1 sem injeções de app.
public struct LaunchSpec: Codable, Hashable, Sendable {
    public var provider: TerminalProvider
    public var profileID: UUID?
    public var model: String?
    public var permissionMode: String?
    public var effort: String?
    public var extraArgs: [String]
    public var envOverrides: [String: String]
    public var customArgv: [String]?
    public var initialPrompt: String?
    public var initialPromptFile: String?
    public var nativeSessionID: String?
    public var resumeOf: String?
    /// Terminal de um worker de app (spec subagent-harness): a identidade MCP do filho. Nunca é pai de orquestração, nem depois de reabrir o app.
    public var workerChildID: String?
    /// Terminal do agente que pediu o worker: a sidebar pendura o worker embaixo dele, como subagente.
    public var workerParentTerminalID: UUID?

    public init(
        provider: TerminalProvider, profileID: UUID? = nil, model: String? = nil, permissionMode: String? = nil,
        effort: String? = nil, extraArgs: [String] = [], envOverrides: [String: String] = [:],
        customArgv: [String]? = nil, initialPrompt: String? = nil, initialPromptFile: String? = nil,
        nativeSessionID: String? = nil, resumeOf: String? = nil, workerChildID: String? = nil
    ) {
        self.workerChildID = workerChildID
        self.provider = provider; self.profileID = profileID; self.model = model
        self.permissionMode = permissionMode; self.effort = effort; self.extraArgs = extraArgs
        self.envOverrides = envOverrides; self.customArgv = customArgv; self.initialPrompt = initialPrompt
        self.initialPromptFile = initialPromptFile; self.nativeSessionID = nativeSessionID; self.resumeOf = resumeOf
    }
}

/// Como o processo foi lançado de fato, em segmentos (06 §2.4.1). Nunca contém valores de segredo.
public struct ResolvedArgv: Codable, Hashable, Sendable {
    public var executable: [String]
    public var identity: [String]
    public var profile: [String]
    public var injected: [String]
    public var prompt: [String]
    public init(executable: [String] = [], identity: [String] = [], profile: [String] = [],
                injected: [String] = [], prompt: [String] = []) {
        self.executable = executable; self.identity = identity; self.profile = profile
        self.injected = injected; self.prompt = prompt
    }
    public var flattened: [String] { executable + identity + profile + injected + prompt }
}

public struct Terminal: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var tabID: UUID
    public var provider: TerminalProvider
    public var profileID: UUID?
    public var title: String
    public var titleSource: TitleSource
    public var cwd: String
    public var addDirs: [String]
    public var launchSpec: LaunchSpec
    public var resolvedArgv: ResolvedArgv?
    public var envKeys: [String]
    public var coldLog: Bool
    public var ptySessionID: String?
    public var daemonMajor: Int?
    public var currentRunID: UUID?
    public var nativeConversationID: String?
    public var state: TerminalProcessState
    public var exitCode: Int?
    public var exitSignal: Int?
    public var lastMessage: String?
    public var fontSize: Double?
    public var createdAt: Date
    public var startedAt: Date?
    public var endedAt: Date?
    public var deletedAt: Date?

    public init(
        id: UUID = .v7(), tabID: UUID, provider: TerminalProvider, profileID: UUID? = nil, title: String,
        titleSource: TitleSource = .auto, cwd: String, addDirs: [String] = [], launchSpec: LaunchSpec,
        resolvedArgv: ResolvedArgv? = nil, envKeys: [String] = [], coldLog: Bool = true,
        ptySessionID: String? = nil, daemonMajor: Int? = nil, currentRunID: UUID? = nil,
        nativeConversationID: String? = nil, state: TerminalProcessState = .notStarted,
        exitCode: Int? = nil, exitSignal: Int? = nil, lastMessage: String? = nil, fontSize: Double? = nil,
        createdAt: Date = Date(), startedAt: Date? = nil, endedAt: Date? = nil, deletedAt: Date? = nil
    ) {
        self.id = id; self.tabID = tabID; self.provider = provider; self.profileID = profileID
        self.title = title; self.titleSource = titleSource; self.cwd = cwd; self.addDirs = addDirs
        self.launchSpec = launchSpec; self.resolvedArgv = resolvedArgv; self.envKeys = envKeys
        self.coldLog = coldLog; self.ptySessionID = ptySessionID; self.daemonMajor = daemonMajor
        self.currentRunID = currentRunID; self.nativeConversationID = nativeConversationID
        self.state = state; self.exitCode = exitCode; self.exitSignal = exitSignal
        self.lastMessage = lastMessage; self.fontSize = fontSize; self.createdAt = createdAt
        self.startedAt = startedAt; self.endedAt = endedAt; self.deletedAt = deletedAt
    }
}

public enum LaunchProfileScope: String, Codable, Sendable { case global, project }

/// Perfil de lançamento (01 §5.8). `env` nunca contém segredo.
public struct LaunchProfile: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var provider: TerminalProvider
    public var model: String?
    public var effort: String?
    public var permissionMode: String?
    public var addDirs: [String]
    public var extraArgs: [String]
    public var env: [String: String]
    public var scope: LaunchProfileScope
    public var projectID: UUID?
    public var isDefault: Bool
    public var source: RecordSource
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = .v7(), name: String, provider: TerminalProvider, model: String? = nil, effort: String? = nil,
        permissionMode: String? = nil, addDirs: [String] = [], extraArgs: [String] = [], env: [String: String] = [:],
        scope: LaunchProfileScope = .global, projectID: UUID? = nil, isDefault: Bool = false,
        source: RecordSource = .manual, createdAt: Date = Date(), updatedAt: Date = Date()
    ) {
        self.id = id; self.name = name; self.provider = provider; self.model = model; self.effort = effort
        self.permissionMode = permissionMode; self.addDirs = addDirs; self.extraArgs = extraArgs; self.env = env
        self.scope = scope; self.projectID = projectID; self.isDefault = isDefault; self.source = source
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

/// Atividade do agente (01 §6.3; 08 §0.4). Na Fatia 1 (sem hooks) vale sempre `unknown`. `stalled` é v1.1.
public enum NeedsInputKind: String, Codable, Sendable { case question, permission, other }

public enum AgentActivity: Hashable, Codable, Sendable {
    case starting, idle, working
    case needsInput(NeedsInputKind)
    case waitingOnSubagents
    case done, failed, blocked, interrupted, unknown
}

public enum AgentRunKind: String, Codable, Sendable {
    case main
    case nativeSubagent = "native_subagent"
    case teammate
    case appWorkerLight = "app_worker_light"
    case appWorkerIsolated = "app_worker_isolated"
}

/// Execução de agente (01 §5.9; tabela `agent_run`, migração `v2_activity`).
/// `activity` e `statusKind` (em `AgentActivity.needsInput`) mapeiam para `status`/`status_kind` (08 §0.4).
public struct AgentRun: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var terminalID: UUID?
    public var parentRunID: UUID?
    public var rootRunID: UUID
    public var kind: AgentRunKind
    public var harness: TerminalProvider
    public var agentType: String?
    public var providerSessionID: String?
    public var providerAgentID: String?
    public var activity: AgentActivity
    public var estimated: Bool
    public var statusReason: String?
    /// Última nota ou ferramenta em uso ("Running Bash").
    public var subtitle: String?
    public var startedAt: Date
    public var lastEventAt: Date?
    public var endedAt: Date?

    public init(id: UUID = .v7(), terminalID: UUID? = nil, parentRunID: UUID? = nil, rootRunID: UUID? = nil,
                kind: AgentRunKind = .main, harness: TerminalProvider, agentType: String? = nil,
                providerSessionID: String? = nil, providerAgentID: String? = nil, activity: AgentActivity = .unknown,
                estimated: Bool = false, statusReason: String? = nil, subtitle: String? = nil,
                startedAt: Date = Date(), lastEventAt: Date? = nil, endedAt: Date? = nil) {
        self.id = id; self.terminalID = terminalID; self.parentRunID = parentRunID; self.rootRunID = rootRunID ?? id
        self.kind = kind; self.harness = harness; self.agentType = agentType; self.providerSessionID = providerSessionID
        self.providerAgentID = providerAgentID; self.activity = activity; self.estimated = estimated
        self.statusReason = statusReason; self.subtitle = subtitle; self.startedAt = startedAt
        self.lastEventAt = lastEventAt; self.endedAt = endedAt
    }
}
