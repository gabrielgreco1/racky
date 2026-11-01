import CoreGraphics
import Foundation
import Testing

@testable import RackyProtocol

/// Zonas de drop e operações de layout do arrasto de tab/pane (F11, 03 §3.4).
@Suite struct PaneDropTests {
    static let rect = CGRect(x: 100, y: 50, width: 800, height: 400)

    static func pane() -> Pane { Pane(content: .terminal(.v7())) }

    @Test func zonesFollowTheEdgesAndTheMiddleIsCenter() {
        let r = Self.rect
        #expect(PaneDropZone.zone(at: CGPoint(x: r.midX, y: r.midY), in: r) == .center)
        #expect(PaneDropZone.zone(at: CGPoint(x: r.minX + 10, y: r.midY), in: r) == .left)
        #expect(PaneDropZone.zone(at: CGPoint(x: r.maxX - 10, y: r.midY), in: r) == .right)
        #expect(PaneDropZone.zone(at: CGPoint(x: r.midX, y: r.minY + 5), in: r) == .top)
        #expect(PaneDropZone.zone(at: CGPoint(x: r.midX, y: r.maxY - 5), in: r) == .bottom)
        // Canto: vence a borda mais próxima (em fração do lado, não em pontos).
        #expect(PaneDropZone.zone(at: CGPoint(x: r.minX + 20, y: r.minY + 90), in: r) == .left)
        #expect(PaneDropZone.zone(at: CGPoint(x: r.minX + 150, y: r.minY + 10), in: r) == .top)
        #expect(PaneDropZone.zone(at: CGPoint(x: -500, y: r.midY), in: r) == .left, "fora do retângulo vale o ponto preso à borda")
    }

    @Test func previewCoversTheAreaTheDroppedItemWillOccupy() {
        let r = Self.rect
        #expect(PaneDropZone.left.previewRect(in: r) == CGRect(x: 100, y: 50, width: 400, height: 400))
        #expect(PaneDropZone.right.previewRect(in: r) == CGRect(x: 500, y: 50, width: 400, height: 400))
        #expect(PaneDropZone.top.previewRect(in: r) == CGRect(x: 100, y: 50, width: 800, height: 200))
        #expect(PaneDropZone.bottom.previewRect(in: r) == CGRect(x: 100, y: 250, width: 800, height: 200))
        #expect(PaneDropZone.center.previewRect(in: r) == r)
    }

    @Test func insertingBySideBuildsTheSplitWithTheDroppedItemOnThatSide() throws {
        let a = Self.pane(), n = Self.pane()
        let base = PaneLayout.leaf(a)
        let expected: [(PaneDropZone, SplitAxis, Bool)] = [
            (.left, .horizontal, true), (.right, .horizontal, false), (.top, .vertical, true), (.bottom, .vertical, false),
        ]
        for (zone, axis, first) in expected {
            let layout = try #require(base.inserting(.leaf(n), beside: a.id, zone: zone))
            guard case .split(let got, let ratio, let f, let s) = layout else { Issue.record("expected split"); return }
            #expect(got == axis)
            #expect(ratio == 0.5)
            #expect(f.firstPane.id == (first ? n.id : a.id))
            #expect(s.firstPane.id == (first ? a.id : n.id))
            #expect(layout.isValid)
        }
        #expect(base.inserting(.leaf(n), beside: a.id, zone: .center) == nil, "o centro não cria split")
    }

    @Test func insertingASubtreeKeepsItIntactAndRefusesDuplicates() throws {
        let a = Self.pane(), b = Self.pane(), c = Self.pane()
        let target = PaneLayout.leaf(a).splitting(paneID: a.id, axis: .horizontal, inserting: b)!
        let subtree = PaneLayout.leaf(c)
        let merged = try #require(target.inserting(subtree, beside: b.id, zone: .bottom))
        #expect(merged.terminalIDs.count == 3)
        #expect(merged.isValid)
        #expect(target.inserting(.leaf(a), beside: b.id, zone: .left) == nil, "o mesmo pane não entra duas vezes")
        let sameTerminal = Pane(content: a.content)
        #expect(target.inserting(.leaf(sameTerminal), beside: b.id, zone: .left) == nil, "nem o mesmo terminal (invariante B7)")
        #expect(target.inserting(subtree, beside: UUID(), zone: .left) == nil)
    }

    @Test func swappingAndReplacingExchangePanesInPlace() throws {
        let a = Self.pane(), b = Self.pane(), x = Self.pane()
        let l = PaneLayout.leaf(a).splitting(paneID: a.id, axis: .horizontal, inserting: b)!
        let swapped = try #require(l.swappingPanes(a.id, b.id))
        #expect(swapped.panes.map(\.id) == [b.id, a.id])
        #expect(swapped.isValid)
        #expect(l.swappingPanes(a.id, a.id) == nil)
        let replaced = try #require(l.replacingPane(b.id, with: x))
        #expect(replaced.panes.map(\.id) == [a.id, x.id])
        #expect(l.replacingPane(b.id, with: a) == nil, "a folha já está na árvore")
        #expect(l.replacingPane(UUID(), with: x) == nil)
    }

    @Test func movingAPaneWithinATreeIsRemoveThenInsert() throws {
        let a = Self.pane(), b = Self.pane(), c = Self.pane()
        var l = PaneLayout.leaf(a)
        l = l.splitting(paneID: a.id, axis: .horizontal, inserting: b)!
        l = l.splitting(paneID: b.id, axis: .horizontal, inserting: c)!
        let base = try #require(l.removing(paneID: c.id))
        let moved = try #require(base.inserting(.leaf(c), beside: a.id, zone: .top))
        #expect(Set(moved.panes.map(\.id)) == [a.id, b.id, c.id])
        #expect(moved.panes.first?.id == c.id)
        #expect(moved.isValid)
    }
}
