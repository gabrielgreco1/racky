import RackyDesignSystem
import RackyProtocol
import AppKit
import SwiftUI
import Testing

@testable import RackyUI

@MainActor
@Suite(.offscreenAppKit) struct UIElementStoreTests {
    @Test func snapshotBuildsHierarchyFromParentLinks() {
        let store = UIElementStore()
        let a = UUID(), b = UUID(), c = UUID()
        store.register(a, id: .windowMain, kind: "window", label: nil, value: nil, action: nil, parent: nil)
        store.register(b, id: .windowTitlebar, kind: "container", label: nil, value: nil, action: nil, parent: .windowMain)
        store.register(c, id: .windowAppName, kind: "text", label: "Racky", value: nil, action: nil, parent: .windowTitlebar)
        store.updateFrame(c, CGRect(x: 1, y: 2, width: 30, height: 10))
        let tree = store.snapshot()
        #expect(tree.roots.map(\.id) == [.windowMain])
        #expect(tree.find(.windowAppName)?.label == "Racky")
        #expect(tree.find(.windowAppName)?.frame == UIFrame(x: 1, y: 2, width: 30, height: 10))
        #expect(tree.roots[0].children[0].children[0].id == .windowAppName)
        #expect(store.snapshot(root: .windowTitlebar).roots.first?.children.first?.id == .windowAppName)
        #expect(store.snapshot(root: .sidebar).roots.isEmpty)
    }

    @Test func unregisterRemovesTheElement() {
        let store = UIElementStore()
        let t = UUID()
        store.register(t, id: .windowMain, kind: "window", label: nil, value: nil, action: nil, parent: nil)
        store.unregister(t)
        #expect(store.snapshot().roots.isEmpty)
    }

    @Test func duplicateIDsAreDetected() {
        let store = UIElementStore()
        store.register(UUID(), id: .tabsNew, kind: "button", label: nil, value: nil, action: nil, parent: nil)
        store.register(UUID(), id: .tabsNew, kind: "button", label: nil, value: nil, action: nil, parent: nil)
        #expect(store.duplicateIDs == [.tabsNew])
    }

    @Test func orphanParentBecomesRoot() {
        let store = UIElementStore()
        store.register(UUID(), id: .windowAppName, kind: "text", label: nil, value: nil, action: nil, parent: .windowTitlebar)
        #expect(store.snapshot().roots.map(\.id) == [.windowAppName])
    }

    @Test func controlStateComesFromTheActionEnablement() {
        let store = UIElementStore()
        store.enablement = { $0 == .tabNewAgent ? .disabled(reason: "Select a session first.") : .enabled }
        store.register(UUID(), id: .tabsNew, kind: "button", label: "New Tab", value: nil, action: .tabNewAgent, parent: nil)
        let node = store.snapshot().find(.tabsNew)
        #expect(node?.enabled == false)
        #expect(node?.disabledReason == "Select a session first.")
        #expect(node?.action == .tabNewAgent)
    }
}

/// A janela vazia lista os controles pelo registro (T1-02: "ctl ui tree lista a janela vazia").
@MainActor
@Suite(.offscreenAppKit) struct EmptyWindowTreeTests {
    static func host(_ env: AppEnvironment, size: NSSize = NSSize(width: 760, height: 480)) async -> MainWindowController {
        NSApplication.shared.setActivationPolicy(.accessory)  // testes nunca ativam nem mostram o app
        MainWindowController.invisibleForTests = true
        let controller = MainWindowController(env: env, autosaveName: nil)
        let window = controller.window!
        window.setContentSize(size)
        controller.orderingEnabled = false  // nunca ordenada: nada na tela do dono, sem ativar o app nem roubar foco
        controller.present(activate: false)
        window.contentView?.layoutSubtreeIfNeeded()
        for _ in 0..<80 {
            try? await Task.sleep(for: .milliseconds(25))
            if env.elements.snapshot().find(.windowAppName)?.frame != nil { break }
        }
        return controller
    }

    @Test func windowListsItsCanonicalControls() async {
        let env = AppEnvironment(environment: [:])
        let controller = await Self.host(env)
        defer { controller.window?.close() }
        let tree = await env.registry.uiTree(root: nil)
        #expect(tree.roots.map(\.id) == [.windowMain])
        let ids: [A11yID] = [.windowMain, .windowTitlebar, .windowAppName, .windowSidebarToggle, .windowHistoryBack, .windowHistoryForward, .sidebar, .landing]
        for id in ids {
            #expect(tree.find(id) != nil, "\(id.rawValue) deveria estar na árvore")
        }
        #expect(tree.find(.windowAutomationBadge) == nil, "o selo só aparece com a automação ligada")
        #expect(tree.window?.width == 760)
        for node in tree.flattened() { #expect(A11yID.isCanonical(node.id.rawValue)) }
        #expect(env.elements.duplicateIDs.isEmpty)
    }

    /// T4-01: a status bar (24 pt) fica no rodapé da janela e some com `view.toggleStatusBar`; o split ocupa o resto.
    @Test func statusBarSitsAtTheBottomAndFollowsTheToggle() async throws {
        let env = AppEnvironment(environment: [:])
        let controller = await Self.host(env)
        defer { controller.window?.close() }
        let bar = try #require(env.elements.snapshot().find(.statusBar)?.frame)
        let window = try #require(controller.window?.contentView?.bounds)
        #expect(bar.height == DS.Layout.statusBarHeight && abs(bar.y + bar.height - window.height) < 1 && bar.width == window.width)
        #expect(controller.splitView.window != nil && controller.splitView.superview?.frame.height == window.height - DS.Layout.statusBarHeight)
        _ = try await env.registry.perform(.viewToggleStatusBar, .press)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        #expect(controller.splitView.superview?.frame.height == window.height)
        _ = try await env.registry.perform(.viewToggleStatusBar, .press)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        #expect(controller.splitView.superview?.frame.height == window.height - DS.Layout.statusBarHeight)
    }

    @Test func historyControlsAreDisabledWithAReason() async {
        let env = AppEnvironment(environment: [:])
        let controller = await Self.host(env)
        defer { controller.window?.close() }
        let tree = await env.registry.uiTree(root: nil)
        #expect(tree.find(.windowHistoryBack)?.enabled == false)
        #expect(tree.find(.windowHistoryBack)?.disabledReason == "No earlier page")
        #expect(tree.find(.windowHistoryForward)?.disabledReason == "No later page")
        #expect(tree.find(.windowSidebarToggle)?.enabled == true)
    }

    @Test func automationBadgeAppearsOnlyWhenAutomationIsOn() async {
        let sock = FileManager.default.temporaryDirectory.appendingPathComponent("abx-\(UUID().uuidString.prefix(8))/app.sock").path
        let env = AppEnvironment(environment: ["RACKY_AUTOMATION": "1", "RACKY_APP_SOCK": sock])
        let controller = await Self.host(env)
        defer { controller.window?.close() }
        let tree = await env.registry.uiTree(root: nil)
        #expect(tree.find(.windowAutomationBadge) != nil)
        await env.stop()
    }

    @Test func hideAppNameActionRemovesTheLabelFromTheTree() async throws {
        let env = AppEnvironment(environment: [:])
        let controller = await Self.host(env)
        defer { controller.window?.close() }
        let result = try await env.registry.perform(.appHideAppName, .press)
        #expect(result.message == "hidden")
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(25))
            if env.elements.snapshot().find(.windowAppName) == nil { break }
        }
        #expect(await env.registry.uiTree(root: nil).find(.windowAppName) == nil)
        #expect(await env.registry.appState().registeredActions.contains(.appHideAppName))
    }

    @Test func futureSliceActionsAreNotRegisteredNorRendered() async {
        let env = AppEnvironment(environment: ["RACKY_SLICE": "1"])
        #expect(env.registry.availability(of: .viewToggleRightPanel) == .unavailable(.slice2))
        #expect(!env.registry.isRendered(.pageInbox))
    }

    /// F13: sem `RACKY_SLICE` o app liga tudo o que as Fatias 1 a 3 já implementam; o gating fica só para controles sem handler.
    @Test func defaultLaunchEnablesDeliveredSlicesAndGatesOnlyControlsWithoutHandler() async {
        let env = AppEnvironment(environment: [:])
        #expect(env.flags.current == .slice3 && !env.flags.restricted)
        #expect(env.attention != nil, "Slice 2 attention is on")
        #expect(env.registry.isRendered(.pageInbox) && env.registry.isRendered(.sessionSetSubagentComputers))
        #expect(env.registry.availability(of: .sessionSetSubagentComputers).isEnabled || env.registry.availability(of: .sessionSetSubagentComputers) != .unavailable(.slice3))
        // Fatia 4 e v1.1 seguem escondidas; controle sem handler de Fatia 3 não vira botão morto.
        #expect(!env.registry.isRendered(.computerNew))
    }
}
