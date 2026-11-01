import RackyDesignSystem
import RackyProtocol
import RackyStore
import AppKit
import Foundation
import Testing

@testable import RackyUI

/// Tabs e panes ligados ao Store real (T1-14): split, fechar, foco, rename, reordenar, reabrir e persistência do layout.
@MainActor
@Suite(.serialized, .tags(.integration), .timeLimit(.minutes(1)), .offscreenAppKit) struct WorkspaceModelTests {
    struct Rig {
        let env: AppEnvironment
        let store: RackyStore
        let session: Session
        let root: URL
        var model: WorkspaceModel { env.workspace }
    }

    func make(tabs: Int = 1, profileID: UUID? = nil) async throws -> Rig {
        let root = URL(fileURLWithPath: "/tmp/abw-\(UInt32.random(in: 0 ... 0xFFFFFF))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let env = AppEnvironment(environment: ["RACKY_HOME": root.path])
        await env.start()
        let store = try #require(env.workspace.store)
        var session = Session(kind: .clean, folderPath: root.path, title: "demo")
        session.managedFolder = true
        try await store.save(session)
        for i in 0 ..< tabs {
            let tabID = UUID.v7(), termID = UUID.v7()
            let terminal = Terminal(id: termID, tabID: tabID, provider: .shell, title: "zsh\(i)", cwd: root.path, launchSpec: LaunchSpec(provider: .shell, profileID: profileID))
            let tab = Tab(id: tabID, sessionID: session.id, title: "zsh\(i)", sortIndex: i, layout: .leaf(Pane(content: .terminal(termID))), focusedTerminalID: termID)
            try await store.save(tab)
            try await store.save(terminal)
        }
        let rig = Rig(env: env, store: store, session: session, root: root)
        for _ in 0 ..< 100 where rig.env.sidebar.session(session.id) == nil { try await Task.sleep(for: .milliseconds(20)) }
        rig.env.sidebar.select(session.id)
        for _ in 0 ..< 100 where !rig.model.isLoaded { try await Task.sleep(for: .milliseconds(20)) }
        for _ in 0 ..< 100 where rig.model.terminalsInCurrentSession.count < tabs { try await Task.sleep(for: .milliseconds(20)) }
        #expect(rig.model.isLoaded)
        return rig
    }

    func cleanup(_ rig: Rig) async {
        await rig.model.settlePersistence()
        try? await rig.store.close()
        try? FileManager.default.removeItem(at: rig.root)
    }

    @Test func splitCreatesAPaneWithTheSameAgentAndFocusesIt() async throws {
        let rig = try await make()
        defer { Task { await cleanup(rig) } }
        let first = try #require(rig.model.focusedTerminalID)
        guard case .created(let second) = rig.model.split(.horizontal) else { Issue.record("split failed"); return }
        #expect(rig.model.focusedTerminalID == second)
        #expect(rig.model.activeTab?.layout.leafCount == 2)
        #expect(rig.model.terminal(second)?.provider == .shell)
        #expect(rig.model.terminal(second)?.cwd == rig.root.path)
        await rig.model.settlePersistence()
        let stored = try #require(try await rig.store.tab(id: rig.model.activeTabID!))
        #expect(stored.layout.terminalIDs == [first, second])
        #expect(stored.focusedTerminalID == second)
        #expect(try await rig.store.terminal(id: second) != nil)
    }

    /// Regressão: o spec de um terminal lançado guarda o ID do perfil embutido (fora da tabela `launch_profile`); o split não pode violar a FK.
    @Test func splitOfATerminalLaunchedWithABuiltinProfileIsPersisted() async throws {
        let builtin = try #require(UUID(uuidString: "A0000000-0000-4000-8000-000000000005"))
        let rig = try await make(profileID: builtin)
        defer { Task { await cleanup(rig) } }
        guard case .created(let second) = rig.model.split(.horizontal) else { Issue.record("split failed"); return }
        await rig.model.settlePersistence()
        let stored = try #require(try await rig.store.terminal(id: second))
        #expect(stored.profileID == nil)
        #expect(stored.launchSpec.profileID == builtin)
    }

    @Test func splitsAreUnlimitedAndRefusedOnlyBelowTheMinimumSize() async throws {
        let rig = try await make()
        defer { Task { await cleanup(rig) } }
        for _ in 0 ..< 8 { _ = rig.model.split(.horizontal) }
        #expect(rig.model.activeTab?.layout.leafCount == 9)
        rig.model.contentSize = CGSize(width: 400, height: 300)
        let small = try #require(rig.model.activeTab)
        let before = small.layout.leafCount
        #expect(rig.model.split(.horizontal) == .noRoom)
        #expect(rig.model.activeTab?.layout.leafCount == before)
    }

    @Test func closingPanesAndTheLastTabKeepsTheSession() async throws {
        let rig = try await make()
        defer { Task { await cleanup(rig) } }
        let first = try #require(rig.model.focusedTerminalID)
        guard case .created(let second) = rig.model.split(.vertical) else { return }
        rig.model.closePane(second)
        for _ in 0 ..< 100 where rig.model.activeTab?.layout.leafCount != 1 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(rig.model.activeTab?.layout.terminalIDs == [first])
        #expect(rig.model.focusedTerminalID == first)
        rig.model.closePane(first)
        for _ in 0 ..< 100 where !rig.model.tabs.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(rig.model.tabs.isEmpty)
        #expect(rig.model.isLoaded, "a sessão continua; só a janela nunca fecha por ⌘W")
        await rig.model.settlePersistence()
        #expect(try await rig.store.tabs(sessionID: rig.session.id).isEmpty)
        #expect(try await rig.store.tabs(sessionID: rig.session.id, includeClosed: true).count == 1)
    }

    @Test func nextAndPreviousPaneMoveFocus() async throws {
        let rig = try await make()
        defer { Task { await cleanup(rig) } }
        let a = try #require(rig.model.focusedTerminalID)
        guard case .created(let b) = rig.model.split(.horizontal) else { return }
        #expect(rig.model.focusNextPane(delta: 1))
        #expect(rig.model.focusedTerminalID == a)
        #expect(rig.model.focusNextPane(delta: -1))
        #expect(rig.model.focusedTerminalID == b)
    }

    @Test func dividerDragWritesAtMostTwiceAndKeepsTheFinalRatio() async throws {
        let rig = try await make()
        defer { Task { await cleanup(rig) } }
        rig.model.contentSize = CGSize(width: 1200, height: 800)
        _ = rig.model.split(.horizontal)
        await rig.model.settlePersistence()
        let before = await rig.store.debouncedWriteCount
        for i in 0 ..< 60 {
            rig.model.setRatio(at: SplitPath(), ratio: 0.3 + Double(i) * 0.005, final: false)
            try await Task.sleep(for: .milliseconds(5))
        }
        rig.model.setRatio(at: SplitPath(), ratio: 0.62, final: true)
        try await Task.sleep(for: .milliseconds(500))
        await rig.model.settlePersistence()
        let writes = await rig.store.debouncedWriteCount - before
        #expect(writes <= 2, "writes: \(writes)")
        let stored = try #require(try await rig.store.tab(id: rig.model.activeTabID!))
        guard case .split(_, let ratio, _, _) = stored.layout else { Issue.record("expected split"); return }
        #expect(abs(ratio - 0.62) < 0.02)
    }

    @Test func renameLocksTheTitleAndEmptyRestoresTheDynamicOne() async throws {
        let rig = try await make()
        defer { Task { await cleanup(rig) } }
        let tab = try #require(rig.model.activeTab)
        #expect(rig.model.beginRename(tab.id))
        rig.model.commitRename("  Build  ")
        #expect(rig.model.displayTitle(of: try #require(rig.model.activeTab)) == "Build")
        #expect(rig.model.activeTab?.titleLocked == true)
        _ = rig.model.beginRename(tab.id)
        rig.model.commitRename("")
        #expect(rig.model.activeTab?.titleLocked == false)
        #expect(rig.model.displayTitle(of: try #require(rig.model.activeTab)) == "zsh0")
    }

    @Test func reorderingTabsPersistsTheOrder() async throws {
        let rig = try await make(tabs: 3)
        defer { Task { await cleanup(rig) } }
        let ids = rig.model.tabs.map(\.id)
        rig.model.moveTab(ids[0], to: 2)
        #expect(rig.model.tabs.map(\.id) == [ids[1], ids[2], ids[0]])
        await rig.model.settlePersistence()
        #expect(try await rig.store.tabs(sessionID: rig.session.id).map(\.id) == [ids[1], ids[2], ids[0]])
    }

    @Test func tabNavigationAndRecent() async throws {
        let rig = try await make(tabs: 3)
        defer { Task { await cleanup(rig) } }
        let ids = rig.model.tabs.map(\.id)
        rig.model.selectTab(ids[0])
        rig.model.selectTab(delta: 1)
        #expect(rig.model.activeTabID == ids[1])
        rig.model.selectTab(delta: -2)
        #expect(rig.model.activeTabID == ids[2], "volta ao fim")
        rig.model.selectRecentTab()
        #expect(rig.model.activeTabID == ids[1])
        rig.model.selectTab(at: 0)
        #expect(rig.model.activeTabID == ids[0])
    }

    @Test func closedTabCanBeReopened() async throws {
        let rig = try await make(tabs: 2)
        defer { Task { await cleanup(rig) } }
        let closing = try #require(rig.model.activeTab)
        rig.model.closeTab(closing.id)
        for _ in 0 ..< 100 where rig.model.tabs.count != 1 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(rig.model.tabs.count == 1)
        rig.model.reopenClosedTab()
        for _ in 0 ..< 100 where rig.model.tabs.count != 2 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(rig.model.tabs.contains { $0.id == closing.id })
        #expect(rig.model.activeTabID == closing.id)
    }

    @Test func expandHidesTheOthersAndEqualizeResetsRatios() async throws {
        let rig = try await make()
        defer { Task { await cleanup(rig) } }
        let a = try #require(rig.model.focusedTerminalID)
        _ = rig.model.split(.horizontal)
        rig.model.toggleExpand(a)
        let tab = try #require(rig.model.activeTab)
        #expect(rig.model.expandedPane(in: tab) == tab.layout.pane(forTerminal: a)?.id)
        rig.model.toggleExpand(a)
        #expect(rig.model.expandedPane(in: try #require(rig.model.activeTab)) == nil)
        rig.model.setRatio(at: SplitPath(), ratio: 0.8, final: true)
        rig.model.equalize()
        guard case .split(_, let r, _, _) = rig.model.activeTab!.layout else { return }
        #expect(r == 0.5)
    }

    @Test func actionsAreDisabledWithoutASession() async throws {
        let env = AppEnvironment(environment: [:])
        for id in [ActionID.paneSplitRight, .paneClose, .tabNewTerminal] {
            #expect(env.registry.availability(of: id) == .disabled(reason: id == .tabNewTerminal ? "Select a session first." : "Select a session first."))
        }
        #expect(env.registry.availability(of: .paneNext) == .disabled(reason: "Select a session first."))
    }

    @Test func actionsDriveTheModelThroughTheRegistry() async throws {
        let rig = try await make()
        defer { Task { await cleanup(rig) } }
        _ = try await rig.env.registry.perform(.paneSplitRight, .press)
        #expect(rig.model.activeTab?.layout.leafCount == 2)
        _ = try await rig.env.registry.perform(.tabNewTerminal, .press)
        #expect(rig.model.tabs.count == 2)
        #expect(rig.env.registry.availability(of: .paneNext) == .disabled(reason: "Only one pane"))
        _ = try await rig.env.registry.perform(.tabSelect1, .press)
        #expect(rig.model.activeTabID == rig.model.tabs[0].id)
        #expect(rig.env.registry.availability(of: .paneNext) == .enabled)
    }
}

/// Tab row e panes: medidas da spec (03 §3, §4, DS §12.7, §12.23).
@MainActor
@Suite(.offscreenAppKit) struct TabRowConformanceTests {
    @Test func metricsMatchTheSpec() {
        #expect(TabMetrics.rowHeight == 32)
        #expect(TabMetrics.dragStrip == 4)
        #expect(TabMetrics.chromeHeight == DS.Layout.titlebarHeight)
        #expect(TabMetrics.baseWidth == 180 && TabMetrics.wideWidth == 220 && TabMetrics.minWidth == 72)
        #expect(TabMetrics.wideBreakpoint == 1280)
        #expect(TabMetrics.indicatorHeight == 2)
        #expect(TabMetrics.chevron == CGSize(width: 20, height: 24))
        #expect(TabMetrics.fade == 24)
        #expect(PaneMetrics.headerHeight == 24)
        #expect(PaneLayout.dividerThickness == 3)
        #expect(PaneMetrics.dividerHit == 9)
        #expect(PaneLayout.minPaneSize == CGSize(width: 240, height: 120))
    }

    @Test func tabWidthShrinksFromBaseToTheMinimum() {
        let row = TabRowView(model: WorkspaceModel(runtime: TerminalRuntime(
            configuration: .init(daemonHome: URL(fileURLWithPath: "/tmp/x"), daemonExecutable: nil, stopDaemonOnQuit: false, appSocketPath: "", loginEnvironment: { [:] }),
            registry: nil, elements: nil)))
        #expect(row.tabWidth(count: 3, available: 1000, window: 1000) == 180)
        #expect(row.tabWidth(count: 3, available: 1000, window: 1400) == 220)
        #expect(row.tabWidth(count: 10, available: 1000, window: 1000) == 100)
        #expect(row.tabWidth(count: 40, available: 1000, window: 1000) == 72)
    }
}
