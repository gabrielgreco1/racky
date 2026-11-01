import RackyDesignSystem
import RackyProtocol
import SwiftUI

// Controles interativos do DS ligados ao registro de ações (02 §12, 08 AR-805). Cada um dispara
// `ActionRegistry.perform` por `ActionButton`; o visual vem de RackyDesignSystem/Components.

/// Botão do DS (02 §12.1). `loading` troca o rótulo por spinner + rótulo de progresso mantendo a largura.
public struct DSButton: View {
    private let action: ActionID
    private let id: A11yID?
    private let title: LocalizedStringKey
    private let variant: DSButtonVariant
    private let size: DSButtonSize
    private let symbol: String?
    private let keycap: String?
    private let loading: LocalizedStringKey?
    private let argument: ActionArgument

    public init(
        _ action: ActionID, id: A11yID? = nil, _ title: LocalizedStringKey, variant: DSButtonVariant = .outline,
        size: DSButtonSize = .sm, symbol: String? = nil, keycap: String? = nil, loading: LocalizedStringKey? = nil,
        argument: ActionArgument = .press
    ) {
        self.action = action
        self.id = id
        self.title = title
        self.variant = variant
        self.size = size
        self.symbol = symbol
        self.keycap = keycap
        self.loading = loading
        self.argument = argument
    }

    public var body: some View {
        ActionButton(action, id: id, argument: argument) {
            ZStack {
                label.opacity(loading == nil ? 1 : 0)
                if let loading {
                    HStack(spacing: DS.Space.s1_5) {
                        DSSpinner(size: size.icon - DS.Space.s0_5, delayed: false)
                        Text(loading, bundle: .module)
                    }
                }
            }
        }
        .buttonStyle(DSButtonStyle(variant, size, hasIcon: symbol != nil))
        .disabled(loading != nil)
    }

    private var label: some View {
        HStack(spacing: DS.Space.s1_5) {
            if let symbol { Image(systemName: symbol).font(.system(size: size.icon)) }
            Text(title, bundle: .module)
            if let keycap { KeyHint(keycap) }
        }
    }
}

/// Botão de ícone do DS (02 §12.2). O nome é o rótulo de acessibilidade e o tooltip.
public struct DSIconButton: View {
    private let action: ActionID
    private let id: A11yID?
    private let symbol: String
    private let name: String
    private let variant: DSIconButtonVariant
    private let destructive: Bool
    private let active: Bool
    /// Sobre o que a ação age (a sessão, o projeto…). Sem isso o botão mandava só `press` e ações que precisam de alvo falhavam.
    private let argument: ActionArgument

    public init(
        _ action: ActionID, id: A11yID? = nil, symbol: String, name: String, variant: DSIconButtonVariant = .header,
        destructive: Bool = false, active: Bool = false, argument: ActionArgument = .press
    ) {
        self.argument = argument
        self.action = action
        self.id = id
        self.symbol = symbol
        self.name = name
        self.variant = variant
        self.destructive = destructive
        self.active = active
    }

    public var body: some View {
        ActionButton(action, id: id, argument: argument, tooltip: name) {
            Image(systemName: symbol)
        }
        .buttonStyle(DSIconButtonStyle(variant, destructive: destructive, active: active))
        .accessibilityLabel(Text(verbatim: name))
    }
}

/// Controle segmentado (02 §12.12): `Picker(.segmented)` do sistema é proibido. Cada segmento dispara `action` com
/// `select(<valor>)`; ←/→ movem a seleção com o controle focado; o fundo do ativo desliza (M-113, `snappy`).
public struct DSSegmented: View {
    @FocusState private var keyboardFocused: Bool
    public struct Option: Identifiable, Equatable {
        public let id: String
        public let title: LocalizedStringKey
        /// Logos antes do nome (ex.: o agente de cada opção); dois logos para "Mixed".
        public let logos: [DSAgentKind]
        /// Explica a opção no tooltip (no lugar de uma linha de texto embaixo do controle).
        public let help: String?

        public init(_ id: String, _ title: LocalizedStringKey, logos: [DSAgentKind] = [], help: String? = nil) {
            self.id = id
            self.title = title
            self.logos = logos
            self.help = help
        }

        public static func == (lhs: Option, rhs: Option) -> Bool { lhs.id == rhs.id }
    }

    private let options: [Option]
    private let selection: String
    private let action: ActionID
    private let id: A11yID
    private let fillWidth: Bool
    private let height: CGFloat
    @Namespace private var namespace
    @Environment(\.actionRegistry) private var registry

    /// `fillWidth`: os segmentos dividem a largura toda em partes iguais (composer, protótipo M-101).
    public init(
        _ options: [Option], selection: String, action: ActionID, id: A11yID, fillWidth: Bool = false,
        height: CGFloat = DSMetrics.segmentedHeight
    ) {
        self.options = options
        self.selection = selection
        self.action = action
        self.id = id
        self.fillWidth = fillWidth
        self.height = height
    }

    public var body: some View {
        HStack(spacing: .zero) {
            ForEach(options) { option in
                let active = option.id == selection
                ActionButton(action, argument: .select(option.id)) {
                    HStack(spacing: DS.Space.s1_5) {
                        if !option.logos.isEmpty {
                            HStack(spacing: -DS.Space.s1) { ForEach(Array(option.logos.enumerated()), id: \.offset) { DSAgentLogo($0.element, size: DS.Space.s4) } }
                        }
                        Text(option.title, bundle: .module)
                    }
                }
                .buttonStyle(DSSegmentStyle(active: active, fillWidth: fillWidth))
                .help(option.help ?? "")
                .background {
                    if active {
                        RoundedRectangle(cornerRadius: DS.Radius.sm)
                            .fill(DS.Color.accent)
                            .matchedGeometryEffect(id: "segment-indicator", in: namespace)
                    }
                }
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .padding(DSMetrics.segmentedPadding)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(fillWidth ? DS.Color.fg6 : DS.Color.secondary))
        .animation(MotionPolicy.shared.animation(MotionTokens.Springs.snappy), value: selection)
        .fixedSize(horizontal: !fillWidth, vertical: true)
        // Foco só pela navegação do teclado (Tab): o clique não acende o anel azul do sistema; o anel é o do DS.
        .focusable(interactions: .activate)
        .focused($keyboardFocused)
        .focusEffectDisabled()
        .dsFocusRing(keyboardFocused, radius: DS.Radius.control)
        .onKeyPress(.leftArrow) { move(-1) }
        .onKeyPress(.rightArrow) { move(1) }
        .a11y(id, kind: "segmented", value: selection)
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard let registry, let index = options.firstIndex(where: { $0.id == selection }) else { return .ignored }
        let next = index + delta
        guard options.indices.contains(next) else { return .handled }
        let target = options[next].id
        Task { await registry.performFromUI(action, .select(target)) }
        return .handled
    }
}

/// Switch (02 §12.13): rótulo à esquerda, descrição opcional; clicar no rótulo também alterna.
public struct DSSwitch: View {
    private let isOn: Bool
    private let action: ActionID
    private let id: A11yID
    private let title: LocalizedStringKey
    private let compact: Bool

    public init(isOn: Bool, action: ActionID, id: A11yID, _ title: LocalizedStringKey, compact: Bool = false) {
        self.isOn = isOn
        self.action = action
        self.id = id
        self.title = title
        self.compact = compact
    }

    public var body: some View {
        ActionButton(action, id: id, argument: .set(isOn ? "off" : "on")) {
            HStack(spacing: DS.Space.s2) {
                DSSwitchVisual(isOn: isOn, compact: compact)
                Text(title, bundle: .module)
                    .dsFont(compact ? DS.Font.tab : DS.Font.body)
                    .foregroundStyle(compact ? DS.Color.textSecondary : DS.Color.textPrimary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityValue(Text(verbatim: isOn ? "on" : "off"))
        .accessibilityAddTraits(.isToggle)
    }
}

/// Checkbox (02 §12.13): 14×14, rótulo `body`.
public struct DSCheckbox: View {
    private let isOn: Bool
    private let action: ActionID
    private let id: A11yID
    private let title: LocalizedStringKey

    public init(isOn: Bool, action: ActionID, id: A11yID, _ title: LocalizedStringKey) {
        self.isOn = isOn
        self.action = action
        self.id = id
        self.title = title
    }

    public var body: some View {
        ActionButton(action, id: id, argument: .set(isOn ? "off" : "on")) {
            HStack(spacing: DS.Space.s2) {
                DSCheckboxVisual(isOn: isOn)
                Text(title, bundle: .module)
                    .dsFont(DS.Font.body)
                    .foregroundStyle(DS.Color.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityValue(Text(verbatim: isOn ? "checked" : "unchecked"))
        .accessibilityAddTraits(.isToggle)
    }
}

/// Linha de lista genérica (02 §12.8).
public struct DSListRow<Content: View>: View {
    private let action: ActionID
    private let id: A11yID?
    private let selected: Bool
    private let argument: ActionArgument
    private let content: Content

    public init(
        _ action: ActionID, id: A11yID? = nil, selected: Bool = false, argument: ActionArgument = .press,
        @ViewBuilder content: () -> Content
    ) {
        self.action = action
        self.id = id
        self.selected = selected
        self.argument = argument
        self.content = content()
    }

    public var body: some View {
        ActionButton(action, id: id, argument: argument) { content }
            .buttonStyle(DSListRowStyle(selected: selected))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Campo de texto (02 §12.10): fundo `input/30`, borda `input`, foco = borda `ring` + anel; inválido = `destructive` + mensagem.
/// Edições passam por `action` (`set(<texto>)`) quando informada. Enter durante composição IME é do `TextField` do sistema.
public struct DSTextField: View {
    private let placeholder: LocalizedStringKey
    @Binding private var text: String
    private let id: A11yID
    private let action: ActionID?
    private let error: String?
    private let multiline: Bool
    private let autofocus: Bool
    private let compact: Bool
    private let mono: Bool
    /// Senha ou chave: digitação escondida e o valor nunca vai para a árvore de acessibilidade (nem para o `ctl ui tree`).
    private let secure: Bool
    @FocusState private var focused: Bool
    @Environment(\.actionRegistry) private var registry
    @Environment(\.isEnabled) private var isEnabled

    public init(
        _ placeholder: LocalizedStringKey, text: Binding<String>, id: A11yID, action: ActionID? = nil, error: String? = nil,
        multiline: Bool = false, autofocus: Bool = false, compact: Bool = false, mono: Bool = false, secure: Bool = false
    ) {
        self.mono = mono
        self.secure = secure
        self.placeholder = placeholder
        self._text = text
        self.id = id
        self.action = action
        self.error = error
        self.multiline = multiline
        self.autofocus = autofocus
        self.compact = compact
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            field
                .textFieldStyle(.plain)
                .dsFont(mono ? DS.Font.monoPane : (compact ? DS.Font.inputCompact : DS.Font.input))
                .foregroundStyle(DS.Color.textPrimary)
                .focused($focused)
                .padding(.vertical, multiline ? DS.Space.s2 : .zero)
                .frame(minHeight: multiline ? DSMetrics.textareaMinHeight : nil, alignment: .topLeading)
                .dsFieldChrome(focused: focused, invalid: error != nil, disabled: !isEnabled, height: multiline ? nil : (compact ? DSMetrics.fieldHeightComposer : DSMetrics.fieldHeight))
                .onChange(of: text) { _, new in
                    guard let action, let registry else { return }
                    Task { await registry.performFromUI(action, .set(new)) }
                }
                .task {
                    guard autofocus else { return }
                    await Task.yield()
                    focused = true
                }
                .a11y(id, kind: multiline ? "textarea" : (secure ? "securefield" : "textfield"), value: secure ? nil : text, action: action)
            if let error {
                HStack(spacing: DS.Space.s1) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: DS.Space.s3))
                    Text(verbatim: error).dsFont(DS.Font.small)
                }
                .foregroundStyle(DS.Color.destructive)
            }
        }
    }

    /// O placeholder é desenhado por nós (o `prompt` do sistema ignora a cor `textQuaternary`).
    @ViewBuilder private var field: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder, bundle: .module)
                    .foregroundStyle(DS.Color.textQuaternary)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            if secure {
                SecureField(text: $text) { EmptyView() }
            } else if multiline {
                TextField(text: $text, axis: .vertical) { EmptyView() }.lineLimit(3...10)
            } else {
                TextField(text: $text) { EmptyView() }
            }
        }
    }
}
