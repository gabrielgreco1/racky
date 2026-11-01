import RackyCore
import RackyTerminalCore
import AppKit
import Foundation
import Testing

@testable import RackyUI

@Suite(.offscreenAppKit) struct ReplyAndPasteFilterTests {
    @Test func uiNeverAnswersAnOSC52Query() {
        let osc52 = Array("\u{1b}]52;c;\(Data("secret".utf8).base64EncodedString())\u{1b}\\".utf8)
        #expect(!UIReplyFilter.allows(osc52))
        #expect(!UIReplyFilter.allows([0x9d, 0x35, 0x32, 0x3b, 0x63, 0x3b, 0x41]))  // OSC C1 `52;c;A`
    }

    @Test func uiAnswersDeviceAndSizeQueries() {
        #expect(UIReplyFilter.allows(Array("\u{1b}[?1;2c".utf8)))  // DA1
        #expect(UIReplyFilter.allows(Array("\u{1b}[0n".utf8)))  // DSR
        #expect(UIReplyFilter.allows(Array("\u{1b}[8;30;100t".utf8)))  // tamanho
        #expect(UIReplyFilter.allows(Array("\u{1b}]11;rgb:2828/2c2c/3434\u{07}".utf8)))  // cor do fundo (a UI é o respondente)
    }

    @Test func headlessFilterStillRefusesWhatTheUIAllows() {
        // O daemon nunca responde cores; a UI responde (AR-105).
        let color = Array("\u{1b}]11;rgb:2828/2c2c/3434\u{07}".utf8)
        #expect(!QueryReplyFilter.allows(color))
        #expect(UIReplyFilter.allows(color))
    }

    @Test func pasteSanitizerRemovesEscapeAndControlsButKeepsTabAndNewline() {
        #expect(PasteSanitizer.sanitize("a\u{1b}[201~b") == "a[201~b")
        #expect(PasteSanitizer.sanitize("x\ty\nz") == "x\ty\nz")
        #expect(PasteSanitizer.sanitize("a\u{00}b\u{07}c\u{7f}d\u{85}e\rf") == "abcdef")
        #expect(PasteSanitizer.sanitize("日本語 héllo") == "日本語 héllo")
    }

    @Test func linkPolicyOpensOnlySimpleSchemes() {
        #expect(TerminalLinkPolicy.openableURL("https://example.com/a?b=1") != nil)
        #expect(TerminalLinkPolicy.openableURL("http://localhost:3000") != nil)
        #expect(TerminalLinkPolicy.openableURL("mailto:a@b.co") != nil)
        #expect(TerminalLinkPolicy.openableURL("file:///etc/passwd") == nil)
        #expect(TerminalLinkPolicy.openableURL("x-apple.systempreferences:com.apple.preference.security") == nil)
        #expect(TerminalLinkPolicy.openableURL("javascript:alert(1)") == nil)
        #expect(TerminalLinkPolicy.openableURL("https://") == nil)
        #expect(TerminalLinkPolicy.openableURL("") == nil)
        #expect(TerminalLinkPolicy.openableURL("/Users/x/file.swift") == nil)
    }

    @Test func optionAsMetaAutoFollowsTheLayout() {
        #expect(OptionAsMeta.auto.resolves(layoutID: "com.apple.keylayout.US"))
        #expect(OptionAsMeta.auto.resolves(layoutID: "com.apple.keylayout.ABC"))
        #expect(!OptionAsMeta.auto.resolves(layoutID: "com.apple.keylayout.Brazilian-ABNT2"))
        #expect(OptionAsMeta.always.resolves(layoutID: "com.apple.keylayout.Brazilian-ABNT2"))
        #expect(!OptionAsMeta.never.resolves(layoutID: "com.apple.keylayout.US"))
    }
}

/// AC-T08: tabela tecla -> bytes de 03 §21.
@Suite(.offscreenAppKit) struct KeyTableTests {
    @Test func reservedChordsProduceTheDocumentedBytes() {
        #expect(TerminalKeyTable.bytes(key: .leftArrow, modifiers: [.command]) == [0x01])
        #expect(TerminalKeyTable.bytes(key: .rightArrow, modifiers: [.command]) == [0x05])
        #expect(TerminalKeyTable.bytes(key: .delete, modifiers: [.command]) == [0x15])
        #expect(TerminalKeyTable.bytes(key: .return, modifiers: [.shift]) == Array("\u{1b}[13;2u".utf8))
        #expect(TerminalKeyTable.bytes(key: .leftArrow, modifiers: [.option]) == [0x1b, 0x62])
        #expect(TerminalKeyTable.bytes(key: .rightArrow, modifiers: [.option]) == [0x1b, 0x66])
    }

    @Test func extraModifiersAndPlainKeysAreNotIntercepted() {
        #expect(TerminalKeyTable.bytes(key: .leftArrow, modifiers: []) == nil)
        #expect(TerminalKeyTable.bytes(key: .return, modifiers: []) == nil)
        #expect(TerminalKeyTable.bytes(key: .leftArrow, modifiers: [.command, .shift]) == nil)
        #expect(TerminalKeyTable.bytes(key: .rightArrow, modifiers: [.option, .shift]) == nil)
        // flags de teclas de função/numpad que o AppKit adiciona às setas não contam.
        #expect(TerminalKeyTable.bytes(key: .leftArrow, modifiers: [.command, .numericPad, .function]) == [0x01])
    }

    @Test func virtualKeyCodes() {
        #expect(TerminalKeyTable.key(forKeyCode: 123) == .leftArrow)
        #expect(TerminalKeyTable.key(forKeyCode: 124) == .rightArrow)
        #expect(TerminalKeyTable.key(forKeyCode: 51) == .delete)
        #expect(TerminalKeyTable.key(forKeyCode: 36) == .return)
        #expect(TerminalKeyTable.key(forKeyCode: 0) == nil)
    }
}

/// AR-710: uma transição gera exatamente um resize; rajadas colapsam; tamanho igual não envia.
@Suite(.offscreenAppKit) struct ResizeCoordinatorTests {
    private actor Log {
        var sizes: [PTYResizeCoordinator.Size] = []
        func add(_ size: PTYResizeCoordinator.Size) { sizes.append(size) }
    }

    private func make(debounce: Duration = .milliseconds(30)) -> (PTYResizeCoordinator, Log) {
        let log = Log()
        let c = PTYResizeCoordinator(initial: .init(cols: 80, rows: 24), debounce: debounce) { await log.add($0) }
        return (c, log)
    }

    @Test func burstCollapsesIntoOneTrailingResize() async throws {
        let (c, log) = make()
        for cols in 81 ... 120 { c.request(.init(cols: UInt16(cols), rows: 24)) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(await log.sizes == [.init(cols: 120, rows: 24)])
        #expect(c.appliedSize == .init(cols: 120, rows: 24))
    }

    @Test func sameSizeAsAppliedSendsNothing() async throws {
        let (c, log) = make()
        c.request(.init(cols: 80, rows: 24))
        c.request(.init(cols: 90, rows: 24))
        c.request(.init(cols: 80, rows: 24))  // voltou ao aplicado antes do debounce
        try await Task.sleep(for: .milliseconds(150))
        #expect(await log.sizes.isEmpty)
    }

    @Test func aTransitionProducesExactlyOneResizeWhenItEnds() async throws {
        let (c, log) = make()
        c.beginTransition()
        for cols in stride(from: 80, through: 160, by: 4) { c.request(.init(cols: UInt16(cols), rows: 40)) }
        try await Task.sleep(for: .milliseconds(150))
        #expect(await log.sizes.isEmpty)  // nada durante a transição
        c.endTransition()
        try await Task.sleep(for: .milliseconds(150))
        #expect(await log.sizes == [.init(cols: 160, rows: 40)])
    }

    @Test func closedCoordinatorNeverApplies() async throws {
        let (c, log) = make()
        c.request(.init(cols: 100, rows: 30))
        c.close()
        try await Task.sleep(for: .milliseconds(150))
        #expect(await log.sizes.isEmpty)
    }
}
