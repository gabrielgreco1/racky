import Foundation
import Testing
@testable import RackyCore

private func makeTree(_ files: [String]) throws -> String {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("racky-files-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for file in files {
        let url = root.appendingPathComponent(file)
        if file.hasSuffix("/") {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "x\n".write(to: url, atomically: true, encoding: .utf8)
        }
    }
    return FileTreeLoader.canonical(root.path)
}

@Suite struct GitIgnoreTests {
    private func ignored(_ patterns: String, _ path: String, dir: Bool = false) -> Bool {
        var stack = GitIgnoreStack()
        stack.push(GitIgnoreFile(directory: "/repo", contents: patterns))
        return stack.isIgnored("/repo/" + path, isDirectory: dir)
    }

    @Test func plainNamesMatchAtAnyDepth() {
        #expect(ignored("build", "build", dir: true))
        #expect(ignored("build", "a/b/build", dir: true))
        #expect(!ignored("build", "builder"))
    }

    @Test func globsStarQuestionAndClasses() {
        #expect(ignored("*.log", "x.log"))
        #expect(ignored("*.log", "deep/dir/x.log"))
        #expect(!ignored("*.log", "x.logs"))
        #expect(ignored("file?.txt", "file1.txt"))
        #expect(!ignored("file?.txt", "file10.txt"))
        #expect(ignored("[ab].txt", "a.txt"))
        #expect(!ignored("[ab].txt", "c.txt"))
    }

    @Test func trailingSlashOnlyMatchesDirectories() {
        #expect(ignored("out/", "out", dir: true))
        #expect(!ignored("out/", "out", dir: false))
    }

    @Test func slashAnchorsToTheIgnoreFileDirectory() {
        #expect(ignored("/dist", "dist", dir: true))
        #expect(!ignored("/dist", "pkg/dist", dir: true))
        #expect(ignored("docs/api", "docs/api", dir: true))
        #expect(!ignored("docs/api", "x/docs/api", dir: true))
    }

    @Test func doubleStar() {
        #expect(ignored("**/gen", "a/b/gen", dir: true))
        #expect(ignored("**/gen", "gen", dir: true))
        #expect(ignored("a/**/z", "a/z"))
        #expect(ignored("a/**/z", "a/b/c/z"))
        #expect(ignored("logs/**", "logs/x/y.txt"))
    }

    @Test func negationAndLastRuleWins() {
        let patterns = "*.log\n!keep.log\n"
        #expect(ignored(patterns, "a.log"))
        #expect(!ignored(patterns, "keep.log"))
        #expect(ignored("!keep.log\n*.log\n", "keep.log"), "a regra de baixo vence")
    }

    @Test func commentsAndBlankLinesAreSkipped() {
        #expect(!ignored("# *.log\n\n", "x.log"))
        #expect(GitIgnoreRule(line: "   ") == nil)
        #expect(GitIgnoreRule(line: "# nope") == nil)
    }

    @Test func nestedIgnoreFilesAreRelativeToTheirDirectory() {
        var stack = GitIgnoreStack()
        stack.push(GitIgnoreFile(directory: "/repo", contents: "*.tmp\n"))
        stack.push(GitIgnoreFile(directory: "/repo/sub", contents: "/only-here\n"))
        #expect(stack.isIgnored("/repo/sub/only-here", isDirectory: false))
        #expect(!stack.isIgnored("/repo/only-here", isDirectory: false))
        #expect(stack.isIgnored("/repo/sub/deep/a.tmp", isDirectory: false))
    }
}

@Suite struct FileTreeLoaderTests {
    @Test func sortsFoldersFirstThenNamesNaturally() throws {
        let root = try makeTree(["b.txt", "a.txt", "Zed/", "alpha/", "file10.txt", "file2.txt"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let names = FileTreeLoader.list(directory: root, root: root, options: FileTreeOptions()).entries.map(\.name)
        #expect(names == ["alpha", "Zed", "a.txt", "b.txt", "file2.txt", "file10.txt"])
    }

    @Test func hidesGitNodeModulesAndGitignoredByDefault() throws {
        let root = try makeTree([".git/HEAD", "node_modules/x/index.js", "src/main.swift", "secret.env", "keep.txt", ".gitignore", ".DS_Store"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "secret.env\n".write(toFile: root + "/.gitignore", atomically: true, encoding: .utf8)
        let names = FileTreeLoader.list(directory: root, root: root, options: FileTreeOptions()).entries.map(\.name)
        #expect(names == ["src", ".gitignore", "keep.txt"])
    }

    @Test func showIgnoredRevealsThemFlagged() throws {
        let root = try makeTree([".git/HEAD", "node_modules/x.js", "secret.env", "keep.txt", ".gitignore"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "secret.env\n".write(toFile: root + "/.gitignore", atomically: true, encoding: .utf8)
        let entries = FileTreeLoader.list(directory: root, root: root, options: FileTreeOptions(showIgnored: true)).entries
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        #expect(byName[".git"]?.isIgnored == true)
        #expect(byName["node_modules"]?.isIgnored == true)
        #expect(byName["secret.env"]?.isIgnored == true)
        #expect(byName["keep.txt"]?.isIgnored == false)
        #expect(byName[".gitignore"]?.isIgnored == false)
    }

    @Test func appliesGitignoreFilesAboveTheRootWhenInsideARepository() throws {
        let repo = try makeTree([".git/HEAD", "app/src/a.swift", "app/dist/out.js", ".gitignore"])
        defer { try? FileManager.default.removeItem(atPath: repo) }
        try "dist/\n".write(toFile: repo + "/.gitignore", atomically: true, encoding: .utf8)
        let root = repo + "/app"
        let names = FileTreeLoader.list(directory: root, root: root, options: FileTreeOptions()).entries.map(\.name)
        #expect(names == ["src"], "dist/ é ignorado pelo .gitignore da raiz do repositório")
    }

    @Test func childrenOfAnIgnoredFolderStayFlagged() throws {
        let root = try makeTree(["out/a.txt", "out/b.txt"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let listing = FileTreeLoader.list(directory: root + "/out", root: root, options: FileTreeOptions(showIgnored: true), ancestorIgnored: true)
        #expect(listing.entries.allSatisfy { $0.isIgnored })
    }

    @Test func symlinksAreLeavesAndMissingDirectoriesAreEmpty() throws {
        let root = try makeTree(["real/a.txt"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createSymbolicLink(atPath: root + "/link", withDestinationPath: root + "/real")
        let entries = FileTreeLoader.list(directory: root, root: root, options: FileTreeOptions()).entries
        let link = try #require(entries.first { $0.name == "link" })
        #expect(link.isSymlink)
        #expect(!link.isDirectory)
        #expect(FileTreeLoader.list(directory: root + "/nope", root: root, options: FileTreeOptions()).entries.isEmpty)
    }

    @Test func repositoryRootFindsGitFolderOrWorktreeFile() throws {
        let repo = try makeTree([".git/HEAD", "a/b/c.txt"])
        defer { try? FileManager.default.removeItem(atPath: repo) }
        #expect(FileTreeLoader.repositoryRoot(containing: repo + "/a/b") == repo)
        let plain = try makeTree(["x/y.txt"])
        defer { try? FileManager.default.removeItem(atPath: plain) }
        // Fora de repositório (e sem `.git` em nenhum ancestral do diretório temporário).
        #expect(FileTreeLoader.repositoryRoot(containing: plain + "/x") == nil)
    }
}

@Suite struct FileTreeStateTests {
    private func listing(_ entries: [FileEntry]) -> FileListing { FileListing(entries: entries, truncated: false) }

    private func state() -> FileTreeState {
        var s = FileTreeState(root: "/r")
        s.setListing(
            listing([
                FileEntry(path: "/r/src", isDirectory: true), FileEntry(path: "/r/docs", isDirectory: true), FileEntry(path: "/r/a.txt", isDirectory: false),
            ]), for: "/r")
        s.setListing(listing([FileEntry(path: "/r/src/main.swift", isDirectory: false), FileEntry(path: "/r/src/util", isDirectory: true)]), for: "/r/src")
        return s
    }

    @Test func collapsedTreeShowsOnlyTheRootChildren() {
        #expect(state().rows.map(\.entry.name) == ["src", "docs", "a.txt"])
        #expect(state().rows.allSatisfy { $0.depth == 0 })
    }

    @Test func expandingInsertsChildrenInPlaceWithDepth() {
        var s = state()
        s.toggle("/r/src")
        let rows = s.rows
        #expect(rows.map(\.entry.name) == ["src", "main.swift", "util", "docs", "a.txt"])
        #expect(rows.map(\.depth) == [0, 1, 1, 0, 0])
        #expect(rows[0].isExpanded)
        s.toggle("/r/src")
        #expect(s.rows.count == 3)
    }

    @Test func expandedButUnloadedFolderIsLoading() {
        var s = state()
        s.expand("/r/docs")
        let docs = s.rows.first { $0.entry.name == "docs" }
        #expect(docs?.isLoading == true)
        #expect(s.pendingDirectories == ["/r/docs"])
    }

    @Test func revealExpandsEveryAncestorAndReportsWhatToLoad() {
        var s = FileTreeState(root: "/r")
        let needed = s.reveal("/r/src/util/deep/file.txt")
        #expect(s.isExpanded("/r/src"))
        #expect(s.isExpanded("/r/src/util"))
        #expect(s.isExpanded("/r/src/util/deep"))
        #expect(needed == ["/r", "/r/src", "/r/src/util", "/r/src/util/deep"])
        var other = FileTreeState(root: "/r")
        #expect(other.reveal("/elsewhere/x").isEmpty)
    }

    @Test func invalidateKeepsExpansionButDropsListings() {
        var s = state()
        s.expand("/r/src")
        s.invalidate()
        #expect(s.isExpanded("/r/src"))
        #expect(s.rows.isEmpty)
        #expect(s.pendingDirectories == ["/r", "/r/src"])
    }

    @Test func visibleDirectoriesAreTheLoadedOnesToRefresh() {
        var s = state()
        s.expand("/r/src")
        s.expand("/r/docs")
        #expect(s.visibleDirectories == ["/r", "/r/src"])
    }
}

@Suite struct FilesFollowTests {
    private let isDir: (String) -> Bool = { _ in true }

    @Test func noSessionMeansNothingToShow() {
        let r = FilesFollow.resolve(sessionRoot: nil, agentCwd: "/tmp", agentName: "Claude", pinnedRoot: nil, isDirectory: isDir)
        #expect(r.root == nil)
        #expect(r.mode == .none)
    }

    @Test func startsOnTheSessionFolderAndFollowsTheAgentCwd() throws {
        let session = try makeTree(["proj/a.txt", "other/b.txt"])
        defer { try? FileManager.default.removeItem(atPath: session) }
        let r1 = FilesFollow.resolve(sessionRoot: session + "/proj", agentCwd: nil, agentName: "Claude", pinnedRoot: nil)
        #expect(r1.root == session + "/proj")
        #expect(r1.mode == .following(agent: "Claude"))
        #expect(!r1.isOutsideSession)
        // O agente entrou numa subpasta.
        let r2 = FilesFollow.resolve(sessionRoot: session + "/proj", agentCwd: session + "/proj/a.txt/..", agentName: "Claude", pinnedRoot: nil)
        #expect(r2.root == session + "/proj")
        // E depois foi para outra pasta fora da sessão.
        let r3 = FilesFollow.resolve(sessionRoot: session + "/proj", agentCwd: session + "/other", agentName: "Claude", pinnedRoot: nil)
        #expect(r3.root == session + "/other")
        #expect(r3.isOutsideSession)
    }

    @Test func pinWinsOverTheAgentCwd() throws {
        let session = try makeTree(["proj/a.txt", "other/b.txt"])
        defer { try? FileManager.default.removeItem(atPath: session) }
        let r = FilesFollow.resolve(
            sessionRoot: session + "/proj", agentCwd: session + "/other", agentName: "Claude", pinnedRoot: session + "/proj")
        #expect(r.root == session + "/proj")
        #expect(r.mode == .pinned)
    }

    @Test func aMissingPinFallsBackToFollowing() throws {
        let session = try makeTree(["proj/a.txt"])
        defer { try? FileManager.default.removeItem(atPath: session) }
        let r = FilesFollow.resolve(sessionRoot: session + "/proj", agentCwd: nil, agentName: "Codex", pinnedRoot: session + "/gone")
        #expect(r.mode == .following(agent: "Codex"))
        #expect(r.root == session + "/proj")
    }

    @Test func aCwdThatIsNotAFolderOrIsRootFallsBackToTheSession() throws {
        let session = try makeTree(["proj/a.txt"])
        defer { try? FileManager.default.removeItem(atPath: session) }
        let missing = FilesFollow.resolve(sessionRoot: session + "/proj", agentCwd: session + "/proj/missing", agentName: nil, pinnedRoot: nil)
        #expect(missing.root == session + "/proj")
        let slash = FilesFollow.resolve(sessionRoot: session + "/proj", agentCwd: "/", agentName: nil, pinnedRoot: nil)
        #expect(slash.root == session + "/proj")
    }

    @Test func tildeAndSymlinkedPathsAreCanonicalised() {
        #expect(FileTreeLoader.canonical("~") == FileTreeLoader.canonical(NSHomeDirectory()))
        #expect(FileTreeLoader.canonical("/tmp") == FileTreeLoader.canonical("/private/tmp"), "o mesmo diretório tem uma só forma canônica")
    }
}

@Suite struct AgentCwdTrackerTests {
    @Test func theMostRecentSourceWins() {
        var tracker = AgentCwdTracker()
        let terminal = UUID()
        let t0 = Date(timeIntervalSince1970: 1000)
        tracker.record("/a", terminal: terminal, source: .hook, at: t0)
        #expect(tracker.cwd(for: terminal) == "/a")
        tracker.record("/b", terminal: terminal, source: .osc7, at: t0.addingTimeInterval(1))
        #expect(tracker.cwd(for: terminal) == "/b")
        #expect(tracker.source(for: terminal) == .osc7)
        tracker.record("/stale", terminal: terminal, source: .hook, at: t0.addingTimeInterval(0.5))
        #expect(tracker.cwd(for: terminal) == "/b", "evento atrasado não sobrescreve um mais novo")
    }

    @Test func terminalsAreIndependentAndForgettable() {
        var tracker = AgentCwdTracker()
        let a = UUID(), b = UUID()
        tracker.record("/a", terminal: a, source: .osc7)
        tracker.record("", terminal: b, source: .hook)
        #expect(tracker.cwd(for: a) == "/a")
        #expect(tracker.cwd(for: b) == nil)
        tracker.forget(a)
        #expect(tracker.cwd(for: a) == nil)
    }
}
