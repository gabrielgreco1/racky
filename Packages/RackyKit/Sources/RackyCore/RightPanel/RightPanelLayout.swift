import Foundation

/// Identificador estável de um módulo do painel direito (`files`, `insights`, `computers`...). Vai para o `ui_state`.
public struct PanelModuleID: Hashable, Codable, Sendable, RawRepresentable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public init(from decoder: any Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    public static let files: PanelModuleID = "files"
    public static let insights: PanelModuleID = "insights"
    public static let computers: PanelModuleID = "computers"
    public static let conversations: PanelModuleID = "conversations"
    /// Tabela ao vivo do dataset da sessão (abre sozinho quando dados começam a entrar).
    public static let data: PanelModuleID = "data"
}

/// Posição vertical de um módulo no painel.
public enum PanelSlot: String, Codable, Sendable, CaseIterable {
    case top, bottom
}

/// Modelo puro do painel direito (10-right-panel §1): aberto/fechado, largura, ordem e visibilidade dos módulos, divisão
/// vertical. Sem AppKit: o controlador da UI só traduz gestos em chamadas destes métodos e persiste o resultado em `ui_state`.
///
/// Regras:
/// - No máximo `slotCapacity` módulos visíveis ao mesmo tempo; mostrar mais um esconde o usado há mais tempo.
/// - Minimizar um módulo o esconde (o outro ocupa o painel); esconder o último fecha o painel.
/// - Fechar o painel guarda quais módulos estavam visíveis; reabrir devolve a mesma configuração.
public struct RightPanelLayout: Codable, Equatable, Sendable {
    public static let slotCapacity = 2
    public static let defaultOrder: [PanelModuleID] = [.files, .insights]

    /// Painel visível (⌥⌘0).
    public var isOpen: Bool
    /// Largura pedida pelo usuário (a largura efetiva também depende da janela, ver `RightPanelGeometry`).
    public var width: Double
    /// Ordem de cima para baixo de todos os módulos conhecidos; os visíveis ocupam os slots nesta ordem.
    public var order: [PanelModuleID]
    /// Módulos minimizados.
    public var hidden: Set<PanelModuleID>
    /// Fração da altura do conteúdo do painel dada ao módulo de cima quando há dois visíveis.
    public var topFraction: Double
    /// Do mais recente para o mais antigo: decide quem sai quando falta slot.
    public var recency: [PanelModuleID]

    public init(
        isOpen: Bool = true, width: Double = RightPanelGeometry.defaultWidth, order: [PanelModuleID] = RightPanelLayout.defaultOrder,
        hidden: Set<PanelModuleID> = [], topFraction: Double = RightPanelGeometry.defaultTopFraction, recency: [PanelModuleID]? = nil
    ) {
        self.isOpen = isOpen
        self.width = RightPanelGeometry.clampedStoredWidth(width)
        self.order = order
        self.hidden = hidden
        self.topFraction = RightPanelGeometry.clampedTopFraction(topFraction)
        self.recency = recency ?? order
    }

    // Decodificação tolerante: chaves ausentes (versões futuras ou antigas) caem nos padrões.
    private enum CodingKeys: String, CodingKey { case isOpen, width, order, hidden, topFraction, recency }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let order = try c.decodeIfPresent([PanelModuleID].self, forKey: .order) ?? Self.defaultOrder
        self.init(
            isOpen: try c.decodeIfPresent(Bool.self, forKey: .isOpen) ?? true,
            width: try c.decodeIfPresent(Double.self, forKey: .width) ?? RightPanelGeometry.defaultWidth,
            order: order,
            hidden: Set(try c.decodeIfPresent([PanelModuleID].self, forKey: .hidden) ?? []),
            topFraction: try c.decodeIfPresent(Double.self, forKey: .topFraction) ?? RightPanelGeometry.defaultTopFraction,
            recency: try c.decodeIfPresent([PanelModuleID].self, forKey: .recency))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(isOpen, forKey: .isOpen)
        try c.encode(width, forKey: .width)
        try c.encode(order, forKey: .order)
        try c.encode(hidden.map(\.rawValue).sorted(), forKey: .hidden)
        try c.encode(topFraction, forKey: .topFraction)
        try c.encode(recency, forKey: .recency)
    }

    // MARK: Consulta

    /// Módulos visíveis de cima para baixo (no máximo dois).
    public var visible: [PanelModuleID] {
        Array(order.filter { !hidden.contains($0) }.prefix(Self.slotCapacity))
    }

    public func isVisible(_ module: PanelModuleID) -> Bool { visible.contains(module) }

    /// Botão da faixa de topo "ligado": painel aberto e módulo visível.
    public func isOn(_ module: PanelModuleID) -> Bool { isOpen && isVisible(module) }

    public func slot(of module: PanelModuleID) -> PanelSlot? {
        guard let index = visible.firstIndex(of: module) else { return nil }
        return index == 0 ? .top : .bottom
    }

    public func module(in slot: PanelSlot) -> PanelModuleID? {
        let list = visible
        switch slot {
        case .top: return list.first
        case .bottom: return list.count > 1 ? list[1] : nil
        }
    }

    // MARK: Mudanças

    /// Garante que o módulo existe na ordem (módulos registrados depois de o estado ter sido salvo entram no fim). Um módulo
    /// novo que não cabe nos slots nasce minimizado: o usuário o liga quando quiser (ex.: Computers por ⇧⌘C).
    public mutating func register(_ module: PanelModuleID) {
        if !order.contains(module) {
            order.append(module)
            if order.filter({ !hidden.contains($0) }).count > Self.slotCapacity { hidden.insert(module) }
        }
        if !recency.contains(module) { recency.append(module) }
    }

    /// Mostra o módulo (abre o painel se estiver fechado). Falta de slot: sai o menos recente.
    public mutating func show(_ module: PanelModuleID) {
        register(module)
        hidden.remove(module)
        isOpen = true
        touch(module)
        while order.filter({ !hidden.contains($0) }).count > Self.slotCapacity {
            let candidates = order.filter { !hidden.contains($0) && $0 != module }
            guard let evict = candidates.max(by: { recencyRank($0) < recencyRank($1) }) else { break }
            hidden.insert(evict)
        }
    }

    /// Minimiza o módulo; esconder o último fecha o painel.
    public mutating func hide(_ module: PanelModuleID) {
        guard order.contains(module) else { return }
        hidden.insert(module)
        if visible.isEmpty { isOpen = false }
    }

    /// Botão do módulo na faixa de topo: desliga se está ligado, liga senão.
    public mutating func toggle(_ module: PanelModuleID) {
        if isOn(module) { hide(module) } else { show(module) }
    }

    /// ⌥⌘0: fecha o painel inteiro, ou reabre com o que estava visível (padrão se nada estava).
    public mutating func toggleOpen() {
        if isOpen {
            isOpen = false
            return
        }
        if visible.isEmpty {
            hidden.removeAll()
            for module in Self.defaultOrder.reversed() { show(module) }
        }
        isOpen = true
    }

    /// Soltar o header de `module` sobre o slot `slot`: troca de lugar com quem o ocupa. Sem dois módulos visíveis não há troca.
    @discardableResult
    public mutating func drop(_ module: PanelModuleID, on slot: PanelSlot) -> Bool {
        let list = visible
        guard list.count == 2, let from = list.firstIndex(of: module) else { return false }
        let to = slot == .top ? 0 : 1
        guard from != to else { return false }
        swapVisible()
        return true
    }

    /// Troca o módulo de cima com o de baixo.
    public mutating func swapVisible() {
        let list = visible
        guard list.count == 2, let a = order.firstIndex(of: list[0]), let b = order.firstIndex(of: list[1]) else { return }
        order.swapAt(a, b)
    }

    public mutating func setWidth(_ value: Double) { width = RightPanelGeometry.clampedStoredWidth(value) }

    public mutating func setTopFraction(_ value: Double) { topFraction = RightPanelGeometry.clampedTopFraction(value) }

    // MARK: Interno

    private mutating func touch(_ module: PanelModuleID) {
        recency.removeAll { $0 == module }
        recency.insert(module, at: 0)
    }

    private func recencyRank(_ module: PanelModuleID) -> Int { recency.firstIndex(of: module) ?? Int.max }
}
