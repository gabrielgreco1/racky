import SwiftUI

// Visual dos controles de formulário (02 §12.10, §12.12, §12.13, §12.8). A ação (registro) é ligada em RackyUI.

/// Moldura de campo (02 §12.10): fundo `input/30`, borda `input`; foco = borda `ring` + anel; inválido = `destructive`.
public struct DSFieldChrome: ViewModifier {
    let focused: Bool
    let invalid: Bool
    let disabled: Bool
    let height: CGFloat?
    let radius: CGFloat

    public func body(content: Content) -> some View {
        content
            .padding(.horizontal, DSMetrics.fieldPaddingH)
            .frame(minHeight: height, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: radius).fill(DS.ColorSpec.input.scaled(0.3).color))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(borderColor, lineWidth: DSMetrics.hairline))
            .dsFocusRing(focused && !invalid, radius: radius)
            .overlay {
                // Anel de erro: `destructive` a 40% (02 §12.10).
                RoundedRectangle(cornerRadius: radius + DS.Radius.focusRingOutset)
                    .strokeBorder(DS.ColorSpec.destructive.scaled(0.4).color, lineWidth: MotionTokens.Stroke.focusRing)
                    .padding(-DS.Radius.focusRingOutset)
                    .opacity(invalid && focused ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .opacity(disabled ? 0.5 : 1)
    }

    private var borderColor: Color {
        if invalid { return DS.Color.destructive }
        return focused ? DS.Color.ring : DS.Color.input
    }
}

public extension View {
    func dsFieldChrome(
        focused: Bool = false, invalid: Bool = false, disabled: Bool = false,
        height: CGFloat? = DSMetrics.fieldHeight, radius: CGFloat = DS.Radius.control
    ) -> some View {
        modifier(DSFieldChrome(focused: focused, invalid: invalid, disabled: disabled, height: height, radius: radius))
    }
}

/// Segmento do controle segmentado (02 §12.12): 12/500, raio 6, ativo `accent` + `textPrimary`, hover `fg/6`.
public struct DSSegmentStyle: ButtonStyle {
    public let active: Bool
    public let fillWidth: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var hovering = false

    public init(active: Bool, fillWidth: Bool = false) {
        self.active = active
        self.fillWidth = fillWidth
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .dsFont(DS.Font.label)
            .foregroundStyle(active ? DS.Color.textPrimary : DS.Color.textSecondary)
            .padding(.horizontal, DSMetrics.segmentPaddingH)
            .frame(maxWidth: fillWidth ? .infinity : nil, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.sm)
                    .fill(hovering && !active && isEnabled ? DS.Color.fg6 : Color.clear)
            )
            .dsFocusRing(isFocused && isEnabled, radius: DS.Radius.sm)
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// Trilho e botão do switch (02 §12.13): trilho 36×20, off `textSecondary/30`, on `textPrimary`; botão 14 `canvas`, desloca 16.
public struct DSSwitchVisual: View {
    private let isOn: Bool
    private let forcedFocus: Bool?
    private let compact: Bool
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    /// `compact`: trilho 24×14, botão 10 (02 §12.13), o do composer.
    public init(isOn: Bool, focused: Bool? = nil, compact: Bool = false) {
        self.isOn = isOn
        self.forcedFocus = focused
        self.compact = compact
    }

    private var focused: Bool { forcedFocus ?? (isFocused && isEnabled) }

    private var track: CGSize { compact ? DSMetrics.switchTrackCompact : DSMetrics.switchTrack }
    private var thumb: CGFloat { compact ? DSMetrics.switchThumbCompact : DSMetrics.switchThumb }
    private var travel: CGFloat { track.width - thumb - (track.height - thumb) }

    public var body: some View {
        let inset = (track.height - thumb) / 2
        ZStack(alignment: .leading) {
            Capsule().fill(isOn ? DS.Color.textPrimary : (compact ? DS.Color.accent : DS.ColorSpec.textSecondary.scaled(0.3).color))
            Circle()
                .fill(compact && !isOn ? DS.Color.textSecondary : DS.Color.canvas)
                .frame(width: thumb, height: thumb)
                .shadow(color: .black.opacity(0.25), radius: DSMetrics.hairline, y: DSMetrics.hairline)
                .offset(x: inset + (isOn ? travel : 0))
        }
        .frame(width: track.width, height: track.height)
        .dsFocusRing(focused, radius: DS.Radius.full)
        .animation(MotionPolicy.shared.animation(MotionTokens.Springs.snappy), value: isOn)
    }
}

/// Checkbox 14×14 (02 §12.13): raio 4, borda `input`, marcado `textPrimary` com check `#171717`.
public struct DSCheckboxVisual: View {
    private let isOn: Bool
    private let forcedFocus: Bool?
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    public init(isOn: Bool, focused: Bool? = nil) {
        self.isOn = isOn
        self.forcedFocus = focused
    }

    private var focused: Bool { forcedFocus ?? (isFocused && isEnabled) }

    public var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(isOn ? DS.Color.textPrimary : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(isOn ? Color.clear : DS.Color.input, lineWidth: DSMetrics.hairline))
            .overlay {
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: DS.Space.s2_5, weight: .bold))
                        .foregroundStyle(DS.Color.textOnPrimary)
                }
            }
            .frame(width: DSMetrics.checkboxSize, height: DSMetrics.checkboxSize)
            .dsFocusRing(focused, radius: 4)
    }
}

/// Linha de lista genérica (02 §12.8): 32 de altura (uma linha), hover `fg5`, selecionada `fg10` + borda `fg18`.
public struct DSListRowStyle: ButtonStyle {
    public let selected: Bool
    public let forcedState: DSInteractionState?
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var hovering = false

    public init(selected: Bool = false, forcedState: DSInteractionState? = nil) {
        self.selected = selected
        self.forcedState = forcedState
    }

    public func makeBody(configuration: Configuration) -> some View {
        let state = forcedState ?? (hovering ? .hover : .rest)
        configuration.label
            .padding(.horizontal, DS.Space.s3)
            .frame(maxWidth: .infinity, minHeight: DSMetrics.listRowHeight, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.control)
                    .fill(selected ? DS.Color.fg10 : (state == .hover && isEnabled ? DS.Color.fg5 : Color.clear))
            )
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(DS.Color.fg18, lineWidth: DSMetrics.hairline)
                } else if isFocused && isEnabled {
                    // Linha focada por teclado: anel interno de 2 pt `ring/50` (inset, 02 §13).
                    RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(DS.ColorSpec.ring.scaled(0.5).color, lineWidth: MotionTokens.Stroke.ring)
                }
            }
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}
