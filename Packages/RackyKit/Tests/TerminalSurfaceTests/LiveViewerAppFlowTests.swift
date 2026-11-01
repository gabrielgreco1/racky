import RackyCore
import RackyProtocol
import AppKit
import Foundation
import Testing

@testable import RackyUI

/// F25 com o Docker real (`RACKY_TEST_DOCKER=1`): o viewer do computador aberto como página do app montado (janela principal,
/// daemon real), noVNC conectado pelo ticket de uso único (60 s) e túnel do egress. Cobre o "Disconnected from <computer>":
/// reconectar por cima de uma conexão viva (o `disconnect` tardio do RFB velho derrubava o estado) e uma queda abrupta, que
/// tem de pedir ticket novo sozinha. Tudo com `racky.test=1` + `racky.test_run=<id>` desta execução; removido no fim.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["RACKY_TEST_DOCKER"] == "1"), .tags(.integration), .timeLimit(.minutes(10)))
struct LiveViewerAppFlowTests {
    static var repoRoot: URL {
        var root = URL(fileURLWithPath: #filePath)
        while root.path != "/", !FileManager.default.fileExists(atPath: root.appendingPathComponent("runtime/computer/Dockerfile").path) {
            root.deleteLastPathComponent()
        }
        return root
    }

    static func waitLive(_ viewer: ComputerViewerController, _ label: String, timeout: Duration = .seconds(30)) async throws {
        do {
            try await eventually(label, timeout: timeout) { viewer.model.connection == .live }
        } catch {
            Issue.record("\(label): connection=\(viewer.model.connection) lastError=\(viewer.lastError ?? "nil") info=\(viewer.web.streamInfo)")
            throw error
        }
    }

    @Test func viewerGoesLiveSurvivesAReconnectOnTopAndRecoversFromADrop() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("abx-liveapp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let rig = try await DemoComputerRig.provision(repoRoot: Self.repoRoot, home: home, name: "live-a")
        do {
            try await AppKeyboardFlowTests.withApp { app in
                _ = try? await rig.computer.backend.runtime("eval", DemoComputerRig.installScript(DemoComputerRig.animationHTML), timeout: 15)
                await app.env.computers.add(rig.computer)
                app.env.computers.openViewer("live-a")
                try await eventually("viewer controller", timeout: .seconds(10)) { app.env.computers.activeViewer != nil }
                guard let viewer = app.env.computers.activeViewer else { return }
                try await Self.waitLive(viewer, "first connection goes live")
                #expect(viewer.ticketsRequested >= 1)

                // Reconectar por cima de uma conexão viva: o RFB velho fecha depois; a conexão nova segue viva e sem aviso falso.
                viewer.reconnectNow()
                try await Self.waitLive(viewer, "reconnect on top of a live connection")
                try await Task.sleep(for: .seconds(4))
                #expect(viewer.model.connection == .live, "o disconnect tardio do RFB velho derrubou a conexão nova: \(viewer.model.connection)")
                let ticketsAfterReconnect = viewer.ticketsRequested
                #expect(ticketsAfterReconnect >= 2, "cada conexão pede ticket novo")

                // Queda abrupta: a reconexão automática pede ticket novo e volta sozinha.
                viewer.web.dropConnectionForTesting()
                try await eventually("drop is noticed", timeout: .seconds(15)) { viewer.model.connection != .live }
                try await Self.waitLive(viewer, "automatic reconnect after a drop", timeout: .seconds(45))
                #expect(viewer.ticketsRequested > ticketsAfterReconnect, "a reconexão automática pediu ticket novo")

                // Voltar à sessão pelo botão e abrir de novo: viewer novo, ticket novo, vivo.
                _ = try await app.env.registry.perform(.pageClose, .press)
                #expect(app.env.computers.page == .workspace)
                try await AppKeyboardFlowTests.assertTyping("after the live viewer closed", app)
                app.env.computers.openViewer("live-a")
                try await eventually("viewer controller again", timeout: .seconds(10)) { app.env.computers.activeViewer != nil }
                if let again = app.env.computers.activeViewer { try await Self.waitLive(again, "second open goes live") }
                _ = try await app.env.registry.perform(.pageClose, .press)
            }
        } catch {
            await rig.cleanup()
            try? FileManager.default.removeItem(at: home)
            throw error
        }
        await rig.cleanup()
        try? FileManager.default.removeItem(at: home)
    }
}
