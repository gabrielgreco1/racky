import CoreGraphics
import Foundation
import Testing
@testable import RackyProtocol

/// Modelo da árvore de panes (T1-14): splits ilimitados, fechar, foco, geometria e proporções (03 §4.3, 06 §1.8).
@Suite struct PaneLayoutOpsTests {
    static func pane() -> Pane { Pane(content: .terminal(.v7())) }
    static let area = CGRect(x: 0, y: 0, width: 1200, height: 800)

    /// a | (b / c): a à esquerda; b em cima de c à direita.
    static func three() -> (PaneLayout, Pane, Pane, Pane) {
        let a = pane(), b = pane(), c = pane()
        var l = PaneLayout.leaf(a)
        l = l.splitting(paneID: a.id, axis: .horizontal, inserting: b)!
        l = l.splitting(paneID: b.id, axis: .vertical, inserting: c)!
        return (l, a, b, c)
    }

    @Test func splitsAreUnlimited() throws {
        var layout = PaneLayout.leaf(Self.pane())
        var last = layout.firstPane
        for i in 0 ..< 12 {
            let next = Self.pane()
            layout = try #require(layout.splitting(paneID: last.id, axis: i.isMultiple(of: 2) ? .horizontal : .vertical, inserting: next))
            last = next
        }
        #expect(layout.leafCount == 13)
        #expect(layout.isValid)
    }

    @Test func nextAndPreviousPaneWrapAround() {
        let (l, a, b, c) = Self.three()
        #expect(l.pane(from: a.id, delta: 1)?.id == b.id)
        #expect(l.pane(from: c.id, delta: 1)?.id == a.id)
        #expect(l.pane(from: a.id, delta: -1)?.id == c.id)
        #expect(PaneLayout.leaf(a).pane(from: a.id, delta: 1) == nil, "com um só pane não há para onde ir")
    }

    @Test func closingAPaneLetsTheSiblingTakeItsSpaceAndMovesFocus() throws {
        let (l, a, b, c) = Self.three()
        #expect(l.focusSuccessor(afterRemoving: c.id)?.id == b.id)
        #expect(l.focusSuccessor(afterRemoving: a.id)?.id == b.id)
        let closedB = try #require(l.removing(paneID: b.id))
        #expect(closedB.panes.map(\.id) == [a.id, c.id])
        guard case .split(let axis, _, _, _) = closedB else { Issue.record("expected split"); return }
        #expect(axis == .horizontal, "o split vertical sumiu; c ocupa o lugar do pai")
        #expect(l.focusSuccessor(afterRemoving: b.id)?.id == c.id)
        #expect(PaneLayout.leaf(a).focusSuccessor(afterRemoving: a.id) == nil)
    }

    @Test func arrangementCoversTheAreaWithoutOverlapAndWithThreePointDividers() {
        let (l, a, b, c) = Self.three()
        let arrangement = l.arrangement(in: Self.area)
        #expect(arrangement.dividers.count == 2)
        for d in arrangement.dividers {
            let thickness = d.axis == .horizontal ? d.rect.width : d.rect.height
            #expect(thickness == 3)
        }
        let fa = arrangement.panes[a.id]!, fb = arrangement.panes[b.id]!, fc = arrangement.panes[c.id]!
        #expect(fa.maxX + 3 == fb.minX)
        #expect(fb.maxY + 3 == fc.minY)
        #expect(fb.maxX == Self.area.maxX && fc.maxX == Self.area.maxX)
        #expect(fc.maxY == Self.area.maxY)
        #expect(!fa.intersects(fb) && !fb.intersects(fc) && !fa.intersects(fc))
        for f in [fa, fb, fc] { #expect(f.minX == f.minX.rounded() && f.width == f.width.rounded(), "o terminal só recebe pontos inteiros") }
    }

    @Test func dividerIDsAreUnique() {
        var layout = PaneLayout.leaf(Self.pane())
        for i in 0 ..< 6 {
            layout = layout.splitting(paneID: layout.panes.last!.id, axis: i.isMultiple(of: 2) ? .horizontal : .vertical, inserting: Self.pane())!
        }
        let ids = layout.arrangement(in: Self.area).dividers.map(\.secondLeadingPaneID)
        #expect(Set(ids).count == ids.count)
    }

    @Test func equalizeGivesEveryPaneTheSameShareAlongAChain() throws {
        let a = Self.pane(), b = Self.pane(), c = Self.pane(), d = Self.pane()
        var l = PaneLayout.leaf(a)
        l = try #require(l.splitting(paneID: a.id, axis: .horizontal, ratio: 0.9, inserting: b))
        l = try #require(l.splitting(paneID: b.id, axis: .horizontal, ratio: 0.1, inserting: c))
        l = try #require(l.splitting(paneID: c.id, axis: .horizontal, ratio: 0.2, inserting: d))
        let arrangement = l.equalized().arrangement(in: CGRect(x: 0, y: 0, width: 1203, height: 600))
        let widths = [a, b, c, d].map { arrangement.panes[$0.id]!.width }
        #expect(widths.max()! - widths.min()! <= 3, "larguras: \(widths)")
    }

    @Test func settingRatioByPathChangesOnlyThatSplit() throws {
        let (l, a, b, c) = Self.three()
        let inner = SplitPath([true])
        let changed = l.settingRatio(at: inner, ratio: 0.8)
        guard case .split(_, let outer, _, let second) = changed, case .split(_, let r, _, _) = second else { Issue.record("shape"); return }
        #expect(outer == 0.5 && r == 0.8)
        #expect(changed.panes.map(\.id) == [a.id, b.id, c.id])
        #expect(l.settingRatio(at: SplitPath(), ratio: 7).arrangement(in: Self.area).dividers.first?.ratio == PaneLayout.maxRatio)
        #expect(l.split(at: SplitPath([false])) == nil, "uma folha não é split")
    }

    @Test func equalizingOneDividerLeavesTheOthers() {
        let (l, _, _, _) = Self.three()
        let skewed = l.settingRatio(at: SplitPath(), ratio: 0.2).settingRatio(at: SplitPath([true]), ratio: 0.9)
        let fixed = skewed.equalizing(at: SplitPath([true]))
        let dividers = fixed.arrangement(in: Self.area).dividers
        #expect(dividers.first { $0.path == SplitPath() }?.ratio == 0.2)
        #expect(dividers.first { $0.path == SplitPath([true]) }?.ratio == 0.5)
    }

    @Test func splitIsRefusedBelowTheMinimumPaneSize() {
        let a = Self.pane()
        let layout = PaneLayout.leaf(a)
        #expect(layout.canSplit(paneID: a.id, axis: .horizontal, in: CGRect(x: 0, y: 0, width: 483, height: 600)))
        #expect(!layout.canSplit(paneID: a.id, axis: .horizontal, in: CGRect(x: 0, y: 0, width: 482, height: 600)), "(482 - 3) / 2 < 240")
        #expect(layout.canSplit(paneID: a.id, axis: .vertical, in: CGRect(x: 0, y: 0, width: 300, height: 243)))
        #expect(!layout.canSplit(paneID: a.id, axis: .vertical, in: CGRect(x: 0, y: 0, width: 300, height: 242)))
        #expect(!layout.canSplit(paneID: UUID(), axis: .horizontal, in: Self.area))
    }

    @Test func dragRatioKeepsBothSidesAtTheMinimum() {
        let (l, a, b, _) = Self.three()
        let area = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let low = l.clampedRatio(0.0, at: SplitPath(), in: area)
        let high = l.clampedRatio(1.0, at: SplitPath(), in: area)
        let lowFrames = l.settingRatio(at: SplitPath(), ratio: low).arrangement(in: area).panes
        let highFrames = l.settingRatio(at: SplitPath(), ratio: high).arrangement(in: area).panes
        #expect(lowFrames[a.id]!.width >= 239, "largura mínima de 240 (arredondamento de 1 pt)")
        #expect(highFrames[b.id]!.width >= 239)
    }

    @Test func replacingContentKeepsTheSlot() throws {
        let (l, a, b, c) = Self.three()
        let newTerminal = UUID.v7()
        let replaced = l.replacingContent(ofPane: b.id, with: .terminal(newTerminal))
        #expect(replaced.panes.map(\.id) == [a.id, b.id, c.id])
        #expect(replaced.pane(forTerminal: newTerminal)?.id == b.id)
        #expect(replaced.isValid)
    }

    @Test func keepingOnlyOnePaneForCloseOthers() {
        let (l, _, b, _) = Self.three()
        #expect(l.keeping(onlyPane: b.id)?.panes.map(\.id) == [b.id])
        #expect(l.keeping(onlyPane: UUID()) == nil)
    }
}
