import Testing

@testable import RackyTerminalCore

/// Enquadramento da colagem por clique (T11): bracketed paste, nunca Enter.
@Suite struct AgentPasteTests {
    private func framed(_ text: String, active: Bool = true) -> String? {
        AgentPaste.frame(text, bracketedPasteActive: active).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func wrapsTheTextInBracketedPasteMarkers() {
        #expect(AgentPaste.frame("hello", bracketedPasteActive: true) == [0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e] + Array("hello".utf8) + [0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e])
    }

    @Test func neverEndsWithCarriageReturnOrNewline() throws {
        let bytes = try #require(AgentPaste.frame("line one\nline two\r\n\n", bracketedPasteActive: true))
        #expect(Array(bytes.suffix(6)) == AgentPaste.end)
        let body = String(decoding: bytes.dropFirst(6).dropLast(6), as: UTF8.self)
        #expect(body == "line one\nline two")
        #expect(!bytes.contains(0x0d))
    }

    @Test func textCannotCloseThePasteEarlyOrInjectEscapes() throws {
        let text = try #require(framed("a\u{1b}[201~rm -rf /\u{1b}[200~b"))
        // O único ESC[201~ é o terminador final.
        #expect(text.components(separatedBy: "\u{1b}[201~").count == 2)
        #expect(text.components(separatedBy: "\u{1b}[200~").count == 2)
    }

    @Test func withoutBracketedPasteOrTextThereIsNothingToSend() {
        #expect(framed("hello", active: false) == nil)
        #expect(framed("", active: true) == nil)
        #expect(framed("\n\r\n") == nil)
    }

    @Test func keepsUnicodeAndInnerNewlines() {
        #expect(framed("héllo 日本\nsecond") == "\u{1b}[200~héllo 日本\nsecond\u{1b}[201~")
    }
}
