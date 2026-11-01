import RackyProtocol
import Foundation
import Observation

// Modelo e navegação por teclado de menus e comboboxes (02 §12.11, §12.15). Sem SwiftUI: tudo aqui é testável sem janela.

/// Item de menu ou de combobox. Dados já localizados pelo chamador (`String(localized:)`).
public struct DSMenuItem: Identifiable, Equatable, Sendable {
    public enum Icon: Equatable, Sendable {
        case symbol(String)
        case agent(DSAgentKind)
        /// Logo de um banco, bucket, planilha ou webhook (cor da marca, sem fundo).
        case data(DSDataBrand)
    }

    public let id: String
    public var title: String
    public var icon: Icon?
    /// `textTertiary` à direita do título (caminho, "Not logged in").
    public var detail: String?
    public var detailMono: Bool
    /// O gatilho do combobox também mostra o detalhe (caminho do projeto); por padrão só o título.
    public var detailInTrigger: Bool
    /// Atalho à direita em `textTertiary`, sem caixa (02 §12.3).
    public var shortcut: String?
    public var checked: Bool
    public var destructive: Bool
    /// Motivo de estar desabilitado; `nil` = habilitado. Vira tooltip (DS §15 regra 20).
    public var disabledReason: String?
    /// Item fixo no fim do combobox (continua visível durante a busca).
    public var pinned: Bool
    public var submenu: [DSMenuEntry]
    /// Ação do registro disparada ao ativar (e o argumento dela).
    public var action: ActionID?
    public var argument: ActionArgument

    public init(
        _ id: String, _ title: String, icon: Icon? = nil, detail: String? = nil, detailMono: Bool = false, detailInTrigger: Bool = false, shortcut: String? = nil,
        checked: Bool = false, destructive: Bool = false, disabledReason: String? = nil, pinned: Bool = false,
        submenu: [DSMenuEntry] = [], action: ActionID? = nil, argument: ActionArgument = .press
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.detail = detail
        self.detailMono = detailMono
        self.detailInTrigger = detailInTrigger
        self.shortcut = shortcut
        self.checked = checked
        self.destructive = destructive
        self.disabledReason = disabledReason
        self.pinned = pinned
        self.submenu = submenu
        self.action = action
        self.argument = argument
    }

    public var isEnabled: Bool { disabledReason == nil }
    public var hasSubmenu: Bool { !submenu.isEmpty }
}

public enum DSMenuEntry: Identifiable, Equatable, Sendable {
    case item(DSMenuItem)
    case separator(String)
    /// Cabeçalho de grupo (11/500 `textSecondary`, ex.: "Session").
    case header(String)

    public var id: String {
        switch self {
        case .item(let item): item.id
        case .separator(let id): "separator.\(id)"
        case .header(let title): "header.\(title)"
        }
    }

    public var item: DSMenuItem? {
        if case .item(let item) = self { item } else { nil }
    }
}

/// Logos de agentes (02 §2.10) usados nos itens.
public enum DSAgentKind: Sendable, Equatable {
    case claude, codex, opencode, shell
}

/// Teclas que o painel entende (já traduzidas dos seletores de comando do AppKit).
public enum DSMenuKey: Equatable, Sendable {
    case up, down, home, end, right, left, enter, escape, backspace, tab, backtab
}

/// Como o item foi ativado: Enter simples, ⌘↵ (Quick Launch: "com o texto como prompt") ou ⇧↵ (abrir em split).
public enum DSMenuActivation: Equatable, Sendable { case plain, command, shift }

public enum DSMenuOutcome: Equatable, Sendable {
    case none
    case activate(DSMenuItem)
    case dismiss
}

/// Estado de navegação de um painel: item destacado, busca ou type-ahead, pilha de submenus.
@MainActor @Observable
public final class DSMenuNavigator {
    public let entries: [DSMenuEntry]
    public let searchable: Bool
    /// Texto digitado: filtra (com busca) ou só move o destaque (type-ahead, sem busca).
    public private(set) var query = ""
    /// Texto de composição IME em andamento (mostrado, ainda não confirmado).
    public private(set) var marked = ""
    public private(set) var highlightedID: String?
    /// Id do item cujo submenu está aberto (um nível, 03 §7).
    public private(set) var openSubmenuID: String?
    public private(set) var submenu: DSMenuNavigator?

    /// Modificador da última ativação (`.activate`): quem recebe o resultado decide o que ⌘↵ e ⇧↵ significam.
    public private(set) var activation: DSMenuActivation = .plain
    /// Linha oferecida quando o texto digitado não casa com nenhum item (Quick Launch: `Start Claude Code with "<texto>"`).
    @ObservationIgnored public var emptyFallback: (@MainActor (String) -> DSMenuItem?)?

    @ObservationIgnored private var typeAheadStamp: ContinuousClock.Instant?
    @ObservationIgnored public var typeAheadReset: Duration = .seconds(1)

    public init(entries: [DSMenuEntry], searchable: Bool = false, selectedID: String? = nil) {
        self.entries = entries
        self.searchable = searchable
        let enabled = entries.compactMap(\.item).filter(\.isEnabled)
        highlightedID = enabled.first { $0.id == selectedID }?.id ?? enabled.first?.id
    }

    /// Uma lista com mais de 7 itens ganha campo de busca (02 §12.11).
    public static func shouldSearch(itemCount: Int) -> Bool { itemCount > DSMetrics.menuSearchThreshold }

    // MARK: Entradas visíveis

    /// Entradas na ordem de exibição; com busca ativa, só os itens que casam (mais os fixos do rodapé).
    public var visibleEntries: [DSMenuEntry] {
        guard searchable, !query.isEmpty else { return entries }
        let needle = query.lowercased()
        var matches = entries.compactMap(\.item).filter { !$0.pinned && Self.matches($0, needle) }.map(DSMenuEntry.item)
        if matches.isEmpty, let fallback = emptyFallback?(query) { matches = [.item(fallback)] }
        let pinned = entries.compactMap(\.item).filter(\.pinned).map(DSMenuEntry.item)
        return pinned.isEmpty ? matches : matches + [.separator("pinned")] + pinned
    }

    public var visibleItems: [DSMenuItem] { visibleEntries.compactMap(\.item) }
    public var enabledItems: [DSMenuItem] { visibleItems.filter(\.isEnabled) }
    public var highlightedItem: DSMenuItem? { visibleItems.first { $0.id == highlightedID } }
    public var isEmptyResult: Bool { searchable && !query.isEmpty && visibleItems.filter { !$0.pinned }.isEmpty }

    private static func matches(_ item: DSMenuItem, _ needle: String) -> Bool {
        item.title.lowercased().contains(needle) || (item.detail?.lowercased().contains(needle) ?? false)
    }

    // MARK: Teclado

    public func handle(_ key: DSMenuKey, activation: DSMenuActivation = .plain) -> DSMenuOutcome {
        self.activation = activation
        if let submenu {
            switch key {
            case .left, .escape:
                closeSubmenu()
                return .none
            default:
                return submenu.handle(key, activation: activation)
            }
        }
        switch key {
        case .down, .tab: move(by: 1)
        case .up, .backtab: move(by: -1)
        case .home: highlight(enabledItems.first)
        case .end: highlight(enabledItems.last)
        case .right:
            if let item = highlightedItem, item.hasSubmenu, item.isEnabled { openSubmenu(of: item) }
        case .left: break
        case .enter:
            guard let item = highlightedItem, item.isEnabled else { return .none }
            if item.hasSubmenu {
                openSubmenu(of: item)
                return .none
            }
            return .activate(item)
        case .escape:
            if searchable, !query.isEmpty {
                setQuery("")
                return .none
            }
            return .dismiss
        case .backspace:
            if !query.isEmpty { setQuery(String(query.dropLast())) }
        }
        return .none
    }

    /// Caracteres digitados (já confirmados pelo IME). Com busca filtra; sem busca faz type-ahead por prefixo.
    public func type(_ text: String, now: ContinuousClock.Instant = .now) {
        let printable = text.filter { !$0.isNewline && $0 != "\t" && !($0.unicodeScalars.first.map { $0.value < 0x20 || $0.value == 0x7f } ?? false) }
        guard !printable.isEmpty else { return }
        marked = ""
        if searchable {
            setQuery(query + printable)
            return
        }
        if let stamp = typeAheadStamp, now - stamp > typeAheadReset { query = "" }
        typeAheadStamp = now
        query += printable
        let needle = query.lowercased()
        if let hit = enabledItems.first(where: { $0.title.lowercased().hasPrefix(needle) }) {
            highlightedID = hit.id
        } else if query.count > 1, let hit = enabledItems.first(where: { $0.title.lowercased().hasPrefix(String(needle.suffix(1))) }) {
            // Mesma letra repetida cicla pelos itens que começam com ela.
            query = String(printable.suffix(1))
            highlightedID = hit.id
        }
    }

    public func setMarked(_ text: String) { marked = text }

    public func setQuery(_ text: String) {
        query = text
        let items = enabledItems
        if !items.contains(where: { $0.id == highlightedID }) { highlightedID = items.first?.id }
    }

    /// Passar o mouse destaca (e fecha submenu de outro item).
    public func hover(_ id: String) {
        guard let item = visibleItems.first(where: { $0.id == id }), item.isEnabled else { return }
        highlightedID = id
        if openSubmenuID != nil, openSubmenuID != id { closeSubmenu() }
    }

    public func openSubmenu(of item: DSMenuItem) {
        guard item.hasSubmenu else { return }
        highlightedID = item.id
        openSubmenuID = item.id
        submenu = DSMenuNavigator(entries: item.submenu)
    }

    public func closeSubmenu() {
        openSubmenuID = nil
        submenu = nil
    }

    private func move(by delta: Int) {
        let items = enabledItems
        guard !items.isEmpty else { return }
        guard let index = items.firstIndex(where: { $0.id == highlightedID }) else {
            highlightedID = (delta > 0 ? items.first : items.last)?.id
            return
        }
        // Sem dar a volta: o fim da lista para (como o NSMenu).
        highlightedID = items[min(max(index + delta, 0), items.count - 1)].id
    }

    private func highlight(_ item: DSMenuItem?) { highlightedID = item?.id ?? highlightedID }

    // MARK: Geometria (linhas de altura fixa)

    /// Deslocamento vertical do topo da lista até a linha de `id` (para posicionar o submenu).
    public func rowOffset(of id: String) -> CGFloat {
        var y: CGFloat = 0
        for entry in visibleEntries {
            if entry.id == id { return y }
            y += Self.height(of: entry)
        }
        return y
    }

    public static func height(of entry: DSMenuEntry) -> CGFloat {
        switch entry {
        case .item, .header: DSMetrics.menuItemHeight
        case .separator: DSMetrics.menuSeparatorHeight
        }
    }
}
