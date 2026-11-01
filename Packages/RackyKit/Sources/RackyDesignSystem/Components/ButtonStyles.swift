import SwiftUI

/// Variantes de botão (02 §12.1).
public enum DSButtonVariant: Sendable, CaseIterable {
    case primary, secondary, outline, ghost, destructive, link
}

public enum DSButtonSize: Sendable, CaseIterable {
    case xs, compact, sm, regular, lg

    public var height: CGFloat {
        switch self {
        case .xs: 24
        case .compact: 28
        case .sm: 32
        case .regular: 36
        case .lg: 40
        }
    }
    /// Padding horizontal sem ícone.
    public var paddingH: CGFloat {
        switch self {
        case .xs: 8
        case .compact: 12
        case .sm: 12
        case .regular: 16
        case .lg: 24
        }
    }
    /// Padding horizontal com ícone.
    public var paddingHWithIcon: CGFloat {
        switch self {
        case .xs: 6
        case .compact: 10
        case .sm: 10
        case .regular: 12
        case .lg: 16
        }
    }
    public var font: DSTextStyle { self == .xs || self == .compact ? DS.Font.label : DS.Font.control }
    public var icon: CGFloat {
        switch self {
        case .xs, .compact: 12
        case .sm: 14
        case .regular, .lg: 16
        }
    }
    public var radius: CGFloat { DS.Radius.control }
}

/// Cores de cada variante e estado (pura, testável).
public struct DSButtonColors: Equatable, Sendable {
    public var background: DSRGBA
    public var foreground: DSRGBA
    public var border: DSRGBA?

    public static func resolve(_ variant: DSButtonVariant, state: DSInteractionState) -> DSButtonColors {
        typealias C = DS.ColorSpec
        let clear = DSRGBA(hex: 0x000000, opacity: 0)
        switch variant {
        case .primary:
            return .init(background: C.primary.scaled(state.factor(hover: 0.9, pressed: 0.84)), foreground: C.textOnPrimary, border: nil)
        case .secondary:
            return .init(background: C.secondary.scaled(state.factor(hover: 0.8, pressed: 0.7)), foreground: C.textPrimary, border: nil)
        case .outline:
            let fill = state == .rest ? 0.3 : (state == .hover ? 0.5 : 0.6)
            return .init(background: C.input.scaled(fill), foreground: C.textPrimary, border: C.input)
        case .ghost:
            let bg = state == .rest ? clear : C.accent.scaled(state == .hover ? 0.5 : 0.7)
            return .init(background: bg, foreground: C.textPrimary, border: nil)
        case .destructive:
            let fill = state == .rest ? 1.0 : (state == .hover ? 0.7 / 0.6 : 0.8 / 0.6)
            return .init(background: C.destructiveFill.scaled(fill), foreground: DSRGBA(hex: 0xffffff), border: nil)
        case .link:
            return .init(background: clear, foreground: C.primary, border: nil)
        }
    }
}

/// Estilo de botão do DS: `.buttonStyle(DSButtonStyle(.primary, .sm))`.
/// Hover por `onHover`, pressed por `configuration.isPressed`, foco por `isFocused`; desabilitado = 50% (02 §12.1).
public struct DSButtonStyle: ButtonStyle {
    public let variant: DSButtonVariant
    public let size: DSButtonSize
    public let hasIcon: Bool
    public let forcedState: DSInteractionState?
    public let forcedFocus: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var hovering = false

    public init(
        _ variant: DSButtonVariant, _ size: DSButtonSize = .regular, hasIcon: Bool = false,
        forcedState: DSInteractionState? = nil, forcedFocus: Bool = false
    ) {
        self.variant = variant
        self.size = size
        self.hasIcon = hasIcon
        self.forcedState = forcedState
        self.forcedFocus = forcedFocus
    }

    public func makeBody(configuration: Configuration) -> some View {
        let state = forcedState ?? (configuration.isPressed ? .pressed : (hovering ? .hover : .rest))
        let colors = DSButtonColors.resolve(variant, state: isEnabled ? state : .rest)
        let isLink = variant == .link
        configuration.label
            .dsFont(size.font)
            .foregroundStyle(colors.foreground.color)
            .underline(isLink && state == .hover && isEnabled)
            .padding(.horizontal, isLink ? CGFloat.zero : (hasIcon ? size.paddingHWithIcon : size.paddingH))
            .frame(height: isLink ? nil : size.height)
            .background(RoundedRectangle(cornerRadius: size.radius).fill(colors.background.color))
            .overlay {
                if let border = colors.border {
                    RoundedRectangle(cornerRadius: size.radius).strokeBorder(border.color, lineWidth: DSMetrics.hairline)
                }
            }
            .dsFocusRing((isFocused || forcedFocus) && isEnabled, radius: size.radius)
            .scaleEffect(state == .pressed && !MotionPolicy.shared.reduceMotion ? MotionTokens.Scale.press : 1)
            .animation(MotionPolicy.shared.animation(MotionTokens.Easing.ease, MotionTokens.Duration.press), value: state)
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

public extension ButtonStyle where Self == DSButtonStyle {
    static func ds(_ variant: DSButtonVariant, _ size: DSButtonSize = .regular) -> DSButtonStyle {
        DSButtonStyle(variant, size)
    }
}

/// Variantes de botão de ícone (02 §12.2).
public enum DSIconButtonVariant: Sendable, CaseIterable {
    case titlebar, titlebarSmall, header, row, pane, tabClose, toolbar, activity

    public var box: CGSize {
        switch self {
        case .titlebar: CGSize(width: 32, height: 24)
        case .titlebarSmall: CGSize(width: 22, height: 20)
        case .header: CGSize(width: 24, height: 24)
        case .row: CGSize(width: 20, height: 20)
        case .pane: CGSize(width: 24, height: 24)
        case .tabClose: CGSize(width: 16, height: 16)
        case .toolbar: CGSize(width: 28, height: 28)
        case .activity: CGSize(width: 36, height: 36)
        }
    }
    public var icon: CGFloat {
        switch self {
        case .titlebar, .activity: 16
        case .titlebarSmall, .pane, .tabClose: 12
        case .header, .row, .toolbar: 14
        }
    }
    public var radius: CGFloat {
        switch self {
        case .header, .toolbar: DS.Radius.md
        case .activity: 0
        default: 4
        }
    }
    /// Hit target mínimo (02 §10): `row` 24 e `tabClose` 20 estendem a área clicável.
    public var hit: CGSize {
        switch self {
        case .row: CGSize(width: 24, height: 24)
        case .tabClose: CGSize(width: 20, height: 20)
        default: box
        }
    }
    func hoverFill(_ state: DSInteractionState) -> DSRGBA {
        let clear = DSRGBA(hex: 0xffffff, opacity: 0)
        guard state != .rest else { return clear }
        switch self {
        case .titlebar, .titlebarSmall, .header, .row: return DS.ColorSpec.accent
        case .pane: return DSRGBA(hex: 0xffffff, opacity: 0.1)
        case .tabClose: return DS.ColorSpec.fg10
        case .toolbar: return DS.ColorSpec.accent.scaled(0.5)
        case .activity: return clear
        }
    }
}

public struct DSIconButtonStyle: ButtonStyle {
    public let variant: DSIconButtonVariant
    public let destructive: Bool
    public let active: Bool
    public let forcedState: DSInteractionState?

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var hovering = false

    public init(_ variant: DSIconButtonVariant, destructive: Bool = false, active: Bool = false, forcedState: DSInteractionState? = nil) {
        self.variant = variant
        self.destructive = destructive
        self.active = active
        self.forcedState = forcedState
    }

    public func makeBody(configuration: Configuration) -> some View {
        let state = forcedState ?? (configuration.isPressed ? .pressed : (hovering ? .hover : .rest))
        let lit = (state != .rest || active) && isEnabled
        let tint: DSRGBA = destructive ? DS.ColorSpec.destructive : (lit ? DS.ColorSpec.textPrimary : DS.ColorSpec.textSecondary)
        // Fundo "ativo" do botão que abriu um overlay (M-101): fica enquanto o overlay existe, sai em `hover` 0,12 s.
        let fill = active ? DS.ColorSpec.fg10 : variant.hoverFill(isEnabled ? state : .rest)
        configuration.label
            .font(.system(size: variant.icon, weight: .regular))
            .foregroundStyle(tint.color)
            .frame(width: variant.box.width, height: variant.box.height)
            .background(RoundedRectangle(cornerRadius: variant.radius).fill(fill.color))
            .dsFocusRing(isFocused && isEnabled, radius: variant.radius)
            .scaleEffect(state == .pressed && !MotionPolicy.shared.reduceMotion ? MotionTokens.Scale.press : 1)
            .animation(MotionPolicy.shared.animation(MotionTokens.Easing.ease, MotionTokens.Duration.press), value: state)
            .animation(MotionPolicy.shared.animation(MotionTokens.Easing.ease, MotionTokens.Duration.hover), value: active)
            .opacity(isEnabled ? 1 : 0.45)
            .frame(width: variant.hit.width, height: variant.hit.height)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}
