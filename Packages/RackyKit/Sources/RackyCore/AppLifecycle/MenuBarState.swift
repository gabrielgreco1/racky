import Foundation

/// Quando o ícone da barra de menus aparece (03 §14.2 e §17). Não existe `Never` (P4: com o app em accessory o ícone
/// é a única porta de volta).
public enum MenuBarVisibility: String, Sendable, Codable, Equatable {
    case always
    case whenAgentsRunning
}

/// Estado puro do item da barra de menus (03 §17): quantos agentes vivos, se aparece e o que o menu oferece.
public struct MenuBarState: Sendable, Equatable {
    public var counts: LiveProcessCounts
    public var visibility: MenuBarVisibility
    /// O app está em modo accessory (sem janela nem Dock): o ícone é obrigatório.
    public var isBackgroundOnly: Bool
    /// "Quit Racky Completely" foi usado: o ícone some até reabrir (o processo termina).
    public var quittingCompletely: Bool

    public init(
        counts: LiveProcessCounts = LiveProcessCounts(), visibility: MenuBarVisibility = .whenAgentsRunning,
        isBackgroundOnly: Bool = false, quittingCompletely: Bool = false
    ) {
        self.counts = counts
        self.visibility = visibility
        self.isBackgroundOnly = isBackgroundOnly
        self.quittingCompletely = quittingCompletely
    }

    public var isVisible: Bool {
        if quittingCompletely { return false }
        if isBackgroundOnly { return true }
        switch visibility {
        case .always: return true
        case .whenAgentsRunning: return counts.agents > 0
        }
    }

    /// Número ao lado do ícone (`button.title`); vazio sem agentes. Com a contagem de pendências (T1-25+) vem em vez dela.
    public var badgeTitle: String { counts.agents > 0 ? "\(counts.agents)" : "" }

    /// Cabeçalho desabilitado do menu.
    public var headerText: String {
        switch counts.agents {
        case 0: "No agents running"
        case 1: "1 agent running"
        default: "\(counts.agents) agents running"
        }
    }

    public enum Item: String, Sendable, Equatable, CaseIterable {
        case open, stopAll, quitCompletely
    }

    /// Itens na ordem do menu. `stopAll` só habilita com agentes vivos.
    public func isEnabled(_ item: Item) -> Bool {
        switch item {
        case .open, .quitCompletely: true
        case .stopAll: counts.agents > 0
        }
    }
}
