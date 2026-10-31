import RackyDocker
import RackyProtocol
import RackyStore
import Foundation

// Spec subagent-harness: workers de app. O pai chama `agent_spawn`; o scheduler reserva o computador, aloca uma identidade de filho
// própria (id `<8 do pai>-a<n>`, capability nova) e pede ao app, por `WorkerLauncher`, que abra o CLI do worker num terminal ao lado
// do pai. `agent_wait`/`agent_status`/`agent_stop` acompanham o ciclo de vida. O launcher real mora no RackyUI; os testes usam um falso.

/// Pedido de lançamento de um worker (o que o app precisa para abrir o terminal).
public struct WorkerLaunchRequest: Sendable, Equatable {
    /// Identidade MCP do pai (id da execução do terminal pai, em minúsculas).
    public var parentID: String
    public var sessionID: UUID?
    public var harness: WorkerHarness
    /// Identidade MCP do worker (`racky mcp --child <childID> --capability <capability>`).
    public var childID: String
    public var capability: String
    public var computerName: String
    public var title: String
    /// Prompt inicial completo (`OrchestrationText.workerPrompt`).
    public var prompt: String
    public var model: String?
    /// `Racky helper` do app (caminho absoluto do `racky`), que o launcher repassa à injeção.
    public var helperPath: String
    /// Número do worker entre os do mesmo CLI deste pai (1, 2, …): o nome que a UI mostra é "Codex 1", "Codex 2".
    public var ordinal: Int = 1
    /// Nome curto do worker na UI.
    public var agentName: String { "\(harness.title) \(ordinal)" }
    /// Terminal "Codex 1 · tarefa": o nome do agente e, depois do ponto, a tarefa (a sidebar mostra os dois separados).
    public var terminalTitle: String { "\(agentName) · \(title)" }

    public init(
        parentID: String, sessionID: UUID?, harness: WorkerHarness, childID: String, capability: String, computerName: String, title: String,
        prompt: String, model: String? = nil, helperPath: String
    ) {
        self.parentID = parentID; self.sessionID = sessionID; self.harness = harness; self.childID = childID; self.capability = capability
        self.computerName = computerName; self.title = title; self.prompt = prompt; self.model = model; self.helperPath = helperPath
    }
}

/// Sinais da parada de um worker: SIGINT, depois SIGTERM (SIGHUP+SIGTERM no grupo), depois SIGKILL, com 5 s de intervalo.
public enum WorkerSignal: String, Sendable, Equatable { case interrupt, terminate, kill }

/// O app implementa isto (RackyUI): abre o terminal do worker e manda sinais a ele. Não conhece reserva nem MCP.
public protocol WorkerLauncher: Sendable {
    /// Abre o terminal do worker e lança o CLI. Devolve o id do terminal (já criado) assim que o processo foi pedido.
    func start(_ request: WorkerLaunchRequest) async throws -> UUID
    func signal(terminal: UUID, _ signal: WorkerSignal) async
}

/// Pedido de `agent_spawn` já validado.
public struct AgentSpawnRequest: Sendable, Equatable {
    public var harness: WorkerHarness?
    public var brief: String
    public var title: String?
    public var name: String?
    public var display: ComputerDisplay
    public var model: String?
    public init(harness: WorkerHarness? = nil, brief: String, title: String? = nil, name: String? = nil, display: ComputerDisplay = .headless, model: String? = nil) {
        self.harness = harness; self.brief = brief; self.title = title; self.name = name; self.display = display; self.model = model
    }
}

/// Um worker de app visto pela UI (sidebar, abas da sessão).
public struct AppWorkerSummary: Sendable, Equatable {
    public var terminalID: UUID
    public var computer: String?
    public var agentName: String
    public var state: AppWorkerState
    public init(terminalID: UUID, computer: String?, agentName: String, state: AppWorkerState) {
        self.terminalID = terminalID; self.computer = computer; self.agentName = agentName; self.state = state
    }
}

public enum AppWorkerState: String, Sendable, Equatable { case starting, running, done, failed, stopped
    public var isFinal: Bool { self == .done || self == .failed || self == .stopped }
    /// `starting` e `running` saem como `running` para o pai (o spawn já respondeu `starting`).
    public var parentFacing: String { self == .starting ? "running" : rawValue }
}

extension OrchestrationInjectionBuilder {
    /// Identidade de um worker de app: `<8 primeiros do pai>-a<n>` (os slots nativos são `-w<n>`).
    public static func appWorkerID(parent: String, index: Int) -> String { "\(parent.prefix(8))-a\(index)" }
    public static func isAppWorker(_ childID: String) -> Bool {
        guard let range = childID.range(of: "-a", options: .backwards) else { return false }
        let tail = childID[range.upperBound...]
        return !tail.isEmpty && tail.allSatisfy(\.isNumber)
    }
    /// Os slots de worker de app começam bem acima dos nativos (`UNIQUE(parent_id, slot)`).
    public static let appWorkerSlotBase = 1000
}

/// O que o lançamento do terminal de um worker de app precisa: pula a orquestração de pai e injeta só o MCP do próprio filho.
public struct WorkerLaunch: Sendable, Equatable {
    public var parentID: String
    public var childID: String
    public var capability: String
    public var harness: WorkerHarness
    public var helperPath: String
    public init(parentID: String, childID: String, capability: String, harness: WorkerHarness, helperPath: String) {
        self.parentID = parentID; self.childID = childID; self.capability = capability; self.harness = harness; self.helperPath = helperPath
    }

    public init(_ request: WorkerLaunchRequest) {
        self.init(parentID: request.parentID, childID: request.childID, capability: request.capability, harness: request.harness, helperPath: request.helperPath)
    }

    var identity: WorkerIdentity { WorkerIdentity(child: childID, capability: capability) }

    /// A injeção do worker sobre `base` (hooks de atividade, quando houver): Codex `-c mcp_servers.racky_worker`, OpenCode
    /// `OPENCODE_CONFIG_CONTENT` só com `abx-<filho>` e Claude `--mcp-config` só com `abx-<filho>` mais `permissions.allow` das ferramentas dele.
    public func applied(to base: LaunchInjection?) -> LaunchInjection {
        var out = base ?? LaunchInjection(helperPath: helperPath, codexActivityHooks: false)
        switch harness {
        case .codex:
            out.codexOrchestration = nil
            out.codexWorker = identity
        case .opencode:
            out.openCodeOrchestration = nil
            out.openCodeWorker = identity
        case .claude:
            let server = OrchestrationInjectionBuilder.serverName(forChild: childID)
            let mcp: [String: Any] = ["mcpServers": [server: ["command": out.helperPath, "args": ["mcp", "--child", childID, "--capability", capability]]]]
            out.claudeMCPConfig = try? JSONSerialization.data(withJSONObject: mcp, options: [.sortedKeys, .withoutEscapingSlashes])
            out.claudePluginFiles = []
            out.claudeAgentsJSON = nil
            out.claudeSpawnGuard = nil
            out.claudeAllowRules = ["mcp__\(server)__*"]
            out.claudeDenyRules = [OrchestrationText.denyGlobalSkill]
        }
        return out
    }
}
