import RackyCore
import RackyProtocol
import RackyStore
import AppKit
import Foundation
import Testing

@testable import RackyUI

/// Arrastar tab e pane com eventos de mouse sintéticos (F11) sobre o `rackyd` real: o layout resultante muda, mas o processo
/// do terminal é o mesmo (pid e sessão do daemon inalterados) e cada pane recebe no máximo um resize de PTY por transição.
/// Nada aparece na tela: janela fora de qualquer tela, nunca ordenada para a frente.
@MainActor
@Suite(.serialized, .tags(.integration), .timeLimit(.minutes(2)), .offscreenAppKit) struct PaneDragIntegrationTests {
    private struct Rig {
        let harness: DaemonHarness
        let runtime: TerminalRuntime
        let model: WorkspaceModel
        let area: PaneAreaView
        let window: NSWindow
        let container: NSView
        let tabs: [Tab]
        let terminals: [Terminal]
    }

    private static let windowSize = NSSize(width: 1200, height: 736)
    /// Tab row simulada: a faixa de cima da janela (y para cima).
    private static let tabRow = CGRect(x: 0, y: 700, width: 1200, height: 36)

    private func makeRig() async throws -> Rig {
        let harness = try DaemonHarness()
        try await harness.start()
        let runtime = TerminalRuntime(
            configuration: .init(
                daemonHome: harness.home, daemonExecutable: rackydBinary(), stopDaemonOnQuit: false, appSocketPath: "/tmp/none.sock",
                loginEnvironment: { ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8"] }),
            registry: nil, elements: nil)
        let model = WorkspaceModel(runtime: runtime)
        let session = Session(kind: .clean, folderPath: NSTemporaryDirectory(), title: "drag")
        model.sessionLookup = { _ in session }
        var tabs: [Tab] = [], terminals: [Terminal] = []
        for i in 0 ..< 2 {
            let tabID = UUID.v7(), termID = UUID.v7()
            let spec = LaunchSpec(provider: .custom, envOverrides: ["PROMPT": "%# ", "RPROMPT": ""], customArgv: ["/bin/zsh", "-f", "-i"])
            terminals.append(Terminal(id: termID, tabID: tabID, provider: .custom, title: "zsh\(i)", cwd: NSTemporaryDirectory(), launchSpec: spec))
            tabs.append(Tab(id: tabID, sessionID: session.id, title: "zsh\(i)", sortIndex: i, layout: .leaf(Pane(content: .terminal(termID))), focusedTerminalID: termID))
        }
        let area = PaneAreaView(model: model, registry: nil, elements: nil, router: nil)
        let window = OffscreenAppKit.makeWindow(size: Self.windowSize, styleMask: [.borderless])
        let container = NSView(frame: NSRect(origin: .zero, size: Self.windowSize))
        window.contentView = container
        container.addSubview(area)
        area.frame = NSRect(x: 0, y: 0, width: Self.windowSize.width, height: 700)
        model.dragController.tabRowRect = { Self.tabRow }
        model.ingest(StoreSnapshot(sessions: [session], tabs: tabs, terminals: terminals))
        model.setSession(session.id)
        area.layoutSubtreeIfNeeded()
        // As duas tabs rodam: seleciona a segunda (lança) e volta para a primeira (lança).
        for index in [1, 0] {
            model.selectTab(at: index)
            area.layoutSubtreeIfNeeded()
            let id = terminals[index].id
            try await eventually("terminal \(index) running") { model.terminal(id)?.state == .running && screen(model, id).contains("% ") }
        }
        return Rig(harness: harness, runtime: runtime, model: model, area: area, window: window, container: container, tabs: tabs, terminals: terminals)
    }

    private func tearDown(_ rig: Rig) async {
        for t in rig.terminals { rig.runtime.dispose(t.id) }
        rig.window.close()
        await rig.runtime.client.stop()
        await rig.harness.stop()
        rig.harness.terminateNow()
    }

    private func screen(_ model: WorkspaceModel, _ id: UUID) -> String {
        guard let entry = model.runtime.existingEntry(for: id) else { return "" }
        return String(decoding: entry.host.surface.getBufferAsData(kind: .active), as: UTF8.self)
    }

    private func mouse(_ type: NSEvent.EventType, _ point: CGPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    /// Origem de arrasto (a tab ou o cabeçalho de um pane) dentro da janela; o clique sem arrasto vai para `onClick`.
    private func source(_ rig: Rig, _ payload: PaneDragPayload, at frame: NSRect) -> DragSourceView {
        let view = DragSourceView(frame: frame)
        view.controller = rig.model.dragController
        view.payload = payload
        view.title = { "drag" }
        rig.container.addSubview(view)
        return view
    }

    private func processes(_ rig: Rig, _ ids: [UUID]) async -> [UUID: (pid: Int32?, session: String?)] {
        var out: [UUID: (Int32?, String?)] = [:]
        for id in ids {
            guard let t = rig.model.terminal(id) else { continue }
            out[id] = (await rig.runtime.summary(of: t)?.pid, t.ptySessionID)
        }
        return out
    }

    private func drag(_ rig: Rig, _ view: DragSourceView, from: CGPoint, via: [CGPoint], to: CGPoint) {
        view.mouseDown(with: mouse(.leftMouseDown, from, in: rig.window))
        for p in via { view.mouseDragged(with: mouse(.leftMouseDragged, p, in: rig.window)) }
        view.mouseDragged(with: mouse(.leftMouseDragged, to, in: rig.window))
    }

    @Test func draggingTabsAndPanesRearrangesTheLayoutWithoutTouchingTheProcesses() async throws {
        let rig = try await makeRig()
        defer { Task { await tearDown(rig) } }
        let (model, window) = (rig.model, rig.window)
        let ids = rig.terminals.map(\.id)
        let before = await processes(rig, ids)
        #expect(before.values.allSatisfy { $0.pid != nil && $0.session != nil })
        let resizes = ids.map { rig.runtime.existingEntry(for: $0)?.resizeCount ?? 0 }

        // 1. Tab 2 arrastada da tab row para a borda direita do pane da tab 1: split à direita.
        let tab2 = source(rig, .tab(rig.tabs[1].id), at: NSRect(x: 180, y: 704, width: 160, height: 28))
        tab2.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 250, y: 718), in: window))
        tab2.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 255, y: 718), in: window))
        #expect(!model.dragController.isActive, "menos de 12 pt ainda é clique")
        tab2.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 600, y: 350), in: window))
        guard case .pane(_, let centerZone, let centerOutcome, _)? = model.dragController.session?.target else { Issue.record("sem alvo"); return }
        #expect(centerZone == .center && centerOutcome == .applied)
        let overlay = try #require(rig.area.subviews.compactMap { $0 as? PaneDropOverlayView }.first)
        #expect(overlay.zone == .center)
        tab2.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 1150, y: 350), in: window))
        #expect(overlay.zone == .right, "zona sob o cursor")
        #expect(model.tabs.count == 2, "nada muda antes de soltar")
        tab2.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 1150, y: 350), in: window))
        #expect(!model.dragController.isActive)
        #expect(model.tabs.map(\.id) == [rig.tabs[0].id])
        guard case .split(let axis, _, let first, let second)? = model.activeTab?.layout else { Issue.record("expected split"); return }
        #expect(axis == .horizontal && first.terminalIDs == [ids[0]] && second.terminalIDs == [ids[1]])
        rig.area.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        #expect(overlay.superview == nil && overlay.alphaValue == 0, "a prévia some depois de soltar")
        let afterMerge = await processes(rig, ids)
        for id in ids {
            #expect(afterMerge[id]?.pid == before[id]?.pid, "o processo do terminal é o mesmo (pid)")
            #expect(afterMerge[id]?.session == before[id]?.session, "a sessão do daemon é reaproveitada")
            #expect(model.terminal(id)?.state == .running)
        }
        for (i, id) in ids.enumerated() {
            let delta = (rig.runtime.existingEntry(for: id)?.resizeCount ?? 0) - resizes[i]
            #expect(delta <= 1, "no máximo um resize de PTY por pane na transição (\(delta))")
        }
        try await eventually("keyboard back on the terminal") { window.firstResponder === model.focusedHost()?.surface }

        // 2. Cabeçalho do pane 2 arrastado sobre o pane 1 (mover pane): vai para cima.
        let header = source(rig, .pane(ids[1]), at: NSRect(x: 700, y: 650, width: 400, height: 24))
        drag(rig, header, from: CGPoint(x: 800, y: 660), via: [CGPoint(x: 700, y: 500)], to: CGPoint(x: 300, y: 690))
        header.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 300, y: 690), in: window))
        guard case .split(let axis2, _, let first2, _)? = model.activeTab?.layout else { Issue.record("expected split"); return }
        #expect(axis2 == .vertical && first2.terminalIDs == [ids[1]], "arrastar o cabeçalho para a borda de cima do pane 1")

        // 3. Cabeçalho do pane 2 arrastado para a tab row: vira tab de novo.
        rig.area.layoutSubtreeIfNeeded()
        let header2 = source(rig, .pane(ids[1]), at: NSRect(x: 700, y: 650, width: 400, height: 24))
        drag(rig, header2, from: CGPoint(x: 800, y: 660), via: [CGPoint(x: 700, y: 690)], to: CGPoint(x: 900, y: 718))
        guard case .tabRow? = model.dragController.session?.target else { Issue.record("sem alvo na tab row"); return }
        header2.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 900, y: 718), in: window))
        #expect(model.tabs.count == 2)
        #expect(model.activeTab?.layout.terminalIDs == [ids[1]])
        #expect(model.tabs[0].layout.terminalIDs == [ids[0]])
        rig.area.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        let afterDetach = await processes(rig, ids)
        for id in ids {
            #expect(afterDetach[id]?.pid == before[id]?.pid)
            #expect(afterDetach[id]?.session == before[id]?.session)
        }

        // 4. Esc no meio do arrasto cancela; soltar fora da janela também; o teclado volta ao terminal.
        let layoutBefore = model.tabs
        let tab1 = source(rig, .tab(model.tabs[0].id), at: NSRect(x: 0, y: 704, width: 160, height: 28))
        drag(rig, tab1, from: CGPoint(x: 50, y: 718), via: [], to: CGPoint(x: 600, y: 300))
        #expect(model.dragController.isActive)
        let esc = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        NSApp.sendEvent(esc)
        #expect(!model.dragController.isActive)
        tab1.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 600, y: 300), in: window))
        #expect(model.tabs == layoutBefore, "Esc não aplica nada, e o mouseUp seguinte também não")
        drag(rig, tab1, from: CGPoint(x: 50, y: 718), via: [], to: CGPoint(x: -300, y: 300))
        #expect(model.dragController.session?.target == nil)
        tab1.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: -300, y: 300), in: window))
        #expect(model.tabs == layoutBefore, "soltar fora cancela")
        #expect(!model.dragController.isActive)
        try await eventually("keyboard back on the terminal after cancel") { window.firstResponder === model.focusedHost()?.surface }

        // 5. Reordenar dentro da tab row continua funcionando.
        for tab in model.tabs { model.dragController.tabFrames[tab.id] = CGRect(x: 0, y: 0, width: 180, height: 32) }
        let firstTab = model.tabs[0].id
        drag(rig, tab1, from: CGPoint(x: 50, y: 718), via: [CGPoint(x: 150, y: 718)], to: CGPoint(x: 300, y: 718))
        #expect(model.dragController.session?.overTabRow == true)
        tab1.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 300, y: 718), in: window))
        #expect(model.tabs.last?.id == firstTab, "a primeira tab foi para o fim")
        #expect(model.tabs.count == 2)
        let final = await processes(rig, ids)
        for id in ids { #expect(final[id]?.pid == before[id]?.pid) }
    }
}
