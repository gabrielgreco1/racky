import RackyDesignSystem
import RackyProtocol
import AppKit
import SwiftUI
import Testing

@testable import RackyUI

/// Menus e comboboxes dentro da janela (02 §12.11, §12.15): foco, Esc, teclado pelo `NSWindow`, geometria, fatias.
extension OverlayHostTests {
@MainActor
@Suite(.serialized, .offscreenAppKit) struct PopoverTests {
    final class FakeTerminal: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    final class Recorder {
        var calls: [String] = []
    }

    struct Rig {
        let env: AppEnvironment
        let controller: MainWindowController
        let window: NSWindow
        let host: OverlayHostingView
        let terminal: FakeTerminal
        let recorder: Recorder
    }

    func rig() async -> Rig {
        let env = AppEnvironment(environment: [:])
        let motion = MotionPolicy()
        motion.mode = .instant
        env.overlays.motion = motion
        env.toasts.motion = motion
        let recorder = Recorder()
        env.registry.replace(.composerSetAgent) { arg in
            recorder.calls.append("setAgent:\(arg.value ?? "-")")
            return nil
        }
        env.registry.replace(.composerManageAgents) { _ in
            recorder.calls.append("manage")
            return nil
        }
        let controller = await EmptyWindowTreeTests.host(env, size: NSSize(width: 1000, height: 700))
        let window = controller.window!
        let terminal = FakeTerminal(frame: NSRect(x: 300, y: 100, width: 300, height: 200))
        window.contentView!.addSubview(terminal, positioned: .below, relativeTo: window.contentView!.subviews.last)
        window.makeFirstResponder(terminal)
        let host = window.contentView!.subviews.compactMap { $0 as? OverlayHostingView }.first!
        return Rig(env: env, controller: controller, window: window, host: host, terminal: terminal, recorder: recorder)
    }

    func teardown(_ r: Rig) {
        r.window.close()
    }

    static let agents: [DSMenuEntry] = [
        .item(DSMenuItem("claude", "Claude Code", icon: .agent(.claude))),
        .item(DSMenuItem("codex", "Codex", icon: .agent(.codex))),
        .item(DSMenuItem("opencode", "OpenCode", disabledReason: "Not installed")),
        .separator("pinned"),
        .item(DSMenuItem("manage", "Manage Agents…", pinned: true, action: .composerManageAgents)),
    ]

    func comboboxSpec(_ r: Rig, selection: String = "claude") -> PopoverSpec {
        DSCombobox.popoverSpec(
            id: .overlayComposerAgent, selection: selection, entries: Self.agents, action: .composerSetAgent, searchPlaceholder: "Search agents…",
            anchor: CGRect(x: 100, y: 200, width: 240, height: 32), registry: r.env.registry)
    }

    func key(_ code: UInt16, _ chars: String, flags: NSEvent.ModifierFlags = [], window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    func arrow(_ scalar: Int, _ code: UInt16, window: NSWindow) -> NSEvent {
        key(code, String(UnicodeScalar(scalar)!), flags: [.numericPad, .function], window: window)
    }

    /// Espera o `DSKeyCatcherView` do painel receber o foco (acontece um ciclo depois de montar).
    func awaitKeyCatcher(_ r: Rig) async -> DSKeyCatcherView? {
        for _ in 0..<80 {
            if let catcher = r.window.firstResponder as? DSKeyCatcherView { return catcher }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return nil
    }

    // MARK: Foco e Esc

    @Test func popoverFromTheTitlebarCapturesTheKeyboardAndReturnsItToTheTerminal() async {
        let r = await rig()
        defer { teardown(r) }
        #expect(r.window.firstResponder === r.terminal)
        r.env.overlays.presentPopover(comboboxSpec(r))
        #expect(r.env.overlays.capturesInput && r.env.overlays.blocksTerminalInput)
        #expect(!r.env.overlays.isPresenting, "popover não é overlay")
        let catcher = await awaitKeyCatcher(r)
        #expect(catcher != nil, "o painel recebe o foco do teclado")
        r.env.overlays.dismissPopover()
        #expect(r.window.firstResponder === r.terminal, "o terminal volta a receber teclas")
        #expect(!r.env.overlays.capturesInput)
    }

    @Test func escapeClosesThePopoverFirstAndThenTheOverlay() async {
        let r = await rig()
        defer { teardown(r) }
        let spec = OverlaySpec(name: "composer", id: .overlayComposer, content: { AnyView(Color.clear.frame(width: 200, height: 100)) })
        r.env.overlays.present(spec)
        r.env.overlays.presentPopover(comboboxSpec(r))
        _ = await awaitKeyCatcher(r)
        // Esc de verdade pela janela: o `DSKeyCatcherView` o entende e fecha só o painel.
        r.window.sendEvent(key(53, "\u{1b}", window: r.window))
        #expect(r.env.overlays.popover == nil, "Esc fecha o painel")
        #expect(r.env.overlays.isPresenting, "o overlay continua aberto")
        #expect(r.window.firstResponder != nil && r.window.firstResponder !== r.terminal, "o foco volta ao overlay, não ao terminal")
        r.env.overlays.escapePressed()
        #expect(!r.env.overlays.isPresenting)
        #expect(r.window.firstResponder === r.terminal)
    }

    @Test func popoverClosesWhenItsOverlayCloses() async {
        let r = await rig()
        defer { teardown(r) }
        let spec = OverlaySpec(name: "composer", id: .overlayComposer, content: { AnyView(Color.clear.frame(width: 200, height: 100)) })
        r.env.overlays.present(spec)
        r.env.overlays.presentPopover(comboboxSpec(r))
        r.env.overlays.dismiss(.action)
        #expect(r.env.overlays.popover == nil)
        #expect(r.window.firstResponder === r.terminal)
    }

    @Test func openingAnotherPopoverReplacesTheFirst() async {
        let r = await rig()
        defer { teardown(r) }
        r.env.overlays.presentPopover(comboboxSpec(r))
        let first = r.env.overlays.popover?.id
        r.env.overlays.presentPopover(comboboxSpec(r, selection: "codex"))
        #expect(r.env.overlays.popover?.id != first)
        r.env.overlays.dismissPopover()
        #expect(r.window.firstResponder === r.terminal)
    }

    @Test func motionEventsRecordM105() async {
        let r = await rig()
        defer { teardown(r) }
        r.env.overlays.presentPopover(comboboxSpec(r))
        r.env.overlays.dismissPopover()
        #expect(r.env.overlays.events.map(\.name) == ["M-105 begin", "M-105 end"])
    }

    // MARK: Teclado pela janela

    @Test func arrowsAndReturnChooseAnItemAndRunItsAction() async {
        let r = await rig()
        defer { teardown(r) }
        r.env.overlays.presentPopover(comboboxSpec(r))
        _ = await awaitKeyCatcher(r)
        r.window.sendEvent(arrow(NSDownArrowFunctionKey, 125, window: r.window))
        r.window.sendEvent(key(36, "\r", window: r.window))
        try? await Task.sleep(for: .milliseconds(80))
        #expect(r.recorder.calls == ["setAgent:codex"], "↓ vai a Codex, ↵ escolhe")
        #expect(r.env.overlays.popover == nil)
        #expect(r.window.firstResponder === r.terminal)
    }

    @Test func downArrowSkipsDisabledItemsAndFooterItemRunsItsOwnAction() async {
        let r = await rig()
        defer { teardown(r) }
        r.env.overlays.presentPopover(comboboxSpec(r, selection: "codex"))
        _ = await awaitKeyCatcher(r)
        r.window.sendEvent(arrow(NSDownArrowFunctionKey, 125, window: r.window))  // pula OpenCode (desabilitado)
        r.window.sendEvent(key(36, "\r", window: r.window))
        try? await Task.sleep(for: .milliseconds(80))
        #expect(r.recorder.calls == ["manage"])
    }

    @Test func typingJumpsByPrefixAndEscapeChoosesNothing() async {
        let r = await rig()
        defer { teardown(r) }
        r.env.overlays.presentPopover(comboboxSpec(r))
        _ = await awaitKeyCatcher(r)
        r.window.sendEvent(key(8, "c", window: r.window))
        r.window.sendEvent(key(31, "o", window: r.window))
        r.window.sendEvent(key(2, "d", window: r.window))
        r.window.sendEvent(key(36, "\r", window: r.window))
        try? await Task.sleep(for: .milliseconds(80))
        #expect(r.recorder.calls == ["setAgent:codex"], "digitar \"cod\" destaca Codex")
        r.env.overlays.presentPopover(comboboxSpec(r))
        _ = await awaitKeyCatcher(r)
        r.window.sendEvent(key(53, "\u{1b}", window: r.window))
        try? await Task.sleep(for: .milliseconds(80))
        #expect(r.recorder.calls.count == 1, "Esc não escolhe")
        #expect(r.env.overlays.popover == nil)
    }

    @Test func commandKeysStillReachTheMenuBar() async {
        let r = await rig()
        defer { teardown(r) }
        r.env.overlays.presentPopover(comboboxSpec(r))
        let catcher = await awaitKeyCatcher(r)
        #expect(catcher != nil)
        // ⌘ + tecla não é digitação: não altera o type-ahead do painel.
        catcher?.keyDown(with: key(8, "c", flags: .command, window: r.window))
        #expect(catcher?.navigator?.query.isEmpty == true)
    }

    // MARK: Geometria e fatias

    @Test func placementOpensBelowAndFlipsAboveNearTheBottom() {
        let container = CGSize(width: 1000, height: 700)
        let below = PopoverGeometry.place(
            anchor: CGRect(x: 100, y: 100, width: 240, height: 32), size: CGSize(width: 240, height: 120), container: container,
            alignment: .leading, gap: 4, margin: 8)
        #expect(below.below && below.origin == CGPoint(x: 100, y: 136) && below.anchor.y == 0)
        let above = PopoverGeometry.place(
            anchor: CGRect(x: 100, y: 640, width: 240, height: 32), size: CGSize(width: 240, height: 200), container: container,
            alignment: .leading, gap: 4, margin: 8)
        #expect(!above.below && above.origin.y == 640 - 4 - 200 && above.anchor.y == 1)
    }

    @Test func placementClampsToTheWindowAndSupportsTrailingAlignment() {
        let container = CGSize(width: 400, height: 700)
        let right = PopoverGeometry.place(
            anchor: CGRect(x: 350, y: 100, width: 40, height: 24), size: CGSize(width: 220, height: 100), container: container,
            alignment: .leading, gap: 4, margin: 8)
        #expect(right.origin.x == CGFloat(172), "preso à margem direita")
        let trailing = PopoverGeometry.place(
            anchor: CGRect(x: 300, y: 100, width: 80, height: 24), size: CGSize(width: 220, height: 100), container: container,
            alignment: .trailing, gap: 4, margin: 8)
        #expect(trailing.origin.x == CGFloat(160))
    }

    @Test func resolveDisablesUnregisteredActionsAndDropsFutureSlices() {
        let env = AppEnvironment(environment: ["RACKY_SLICE": "1"])
        try? env.registry.register(.appHideAppName) { _ in nil }
        let future = ActionID.catalog.first { $0.slice > .slice1 && $0.slice < .v11 }!.id
        let entries: [DSMenuEntry] = [
            .item(DSMenuItem("hide", "Hide App Name", action: .appHideAppName)),
            .separator("a"),
            .item(DSMenuItem("about", "About", action: .appAbout)),
            .separator("b"),
            .item(DSMenuItem("later", "Later", action: future)),
        ]
        let resolved = DSMenuPanel.resolve(entries, registry: env.registry)
        let items = resolved.compactMap(\.item)
        #expect(items.map(\.id) == ["hide", "about"], "ação de fatia futura não é renderizada (AC-T28)")
        #expect(items.first { $0.id == "hide" }?.isEnabled == true)
        #expect(items.first { $0.id == "about" }?.disabledReason != nil, "sem handler: desabilitado com motivo")
        #expect(resolved.last?.item != nil, "separador órfão no fim sai")
    }

    @Test func appNameMenuListsTheSpecItems() {
        let titles = AppMenuEntries.entries.compactMap(\.item).map(\.title)
        #expect(titles == ["About Racky", "Settings…", "Check for Problems", "Hide App Name"])
        #expect(AppMenuEntries.entries.compactMap(\.item).first { $0.id == "settings" }?.shortcut == "⌘,")
    }

    @Test func appNameClickPresentsTheMenuPanel() async {
        let r = await rig()
        defer { teardown(r) }
        let anchor = r.env.elements.frame(of: .windowAppName)
        #expect(anchor != nil)
        let ok = DSMenuPanel.present(
            router: r.env.overlays, registry: r.env.registry, name: "appMenu", anchor: anchor ?? .zero, entries: AppMenuEntries.entries)
        #expect(ok && r.env.overlays.popover?.spec.id == .menuPanel("appMenu"))
    }
}
}
