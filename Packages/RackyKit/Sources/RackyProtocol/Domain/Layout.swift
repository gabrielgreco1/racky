import Foundation

public enum SplitAxis: String, Codable, Sendable { case horizontal, vertical }

public enum PaneContent: Hashable, Codable, Sendable {
    case terminal(UUID)
    case computerViewer(UUID)
    /// Tabela de um dataset (id ULID do `dataset`): fica numa tab própria ou ao lado do agente.
    case dataset(String)
    /// Tela do computador de um subagente (pelo nome): uma tab da sessão como as outras, ao lado do agente ou da tabela.
    case computer(String)
    /// Notebook Python de datasets (id do notebook): tab da sessão ou ao lado do agente, como a tabela.
    case notebook(String)
    /// Tela Traffic de um computador (pelo nome): as requests e os comandos dele, ao lado do agente ou numa tab própria.
    case traffic(String)

    private enum CodingKeys: String, CodingKey { case type, id }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        if type == "dataset" {
            self = .dataset(try c.decode(String.self, forKey: .id))
            return
        }
        if type == "computer" {
            self = .computer(try c.decode(String.self, forKey: .id))
            return
        }
        if type == "notebook" {
            self = .notebook(try c.decode(String.self, forKey: .id))
            return
        }
        if type == "traffic" {
            self = .traffic(try c.decode(String.self, forKey: .id))
            return
        }
        let id = try c.decode(UUID.self, forKey: .id)
        switch type {
        case "terminal": self = .terminal(id)
        case "computer_viewer": self = .computerViewer(id)
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown pane content \(other)")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .terminal(let id): try c.encode("terminal", forKey: .type); try c.encode(id, forKey: .id)
        case .computerViewer(let id): try c.encode("computer_viewer", forKey: .type); try c.encode(id, forKey: .id)
        case .dataset(let id): try c.encode("dataset", forKey: .type); try c.encode(id, forKey: .id)
        case .computer(let name): try c.encode("computer", forKey: .type); try c.encode(name, forKey: .id)
        case .notebook(let id): try c.encode("notebook", forKey: .type); try c.encode(id, forKey: .id)
        case .traffic(let name): try c.encode("traffic", forKey: .type); try c.encode(name, forKey: .id)
        }
    }
}

extension PaneContent {
    /// Terminal do pane (`nil` em panes de dataset e viewer).
    public var terminalID: UUID? { if case .terminal(let id) = self { id } else { nil } }
}

public struct Pane: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var content: PaneContent
    public init(id: UUID = .v7(), content: PaneContent) { self.id = id; self.content = content }
}

/// Árvore binária de splits cujas folhas são panes (01 §5.5). Valor puro; as operações devolvem nova árvore.
public indirect enum PaneLayout: Hashable, Codable, Sendable {
    case leaf(Pane)
    case split(axis: SplitAxis, ratio: Double, first: PaneLayout, second: PaneLayout)

    public static let minRatio = 0.05
    public static let maxRatio = 0.95

    public var panes: [Pane] {
        switch self {
        case .leaf(let p): [p]
        case .split(_, _, let a, let b): a.panes + b.panes
        }
    }

    public var terminalIDs: [UUID] {
        panes.compactMap { if case .terminal(let id) = $0.content { id } else { nil } }
    }

    /// Datasets abertos nos panes deste layout.
    public var datasetIDs: [String] {
        panes.compactMap { if case .dataset(let id) = $0.content { id } else { nil } }
    }

    /// Pane que mostra o dataset `id`.
    public func pane(forDataset id: String) -> Pane? {
        panes.first { if case .dataset(let d) = $0.content { d == id } else { false } }
    }

    /// Invariante: um terminal aparece em no máximo um pane (audit/01 B7), ids de pane únicos e proporções válidas.
    public var isValid: Bool {
        let ids = terminalIDs
        guard Set(ids).count == ids.count, Set(panes.map(\.id)).count == panes.count else { return false }
        return ratiosValid
    }

    private var ratiosValid: Bool {
        switch self {
        case .leaf: true
        case .split(_, let r, let a, let b):
            r >= Self.minRatio && r <= Self.maxRatio && a.ratiosValid && b.ratiosValid
        }
    }

    public func contains(paneID: UUID) -> Bool { panes.contains { $0.id == paneID } }

    /// Divide a folha `paneID`; o novo pane fica em `second`. Nil se o pane não existe ou o terminal já está no layout.
    public func splitting(paneID: UUID, axis: SplitAxis, ratio: Double = 0.5, inserting newPane: Pane) -> PaneLayout? {
        guard contains(paneID: paneID), !contains(paneID: newPane.id) else { return nil }
        if case .terminal(let t) = newPane.content, terminalIDs.contains(t) { return nil }
        let r = min(max(ratio, Self.minRatio), Self.maxRatio)
        return mapLeaf(paneID) { .split(axis: axis, ratio: r, first: .leaf($0), second: .leaf(newPane)) }
    }

    /// Remove a folha; o irmão ocupa o lugar do pai. Nil se for o último pane ou não existir.
    public func removing(paneID: UUID) -> PaneLayout? {
        guard contains(paneID: paneID) else { return nil }
        if case .leaf = self { return nil }
        return pruned(paneID)
    }

    private func pruned(_ id: UUID) -> PaneLayout? {
        switch self {
        case .leaf(let p): return p.id == id ? nil : self
        case .split(let axis, let r, let a, let b):
            let na = a.pruned(id), nb = b.pruned(id)
            switch (na, nb) {
            case (nil, let x?), (let x?, nil): return x
            case (let x?, let y?): return .split(axis: axis, ratio: r, first: x, second: y)
            case (nil, nil): return nil
            }
        }
    }

    /// Ajusta a proporção do split cujo primeiro ramo é a folha `paneID`.
    public func settingRatio(splitWithFirstPane paneID: UUID, ratio: Double) -> PaneLayout {
        let r = min(max(ratio, Self.minRatio), Self.maxRatio)
        switch self {
        case .leaf: return self
        case .split(let axis, let old, let a, let b):
            if case .leaf(let p) = a, p.id == paneID { return .split(axis: axis, ratio: r, first: a, second: b) }
            return .split(axis: axis, ratio: old,
                          first: a.settingRatio(splitWithFirstPane: paneID, ratio: r),
                          second: b.settingRatio(splitWithFirstPane: paneID, ratio: r))
        }
    }

    private func mapLeaf(_ id: UUID, _ transform: (Pane) -> PaneLayout) -> PaneLayout {
        switch self {
        case .leaf(let p): return p.id == id ? transform(p) : self
        case .split(let axis, let r, let a, let b):
            return .split(axis: axis, ratio: r, first: a.mapLeaf(id, transform), second: b.mapLeaf(id, transform))
        }
    }

    // MARK: Codable estável (layout_json)
    private enum CodingKeys: String, CodingKey { case type, pane, axis, ratio, first, second }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "leaf": self = .leaf(try c.decode(Pane.self, forKey: .pane))
        case "split":
            self = .split(axis: try c.decode(SplitAxis.self, forKey: .axis), ratio: try c.decode(Double.self, forKey: .ratio),
                          first: try c.decode(PaneLayout.self, forKey: .first), second: try c.decode(PaneLayout.self, forKey: .second))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown layout node \(other)")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let p): try c.encode("leaf", forKey: .type); try c.encode(p, forKey: .pane)
        case .split(let axis, let r, let a, let b):
            try c.encode("split", forKey: .type); try c.encode(axis, forKey: .axis); try c.encode(r, forKey: .ratio)
            try c.encode(a, forKey: .first); try c.encode(b, forKey: .second)
        }
    }
}

public struct Tab: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var sessionID: UUID
    public var title: String
    public var titleLocked: Bool
    public var sortIndex: Int
    public var layout: PaneLayout
    public var focusedTerminalID: UUID?
    public var createdAt: Date
    public var closedAt: Date?

    public init(
        id: UUID = .v7(), sessionID: UUID, title: String, titleLocked: Bool = false, sortIndex: Int = 0,
        layout: PaneLayout, focusedTerminalID: UUID? = nil, createdAt: Date = Date(), closedAt: Date? = nil
    ) {
        self.id = id; self.sessionID = sessionID; self.title = title; self.titleLocked = titleLocked
        self.sortIndex = sortIndex; self.layout = layout; self.focusedTerminalID = focusedTerminalID
        self.createdAt = createdAt; self.closedAt = closedAt
    }
}
