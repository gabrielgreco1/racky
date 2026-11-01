import RackyPlatform
import RackyProtocol
import RackyStore
import Foundation
import Testing

@testable import RackyCore

/// T2-02/T2-03: injeções por lançamento da Fatia 2 (06 §2.8). Os golden files da Fatia 1 continuam em `slice1/`.
private let helper = "/Applications/Racky.app/Contents/MacOS/racky"

private func hashes() throws -> [HookEventName: String] {
    CodexHookConfig.parseCurrentHashes(hooksList: try RealHooks.data("S-05/codex-hooks-list-sessionflags.json"))
}

private let pluginFiles = [
    LaunchFile(name: "plugin/.claude-plugin/plugin.json", contents: Data(#"{"name":"racky-run"}"#.utf8)),
    LaunchFile(name: "plugin/skills/x/SKILL.md", contents: Data("---\nname: x\n---\n".utf8)),
]

@Suite struct Slice2GoldenTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let spec: LaunchSpec
        var mode: LaunchMode = .automatic
        var injection: LaunchInjection
        var testDescription: String { name }
    }

    static var cases: [Case] {
        let hooksOnly = LaunchInjection(helperPath: helper)
        let full = LaunchInjection(
            helperPath: helper, claudeMCPConfig: Data(#"{"mcpServers":{"racky":{"command":"racky","args":["mcp"]}}}"#.utf8),
            claudePluginFiles: pluginFiles)
        let codex = LaunchInjection(helperPath: helper, codexHookHashes: (try? hashes()) ?? [:])
        return [
            Case(name: "claude/hooks-hello", spec: LaunchSpec(provider: .claude, initialPrompt: "hello"), injection: hooksOnly),
            Case(name: "claude/hooks-mcp-plugin-hello", spec: LaunchSpec(provider: .claude, initialPrompt: "hello"), injection: full),
            Case(name: "claude/hooks-mcp-plugin-resume-id", spec: LaunchSpec(provider: .claude, initialPrompt: "ignored", resumeOf: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"), injection: full),
            Case(name: "claude/hooks-no-prompt", spec: LaunchSpec(provider: .claude), injection: hooksOnly),
            Case(name: "codex/hooks-trusted-hello", spec: LaunchSpec(provider: .codex, initialPrompt: "hello"), injection: codex),
            Case(name: "codex/hooks-untrusted-hello", spec: LaunchSpec(provider: .codex, initialPrompt: "hello"), injection: hooksOnly),
            Case(name: "codex/hooks-trusted-resume-id", spec: LaunchSpec(provider: .codex, resumeOf: "01a147e5-72b7-7c52-a686-6e002673cc8b"), injection: codex),
        ]
    }

    @Test(arguments: cases)
    func argvMatchesGolden(_ c: Case) throws {
        let caps = LaunchSamples.helpCapabilities(c.spec.provider)
        let plan = try LaunchSamples.plan(c.spec, mode: c.mode, capabilities: caps, slice: .slice2, injection: c.injection)
        LaunchFixtures.assertGolden("slice2/\(c.name).golden", LaunchSamples.render(c.name, plan))
        #expect(!plan.argv.injected.isEmpty)
        #expect(InjectionValidator.violations(injected: plan.argv.injected, launchDirectory: LaunchSamples.launchDirectory, slice: .slice2).isEmpty)
        #expect(!plan.flattenedArgv.contains("--dangerously-bypass-hook-trust"))
    }

    @Test func slice1IgnoresInjectionAndStaysEmpty() throws {
        for provider in [TerminalProvider.claude, .codex] {
            let plan = try LaunchSamples.plan(LaunchSpec(provider: provider, initialPrompt: "hello"), slice: .slice1, injection: LaunchInjection(helperPath: helper))
            #expect(plan.argv.injected.isEmpty)
            #expect(plan.files.isEmpty)
        }
    }

    @Test func claudeSettingsPathIsInsideTheLaunchDirectoryAndEnvCarriesTheRun() throws {
        let plan = try LaunchSamples.plan(LaunchSpec(provider: .claude, initialPrompt: "hello"), slice: .slice2, injection: LaunchInjection(helperPath: helper))
        let dir = LaunchSamples.launchDirectory.standardizedFileURL.path
        #expect(plan.argv.injected == ["--settings", "\(dir)/settings.json"])
        #expect(plan.files.map(\.name) == ["settings.json"])
        #expect(plan.files.allSatisfy { $0.posixMode == 0o600 })
        #expect(plan.environment["RACKY_RUN_ID"] == LaunchSamples.runID.uuidString.lowercased())
        #expect(plan.environment["RACKY_PANE_ID"] == LaunchSamples.terminalID.uuidString.lowercased())
        #expect(plan.environment["RACKY_APP_SOCK"] == "/tmp/ab/run/app.sock")
    }

    @Test func emptyMCPAndPluginAreOmitted() throws {
        let plan = try LaunchSamples.plan(LaunchSpec(provider: .claude), slice: .slice2, injection: LaunchInjection(helperPath: helper, claudeMCPConfig: Data()))
        #expect(!plan.argv.injected.contains("--mcp-config") && !plan.argv.injected.contains("--plugin-dir"))
    }

    @Test func resumeRegeneratesIdenticalFlagsAndFiles() throws {
        let inj = LaunchInjection(helperPath: helper, claudeMCPConfig: Data("{}".utf8), claudePluginFiles: pluginFiles)
        let first = try LaunchSamples.plan(LaunchSpec(provider: .claude), slice: .slice2, injection: inj)
        let resumed = try LaunchSamples.plan(LaunchSpec(provider: .claude, resumeOf: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"), slice: .slice2, injection: inj)
        #expect(first.argv.injected == resumed.argv.injected)
        #expect(first.files == resumed.files)
        let codexA = try LaunchSamples.plan(LaunchSpec(provider: .codex, initialPrompt: "hello"), slice: .slice2, injection: LaunchInjection(helperPath: helper, codexHookHashes: try hashes()))
        let codexB = try LaunchSamples.plan(LaunchSpec(provider: .codex, resumeOf: "01a147e5-72b7-7c52-a686-6e002673cc8b"), slice: .slice2, injection: LaunchInjection(helperPath: helper, codexHookHashes: try hashes()))
        #expect(codexA.argv.injected == codexB.argv.injected)
    }

    @Test func codexTrustedInjectionHasHooksStateAndNoDaemon() throws {
        let plan = try LaunchSamples.plan(
            LaunchSpec(provider: .codex, initialPrompt: "hello"), capabilities: LaunchSamples.helpCapabilities(.codex), slice: .slice2,
            injection: LaunchInjection(helperPath: helper, codexHookHashes: try hashes()))
        #expect(plan.argv.profile.first == "--no-daemon")
        #expect(plan.argv.injected.contains { $0.hasPrefix("hooks.state={") })
        #expect(plan.files.isEmpty)
    }

    @Test func materializeWritesOwnerOnlyFilesInsideTheLaunchDirectoryOnly() throws {
        let root = URL(fileURLWithPath: "/tmp/abl-\(UInt32.random(in: 0 ... 0xFFFFFF))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("run/launch/\(LaunchSamples.runID.uuidString.lowercased())", isDirectory: true)
        var input = LaunchSamples.input(
            LaunchSpec(provider: .claude, initialPrompt: "hello"), slice: .slice2,
            injection: LaunchInjection(helperPath: helper, claudeMCPConfig: Data("{}".utf8), claudePluginFiles: pluginFiles))
        input.launchDirectory = dir
        let plan = try LaunchPlanner.plan(input)
        try LaunchFileWriter.materialize(plan)
        let fm = FileManager.default
        func mode(_ path: String) throws -> Int { (try fm.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue ?? -1 }
        #expect(try mode(dir.path) == 0o700)
        for name in ["settings.json", "mcp.json", "plugin/.claude-plugin/plugin.json", "plugin/skills/x/SKILL.md"] {
            #expect(try mode(dir.appendingPathComponent(name).path) == 0o600, "\(name)")
        }
        #expect(try mode(dir.appendingPathComponent("plugin").path) == 0o700)
        #expect(try fm.contentsOfDirectory(atPath: root.path) == ["run"])
        LaunchFileWriter.cleanup(launchDirectory: dir)
        #expect(!fm.fileExists(atPath: dir.path))
    }

    @Test func validatorRejectsSettingsOutsideTheLaunchDirectory() {
        #expect(!InjectionValidator.violations(injected: ["--settings", "/Users/x/.claude/settings.json"], launchDirectory: LaunchSamples.launchDirectory, slice: .slice2).isEmpty)
    }
}

// MARK: - Integração real (barata)

private func rackyBinary() -> URL {
    for bundle in Bundle.allBundles where bundle.bundleURL.pathExtension == "xctest" {
        return bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("racky")
    }
    return URL(fileURLWithPath: ".build/debug/racky")
}

private func which(_ name: String) -> String? {
    for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
        let path = "\(dir)/\(name)"
        if FileManager.default.isExecutableFile(atPath: path) { return path }
    }
    return nil
}

/// `claude -p --model haiku "reply OK"` com a injeção da Fatia 2: `SessionStart` e `Stop` chegam ao serviço `hook` de
/// um app de teste. Custa centavos; só roda com `AB_REAL_CLI=1`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["AB_REAL_CLI"] == "1")) struct Slice2RealClaudeTests {
    @Test func sessionStartAndStopReachTheTestServer() async throws {
        let claude = try #require(which("claude"), "claude not on PATH")
        let home = try ActivityHome(); defer { home.remove() }
        let store = try await home.openStore()
        let activity = ActivityService(store: store, spoolDirectory: home.spoolDirectory)
        let hub = AppSockHub(socketPath: home.socketPath, providers: [HookServiceProvider(activity: activity)])
        try await hub.start()

        let work = URL(fileURLWithPath: "/tmp/abw-\(UInt32.random(in: 0 ... 0xFFFFFF))", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let runID = UUID(), terminalID = UUID()
        let launchDir = home.root.appendingPathComponent("run/launch/\(runID.uuidString.lowercased())", isDirectory: true)
        let input = LaunchPlanInput(
            spec: LaunchSpec(provider: .claude, model: "haiku", permissionMode: "default", extraArgs: ["-p"], initialPrompt: "reply OK"),
            terminalID: terminalID, runID: runID, cwd: work.path, executablePath: claude,
            loginEnvironment: ProcessInfo.processInfo.environment, launchDirectory: launchDir, slice: .slice2,
            appSocketPath: home.socketPath, injection: LaunchInjection(helperPath: rackyBinary().path))
        let plan = try LaunchPlanner.plan(input)
        try LaunchFileWriter.materialize(plan)
        #expect(plan.argv.injected.first == "--settings")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = Array(plan.flattenedArgv.dropFirst())
        process.currentDirectoryURL = work
        process.environment = plan.environment
        let out = Pipe(); process.standardOutput = out; process.standardError = out
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let output = await offPool { () -> String in
            let data = out.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }
        #expect(process.terminationStatus == 0, "claude output: \(output)")

        var run: AgentRun?
        for _ in 0 ..< 50 {
            run = try await store.agentRun(id: runID)
            if run?.activity == .done { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let spooled = (try? FileManager.default.contentsOfDirectory(atPath: home.spoolDirectory.path)) ?? []
        #expect(run?.activity == .done, "Stop did not reach the server (spool: \(spooled)); claude output: \(output)")
        // `SessionStart` registra o session_id nativo, que é o `--session-id` atribuído pelo app.
        #expect(run?.providerSessionID == plan.nativeConversationID, "SessionStart missing; run: \(String(describing: run))")
        LaunchFileWriter.cleanup(launchDirectory: launchDir)
        await hub.stop()
        try await store.close()
    }
}

@Suite struct Slice2RealCodexTests {
    @Test(.disabled("Codex sem cota até 22/10/2026 (S-05: payloads PreToolUse/PostToolUse/Stop pendentes); só o argv é verificado por golden"))
    func hooksWithInlineTrustFireInARealRun() async throws {}
}
