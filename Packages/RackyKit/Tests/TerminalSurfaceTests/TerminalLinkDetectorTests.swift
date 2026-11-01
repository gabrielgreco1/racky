import Foundation
import Testing

@testable import RackyUI

/// Detecção pura de links na linha do terminal (03 §4.1): URLs e caminhos que existem.
@Suite struct TerminalLinkDetectorTests {
    private let cwd = "/work/proj"
    private let home = "/Users/me"
    private let present: Set<String> = [
        "/work/proj/src/foo.swift", "/work/proj/Package.swift", "/work/proj/src", "/Users/me/notes.md", "/etc/hosts", "/work/other/x.ts",
    ]

    private func detect(_ line: String, at needle: String) -> TerminalLink? {
        guard let found = line.range(of: needle) else { return nil }
        let column = line.distance(from: line.startIndex, to: found.lowerBound)
        return TerminalLinkDetector.detect(line: line, column: column, cwd: cwd, home: home) { present.contains($0) }
    }

    private func text(_ line: String, _ link: TerminalLink?) -> String? {
        link.map { String(Array(line)[$0.range]) }
    }

    // MARK: URLs

    @Test func urlWithTrailingPunctuationIsTrimmed() {
        let line = "see https://example.com/a?b=1, then go."
        let link = detect(line, at: "example")
        #expect(link?.kind == .url("https://example.com/a?b=1"))
        #expect(text(line, link) == "https://example.com/a?b=1")
    }

    @Test func urlInsideParenthesesDropsTheClosingOne() {
        #expect(detect("(docs: https://example.com/x)", at: "example")?.kind == .url("https://example.com/x"))
    }

    @Test func urlKeepsBalancedParentheses() {
        #expect(detect("https://en.wikipedia.org/wiki/Foo_(bar).", at: "wiki")?.kind == .url("https://en.wikipedia.org/wiki/Foo_(bar)"))
    }

    @Test func urlInQuotesAndAngleBrackets() {
        #expect(detect("open \"http://localhost:3000/a\" now", at: "localhost")?.kind == .url("http://localhost:3000/a"))
        #expect(detect("<https://a.dev/x>", at: "a.dev")?.kind == .url("https://a.dev/x"))
    }

    @Test func bareSchemeIsNotALink() {
        #expect(detect("https://", at: "https") == nil)
    }

    // MARK: Caminhos

    @Test func absolutePathWithLineAndColumn() {
        let line = "error: /work/proj/src/foo.swift:12:5: boom"
        let link = detect(line, at: "foo")
        #expect(link?.kind == .file(path: "/work/proj/src/foo.swift", line: 12, column: 5))
        #expect(text(line, link) == "/work/proj/src/foo.swift:12:5")
    }

    @Test func relativePathResolvesAgainstCwd() {
        #expect(detect("  modified: src/foo.swift", at: "foo")?.kind == .file(path: "/work/proj/src/foo.swift", line: nil, column: nil))
    }

    @Test func dotSlashAndDotDotAreNormalised() {
        #expect(detect("./src/foo.swift:3", at: "foo")?.kind == .file(path: "/work/proj/src/foo.swift", line: 3, column: nil))
        #expect(detect("../other/x.ts", at: "x.ts")?.kind == .file(path: "/work/other/x.ts", line: nil, column: nil))
    }

    @Test func tildeExpandsToHome() {
        #expect(detect("wrote ~/notes.md", at: "notes")?.kind == .file(path: "/Users/me/notes.md", line: nil, column: nil))
    }

    @Test func bareFileNameInCwd() {
        #expect(detect("edit Package.swift please", at: "Package")?.kind == .file(path: "/work/proj/Package.swift", line: nil, column: nil))
    }

    @Test func directoryIsALinkToo() {
        #expect(detect("cd src/", at: "src")?.kind == .file(path: "/work/proj/src", line: nil, column: nil))
    }

    @Test func nonExistentPathIsIgnored() {
        #expect(detect("see src/missing.swift:3", at: "missing") == nil)
        #expect(detect("/nope/at/all", at: "nope") == nil)
    }

    @Test func relativePathWithoutCwdIsIgnored() {
        #expect(TerminalLinkDetector.detect(line: "src/foo.swift", column: 5, cwd: nil, home: home) { _ in true } == nil)
    }

    @Test func trailingPunctuationAndColonAreNotPartOfThePath() {
        let line = "failed in src/foo.swift:12: expected ')'"
        let link = detect(line, at: "foo")
        #expect(link?.kind == .file(path: "/work/proj/src/foo.swift", line: 12, column: nil))
        #expect(text(line, link) == "src/foo.swift:12")
        #expect(detect("(see src/foo.swift).", at: "foo")?.kind == .file(path: "/work/proj/src/foo.swift", line: nil, column: nil))
    }

    @Test func parenthesisLocationFromTypeScript() {
        #expect(detect("src/foo.swift(12,3): error", at: "foo")?.kind == .file(path: "/work/proj/src/foo.swift", line: 12, column: 3))
    }

    @Test func gitDiffPrefixesFallBackToThePlainPath() {
        #expect(detect("+++ b/src/foo.swift", at: "foo")?.kind == .file(path: "/work/proj/src/foo.swift", line: nil, column: nil))
    }

    @Test func optionValueAfterEqualsIsThePath() {
        #expect(detect("--file=src/foo.swift", at: "foo")?.kind == .file(path: "/work/proj/src/foo.swift", line: nil, column: nil))
    }

    @Test func tuiBorderIsASeparator() {
        #expect(detect("│ src/foo.swift:9 │", at: "foo")?.kind == .file(path: "/work/proj/src/foo.swift", line: 9, column: nil))
    }

    @Test func clockAndPlainWordsAreNotPaths() {
        #expect(detect("at 12:30:45 today", at: "12:30") == nil)
        #expect(TerminalLinkDetector.detect(line: "/ . ..", column: 0, cwd: cwd, home: home) { _ in true } == nil)
    }

    @Test func columnOutsideTheTokenFindsNothing() {
        let line = "a  src/foo.swift"
        #expect(TerminalLinkDetector.detect(line: line, column: 2, cwd: cwd, home: home) { _ in true } == nil)
        #expect(TerminalLinkDetector.detect(line: line, column: 99, cwd: cwd, home: home) { _ in true } == nil)
    }

    // MARK: Colunas

    @Test func wideGlyphsShiftTheColumns() {
        let line = "日本 src/foo.swift"
        #expect(TerminalLinkDetector.characterIndex(forColumn: 0, in: line) == 0)
        #expect(TerminalLinkDetector.characterIndex(forColumn: 1, in: line) == 0)
        #expect(TerminalLinkDetector.characterIndex(forColumn: 5, in: line) == 3)
        #expect(TerminalLinkDetector.columns(of: 3..<6, in: line) == 5..<8)
        #expect(TerminalLinkDetector.characterIndex(forColumn: 99, in: line) == nil)
    }

    // MARK: Política de abertura

    @Test func defaultAppNeverRunsApplicationsOrScripts() {
        #expect(!TerminalLinkPolicy.opensSafelyWithDefaultApp("/x/Foo.app", isDirectory: true))
        #expect(!TerminalLinkPolicy.opensSafelyWithDefaultApp("/x/run.command", isDirectory: false))
        #expect(TerminalLinkPolicy.opensSafelyWithDefaultApp("/x/readme.md", isDirectory: false))
        #expect(TerminalLinkPolicy.opensSafelyWithDefaultApp("/x/src", isDirectory: true))
    }
}
