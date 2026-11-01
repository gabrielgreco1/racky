import AppKit
import SwiftUI

// Painel de menu próprio (02 §12.15): dropdowns ricos, combobox e menus dentro da janela. Visual e teclado; quem abre o
// painel (posição, animação M-105, ações) é o `OverlayRouter` em RackyUI.

/// Logo de agente (02 §2.10, §12.6): ÚNICO componente de logo. Logos oficiais em `Resources/AgentLogos/`
/// (proveniência em `sources.json`).
/// - Claude: monocromático, template em `#D97757` (nunca recolorido além disso).
/// - OpenCode: monocromático após remover o fundo opaco do arquivo; template em `textPrimary`.
/// - Codex: ícone de app colorido; mantém as cores originais (template o achataria numa silhueta).
/// - Shell: SF Symbol `terminal` em `textSecondary`.
public struct DSAgentLogo: View {
    private let kind: DSAgentKind
    private let size: CGFloat
    private let dimmed: Bool

    public init(_ kind: DSAgentKind, size: CGFloat = DSMetrics.menuItemIcon, dimmed: Bool = false) {
        self.kind = kind
        self.size = size
        self.dimmed = dimmed
    }

    public static let claudeColor = DSRGBA(hex: 0xD97757)

    public var body: some View {
        Group {
            switch kind {
            case .claude: brandImage("claude", template: true, tint: Self.claudeColor.color)
            case .codex: brandImage("codex", template: false, tint: DS.Color.textPrimary)
            case .opencode: brandImage("opencode", template: true, tint: DS.Color.textPrimary)
            case .shell:
                Image(systemName: "terminal").font(.system(size: size * 0.9)).foregroundStyle(DS.Color.textSecondary)
            }
        }
        .frame(width: size, height: size)
        .opacity(dimmed ? 0.7 : 1)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func brandImage(_ name: String, template: Bool, tint: Color) -> some View {
        if let nsImage = DSAgentLogoImages.image(named: name) {
            Image(nsImage: nsImage)
                .renderingMode(template ? .template : .original)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(tint)
        } else {
            // Recurso ausente no bundle: `AgentLogoTests` falha antes de isso chegar à UI.
            Image(systemName: "questionmark.square.dashed").font(.system(size: size * 0.9)).foregroundStyle(DS.Color.textSecondary)
        }
    }
}

/// Marca do GitHub (Octicons `mark-github`, MIT) em template: segue a cor do texto.
public struct DSGitHubMark: View {
    private let size: CGFloat

    public init(size: CGFloat = DSMetrics.menuItemIcon) { self.size = size }

    public var body: some View {
        Group {
            if let nsImage = DSAgentLogoImages.image(named: "github") {
                Image(nsImage: nsImage).renderingMode(.template).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "arrow.down.circle").font(.system(size: size * 0.9))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Logo de provedor ou serviço (`AgentLogos/<name>`) em template, tingido com a cor da marca.
public struct DSBrandLogo: View {
    private let name: String
    private let size: CGFloat
    private let tint: Color

    public init(_ name: String, size: CGFloat, tint: Color) {
        self.name = name
        self.size = size
        self.tint = tint
    }

    public var body: some View {
        Group {
            if let nsImage = DSAgentLogoImages.image(named: name) {
                Image(nsImage: nsImage).renderingMode(.template).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .foregroundStyle(tint)
            } else {
                Image(systemName: "cloud").font(.system(size: size * 0.8)).foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Carrega os PNGs oficiais (`@3x`, 60 px, cobre até 20 pt) do bundle do módulo.
@MainActor
enum DSAgentLogoImages {
    static func image(named name: String) -> NSImage? {
        guard let url = fileURL(name, scale: 3) else { return nil }
        return NSImage(contentsOf: url)
    }

    static func fileURL(_ name: String, scale: Int) -> URL? {
        Bundle.module.url(forResource: "\(name)@\(scale)x", withExtension: "png", subdirectory: "AgentLogos")
    }

    /// `sources.json` (proveniência dos logos, copiada junto).
    static var provenanceURL: URL? {
        Bundle.module.url(forResource: "sources", withExtension: "json", subdirectory: "AgentLogos")
    }
}

/// Fundo translúcido do menu: blur dentro da janela + `menuMaterial` (02 §8).
struct DSVisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .withinWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

public extension View {
    /// Superfície de menu/popover: raio 11, `menuMaterial`, borda `white/14`, `shadowMenu` (02 §12.15, §12.16).
    func dsMenuSurface(solid: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.menu)
        return background {
            ZStack {
                if !solid, !MotionPolicy.shared.reduceTransparency { DSVisualEffect() }
                (solid || MotionPolicy.shared.reduceTransparency ? DS.Color.menuSolid : DS.Color.menuMaterial)
            }
            .clipShape(shape)
        }
        .overlay(shape.strokeBorder(DS.Color.borderStrong, lineWidth: DSMetrics.hairline))
        .dsShadow(DS.Shadow.menu)
    }
}

/// Painel de itens: lista com cabeçalhos, separadores, atalhos à direita, check, submenu e busca opcional.
public struct DSMenuPanelView: View {
    private let navigator: DSMenuNavigator
    private let width: CGFloat
    private let searchPlaceholder: String
    private let solidSurface: Bool
    private let itemFont: DSTextStyle
    private let footer: String?
    private let decorateRow: (DSMenuItem, AnyView) -> AnyView
    private let decorateSearch: (AnyView) -> AnyView
    private let onOutcome: (DSMenuOutcome) -> Void

    /// `solidSurface`: fundo sólido em vez de blur (snapshots determinísticos). `footer`: linha de dicas de teclado abaixo da
    /// lista (Quick Launch). `decorateRow` e `decorateSearch` deixam quem usa o painel ligar identificadores de automação.
    public init(
        navigator: DSMenuNavigator, width: CGFloat = DS.Layout.menuMinWidth, searchPlaceholder: String = "", solidSurface: Bool = false,
        footer: String? = nil, itemFont: DSTextStyle = DS.Font.menuItem, decorateRow: @escaping (DSMenuItem, AnyView) -> AnyView = { _, view in view },
        decorateSearch: @escaping (AnyView) -> AnyView = { $0 }, onOutcome: @escaping (DSMenuOutcome) -> Void
    ) {
        self.footer = footer
        self.itemFont = itemFont
        self.decorateRow = decorateRow
        self.decorateSearch = decorateSearch
        self.solidSurface = solidSurface
        self.navigator = navigator
        self.width = width
        self.searchPlaceholder = searchPlaceholder
        self.onOutcome = onOutcome
    }

    private var listHeight: CGFloat {
        let content = navigator.visibleEntries.reduce(CGFloat.zero) { $0 + DSMenuNavigator.height(of: $1) }
        return min(content + DSMetrics.menuPadding * 2, DSMetrics.menuMaxHeight)
    }

    public var body: some View {
        VStack(spacing: .zero) {
            if navigator.searchable {
                decorateSearch(AnyView(searchRow))
                DS.Color.border.frame(height: DSMetrics.hairline)
            }
            list
            if let footer {
                DS.Color.border.frame(height: DSMetrics.hairline)
                Text(verbatim: footer)
                    .dsFont(DS.Font.small)
                    .foregroundStyle(DS.Color.textTertiary)
                    .lineLimit(1)
                    .padding(.horizontal, DSMetrics.menuItemPaddingH + DSMetrics.menuPadding)
                    .frame(maxWidth: .infinity, minHeight: DSMetrics.menuItemHeight, alignment: .leading)
            }
        }
        .frame(width: width)
        .dsMenuSurface(solid: solidSurface)
        .overlay(alignment: .topLeading) { submenuView }
        .background(DSKeyCatcher(navigator: navigator, active: keysActive, onOutcome: onOutcome))
        .environment(\.colorScheme, .dark)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: .zero) {
                    ForEach(navigator.visibleEntries) { entry in
                        switch entry {
                        case .item(let item): decorateRow(item, AnyView(row(item))).id(item.id)
                        case .separator: separator
                        case .header(let title): header(title)
                        }
                    }
                    if navigator.isEmptyResult {
                        Text(verbatim: "No results")
                            .dsFont(DS.Font.menuItem)
                            .foregroundStyle(DS.Color.textTertiary)
                            .frame(maxWidth: .infinity, minHeight: DSMetrics.menuItemHeight)
                    }
                }
                .padding(DSMetrics.menuPadding)
            }
            .scrollIndicators(.never)
            .frame(height: navigator.isEmptyResult ? nil : listHeight)
            .onChange(of: navigator.highlightedID) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
            }
        }
    }

    private var separator: some View {
        DS.Color.border.opacity(0.6)
            .frame(height: DSMetrics.hairline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, (DSMetrics.menuSeparatorHeight - DSMetrics.hairline) / 2)
    }

    private func header(_ title: String) -> some View {
        Text(verbatim: title)
            .dsFont(DS.Font.small)
            .fontWeight(.medium)
            .foregroundStyle(DS.Color.textSecondary)
            .padding(.horizontal, DSMetrics.menuItemPaddingH)
            .frame(maxWidth: .infinity, minHeight: DSMetrics.menuItemHeight, alignment: .leading)
    }

    private func row(_ item: DSMenuItem) -> some View {
        let highlighted = navigator.highlightedID == item.id
        return HStack(spacing: DS.Space.s2) {
            if let icon = item.icon { iconView(icon, destructive: item.destructive) }
            Text(verbatim: item.title)
                .dsFont(itemFont)
                .foregroundStyle(item.destructive ? DS.Color.destructive : DS.Color.textPrimary)
                .lineLimit(1)
            if let detail = item.detail {
                Text(verbatim: detail)
                    .dsFont(item.detailMono ? DS.Font.monoMicro : DS.Font.small)
                    .foregroundStyle(DS.Color.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: DS.Space.s2)
            if let shortcut = item.shortcut {
                Text(verbatim: shortcut).dsFont(itemFont).foregroundStyle(DS.Color.textTertiary)
            }
            if item.checked {
                Image(systemName: "checkmark").font(.system(size: DSMetrics.menuItemIcon - DS.Space.s0_5, weight: .medium))
                    .foregroundStyle(DS.Color.textPrimary)
            }
            if item.hasSubmenu {
                Image(systemName: "chevron.right").font(.system(size: DS.Space.s2_5, weight: .medium)).foregroundStyle(DS.Color.textSecondary)
            }
        }
        .padding(.horizontal, DSMetrics.menuItemPaddingH)
        .frame(maxWidth: .infinity, minHeight: DSMetrics.menuItemHeight, maxHeight: DSMetrics.menuItemHeight, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.control)
                .fill(highlighted ? highlightFill(item) : Color.clear)
        )
        .opacity(item.isEnabled ? 1 : 0.5)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { navigator.hover(item.id) }
        }
        // lint-ui: allow buttons o painel entrega o item ao chamador, que dispara a ação do registro
        .onTapGesture {
            guard item.isEnabled else { return }
            if item.hasSubmenu {
                navigator.openSubmenu(of: item)
            } else {
                onOutcome(.activate(item))
            }
        }
        .dsTooltip(item.disabledReason ?? "", enabled: item.disabledReason != nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: item.title))
        .accessibilityAddTraits(item.checked ? .isSelected : [])
    }

    private func highlightFill(_ item: DSMenuItem) -> Color {
        item.destructive ? DS.ColorSpec.destructive.scaled(0.2).color : DS.Color.borderStrong
    }

    @ViewBuilder private func iconView(_ icon: DSMenuItem.Icon, destructive: Bool) -> some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: DSMetrics.menuItemIcon - DS.Space.s0_5))
                .foregroundStyle(destructive ? DS.Color.destructive : DS.Color.textSecondary)
                .frame(width: DSMetrics.menuItemIcon, height: DSMetrics.menuItemIcon)
        case .agent(let kind):
            DSAgentLogo(kind, size: DSMetrics.menuItemIcon)
        case .data(let brand):
            DSDataLogo(brand, size: DSMetrics.menuItemIcon)
        }
    }

    private var searchRow: some View {
        HStack(spacing: DS.Space.s2) {
            Image(systemName: "magnifyingglass").font(.system(size: DSMetrics.menuItemIcon - DS.Space.s0_5)).foregroundStyle(DS.ColorSpec.textSecondary.scaled(0.6).color)
            HStack(spacing: .zero) {
                if navigator.query.isEmpty, navigator.marked.isEmpty {
                    Text(verbatim: searchPlaceholder).foregroundStyle(DS.Color.textQuaternary)
                } else {
                    Text(verbatim: navigator.query).foregroundStyle(DS.Color.textPrimary)
                    Text(verbatim: navigator.marked).foregroundStyle(DS.Color.textPrimary).underline()
                }
                Spacer(minLength: .zero)
            }
            .dsFont(DS.Font.menuItem)
        }
        .padding(.horizontal, DS.Space.s3)
        .frame(height: DSMetrics.menuSearchHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: searchPlaceholder))
        .accessibilityValue(Text(verbatim: navigator.query))
    }

    @Environment(\.dsMenuKeysActive) private var keysActive

    @ViewBuilder private var submenuView: some View {
        if let sub = navigator.submenu, let id = navigator.openSubmenuID {
            DSMenuPanelView(navigator: sub, width: width, solidSurface: solidSurface, itemFont: itemFont, decorateRow: decorateRow, onOutcome: onOutcome)
                .offset(x: width + DSMetrics.menuSubmenuGap, y: navigator.rowOffset(of: id) + DSMetrics.menuPadding + (navigator.searchable ? DSMetrics.menuSearchHeight + DSMetrics.hairline : 0))
        }
    }
}

// MARK: Teclado e IME

/// View invisível que recebe o foco do teclado enquanto o painel está aberto. Digita (com IME), navega e fecha.
struct DSKeyCatcher: NSViewRepresentable {
    let navigator: DSMenuNavigator
    let active: Bool
    let onOutcome: (DSMenuOutcome) -> Void

    func makeNSView(context: Context) -> DSKeyCatcherView {
        let view = DSKeyCatcherView()
        view.navigator = navigator
        view.onOutcome = onOutcome
        view.isActive = active
        return view
    }

    func updateNSView(_ view: DSKeyCatcherView, context: Context) {
        view.navigator = navigator
        view.onOutcome = onOutcome
        view.isActive = active
    }
}

/// Recebe teclas via `interpretKeyEvents` (setas, Return, Esc, Backspace chegam como seletores; texto e IME como `insertText`).
public final class DSKeyCatcherView: NSView, NSTextInputClient {
    public var navigator: DSMenuNavigator?
    public var onOutcome: (DSMenuOutcome) -> Void = { _ in }
    private var markedString = ""

    /// Só é first responder enquanto o menu está aberto (não em saída animada, não depois de fechado): um captador de
    /// teclas parado como first responder engole a digitação do terminal (F27).
    public var isActive = true {
        didSet {
            guard !isActive, oldValue else { return }
            markedString = ""
            if let window, window.firstResponder === self { window.makeFirstResponder(nil) }
        }
    }

    public override var acceptsFirstResponder: Bool { isActive }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, let window, window.firstResponder === self { window.makeFirstResponder(nil) }
        super.viewWillMove(toWindow: newWindow)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // O foco entra depois do primeiro layout (o painel nasce no mesmo ciclo em que o host muda de estado).
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    public override func keyDown(with event: NSEvent) {
        // ⌘↵ e ⇧↵ ativam o item destacado com o modificador (Quick Launch: com prompt, em split).
        if event.keyCode == 36 || event.keyCode == 76 {
            if event.modifierFlags.contains(.command) { deliver(.enter, activation: .command); return }
            if event.modifierFlags.contains(.shift) { deliver(.enter, activation: .shift); return }
        }
        if event.modifierFlags.contains(.command) {
            if event.charactersIgnoringModifiers == "v", navigator?.searchable == true,
                let text = NSPasteboard.general.string(forType: .string)
            {
                navigator?.type(text)
                return
            }
            super.keyDown(with: event)
            return
        }
        interpretKeyEvents([event])
    }

    private func deliver(_ key: DSMenuKey, activation: DSMenuActivation = .plain) {
        guard let outcome = navigator?.handle(key, activation: activation), outcome != .none else { return }
        onOutcome(outcome)
    }

    public override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): deliver(.up)
        case #selector(NSResponder.moveDown(_:)): deliver(.down)
        case #selector(NSResponder.moveLeft(_:)): deliver(.left)
        case #selector(NSResponder.moveRight(_:)): deliver(.right)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)): deliver(.enter)
        case #selector(NSResponder.cancelOperation(_:)): deliver(.escape)
        case #selector(NSResponder.deleteBackward(_:)): deliver(.backspace)
        case #selector(NSResponder.insertTab(_:)): deliver(.tab)
        case #selector(NSResponder.insertBacktab(_:)): deliver(.backtab)
        case #selector(NSResponder.moveToBeginningOfDocument(_:)), #selector(NSResponder.moveToBeginningOfLine(_:)): deliver(.home)
        case #selector(NSResponder.moveToEndOfDocument(_:)), #selector(NSResponder.moveToEndOfLine(_:)): deliver(.end)
        default: break
        }
    }

    // MARK: NSTextInputClient

    public func insertText(_ string: Any, replacementRange: NSRange) {
        markedString = ""
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        navigator?.type(text)
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedString = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        navigator?.setMarked(markedString)
    }

    public func unmarkText() {
        markedString = ""
        navigator?.setMarked("")
    }

    public func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    public func markedRange() -> NSRange {
        markedString.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: markedString.utf16.count)
    }
    public func hasMarkedText() -> Bool { !markedString.isEmpty }
    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    public func characterIndex(for point: NSPoint) -> Int { 0 }

    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(bounds, to: nil))
    }
}

public extension EnvironmentValues {
    /// `false` quando o painel está fechando (saída animada): o captador de teclas larga o first responder.
    @Entry var dsMenuKeysActive: Bool = true
}
