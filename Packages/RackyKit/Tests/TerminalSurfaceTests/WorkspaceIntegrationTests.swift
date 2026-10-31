import RackyCore
import RackyProtocol
import RackyStore
import AppKit
import Foundation
import Testing

@testable import RackyUI

/// Tabs e panes com o `rackyd` real: 2 panes com zsh, split sem recriar o PTY e um resize por transição (04 MA6).
@MainActor
@Suite(.serialized, .tags(.integration), .timeLimit(.minutes(1)), .offscreenAppKit) struct WorkspaceIntegrationTests {
    private func screen(_ model: WorkspaceModel, _ id: UUID) -> String {
        guard let entry = model.runtime.existingEntry(for: id) else { return "" }
        return String(decoding: entry.host.surface.getBufferAsData(kind: .active), as: UTF8.self)
    }

    @Test func twoPanesRunZshInTheRealDaemonAndSplitNeverRecreatesThePTY() async throws {
        let harness = try DaemonHarness()
        defer { harness.terminateNow() }
        try await harness.start()
        let runtime = TerminalRuntime(
            configuration: .init(
                daemonHome: harness.home, daemonExecutable: rackydBinary(), stopDaemonOnQuit: false, appSocketPath: "/tmp/none.sock",
                loginEnvironment: { ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8"] }),
            registry: nil, elements: nil)
        let model = WorkspaceModel(runtime: runtime)
        let session = Session(kind: .clean, folderPath: NSTemporaryDirectory(), title: "it")
        model.sessionLookup = { _ in session }
        let tabID = UUID.v7(), termID = UUID.v7()
        let spec = LaunchSpec(provider: .custom, envOverrides: ["PROMPT": "%# ", "RPROMPT": ""], customArgv: ["/bin/zsh", "-f", "-i"])
        let terminal = Terminal(id: termID, tabID: tabID, provider: .custom, title: "zsh", cwd: NSTemporaryDirectory(), launchSpec: spec)
        let tab = Tab(id: tabID, sessionID: session.id, title: "zsh", layout: .leaf(Pane(content: .terminal(termID))), focusedTerminalID: termID)
        let area = PaneAreaView(model: model, registry: nil, elements: nil, router: nil)
        let window = OffscreenAppKit.makeWindow(size: NSSize(width: 1200, height: 700), styleMask: [.borderless])
        window.isReleasedWhenClosed = false
        window.contentView = area
        area.frame = NSRect(x: 0, y: 0, width: 1200, height: 700)
        defer { window.close() }

        model.ingest(StoreSnapshot(sessions: [session], tabs: [tab], terminals: [terminal]))
        model.setSession(session.id)
        area.layoutSubtreeIfNeeded()
        try await eventually("first pane running") { model.terminal(termID)?.state == .running && screen(model, termID).contains("% ") }
        let firstSession = model.terminal(termID)?.ptySessionID
        #expect(firstSession != nil)

        // Split à direita: o pane novo nasce com o mesmo comando, o PTY do primeiro não é recriado.
        let resizesBefore = runtime.totalResizes
        guard case .created(let secondID) = model.split(.horizontal) else { Issue.record("split failed"); return }
        area.layoutSubtreeIfNeeded()
        try await eventually("second pane running") { model.terminal(secondID)?.state == .running && screen(model, secondID).contains("% ") }
        try await Task.sleep(for: .milliseconds(400))
        #expect(runtime.totalResizes - resizesBefore == 1, "um resize de PTY por transição (o pane existente); o novo nasce no tamanho final")
        #expect(model.terminal(termID)?.ptySessionID == firstSession)

        for (id, word) in [(termID, "one"), (secondID, "two")] {
            runtime.existingEntry(for: id)?.host.surface.send(txt: "echo pane-\(word)-$((6*7))\r")
        }
        try await eventually("both panes answer") {
            screen(model, termID).contains("pane-one-42") && screen(model, secondID).contains("pane-two-42")
        }
        let sessions = try await runtime.client.list().filter { $0.state == .running }
        #expect(sessions.count == 2)

        // Nova tab e volta: nenhuma sessão nova, nenhum resize.
        let beforeTabs = runtime.totalResizes
        model.newTab(provider: .shell)
        area.layoutSubtreeIfNeeded()
        model.selectTab(at: 0)
        area.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.terminal(termID)?.ptySessionID == firstSession)
        #expect(runtime.totalResizes == beforeTabs, "trocar de tab nunca redimensiona nem recria o PTY")

        // Fechar o segundo pane (shell ocioso): sai sem confirmação e o primeiro volta a ocupar a tab.
        model.closePane(secondID)
        try await eventually("pane closed") { model.tabs.first?.layout.leafCount == 1 }
        #expect(model.tabs.first?.layout.terminalIDs == [termID])

        runtime.dispose(termID)
        await runtime.client.stop()
        await harness.stop()
    }
}
