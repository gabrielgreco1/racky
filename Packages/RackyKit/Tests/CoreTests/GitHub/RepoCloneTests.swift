import RackyProtocol
import RackyStore
import Foundation
import Testing
@testable import RackyCore

// MARK: Catálogo de repositórios (runner falso do gh)

private func repoJSON(_ items: [(owner: String, name: String, isPrivate: Bool, lang: String?, pushed: String?, updated: String)]) -> String {
    let objects = items.map { item -> String in
        let lang = item.lang.map { "{\"name\":\"\($0)\"}" } ?? "null"
        let pushed = item.pushed.map { "\"\($0)\"" } ?? "null"
        return """
        {"name":"\(item.name)","owner":{"id":"X","login":"\(item.owner)"},"isPrivate":\(item.isPrivate),"primaryLanguage":\(lang),\
        "pushedAt":\(pushed),"updatedAt":"\(item.updated)","description":"desc of \(item.name)"}
        """
    }
    return "[" + objects.joined(separator: ",") + "]"
}

private func ok(_ stdout: String) -> GitCommandResult { GitCommandResult(exitCode: 0, stdout: stdout, stderr: "") }

@Suite struct GitHubRepoCatalogTests {
    static let user = repoJSON([
        ("me", "old-tool", false, "Go", "2024-01-01T00:00:00Z", "2024-01-02T00:00:00Z"),
        ("me", "secret", true, "Swift", "2025-06-01T10:00:00Z", "2025-06-01T10:00:00Z"),
        ("me", "never-pushed", false, nil, nil, "2025-03-01T00:00:00Z"),
    ])
    static let org = repoJSON([
        ("acme", "platform", true, "TypeScript", "2025-09-01T12:00:00Z", "2025-09-01T12:00:00Z"),
        ("me", "secret", true, "Swift", "2025-06-01T10:00:00Z", "2025-06-01T10:00:00Z"),
    ])

    static func runner() -> FakeGitHubRunner {
        FakeGitHubRunner { args in
            switch args.prefix(3).joined(separator: " ") {
            case "repo list --limit": return ok(user)
            case "repo list acme": return ok(org)
            default:
                if args.first == "api", args.dropFirst().first == "user/orgs" { return ok("acme\n") }
                return GitCommandResult(exitCode: 1, stdout: "", stderr: "unexpected \(args)")
            }
        }
    }

    @Test func listsUserAndOrganizationReposSortedByActivityWithoutDuplicates() async throws {
        let runner = Self.runner()
        let catalog = GitHubRepoCatalog(runner: runner)
        let repos = try await catalog.repositories()
        #expect(repos.map(\.nameWithOwner) == ["acme/platform", "me/secret", "me/never-pushed", "me/old-tool"])
        let secret = try #require(repos.first { $0.name == "secret" })
        #expect(secret.isPrivate && secret.language == "Swift" && secret.summary == "desc of secret")
        // Sem pushedAt, vale updatedAt (2025-03 fica entre 2025-06 e 2024-01).
        #expect(repos.first { $0.name == "never-pushed" }?.activityDate == repos.first { $0.name == "never-pushed" }?.updatedAt)
        #expect(repos.first { $0.name == "never-pushed" }?.language == nil)
    }

    @Test func usesTheGhJSONListCommandWithTheRequestedFields() async throws {
        let runner = Self.runner()
        _ = try await GitHubRepoCatalog(runner: runner, limit: 50).repositories()
        let list = try #require(runner.calls.first { $0.first == "repo" })
        #expect(list.contains("--json") && list.contains("--limit") && list.contains("50"))
        #expect(list.contains(GitHubRepoCatalogParser.jsonFields))
        #expect(runner.calls.contains { $0.prefix(3) == ["repo", "list", "acme"] })
    }

    @Test func cacheServesTheSecondCallUntilTtlOrForce() async throws {
        let runner = Self.runner()
        let clock = TestClock()
        let catalog = GitHubRepoCatalog(runner: runner, ttl: 300, now: { clock.now })
        _ = try await catalog.repositories()
        let first = runner.calls.count
        _ = try await catalog.repositories()
        #expect(runner.calls.count == first, "dentro do TTL não chama o gh")
        #expect(await catalog.cached()?.count == 4)
        clock.advance(301)
        _ = try await catalog.repositories()
        #expect(runner.calls.count == first * 2, "TTL vencido atualiza")
        _ = try await catalog.repositories(forceRefresh: true)
        #expect(runner.calls.count == first * 3)
        await catalog.invalidate()
        #expect(await catalog.cached() == nil)
    }

    @Test func notLoggedInIsReportedAsNotAuthenticated() async throws {
        let runner = FakeGitHubRunner { _ in
            GitCommandResult(exitCode: 4, stdout: "", stderr: "To get started with GitHub CLI, please run:  gh auth login")
        }
        await #expect(throws: GitHubError.notAuthenticated(host: "github.com")) {
            _ = try await GitHubRepoCatalog(runner: runner).repositories()
        }
    }

    @Test func missingGhIsReportedAndOrganizationFailureIsTolerated() async throws {
        let missing = FakeGitHubRunner { _ in throw GitHubError.ghNotInstalled }
        await #expect(throws: GitHubError.ghNotInstalled) { _ = try await GitHubRepoCatalog(runner: missing).repositories() }

        let flaky = FakeGitHubRunner { args in
            if args.first == "api" { return GitCommandResult(exitCode: 1, stdout: "", stderr: "HTTP 403 read:org") }
            return ok(Self.user)
        }
        #expect(try await GitHubRepoCatalog(runner: flaky).repositories().count == 3)
    }

    @Test func searchMatchesNameOwnerLanguageAndDescriptionPrefixFirst() throws {
        let repos = try GitHubRepoCatalogParser.parseRepos(json: Self.user + "")
            + GitHubRepoCatalogParser.parseRepos(json: Self.org)
        #expect(GitHubRepoCatalog.search("", in: repos).count == repos.count)
        #expect(GitHubRepoCatalog.search("plat", in: repos).map(\.name) == ["platform"])
        #expect(GitHubRepoCatalog.search("swift", in: repos).map(\.name) == ["secret", "secret"])
        #expect(GitHubRepoCatalog.search("acme type", in: repos).map(\.name) == ["platform"])
        #expect(GitHubRepoCatalog.search("desc of old", in: repos).map(\.name) == ["old-tool"])
        #expect(GitHubRepoCatalog.search("zzz", in: repos).isEmpty)
        // Quem começa com o texto vem antes de quem só contém.
        let mixed = [GitHubRepository(owner: "a", name: "my-tool"), GitHubRepository(owner: "a", name: "tool")]
        #expect(GitHubRepoCatalog.search("tool", in: mixed).map(\.name) == ["tool", "my-tool"])
    }

    @Test func parserRejectsGarbageAndReadsOrganizations() {
        #expect(throws: GitHubError.self) { _ = try GitHubRepoCatalogParser.parseRepos(json: "not json") }
        #expect(GitHubRepoCatalogParser.parseOrganizations(output: "acme\n\n  other-org \nwarning: something odd\n") == ["acme", "other-org"])
    }
}

// MARK: Referência (URL, SSH, owner/repo)

@Suite struct RepoReferenceTests {
    @Test(arguments: [
        ("octocat/Hello-World", "https://github.com/octocat/Hello-World.git", "octocat", "Hello-World", true),
        ("octocat/Hello-World.git", "https://github.com/octocat/Hello-World.git", "octocat", "Hello-World", true),
        ("https://github.com/octocat/Hello-World", "https://github.com/octocat/Hello-World.git", "octocat", "Hello-World", false),
        ("https://github.com/octocat/Hello-World.git", "https://github.com/octocat/Hello-World.git", "octocat", "Hello-World", false),
        ("https://github.com/octocat/Hello-World/tree/main/src", "https://github.com/octocat/Hello-World.git", "octocat", "Hello-World", false),
        ("https://user:s3cret@github.com/octocat/Hello-World.git", "https://github.com/octocat/Hello-World.git", "octocat", "Hello-World", false),
        ("github.com/octocat/Hello-World", "https://github.com/octocat/Hello-World.git", "octocat", "Hello-World", false),
        ("git@github.com:octocat/Hello-World.git", "git@github.com:octocat/Hello-World.git", "octocat", "Hello-World", false),
        ("ssh://git@github.com/octocat/Hello-World.git", "ssh://git@github.com/octocat/Hello-World.git", "octocat", "Hello-World", false),
        ("  octocat/Hello-World \n", "https://github.com/octocat/Hello-World.git", "octocat", "Hello-World", true),
        ("https://gitlab.com/group/sub/project.git", "https://gitlab.com/group/sub/project.git", "sub", "project", false),
    ])
    func parsesSupportedForms(text: String, url: String, owner: String, name: String, shorthand: Bool) throws {
        let ref = try #require(RepoReferenceParser.parse(text))
        #expect(ref.cloneURL == url)
        #expect(ref.owner == owner && ref.name == name && ref.isShorthand == shorthand)
    }

    @Test(arguments: [
        "", "   ", "octocat", "octocat/", "/octocat/hello", "-c core.sshCommand=evil", "--upload-pack=evil/x", "file:///etc/passwd",
        "ext::sh -c touch /tmp/pwn", "http://example.com/a/b", "ftp://example.com/a/b", "https://github.com/octocat", "a/b/c",
        "https://github.com/../etc", "octocat/he llo", "git@github.com:octocat", "https://example.com/a/..", "owner/-repo",
    ])
    func rejectsUnsafeOrIncompleteInput(text: String) {
        #expect(RepoReferenceParser.parse(text) == nil, "\(text)")
    }

    @Test func httpsAndGitHubFlagsAndDisplayName() throws {
        let https = try #require(RepoReferenceParser.parse("octocat/Hello-World"))
        #expect(https.usesHTTPS && https.isGitHub && https.displayName == "octocat/Hello-World")
        let ssh = try #require(RepoReferenceParser.parse("git@github.com:octocat/Hello-World.git"))
        #expect(!ssh.usesHTTPS && ssh.isGitHub)
    }
}

// MARK: Progresso do git clone

@Suite struct GitCloneProgressTests {
    @Test func parsesEachPhase() {
        typealias P = CloneProgress
        #expect(GitCloneProgressParser.parse(line: "Receiving objects:  42% (5/12), 1.20 MiB | 2.00 MiB/s") == P(phase: .receiving, percent: 42))
        #expect(GitCloneProgressParser.parse(line: "Receiving objects: 100% (12/12), 2.00 MiB, done.") == P(phase: .receiving, percent: 100))
        #expect(GitCloneProgressParser.parse(line: "Resolving deltas:  7% (1/14)") == P(phase: .resolving, percent: 7))
        #expect(GitCloneProgressParser.parse(line: "remote: Counting objects: 100% (3/3), done.") == P(phase: .counting, percent: 100))
        #expect(GitCloneProgressParser.parse(line: "remote: Compressing objects:  50% (1/2)") == P(phase: .compressing, percent: 50))
        #expect(GitCloneProgressParser.parse(line: "remote: Enumerating objects: 12, done.") == P(phase: .counting, percent: nil))
        #expect(GitCloneProgressParser.parse(line: "Updating files:  80% (8/10)") == P(phase: .updatingFiles, percent: 80))
        #expect(GitCloneProgressParser.parse(line: "Cloning into 'x'...") == nil)
        #expect(GitCloneProgressParser.parse(line: "fatal: repository not found") == nil)
    }

    @Test func overallProgressIsMonotonicAcrossPhases() {
        let steps: [CloneProgress] = [
            .init(phase: .starting), .init(phase: .counting, percent: 100), .init(phase: .compressing, percent: 100),
            .init(phase: .receiving, percent: 0), .init(phase: .receiving, percent: 50), .init(phase: .receiving, percent: 100),
            .init(phase: .resolving, percent: 50), .init(phase: .resolving, percent: 100), .init(phase: .updatingFiles, percent: 100),
        ]
        let values = steps.map(\.overall)
        #expect(values == values.sorted())
        #expect(values.first == 0 && abs(values.last! - 1) < 0.0001)
        #expect(CloneProgress(phase: .receiving, percent: 42).text == "Receiving objects 42%")
    }

    @Test func splitterJoinsChunksAndHonorsCarriageReturns() {
        var splitter = GitCloneProgressParser.LineSplitter()
        #expect(splitter.feed("Receiving objects:  1").isEmpty)
        #expect(splitter.feed("0% (1/10)\rReceiving objects:  20% (2/10)\r") == ["Receiving objects:  10% (1/10)", "Receiving objects:  20% (2/10)"])
        #expect(splitter.feed("Resolving deltas: 50%\nfatal") == ["Resolving deltas: 50%"])
        #expect(splitter.flush() == "fatal")
        #expect(splitter.flush() == nil)
    }
}

// MARK: Clonador (runner falso e git real em pastas temporárias)

/// Runner de clone falso: grava os argumentos, emite stderr e age sobre a pasta de destino como o git faria.
private final class FakeCloneRunner: GitCloneRunning, @unchecked Sendable { // SAFETY: estado protegido por `lock`.
    private let lock = NSLock()
    private var _calls: [(args: [String], env: [String: String])] = []
    private let body: @Sendable ([String], @Sendable (String) -> Void) async throws -> GitCommandResult
    init(_ body: @escaping @Sendable ([String], @Sendable (String) -> Void) async throws -> GitCommandResult) { self.body = body }
    var calls: [(args: [String], env: [String: String])] { lock.withLock { _calls } }

    func clone(arguments: [String], environment: [String: String], onStderr: @escaping @Sendable (String) -> Void) async throws -> GitCommandResult {
        lock.withLock { _calls.append((arguments, environment)) }
        return try await body(arguments, onStderr)
    }
}

private final class ProgressLog: @unchecked Sendable { // SAFETY: estado protegido por `lock`.
    private let lock = NSLock()
    private var _items: [CloneProgress] = []
    func add(_ p: CloneProgress) { lock.withLock { _items.append(p) } }
    var items: [CloneProgress] { lock.withLock { _items } }
}

private final class Registered: @unchecked Sendable { // SAFETY: estado protegido por `lock`.
    private let lock = NSLock()
    private var _urls: [URL] = []
    func add(_ u: URL) { lock.withLock { _urls.append(u) } }
    var urls: [URL] { lock.withLock { _urls } }
}

private func fakeProject(_ url: URL) -> Project {
    Project(name: url.lastPathComponent, kind: .git, rootPath: url.path, gitRemoteURL: nil, defaultBranch: nil, worktreeRoot: nil,
            branchPrefix: nil, source: .manual, sortIndex: 0, createdAt: Date())
}

@Suite struct RepoClonerTests {
    static let gh = URL(fileURLWithPath: "/opt/homebrew/bin/gh")

    /// O destino é o último argumento; cria a pasta como o `git clone` faria.
    private static func destination(_ args: [String]) -> URL { URL(fileURLWithPath: args[args.count - 1], isDirectory: true) }

    private func make(
        _ sandbox: GitSandbox, runner: any GitCloneRunning, gh: URL? = RepoClonerTests.gh, registered: Registered = Registered()
    ) -> RepoCloner {
        RepoCloner(runner: runner, git: sandbox.service, ghExecutable: gh) { url in
            registered.add(url)
            return fakeProject(url)
        }
    }

    @Test func clonesIntoProjectsRootReportsProgressAndRegistersTheProject() async throws {
        let sandbox = try GitSandbox()
        let root = sandbox.root.appendingPathComponent("projects", isDirectory: true)
        let runner = FakeCloneRunner { args, stderr in
            try FileManager.default.createDirectory(at: Self.destination(args), withIntermediateDirectories: true)
            stderr("Cloning into 'Hello-World'...\nremote: Counting objects: 100% (3/3), done.\nReceiving objects:  42% (5/12)\r")
            stderr("Receiving objects: 100% (12/12), done.\nResolving deltas: 100% (2/2), done.\n")
            return GitCommandResult(exitCode: 0, stdout: "", stderr: "")
        }
        let registered = Registered()
        let log = ProgressLog()
        let ref = try #require(RepoReferenceParser.parse("octocat/Hello-World"))
        let result = try await make(sandbox, runner: runner, registered: registered).clone(ref, into: root) { log.add($0) }

        #expect(result.destination == root.appendingPathComponent("Hello-World", isDirectory: true))
        #expect(!result.alreadyExisted && registered.urls == [result.destination] && result.project.name == "Hello-World")
        let phases = log.items.map(\.phase)
        #expect(phases.first == .starting)
        #expect(log.items.contains(CloneProgress(phase: .receiving, percent: 42)))
        #expect(log.items.contains(CloneProgress(phase: .resolving, percent: 100)))
        let call = try #require(runner.calls.first)
        #expect(call.args.contains("--progress"))
        let dashIndex = try #require(call.args.firstIndex(of: "--"))
        #expect(call.args[dashIndex + 1] == "https://github.com/octocat/Hello-World.git", "URL vem depois de `--`, nunca como opção")
        #expect(call.env["GIT_TERMINAL_PROMPT"] == "0" && call.env["LC_ALL"] == "C")
    }

    @Test func httpsCloneUsesTheGhCredentialHelperOnlyForThatCommand() async throws {
        let sandbox = try GitSandbox()
        let runner = FakeCloneRunner { args, _ in
            try FileManager.default.createDirectory(at: Self.destination(args), withIntermediateDirectories: true)
            return GitCommandResult(exitCode: 0, stdout: "", stderr: "")
        }
        let root = sandbox.root.appendingPathComponent("p", isDirectory: true)
        let https = try #require(RepoReferenceParser.parse("octocat/Hello-World"))
        _ = try await make(sandbox, runner: runner).clone(https, into: root) { _ in }
        let args = try #require(runner.calls.first?.args)
        #expect(args.starts(with: ["-c", "credential.https://github.com.helper=", "-c"]))
        #expect(args[3] == "credential.https://github.com.helper=!'/opt/homebrew/bin/gh' auth git-credential")
        #expect(args[4] == "clone")

        let ssh = try #require(RepoReferenceParser.parse("git@github.com:octocat/Other.git"))
        _ = try await make(sandbox, runner: runner).clone(ssh, into: root) { _ in }
        let sshCall = try #require(runner.calls.last)
        #expect(sshCall.args.first == "clone", "SSH não usa helper de credencial")
        #expect(sshCall.env["GIT_SSH_COMMAND"]?.contains("BatchMode=yes") == true)

        let noGh = FakeCloneRunner { args, _ in
            try FileManager.default.createDirectory(at: Self.destination(args), withIntermediateDirectories: true)
            return GitCommandResult(exitCode: 0, stdout: "", stderr: "")
        }
        let publicRef = try #require(RepoReferenceParser.parse("octocat/Public"))
        _ = try await make(sandbox, runner: noGh, gh: nil).clone(publicRef, into: root) { _ in }
        #expect(noGh.calls.first?.args.first == "clone", "sem gh a URL pública ainda clona")
    }

    @Test func existingFolderWithTheSameRemoteIsOpenedWithoutCloning() async throws {
        let sandbox = try GitSandbox()
        let root = try sandbox.dir("projects")
        let existing = root.appendingPathComponent("Hello-World", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try await sandbox.git(["init", "-q", "-b", "main"], in: existing)
        // Mesmo remote em outra forma (ssh) e com maiúsculas diferentes.
        try await sandbox.git(["remote", "add", "origin", "git@github.com:OctoCat/hello-world.git"], in: existing)
        let runner = FakeCloneRunner { _, _ in GitCommandResult(exitCode: 0, stdout: "", stderr: "") }
        let registered = Registered()
        let ref = try #require(RepoReferenceParser.parse("octocat/Hello-World"))
        let result = try await make(sandbox, runner: runner, registered: registered).clone(ref, into: root) { _ in }
        #expect(result.alreadyExisted && result.destination.path == existing.path)
        #expect(runner.calls.isEmpty, "não clona por cima")
        #expect(registered.urls.map(\.path) == [existing.path])
    }

    @Test func foreignFolderGetsAnOwnerSuffixOrAClearConflict() async throws {
        let sandbox = try GitSandbox()
        let root = try sandbox.dir("projects")
        let foreign = root.appendingPathComponent("Hello-World", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try "mine\n".write(to: foreign.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let runner = FakeCloneRunner { args, _ in
            try FileManager.default.createDirectory(at: Self.destination(args), withIntermediateDirectories: true)
            return GitCommandResult(exitCode: 0, stdout: "", stderr: "")
        }
        let ref = try #require(RepoReferenceParser.parse("octocat/Hello-World"))
        let result = try await make(sandbox, runner: runner).clone(ref, into: root) { _ in }
        #expect(result.destination.lastPathComponent == "Hello-World-octocat")
        #expect(FileManager.default.fileExists(atPath: foreign.appendingPathComponent("notes.txt").path), "a pasta do usuário fica intacta")

        // As duas ocupadas por outra coisa: conflito claro, nada é clonado.
        let second = root.appendingPathComponent("Other-octocat", isDirectory: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try "x".write(to: second.appendingPathComponent("a"), atomically: true, encoding: .utf8)
        let other = root.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try "x".write(to: other.appendingPathComponent("a"), atomically: true, encoding: .utf8)
        let before = runner.calls.count
        let otherRef = try #require(RepoReferenceParser.parse("octocat/Other"))
        await #expect(throws: CloneError.destinationConflict(path: other.path)) {
            _ = try await make(sandbox, runner: runner).clone(otherRef, into: root) { _ in }
        }
        #expect(runner.calls.count == before)
        #expect(CloneError.destinationConflict(path: other.path).errorDescription == "A folder named Other already exists and isn't this repository.")
    }

    @Test func emptyExistingFolderIsReused() async throws {
        let sandbox = try GitSandbox()
        let root = try sandbox.dir("projects")
        let empty = root.appendingPathComponent("Hello-World", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let runner = FakeCloneRunner { _, _ in GitCommandResult(exitCode: 0, stdout: "", stderr: "") }
        let ref = try #require(RepoReferenceParser.parse("octocat/Hello-World"))
        let result = try await make(sandbox, runner: runner).clone(ref, into: root) { _ in }
        #expect(result.destination.path == empty.path && !result.alreadyExisted && runner.calls.count == 1)
    }

    @Test func failuresAreClassifiedAndLeaveNothingBehind() async throws {
        let cases: [(stderr: String, expected: CloneError)] = [
            ("Cloning into 'x'...\nremote: Repository not found.\nfatal: repository 'https://github.com/a/b.git/' not found", .notFound),
            ("fatal: could not read Username for 'https://github.com': terminal prompts disabled", .authenticationRequired),
            ("git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository.", .authenticationRequired),
            ("fatal: unable to access 'https://github.com/a/b.git/': Could not resolve host: github.com", .network),
            ("fatal: something odd happened", .failed("fatal: something odd happened")),
        ]
        for (stderr, expected) in cases {
            let sandbox = try GitSandbox()
            let root = sandbox.root.appendingPathComponent("projects", isDirectory: true)
            let runner = FakeCloneRunner { args, _ in
                try FileManager.default.createDirectory(at: Self.destination(args), withIntermediateDirectories: true)
                try "partial".write(to: Self.destination(args).appendingPathComponent("p"), atomically: true, encoding: .utf8)
                return GitCommandResult(exitCode: 128, stdout: "", stderr: stderr)
            }
            let registered = Registered()
            let ref = try #require(RepoReferenceParser.parse("a/b"))
            await #expect(throws: expected) { _ = try await make(sandbox, runner: runner, registered: registered).clone(ref, into: root) { _ in } }
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("b").path), "pasta parcial removida: \(stderr)")
            #expect(registered.urls.isEmpty)
        }
        #expect(CloneError.notFound.errorDescription == "Repository not found. If it is private, log in to GitHub.")
        // Números de progresso (403/500) não viram erro de permissão.
        #expect(RepoCloner.classify(stderr: "Receiving objects: 80% (403/500)\nfatal: early EOF") == .failed("fatal: early EOF"))
    }

    @Test func cancellingStopsTheCloneAndRemovesThePartialFolder() async throws {
        let sandbox = try GitSandbox()
        let root = sandbox.root.appendingPathComponent("projects", isDirectory: true)
        let started = Registered()
        let runner = FakeCloneRunner { args, _ in
            try FileManager.default.createDirectory(at: Self.destination(args), withIntermediateDirectories: true)
            started.add(Self.destination(args))
            try await Task.sleep(for: .seconds(60))
            return GitCommandResult(exitCode: 0, stdout: "", stderr: "")
        }
        let registered = Registered()
        let cloner = make(sandbox, runner: runner, registered: registered)
        let ref = try #require(RepoReferenceParser.parse("octocat/Hello-World"))
        let task = Task { try await cloner.clone(ref, into: root) { _ in } }
        for _ in 0 ..< 200 where started.urls.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!started.urls.isEmpty)
        task.cancel()
        await #expect(throws: CloneError.cancelled) { _ = try await task.value }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Hello-World").path))
        #expect(registered.urls.isEmpty)
    }

    @Test func gitMissingAndRegistrationFailureAreReported() async throws {
        let sandbox = try GitSandbox()
        let root = sandbox.root.appendingPathComponent("projects", isDirectory: true)
        let missing = FakeCloneRunner { _, _ in throw GitError.gitNotInstalled }
        let ref = try #require(RepoReferenceParser.parse("a/b"))
        await #expect(throws: CloneError.gitNotInstalled) { _ = try await make(sandbox, runner: missing).clone(ref, into: root) { _ in } }

        struct Boom: Error {}
        let ok = FakeCloneRunner { args, _ in
            try FileManager.default.createDirectory(at: Self.destination(args), withIntermediateDirectories: true)
            return GitCommandResult(exitCode: 0, stdout: "", stderr: "")
        }
        let cloner = RepoCloner(runner: ok, git: sandbox.service, ghExecutable: nil) { _ in throw Boom() }
        do {
            _ = try await cloner.clone(ref, into: root) { _ in }
            Issue.record("devia falhar")
        } catch let error as CloneError {
            if case .failed(let message) = error {
                #expect(message.hasPrefix("Cloned, but couldn't add the project"))
            } else {
                Issue.record("erro inesperado \(error)")
            }
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("b").path), "o clone fica no disco")
        }
    }

    @Test func realLocalCloneWithTheProductionRunnerRegistersARealProject() async throws {
        let h = try await ProjectHarness()
        let (_, origin) = try await h.sandbox.makeRepoWithOrigin("source")
        let root = h.sandbox.root.appendingPathComponent("projects", isDirectory: true)
        let ref = RepoReference(cloneURL: origin.path, host: nil, owner: nil, name: "source-clone", isShorthand: false)
        let log = ProgressLog()
        let cloner = RepoCloner(runner: GitCloneProcessRunner(), git: h.sandbox.service, ghExecutable: nil, projects: h.service)
        let result = try await cloner.clone(ref, into: root) { log.add($0) }
        #expect(result.project.kind == .git && result.project.name == "source-clone")
        #expect(FileManager.default.fileExists(atPath: result.destination.appendingPathComponent("README.md").path))
        #expect(try await h.store.projects().map(\.id) == [result.project.id])
        #expect(log.items.first?.phase == .starting)

        // Clonar de novo abre o mesmo projeto sem clonar nada.
        let again = try await cloner.clone(ref, into: root) { _ in }
        #expect(again.alreadyExisted && again.project.id == result.project.id)
    }
}

// MARK: Integração real opcional (RACKY_REAL_GH=1)

/// `RACKY_REAL_GH=1`: clona `octocat/Hello-World` (repositório público pequeno) com `git` e `gh` reais, só em pasta
/// temporária, e lista os repositórios da conta quando o `gh` está logado. Nada é criado no GitHub.
@Suite struct RepoCloneRealTests {
    static let enabled = ProcessInfo.processInfo.environment["RACKY_REAL_GH"] == "1"

    @Test(.enabled(if: RepoCloneRealTests.enabled), .timeLimit(.minutes(3)))
    func clonesOctocatHelloWorldIntoATemporaryFolder() async throws {
        let h = try await ProjectHarness()
        let root = h.sandbox.root.appendingPathComponent("projects", isDirectory: true)
        let ref = try #require(RepoReferenceParser.parse("octocat/Hello-World"))
        let log = ProgressLog()
        let cloner = RepoCloner(runner: GitCloneProcessRunner(), git: h.sandbox.service, projects: h.service)
        let result = try await cloner.clone(ref, into: root) { log.add($0) }
        #expect(result.destination.lastPathComponent == "Hello-World")
        #expect(FileManager.default.fileExists(atPath: result.destination.appendingPathComponent("README").path))
        #expect(result.project.kind == .git && result.project.gitRemoteURL?.contains("octocat/Hello-World") == true)
        #expect(log.items.contains { $0.phase == .receiving }, "o git real informa o progresso de recebimento")
        #expect(!result.alreadyExisted)
        let again = try await cloner.clone(ref, into: root) { _ in }
        #expect(again.alreadyExisted)
    }

    @Test(.enabled(if: RepoCloneRealTests.enabled), .timeLimit(.minutes(2)))
    func listsTheAccountRepositoriesWhenGhIsLoggedIn() async throws {
        let auth = await GitHubService().authStatus()
        try #require(auth.isConnected, "gh não está autenticado")
        let repos = try await GitHubRepoCatalog().repositories(forceRefresh: true)
        #expect(repos == GitHubRepoCatalog.search("", in: repos))
        let dates = repos.compactMap(\.activityDate)
        #expect(dates == dates.sorted(by: >), "mais recentes primeiro")
    }
}
