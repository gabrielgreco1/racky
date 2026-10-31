import CoreGraphics
import Foundation

/// Zona de drop sobre um pane (F11): as quatro bordas criam um split com o item arrastado naquele lado; o centro troca de lugar.
public enum PaneDropZone: String, Sendable, CaseIterable, Codable {
    case left, right, top, bottom, center

    /// Fração de cada lado ocupada pelas zonas de borda (o centro é o miolo restante).
    public static let edgeFraction: CGFloat = 0.25

    /// Zona sob `point` (y cresce para baixo) dentro de `rect`: o miolo é o centro; fora dele vale a borda mais próxima.
    public static func zone(at point: CGPoint, in rect: CGRect) -> PaneDropZone {
        guard rect.width > 0, rect.height > 0 else { return .center }
        let nx = min(max((point.x - rect.minX) / rect.width, 0), 1)
        let ny = min(max((point.y - rect.minY) / rect.height, 0), 1)
        if nx >= edgeFraction, nx <= 1 - edgeFraction, ny >= edgeFraction, ny <= 1 - edgeFraction { return .center }
        let distances: [(PaneDropZone, CGFloat)] = [(.left, nx), (.right, 1 - nx), (.top, ny), (.bottom, 1 - ny)]
        return distances.min { $0.1 < $1.1 }?.0 ?? .center
    }

    /// Eixo do split criado (`nil` no centro).
    public var axis: SplitAxis? {
        switch self {
        case .left, .right: .horizontal
        case .top, .bottom: .vertical
        case .center: nil
        }
    }

    /// `true` quando o item arrastado fica no primeiro ramo (esquerda ou acima).
    public var insertsFirst: Bool { self == .left || self == .top }

    /// Área que o item arrastado passa a ocupar (metade do pane na borda; o pane inteiro no centro). Mesmo espaço de `rect`.
    public func previewRect(in rect: CGRect) -> CGRect {
        switch self {
        case .left: CGRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .right: CGRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .top: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2)
        case .bottom: CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
        case .center: rect
        }
    }
}

extension PaneLayout {
    /// Insere `subtree` ao lado da folha `paneID` (zona de borda): vira um split novo no lugar da folha. Nil se a zona é o centro,
    /// o pane não existe ou a subárvore repete um pane ou terminal já presente (invariante B7).
    public func inserting(_ subtree: PaneLayout, beside paneID: UUID, zone: PaneDropZone, ratio: Double = 0.5) -> PaneLayout? {
        guard let axis = zone.axis, contains(paneID: paneID), subtree.isValid else { return nil }
        let mine = Set(panes.map(\.id)), theirs = Set(subtree.panes.map(\.id))
        guard mine.isDisjoint(with: theirs), Set(terminalIDs).isDisjoint(with: Set(subtree.terminalIDs)) else { return nil }
        let r = min(max(ratio, Self.minRatio), Self.maxRatio)
        return replacingLeaf(paneID) { target in
            zone.insertsFirst
                ? .split(axis: axis, ratio: r, first: subtree, second: .leaf(target))
                : .split(axis: axis, ratio: 1 - r, first: .leaf(target), second: subtree)
        }
    }

    /// Troca de lugar os panes `a` e `b` da mesma árvore (centro do drop dentro de uma tab).
    public func swappingPanes(_ a: UUID, _ b: UUID) -> PaneLayout? {
        guard a != b, let pa = pane(withID: a), let pb = pane(withID: b) else { return nil }
        return mappingLeaves { $0.id == a ? pb : ($0.id == b ? pa : $0) }
    }

    /// Troca a folha `id` por `pane` (centro do drop entre duas tabs). Nil se `id` não existe ou `pane` já está na árvore.
    public func replacingPane(_ id: UUID, with pane: Pane) -> PaneLayout? {
        guard contains(paneID: id), !contains(paneID: pane.id) else { return nil }
        if case .terminal(let t) = pane.content, terminalIDs.contains(t) { return nil }
        return mappingLeaves { $0.id == id ? pane : $0 }
    }

    private func replacingLeaf(_ id: UUID, _ transform: (Pane) -> PaneLayout) -> PaneLayout {
        switch self {
        case .leaf(let p): return p.id == id ? transform(p) : self
        case .split(let axis, let r, let a, let b):
            return .split(axis: axis, ratio: r, first: a.replacingLeaf(id, transform), second: b.replacingLeaf(id, transform))
        }
    }

    private func mappingLeaves(_ transform: (Pane) -> Pane) -> PaneLayout {
        switch self {
        case .leaf(let p): return .leaf(transform(p))
        case .split(let axis, let r, let a, let b):
            return .split(axis: axis, ratio: r, first: a.mappingLeaves(transform), second: b.mappingLeaves(transform))
        }
    }
}
