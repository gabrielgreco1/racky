import RackyProtocol
import Foundation

/// Processos vivos que o ⌘Q deixaria para trás (03 §16.10).
public struct LiveProcessCounts: Sendable, Equatable {
    public var agents: Int
    public var shells: Int

    public init(agents: Int = 0, shells: Int = 0) {
        self.agents = agents
        self.shells = shells
    }

    /// Terminais com processo vivo segundo o banco (`running` ou ainda `launching`).
    public init(counting terminals: [Terminal]) {
        let live = terminals.filter { $0.state == .running || $0.state == .launching }
        agents = live.filter { $0.provider.isAgent }.count
        shells = live.count - agents
    }

    public var total: Int { agents + shells }
    public var isEmpty: Bool { total == 0 }
}

/// Quem pediu o encerramento.
public enum QuitRequestReason: Sendable, Equatable {
    /// ⌘Q, menu do app ou Dock.
    case user
    /// Logout, reinício ou desligamento do Mac: nunca bloqueia nem pergunta.
    case system
    /// "Quit Racky Completely" (barra de menus, `ctl app quit --completely`): sai do processo e deixa o daemon.
    case completely
}

/// Preferências lidas de Settings › General.
public struct QuitPreferences: Sendable, Equatable {
    /// `Keep agents running when you quit` (padrão ligado, P4).
    public var keepAgentsRunning: Bool
    /// `Ask before quitting with running agents` (padrão ligado; "Don't ask again" o desliga).
    public var askBeforeQuit: Bool

    public init(keepAgentsRunning: Bool = true, askBeforeQuit: Bool = true) {
        self.keepAgentsRunning = keepAgentsRunning
        self.askBeforeQuit = askBeforeQuit
    }
}

/// O que o overlay "Quit Racky?" mostra.
public struct QuitPrompt: Sendable, Equatable {
    public var counts: LiveProcessCounts
    /// `false`: Settings › "Keep agents running" desligado; o texto vira "Quitting stops them" e o padrão (↵) é Cancel.
    public var keepAgentsRunning: Bool
    /// P15: no primeiro ⌘Q o "Don't ask again" já vem marcado.
    public var dontAskPreChecked: Bool

    public init(counts: LiveProcessCounts, keepAgentsRunning: Bool, dontAskPreChecked: Bool) {
        self.counts = counts
        self.keepAgentsRunning = keepAgentsRunning
        self.dontAskPreChecked = dontAskPreChecked
    }
}

public enum QuitDecision: Sendable, Equatable {
    /// Encerra o processo agora.
    case quitNow
    /// Fecha a janela e fica em modo accessory, com o ícone na barra de menus; agentes e daemon seguem.
    case keepRunning
    /// Mostra o overlay na janela.
    case askUser(QuitPrompt)
    /// Para os processos (kill graceful, 5 s) e encerra.
    case stopAllAndQuit
}

/// Resposta do usuário ao overlay.
public enum QuitChoice: Sendable, Equatable {
    case keepRunning(dontAskAgain: Bool)
    case stopAll
    case cancel
}

/// Política do ⌘Q (06 §1.9, 03 §16.10): pura, sem AppKit.
public enum QuitPolicy {
    public static func decide(
        reason: QuitRequestReason, counts: LiveProcessCounts, preferences: QuitPreferences, askedBefore: Bool = false
    ) -> QuitDecision {
        switch reason {
        case .system, .completely:
            return .quitNow
        case .user:
            break
        }
        if !preferences.keepAgentsRunning {
            // Sem "Keep agents running": quitar para tudo. Pergunta só se há agente vivo e o aviso está ligado.
            if counts.isEmpty { return .quitNow }
            if counts.agents > 0, preferences.askBeforeQuit {
                return .askUser(QuitPrompt(counts: counts, keepAgentsRunning: false, dontAskPreChecked: false))
            }
            return .stopAllAndQuit
        }
        guard counts.agents > 0 else { return .quitNow }
        if preferences.askBeforeQuit {
            return .askUser(QuitPrompt(counts: counts, keepAgentsRunning: true, dontAskPreChecked: !askedBefore))
        }
        return .keepRunning
    }

    /// Efeito de uma escolha do overlay: o que o app faz e o que grava em Settings.
    public struct Effect: Sendable, Equatable {
        public var decision: QuitDecision?
        /// `true` desliga `Ask before quitting with running agents`.
        public var disableAsking: Bool
    }

    public static func apply(_ choice: QuitChoice, prompt: QuitPrompt) -> Effect {
        switch choice {
        case .cancel:
            return Effect(decision: nil, disableAsking: false)
        case .stopAll:
            return Effect(decision: .stopAllAndQuit, disableAsking: false)
        case .keepRunning(let dontAsk):
            // Com "Keep agents running" desligado o botão primário é Stop All; esta escolha não existe nessa variante.
            guard prompt.keepAgentsRunning else { return Effect(decision: nil, disableAsking: false) }
            return Effect(decision: .keepRunning, disableAsking: dontAsk)
        }
    }
}
