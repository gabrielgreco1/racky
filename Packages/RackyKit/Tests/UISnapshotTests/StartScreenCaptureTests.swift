import AppKit
import Testing

@testable import RackyUI

/// Print da tela inicial na janela inteira, para revisar mudanças de visual. Só roda com `RACKY_CAPTURE_DIR=<pasta>`;
/// grava `<pasta>/start-<RACKY_CAPTURE_NAME ou "now">.png`.
@MainActor
@Suite(.serialized, .offscreenAppKit, .enabled(if: ProcessInfo.processInfo.environment["RACKY_CAPTURE_DIR"] != nil)) struct StartScreenCaptureTests {
    @Test func captureStartScreen() async {
        let info = ProcessInfo.processInfo.environment
        let env = VisualBatchTests.windowEnv()
        let c = await EmptyWindowTreeTests.host(env, size: NSSize(width: 1400, height: 860))
        defer { c.window?.close() }
        await VisualBatchTests.settle(800)
        let view = c.window!.contentView!
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let dir = URL(fileURLWithPath: info["RACKY_CAPTURE_DIR"]!)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("start-\(info["RACKY_CAPTURE_NAME"] ?? "now").png"))
    }
}
