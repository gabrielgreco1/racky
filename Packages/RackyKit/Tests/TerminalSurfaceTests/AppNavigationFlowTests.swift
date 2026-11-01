import RackyCore
import RackyProtocol
import AppKit
import Foundation
import Testing

@testable import RackyUI

/// F25: ir e voltar entre sessão, terminal, viewer, Computers e Inbox no app montado de verdade (daemon real, sem abrir o app).
@MainActor
@Suite(.serialized, .tags(.integration), .timeLimit(.minutes(4))) struct AppNavigationFlowTests {
    typealias Rig = AppKeyboardFlowTests.Rig

    static func addComputer(_ rig: Rig, _ name: String) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("abx-nav-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let computer = try ManagedComputer(name: name, display: .headless, run: RunFolder(root: folder), backend: FocusFlowBackend())
        await rig.env.computers.add(computer)
        return folder
    }

    @Test func viewerHasABackButtonAndEscAndCmdWReturnToTheSession() async throws {
        try await AppKeyboardFlowTests.withApp { rig in
            let folder = try await Self.addComputer(rig, "nav-a")
            defer { try? FileManager.default.removeItem(at: folder) }
            let title = rig.env.sidebar.selectedSession.flatMap { rig.env.sidebar.session($0)?.title } ?? ""

            rig.env.computers.openViewer("nav-a")
            try await eventually("viewer back button in the tree", timeout: .seconds(5)) {
                rig.env.elements.snapshot().find(.viewerBack("nav-a")) != nil
            }
            let node = rig.env.elements.snapshot().find(.viewerBack("nav-a"))
            #expect(node?.enabled == true)
            #expect(node?.action == .pageClose)
            #expect(!title.isEmpty)

            // O botão dispara `page.close` pelo registro.
            _ = try await rig.env.registry.perform(.pageClose, .press)
            #expect(rig.env.computers.page == .workspace)
            try await AppKeyboardFlowTests.assertTyping("back button", rig)

            // Esc.
            rig.env.computers.openViewer("nav-a")
            await AppKeyboardFlowTests.settle(300)
            AppKeyboardFlowTests.escape(rig)
            await AppKeyboardFlowTests.settle(300)
            #expect(rig.env.computers.page == .workspace)
            try await AppKeyboardFlowTests.assertTyping("esc from the viewer", rig)

            // ⌘W (a ação de fechar pane/tab vira "fechar página" com o viewer aberto e não fecha o terminal).
            let tabs = rig.env.workspace.tabs.count
            rig.env.computers.openViewer("nav-a")
            await AppKeyboardFlowTests.settle(300)
            _ = try await rig.env.registry.perform(.paneClose, .press)
            #expect(rig.env.computers.page == .workspace)
            #expect(rig.env.workspace.tabs.count == tabs, "⌘W no viewer não fecha a tab")
            try await AppKeyboardFlowTests.assertTyping("cmd-w from the viewer", rig)
        }
    }

    @Test func clickingASessionOrTerminalAlwaysShowsThatTerminal() async throws {
        try await AppKeyboardFlowTests.withApp { rig in
            let folder = try await Self.addComputer(rig, "nav-b")
            defer { try? FileManager.default.removeItem(at: folder) }
            guard let session = rig.env.sidebar.selectedSession, let terminal = rig.terminalID else { Issue.record("no session"); return }
            rig.env.computers.openViewer("nav-b")
            await AppKeyboardFlowTests.settle(300)
            // Clicar na sessão já selecionada (sidebar) com o viewer aberto mostra o terminal.
            #expect(rig.env.sidebar.select(session))
            #expect(rig.env.computers.page == .workspace)
            try await AppKeyboardFlowTests.assertTyping("session click over viewer", rig, strictResponder: false)
            // Computers e depois o terminal (linha do agente / tab) pelo `pane.show`.
            rig.env.computers.show(.computers)
            await AppKeyboardFlowTests.settle(200)
            _ = try await rig.env.registry.perform(.paneShow, .select(terminal.uuidString))
            #expect(rig.env.computers.page == .workspace)
            try await AppKeyboardFlowTests.assertTyping("pane.show over computers", rig)
        }
    }

    @Test func historyArrowsWalkSessionTerminalViewerComputersAndInbox() async throws {
        try await AppKeyboardFlowTests.withApp { rig in
            let folder = try await Self.addComputer(rig, "nav-c")
            defer { try? FileManager.default.removeItem(at: folder) }
            let env = rig.env
            guard let session = env.sidebar.selectedSession, let first = rig.terminalID else { Issue.record("no session"); return }
            // Dois terminais: o do começo e um segundo numa tab nova.
            _ = env.workspace.newTab(provider: .shell)
            try await AppKeyboardFlowTests.waitForTabs(rig, 2)
            try await AppKeyboardFlowTests.waitTerminalRunning(rig)
            guard let second = rig.terminalID, second != first else { Issue.record("no second terminal"); return }
            env.computers.openViewer("nav-c")
            await AppKeyboardFlowTests.settle(200)
            env.computers.show(.computers)
            await AppKeyboardFlowTests.settle(200)
            #expect(env.shell.canGoBack)
            #expect(!env.shell.canGoForward)
            #expect(env.navigation.current == .computers)

            // ← ← ← ←: computers → viewer → terminal 2 → terminal 1.
            _ = try await env.registry.perform(.navBack, .press)
            #expect(env.computers.page == .viewer("nav-c"))
            _ = try await env.registry.perform(.navBack, .press)
            #expect(env.computers.page == .workspace && env.workspace.focusedTerminalID == second)
            try await AppKeyboardFlowTests.assertTyping("back to terminal 2", rig)
            _ = try await env.registry.perform(.navBack, .press)
            #expect(env.computers.page == .workspace && env.workspace.focusedTerminalID == first)
            try await AppKeyboardFlowTests.assertTyping("back to terminal 1", rig)
            #expect(!env.shell.canGoBack || env.navigation.index == 0, "entries=\(env.navigation.entries) index=\(env.navigation.index)")
            #expect(env.shell.canGoForward)

            // → → →: volta a terminal 2, viewer, computers; chegou ao fim.
            _ = try await env.registry.perform(.navForward, .press)
            #expect(env.workspace.focusedTerminalID == second)
            _ = try await env.registry.perform(.navForward, .press)
            #expect(env.computers.page == .viewer("nav-c"))
            _ = try await env.registry.perform(.navForward, .press)
            #expect(env.computers.page == .computers)
            #expect(!env.shell.canGoForward)

            // Navegar a partir do meio descarta o futuro.
            _ = try await env.registry.perform(.navBack, .press)
            #expect(env.sidebar.select(session))
            #expect(!env.shell.canGoForward)

            // Inbox entra no histórico (Fatia 2 ligada no app de uso).
            if env.attention != nil {
                env.sidebar.setInbox(open: true)
                #expect(env.navigation.current == .inbox)
                _ = try await env.registry.perform(.navBack, .press)
                #expect(!env.sidebar.inboxOpen)
            }
            try await AppKeyboardFlowTests.assertTyping("after history walk", rig)
        }
    }
}

@MainActor
@Suite struct NavigationHistoryTests {
    @Test func recordsDedupesAndTruncatesTheFuture() {
        var h = NavigationHistory()
        let a = UUID(), b = UUID()
        h.record(.session(a)); h.record(.session(a)); h.record(.viewer("x")); h.record(.computers)
        #expect(h.entries.count == 3 && h.canGoBack && !h.canGoForward)
        #expect(h.move(-1, isValid: { _ in true }) == .viewer("x"))
        #expect(h.canGoForward)
        h.record(.session(b))
        #expect(h.entries == [.session(a), .viewer("x"), .session(b)])
    }

    @Test func skipsDestinationsThatNoLongerExist() {
        var h = NavigationHistory()
        let a = UUID()
        h.record(.session(a)); h.record(.viewer("gone")); h.record(.computers)
        #expect(h.move(-1, isValid: { $0 != .viewer("gone") }) == .session(a))
        #expect(h.move(-1, isValid: { _ in true }) == nil)
        #expect(!h.canMove(-1, isValid: { _ in true }))
    }
}
