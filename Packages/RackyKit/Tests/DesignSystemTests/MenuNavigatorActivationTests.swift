import Testing

@testable import RackyDesignSystem

/// Extensões do navegador usadas pelo Quick Launch (03 §7): linha de fallback com o texto digitado e o modificador da ativação.
@MainActor
@Suite(.offscreenAppKit) struct MenuNavigatorActivationTests {
    private func navigator() -> DSMenuNavigator {
        let nav = DSMenuNavigator(
            entries: [.item(DSMenuItem("claude", "New Claude Code Tab")), .item(DSMenuItem("codex", "New Codex Tab")), .item(DSMenuItem("terminal", "New Terminal"))],
            searchable: true)
        nav.emptyFallback = { text in DSMenuItem("fallback", "Start Claude Code with \"\(text)\"") }
        return nav
    }

    @Test func textThatMatchesNothingOffersTheFallbackRowAndHighlightsIt() {
        let nav = navigator()
        nav.type("fix the pagination bug")
        #expect(nav.visibleItems.map(\.id) == ["fallback"])
        #expect(nav.highlightedID == "fallback")
        #expect(nav.visibleItems.first?.title == "Start Claude Code with \"fix the pagination bug\"")
        #expect(!nav.isEmptyResult)
        #expect(nav.handle(.enter) == .activate(nav.visibleItems[0]))
    }

    @Test func textThatMatchesAnItemKeepsTheMatchesAndHidesTheFallback() {
        let nav = navigator()
        nav.type("codex")
        #expect(nav.visibleItems.map(\.id) == ["codex"])
        nav.setQuery("")
        #expect(nav.visibleItems.count == 3)
    }

    @Test func activationRecordsTheModifier() {
        let nav = navigator()
        #expect(nav.activation == .plain)
        _ = nav.handle(.enter, activation: .command)
        #expect(nav.activation == .command)
        _ = nav.handle(.enter, activation: .shift)
        #expect(nav.activation == .shift)
        _ = nav.handle(.down)
        #expect(nav.activation == .plain, "teclas comuns voltam ao modo simples")
    }
}
