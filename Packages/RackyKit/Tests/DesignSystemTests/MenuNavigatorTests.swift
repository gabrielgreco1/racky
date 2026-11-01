import AppKit
import SwiftUI
import Testing

@testable import RackyDesignSystem

/// Teclado de menus e comboboxes (02 §12.11, §12.15): destaque, busca, type-ahead, submenu. Sem janela.
@MainActor
@Suite(.offscreenAppKit) struct MenuNavigatorTests {
    private func item(_ id: String, _ title: String? = nil, disabled: Bool = false, pinned: Bool = false, sub: [DSMenuEntry] = []) -> DSMenuEntry {
        .item(DSMenuItem(id, title ?? id, disabledReason: disabled ? "Not installed" : nil, pinned: pinned, submenu: sub))
    }

    private var agents: [DSMenuEntry] {
        [item("claude", "Claude Code"), item("codex", "Codex"), item("opencode", "OpenCode", disabled: true), .separator("a"), item("shell", "Blank Terminal"), item("manage", "Manage Agents…", pinned: true)]
    }

    @Test func startsOnTheSelectedItemOrTheFirstEnabledOne() {
        #expect(DSMenuNavigator(entries: agents).highlightedID == "claude")
        #expect(DSMenuNavigator(entries: agents, selectedID: "codex").highlightedID == "codex")
        // Selecionado desabilitado: cai no primeiro habilitado.
        #expect(DSMenuNavigator(entries: agents, selectedID: "opencode").highlightedID == "claude")
    }

    @Test func arrowsSkipDisabledItemsAndStopAtTheEnds() {
        let nav = DSMenuNavigator(entries: agents)
        #expect(nav.handle(.up) == .none && nav.highlightedID == "claude", "não dá a volta no início")
        _ = nav.handle(.down)
        #expect(nav.highlightedID == "codex")
        _ = nav.handle(.down)
        #expect(nav.highlightedID == "shell", "OpenCode está desabilitado")
        _ = nav.handle(.down)
        #expect(nav.highlightedID == "manage")
        _ = nav.handle(.down)
        #expect(nav.highlightedID == "manage", "não dá a volta no fim")
        _ = nav.handle(.home)
        #expect(nav.highlightedID == "claude")
        _ = nav.handle(.end)
        #expect(nav.highlightedID == "manage")
    }

    @Test func enterActivatesTheHighlightedItemAndEscapeDismisses() {
        let nav = DSMenuNavigator(entries: agents)
        _ = nav.handle(.down)
        if case .activate(let it) = nav.handle(.enter) { #expect(it.id == "codex") } else { Issue.record("Enter deveria ativar") }
        #expect(nav.handle(.escape) == .dismiss)
    }

    @Test func disabledItemsNeverActivateAndHoverIgnoresThem() {
        let nav = DSMenuNavigator(entries: agents)
        nav.hover("opencode")
        #expect(nav.highlightedID == "claude")
        nav.hover("shell")
        #expect(nav.highlightedID == "shell")
    }

    @Test func searchAppearsAboveSevenItems() {
        #expect(!DSMenuNavigator.shouldSearch(itemCount: 7))
        #expect(DSMenuNavigator.shouldSearch(itemCount: 8))
    }

    @Test func typingFiltersWhenSearchableAndKeepsPinnedItems() {
        let nav = DSMenuNavigator(entries: agents, searchable: true)
        nav.type("co")
        #expect(nav.visibleItems.map(\.id) == ["claude", "codex", "opencode", "manage"], "casa o título (OpenCode tem \"co\"); o rodapé fixo continua")
        #expect(nav.highlightedID == "claude")
        nav.type("dex")
        #expect(nav.visibleItems.map(\.id) == ["codex", "manage"])
        #expect(nav.highlightedID == "codex", "o destaque acompanha o primeiro resultado")
        _ = nav.handle(.backspace)
        #expect(nav.query == "code")
        // Esc limpa a busca antes de fechar.
        #expect(nav.handle(.escape) == .none && nav.query.isEmpty)
        #expect(nav.handle(.escape) == .dismiss)
    }

    @Test func noMatchLeavesOnlyPinnedItemsAndReportsEmptyResult() {
        let nav = DSMenuNavigator(entries: agents, searchable: true)
        nav.type("zzz")
        #expect(nav.isEmptyResult)
        #expect(nav.visibleItems.map(\.id) == ["manage"])
    }

    @Test func typeAheadJumpsByPrefixWithoutFilteringAndResetsAfterAPause() {
        let nav = DSMenuNavigator(entries: agents)
        let t0 = ContinuousClock.now
        nav.type("b", now: t0)
        #expect(nav.highlightedID == "shell", "Blank Terminal")
        #expect(nav.visibleItems.count == agents.compactMap(\.item).count, "type-ahead não filtra")
        nav.type("l", now: t0 + .milliseconds(300))
        #expect(nav.query == "bl" && nav.highlightedID == "shell", "o buffer acumula o prefixo (Blank)")
        nav.type("c", now: t0 + .seconds(2))
        #expect(nav.query == "c", "depois de 1 s o buffer recomeça")
        #expect(nav.highlightedID == "claude")
    }

    @Test func controlCharactersAreNotTyped() {
        let nav = DSMenuNavigator(entries: agents, searchable: true)
        nav.type("\u{7f}\r\t")
        #expect(nav.query.isEmpty)
    }

    @Test func compositionTextIsHeldUntilCommitted() {
        let nav = DSMenuNavigator(entries: agents, searchable: true)
        nav.setMarked("こ")
        #expect(nav.query.isEmpty && nav.marked == "こ")
        nav.type("こ")
        #expect(nav.query == "こ" && nav.marked.isEmpty)
    }

    @Test func submenuOpensWithRightEnterAndClosesWithLeftThenEscape() {
        let sub: [DSMenuEntry] = [item("c1", "Computer 1"), item("c2", "Computer 2")]
        let nav = DSMenuNavigator(entries: [item("start", "Start Claude"), item("open", "Open Computer…", sub: sub)])
        _ = nav.handle(.down)
        #expect(nav.handle(.right) == .none)
        #expect(nav.openSubmenuID == "open" && nav.submenu?.highlightedID == "c1")
        _ = nav.handle(.down)
        if case .activate(let it) = nav.handle(.enter) { #expect(it.id == "c2") } else { Issue.record("o item do submenu deveria ativar") }
        #expect(nav.handle(.left) == .none && nav.submenu == nil, "← fecha só o submenu")
        #expect(nav.handle(.enter) == .none && nav.submenu != nil, "Enter em item com submenu abre")
        #expect(nav.handle(.escape) == .none && nav.submenu == nil, "Esc fecha o submenu antes do menu")
        #expect(nav.handle(.escape) == .dismiss)
    }

    @Test func rowOffsetsUseFixedRowHeights() {
        let nav = DSMenuNavigator(entries: agents)
        #expect(nav.rowOffset(of: "claude") == 0)
        #expect(nav.rowOffset(of: "codex") == DSMetrics.menuItemHeight)
        #expect(nav.rowOffset(of: "shell") == DSMetrics.menuItemHeight * 3 + DSMetrics.menuSeparatorHeight)
    }

    @Test func keyCatcherTranslatesCommandSelectorsToKeys() {
        let nav = DSMenuNavigator(entries: agents)
        var outcomes: [DSMenuOutcome] = []
        let view = DSKeyCatcherView()
        view.navigator = nav
        view.onOutcome = { outcomes.append($0) }
        view.doCommand(by: #selector(NSResponder.moveDown(_:)))
        #expect(nav.highlightedID == "codex")
        view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(outcomes.count == 1)
        view.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(outcomes.last == .dismiss)
        view.insertText("b", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(nav.highlightedID == "shell", "texto vira type-ahead")
        view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText() && nav.marked == "か")
    }
}

/// Espera até `timeout` s a condição valer (a main thread é compartilhada com outras suítes em paralelo).
@MainActor
func waitUntil(_ timeout: Double = 3, _ condition: @MainActor () -> Bool) async -> Bool {
    let end = ContinuousClock.now + .seconds(timeout)
    while ContinuousClock.now < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@MainActor
@Suite(.offscreenAppKit) struct TooltipPolicyTests {
    @Test func delaysComeFromTheTokens() {
        #expect(TooltipDelay.standard.seconds == 0.4)
        #expect(TooltipDelay.tab.seconds == 0.5)
        #expect(TooltipDelay.tabClose.seconds == 1.0)
        #expect(TooltipDelay.stateDot.seconds == 0.2)
    }

    @Test func chainedTooltipsOpenWithoutDelay() {
        let base = TooltipDelay.standard.seconds
        #expect(TooltipController.effectiveDelay(base: base, tooltipVisible: false, hiddenAgo: nil) == base)
        #expect(TooltipController.effectiveDelay(base: base, tooltipVisible: true, hiddenAgo: nil) == 0, "outro tooltip visível")
        #expect(TooltipController.effectiveDelay(base: base, tooltipVisible: false, hiddenAgo: 0.29) == 0, "escondido há menos de 300 ms")
        #expect(TooltipController.effectiveDelay(base: base, tooltipVisible: false, hiddenAgo: 0.31) == base)
    }

    /// Controlador com agendador e relógio virtuais: o atraso é cumprido por ordem de eventos, não por tempo real.
    func makeController() -> (TooltipController, ManualScheduler) {
        let scheduler = ManualScheduler()
        let controller = TooltipController()
        controller.sleep = scheduler.sleep
        controller.clock = { scheduler.now }
        let motion = MotionPolicy()
        motion.mode = .instant
        controller.motion = motion
        controller.isWindowActive = { _ in true }
        return (controller, scheduler)
    }

    @Test func showsAfterTheDelayAndNotBefore() async {
        let (controller, scheduler) = makeController()
        let window = OffscreenAppKit.makeWindow(size: NSSize(width: 200, height: 100), styleMask: [.titled])
        window.isReleasedWhenClosed = false
        defer { controller.dismiss(); window.close() }
        let key = UUID()
        controller.hoverBegan(key: key, content: TooltipContent("Split Right", shortcut: "⌘D"), delay: 0.2, side: .bottom, window: window) {
            NSRect(x: -3900, y: -3950, width: 28, height: 28)
        }
        #expect(!controller.isVisible, "ainda dentro do atraso")
        await scheduler.waitForSleepers()
        await scheduler.advance(by: 0.19)
        #expect(!controller.isVisible, "o atraso de 0,2 s ainda não venceu")
        await scheduler.advance(by: 0.02)
        #expect(controller.visibleKey == key)
        #expect(controller.currentContent == TooltipContent("Split Right", shortcut: "⌘D"))
    }

    @Test func leavingBeforeTheDelayCancelsAndClickDismisses() async {
        let (controller, scheduler) = makeController()
        let window = OffscreenAppKit.makeWindow(size: NSSize(width: 200, height: 100), styleMask: [.titled])
        window.isReleasedWhenClosed = false
        defer { controller.dismiss(); window.close() }
        let key = UUID()
        let anchor: () -> NSRect? = { NSRect(x: -3900, y: -3950, width: 28, height: 28) }
        controller.hoverBegan(key: key, content: TooltipContent("Back"), delay: 0.15, side: .bottom, window: window, anchor: anchor)
        controller.hoverEnded(key: key)
        await scheduler.advance(by: 1)
        #expect(!controller.isVisible, "saiu antes do atraso")
        controller.hoverBegan(key: key, content: TooltipContent("Back"), delay: 0.05, side: .bottom, window: window, anchor: anchor)
        await scheduler.waitForSleepers()
        await scheduler.advance(by: 0.05)
        #expect(controller.isVisible)
        controller.dismiss()
        #expect(!controller.isVisible, "clique, rolagem ou tecla fecham")
    }

    @Test func windowLosingKeyHidesTheTooltipImmediately() async throws {
        let (controller, scheduler) = makeController()
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { controller.dismiss(); window.close() }
        controller.hoverBegan(key: UUID(), content: TooltipContent("Path"), delay: 0.05, side: .bottom, window: window) {
            NSRect(x: -3900, y: -3950, width: 28, height: 28)
        }
        await scheduler.waitForSleepers()
        await scheduler.advance(by: 0.05)
        #expect(controller.isVisible)
        // NSOpenPanel/sheet/outro app: o mouseExited nunca chega, a notificação esconde o balão.
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!controller.isVisible)
    }

    @Test func suppressedControllerNeverOpens() async {
        let (controller, scheduler) = makeController()
        controller.isSuppressed = { true }
        controller.hoverBegan(key: UUID(), content: TooltipContent("x"), delay: 0, side: .top, window: nil) { .zero }
        await scheduler.advance(by: 1)
        #expect(!controller.isVisible && controller.pendingKey == nil)
    }

    @Test func secondTooltipWithinTheChainWindowOpensImmediately() async {
        let (controller, scheduler) = makeController()
        let window = OffscreenAppKit.makeWindow(size: NSSize(width: 200, height: 100), styleMask: [.titled])
        window.isReleasedWhenClosed = false
        defer { controller.dismiss(); window.close() }
        let anchor: () -> NSRect? = { NSRect(x: -3900, y: -3950, width: 28, height: 28) }
        let a = UUID(), b = UUID()
        controller.hoverBegan(key: a, content: TooltipContent("A"), delay: 0, side: .bottom, window: window, anchor: anchor)
        await scheduler.advance(by: 0)
        #expect(controller.visibleKey == a)
        controller.hoverEnded(key: a)
        controller.hoverBegan(key: b, content: TooltipContent("B"), delay: 5, side: .bottom, window: window, anchor: anchor)
        await scheduler.advance(by: 0)
        #expect(controller.visibleKey == b, "base de 5 s ignorada: um tooltip acabou de fechar, sem avançar o tempo")
    }

    @Test func bubbleSizesToItsContentAndCapsAt280() {
        DSFonts.registerIfNeeded()
        let margin = TooltipController.panelMargin * 2
        func width(_ content: TooltipContent) -> CGFloat {
            let model = TooltipModel()
            model.content = content
            let host = NSHostingView(rootView: TooltipBubbleHost(model: model))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.width - margin
        }
        let short = width(TooltipContent("Settings"))
        #expect(short > 40 && short < 120, "balão curto não estica: \(short)")
        #expect(width(TooltipContent("Split Right", shortcut: "⌘D")) > short)
        let long = width(TooltipContent(String(repeating: "Take over to interact. ", count: 10)))
        #expect(long <= DS.Layout.tooltipMaxWidth + 0.5, "máx. 280: \(long)")
    }
}
