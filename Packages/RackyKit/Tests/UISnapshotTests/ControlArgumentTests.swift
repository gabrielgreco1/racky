import AppKit
import RackyProtocol
import SwiftUI
import Testing

@testable import RackyUI

/// Bug do dono (2026-10-26): o "+" da linha do projeto não criava sessão. O botão de ícone não tinha argumento, mandava só `press`, o
/// handler falhava com "Project not found" e o botão engolia o erro. Agora o botão de ícone leva o alvo e toda falha de clique vira aviso.
@MainActor
@Suite(.serialized, .offscreenAppKit) struct ControlArgumentTests {
    @Test func iconButtonCarriesItsTarget() async throws {
        let store = UIElementStore()
        let registry = ActionRegistry(flags: SliceFlags(current: .slice4), surface: FakeSurface())
        let id = UUID().uuidString
        let view = DSIconButton(.projectNewSession, id: .sidebarProjectNewSession(id), symbol: "plus", name: "New Session", variant: .row, argument: .select(id))
            .environment(\.actionRegistry, registry).environment(\.elementStore, store).frame(width: 40, height: 40)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let node = try #require(store.snapshot(root: .sidebarProjectNewSession(id)).roots.first)
        #expect(node.action == .projectNewSession && node.argument == .select(id))
    }

    @Test func aFailedClickIsReportedNotSwallowed() async throws {
        let registry = ActionRegistry(flags: SliceFlags(current: .slice4), surface: FakeSurface())
        try registry.register(.projectNewSession) { arg in
            guard arg.kind == .select else { throw ActionError.failed(.projectNewSession, message: "Project not found") }
            return "opened"
        }
        var reported: [(ActionID, String)] = []
        registry.onUIFailure = { reported.append(($0, $1)) }
        await registry.performFromUI(.projectNewSession, .press)
        #expect(reported.count == 1 && reported.first?.1 == "Project not found")
        await registry.performFromUI(.projectNewSession, .select(UUID().uuidString))
        #expect(reported.count == 1, "um clique que deu certo não avisa nada")
    }
}
