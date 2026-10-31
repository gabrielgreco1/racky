import RackyCore
import RackyProtocol
import AppKit
import Foundation
import SwiftUI
import Testing

@testable import RackyUI

/// Digitação de ponta a ponta com o `rackyd` real: `NSEvent.keyEvent` real entregue por `NSWindow.sendEvent` e os bytes
/// contados pelo daemon (`inputBytesByOrigin[.key]`). Cobre o congelamento do terminal depois do onboarding/overlay, de
/// foco roubado pela chrome (tab row, sidebar) e de um arrasto de tab cancelado.
@MainActor
@Suite(.serialized, .tags(.integration), .timeLimit(.minutes(1))) struct TypingFocusTests {
    private struct Rig {
        let client: PTYClient
        let host: TerminalHostView
        let chrome: ChromeHostingView
        let window: RackyWindow
        let session: SessionID
    }

    private func withRig(_ body: (Rig) async throws -> Void) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)  // sem Dock nem janela visível
        let harness = try DaemonHarness()
        try await harness.start()
        let client = harness.makeClient()
        var binding: TerminalSessionBinding?
        do {
            try await client.start()
            let host = TerminalHostView(terminalID: "typing-1")
            let chrome = ChromeHostingView(content: Button("Tab") {}.frame(width: 200, height: 30))
            let size = NSSize(width: 800, height: 530)
            let window = RackyWindow(
                contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let content = NSView(frame: NSRect(origin: .zero, size: size))
            chrome.frame = NSRect(x: 0, y: 500, width: 200, height: 30)
            host.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
            content.addSubview(host)
            content.addSubview(chrome)
            window.contentView = content
            content.layoutSubtreeIfNeeded()
            let dims = host.surface.terminalDimensions
            var create = makeCreate(["/bin/zsh", "-f", "-i"], cols: UInt16(dims.cols), rows: UInt16(dims.rows), env: ["PROMPT": "%# ", "RPROMPT": ""])
            create.cwd = NSTemporaryDirectory()
            let created = try await client.create(create)
            let b = TerminalSessionBinding(client: client, sessionID: created.session.sessionID, host: host)
            binding = b
            try await b.start()
            try await body(Rig(client: client, host: host, chrome: chrome, window: window, session: created.session.sessionID))
        } catch {
            binding?.stop()
            await client.stop()
            await harness.stop()
            throw error
        }
        binding?.stop()
        await client.stop()
        await harness.stop()
    }

    private func keyBytes(_ rig: Rig) async throws -> UInt64 {
        let sessions = try await rig.client.list()
        return sessions.first { $0.sessionID == rig.session }?.inputBytesByOrigin[.key] ?? 0
    }

    private func waitPrompt(_ rig: Rig) async throws {
        try await eventually("prompt") { String(decoding: rig.host.surface.getBufferAsData(kind: .active), as: UTF8.self).contains("% ") }
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in rig: Rig) {
        let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: rig.window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)!
        rig.window.sendEvent(event)
    }

    /// Digita pelo `NSWindow.sendEvent` e espera o daemon contar o byte; `false` se nada chegou.
    private func typed(_ character: String, in rig: Rig) async throws -> Bool {
        let before = try await keyBytes(rig)
        rig.window.sendEvent(keyEvent(keyCode: 0, characters: character, modifiers: [], window: rig.window))
        do {
            try await eventually("daemon counts the key", timeout: .seconds(2)) { try await keyBytes(rig) > before }
            return true
        } catch { return false }
    }

    @Test func keyDownReachesTheDaemonThroughTheWindow() async throws {
        try await withRig { rig in
            try await waitPrompt(rig)
            rig.window.makeFirstResponder(rig.host.surface)
            #expect(try await typed("a", in: rig))
        }
    }

    @Test func clickingTheTerminalRestoresFocusAfterChromeStoleIt() async throws {
        try await withRig { rig in
            try await waitPrompt(rig)
            rig.window.makeFirstResponder(rig.chrome)
            #expect(rig.window.firstResponder === rig.chrome)
            // Arrasto de tab cancelado dentro da própria row: down, drag, up.
            mouse(.leftMouseDown, at: NSPoint(x: 20, y: 515), in: rig)
            mouse(.leftMouseDragged, at: NSPoint(x: 60, y: 515), in: rig)
            mouse(.leftMouseUp, at: NSPoint(x: 20, y: 515), in: rig)
            // Um clique real no pane sempre devolve a superfície como first responder.
            // O teste não roda como app ativo (a janela não vira key e `sendEvent` só "ativaria"): entrega o clique à view
            // sob o ponteiro, que é o caminho do AppKit para o `mouseDown` (a subview Metal repassa pela cadeia).
            let point = NSPoint(x: 300, y: 250)
            let hit = try #require(rig.window.contentView?.hitTest(point))
            let down = NSEvent.mouseEvent(
                with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: rig.window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            hit.mouseDown(with: down)
            let up = NSEvent.mouseEvent(
                with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0, windowNumber: rig.window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            hit.mouseUp(with: up)
            #expect(rig.window.firstResponder === rig.host.surface)
            #expect(try await typed("b", in: rig))
        }
    }

    @Test func keyThatNothingHandlesIsRoutedToTheTerminal() async throws {
        try await withRig { rig in
            try await waitPrompt(rig)
            rig.window.onUnhandledKey = { [host = rig.host] event in
                host.focusTerminal()
                host.surface.keyDown(with: event)
                return true
            }
            rig.window.makeFirstResponder(nil)
            #expect(try await typed("c", in: rig))
            #expect(rig.window.firstResponder === rig.host.surface)
        }
    }

    @Test func closingTheFirstLaunchOverlayLeavesTheTerminalTyping() async throws {
        try await withRig { rig in
            try await waitPrompt(rig)
            // Primeira abertura: nada útil tem o foco quando o onboarding abre.
            rig.window.makeFirstResponder(nil)
            let router = OverlayRouter()
            let coordinator = OverlayFocusCoordinator()
            coordinator.window = rig.window
            coordinator.hostView = rig.chrome  // no lugar do host do overlay
            coordinator.fallbackFocus = { [host = rig.host] in host.focusTerminal() }
            router.focus = coordinator
            router.present(OverlaySpec(name: "onboarding", id: .windowMain, content: { AnyView(EmptyView()) }))
            #expect(router.blocksTerminalInput)
            router.dismiss(.action)
            #expect(router.blocksTerminalInput == false)
            #expect(rig.window.firstResponder === rig.host.surface)
            #expect(try await typed("d", in: rig))
        }
    }
}
