@testable import RackyPlatform
import RackyProtocol
import Foundation
import Testing

@testable import RackyCore

/// Runner falso: responde com fixtures reais e registra cada pedido. Nunca executa um agente.
actor FakeCommandRunner: CommandRunning {
    struct Reply { var stdout: String = ""; var stderr: String = ""; var exit: Int32 = 0; var error: ProcessRunnerError? }
    private(set) var requests: [ProcessRequest] = []
    private var replies: [String: Reply]

    init(_ replies: [String: Reply]) { self.replies = replies }

    func setReply(_ key: String, _ reply: Reply) { replies[key] = reply }

    func run(_ request: ProcessRequest) async throws -> ProcessOutput {
        requests.append(request)
        let key = request.executable.lastPathComponent + " " + request.arguments.joined(separator: " ")
        guard let reply = replies[key] else { throw ProcessRunnerError.launchFailed("unexpected command: \(key)") }
        if let error = reply.error { throw error }
        return ProcessOutput(exitCode: reply.exit, stdout: Data(reply.stdout.utf8), stderr: Data(reply.stderr.utf8), truncated: false)
    }

    func commands() -> [String] { requests.map { $0.executable.lastPathComponent + " " + $0.arguments.joined(separator: " ") } }
}

@Suite struct CLIProberTests {
    /// Diretório com executáveis falsos (só precisam existir e ter bit de execução).
    private func makeBin(_ names: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ab-bin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in names {
            let url = dir.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 99\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return dir
    }

    private func replies(login: Bool = true) -> [String: FakeCommandRunner.Reply] {
        [
            "claude --version": .init(stdout: LaunchFixtures.text("claude-2.1.302.version.txt")),
            "claude --help": .init(stdout: LaunchFixtures.text("claude-2.1.302.help.txt")),
            "claude auth status --json": .init(stdout: LaunchFixtures.text(login ? "claude-auth-status.loggedin.json" : "claude-auth-status.loggedout.json"), exit: login ? 0 : 1),
            "codex --version": .init(stdout: LaunchFixtures.text("codex-0.163.0.version.txt")),
            "codex --help": .init(stdout: LaunchFixtures.text("codex-0.163.0.help.txt")),
            "codex login status": .init(stderr: LaunchFixtures.text(login ? "codex-login-status.loggedin.txt" : "codex-login-status.loggedout.txt"), exit: login ? 0 : 1),
            "opencode --version": .init(stdout: LaunchFixtures.text("opencode-1.18.34.version.txt")),
            "opencode --help": .init(stdout: LaunchFixtures.text("opencode-1.18.34.help.txt")),
            "opencode providers list": .init(stdout: LaunchFixtures.text(login ? "opencode-providers-list.loggedin.txt" : "opencode-providers-list.loggedout.txt")),
        ]
    }

    @Test func detectsInstalledVersionsFlagsAndLogin() async throws {
        let bin = try makeBin(["claude", "codex", "opencode"])
        defer { try? FileManager.default.removeItem(at: bin) }
        let runner = FakeCommandRunner(replies())
        let prober = CLIProber(runner: runner, environment: { ["PATH": bin.path] })

        let claude = await prober.probe(ClaudeAdapter())
        #expect(claude.isInstalled)
        #expect(claude.executable == bin.appendingPathComponent("claude").path)
        #expect(claude.version == CLIVersion(2, 1, 302))
        #expect(claude.capabilities?.source == .help)
        #expect(claude.capabilities?.supports("--effort") == true)
        #expect(claude.login == .loggedIn)

        let codex = await prober.probe(CodexAdapter())
        #expect(codex.version == CLIVersion(0, 163, 0))
        #expect(codex.capabilities?.supports("--no-daemon") == true)
        #expect(codex.capabilities?.supports(subcommand: "resume") == true)
        #expect(codex.login == .loggedIn)

        let oc = await prober.probe(OpenCodeAdapter())
        #expect(oc.version == CLIVersion(1, 18, 34))
        #expect(oc.capabilities?.supports("--prompt") == true)
        #expect(oc.login == .loggedIn)
        #expect(claude.issues.isEmpty && codex.issues.isEmpty && oc.issues.isEmpty)
    }

    @Test func loggedOutIsDetectedWithoutRunningLogin() async throws {
        let bin = try makeBin(["claude", "codex", "opencode"])
        defer { try? FileManager.default.removeItem(at: bin) }
        let runner = FakeCommandRunner(replies(login: false))
        let prober = CLIProber(runner: runner, environment: { ["PATH": bin.path] })
        #expect(await prober.probe(ClaudeAdapter()).login == .loggedOut)
        #expect(await prober.probe(CodexAdapter()).login == .loggedOut)
        #expect(await prober.probe(OpenCodeAdapter()).login == .loggedOut)

        // AC-104: o probe é somente leitura. Nenhum comando é `login`/`logout`/`providers login`.
        for command in await runner.commands() {
            let words = command.split(separator: " ").map(String.init)
            #expect(words.last != "login" && !words.contains("logout"), "probe must never run login: \(command)")
        }
        let allowed: Set<String> = [
            "claude --version", "claude --help", "claude auth status --json", "codex --version", "codex --help",
            "codex login status", "opencode --version", "opencode --help", "opencode providers list",
        ]
        #expect(Set(await runner.commands()).isSubset(of: allowed))
    }

    @Test func missingCLIIsReportedNotInstalled() async throws {
        let bin = try makeBin([])
        defer { try? FileManager.default.removeItem(at: bin) }
        let runner = FakeCommandRunner([:])
        let prober = CLIProber(runner: runner, environment: { ["PATH": bin.path, "HOME": "/nonexistent-home"] })
        // Nenhum dos diretórios conhecidos (`~/.local/bin`, /opt/homebrew/bin…) pode ter um `racky-nope`; usa um nome inexistente.
        let ghost = GhostAdapter()
        let result = await prober.probe(ghost)
        #expect(!result.isInstalled)
        #expect(result.executable == nil && result.version == nil && result.capabilities == nil)
        if case .unknown(let reason) = result.login { #expect(reason.contains("not installed")) } else { Issue.record("expected unknown login") }
        #expect(result.issues == ["racky-nope-cli not found in PATH"])
        #expect(await runner.commands().isEmpty) // nada é executado
    }

    @Test func cachesByPathAndModificationTimeAndForceRefreshes() async throws {
        let bin = try makeBin(["claude"])
        defer { try? FileManager.default.removeItem(at: bin) }
        let runner = FakeCommandRunner(replies())
        let stamp = StampBox(Date(timeIntervalSince1970: 1_000))
        let prober = CLIProber(runner: runner, environment: { ["PATH": bin.path] }, stamp: { _ in stamp.value })

        _ = await prober.probe(ClaudeAdapter(), checkLogin: false)
        _ = await prober.probe(ClaudeAdapter(), checkLogin: false)
        #expect(await prober.probeRuns == 1)

        stamp.value = Date(timeIntervalSince1970: 2_000) // binário trocado (mtime)
        _ = await prober.probe(ClaudeAdapter(), checkLogin: false)
        #expect(await prober.probeRuns == 2)

        _ = await prober.probe(ClaudeAdapter(), checkLogin: false, force: true) // "Check Again"
        #expect(await prober.probeRuns == 3)
        let versionRuns = await runner.commands().filter { $0 == "claude --version" }.count
        #expect(versionRuns == 3)
    }

    @Test func probeTimeoutsAndGarbageFallBackToTable() async throws {
        let bin = try makeBin(["codex"])
        defer { try? FileManager.default.removeItem(at: bin) }
        let runner = FakeCommandRunner([
            "codex --version": .init(error: .timedOut),
            "codex --help": .init(stdout: "error: weird banner\n"),
            "codex login status": .init(stdout: "something unexpected", exit: 3),
        ])
        let prober = CLIProber(runner: runner, environment: { ["PATH": bin.path] })
        let result = await prober.probe(CodexAdapter())
        #expect(result.isInstalled)
        #expect(result.version == nil)
        #expect(result.capabilities?.flags.isEmpty == true) // sem versão nem help: nada habilitado por engano
        #expect(result.issues.contains { $0.contains("`--version` failed: timed out") })
        #expect(result.issues.contains { $0.contains("`--help` output was not recognised") })
        if case .unknown = result.login {} else { Issue.record("login must be unknown on unexpected output") }
    }

    @Test func overrideWinsAndMustExist() async throws {
        let bin = try makeBin(["claude-custom"])
        defer { try? FileManager.default.removeItem(at: bin) }
        let custom = bin.appendingPathComponent("claude-custom").path
        let runner = FakeCommandRunner([
            "claude-custom --version": .init(stdout: "2.1.302 (Claude Code)"),
            "claude-custom --help": .init(stdout: LaunchFixtures.text("claude-2.1.302.help.txt")),
        ])
        let prober = CLIProber(runner: runner, environment: { ["PATH": "/nonexistent"] }, overrides: [.claude: custom])
        #expect(await prober.probe(ClaudeAdapter(), checkLogin: false).executable == custom)
        let broken = CLIProber(runner: runner, environment: { ["PATH": "/nonexistent"] }, overrides: [.claude: "/nope/claude"])
        #expect(await broken.probe(ClaudeAdapter(), checkLogin: false).isInstalled == false)
    }

    @Test func probesUseLoginEnvironmentAndNeutralDirectory() async throws {
        let bin = try makeBin(["claude"])
        defer { try? FileManager.default.removeItem(at: bin) }
        let runner = FakeCommandRunner(replies())
        let prober = CLIProber(runner: runner, environment: { ["PATH": bin.path, "MARKER": "login-env"] })
        _ = await prober.probe(ClaudeAdapter(), checkLogin: false)
        let requests = await runner.requests
        #expect(requests.allSatisfy { $0.environment["MARKER"] == "login-env" })
        #expect(requests.allSatisfy { $0.timeout == .seconds(5) })
    }

    @Test func loginInterpretersHandleRealOutputs() {
        func out(_ text: String, exit: Int32 = 0) -> ProcessOutput { ProcessOutput(exitCode: exit, stdout: Data(text.utf8), stderr: Data(), truncated: false) }
        let claude = ClaudeAdapter(), codex = CodexAdapter(), oc = OpenCodeAdapter()
        #expect(claude.interpretLoginStatus(out(LaunchFixtures.text("claude-auth-status.loggedin.json"))) == .loggedIn)
        #expect(claude.interpretLoginStatus(out(LaunchFixtures.text("claude-auth-status.loggedout.json"), exit: 1)) == .loggedOut)
        #expect(codex.interpretLoginStatus(out(LaunchFixtures.text("codex-login-status.loggedin.txt"))) == .loggedIn)
        #expect(codex.interpretLoginStatus(out(LaunchFixtures.text("codex-login-status.loggedout.txt"), exit: 1)) == .loggedOut)
        #expect(oc.interpretLoginStatus(out(LaunchFixtures.text("opencode-providers-list.loggedin.txt"))) == .loggedIn)
        #expect(oc.interpretLoginStatus(out(LaunchFixtures.text("opencode-providers-list.loggedout.txt"))) == .loggedOut)
        if case .unknown = claude.interpretLoginStatus(out("<html>")) {} else { Issue.record("claude garbage must be unknown") }
    }

    @Test func resolverPrefersSearchPathThenKnownDirectories() throws {
        let bin = try makeBin(["tool-a"])
        defer { try? FileManager.default.removeItem(at: bin) }
        #expect(CLIExecutableResolver.resolve(name: "tool-a", searchPath: "/nonexistent:\(bin.path)") == bin.appendingPathComponent("tool-a").path)
        #expect(CLIExecutableResolver.resolve(name: "tool-a", searchPath: nil, home: "/nonexistent") == nil)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ab-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let local = home.appendingPathComponent(".opencode/bin")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let exe = local.appendingPathComponent("opencode")
        try Data("#!/bin/sh\n".utf8).write(to: exe)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        // PATH sem entradas (rc não rodou): o diretório conhecido `~/.opencode/bin` salva.
        #expect(CLIExecutableResolver.resolve(name: "opencode", searchPath: "/usr/bin", home: home.path) == exe.path)
    }
}

final class StampBox: @unchecked Sendable { // SAFETY: usado em sequência por um único teste; sem acesso concorrente.
    var value: Date?
    init(_ value: Date?) { self.value = value }
}

struct GhostAdapter: ProviderAdapter {
    let provider = TerminalProvider.claude
    let displayName = "Ghost"
    let executableName: String? = "racky-nope-cli"
    let flagRules: [FlagRule] = []
    func build(_ launch: EffectiveLaunch, context: AdapterContext, capabilities: CLICapabilities) throws -> AdapterOutput {
        throw LaunchPlanError.missingCustomArgv
    }
}
