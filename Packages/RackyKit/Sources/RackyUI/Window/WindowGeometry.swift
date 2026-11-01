import RackyDesignSystem
import CoreGraphics

/// Medidas puras da janela (03 §1, DS §5.2). Separadas do AppKit para `LayoutConformanceTests`.
nonisolated public enum WindowGeometry {
    /// Origem (canto inferior esquerdo, coordenadas da titlebar view não invertida) dos três semáforos.
    /// O centro vertical fica em `trafficLightCenterY` a partir do topo; x da origem = 16 / 36 / 56.
    public static func trafficLightOrigins(buttonSize: CGSize, titlebarHeight: CGFloat = DS.Layout.titlebarHeight) -> [CGPoint] {
        let y = titlebarHeight - DS.Layout.trafficLightCenterY - buttonSize.height / 2
        return (0..<3).map { i in
            CGPoint(x: DS.Layout.trafficLightFirstCenterX + CGFloat(i) * DS.Layout.trafficLightSpacing, y: y)
        }
    }

    /// Largura do pad dos semáforos na faixa: 80, ou 0 em tela cheia (os semáforos somem).
    public static func trafficLightPad(fullScreen: Bool) -> CGFloat {
        fullScreen ? 0 : DS.Layout.trafficLightPad
    }

    /// Largura de sidebar permitida (220–500).
    public static func clampedSidebarWidth(_ w: CGFloat) -> CGFloat {
        min(max(w, DS.Layout.sidebarMinWidth), DS.Layout.sidebarMaxWidth)
    }
}
