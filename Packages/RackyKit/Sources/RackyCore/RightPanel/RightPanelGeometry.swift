import CoreGraphics
import Foundation

/// Medidas puras do painel direito (10-right-panel §1). Os valores que coincidem com tokens do DS (`rightPanelCenterMinWidth`,
/// `rightPanelCollapseBelowWindowWidth`) são conferidos por teste contra `DS.Layout`.
public enum RightPanelGeometry {
    public static let defaultWidth: Double = 520
    public static let minWidth: Double = 260
    public static let maxWidth: Double = 960
    /// Abaixo desta largura o módulo entra em modo compacto (só ícones e números principais).
    public static let compactBelowWidth: Double = 320
    public static let defaultTopFraction: Double = 2.0 / 3.0
    public static let minTopFraction: Double = 0.15
    public static let maxTopFraction: Double = 0.85
    /// Altura mínima do conteúdo de um módulo (abaixo disso o divisor para de ceder).
    public static let minModuleHeight: Double = 96
    /// Altura do header de cada módulo.
    public static let moduleHeaderHeight: Double = 32
    /// Altura da faixa de topo do painel, alinhada com a tab row (36 = 32 + 4).
    public static let barHeight: Double = 36
    /// Espessura visível do divisor entre módulos; a área de arrasto é maior.
    public static let dividerThickness: Double = 1
    public static let dividerHitSlop: Double = 4
    /// Janela mais estreita que isto recolhe o painel sozinho (03 §1.1).
    public static let collapseBelowWindowWidth: Double = 1100
    /// Menor largura do centro (tabs e terminais) com o painel aberto.
    public static let centerMinWidth: Double = 320

    public static func clampedStoredWidth(_ value: Double) -> Double {
        guard value.isFinite else { return defaultWidth }
        return min(max(value, minWidth), maxWidth)
    }

    public static func clampedTopFraction(_ value: Double) -> Double {
        guard value.isFinite else { return defaultTopFraction }
        return min(max(value, minTopFraction), maxTopFraction)
    }

    /// Modo compacto por largura (do painel, não da janela).
    public static func isCompact(width: Double) -> Bool { width < compactBelowWidth }

    /// A janela é estreita demais para o painel ficar aberto sozinho (reabre ao alargar se estava aberto).
    public static func autoCollapses(windowWidth: Double) -> Bool { windowWidth < collapseBelowWindowWidth }

    /// Largura efetiva: a pedida, limitada ao que sobra depois da sidebar e do mínimo do centro. `nil` se nem a mínima cabe.
    public static func effectiveWidth(requested: Double, windowWidth: Double, sidebarWidth: Double) -> Double? {
        let room = windowWidth - sidebarWidth - centerMinWidth
        guard room >= minWidth else { return nil }
        return min(clampedStoredWidth(requested), room, maxWidth)
    }

    /// Alturas (de cima para baixo) dos módulos visíveis dentro de `total` pontos de conteúdo do painel (sem a faixa de topo).
    /// Um módulo ocupa tudo. Dois: divisão por `topFraction`, descontado o divisor, sem deixar nenhum abaixo de
    /// `minModuleHeight + moduleHeaderHeight` (se nem isso cabe, divide ao meio).
    public static func slotHeights(total: Double, count: Int, topFraction: Double) -> [Double] {
        guard count > 0, total > 0 else { return [] }
        guard count > 1 else { return [total] }
        let usable = max(0, total - dividerThickness)
        let minimum = minModuleHeight + moduleHeaderHeight
        if usable < minimum * 2 { return [usable / 2, usable / 2] }
        let top = min(max(usable * clampedTopFraction(topFraction), minimum), usable - minimum)
        return [top, usable - top]
    }

    /// Fração de topo correspondente a uma altura de topo arrastada (com os limites de altura mínima aplicados).
    public static func topFraction(forTopHeight height: Double, total: Double) -> Double {
        let usable = max(1, total - dividerThickness)
        let minimum = minModuleHeight + moduleHeaderHeight
        let clamped = usable < minimum * 2 ? usable / 2 : min(max(height, minimum), usable - minimum)
        return clampedTopFraction(clamped / usable)
    }
}
