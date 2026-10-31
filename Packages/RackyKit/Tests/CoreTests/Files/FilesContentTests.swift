import Foundation
import Testing
@testable import RackyCore

@Suite struct GitChangeMapTests {
    @Test func parsesPorcelainV1WithRenamesAndUntrackedDirectories() {
        let output = [
            " M src/a.swift", "A  src/new.swift", "?? notes.txt", "?? build/", "R  new/name.txt", "old/name.txt", " D gone.txt", "UU conflict.txt",
            "!! ignored.log",
        ].joined(separator: "\0") + "\0"
        let map = GitChangeMap.parse(porcelainV1: output, repositoryRoot: "/repo")
        #expect(map.change(for: "/repo/src/a.swift") == .modified)
        #expect(map.change(for: "/repo/src/new.swift") == .added)
        #expect(map.change(for: "/repo/notes.txt") == .untracked)
        #expect(map.change(for: "/repo/new/name.txt") == .renamed)
        #expect(map.change(for: "/repo/old/name.txt") == nil, "o caminho de origem do rename não vira registro")
        #expect(map.change(for: "/repo/gone.txt") == .deleted)
        #expect(map.change(for: "/repo/conflict.txt") == .conflicted)
        #expect(map.change(for: "/repo/ignored.log") == nil)
        #expect(map.change(for: "/repo/build/deep/out.o") == .untracked, "tudo dentro de uma pasta não rastreada é untracked")
        #expect(map.change(for: "/repo/clean.txt") == nil)
    }

    @Test func directoriesWithChangesIncludeEveryAncestorUpToTheRoot() {
        let map = GitChangeMap.parse(porcelainV1: " M a/b/c.txt\0", repositoryRoot: "/repo")
        #expect(map.directoryHasChanges("/repo/a/b"))
        #expect(map.directoryHasChanges("/repo/a"))
        #expect(map.directoryHasChanges("/repo"))
        #expect(!map.directoryHasChanges("/repo/other"))
    }

    @Test func untrackedDirectoryMarksItsParents() {
        let map = GitChangeMap.parse(porcelainV1: "?? pkg/gen/\0", repositoryRoot: "/repo")
        #expect(map.directoryHasChanges("/repo/pkg"))
        #expect(map.directoryHasChanges("/repo/pkg/gen"))
    }

    @Test func emptyOutputIsEmpty() {
        #expect(GitChangeMap.parse(porcelainV1: "", repositoryRoot: "/repo").isEmpty)
        #expect(GitChangeMap.empty.count == 0)
    }

    @Test func lineMarksFromAZeroContextDiff() {
        let diff = """
        diff --git a/f.txt b/f.txt
        --- a/f.txt
        +++ b/f.txt
        @@ -2 +2 @@
        -old
        +new
        @@ -10,0 +11,3 @@
        +a
        +b
        +c
        @@ -20,2 +23,0 @@
        -x
        -y
        """
        let marks = LineChangeMarks.parse(unifiedDiff: diff)
        #expect(marks.marks.count == 3)
        #expect(marks.kind(forLine: 2) == .modified)
        #expect(marks.kind(forLine: 1) == nil)
        #expect(marks.kind(forLine: 11) == .added)
        #expect(marks.kind(forLine: 13) == .added)
        #expect(marks.kind(forLine: 14) == nil)
        #expect(marks.kind(forLine: 23) == .deleted)
    }

    @Test func newFilesAreAllAdded() {
        let marks = LineChangeMarks.allAdded(lineCount: 5)
        #expect(marks.kind(forLine: 1) == .added)
        #expect(marks.kind(forLine: 5) == .added)
        #expect(marks.kind(forLine: 6) == nil)
        #expect(LineChangeMarks.allAdded(lineCount: 0) == .none)
    }

    @Test func realRepositoryStatusAndDiffMarks() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepo()
        try sandbox.write("README.md", "hello\nchanged\n", in: repo)
        try sandbox.write("new.txt", "fresh\n", in: repo)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try sandbox.write("sub/inner.txt", "inner\n", in: repo.appendingPathComponent(""))
        let service = FilesGitService(runner: sandbox.runner)
        let root = FileTreeLoader.canonical(repo.path)
        let snapshot = await service.snapshot(at: root)
        #expect(snapshot.repositoryRoot == root)
        #expect(snapshot.branch == "main")
        #expect(snapshot.changes.change(for: root + "/README.md") == .modified)
        #expect(snapshot.changes.change(for: root + "/new.txt") == .untracked)
        #expect(snapshot.changes.directoryHasChanges(root + "/sub"))
        let marks = await service.lineMarks(forFile: root + "/README.md", repositoryRoot: root)
        #expect(marks.kind(forLine: 2) == .added)
        // Pasta fora de repositório: vazio, sem erro.
        let outside = try sandbox.dir("not-a-repo")
        let none = await service.snapshot(at: FileTreeLoader.canonical(outside.path))
        #expect(none.repositoryRoot == nil)
        #expect(none.changes.isEmpty)
    }
}

@Suite struct FileReaderTests {
    private func write(_ data: Data, name: String = "f.bin") throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("racky-read-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url.path
    }

    @Test func readsTextAndCountsLines() throws {
        let path = try write(Data("one\ntwo\nthree".utf8), name: "a.txt")
        guard case .text(let text, let truncated) = FileReader.read(path: path) else { Issue.record("expected text"); return }
        #expect(text == "one\ntwo\nthree")
        #expect(!truncated)
        #expect(FileReader.lineCount(text) == 3)
        #expect(FileReader.lineCount("a\n") == 1)
        #expect(FileReader.lineCount("") == 0)
    }

    @Test func detectsBinaryByNul() throws {
        let path = try write(Data([0x89, 0x50, 0x00, 0x01, 0x02]), name: "blob.dat")
        #expect(FileReader.read(path: path) == .binary(size: 5))
    }

    @Test func truncatesAtTheLimit() throws {
        let path = try write(Data(String(repeating: "x", count: 5000).utf8), name: "big.txt")
        guard case .text(let text, let truncated) = FileReader.read(path: path, limit: 1000) else { Issue.record("expected text"); return }
        #expect(text.count == 1000)
        #expect(truncated)
    }

    @Test func imagesAreRecognisedByExtensionAndMissingFilesAreUnreadable() throws {
        #expect(FileReader.read(path: "/tmp/whatever.PNG") == .image(path: "/tmp/whatever.PNG"))
        guard case .unreadable = FileReader.read(path: "/definitely/not/here.txt") else { Issue.record("expected unreadable"); return }
    }

    @Test func invalidUtf8StillShowsText() throws {
        let path = try write(Data([0x68, 0x69, 0xFF, 0x0A]), name: "latin.txt")
        guard case .text(let text, _) = FileReader.read(path: path) else { Issue.record("expected text"); return }
        #expect(text.hasPrefix("hi"))
    }

    @Test func searchFindsAllCaseInsensitiveMatches() {
        let text = "Foo bar foo\nFOO"
        let hits = CodeSearch.ranges(of: "foo", in: text)
        #expect(hits.map(\.location) == [0, 8, 12])
        #expect(CodeSearch.ranges(of: "foo", in: text, caseSensitive: true).map(\.location) == [8])
        #expect(CodeSearch.ranges(of: "", in: text).isEmpty)
        #expect(CodeSearch.ranges(of: "zzz", in: text).isEmpty)
    }
}

@Suite struct SyntaxHighlighterTests {
    private func kinds(_ text: String, _ language: SyntaxLanguage) -> [(String, SyntaxKind)] {
        let ns = text as NSString
        return SyntaxHighlighter.spans(in: text, language: language).map { (ns.substring(with: $0.range), $0.kind) }
    }

    private func has(_ list: [(String, SyntaxKind)], _ text: String, _ kind: SyntaxKind) -> Bool {
        list.contains { $0.0 == text && $0.1 == kind }
    }

    @Test func languageFromFileName() {
        #expect(SyntaxLanguage.forFile(named: "main.swift") == .swift)
        #expect(SyntaxLanguage.forFile(named: "App.TSX") == .typescript)
        #expect(SyntaxLanguage.forFile(named: "Dockerfile") == .shell)
        #expect(SyntaxLanguage.forFile(named: "package.json") == .json)
        #expect(SyntaxLanguage.forFile(named: "README.md") == .markdown)
        #expect(SyntaxLanguage.forFile(named: "data.xyz") == .plain)
        #expect(SyntaxHighlighter.spans(in: "let x = 1", language: .plain).isEmpty)
    }

    @Test func swiftTokens() {
        let k = kinds("// note\nlet name: String = \"hi \\\"there\\\"\" // tail\nfunc run() { call(42) }\n@MainActor struct S {}", .swift)
        #expect(has(k, "// note", .comment))
        #expect(has(k, "let", .keyword))
        #expect(has(k, "String", .type))
        #expect(has(k, "\"hi \\\"there\\\"\"", .string))
        #expect(has(k, "// tail", .comment))
        #expect(has(k, "func", .keyword))
        #expect(has(k, "run", .function))
        #expect(has(k, "call", .function))
        #expect(has(k, "42", .number))
        #expect(has(k, "@MainActor", .attribute))
        #expect(has(k, "struct", .keyword))
    }

    @Test func keywordsInsideStringsAndCommentsAreNotKeywords() {
        let k = kinds("let s = \"let if else\" /* func class */", .swift)
        #expect(k.filter { $0.1 == .keyword }.map(\.0) == ["let"])
        #expect(has(k, "\"let if else\"", .string))
        #expect(has(k, "/* func class */", .comment))
    }

    @Test func pythonTripleQuotesAndHashComments() {
        let k = kinds("def f(x):\n    \"\"\"doc\n    string\"\"\"\n    return x  # done\n", .python)
        #expect(has(k, "def", .keyword))
        #expect(has(k, "\"\"\"doc\n    string\"\"\"", .string))
        #expect(has(k, "return", .keyword))
        #expect(has(k, "# done", .comment))
    }

    @Test func jsonKeysDifferFromValues() {
        let k = kinds("{\"name\": \"agent\", \"n\": 3, \"ok\": true}", .json)
        #expect(has(k, "\"name\"", .key))
        #expect(has(k, "\"agent\"", .string))
        #expect(has(k, "3", .number))
        #expect(has(k, "true", .keyword))
    }

    @Test func yamlKeysAndComments() {
        let k = kinds("name: box # c\nitems:\n  - id: 7\n", .yaml)
        #expect(has(k, "name", .key))
        #expect(has(k, "# c", .comment))
        #expect(has(k, "items", .key))
        #expect(has(k, "id", .key))
        #expect(has(k, "7", .number))
    }

    @Test func shellHashOnlyCommentsAtWordStart() {
        let k = kinds("echo a#b # real\nif [ -f x ]; then ls; fi\n", .shell)
        #expect(!has(k, "#b # real", .comment))
        #expect(has(k, "# real", .comment))
        #expect(has(k, "if", .keyword))
        #expect(has(k, "then", .keyword))
    }

    @Test func rustLifetimesAreNotStrings() {
        let k = kinds("fn f<'a>(x: &'a str) -> char { 'z' }", .rust)
        #expect(has(k, "'z'", .string))
        #expect(!k.contains { $0.1 == .string && $0.0.hasPrefix("'a") })
        #expect(has(k, "fn", .keyword))
    }

    @Test func htmlTagsAttributesAndComments() {
        let k = kinds("<!-- c --><div class=\"a\">text</div>", .html)
        #expect(has(k, "<!-- c -->", .comment))
        #expect(has(k, "<div", .tag))
        #expect(has(k, "class", .attribute))
        #expect(has(k, "\"a\"", .string))
        #expect(has(k, "</div", .tag))
    }

    @Test func markdownHeadingsFencesAndInlineCode() {
        let k = kinds("# Title\ntext `code` more\n```swift\nlet x = 1\n```\n> quote\n", .markdown)
        #expect(has(k, "# Title", .heading))
        #expect(has(k, "`code`", .string))
        #expect(has(k, "let x = 1", .string))
        #expect(has(k, "> quote", .comment))
    }

    @Test func sqlKeywordsAreCaseInsensitive() {
        let k = kinds("SELECT id FROM t WHERE x = 'a' -- c", .sql)
        #expect(has(k, "SELECT", .keyword))
        #expect(has(k, "FROM", .keyword))
        #expect(has(k, "'a'", .string))
        #expect(has(k, "-- c", .comment))
    }

    @Test func spansNeverOverlapAndStayInBounds() {
        let sample = String(repeating: "func a() { let s = \"x\" // c\n  /* b */ 12 }\n", count: 200)
        let spans = SyntaxHighlighter.spans(in: sample, language: .swift)
        let length = (sample as NSString).length
        var cursor = 0
        for span in spans {
            #expect(span.range.location >= cursor)
            #expect(NSMaxRange(span.range) <= length)
            cursor = NSMaxRange(span.range)
        }
    }

    @Test func respectsTheLimit() {
        let text = String(repeating: "let a = 1\n", count: 100)
        let spans = SyntaxHighlighter.spans(in: text, language: .swift, limit: 50)
        #expect(spans.allSatisfy { NSMaxRange($0.range) <= 50 })
    }
}
