import RackyProtocol
import RackyStore
import AppKit
import Foundation
import Testing

@testable import RackyUI

/// Arrasto da tab ativa sobre o próprio conteúdo: vira split com a tab parceira (mais recente, ou a vizinha).
extension WorkspaceModelTests {
    @Test func draggingTheActiveTabOverItselfSplitsWithThePartnerOnEachZone() async throws {
        for (zone, axis, draggedFirst) in [
            (PaneDropZone.right, SplitAxis.horizontal, false), (.left, .horizontal, true), (.top, .vertical, true), (.bottom, .vertical, false),
        ] {
            let rig = try await make(tabs: 2)
            defer { Task { await cleanup(rig) } }
            rig.model.contentSize = CGSize(width: 1200, height: 700)
            let tabs = rig.model.tabs
            let (active, partner) = (tabs[0].id, tabs[1].id)
            let (dragged, other) = (tabs[0].layout.terminalIDs[0], tabs[1].layout.terminalIDs[0])
            #expect(rig.model.activeTabID == active)
            #expect(rig.model.selfDropPartner(of: active)?.id == partner)
            #expect(rig.model.evaluateSelfDrop(active, zone: zone) == .applied)
            #expect(rig.model.performSelfDrop(active, zone: zone) == .applied)
            #expect(rig.model.tabs.map(\.id) == [partner], "a tab arrastada some")
            #expect(rig.model.activeTabID == partner)
            guard case .split(let got, let ratio, let first, let second)? = rig.model.activeTab?.layout else { Issue.record("expected split"); return }
            #expect(got == axis)
            #expect(ratio == 0.5)
            #expect(first.terminalIDs == [draggedFirst ? dragged : other])
            #expect(second.terminalIDs == [draggedFirst ? other : dragged])
            #expect(rig.model.terminal(dragged)?.tabID == partner, "mesmo terminal, só muda de tab")
            #expect(rig.model.focusedTerminalID == dragged)
        }
    }

    @Test func draggingTheOpenDatasetTabOverItselfSplitsItWithTheAgent() async throws {
        let rig = try await make(tabs: 1)
        defer { Task { await cleanup(rig) } }
        rig.model.contentSize = CGSize(width: 1400, height: 800)
        let agentTab = try #require(rig.model.activeTabID)
        let agent = try #require(rig.model.activeTab?.layout.terminalIDs.first)
        _ = rig.model.openDataset("DS1")
        let datasetTab = try #require(rig.model.activeTabID)
        #expect(datasetTab != agentTab)
        // Na tab do books, arrastar a própria tab para a direita: o agente fica à esquerda e a tabela à direita, numa tab só.
        #expect(rig.model.evaluateSelfDrop(datasetTab, zone: .right) == .applied)
        #expect(rig.model.performSelfDrop(datasetTab, zone: .right) == .applied)
        #expect(rig.model.tabs.map(\.id) == [agentTab] && rig.model.activeTabID == agentTab)
        guard case .split(let axis, _, let first, let second)? = rig.model.activeTab?.layout else { Issue.record("expected split"); return }
        #expect(axis == .horizontal && first.terminalIDs == [agent] && second.datasetIDs == ["DS1"])
    }

    @Test func theMostRecentOtherTabIsThePartner() async throws {
        let rig = try await make(tabs: 3)
        defer { Task { await cleanup(rig) } }
        rig.model.contentSize = CGSize(width: 1200, height: 700)
        let tabs = rig.model.tabs
        rig.model.selectTab(tabs[2].id)
        rig.model.selectTab(tabs[0].id)
        #expect(rig.model.selfDropPartner(of: tabs[0].id)?.id == tabs[2].id)
        #expect(rig.model.performSelfDrop(tabs[0].id, zone: .right) == .applied)
        #expect(rig.model.tabs.map(\.id) == [tabs[1].id, tabs[2].id])
        #expect(rig.model.activeTabID == tabs[2].id)
    }

    @Test func selfDropWithoutPartnerCenterOrNonActiveTabIsANoOp() async throws {
        let single = try await make(tabs: 1)
        defer { Task { await cleanup(single) } }
        single.model.contentSize = CGSize(width: 1200, height: 700)
        let only = single.model.tabs[0]
        #expect(single.model.selfDropPartner(of: only.id) == nil)
        #expect(single.model.evaluateSelfDrop(only.id, zone: .right) == .invalid)
        #expect(single.model.performSelfDrop(only.id, zone: .right) == .invalid)
        #expect(single.model.tabs.map(\.id) == [only.id])
        #expect(single.model.tabs[0].layout == only.layout)

        let rig = try await make(tabs: 2)
        defer { Task { await cleanup(rig) } }
        rig.model.contentSize = CGSize(width: 1200, height: 700)
        let before = rig.model.tabs
        #expect(rig.model.performSelfDrop(before[0].id, zone: .center) == .invalid, "centro cancela")
        #expect(rig.model.performSelfDrop(before[1].id, zone: .right) == .invalid, "só a tab ativa")
        #expect(rig.model.tabs.map(\.id) == before.map(\.id))
        #expect(rig.model.tabs.map(\.layout) == before.map(\.layout))
        #expect(rig.model.activeTabID == before[0].id)
    }

    @Test func cancellingASelfTabDragChangesNothing() async throws {
        let rig = try await make(tabs: 2)
        defer { Task { await cleanup(rig) } }
        rig.model.contentSize = CGSize(width: 1200, height: 700)
        let before = rig.model.tabs
        let drag = rig.model.dragController
        drag.begin(.tab(before[0].id), title: "t", from: .zero, at: .zero, window: nil, owner: nil)
        drag.cancel()
        #expect(drag.session == nil)
        #expect(rig.model.tabs.map(\.layout) == before.map(\.layout))
        #expect(rig.model.activeTabID == before[0].id)
    }

    @Test func selfDropMovesEveryPaneOfASplitTab() async throws {
        let rig = try await make(tabs: 2)
        defer { Task { await cleanup(rig) } }
        rig.model.contentSize = CGSize(width: 1600, height: 900)
        let tabs = rig.model.tabs
        guard case .created(let extra) = rig.model.split(.horizontal, source: tabs[0].layout.terminalIDs[0]) else { Issue.record("split"); return }
        let moving = Set(rig.model.tab(tabs[0].id)?.layout.terminalIDs ?? [])
        #expect(moving.contains(extra))
        #expect(rig.model.performSelfDrop(tabs[0].id, zone: .bottom) == .applied)
        let result = try #require(rig.model.activeTab)
        #expect(result.id == tabs[1].id)
        #expect(Set(result.layout.terminalIDs) == moving.union(tabs[1].layout.terminalIDs))
        for id in moving { #expect(rig.model.terminal(id)?.tabID == tabs[1].id) }
    }
}
