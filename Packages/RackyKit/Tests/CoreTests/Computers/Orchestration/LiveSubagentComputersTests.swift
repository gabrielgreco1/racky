import RackyDocker
import RackyPlatform
import RackyProtocol
import RackyStore
import Foundation
import Testing

@testable import RackyCore

// F12 com o Docker real (`RACKY_TEST_DOCKER=1`) e o Claude Code real (`RACKY_TEST_CLAUDE=1`, haiku, teto de US$ 0,20 por execução).
// O orquestrador do app (`ComputerOrchestrator`, `AppComputerProvisioning`, porta Ask/Full, hook de spawn) sobre um `app.sock` real, o
// `racky mcp` e o `racky hook-guard` REAIS como processos, e uma página de teste servida por um container numa bridge de teste.
// Só toca recursos `racky.test=1` + `racky.test_run=<id>` e remove tudo ao final.

@Suite("F12 - Subagent computers reais", .serialized, .enabled(if: LiveC.enabled && LiveOrchestrationTests.claudeEnabled))
struct LiveSubagentComputersTests {
    static let evidenceFile = "fixes/subagent-computers/live-subagent-computers.json"
    /// O pedido do dono, com a URL do site de teste (servido por um container na bridge de teste).
    static let ownerPrompt = "spawna um sub agent pra estudar o site http://origin:8080/ e me diz o título da página"
    static let forcedPlainPrompt = """
        Use the Agent tool with subagent_type "general-purpose" to study the website http://origin:8080/ and report its page title. \
        Do not use any other way. If a hook or tool tells you to do something else first, follow it.
        """

    @Test func fullAccessOwnerPromptReservesAComputerAndTheWorkerBrowses() async throws {
        try await run(label: "full", mode: .full, prompt: Self.ownerPrompt)
    }

    @Test func askModeWithAutomaticAllowCreatesTheComputerAfterTheDecision() async throws {
        try await run(label: "ask", mode: .ask, prompt: Self.ownerPrompt, autoAllow: true)
    }

    @Test func theSpawnGuardBlocksAPlainWebSubagentAndClaudeFollowsTheInstruction() async throws {
        try await run(label: "guard", mode: .full, prompt: Self.forcedPlainPrompt, expectGuardBlock: true)
    }

    func run(label: String, mode: SubagentComputersMode, prompt: String, autoAllow: Bool = false, expectGuardBlock: Bool = false) async throws {
        let runID = LiveComputerTests.shortID()
        let detected = try await RuntimeDetector().detect()
        let client = DockerClient(runtime: detected.runtime, defaultTimeout: .seconds(60))
        let testLabels = [RackyLabel.test: "1", "racky.test_run": runID]
        let labelFilter = ["\(RackyLabel.test)=1", "racky.test_run=\(runID)"]
        let home = URL(fileURLWithPath: "/tmp/abx-sub-\(label)-\(runID)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let evidence = LiveEvidenceC()

        func cleanup() async {
            let gc = GarbageCollector(client: client)
            if let items = try? await gc.inventory(labels: labelFilter) { _ = await gc.remove(items) }
            if let images = try? await client.listImages(filters: ["label": labelFilter]) { for image in images { try? await client.removeImage(image.id, force: true) } }
            try? FileManager.default.removeItem(at: home)
        }
        do {
            try await scenario(
                label: label, mode: mode, prompt: prompt, autoAllow: autoAllow, expectGuardBlock: expectGuardBlock, runID: runID, client: client,
                testLabels: testLabels, home: home, evidence: evidence)
        } catch {
            await cleanup()
            await evidence.flush(to: "fixes/subagent-computers/live-\(label).json")
            throw error
        }
        await cleanup()
        let leftovers = (try? await GarbageCollector(client: client).inventory(labels: labelFilter)) ?? []
        let images = (try? await client.listImages(filters: ["label": labelFilter])) ?? []
        #expect(leftovers.isEmpty && images.isEmpty, "cleanup left \(leftovers.count) resources and \(images.count) images")
        await evidence.record("cleanup", ["leftover_resources": .int(leftovers.count), "leftover_images": .int(images.count)])
        await evidence.flush(to: "fixes/subagent-computers/live-\(label).json")
    }

    func scenario(
        label: String, mode: SubagentComputersMode, prompt: String, autoAllow: Bool, expectGuardBlock: Bool, runID: String, client: DockerClient,
        testLabels: [String: String], home: URL, evidence: LiveEvidenceC
    ) async throws {
        // ---- origem de teste numa bridge de teste (a imagem do egress já serve para o Python)
        let runtimeRoot = LiveC.repoRoot.appendingPathComponent("runtime", isDirectory: true)
        let egressImage = try await ImageManager(client: client).ensure(ImageSource(
            repository: "racky-computer-origin-\(runID)", contextDirectory: runtimeRoot.appendingPathComponent("computer"), extraLabels: testLabels))
        let bridge = "abx-t-\(runID)-bridge"
        let bridgeID = try await client.createNetwork(name: bridge, isInternal: false, labels: testLabels)
        let subnet = try #require(try await client.inspectNetwork(bridgeID).subnets.first)
        var origin = ContainerSpec(name: "abx-t-\(runID)-origin", image: egressImage.tag)
        origin.entrypoint = ["python"]
        origin.command = ["-c", liveOriginScript]
        origin.labels = testLabels.merging([RackyLabel.owner: "test-\(runID)", RackyLabel.computer: "c-origin-\(runID)", RackyLabel.ephemeral: "true"]) { $1 }
        origin.user = "65534"
        origin.tmpfs = ["/tmp": "rw,nosuid,size=16m"]
        origin.resources = ContainerResources(memoryBytes: 128 << 20, cpus: 0.5, pidsLimit: 128)
        origin.network = ContainerNetworkAttachment(network: bridge, aliases: ["origin"])
        try await client.startContainer(try await client.createContainer(origin))

        // ---- o orquestrador do app, com o preparo de imagens do app (primeira vez: constrói)
        let store = try await RackyStore.open(paths: StorePaths(root: home.appendingPathComponent("store", isDirectory: true)))
        var config = AppComputerProvisioning.Config(runtimeRoot: runtimeRoot, secretsRoot: home, owner: "test-\(runID)")
        config.isTest = true
        config.repositorySuffix = "-test-\(runID)"
        config.extraLabels = testLabels
        config.network = bridge
        config.allowCIDRs = [subnet]
        let provisioning = AppComputerProvisioning(config: config)
        let orchestrator = ComputerOrchestrator(
            helperPath: McpHelperProcessTests.binary().path, store: store, provisioning: provisioning,
            runsRoot: home.appendingPathComponent("runs", isDirectory: true), waitSeconds: 20, fixedEstimates: true)
        await orchestrator.start()
        let setupStates = Rec<String>()
        await provisioning.setObserver(state: { state in if let label = state.label { setupStates.add(label) } }, problem: nil)
        let socketHome = try McpSocketTests.Home()
        defer { try? FileManager.default.removeItem(at: socketHome.root) }
        let appSock = AppSockHub(socketPath: socketHome.socket, providers: [orchestrator.mcpProvider])
        try await appSock.start()
        defer { Task { await appSock.stop() } }

        // ---- decisão automática do Ask (o que `ctl ui action computer.allowRequest` faz no app)
        let decided = Rec<String>()
        let allower = Task {
            while !Task.isCancelled {
                for request in await orchestrator.approvals.open {
                    decided.add(request.summary)
                    _ = await orchestrator.approvals.decide(id: request.id, .allow)
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        defer { allower.cancel() }
        if !autoAllow { allower.cancel() }

        // ---- o lançamento: o mesmo caminho do app (injeção por modo)
        let parentID = UUID().uuidString.lowercased()
        var options = OrchestrationInjectionBuilder.Options()
        options.workerSlots = 4
        let bundle = try await orchestrator.prepareParent(
            ParentInfo(parentID: parentID, sessionID: UUID(), sessionTitle: "houston-listings", mode: mode), options: options)
        let helperPath = McpHelperProcessTests.binary().path
        let claudePath = try #require(CLIExecutableResolver.resolve(name: "claude", searchPath: ProcessInfo.processInfo.environment["PATH"], override: nil))
        let launchDirectory = home.appendingPathComponent("launch/\(parentID)", isDirectory: true)
        var input = LaunchPlanInput(
            spec: LaunchSpec(provider: .claude, initialPrompt: prompt), terminalID: UUID(), runID: UUID(uuidString: parentID)!, cwd: home.path,
            executablePath: claudePath, capabilities: nil, loginEnvironment: ProcessInfo.processInfo.environment, launchDirectory: launchDirectory,
            slice: .slice2, appVersion: "0.0.0", appSocketPath: socketHome.socket, injection: bundle.apply(to: LaunchInjection(helperPath: helperPath)))
        input.capabilities = LaunchSamples.helpCapabilities(.claude)
        let plan = try LaunchPlanner.plan(input)
        try LaunchFileWriter.materialize(plan)
        let settingsText = (try? String(contentsOf: launchDirectory.appendingPathComponent("settings.json"), encoding: .utf8)) ?? ""
        #expect(settingsText.contains("hook-guard") && settingsText.contains("Agent|Task"), "the spawn guard is in the launch hooks file")
        var argv = ["-p", "--model", "haiku", "--dangerously-skip-permissions", "--output-format", "stream-json", "--verbose", "--max-budget-usd", "0.20"]
        argv += plan.argv.injected
        argv += ["--", prompt]
        var env = plan.environment
        env["RACKY_MCP_NO_LAUNCH"] = "1"
        env["RACKY_APP_SOCK"] = socketHome.socket
        let result = await LiveOrchestrationTests().runProcess(claudePath, argv, environment: env, cwd: home, timeout: 480)
        let lines = result.stdout.split(separator: "\n").compactMap { try? JSON.parse(String($0)) }
        var summary = ClaudeRunSummary()
        for line in lines { summary.absorb(line) }
        let guardBlocked = result.stdout.contains("Subagent computers is on for this session")
        try? result.stdout.write(to: home.appendingPathComponent("claude-stream.jsonl"), atomically: true, encoding: .utf8)

        // ---- o que o reqlog do computador viu
        let reqlogHits = Self.reqlogHits(in: home.appendingPathComponent("runs"), host: "origin")
        var json = summary.json(exit: result.status)
        if case .object(var object) = json {
            object["mode"] = .string(mode.rawValue)
            object["guard_blocked_a_plain_subagent"] = .bool(guardBlocked)
            object["approval_cards_decided"] = .array(decided.items.map { .string($0) })
            object["reqlog_requests_to_origin"] = .int(reqlogHits)
            object["image_setup_labels"] = .array(setupStates.items.prefix(6).map { .string($0) })
            json = .object(object)
        }
        await evidence.record("claude_run", json)
        let scratch = LiveC.evidenceRoot?.appendingPathComponent("fixes/subagent-computers/claude-\(label)-summary.json")
        if let scratch {
            try? FileManager.default.createDirectory(at: scratch.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? json.data(pretty: true).write(to: scratch)
        }

        #expect(summary.toolUses.contains("mcp__racky__boxes_reserve"), "boxes_reserve was called: \(summary.toolUses)")
        #expect(summary.agentSubagentTypes.contains { $0.hasPrefix("racky-worker-") }, "the subagent is an app worker: \(summary.agentSubagentTypes)")
        #expect(summary.workerToolUses.contains { $0.hasSuffix("__box_claim") } && summary.workerToolUses.contains { $0.hasSuffix("__browser_open") }, "the worker claimed and browsed: \(summary.workerToolUses)")
        #expect(reqlogHits > 0, "the computer's request log shows the worker reaching the page")
        #expect(summary.finalText.contains("Origin Page"), "the final answer carries the page title: \(summary.finalText)")
        #expect(summary.costUSD < 0.20)
        if autoAllow { #expect(!decided.items.isEmpty, "a Claude-wants-a-computer card was shown and allowed") }
        if expectGuardBlock { #expect(guardBlocked, "the guard blocked the plain subagent and told Claude to reserve a computer") }
        try await store.close()
    }

    /// Linhas dos reqlogs do run que citam o host da página (o worker navegou pelo egress).
    static func reqlogHits(in runs: URL, host: String) -> Int {
        guard let walker = FileManager.default.enumerator(at: runs, includingPropertiesForKeys: nil) else { return 0 }
        var hits = 0
        for case let url as URL in walker where url.lastPathComponent == "requests.jsonl" {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            hits += text.split(separator: "\n").filter { $0.contains(host) && !$0.contains("\"blocked\"") && !$0.contains("not-in-allowlist") }.count
        }
        return hits
    }
}
