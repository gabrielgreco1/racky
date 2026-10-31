import RackyPlatform
import RackyProtocol
import RackyStore
import Foundation

/// Resultado da reconciliação do banco com o que o daemon ainda tem (06 §1.4).
public struct ReconcileReport: Sendable, Equatable {
    /// Terminais cujo processo continua vivo no daemon (a UI os religa com snapshot).
    public var alive: [UUID] = []
    public var exited: [UUID] = []
    public var interrupted: [UUID: InterruptionReason] = [:]
    /// Interrompidos que o usuário parou de propósito: nunca são retomados sozinhos (P25).
    public var stoppedByUser: Set<UUID> = []
    public init() {}
}

/// Ao abrir o app: terminais que o banco diz estarem `running`/`launching` são cruzados com o `list` do daemon.
/// Vivo = fica como está; encerrado = grava a saída; ausente = `interrupted` com o motivo. **Nada é relançado**
/// (06 §1.6): quem decide é o usuário, com Resume, Start Fresh ou Close.
public enum SessionReconciler {
    /// - Parameter daemonSessions: `nil` = daemon inalcançável (todas as sessões estão perdidas).
    public static func reconcile(
        store: RackyStore, daemonSessions: [SessionSummary]?, now: Date = Date(), bootTime: Date = InterruptionClassifier.bootTime(),
        runIDOfProcess: @Sendable (Int32) async -> UUID? = SessionReconciler.launchRunID(ofProcess:)
    ) async throws -> ReconcileReport {
        var report = ReconcileReport()
        var state = (try await store.uiState(RestoreUIState.key, as: RestoreUIState.self)) ?? RestoreUIState()
        let previousClean = !state.appRunning
        var candidates = try await store.terminals(in: .running)
        candidates += try await store.terminals(in: .launching)
        let byID = Dictionary((daemonSessions ?? []).map { ($0.sessionID.description, $0) }, uniquingKeysWith: { first, _ in first })
        // Marcado `interrupted` por engano (uma abertura que não alcançou o daemon, um daemon filho de fallback) mas a sessão
        // continua viva no daemon: volta a `running` e é religada. Senão o agente vivo some da UI e a retomada criaria um segundo.
        var lost = try await store.terminals(in: .interrupted)
        lost += try await store.terminals(in: .failedToStart)
        let known = Set((try await store.terminals(in: .running) + store.terminals(in: .launching)).compactMap(\.ptySessionID))
        // Sessão viva sem nenhum terminal apontando para ela: o ID salvo foi sobrescrito por uma retomada que falhou. O processo
        // carrega `run/launch/<runID>` na linha de comando; casa com o `currentRunID` do terminal.
        var orphanByRun: [UUID: SessionSummary] = [:]
        let claimed = Set(lost.compactMap(\.ptySessionID)).union(known)
        for summary in daemonSessions ?? [] where summary.state == .running && !claimed.contains(summary.sessionID.description) {
            if let pid = summary.pid, let run = await runIDOfProcess(pid) { orphanByRun[run] = summary }
        }
        for var terminal in lost {
            let summary = terminal.ptySessionID.flatMap { byID[$0] }.flatMap { $0.state == .running ? $0 : nil }
                ?? terminal.currentRunID.flatMap { orphanByRun[$0] }
            guard let summary else { continue }
            terminal.ptySessionID = summary.sessionID.description
            terminal.state = .running
            terminal.endedAt = nil
            try await store.save(terminal)
            report.alive.append(terminal.id)
            state.interruptions[terminal.id.uuidString] = nil
        }
        for var terminal in candidates {
            let summary = terminal.ptySessionID.flatMap { byID[$0] }
            if let summary, summary.state == .running {
                report.alive.append(terminal.id)
            } else if let summary {
                terminal.state = summary.exit?.signal != nil ? .killed : .exited
                terminal.exitCode = summary.exit?.code.map(Int.init)
                terminal.exitSignal = summary.exit?.signal.map(Int.init)
                terminal.endedAt = summary.exit?.at ?? now
                try await store.save(terminal)
                report.exited.append(terminal.id)
            } else {
                let reason = InterruptionClassifier.reason(
                    startedAt: terminal.startedAt, bootTime: bootTime, previousRunWasClean: previousClean)
                terminal.state = .interrupted
                terminal.endedAt = terminal.endedAt ?? now
                try await store.save(terminal)
                report.interrupted[terminal.id] = reason
                state.interruptions[terminal.id.uuidString] = reason
                if state.explicitlyStopped.contains(terminal.id.uuidString) { report.stoppedByUser.insert(terminal.id) }
            }
        }
        state.appRunning = true
        state.explicitlyStopped = []
        try await store.setUIState(RestoreUIState.key, state)
        return report
    }

    /// `run/launch/<uuid>` nos argumentos do processo (`--settings` do lançamento), lido com `ps`.
    public static func launchRunID(ofProcess pid: Int32) async -> UUID? {
        let request = ProcessRequest(executable: URL(fileURLWithPath: "/bin/ps"), arguments: ["-ww", "-o", "args=", "-p", "\(pid)"], timeout: .seconds(3))
        guard let out = try? await ProcessRunner.run(request), out.exitCode == 0,
              let range = out.stdoutString.range(of: #"run/launch/[0-9a-fA-F-]{36}"#, options: .regularExpression) else { return nil }
        return UUID(uuidString: String(out.stdoutString[range].dropFirst("run/launch/".count)))
    }

    /// "Stop All and Quit": guarda quais terminais o usuário parou de propósito, para a próxima abertura não os retomar.
    public static func recordExplicitStop(store: RackyStore, terminalIDs: [UUID]) async {
        var state = (try? await store.uiState(RestoreUIState.key, as: RestoreUIState.self)) ?? RestoreUIState()
        state.explicitlyStopped = Array(Set(state.explicitlyStopped + terminalIDs.map(\.uuidString)))
        try? await store.setUIState(RestoreUIState.key, state)
    }

    /// Saída limpa do app (⌘Q, fechar a janela): a próxima abertura sabe que o que morreu depois morreu "com o app fechado".
    public static func markCleanExit(store: RackyStore) async {
        var state = (try? await store.uiState(RestoreUIState.key, as: RestoreUIState.self)) ?? RestoreUIState()
        state.appRunning = false
        try? await store.setUIState(RestoreUIState.key, state)
    }

    /// Um terminal passou a `interrupted` com o app aberto (daemon morreu): guarda o motivo para o banner.
    public static func recordInterruption(store: RackyStore, terminalID: UUID, reason: InterruptionReason) async {
        var state = (try? await store.uiState(RestoreUIState.key, as: RestoreUIState.self)) ?? RestoreUIState()
        state.interruptions[terminalID.uuidString] = reason
        try? await store.setUIState(RestoreUIState.key, state)
    }

    public static func interruptions(store: RackyStore) async -> [UUID: InterruptionReason] {
        let state = (try? await store.uiState(RestoreUIState.key, as: RestoreUIState.self)) ?? RestoreUIState()
        return Dictionary(uniqueKeysWithValues: state.interruptions.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }
}
