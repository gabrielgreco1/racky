import RackyProtocol

/// Registro de ações sem ciclo Core -> UI (08 AR-134). O servidor `ctl` (Core) fala só com este protocolo;
/// o `ActionRegistry` (RackyUI, `@MainActor`) o implementa e é injetado pelo `AppEnvironment` no boot.
public protocol ActionDispatching: Sendable {
    /// Executa uma ação do registro. Lança `ActionError` (não registrada, fatia futura, desabilitada com motivo).
    func perform(_ id: ActionID, _ arg: ActionArgument?) async throws -> ActionResult

    /// Ação ligada a um controle (`ctl ui action <a11yID>`), se o controle estiver na tela e tiver ação.
    func actionID(forControl id: A11yID) async -> ActionID?

    /// Argumento que o controle manda ao ser clicado (o mesmo de um clique de verdade).
    func boundArgument(forControl id: A11yID) async -> ActionArgument?

    /// Árvore de controles montados; com `root`, só a subárvore (vazia se o ID não existe).
    func uiTree(root: A11yID?) async -> UITreeSnapshot

    func screenshot(_ target: ScreenshotTarget) async throws -> ScreenshotResult

    func record(_ command: RecordingCommand) async throws -> RecordingResult

    /// Estado visível (`ctl state`); o modelo de domínio entra com T1-05.
    func appState() async -> AppStateSnapshot
}

extension ActionDispatching {
    public func boundArgument(forControl id: A11yID) async -> ActionArgument? { nil }
}
