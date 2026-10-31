import RackyDesignSystem
import RackyProtocol
import AppKit
import Foundation
import SwiftTerm
import Testing

@testable import RackyUI

@Suite(.serialized, .offscreenAppKit) struct SurfaceTests {
    private func make(_ id: String = "t1") -> (TerminalHostView, NSWindow, OutputCollector) {
        let host = TerminalHostView(terminalID: id)
        let window = makeWindow(hosting: host)
        let out = OutputCollector()
        host.surface.setOutputSink(out.sink)
        return (host, window, out)
    }

    // MARK: Tema, Metal, inset

    @Test func themeFollowsTheTokens() {
        let (host, _, _) = make()
        let surface = host.surface
        #expect(surface.nativeBackgroundColor == DS.Terminal.background.nsColor)
        #expect(surface.nativeForegroundColor == DS.Terminal.foreground.nsColor)
        #expect(surface.caretColor == DS.Terminal.cursor.nsColor)
        #expect(surface.caretTextColor == DS.Terminal.cursorText.nsColor)
        #expect(surface.selectedTextBackgroundColor == DS.Terminal.selectionBackground.nsColor)
        #expect(surface.font.pointSize == DS.TerminalFont.defaultSize)
        #expect(surface.font.isFixedPitch)
        #expect(TerminalTheme.ansiPalette.count == 16)
        // Vermelho normal (#cc6666) em 16 bits.
        let red = TerminalTheme.ansiPalette[1]
        #expect(red.red == 0xcc * 257 && red.green == 0x66 * 257 && red.blue == 0x66 * 257)
    }

    @Test func metalRendererIsOn() {
        let (host, _, _) = make()
        #expect(host.surface.metalEnabled)
        #expect(host.surface.isUsingMetalRenderer)
    }

    @Test func surfaceIsInsetByFourPointsAndOwnsFocus() {
        let (host, window, _) = make()
        host.layoutSubtreeIfNeeded()
        #expect(host.surface.frame == host.bounds.insetBy(dx: DS.TerminalFont.padding, dy: DS.TerminalFont.padding))
        #expect(window.firstResponder === host.surface)
        #expect(!host.acceptsFirstResponder)
        #expect(host.surface.accessibilityIdentifier() == "pane.t1.terminal")
    }

    // MARK: Respostas (AR-105, AR-520)

    @Test func osc52ReadIsNeverAnswered() async throws {
        let (host, _, out) = make()
        await feedOffMain(host.surface, "\u{1b}]52;c;?\u{07}")
        await feedOffMain(host.surface, "\u{1b}]52;p;?\u{1b}\\")
        try await Task.sleep(for: .milliseconds(150))  // o hop para o main, se existisse, já teria ocorrido
        #expect(out.all.isEmpty, "nada pode ser escrito no PTY")
    }

    @Test func osc52ReadNeverReachesThePasteboardEvenWithATextClipboard() async throws {
        let (host, _, out) = make()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("racky.test.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("do-not-leak", forType: .string)
        host.surface.clipboardPasteboard = pasteboard
        await feedOffMain(host.surface, "\u{1b}]52;c;?\u{07}")
        try await Task.sleep(for: .milliseconds(150))
        #expect(out.all.isEmpty)
        #expect(!out.bytes(origin: .terminalReply).contains(UInt8(ascii: "d")))
    }

    @Test func osc52WriteFollowsTheSetting() async throws {
        let (host, _, _) = make()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("racky.test.\(UUID().uuidString)"))
        host.surface.clipboardPasteboard = pasteboard
        var written = 0
        host.onClipboardWritten = { written += 1 }
        let payload = Data("hello clip".utf8).base64EncodedString()

        await feedOffMain(host.surface, "\u{1b}]52;c;\(payload)\u{07}")
        try await eventually("osc52 write") { pasteboard.string(forType: .string) == "hello clip" }
        #expect(written == 1)

        pasteboard.clearContents()
        host.surface.osc52WriteEnabled = false
        await feedOffMain(host.surface, "\u{1b}]52;c;\(payload)\u{07}")
        try await Task.sleep(for: .milliseconds(150))
        #expect(pasteboard.string(forType: .string) == nil)
        #expect(written == 1)
    }

    @Test func deviceAttributesAreAnsweredWithTheReplyOrigin() async throws {
        let (host, _, out) = make()
        await feedOffMain(host.surface, "\u{1b}[c")
        try await eventually("DA1 reply") { !out.bytes(origin: .terminalReply).isEmpty }
        let reply = String(decoding: out.bytes(origin: .terminalReply), as: UTF8.self)
        #expect(reply.hasPrefix("\u{1b}[?"))
        #expect(reply.hasSuffix("c"))
        #expect(out.all.allSatisfy { $0.origin == .terminalReply })
    }

    @Test func repliesAreSilentWhileReplayingASnapshot() async throws {
        let (host, _, out) = make()
        host.surface.setReplaying(true)
        await feedOffMain(host.surface, "old query \u{1b}[c done")
        try await Task.sleep(for: .milliseconds(150))
        #expect(out.all.isEmpty)
        host.surface.setReplaying(false)
        await feedOffMain(host.surface, "\u{1b}[c")
        try await eventually("live reply") { !out.all.isEmpty }
    }

    // MARK: Input e colar

    @Test func typedTextGoesOutAsKeyOrigin() async throws {
        let (host, window, out) = make()
        host.surface.keyDown(with: keyEvent(keyCode: 0, characters: "a", modifiers: [], window: window))
        try await eventually("key bytes") { !out.all.isEmpty }
        #expect(out.bytes(origin: .key) == [UInt8(ascii: "a")])
        #expect(out.all.allSatisfy { $0.origin == .key })
    }

    @Test func reservedChordsAreSentThroughTheKeyTable() async throws {
        let (host, window, out) = make()
        func press(_ code: UInt16, _ chars: String, _ mods: NSEvent.ModifierFlags) -> Bool {
            host.performKeyEquivalent(with: keyEvent(keyCode: code, characters: chars, modifiers: mods, window: window))
        }
        #expect(press(123, "\u{F702}", [.command, .numericPad, .function]))  // ⌘←
        #expect(press(124, "\u{F703}", [.command, .numericPad, .function]))  // ⌘→
        #expect(press(51, "\u{7f}", [.command]))  // ⌘⌫
        #expect(press(36, "\r", [.shift]))  // ⇧↵
        #expect(press(123, "\u{F702}", [.option, .numericPad, .function]))  // ⌥←
        #expect(press(124, "\u{F703}", [.option, .numericPad, .function]))  // ⌥→
        try await eventually("chord bytes") { out.bytes(origin: .key).count >= 1 + 1 + 1 + 7 + 2 + 2 }
        let head: [UInt8] = [0x01, 0x05, 0x15]
        let csiU: [UInt8] = Array("\u{1b}[13;2u".utf8)
        let tail: [UInt8] = [0x1b, 0x62, 0x1b, 0x66]
        let expected: [UInt8] = head + csiU + tail
        #expect(out.bytes(origin: .key) == expected)
    }

    @Test func blockedInputDoesNotSendKeysAndRefusesFocus() async throws {
        let (host, window, out) = make()
        host.inputBlocked = true
        #expect(window.firstResponder !== host.surface)
        #expect(!host.performKeyEquivalent(with: keyEvent(keyCode: 123, characters: "\u{F702}", modifiers: [.command], window: window)))
        host.focusTerminal()
        #expect(window.firstResponder !== host.surface)
        try await Task.sleep(for: .milliseconds(100))
        #expect(out.all.isEmpty)
        host.inputBlocked = false
        host.focusTerminal()
        #expect(window.firstResponder === host.surface)
    }

    @Test func pasteUsesBracketedPasteWhenTheProgramEnabledIt() async throws {
        let (host, _, out) = make()
        await feedOffMain(host.surface, "\u{1b}[?2004h")
        host.surface.pasteUser("one\ntwo \u{1b}[201~ three")
        try await eventually("paste bytes") { !out.all.isEmpty }
        let text = String(decoding: out.bytes(origin: .userPaste), as: UTF8.self)
        #expect(text == "\u{1b}[200~one\ntwo [201~ three\u{1b}[201~")
        #expect(out.all.allSatisfy { $0.origin == .userPaste })
        #expect(out.bytes(origin: .key).isEmpty)
    }

    @Test func pasteWithoutBracketedModeTurnsNewlinesIntoReturns() async throws {
        let (host, _, out) = make()
        host.surface.pasteUser("ls\npwd")
        try await eventually("paste bytes") { !out.all.isEmpty }
        #expect(String(decoding: out.bytes(origin: .userPaste), as: UTF8.self) == "ls\rpwd")
    }

    @Test func pasteFromPasteboardUsesThePasteboardText() async throws {
        let (host, _, out) = make()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("racky.test.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("from board", forType: .string)
        host.surface.pasteUser(from: pasteboard)
        try await eventually("paste bytes") { !out.all.isEmpty }
        #expect(String(decoding: out.bytes(origin: .userPaste), as: UTF8.self) == "from board")
    }

    // MARK: Seleção, links, zoom, busca

    @Test func selectAllAndCopyTrimTrailingWhitespace() async throws {
        let (host, _, _) = make()
        await feedOffMain(host.surface, "hello world\r\nsecond line")
        host.selectAll()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("racky.test.\(UUID().uuidString)"))
        #expect(host.copySelection(to: pasteboard))
        let copied = try #require(pasteboard.string(forType: .string))
        #expect(copied.contains("hello world"))
        #expect(copied.split(separator: "\n").allSatisfy { !$0.hasSuffix(" ") })
    }

    @Test func linkActivationOpensOnlyAllowedSchemes() {
        let (host, _, _) = make()
        var opened: [URL] = []
        host.surface.openURL = { opened.append($0) }
        host.surface.activateLink("https://example.com/path")
        host.surface.activateLink("file:///etc/passwd")
        host.surface.activateLink("x-apple.systempreferences:com.apple.preference.security")
        host.surface.activateLink("mailto:dev@example.com")
        #expect(opened.map(\.absoluteString) == ["https://example.com/path", "mailto:dev@example.com"])
    }

    // MARK: Links com mouse (03 §4.1)

    /// Evento de mouse na célula (col, row) da superfície, em coordenadas da janela.
    private func mouse(_ type: NSEvent.EventType, col: Int, row: Int, in host: TerminalHostView, window: NSWindow, flags: NSEvent.ModifierFlags) -> NSEvent {
        let surface = host.surface
        let dims = surface.terminalDimensions
        let optimal = surface.getOptimalFrameSize()
        let size = CGSize(width: optimal.width / CGFloat(dims.cols), height: optimal.height / CGFloat(dims.rows))
        let local = NSPoint(x: (CGFloat(col) + 0.5) * size.width, y: surface.bounds.height - (CGFloat(row) + 0.5) * size.height)
        return NSEvent.mouseEvent(
            with: type, location: surface.convert(local, to: nil), modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }

    @Test func commandClickOnURLOpensEvenWhenTheProgramReportsMouse() async {
        let (host, window, out) = make()
        var opened: [URL] = []
        host.surface.openURL = { opened.append($0) }
        await feedOffMain(host.surface, "\u{1b}[?1000h\u{1b}[?1006hhttps://example.com/x")
        out.reset()
        host.surface.mouseDown(with: mouse(.leftMouseDown, col: 4, row: 0, in: host, window: window, flags: [.command]))
        host.surface.mouseUp(with: mouse(.leftMouseUp, col: 4, row: 0, in: host, window: window, flags: [.command]))
        #expect(opened.map(\.absoluteString) == ["https://example.com/x"])
        #expect(out.all.isEmpty)  // nem press nem release chegam ao programa
        // Sem ⌘ o clique continua sendo do programa.
        host.surface.mouseDown(with: mouse(.leftMouseDown, col: 4, row: 0, in: host, window: window, flags: []))
        host.surface.mouseUp(with: mouse(.leftMouseUp, col: 4, row: 0, in: host, window: window, flags: []))
        #expect(opened.count == 1)
        #expect(!out.all.isEmpty)
    }

    @Test func commandClickOnExistingPathOpensItAndPlainClickDoesNot() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "x".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let cwd = dir.resolvingSymlinksInPath().path
        let (host, window, out) = make()
        host.surface.linkCwd = { cwd }
        var opened: [(TerminalFileTarget, TerminalLinkOpenMode)] = []
        host.surface.onOpenFile = { opened.append(($0, $1)) }
        await feedOffMain(host.surface, "\u{1b}[?1000h\u{1b}[?1006hsee a.txt:7 and nope.txt")
        out.reset()
        func hover(col: Int, flags: NSEvent.ModifierFlags) async {
            host.surface.links.mouseMoved(with: mouse(.mouseMoved, col: col, row: 0, in: host, window: window, flags: flags))
            for _ in 0..<100 where (host.surface.links.hoveredTarget != nil) != flags.contains(.command) || col > 20 {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        await hover(col: 5, flags: [])
        #expect(host.surface.links.hoveredTarget == nil)  // sem ⌘ não há link
        await hover(col: 5, flags: [.command])
        #expect(host.surface.links.hoveredTarget == TerminalFileTarget(path: cwd + "/a.txt", line: 7, column: nil, isDirectory: false))
        host.surface.mouseDown(with: mouse(.leftMouseDown, col: 5, row: 0, in: host, window: window, flags: [.command, .shift]))
        host.surface.mouseUp(with: mouse(.leftMouseUp, col: 5, row: 0, in: host, window: window, flags: [.command, .shift]))
        #expect(opened.count == 1 && opened[0].1 == .system && opened[0].0.line == 7)
        #expect(out.all.isEmpty)
        host.surface.mouseDown(with: mouse(.leftMouseDown, col: 5, row: 0, in: host, window: window, flags: [.command]))
        host.surface.mouseUp(with: mouse(.leftMouseUp, col: 5, row: 0, in: host, window: window, flags: [.command]))
        #expect(opened.count == 2 && opened[1].1 == .inApp)
        // Sem ⌘: o mouse parado ~0,2 s sobre o caminho mostra o cartão, e clicar nele abre.
        host.surface.links.mouseMoved(with: mouse(.mouseMoved, col: 6, row: 0, in: host, window: window, flags: []))
        for _ in 0..<100 where host.surface.links.hoveredTarget == nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(host.surface.links.hoveredTarget?.path == cwd + "/a.txt" && host.surface.links.tipVisible)
        host.surface.links.openFromTip(.inApp)
        #expect(opened.count == 3 && opened[2].1 == .inApp && !host.surface.links.tipVisible)
        // Caminho que não existe nunca vira link.
        host.surface.links.mouseMoved(with: mouse(.mouseMoved, col: 20, row: 0, in: host, window: window, flags: [.command]))
        try? await Task.sleep(for: .milliseconds(150))
        #expect(host.surface.links.hoveredTarget == nil)
    }

    @Test func zoomStepsAndClamps() {
        let (host, _, _) = make()
        host.fontBigger()
        #expect(host.surface.font.pointSize == 15)
        host.fontSmaller()
        host.fontSmaller()
        #expect(host.surface.font.pointSize == 13)
        host.fontReset()
        #expect(host.surface.font.pointSize == 14)
        for _ in 0 ..< 40 { host.fontBigger() }
        #expect(host.surface.font.pointSize == DS.TerminalFont.sizeMax)
        for _ in 0 ..< 40 { host.fontSmaller() }
        #expect(host.surface.font.pointSize == DS.TerminalFont.sizeMin)
    }

    @Test func zoomChangesTheGridSize() {
        let (host, _, _) = make()
        host.layoutSubtreeIfNeeded()
        let before = host.surface.terminalDimensions
        host.fontBigger()
        host.fontBigger()
        host.layoutSubtreeIfNeeded()
        let after = host.surface.terminalDimensions
        #expect(after.cols < before.cols && after.rows < before.rows)
    }

    @Test func findHonorsCaseSensitivityAndRegexAndClosesCleanly() async throws {
        let (host, _, _) = make()
        await feedOffMain(host.surface, "alpha beta\r\nbeta gamma\r\nBETA delta\r\n")
        host.openFind()
        host.findModel.query = "beta"
        #expect(host.findModel.total == 3)  // insensível a maiúsculas por padrão
        host.findModel.caseSensitive = true
        #expect(host.findModel.total == 2)
        host.findModel.caseSensitive = false
        host.findModel.regex = true
        host.findModel.query = "^beta"
        #expect(host.findModel.total == 2)
        host.findModel.query = "zzz"
        #expect(host.findModel.total == 0)
        #expect(host.findModel.hasNoResults)
        host.findModel.regex = false
        host.findModel.query = "gamma"
        #expect(host.findModel.next())
        #expect(host.surface.getSelection() == "gamma")
        host.closeFind()
        #expect(!host.findModel.isOpen)
        #expect(host.surface.getSelection() == nil)
    }

    @Test func commandFOpensFindAndEscapeClosesIt() throws {
        let (host, window, _) = make()
        #expect(host.performKeyEquivalent(with: keyEvent(keyCode: 3, characters: "f", modifiers: [.command], window: window)))
        #expect(host.findModel.isOpen)
        host.closeFind()
        #expect(!host.findModel.isOpen)
        #expect(window.firstResponder === host.surface)
    }
}
