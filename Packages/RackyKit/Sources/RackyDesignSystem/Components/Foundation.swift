import SwiftUI

/// Estado de interação forçado (snapshots e testes). Em uso normal vem do mouse e do foco.
public enum DSInteractionState: Sendable, Equatable {
    case rest, hover, pressed

    func factor(hover: Double, pressed: Double) -> Double {
        switch self {
        case .rest: 1
        case .hover: hover
        case .pressed: pressed
        }
    }
}

public extension DSRGBA {
    /// Mesma cor com o alfa multiplicado (`input/30`, `primary/90` de referência). Nunca pré-mistura com a superfície (02 §2).
    func scaled(_ factor: Double) -> DSRGBA { DSRGBA(hex: hex, opacity: alpha * factor) }
}

public extension View {
    /// Estilo tipográfico do DS (fonte, tracking). `Font` de tamanho fixo fica só aqui (02 §15).
    func dsFont(_ style: DSTextStyle) -> some View {
        font(style.font).tracking(style.trackingPoints)
    }

    /// Anel de foco de 3 pt `ring` a 50% por fora do controle (02 §13, DS9). Fade de 0,12 s (M-803).
    func dsFocusRing(_ visible: Bool, radius: CGFloat = DS.Radius.control) -> some View {
        overlay {
            RoundedRectangle(cornerRadius: radius + DS.Radius.focusRingOutset)
                .strokeBorder(DS.ColorSpec.ring.scaled(0.5).color, lineWidth: MotionTokens.Stroke.focusRing)
                .padding(-DS.Radius.focusRingOutset)
                .opacity(visible ? 1 : 0)
                .allowsHitTesting(false)
                .animation(MotionPolicy.shared.animation(MotionTokens.Easing.ease, MotionTokens.Duration.hover), value: visible)
        }
    }
}

/// Medidas dos componentes base (02 §12). Valores que não são tokens de layout ficam aqui, nunca soltos nas telas.
public enum DSMetrics {
    public static let hairline: CGFloat = 1
    public static let fieldHeight: CGFloat = 36
    public static let fieldHeightSmall: CGFloat = 32
    public static let fieldPaddingH: CGFloat = 12
    public static let textareaMinHeight: CGFloat = 88
    public static let segmentedHeight: CGFloat = 28
    public static let segmentedPadding: CGFloat = 2
    public static let segmentPaddingH: CGFloat = 10
    public static let switchTrack = CGSize(width: 36, height: 20)
    public static let switchThumb: CGFloat = 14
    public static let switchTrackCompact = CGSize(width: 24, height: 14)
    public static let switchThumbCompact: CGFloat = 10
    public static let checkboxSize: CGFloat = 14
    public static let badgeHeight: CGFloat = 16
    public static let keycapHeight: CGFloat = 16
    public static let listRowHeight: CGFloat = 32
    public static let toastIcon: CGFloat = 16
    public static let overlayCloseSize: CGFloat = 16
    public static let overlayPadding: CGFloat = 24
    public static let overlayGap: CGFloat = 16
    public static let overlayWindowMarginH: CGFloat = 32
    public static let overlayWindowMarginV: CGFloat = 96
    public static let emptyStateMaxWidth: CGFloat = 320
    public static let confirmationTile: CGFloat = 40
    public static let confirmationIcon: CGFloat = 20
    /// Campo compacto do composer (protótipo M-101: 32 pt).
    public static let fieldHeightComposer: CGFloat = 32
    public static let segmentedHeightComposer: CGFloat = 32
    public static let promptMaxHeight: CGFloat = 240
    // Menu e combobox (02 §12.11, §12.15).
    public static let menuPadding: CGFloat = 4
    public static let menuItemHeight: CGFloat = 24
    /// Largura do menu de contexto (F17): título 13 pt, ícone, atalho à direita.
    public static let contextMenuWidth: CGFloat = 232
    public static let menuItemPaddingH: CGFloat = 8
    public static let menuItemIcon: CGFloat = 14
    public static let menuSeparatorHeight: CGFloat = 7
    public static let menuSearchHeight: CGFloat = 32
    public static let menuMaxHeight: CGFloat = 320
    public static let menuSearchThreshold = 7
    public static let menuSubmenuGap: CGFloat = 2
    public static let popoverGap: CGFloat = 4
    public static let comboboxChevron: CGFloat = 11
    // Tooltip (02 §12.14).
    public static let tooltipArrow: CGFloat = 10
    public static let tooltipGap: CGFloat = 6
    public static let tooltipPaddingH: CGFloat = 12
    public static let tooltipPaddingV: CGFloat = 6
    public static let keyHintSize: CGFloat = 9
}
