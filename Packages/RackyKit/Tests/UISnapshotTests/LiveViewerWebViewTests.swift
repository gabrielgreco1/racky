import RackyCore
import AppKit
import Foundation
import Testing

@testable import RackyUI

/// T3-05 / S3 com o Docker real (`RACKY_TEST_DOCKER=1`): o noVNC dentro do WKWebView isolado, ligado a um computador de verdade
/// pelo ticket e pelo túnel do egress. Mede fps (página animada) e latência de input (humano no controle), com a janela visível
/// e com ela fora da tela. Só toca em recursos `racky.test=1` + `racky.test_run=<id>`.
@MainActor
@Suite("T3-05 - noVNC no WKWebView com o Docker real", .serialized, .enabled(if: ProcessInfo.processInfo.environment["RACKY_TEST_DOCKER"] == "1"), .tags(.integration), .timeLimit(.minutes(10)), .offscreenAppKit)
struct LiveViewerWebViewTests {
    static var repoRoot: URL {
        var root = URL(fileURLWithPath: #filePath)
        while root.path != "/", !FileManager.default.fileExists(atPath: root.appendingPathComponent("runtime/computer/Dockerfile").path) {
            root.deleteLastPathComponent()
        }
        return root
    }

    @Test func novncInTheIsolatedWebViewStreamsAnimationAndFollowsTheLease() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("abx-webview-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let rig = try await DemoComputerRig.provision(repoRoot: Self.repoRoot, home: home, name: "webview-a")
        do {
            try await scenario(rig: rig)
        } catch {
            await rig.cleanup()
            try? FileManager.default.removeItem(at: home)
            throw error
        }
        await rig.cleanup()
        try? FileManager.default.removeItem(at: home)
    }

    func scenario(rig: DemoComputerRig) async throws {
        let computer = rig.computer
        _ = try await computer.backend.runtime("eval", DemoComputerRig.installScript(DemoComputerRig.animationHTML), timeout: 15)

        let controller = ComputerViewerController(computer: computer)
        var events: [String] = []
        let original = controller.web.onEvent
        controller.web.onEvent = { event in
            if events.count < 40 { events.append("\(event)") }
            original(event)
        }
        let window = OffscreenAppKit.makeWindow(size: NSSize(width: 1000, height: 640), styleMask: [.titled])
        window.isReleasedWhenClosed = false
        window.contentView = controller.web
        await controller.start()
        for _ in 0..<80 where controller.model.connection != .live { try await Task.sleep(for: .milliseconds(250)) }
        #expect(controller.model.connection == .live, "the viewer never went live: \(controller.model.connection) info \(controller.web.streamInfo) events \(events)")

        // agente no controle: view-only, borda e pill (o runtime recusa o input; o WebView também)
        #expect(controller.model.control == .agent && !controller.model.inputEnabled)

        let result = await controller.measure(seconds: 8) {
            _ = try? await computer.backend.runtime("eval", DemoComputerRig.installScript(DemoComputerRig.inputHTML), timeout: 15)
        }
        let snapshot = await controller.web.snapshotPNG()
        #expect((snapshot?.count ?? 0) > 5_000)
        #expect(controller.model.control == .human && controller.model.inputEnabled)
        let record = """
        {"fps_average": \(result.fpsAverage), "fps_min": \(result.fpsMin), "fps_samples": \(result.fpsSamples),
         "latency_p50_ms": \(result.latencyP50Ms), "latency_p95_ms": \(result.latencyP95Ms), "latency_samples": \(result.latencySamplesMs.count),
         "ws_messages": \(result.wsMessages), "ws_bytes": \(result.wsBytes), "page_hidden": \(result.pageHidden),
         "window_visible": \(result.windowVisible), "app_active": \(result.appActive)}
        """
        if let root = ProcessInfo.processInfo.environment["RACKY_EVIDENCE_DIR"] {
            let url = URL(fileURLWithPath: root).appendingPathComponent("spikes/S3/webview-test-results.json")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(record.utf8).write(to: url)
        }
        #expect(result.fpsAverage >= 20, "noVNC in the WKWebView ran at \(result.fpsAverage) fps: \(record)")
        #expect(result.latencySamplesMs.count >= 30 && result.latencyP95Ms < 100, "input latency p95 \(result.latencyP95Ms) ms: \(record)")
        await controller.handBack()
        #expect(controller.model.control == .agent)
        controller.stop()
        window.close()
    }
}
