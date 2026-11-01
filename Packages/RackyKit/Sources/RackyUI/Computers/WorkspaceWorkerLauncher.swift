import RackyCore
import RackyProtocol
import Foundation

/// `WorkerLauncher` do app (spec subagent-harness): `agent_spawn` pede, e o `WorkspaceModel` abre o terminal do worker como um pane
/// dividido ao lado do pai (ou numa tab nova da mesma sessão), na sessão do pai, sem depender da tab ativa. Os sinais de `agent_stop`
/// vão ao processo do terminal. O fim do terminal volta ao orquestrador por `WorkspaceModel.onWorkerTerminalEnded`.
struct WorkspaceWorkerLauncher: WorkerLauncher {
    enum Failure: Error, LocalizedError {
        case parentNotOpen
        var errorDescription: String? { "the parent session isn't open in the app, so the worker terminal can't be placed" }
    }

    /// Abre o terminal; roda na main actor. Devolve o id do terminal.
    let open: @MainActor @Sendable (WorkerLaunchRequest) async throws -> UUID
    let send: @MainActor @Sendable (UUID, WorkerSignal) async -> Void

    func start(_ request: WorkerLaunchRequest) async throws -> UUID { try await open(request) }
    func signal(terminal: UUID, _ signal: WorkerSignal) async { await send(terminal, signal) }

    /// O launcher ligado ao workspace e às settings (perfil padrão de cada CLI). `provider` do worker: o mesmo nome do harness.
    @MainActor
    static func make(workspace: WorkspaceModel, settings: SettingsModel, computers: ComputersModel? = nil) -> WorkspaceWorkerLauncher {
        WorkspaceWorkerLauncher(
            open: { [weak workspace, weak computers] request in
                guard let workspace else { throw Failure.parentNotOpen }
                let parentTerminal = UUID(uuidString: request.parentID).flatMap { workspace.terminalOfRun($0) }
                guard let sid = request.sessionID ?? parentTerminal.flatMap({ workspace.sessionID(of: $0) }) else { throw Failure.parentNotOpen }
                let provider = TerminalProvider(workerHarness: request.harness)
                let spec = LaunchSpec(
                    provider: provider, profileID: settings.defaultProfile(for: provider)?.id, model: request.model, initialPrompt: request.prompt)
                guard let id = workspace.openWorkerTerminal(
                    session: sid, nextTo: parentTerminal?.id, worker: WorkerLaunch(request), spec: spec, title: request.terminalTitle)
                else { throw Failure.parentNotOpen }
                // A sidebar e as abas da sessão chamam o computador pelo agente que o usa ("Codex 1").
                computers?.workerComputers[id] = request.computerName
                computers?.computerAgentNames[request.computerName] = request.agentName
                return id
            },
            send: { [weak workspace] id, signal in await workspace?.signalWorker(terminal: id, signal) })
    }
}

extension TerminalProvider {
    /// O CLI de um worker de app.
    init(workerHarness: WorkerHarness) {
        switch workerHarness {
        case .claude: self = .claude
        case .codex: self = .codex
        case .opencode: self = .opencode
        }
    }
}
