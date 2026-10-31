import RackyDesignSystem
import RackyProtocol
import SwiftUI

/// Medidas fixas do Settings (03 §14.1): nav 240, conteúdo até 720 com padding 40/32/96, controles de 240.
enum SettingsMetrics {
    static let navWidth: CGFloat = 240
    static let navPadding: CGFloat = DS.Space.s2
    static let navItemHeight: CGFloat = 30
    static let contentMaxWidth: CGFloat = 720
    static let contentTop: CGFloat = DS.Space.s10
    static let contentSide: CGFloat = DS.Space.s8
    static let contentBottom: CGFloat = 96
    static let controlWidth: CGFloat = 240
    static let folderControlWidth: CGFloat = 340
    static let sectionGap: CGFloat = DS.Space.s10
    static let rowGap: CGFloat = DS.Space.s4
    /// Abaixo de 560 de conteúdo o rótulo vai para cima e o controle para baixo (03 §1.5, §14.1).
    static let stackedBreakpoint: CGFloat = 560
    static let labelMinWidth: CGFloat = stackedBreakpoint - controlWidth - DS.Space.s4
    static let agentLogo: CGFloat = 16
    static let rowIcon: CGFloat = DS.Space.s4
    static let pendingDot: CGFloat = 6
    static let profileRowHeight: CGFloat = 36
    static let previewHeight: CGFloat = 132
}

/// Item da nav: 30 de altura, 12×6 de padding, raio 10, 13/500; hover `fg5`, selecionado `panelSelected` (02 §12.8).
struct SettingsNavStyle: ButtonStyle {
    let selected: Bool
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .dsFont(DS.Font.nav)
            .foregroundStyle(selected ? DS.Color.textPrimary : DS.Color.navText)
            .padding(.horizontal, DS.Space.s3)
            .frame(maxWidth: .infinity, minHeight: SettingsMetrics.navItemHeight, maxHeight: SettingsMetrics.navItemHeight, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(selected ? DS.Color.panelSelected : (hovering ? DS.Color.fg5 : Color.clear)))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// Bloco com título interno 13/600 (03 §14.1); o espaço entre blocos é 40.
struct SettingsBlock<Content: View>: View {
    let title: LocalizedStringKey?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowGap) {
            if let title {
                Text(title, bundle: .module)
                    .dsFont(DS.Font.bodyStrong)
                    .foregroundStyle(DS.Color.textPrimary)
                    .accessibilityAddTraits(.isHeader)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Linha de configuração: rótulo `body` 13/500 e ajuda `small` à esquerda, controle à direita (largura 240).
/// Com menos de 560 de conteúdo o controle desce para baixo do rótulo.
struct SettingsRow<Control: View>: View {
    let title: LocalizedStringKey
    var help: LocalizedStringKey?
    var helpText: String?
    /// Campos de pasta precisam de mais que 240 (o caminho cortava: "~/Racky/worktre…").
    var controlWidth: CGFloat = SettingsMetrics.controlWidth
    @ViewBuilder var control: Control

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: DS.Space.s4) {
                // A largura ideal do rótulo é a mínima: uma ajuda longa quebra em 2 linhas em vez de jogar o controle para baixo.
                label.frame(minWidth: SettingsMetrics.labelMinWidth, idealWidth: SettingsMetrics.labelMinWidth, maxWidth: .infinity, alignment: .leading)
                control.frame(width: controlWidth, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                label
                control.frame(maxWidth: controlWidth, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: .zero) {
            Text(title, bundle: .module)
                .dsFont(DS.Font.label)
                .fontWeight(.medium)
                .foregroundStyle(DS.Color.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let help {
                Text(help, bundle: .module)
                    .dsFont(DS.Font.small)
                    .foregroundStyle(DS.Color.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .truncationMode(.tail)
            } else if let helpText {
                Text(verbatim: helpText)
                    .dsFont(DS.Font.small)
                    .foregroundStyle(DS.Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .dsTooltip(helpText)
            }
        }
    }
}

/// Campo de texto do Settings (03 §14.1 regras 2 e 3): salva ao sair do campo ou com ↵; Esc desfaz a edição; enquanto o texto
/// difere do salvo mostra um ponto de mudança pendente; valor inválido mostra borda `destructive` e a mensagem, e o salvo vale.
struct SettingsTextField: View {
    let id: A11yID
    let action: ActionID
    let saved: String
    var error: String?
    var placeholder: LocalizedStringKey = ""
    var mono = false
    @State private var draft: String
    @FocusState private var focused: Bool
    @Environment(\.actionRegistry) private var registry
    @Environment(\.isEnabled) private var isEnabled

    init(id: A11yID, action: ActionID, saved: String, error: String? = nil, placeholder: LocalizedStringKey = "", mono: Bool = false) {
        self.id = id
        self.action = action
        self.saved = saved
        self.error = error
        self.placeholder = placeholder
        self.mono = mono
        _draft = State(initialValue: saved)
    }

    private var pending: Bool { draft != saved && error == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            HStack(spacing: DS.Space.s2) {
                ZStack(alignment: .leading) {
                    if draft.isEmpty {
                        Text(placeholder, bundle: .module).foregroundStyle(DS.Color.textQuaternary).allowsHitTesting(false).accessibilityHidden(true)
                    }
                    TextField(text: $draft) { EmptyView() }
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onSubmit(commit)
                        .onKeyPress(.escape) {
                            guard focused, draft != saved || error != nil else { return .ignored }
                            draft = saved
                            return .handled
                        }
                }
                .dsFont(mono ? DS.Font.monoPane : DS.Font.inputCompact)
                .foregroundStyle(DS.Color.textPrimary)
                if pending {
                    Circle().fill(DS.Color.textTertiary).frame(width: SettingsMetrics.pendingDot, height: SettingsMetrics.pendingDot)
                        .accessibilityHidden(true)
                }
            }
            .dsFieldChrome(focused: focused, invalid: error != nil, disabled: !isEnabled, height: DSMetrics.fieldHeightComposer)
            .onChange(of: focused) { _, now in if !now { commit() } }
            .onChange(of: saved) { _, new in if !focused { draft = new } }
            .a11y(id, kind: "textfield", value: draft, action: action)
            if let error {
                HStack(spacing: DS.Space.s1) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: DS.Space.s3))
                    Text(verbatim: error).dsFont(DS.Font.small).lineLimit(1).truncationMode(.tail)
                }
                .foregroundStyle(DS.Color.destructive)
                .dsTooltip(error)
            }
        }
    }

    private func commit() {
        guard draft != saved, let registry else { return }
        let value = draft
        Task { _ = try? await registry.perform(action, .set(value)) }
    }
}

/// Stepper (02 §12.13): valor central e dois botões `−`/`+` que disparam `select(dec|inc)`.
struct SettingsStepper: View {
    let value: Int
    let action: ActionID
    let id: A11yID
    let range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: DS.Space.s2) {
            step("minus", "dec", name: String(localized: "Smaller", bundle: .module))
                .opacity(value > range.lowerBound ? 1 : 0.4)
            Text(verbatim: "\(value)")
                .dsFont(DS.Font.label)
                .monospacedDigit()
                .foregroundStyle(DS.Color.textPrimary)
                .frame(minWidth: DS.Space.s8)
                .a11y(id, kind: "stepper", value: String(value), action: action)
            step("plus", "inc", name: String(localized: "Larger", bundle: .module))
                .opacity(value < range.upperBound ? 1 : 0.4)
        }
    }

    private func step(_ symbol: String, _ direction: String, name: String) -> some View {
        ActionButton(action, argument: .select(direction), tooltip: name) { Image(systemName: symbol) }
            .buttonStyle(DSIconButtonStyle(.header, destructive: false, active: false))
            .accessibilityLabel(Text(verbatim: name))
    }
}

/// Controle que não pode ser usado agora: aparência de desabilitado e o motivo no tooltip (03 §24.6, AC-T02).
struct DisabledControl: View {
    let symbol: String
    let reason: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: DS.Space.s3))
            .foregroundStyle(DS.Color.textSecondary)
            .opacity(0.4)
            .frame(width: DS.Space.s6, height: DS.Space.s6)
            .contentShape(Rectangle())
            .dsTooltip(reason)
            .accessibilityLabel(Text(verbatim: reason))
    }
}

extension DSAgentKind {
    init(_ provider: TerminalProvider) {
        switch provider {
        case .claude: self = .claude
        case .codex: self = .codex
        case .opencode: self = .opencode
        case .shell, .custom: self = .shell
        }
    }
}
