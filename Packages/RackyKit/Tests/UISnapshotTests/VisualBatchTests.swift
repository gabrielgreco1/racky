import RackyDesignSystem
import RackyProtocol
import AppKit
import SwiftUI
import Testing

@testable import RackyUI

/// Evidência visual do lote de feedback do dono (OWNER-FEEDBACK F1–F6, F17): renderiza janela e componentes offscreen e grava PNGs
/// na pasta temporária `racky-visual-batch/<item>-<fase>.png`. Fase vem de `AB_VB_PHASE` (`before` | `after`; padrão `after`).
/// Só roda quando `AB_VB_CAPTURE=1` (não é teste de regressão: escreve arquivos no repositório).
@MainActor
@Suite(.serialized, .offscreenAppKit, .enabled(if: ProcessInfo.processInfo.environment["AB_VB_CAPTURE"] == "1")) struct VisualBatchTests {
    static var phase: String { ProcessInfo.processInfo.environment["AB_VB_PHASE"] ?? "after" }

    static var outDir: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("racky-visual-batch", isDirectory: true)
    }

    static func write(_ view: NSView, _ name: String, crop: NSRect? = nil) {
        view.layoutSubtreeIfNeeded()
        let rect = crop ?? view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return }
        view.cacheDisplay(in: rect, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try? png.write(to: outDir.appendingPathComponent("\(name)-\(phase).png"))
    }

    static func windowEnv(screen: String = SidebarFixtures.screenID) -> AppEnvironment {
        AppEnvironment(environment: ["RACKY_SCREEN": screen, "RACKY_SKIP_ONBOARDING": "1"])
    }

    static func settle(_ ms: Int = 500) async { try? await Task.sleep(for: .milliseconds(ms)) }

    @Test func f1TitlebarBrand() async {
        let env = Self.windowEnv()
        let c = await EmptyWindowTreeTests.host(env, size: NSSize(width: 1100, height: 700))
        defer { c.window?.close() }
        await Self.settle()
        let v = c.window!.contentView!
        Self.write(v, "F1-titlebar", crop: NSRect(x: 0, y: v.bounds.height - 120, width: 420, height: 120))
    }

    @Test func f2OverlayScrimCoversWindow() async {
        let env = Self.windowEnv()
        let c = await EmptyWindowTreeTests.host(env, size: NSSize(width: 1100, height: 700))
        defer { c.window?.close() }
        await Self.settle()
        env.overlays.motion.mode = .instant
        env.overlays.present(OverlaySpec(name: "vb", id: .overlayComposer, width: 480, content: { AnyView(Text(verbatim: "Dialog").padding(40)) }))
        await Self.settle()
        Self.write(c.window!.contentView!, "F2-scrim")
    }

    @Test func f3OpenCodeLogo() {
        DSFonts.registerIfNeeded()
        let row = HStack(spacing: 16) {
            DSAgentLogo(DSAgentKind.claude, size: 48)
            DSAgentLogo(DSAgentKind.codex, size: 48)
            DSAgentLogo(DSAgentKind.opencode, size: 48)
            DSAgentLogo(DSAgentKind.opencode, size: 16)
        }
        .padding(20).background(DS.Color.overlaySolid).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: row)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.appearance = NSAppearance(named: .darkAqua)
        Self.write(host, "F3-logos")
    }

    @Test func f4Onboarding() async {
        let env = Self.windowEnv(screen: AppEnvironment.setupDemoFixture)
        await env.settings.refreshAgents(force: false)
        let c = await EmptyWindowTreeTests.host(env, size: NSSize(width: 1100, height: 760))
        defer { c.window?.close() }
        env.overlays.motion.mode = .instant
        env.overlays.present(env.onboarding.overlaySpec())
        await Self.settle(700)
        Self.write(c.window!.contentView!, "F4-onboarding")
    }

    @Test func f5f6Settings() async throws {
        let env = Self.windowEnv(screen: AppEnvironment.setupDemoFixture)
        let c = await EmptyWindowTreeTests.host(env, size: NSSize(width: 1100, height: 700))
        defer { c.window?.close() }
        await env.settings.refreshAgents(force: false)
        _ = try await env.registry.perform(.settingsOpenSection, .select("agents"))
        _ = try await env.registry.perform(.appSettings, .press)
        await Self.settle(700)
        let v = c.window!.contentView!
        Self.write(v, "F5-settings-window")
        Self.write(v, "F6-agents", crop: NSRect(x: 240, y: v.bounds.height - 420, width: 860, height: 420))
    }

    /// F17: o menu de contexto de sessão no `DSMenuPanel` (antes era o `NSMenu` nativo, que não renderiza offscreen).
    @Test func f17SessionContextMenu() {
        DSFonts.registerIfNeeded()
        func e(_ a: ActionID, _ t: String) -> MenuEntry { MenuEntry(action: a, title: t) }
        let entries = ContextMenuStyle.entries(
            groups: [
                [e(.sessionRename, "Rename…"), e(.sessionEditNote, "Edit Note…")],
                [e(.itemOpenIn, "Open in…"), e(.itemRevealInFinder, "Reveal in Finder"), e(.itemCopyPath, "Copy Path")],
                [e(.sessionArchive, "Archive Session…"), e(.sessionDelete, "Delete Session…")],
            ], registry: nil)
        let nav = DSMenuNavigator(entries: entries)
        let panel = DSMenuPanelView(navigator: nav, width: DSMetrics.contextMenuWidth, solidSurface: true, itemFont: DS.Font.body) { _ in }
            .padding(24).background(DS.Color.canvas).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: panel)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.appearance = NSAppearance(named: .darkAqua)
        Self.write(host, "F17-session-menu")
    }
}
