import RackyDesignSystem
import RackyProtocol
import SwiftUI

/// Menus próprios dentro da janela (02 §12.15, M-105): dropdowns, comboboxes e o menu do nome do app.
/// O painel entrega o item escolhido; a ação do registro dispara depois que o painel fecha (foco já devolvido).
public enum DSMenuPanel {
    /// Itens cuja ação a fatia atual não entrega somem (AC-T28); ação indisponível vira item desabilitado com o motivo.
    @MainActor
    static func resolve(_ entries: [DSMenuEntry], registry: ActionRegistry?) -> [DSMenuEntry] {
        guard let registry else { return entries }
        var result: [DSMenuEntry] = []
        for entry in entries {
            guard case .item(var item) = entry else {
                result.append(entry)
                continue
            }
            if let action = item.action {
                guard registry.isRendered(action) else { continue }
                if item.disabledReason == nil {
                    switch registry.availability(of: action) {
                    case .disabled(let reason): item.disabledReason = reason
                    case .unregistered, .unavailable: item.disabledReason = String(localized: "Not available yet", bundle: .module)
                    case .enabled: break
                    }
                }
            }
            item.submenu = resolve(item.submenu, registry: registry)
            result.append(.item(item))
        }
        // Separadores seguidos ou nas pontas, deixados por itens removidos, saem.
        var cleaned: [DSMenuEntry] = []
        for entry in result {
            if case .separator = entry, cleaned.isEmpty || { if case .separator = cleaned.last { true } else { false } }() { continue }
            cleaned.append(entry)
        }
        if case .separator = cleaned.last { cleaned.removeLast() }
        return cleaned
    }

    /// Especificação do popover (posição, largura, conteúdo). Quem chama entrega para `OverlayRouter.presentPopover`.
    @MainActor
    public static func spec(
        name: String, anchor: CGRect, width: CGFloat, entries: [DSMenuEntry], selectedID: String? = nil, searchable: Bool = false,
        searchPlaceholder: String = "", alignment: PopoverAlignment = .leading, itemFont: DSTextStyle = DS.Font.menuItem, registry: ActionRegistry?,
        onActivate: (@MainActor (DSMenuItem) -> Void)? = nil
    ) -> PopoverSpec {
        let resolved = resolve(entries, registry: registry)
        return PopoverSpec(name: name, id: .menuPanel(name), anchor: anchor, width: width, alignment: alignment) { dismiss in
            AnyView(
                DSMenuPanelContent(
                    entries: resolved, selectedID: selectedID, searchable: searchable, searchPlaceholder: searchPlaceholder,
                    width: width, itemFont: itemFont, registry: registry, onActivate: onActivate, dismiss: dismiss))
        }
    }

    /// Abre o painel ancorado em `anchor`. `false` se o roteador não existe (view fora de uma janela montada).
    @MainActor @discardableResult
    public static func present(
        router: OverlayRouter?, registry: ActionRegistry?, name: String, anchor: CGRect, width: CGFloat = DS.Layout.menuMinWidth,
        entries: [DSMenuEntry], alignment: PopoverAlignment = .leading, itemFont: DSTextStyle = DS.Font.menuItem
    ) -> Bool {
        guard let router else { return false }
        return router.presentPopover(
            spec(name: name, anchor: anchor, width: width, entries: entries, alignment: alignment, itemFont: itemFont, registry: registry))
    }
}

private struct DSMenuPanelContent: View {
    let width: CGFloat
    let itemFont: DSTextStyle
    let registry: ActionRegistry?
    let onActivate: (@MainActor (DSMenuItem) -> Void)?
    let dismiss: @MainActor () -> Void
    let searchPlaceholder: String
    @State private var navigator: DSMenuNavigator

    init(
        entries: [DSMenuEntry], selectedID: String?, searchable: Bool, searchPlaceholder: String, width: CGFloat, itemFont: DSTextStyle,
        registry: ActionRegistry?, onActivate: (@MainActor (DSMenuItem) -> Void)?, dismiss: @escaping @MainActor () -> Void
    ) {
        self.width = width
        self.itemFont = itemFont
        self.registry = registry
        self.onActivate = onActivate
        self.dismiss = dismiss
        self.searchPlaceholder = searchPlaceholder
        _navigator = State(initialValue: DSMenuNavigator(entries: entries, searchable: searchable, selectedID: selectedID))
    }

    var body: some View {
        DSMenuPanelView(navigator: navigator, width: width, searchPlaceholder: searchPlaceholder, itemFont: itemFont) { outcome in
            switch outcome {
            case .none: break
            case .dismiss: dismiss()
            case .activate(let item):
                dismiss()
                onActivate?(item)
                if let action = item.action, let registry {
                    Task { await registry.performFromUI(action, item.argument) }
                }
            }
        }
    }
}

/// Select com busca (02 §12.11): gatilho com ícone opcional e um único `chevron-down`, popover `DSMenuPanel` com teclado
/// (↑↓ ↵ Esc, digitar filtra). Mais de 7 itens mostram o campo de busca. Escolher dispara `action` com `select(<id do item>)`;
/// itens com ação própria (rodapé "Add a New Project…") disparam a deles.
public struct DSCombobox: View {
    private let id: A11yID
    private let selection: String
    private let entries: [DSMenuEntry]
    private let action: ActionID
    private let searchPlaceholder: String
    private let placeholder: String
    private let height: CGFloat
    @State private var anchor: CGRect = .zero
    @Environment(\.overlayRouter) private var router
    @Environment(\.actionRegistry) private var registry

    public init(
        id: A11yID, selection: String, entries: [DSMenuEntry], action: ActionID, searchPlaceholder: String = "",
        placeholder: String = "", height: CGFloat = DSMetrics.fieldHeightComposer
    ) {
        self.id = id
        self.selection = selection
        self.entries = entries
        self.action = action
        self.searchPlaceholder = searchPlaceholder
        self.placeholder = placeholder
        self.height = height
    }

    private var selected: DSMenuItem? { entries.compactMap(\.item).first { $0.id == selection } }
    private var popoverID: A11yID { .menuPanel(id.rawValue) }
    private var isOpen: Bool { router?.popover?.spec.id == popoverID && router?.popoverIsOpen == true }

    public var body: some View {
        // lint-ui: allow buttons abre o popover do combobox (apresentação); a escolha dispara a ação do registro
        Button { open() } label: {
            DSComboboxField(
                icon: selected?.icon, title: selected?.title ?? placeholder, detail: selected?.detailInTrigger == true ? selected?.detail : nil, open: isOpen, height: height)
        }
        .buttonStyle(.plain)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { anchor = $0 }
        .onKeyPress(.downArrow) {
            open()
            return .handled
        }
        .accessibilityLabel(Text(verbatim: selected?.title ?? placeholder))
        .accessibilityAddTraits(.isButton)
        .a11y(id, kind: "combobox", label: action.spec.label, value: selection, action: action)
    }

    private func open() {
        guard !isOpen, let router else { return }
        router.presentPopover(
            Self.popoverSpec(
                id: id, selection: selection, entries: entries, action: action, searchPlaceholder: searchPlaceholder, anchor: anchor,
                registry: registry))
    }

    /// Popover do combobox: itens sem ação própria disparam `action` com `select(<id>)`; o selecionado leva o check.
    /// Público para o fixture de desenvolvimento e para testes abrirem o mesmo painel sem clicar.
    @MainActor
    public static func popoverSpec(
        id: A11yID, selection: String, entries: [DSMenuEntry], action: ActionID, searchPlaceholder: String, anchor: CGRect,
        registry: ActionRegistry?
    ) -> PopoverSpec {
        let mapped: [DSMenuEntry] = entries.map { entry in
            guard case .item(var item) = entry else { return entry }
            if item.action == nil {
                item.action = action
                item.argument = .select(item.id)
            }
            item.checked = item.id == selection
            return .item(item)
        }
        let count = mapped.compactMap(\.item).filter { !$0.pinned }.count
        return DSMenuPanel.spec(
            name: id.rawValue, anchor: anchor, width: max(anchor.width, DS.Layout.menuMinWidth), entries: mapped, selectedID: selection,
            searchable: DSMenuNavigator.shouldSearch(itemCount: count), searchPlaceholder: searchPlaceholder, registry: registry)
    }
}
