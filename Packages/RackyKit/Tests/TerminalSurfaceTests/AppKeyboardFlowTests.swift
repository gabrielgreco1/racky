import RackyCore
import RackyDesignSystem
import RackyProtocol
import AppKit
import Foundation
import SwiftUI
import Testing

@testable import RackyUI

/// Backend mínimo para abrir o viewer sem Docker: lease por ACK, resto vazio, ticket que nunca conecta.
actor FocusFlowBackend: ComputerBackend {
    func runtime(_ operation: String, _ args: JSON, timeout: TimeInterval) async throws -> JSON {
        if operation == "lease" { return ["lease": .string("human"), "ack": .bool(true)] }
        return ["ok": true, "url": "http://aca.example.test/search", "title": "t", "cookies": [], "tabs": []]
    }
    func execRun(_ request: BackendExec, timeout: Duration) async throws -> BackendExecOutcome { BackendExecOutcome() }
    func execStart(_ request: BackendExec) async throws -> String { "job" }
    func execPoll(jobID: String, wait: Duration) async throws -> BackendExecOutcome { BackendExecOutcome() }
    func execCancel(jobID: String) async throws -> BackendExecOutcome { BackendExecOutcome() }
    func ingest(_ payload: JSON) async throws -> String { "id" }
    func switchProxy(to proxy: String, country: String?) async throws -> Int { 0 }
    func proxyInfo() async throws -> JSON { [:] }
    func usage() async throws -> JSON { [:] }
    func render(_ payload: JSON) async throws -> JSON { [:] }
    func vncEndpoint() async throws -> URL { URL(string: "ws://127.0.0.1:1/vnc?ticket=t")! }
}

/// F27 de ponta a ponta, sem abrir o app: `AppEnvironment` + `MainWindowController` reais, `rackyd` real (`--idle-exit 5`),
/// activation policy `.prohibited` e eventos pelo caminho do AppKit. Depois de CADA sequência que abre e fecha algo (Quick
/// Launch, combobox, menu, composer, Settings, viewer, troca de tab) o teste exige first responder = surface do terminal,
/// nenhuma janela-filha key e a tecla digitada chegando ao daemon (bytes contados pelo `rackyd`).
///
/// Com `.prohibited` o app nunca fica ativo e não existe `NSApp.keyWindow`: `NSApp.sendEvent` descarta teclas. Por isso as
/// teclas entram por `NSApp.sendEvent` quando há key window e, sem ela, pelo `NSWindow.sendEvent` da janela principal
/// (o último passo do despacho do AppKit: `performKeyEquivalent` e depois o first responder).
@MainActor
@Suite(.serialized, .tags(.integration), .timeLimit(.minutes(4))) struct AppKeyboardFlowTests {
    final class Rig {
        let env: AppEnvironment
        let controller: MainWindowController
        let window: NSWindow
        let harness: DaemonHarness
        let client: PTYClient
        init(env: AppEnvironment, controller: MainWindowController, window: NSWindow, harness: DaemonHarness, client: PTYClient) {
            self.env = env; self.controller = controller; self.window = window; self.harness = harness; self.client = client
        }

        var surface: TerminalSurfaceView? { env.workspace.focusedHost()?.surface }
        var terminalID: UUID? { env.workspace.focusedTerminalID }
        var ptySession: SessionID? { terminalID.flatMap { env.workspace.terminal($0)?.ptySessionID }.flatMap { SessionID(string: $0) } }
    }

    static func withApp(_ body: (Rig) async throws -> Void) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)  // sem Dock nem janela visível
        TooltipController.orderingEnabled = false
        MainWindowController.invisibleForTests = true
        let harness = try DaemonHarness()
        try await harness.start()
        let env = AppEnvironment(environment: [
            "RACKY_HOME": harness.home.path, "RACKY_DAEMON": rackydBinary().path, "RACKY_SCREEN": AppEnvironment.workspaceDemoFixture,
            "RACKY_SKIP_ONBOARDING": "1", "RACKY_TEST_HEADLESS": "1", "RACKY_LAUNCHD": "0",
        ])
        let controller = MainWindowController(env: env, autosaveName: nil)
        let window = controller.window!
        window.setContentSize(NSSize(width: 1280, height: 800))
        controller.orderingEnabled = false
        controller.present(activate: false)
        window.contentView?.layoutSubtreeIfNeeded()
        let client = harness.makeClient()
        let rig = Rig(env: env, controller: controller, window: window, harness: harness, client: client)
        func teardown() async {
            window.close()
            await env.stop()
            env.shutdownSync()
            await client.stop()
            await harness.stop()
        }
        do {
            await env.start()
            try await client.start()
            window.makeKey()
            try await eventually("terminal running", timeout: .seconds(20)) {
                guard let id = rig.terminalID else { return false }
                return env.workspace.terminal(id)?.state == .running && env.workspace.focusedHost() != nil
            }
            window.contentView?.layoutSubtreeIfNeeded()
            // Como `windowDidBecomeKey` no app real: o terminal do pane focado recebe o foco.
            controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
            try await body(rig)
        } catch {
            await teardown()
            throw error
        }
        await teardown()
    }

    // MARK: Eventos pelo caminho real

    static func keyBytes(_ rig: Rig) async throws -> UInt64 {
        guard let pty = rig.ptySession else { return 0 }
        let sessions = try await rig.client.list()
        return sessions.first { $0.sessionID == pty }?.inputBytesByOrigin[.key] ?? 0
    }

    static func dispatch(_ event: NSEvent, _ rig: Rig) {
        if NSApp.keyWindow === rig.window { NSApp.sendEvent(event) } else { rig.window.sendEvent(event) }
    }

    static func press(_ character: String, keyCode: UInt16, _ rig: Rig, modifiers: NSEvent.ModifierFlags = []) {
        dispatch(keyEvent(keyCode: keyCode, characters: character, modifiers: modifiers, window: rig.window), rig)
    }

    static func escape(_ rig: Rig) { press("\u{1b}", keyCode: 53, rig) }
    static func returnKey(_ rig: Rig) { press("\r", keyCode: 36, rig) }

    /// Digita uma tecla e espera o daemon contar o byte.
    static func type(_ character: String, _ rig: Rig, keyCode: UInt16 = 0) async throws -> Bool {
        let before = try await keyBytes(rig)
        press(character, keyCode: keyCode, rig)
        do {
            try await eventually("daemon counts the key", timeout: .seconds(2)) { try await keyBytes(rig) > before }
            return true
        } catch { return false }
    }

    static func settle(_ ms: Int = 250) async { try? await Task.sleep(for: .milliseconds(ms)) }

    /// Estado exigido depois de cada sequência.
    static func assertTyping(_ label: String, _ rig: Rig, strictResponder: Bool = true, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        await settle(400)
        let responder = rig.window.firstResponder.map { String(describing: Swift.type(of: $0)) } ?? "nil"
        #expect(NSApp.keyWindow == nil || NSApp.keyWindow === rig.window, "\(label): outra janela é key: \(String(describing: NSApp.keyWindow))", sourceLocation: sourceLocation)
        #expect(rig.window.childWindows?.contains { $0.isKeyWindow } != true, "\(label): janela-filha key", sourceLocation: sourceLocation)
        if strictResponder {
            #expect(rig.window.firstResponder === rig.surface, "\(label): first responder deve ser a surface (é \(responder))", sourceLocation: sourceLocation)
        }
        #expect(!(rig.surface?.hasMarkedText() ?? false), "\(label): texto marcado preso na surface", sourceLocation: sourceLocation)
        #expect(try await type("x", rig), "\(label): a tecla deve chegar ao daemon (responder=\(responder))", sourceLocation: sourceLocation)
    }

    /// Clique de verdade no terminal: mouseDown/mouseUp pelo despacho da janela na posição do pane.
    static func clickTerminal(_ rig: Rig) {
        guard let surface = rig.surface else { return }
        click(at: surface.convert(NSPoint(x: surface.bounds.midX, y: surface.bounds.midY), to: nil), rig)
    }

    /// Sem key window (`.prohibited`) o AppKit só "ativaria" a janela no clique; o teste entrega o clique à view sob o ponteiro,
    /// que é o que o AppKit faz em seguida (`hitTest` e `mouseDown`/`mouseUp`).
    static func click(at inWindow: NSPoint, _ rig: Rig) {
        guard let content = rig.window.contentView, let hit = content.hitTest(content.convert(inWindow, from: nil)) else { return }
        for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(
                with: kind, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: rig.window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            if kind == .leftMouseDown { hit.mouseDown(with: event) } else { hit.mouseUp(with: event) }
        }
    }

    static func waitTerminalRunning(_ rig: Rig) async throws {
        try await eventually("focused terminal running", timeout: .seconds(20)) {
            guard let id = rig.terminalID else { return false }
            return rig.env.workspace.terminal(id)?.state == .running && rig.env.workspace.focusedHost() != nil
        }
    }

    // MARK: Cenários

    @Test func baselineTypingReachesTheDaemon() async throws {
        try await Self.withApp { rig in
            try await Self.assertTyping("baseline", rig)
        }
    }

    @Test func quickLaunchEscapeThenType() async throws {
        try await Self.withApp { rig in
            _ = try await rig.env.registry.perform(.tabQuickLaunch, .press)
            await Self.settle()
            #expect(rig.env.overlays.popoverIsOpen)
            try await Self.waitMenuKeyboard(rig)
            Self.escape(rig)
            await Self.settle()
            #expect(!rig.env.overlays.popoverIsOpen)
            try await Self.assertTyping("quick launch + esc", rig)
        }
    }

    @Test func quickLaunchEnterOpensANewTabAndTypingFollowsIt() async throws {
        try await Self.withApp { rig in
            let tabs = rig.env.workspace.tabs.count
            _ = try await rig.env.registry.perform(.tabQuickLaunch, .press)
            try await Self.waitMenuKeyboard(rig)
            // Primeiro item ("Terminal" ou o agente padrão), com ↓ para cair num shell se o agente não estiver instalado.
            Self.returnKey(rig)
            try await Self.waitForTabs(rig, tabs + 1)
            try await Self.waitTerminalRunning(rig)
            try await Self.assertTyping("quick launch + enter", rig)
        }
    }

    /// O painel aberto tem de ficar com o teclado (o captador vira first responder); senão ↑↓ ↵ Esc não funcionam.
    static func waitMenuKeyboard(_ rig: Rig) async throws {
        do {
            try await eventually("menu key catcher is first responder", timeout: .seconds(3)) { rig.window.firstResponder is DSKeyCatcherView }
        } catch {
            let name = rig.window.firstResponder.map { String(describing: Swift.type(of: $0)) } ?? "nil"
            Issue.record("o menu aberto não recebeu o teclado: first responder = \(name)")
            throw error
        }
    }

    static func waitForTabs(_ rig: Rig, _ count: Int) async throws {
        try await eventually("tab count \(count)", timeout: .seconds(20)) { rig.env.workspace.tabs.count >= count }
    }

    @Test func quickLaunchTypedTextBackspaceThenClickOutside() async throws {
        try await Self.withApp { rig in
            _ = try await rig.env.registry.perform(.tabQuickLaunch, .press)
            try await Self.waitMenuKeyboard(rig)
            Self.press("a", keyCode: 0, rig)
            Self.press("b", keyCode: 11, rig)
            Self.press("\u{7f}", keyCode: 51, rig)
            await Self.settle(100)
            // Clique fora do painel: a camada do popover fecha por `dismissPopover` (o SwiftUI do `onTapGesture` não roda sem eventos reais).
            rig.env.overlays.dismissPopover()
            await Self.settle()
            #expect(!rig.env.overlays.popoverIsOpen)
            try await Self.assertTyping("quick launch + typing + click outside", rig)
            // Clicar no terminal depois de tudo também deixa digitar.
            Self.clickTerminal(rig)
            try await Self.assertTyping("click terminal after popover", rig)
        }
    }

    @Test func appMenuOpenAndCloseThenType() async throws {
        try await Self.withApp { rig in
            for close in 0 ..< 3 {
                let anchor = rig.env.elements.frame(of: .windowAppName) ?? CGRect(x: 80, y: 8, width: 80, height: 24)
                DSMenuPanel.present(router: rig.env.overlays, registry: rig.env.registry, name: "appMenu", anchor: anchor, entries: AppMenuEntries.entries)
                await Self.settle()
                #expect(rig.env.overlays.popoverIsOpen)
                try await Self.waitMenuKeyboard(rig)
                switch close {
                case 0: Self.escape(rig)
                case 1:
                    Self.press("\u{F701}", keyCode: 125, rig)  // ↓
                    Self.press("\u{F701}", keyCode: 125, rig)
                    Self.press("\u{F700}", keyCode: 126, rig)  // ↑
                    Self.escape(rig)
                default: Self.clickTerminal(rig)
                }
                await Self.settle()
                try await Self.assertTyping("app menu close #\(close)", rig)
            }
        }
    }

    @Test func comboboxInsideTheComposerThenCloseEverything() async throws {
        try await Self.withApp { rig in
            _ = try await rig.env.registry.perform(.sessionNew, .press)
            await Self.settle(500)
            #expect(rig.env.overlays.isPresenting)
            guard let model = rig.env.composer?.model else { Issue.record("composer model missing"); return }
            let anchor = rig.env.elements.frame(of: .overlayComposerAgent) ?? CGRect(x: 400, y: 300, width: 220, height: 32)
            rig.env.overlays.presentPopover(
                DSCombobox.popoverSpec(
                    id: .overlayComposerAgent, selection: model.draft.provider.rawValue, entries: model.agentEntries, action: .composerSetAgent,
                    searchPlaceholder: "Search agents…", anchor: anchor, registry: rig.env.registry))
            await Self.settle()
            #expect(rig.env.overlays.popoverIsOpen)
            try await Self.waitMenuKeyboard(rig)
            Self.escape(rig)  // fecha o combobox
            await Self.settle()
            #expect(!rig.env.overlays.popoverIsOpen && rig.env.overlays.isPresenting)
            Self.escape(rig)  // fecha o composer
            await Self.settle(500)
            #expect(!rig.env.overlays.isPresenting)
            try await Self.assertTyping("composer + combobox + esc esc", rig)
        }
    }

    @Test func settingsOpenAndBackThenType() async throws {
        try await Self.withApp { rig in
            _ = try await rig.env.registry.perform(.appSettings, .press)
            await Self.settle(400)
            #expect(rig.env.settings.isOpen)
            _ = try await rig.env.registry.perform(.settingsBack, .press)
            await Self.settle(400)
            #expect(!rig.env.settings.isOpen)
            try await Self.assertTyping("settings open/back", rig)
            // Settings pelo menu do nome do app e fechamento por Esc.
            _ = try await rig.env.registry.perform(.appSettings, .press)
            await Self.settle(300)
            Self.escape(rig)
            await Self.settle(300)
            if rig.env.settings.isOpen { rig.env.settings.close() }
            try await Self.assertTyping("settings esc", rig)
        }
    }

    @Test func tabSwitchingKeepsTheTerminalTyping() async throws {
        try await Self.withApp { rig in
            _ = rig.env.workspace.newTab(provider: .shell)
            try await Self.waitForTabs(rig, 2)
            try await Self.waitTerminalRunning(rig)
            try await Self.assertTyping("second tab", rig)
            rig.env.workspace.selectTab(at: 0)
            await Self.settle()
            try await Self.assertTyping("back to first tab", rig)
            rig.env.workspace.selectTab(at: 1)
            await Self.settle()
            try await Self.assertTyping("forward to second tab", rig)
        }
    }

    @Test func viewerOpenAndCloseThenType() async throws {
        try await Self.withApp { rig in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("abx-focus-\(UUID().uuidString.prefix(8))", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let computer = try ManagedComputer(name: "focus-a", display: .headless, run: RunFolder(root: folder), backend: FocusFlowBackend())
            await rig.env.computers.add(computer)
            rig.env.computers.openViewer("focus-a")
            await Self.settle(600)
            #expect(rig.env.computers.page == .viewer("focus-a"))
            rig.env.computers.closePage()
            await Self.settle(400)
            try await Self.assertTyping("viewer closed with closePage", rig)
            rig.env.computers.show(.computers)
            await Self.settle(300)
            rig.env.computers.closePage()
            await Self.settle(300)
            try await Self.assertTyping("computers page closed", rig)
        }
    }

    @Test func clickingTheTerminalRecoversFromEveryStolenFocus() async throws {
        try await Self.withApp { rig in
            let thieves: [(String, NSResponder?)] = [
                ("window", rig.window), ("contentView", rig.window.contentView), ("nil", nil),
                ("key catcher", DSKeyCatcherView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))),
            ]
            for (name, responder) in thieves {
                if let catcher = responder as? DSKeyCatcherView { rig.window.contentView?.addSubview(catcher) }
                rig.window.makeFirstResponder(responder)
                await Self.settle(200)
                Self.clickTerminal(rig)
                try await Self.assertTyping("click after \(name) stole focus", rig)
                if let catcher = responder as? DSKeyCatcherView { catcher.removeFromSuperview() }
            }
        }
    }

    @Test func staleKeyCatcherNeverKeepsTheKeyboard() async throws {
        try await Self.withApp { rig in
            // Um catcher órfão no first responder sem popover aberto: o watchdog devolve a tecla ao terminal.
            let catcher = DSKeyCatcherView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
            rig.window.contentView?.addSubview(catcher)
            rig.window.makeFirstResponder(catcher)
            #expect(!rig.env.overlays.popoverIsOpen)
            let before = try await Self.keyBytes(rig)
            Self.press("k", keyCode: 40, rig)
            try await eventually("watchdog routes the key", timeout: .seconds(3)) { try await Self.keyBytes(rig) > before }
            try await Self.assertTyping("after the watchdog", rig)
            catcher.removeFromSuperview()
        }
    }

    // MARK: Arrasto de tab (F11) e texto marcado (ABNT2)

    @Test func tabDragStartedAndCancelledThenType() async throws {
        try await Self.withApp { rig in
            _ = rig.env.workspace.newTab(provider: .shell)
            try await Self.waitForTabs(rig, 2)
            try await Self.waitTerminalRunning(rig)
            let drag = rig.env.workspace.dragController
            guard let tab = rig.env.workspace.activeTab, let surface = rig.surface else { Issue.record("no active tab"); return }
            let start = CGPoint(x: 200, y: rig.window.contentView!.bounds.height - 18)
            let over = surface.convert(NSPoint(x: surface.bounds.midX, y: surface.bounds.midY), to: nil)
            drag.begin(.tab(tab.id), title: "t", from: start, at: start, window: rig.window, owner: nil)
            drag.update(at: over)
            #expect(drag.isActive)
            drag.cancel()
            #expect(!drag.isActive)
            try await Self.assertTyping("tab drag cancelled", rig)
            // Arrasto interrompido pela janela sem foco (perda de key): também devolve o teclado.
            drag.begin(.tab(tab.id), title: "t", from: start, at: start, window: rig.window, owner: nil)
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: rig.window)
            await Self.settle(200)
            #expect(!drag.isActive)
            try await Self.assertTyping("tab drag cancelled by resign key", rig)
        }
    }

    @Test func tabDragDroppedOnTheOtherPaneThenType() async throws {
        try await Self.withApp { rig in
            _ = rig.env.workspace.newTab(provider: .shell)
            try await Self.waitForTabs(rig, 2)
            try await Self.waitTerminalRunning(rig)
            rig.env.workspace.selectTab(at: 0)
            await Self.settle(300)
            let drag = rig.env.workspace.dragController
            guard let second = rig.env.workspace.tabs.last, let surface = rig.surface else { Issue.record("no tabs"); return }
            let start = CGPoint(x: 400, y: rig.window.contentView!.bounds.height - 18)
            let leftEdge = surface.convert(NSPoint(x: surface.bounds.minX + 40, y: surface.bounds.midY), to: nil)
            drag.begin(.tab(second.id), title: "t", from: start, at: start, window: rig.window, owner: nil)
            drag.update(at: leftEdge)
            drag.end(at: leftEdge)
            await Self.settle(600)
            #expect(!drag.isActive)
            try await Self.waitTerminalRunning(rig)
            try await Self.assertTyping("tab dropped on pane", rig)
        }
    }

    @Test func markedTextLeftByADeadKeyNeverBlocksTheTerminal() async throws {
        try await Self.withApp { rig in
            guard let surface = rig.surface else { Issue.record("no surface"); return }
            surface.setMarkedText("´", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(surface.hasMarkedText())
            // O usuário vai para a sidebar/outro lugar e volta clicando no terminal: o texto marcado preso é descartado.
            rig.window.makeFirstResponder(rig.window.contentView)
            Self.clickTerminal(rig)
            try await Self.assertTyping("dead key then click", rig)
        }
    }
}
