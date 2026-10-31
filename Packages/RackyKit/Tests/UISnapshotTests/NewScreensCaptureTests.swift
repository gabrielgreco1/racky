import RackyCore
import RackyProtocol
import RackyDesignSystem
import AppKit
import SwiftUI
import Testing

@testable import RackyUI

/// Capturas das telas novas para a rodada de testers (só com `RACKY_CAPTURE_DIR`): o pane de um computador encerrado, a linha do
/// "Needs You" e a tabela numa tab da sessão na aba Overview.
@MainActor
@Suite(.serialized, .offscreenAppKit, .tags(.integration)) struct NewScreensCaptureTests {
    private func write(_ view: NSView, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["RACKY_CAPTURE_DIR"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    @Test func captureNewScreens() async throws {
        guard ProcessInfo.processInfo.environment["RACKY_CAPTURE_DIR"] != nil else { return }
        let gone = NSHostingView(rootView: GoneComputerPane(name: "email-tabacaria-green", close: {}, showAgent: {}, showRuns: {}).frame(width: 900, height: 560))
        gone.frame = NSRect(x: 0, y: 0, width: 900, height: 560)
        let w1 = NSWindow(contentRect: gone.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w1.appearance = NSAppearance(named: .darkAqua)
        w1.contentView = gone
        await VisualBatchTests.settle(300)
        write(gone, "gone-computer")

        let items = [
            InboxItem(id: "a", computer: "mail-registos", summary: HelpSummary(id: "a", kind: .permission, reason: "Permission", host: nil), createdAt: Date()),
            InboxItem(id: "b", computer: "mail-nifpt-mj", summary: HelpSummary(id: "b", kind: .captcha, reason: "CAPTCHA", host: "nif.pt"), createdAt: Date()),
        ]
        let rows = NSHostingView(rootView: VStack(spacing: 4) { ForEach(items) { HelpRequestRowView(item: $0) } }
            .padding(8).frame(width: 280).background(DS.Color.sidebar))
        rows.frame = NSRect(x: 0, y: 0, width: 280, height: 140)
        let w2 = NSWindow(contentRect: rows.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w2.appearance = NSAppearance(named: .darkAqua)
        w2.contentView = rows
        await VisualBatchTests.settle(300)
        write(rows, "needs-you-rows")
    }
}
