import RackyCore
import RackyPlatform
import RackyProtocol
import RackyStore
import Foundation
import Testing

/// Composer ponta a ponta no nível do Core (T1-20): repositório temporário -> projeto -> `SessionCreationService` cria a
/// worktree e grava sessão/tab/terminal -> `LaunchCoordinator` lança o terminal gravado no `rackyd` real, na pasta da
/// worktree. zsh de verdade; `claude -p --model haiku "reply OK"` de verdade (opt-in por custo, `AB_REAL_CLI=1`).
@Suite(.serialized, .tags(.integration), .timeLimit(.minutes(1))) struct ComposerLaunchIntegrationTests {
    private final class Events: @unchecked Sendable {  // SAFETY: estado sob `lock`.
        private let lock = NSLock()  // LOCK: seções curtas, sem await.
        private var items: [LaunchEvent] = []
        func add(_ event: LaunchEvent) { lock.lock(); items.append(event); lock.unlock() }
        var all: [LaunchEvent] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private struct Rig {
        let root: URL
        let store: RackyStore
        let project: Project
        let service: SessionCreationService
        let worktreeRoot: URL
        let repo: URL
    }

    @discardableResult
    private static func git(_ args: [String], in dir: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = dir.path
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_AUTHOR_NAME"] = "Test User"; env["GIT_AUTHOR_EMAIL"] = "test@example.com"
        env["GIT_COMMITTER_NAME"] = "Test User"; env["GIT_COMMITTER_EMAIL"] = "test@example.com"
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeRig() async throws -> Rig {
        let root = URL(fileURLWithPath: "/tmp/abc-\(UInt32.random(in: 0 ... 0xFFFFFF))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = root.appendingPathComponent("acme-platform", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try Self.git(["init", "-q", "-b", "main"], in: repo)
        try "hello\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try Self.git(["add", "."], in: repo)
        try Self.git(["commit", "-q", "-m", "init"], in: repo)
        let origin = root.appendingPathComponent("origin.git", isDirectory: true)
        try Self.git(["init", "-q", "--bare", "-b", "main", origin.path], in: root)
        try Self.git(["remote", "add", "origin", origin.path], in: repo)
        try Self.git(["push", "-q", "-u", "origin", "main"], in: repo)
        try Self.git(["remote", "set-head", "origin", "main"], in: repo)

        let store = try await RackyStore.open(paths: StorePaths(root: root.appendingPathComponent("home", isDirectory: true)))
        let worktreeRoot = root.appendingPathComponent("wt", isDirectory: true)
        let projects = ProjectService(store: store, worktreeBase: worktreeRoot)
        let project = try await projects.addProject(folder: repo).project
        return Rig(root: root, store: store, project: project, service: SessionCreationService(store: store), worktreeRoot: worktreeRoot, repo: repo)
    }

    private func coordinator(_ harness: DaemonHarness, client: PTYClient, login: @escaping @Sendable () async -> [String: String]) -> LaunchCoordinator {
        let gateway = PTYLaunchGateway(client: client, ensureConnected: { (try? await client.start()) != nil })
        return LaunchCoordinator(
            daemon: gateway,
            configuration: .init(
                launchRoot: harness.home.appendingPathComponent("run/launch", isDirectory: true),
                appSocketPath: harness.home.appendingPathComponent("run/app.sock").path, loginEnvironment: login))
    }

    private func waitFor(_ client: PTYClient, _ id: SessionID, state: SessionState, timeout: Duration = .seconds(60)) async throws -> SessionSummary {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let s = try await client.list().first(where: { $0.sessionID == id }), s.state == state { return s }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw HarnessError.timeout("session \(id) never reached \(state)")
    }

    @Test func newWorktreeThenZshRunsInsideIt() async throws {
        let rig = try await makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let harness = try DaemonHarness()
        defer { harness.terminateNow() }
        try await harness.start()
        let client = harness.makeClient()
        try await client.start()

        let request = SessionCreationRequest(
            title: "fix search pagination",
            target: .newWorktree(NewWorktreeSpec(
                projectID: rig.project.id, source: .newBranch(slug: "fix-search-pagination", prefix: .custom("me"), baseRef: nil),
                worktreeRoot: rig.worktreeRoot)),
            spec: LaunchSpec(provider: .shell))
        let output = try await rig.service.create(request)
        #expect(output.session.folderPath.hasSuffix("/acme-platform/fix-search-pagination"))
        #expect(try Self.git(["rev-parse", "--abbrev-ref", "HEAD"], in: URL(fileURLWithPath: output.session.folderPath)) == "me/fix-search-pagination")

        // O terminal gravado é o que o workspace lançaria.
        let stored = try #require(try await rig.store.terminal(id: output.terminal.id))
        let c = coordinator(harness, client: client) { ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "SHELL": "/bin/zsh", "LANG": "en_US.UTF-8"] }
        let events = Events()
        let result = try await c.launch(LaunchJob(terminalID: stored.id, spec: stored.launchSpec, cwd: stored.cwd), onEvent: events.add)
        let running = try await waitFor(client, result.summary.sessionID, state: .running)
        #expect(running.argv0.hasSuffix("zsh"))
        #expect(running.cwd.hasSuffix("/acme-platform/fix-search-pagination"))
        #expect(running.inputBytesByOrigin.total == 0, "nada do app foi digitado no PTY (T11)")
        try await client.kill(sessionID: result.summary.sessionID, mode: .graceful)
        _ = try await waitFor(client, result.summary.sessionID, state: .exited, timeout: .seconds(10))
        await client.stop()
        await harness.stop()
    }

    /// Custo: uma chamada `claude -p --model haiku "reply OK"` na worktree nova. Só com `AB_REAL_CLI=1`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AB_REAL_CLI"] == "1"))
    func newWorktreeThenClaudeHaikuReceivesThePromptAsArgument() async throws {
        let rig = try await makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let harness = try DaemonHarness()
        defer { harness.terminateNow() }
        try await harness.start()
        let client = harness.makeClient()
        try await client.start()

        var spec = LaunchSpec(provider: .claude, model: "haiku", extraArgs: ["-p"], initialPrompt: "reply OK")
        spec.profileID = BuiltinProfiles.claudeDefault.id
        let output = try await rig.service.create(SessionCreationRequest(
            title: "reply OK",
            target: .newWorktree(NewWorktreeSpec(projectID: rig.project.id, source: .newBranch(slug: "reply-ok", prefix: .custom("me"), baseRef: nil), worktreeRoot: rig.worktreeRoot)),
            spec: spec))
        let loginProvider = LoginShellEnvProvider()
        let c = coordinator(harness, client: client) { await loginProvider.environment().variables }
        let events = Events()
        let result = try await c.launch(LaunchJob(terminalID: output.terminal.id, spec: output.terminal.launchSpec, cwd: output.terminal.cwd), onEvent: events.add)
        #expect(result.plan.flattenedArgv.contains("-p"))
        #expect(result.plan.flattenedArgv.last == "reply OK", "o prompt é o último argumento do CLI, nunca digitado no PTY")
        #expect(result.plan.cwd == output.session.folderPath)
        let exited = try await waitFor(client, result.summary.sessionID, state: .exited, timeout: .seconds(120))
        #expect(exited.exit?.code == 0)
        let text = try await client.textSnapshot(sessionID: result.summary.sessionID, lines: 40)
        #expect(text.contains("OK"))
        #expect(exited.inputBytesByOrigin.total == 0)
        await client.stop()
        await harness.stop()
    }
}
