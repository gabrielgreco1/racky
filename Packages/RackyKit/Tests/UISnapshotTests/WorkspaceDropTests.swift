import RackyProtocol
import RackyStore
import AppKit
import Foundation
import Testing

@testable import RackyUI

/// Operações do arrasto de tab/pane no modelo (F11): split por lado, centro, pane → tab, cancelamento e persistência.
extension WorkspaceModelTests {
    private func drop(_ rig: Rig, size: CGSize = CGSize(width: 1200, height: 700)) async throws -> (tabs: [Tab], terminals: [UUID]) {
        rig.model.contentSize = size
        let list = rig.model.tabs
        return (list, list.flatMap { $0.layout.terminalIDs })
    }

    @Test func droppingATabOnASideSplitsThatPaneAndMergesTheTabs() async throws {
        for (zone, axis, droppedFirst) in [
            (PaneDropZone.right, SplitAxis.horizontal, false), (.left, .horizontal, true), (.top, .vertical, true), (.bottom, .vertical, false),
        ] {
            let rig = try await make(tabs: 2)
            defer { Task { await cleanup(rig) } }
            let (tabs, terminals) = try await drop(rig)
            let (target, dropped) = (terminals[0], terminals[1])
            #expect(rig.model.activeTabID == tabs[0].id)
            #expect(rig.model.performDrop(.tab(tabs[1].id), onTerminal: target, zone: zone) == .applied)
            #expect(rig.model.tabs.map(\.id) == [tabs[0].id], "a tab arrastada vira parte da tab de destino")
            let layout = try #require(rig.model.activeTab?.layout)
            guard case .split(let got, _, let first, let second) = layout else { Issue.record("expected split"); return }
            #expect(got == axis)
            #expect(first.terminalIDs == [droppedFirst ? dropped : target])
            #expect(second.terminalIDs == [droppedFirst ? target : dropped])
            #expect(rig.model.focusedTerminalID == dropped)
            #expect(rig.model.terminal(dropped)?.tabID == tabs[0].id)

            await rig.model.settlePersistence()
            let stored = try #require(try await rig.store.tab(id: tabs[0].id))
            #expect(stored.layout == layout)
            #expect(stored.focusedTerminalID == dropped)
            #expect(try await rig.store.terminal(id: dropped)?.tabID == tabs[0].id)
            #expect(try await rig.store.tabs(sessionID: rig.session.id).map(\.id) == [tabs[0].id])
            #expect(try await rig.store.tab(id: tabs[1].id)?.closedAt != nil)
        }
    }

    @Test func droppingATabInTheCenterSwapsItsPaneWithTheTarget() async throws {
        let rig = try await make(tabs: 2)
        defer { Task { await cleanup(rig) } }
        let (tabs, terminals) = try await drop(rig)
        guard case .created(let extra) = rig.model.split(.horizontal, source: terminals[0]) else { Issue.record("split"); return }
        #expect(rig.model.performDrop(.tab(tabs[1].id), onTerminal: terminals[0], zone: .center) == .applied)
        #expect(rig.model.tabs.count == 2, "o centro troca de lugar: nenhuma tab some")
        #expect(rig.model.tab(tabs[0].id)?.layout.terminalIDs == [terminals[1], extra])
        #expect(rig.model.tab(tabs[1].id)?.layout.terminalIDs == [terminals[0]])
        #expect(rig.model.terminal(terminals[1])?.tabID == tabs[0].id)
        #expect(rig.model.terminal(terminals[0])?.tabID == tabs[1].id)
        #expect(rig.model.focusedTerminalID == terminals[1])
        await rig.model.settlePersistence()
        #expect(try await rig.store.tab(id: tabs[1].id)?.layout.terminalIDs == [terminals[0]])
        #expect(try await rig.store.terminal(id: terminals[0])?.tabID == tabs[1].id)
    }

    @Test func movingAPaneWithinTheTabReordersThePanesWithoutNewTerminals() async throws {
        let rig = try await make()
        defer { Task { await cleanup(rig) } }
        rig.model.contentSize = CGSize(width: 1200, height: 700)
        let a = try #require(rig.model.focusedTerminalID)
        guard case .created(let b) = rig.model.split(.horizontal), case .created(let c) = rig.model.split(.horizontal) else { return }
        #expect(rig.model.performDrop(.pane(c), onTerminal: a, zone: .top) == .applied)
        let layout = try #require(rig.model.activeTab?.layout)
        #expect(layout.leafCount == 3)
        #expect(Set(layout.terminalIDs) == [a, b, c])
        #expect(layout.terminalIDs.first == c)
        #expect(rig.model.tabs.count == 1)
        #expect(rig.model.performDrop(.pane(a), onTerminal: b, zone: .center) == .applied)
        let swapped = try #require(rig.model.activeTab?.layout.terminalIDs)
        #expect(swapped.firstIndex(of: b)! < swapped.firstIndex(of: a)!, "centro troca os dois de lugar")
        await rig.model.settlePersistence()
        #expect(try await rig.store.tab(id: rig.model.activeTabID!)?.layout == rig.model.activeTab?.layout)
    }

    @Test func detachingAPaneTurnsItIntoATabAtTheChosenPosition() async throws {
        let rig = try await make(tabs: 2)
        defer { Task { await cleanup(rig) } }
        let (tabs, terminals) = try await drop(rig)
        guard case .created(let extra) = rig.model.split(.horizontal, source: terminals[0]) else { Issue.record("split"); return }
        #expect(rig.model.detachPane(extra, toIndex: 1) == .applied)
        let ids = rig.model.tabs.map(\.id)
        #expect(ids.count == 3 && ids[0] == tabs[0].id && ids[2] == tabs[1].id)
        let newTab = try #require(rig.model.tab(ids[1]))
        #expect(newTab.layout.terminalIDs == [extra])
        #expect(rig.model.tab(tabs[0].id)?.layout.terminalIDs == [terminals[0]])
        #expect(rig.model.terminal(extra)?.tabID == newTab.id)
        #expect(rig.model.activeTabID == newTab.id)
        #expect(rig.model.focusedTerminalID == extra)
        await rig.model.settlePersistence()
        #expect(try await rig.store.tabs(sessionID: rig.session.id).map(\.id) == ids)
        #expect(try await rig.store.terminal(id: extra)?.tabID == newTab.id)
        #expect(rig.model.detachPane(extra) == .invalid, "uma tab de um só pane já é uma tab")
    }

    @Test func dropsThatCannotHappenAreRefusedAndLeaveTheModelUntouched() async throws {
        let rig = try await make(tabs: 2)
        defer { Task { await cleanup(rig) } }
        let (tabs, terminals) = try await drop(rig)
        let before = rig.model.tabs
        #expect(rig.model.performDrop(.tab(tabs[0].id), onTerminal: terminals[0], zone: .right) == .invalid, "tab sobre os próprios panes")
        #expect(rig.model.performDrop(.pane(terminals[0]), onTerminal: terminals[0], zone: .left) == .invalid, "pane sobre si mesmo")
        #expect(rig.model.performDrop(.tab(UUID()), onTerminal: terminals[0], zone: .left) == .invalid)
        rig.model.contentSize = CGSize(width: 400, height: 300)
        #expect(rig.model.evaluateDrop(.tab(tabs[1].id), onTerminal: terminals[0], zone: .right) == .noRoom)
        #expect(rig.model.performDrop(.tab(tabs[1].id), onTerminal: terminals[0], zone: .right) == .noRoom)
        #expect(rig.model.evaluateDrop(.tab(tabs[1].id), onTerminal: terminals[0], zone: .center) == .applied, "trocar não precisa de espaço")
        #expect(rig.model.tabs == before)
    }

    @Test func cancellingADragChangesNothingAndReturnsTheKeyboard() async throws {
        let rig = try await make(tabs: 2)
        defer { Task { await cleanup(rig) } }
        let (tabs, _) = try await drop(rig)
        let before = rig.model.tabs
        let drag = rig.model.dragController
        drag.begin(.tab(tabs[1].id), title: "zsh1", from: .zero, at: CGPoint(x: 20, y: 20), window: nil, owner: nil)
        #expect(drag.isActive)
        drag.cancel()
        #expect(!drag.isActive)
        drag.cancel()
        #expect(drag.finishedCount == 1, "cancelar duas vezes não deixa estado nem repete a limpeza")
        #expect(drag.end(at: .zero) == nil, "soltar depois de cancelar não faz nada")
        #expect(rig.model.tabs == before)
    }

    @Test func escapeKeyCancelsTheDragThroughTheEventMonitor() async throws {
        let rig = try await make(tabs: 2)
        defer { Task { await cleanup(rig) } }
        let (tabs, _) = try await drop(rig)
        let window = OffscreenAppKit.makeWindow(size: NSSize(width: 400, height: 300))
        defer { window.close() }
        let drag = rig.model.dragController
        drag.begin(.tab(tabs[1].id), title: "zsh1", from: .zero, at: CGPoint(x: 20, y: 20), window: window, owner: nil)
        let esc = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false,
                keyCode: 53))
        NSApp.sendEvent(esc)
        #expect(!drag.isActive, "Esc cancela o arrasto")
        #expect(rig.model.tabs.count == 2)
    }

    @Test func dropActionsDriveTheSameOperations() async throws {
        let rig = try await make(tabs: 2)
        defer { Task { await cleanup(rig) } }
        let (tabs, terminals) = try await drop(rig)
        let registry = rig.env.registry
        let result = try await registry.perform(.tabDropOnPane, .set("\(tabs[1].id.uuidString)=\(terminals[0].uuidString)@right"))
        #expect(result.message == "applied")
        #expect(rig.model.activeTab?.layout.terminalIDs == [terminals[0], terminals[1]])
        let detached = try await registry.perform(.paneDetach, .select(terminals[1].uuidString))
        #expect(detached.message == "applied")
        #expect(rig.model.tabs.count == 2)
        let moved = try? await registry.perform(.paneMove, .set("bad"))
        #expect(moved == nil, "argumento inválido falha com mensagem")
    }

    @Test func aMergedTabIsNotResurrectedByReopen() async throws {
        let rig = try await make(tabs: 2)
        defer { Task { await cleanup(rig) } }
        let (tabs, terminals) = try await drop(rig)
        #expect(rig.model.performDrop(.tab(tabs[1].id), onTerminal: terminals[0], zone: .right) == .applied)
        await rig.model.settlePersistence()
        rig.model.reopenClosedTab()
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.model.tabs.map(\.id) == [tabs[0].id], "os terminais da tab fundida já vivem na tab de destino")
        #expect(rig.model.activeTab?.layout.terminalIDs == [terminals[0], terminals[1]])
    }
}
