import RackyProtocol
import RackyStore
import Foundation
import Testing

@testable import RackyUI

/// Ligar "Subagent computers" numa sessão aberta redesenha o pane na hora: o ícone e o "Restart to apply" não esperam a primeira
/// mensagem do agente (F38).
@MainActor
@Suite(.offscreenAppKit) struct SubagentModeRefreshTests {
    @Test func changingTheSessionModeNotifiesThePaneTree() {
        let workspace = WorkspaceModel(runtime: TerminalRuntime(
            configuration: .init(daemonHome: URL(fileURLWithPath: "/tmp/x"), daemonExecutable: nil, stopDaemonOnQuit: false, appSocketPath: "", loginEnvironment: { [:] }),
            registry: nil, elements: nil))
        var notified = 0
        workspace.addListener { notified += 1 }
        var session = Session(kind: .clean, folderPath: "/tmp/abx-mode", title: "mode")
        workspace.ingest(StoreSnapshot(sessions: [session]))
        let afterFirst = notified
        workspace.ingest(StoreSnapshot(sessions: [session]))
        #expect(notified == afterFirst, "snapshot igual não redesenha")
        session.subagentComputers = .full
        workspace.ingest(StoreSnapshot(sessions: [session]))
        #expect(notified > afterFirst)
    }
}
