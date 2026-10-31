import RackyProtocol
import Foundation

/// Transição não prevista pela tabela da máquina (01 §6). O estado de origem nunca muda quando ela é lançada.
public struct InvalidTransition<State: Sendable & Equatable, Event: Sendable & Equatable>: Error, Sendable, Equatable {
    public let state: State
    public let event: Event
    public init(state: State, event: Event) { self.state = state; self.event = event }
}

// MARK: - Sessão (01 §6.1)

public enum SessionEvent: Sendable, Equatable, CaseIterable {
    /// Trabalho de criação terminou bem (ou o import encerrou).
    case createSucceeded
    case createFailed
    /// "Try Again", "Use Existing Branch", "Create Without Fetching".
    case retryCreate
    /// "Discard" na sessão que falhou ao criar.
    case discard
    case archive
    case restore
    case folderMissing
    /// "Locate…"
    case folderLocated
    case delete
}

/// Funções puras do ciclo de vida da sessão. Fatia 1: sem `sleeping` (v1.1).
public enum SessionLifecycleMachine {
    public static func next(_ state: SessionLifecycle, _ event: SessionEvent) -> SessionLifecycle? {
        switch (state, event) {
        case (.creating, .createSucceeded): .active
        case (.creating, .createFailed): .failedToCreate
        case (.failedToCreate, .retryCreate): .creating
        case (.failedToCreate, .discard): .deleted
        case (.active, .archive): .archived
        case (.active, .folderMissing): .missing
        case (.archived, .restore): .active
        case (.archived, .delete): .deleted
        case (.missing, .folderLocated): .active
        case (.missing, .delete): .deleted
        default: nil
        }
    }

    public static func reduce(_ state: SessionLifecycle, _ event: SessionEvent) throws(InvalidTransition<SessionLifecycle, SessionEvent>) -> SessionLifecycle {
        guard let n = next(state, event) else { throw InvalidTransition(state: state, event: event) }
        return n
    }

    /// Estados em que arquivar/apagar exige listar processos vivos (01 §6.1).
    public static func confirmationRequired(_ event: SessionEvent, runningTerminals: Int) -> Bool {
        (event == .archive || event == .delete) && runningTerminals > 0
    }
}

// MARK: - Terminal / processo (01 §6.2)

public enum TerminalProcessEvent: Sendable, Equatable {
    /// Primeiro lançamento, "Restart" ou "Resume".
    case launch
    case firstByte
    case spawnFailed
    case exited(code: Int)
    /// Parado pelo usuário.
    case killedByUser
    /// Sinal externo (`Killed (<SIGNAME>)`).
    case signaled(Int)
    /// O daemon perdeu o PTY (reboot ou crash).
    case ptyLost
    case containerStopped
}

public enum TerminalProcessMachine {
    public static func next(_ state: TerminalProcessState, _ event: TerminalProcessEvent) -> TerminalProcessState? {
        switch (state, event) {
        case (.notStarted, .launch), (.exited, .launch), (.killed, .launch),
             (.failedToStart, .launch), (.interrupted, .launch), (.containerStopped, .launch):
            return .launching
        case (.launching, .firstByte): return .running
        case (.launching, .spawnFailed): return .failedToStart
        // Processo que sai antes do primeiro byte também termina (senão ficaria preso em launching).
        case (.launching, .exited), (.running, .exited): return .exited
        case (.launching, .killedByUser), (.running, .killedByUser),
             (.launching, .signaled), (.running, .signaled): return .killed
        case (.launching, .ptyLost), (.running, .ptyLost): return .interrupted
        case (.running, .containerStopped): return .containerStopped
        default: return nil
        }
    }

    public static func reduce(_ state: TerminalProcessState, _ event: TerminalProcessEvent) throws(InvalidTransition<TerminalProcessState, TerminalProcessEvent>) -> TerminalProcessState {
        guard let n = next(state, event) else { throw InvalidTransition(state: state, event: event) }
        return n
    }

    /// Aplica o evento a um `Terminal`, mantendo os campos de saída coerentes com o estado.
    public static func apply(_ event: TerminalProcessEvent, to terminal: Terminal, at now: Date) throws(InvalidTransition<TerminalProcessState, TerminalProcessEvent>) -> Terminal {
        var t = terminal
        t.state = try reduce(terminal.state, event)
        switch event {
        case .launch:
            t.exitCode = nil; t.exitSignal = nil; t.endedAt = nil; t.startedAt = now
        case .exited(let code): t.exitCode = code; t.endedAt = now
        case .signaled(let sig): t.exitSignal = sig; t.endedAt = now
        case .killedByUser, .spawnFailed, .ptyLost, .containerStopped: t.endedAt = now
        case .firstByte: break
        }
        return t
    }

    /// Rótulo de UI (01 §6.2). `nil` para estados sem rótulo (running).
    public static func label(state: TerminalProcessState, exitCode: Int?, exitSignal: Int?) -> String? {
        switch state {
        case .notStarted: nil
        case .launching: "Starting"
        case .running: nil
        case .exited: (exitCode ?? 0) == 0 ? "Exited" : "Exited with code \(exitCode ?? 0)"
        case .killed: exitSignal.map { "Killed (\(signalName($0)))" } ?? "Stopped"
        case .failedToStart: "Couldn't start"
        case .interrupted: "Interrupted"
        case .containerStopped: "Container stopped"
        }
    }

    /// Ações oferecidas pela UI por estado (03 §4.6). "Resume Conversation" só com ID nativo.
    public static func isRestartable(_ state: TerminalProcessState) -> Bool {
        next(state, .launch) != nil
    }

    public static func signalName(_ n: Int) -> String {
        switch n {
        case 1: "SIGHUP"; case 2: "SIGINT"; case 3: "SIGQUIT"; case 6: "SIGABRT"; case 9: "SIGKILL"
        case 11: "SIGSEGV"; case 13: "SIGPIPE"; case 15: "SIGTERM"
        default: "SIG\(n)"
        }
    }
}

// MARK: - Atividade do agente (01 §6.3)

public enum AgentActivityEvent: Sendable, Equatable {
    case launched
    case sessionStarted
    case promptSubmitted
    case needsInput(NeedsInputKind)
    case turnEnded(activeChildren: Bool)
    case childrenFinished
    case failure
    case blocked
    case unblocked
    case interrupted
    /// `done` visto e sem atividade por 30 min.
    case idleTimeout
    case hooksUnavailable
}

public enum AgentActivityMachine {
    public static func next(_ state: AgentActivity, _ event: AgentActivityEvent) -> AgentActivity? {
        switch (state, event) {
        case (_, .launched): return .starting
        case (.starting, .sessionStarted): return .idle
        case (.starting, .promptSubmitted), (.idle, .promptSubmitted), (.done, .promptSubmitted),
             (.failed, .promptSubmitted), (.needsInput, .promptSubmitted), (.unknown, .promptSubmitted),
             (.working, .promptSubmitted):
            return .working
        case (.working, .needsInput(let k)): return .needsInput(k)
        case (.working, .turnEnded(let children)): return children ? .waitingOnSubagents : .done
        case (.waitingOnSubagents, .childrenFinished): return .done
        case (.starting, .failure), (.working, .failure), (.needsInput, .failure), (.waitingOnSubagents, .failure):
            return .failed
        case (.working, .blocked): return .blocked
        case (.blocked, .unblocked): return .working
        case (.starting, .interrupted), (.idle, .interrupted), (.working, .interrupted), (.needsInput, .interrupted),
             (.waitingOnSubagents, .interrupted), (.blocked, .interrupted):
            return .interrupted
        case (.done, .idleTimeout): return .idle
        case (.starting, .hooksUnavailable), (.idle, .hooksUnavailable), (.working, .hooksUnavailable),
             (.needsInput, .hooksUnavailable), (.waitingOnSubagents, .hooksUnavailable):
            return .unknown
        default: return nil
        }
    }

    public static func reduce(_ state: AgentActivity, _ event: AgentActivityEvent) throws(InvalidTransition<AgentActivity, AgentActivityEvent>) -> AgentActivity {
        guard let n = next(state, event) else { throw InvalidTransition(state: state, event: event) }
        return n
    }

    /// Fatia 1 (sem hooks): atividade derivada só do processo. Shell e Custom Command não têm atividade.
    public static func derivedActivity(provider: TerminalProvider, process: TerminalProcessState, exitCode: Int?) -> AgentActivity? {
        guard provider.isAgent else { return nil }
        switch process {
        case .launching: return .starting
        case .interrupted: return .interrupted
        case .failedToStart: return .failed
        case .exited: return (exitCode ?? 0) == 0 ? .unknown : .failed
        case .notStarted, .running, .killed, .containerStopped: return .unknown
        }
    }

    public struct Sample: Sendable, Equatable {
        public var activity: AgentActivity
        /// `done` ainda não visto pelo usuário.
        public var unseen: Bool
        public init(_ activity: AgentActivity, unseen: Bool = false) { self.activity = activity; self.unseen = unseen }
    }

    /// Ordem de agregação (01 §6.3): needsInput > failed > blocked > working > waitingOnSubagents >
    /// done não lido > interrupted > starting > done lido > idle > unknown. Pior estado vence.
    public static func rank(_ s: Sample) -> Int {
        switch s.activity {
        case .needsInput: 100
        case .failed: 91
        case .blocked: 90
        case .working: 80
        case .waitingOnSubagents: 70
        case .done: s.unseen ? 60 : 30
        case .interrupted: 50
        case .starting: 40
        case .idle: 20
        case .unknown: 10
        }
    }

    public static func aggregate(_ samples: [Sample]) -> AgentActivity? {
        samples.max { rank($0) < rank($1) }?.activity
    }
}
