import RackyDocker
import RackyPlatform
import RackyProtocol
import RackyStore
import Foundation
import Synchronization
import Testing

@testable import RackyCore

// F12 ("Subagent computers"): injeção por modo (golden de argv com mcp/plugin/agents), o fluxo Ask (Allow, Allow for this session, Deny,
// `pending` sem bloquear) e o Full direto. Provisionador falso: o Docker real fica em `LiveSubagentComputersTests`.

private let helper = "/Applications/Racky.app/Contents/MacOS/racky"

/// Pacote de injeção determinístico (capabilities fixas, 2 slots) para o golden.
private func fixedBundle(parent: String = "parent-aaaaaaaa") throws -> OrchestrationBundle {
    var options = OrchestrationInjectionBuilder.Options()
    options.workerSlots = 2
    return try OrchestrationInjectionBuilder.make(parentID: parent, helperPath: helper, options: options, parentCapability: "cap-parent", workerCapability: { "cap-w\($0)" })
}

// MARK: Injeção por modo

@Suite("F12 injeção por modo") struct SubagentInjectionTests {
    private func coordinator(
        gateway: FakeGateway, prepared: Rec<ParentInfo>, ended: Rec<String>, bundleFails: Bool = false
    ) -> LaunchCoordinator {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sub-\(UUID().uuidString)", isDirectory: true)
        return LaunchCoordinator(
            daemon: gateway,
            configuration: .init(
                launchRoot: root, appSocketPath: "/tmp/app.sock",
                loginEnvironment: { ["PATH": "/usr/bin:/bin", "HOME": "/Users/example", "SHELL": "/bin/zsh"] },
                resolveExecutable: { name, _ in ["claude": "/usr/local/bin/claude", "codex": "/usr/local/bin/codex", "zsh": "/bin/zsh"][name] },
                capabilities: { provider, _ in LaunchSamples.helpCapabilities(provider) }, slice: .slice2,
                injection: { provider in provider == .claude ? LaunchInjection(helperPath: helper) : nil },
                prepareOrchestration: { info in
                    prepared.add(info)
                    return bundleFails ? nil : try? fixedBundle(parent: info.parentID)
                },
                endOrchestration: { parent in ended.add(parent) }))
    }

    private func job(_ provider: TerminalProvider = .claude, mode: SubagentComputersMode?, launchMode: LaunchMode = .automatic, spec: LaunchSpec? = nil) -> LaunchJob {
        LaunchJob(
            terminalID: UUID(), spec: spec ?? LaunchSpec(provider: provider, initialPrompt: "spawn a sub agent to study the site"), cwd: "/tmp", mode: launchMode,
            subagent: mode.map { SubagentLaunch(sessionID: UUID(), sessionTitle: "houston-listings", mode: $0) })
    }

    @Test func offInjectsNoComputersAtAll() async throws {
        let gateway = FakeGateway()
        let prepared = Rec<ParentInfo>(), ended = Rec<String>()
        let c = coordinator(gateway: gateway, prepared: prepared, ended: ended)
        _ = try await c.launch(job(mode: .off), onEvent: { _ in })
        let argv = gateway.requests[0].argv
        for flag in ["--mcp-config", "--agents", "--plugin-dir"] { #expect(!argv.contains(flag), "off must not pass \(flag)") }
        #expect(argv.contains("--settings"), "activity hooks stay")
        #expect(prepared.items.isEmpty)
        // Sem sessão com o atributo (terminal avulso) também não.
        _ = try await c.launch(job(mode: nil), onEvent: { _ in })
        #expect(!gateway.requests[1].argv.contains("--mcp-config") && prepared.items.isEmpty)
    }

    @Test(arguments: [SubagentComputersMode.ask, .full])
    func askAndFullInjectMcpPluginAgentsAndDeny(_ mode: SubagentComputersMode) async throws {
        let gateway = FakeGateway()
        let prepared = Rec<ParentInfo>(), ended = Rec<String>()
        let c = coordinator(gateway: gateway, prepared: prepared, ended: ended)
        let result = try await c.launch(job(mode: mode), onEvent: { _ in })
        let argv = gateway.requests[0].argv
        for flag in ["--mcp-config", "--agents", "--plugin-dir", "--settings"] { #expect(argv.contains(flag), "\(mode) must pass \(flag)") }
        let info = try #require(prepared.items.first)
        #expect(info.mode == mode && info.sessionTitle == "houston-listings" && info.parentID == result.runID.uuidString.lowercased(), "the parent is the launch run")
        // `--agents`: um worker por slot, mcpServers em ARRAY (S-08), servidor próprio por filho.
        let agentsJSON = try #require(argv.firstIndex(of: "--agents").map { argv[$0 + 1] })
        let agents = try #require(try JSONSerialization.jsonObject(with: Data(agentsJSON.utf8)) as? [String: Any])
        #expect(Set(agents.keys) == ["racky-worker-1", "racky-worker-2"])
        let servers = try #require((agents["racky-worker-1"] as? [String: Any])?["mcpServers"] as? [[String: Any]])
        #expect(servers.count == 1 && servers[0].keys.first?.hasPrefix("abx-") == true)
        // `--mcp-config`: o servidor do app como pai (`racky mcp --child <pai>`).
        let mcpPath = try #require(argv.firstIndex(of: "--mcp-config").map { argv[$0 + 1] })
        let mcp = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: mcpPath))) as? [String: Any])
        let server = try #require((mcp["mcpServers"] as? [String: Any])?["racky"] as? [String: Any])
        #expect(server["command"] as? String == helper && (server["args"] as? [String])?.first == "mcp")
        // Plugin com a skill e deny da skill global.
        let pluginPath = try #require(argv.firstIndex(of: "--plugin-dir").map { argv[$0 + 1] })
        let skill = try String(contentsOfFile: pluginPath + "/skills/racky-boxes/SKILL.md", encoding: .utf8)
        #expect(skill.contains("boxes_reserve") && skill.contains("study"))
        let settingsPath = try #require(argv.firstIndex(of: "--settings").map { argv[$0 + 1] })
        let settings = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: settingsPath))) as? [String: Any])
        #expect(((settings["permissions"] as? [String: Any])?["deny"] as? [String]) == ["Skill(racky)"])
        #expect(gateway.requests[0].env["CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS"] == "2")
        #expect(gateway.requests[0].env["CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"] == nil)
        // O pai some com o lançamento.
        await c.finish(runID: result.runID)
        try await Task.sleep(for: .milliseconds(50))
        #expect(ended.items == [info.parentID])
    }

    @Test func resumeRegeneratesTheInjectionAndShellsNeverGetIt() async throws {
        let gateway = FakeGateway()
        let prepared = Rec<ParentInfo>(), ended = Rec<String>()
        let c = coordinator(gateway: gateway, prepared: prepared, ended: ended)
        let resume = LaunchSpec(provider: .claude, resumeOf: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        _ = try await c.launch(job(mode: .ask, launchMode: .resume(nativeID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"), spec: resume), onEvent: { _ in })
        let argv = gateway.requests[0].argv
        #expect(argv.contains("--resume") && argv.contains("--agents") && argv.contains("--mcp-config"), "Restart to apply: resume carries the new flags")
        _ = try await c.launch(job(.codex, mode: .full), onEvent: { _ in })
        _ = try await c.launch(job(.shell, mode: .full, spec: LaunchSpec(provider: .shell)), onEvent: { _ in })
        #expect(prepared.items.map(\.provider) == [.claude, .codex], "the three agents get the orchestration, a shell never does")
    }

    @Test func aFailingOrchestratorLeavesTheLaunchWorkingWithoutComputers() async throws {
        let gateway = FakeGateway()
        let prepared = Rec<ParentInfo>(), ended = Rec<String>()
        let c = coordinator(gateway: gateway, prepared: prepared, ended: ended, bundleFails: true)
        _ = try await c.launch(job(mode: .full), onEvent: { _ in })
        #expect(!gateway.requests[0].argv.contains("--agents"))
    }

    @Test func goldenArgvOffAndOn() throws {
        let spec = LaunchSpec(provider: .claude, initialPrompt: "spawn a sub agent to study the listings site of Houston")
        let caps = LaunchSamples.helpCapabilities(.claude)
        let off = try LaunchSamples.plan(spec, capabilities: caps, slice: .slice2, injection: LaunchInjection(helperPath: helper))
        LaunchFixtures.assertGolden("slice3/claude/subagent-computers-off.golden", LaunchSamples.render("claude/subagent-computers-off", off))
        let bundle = try fixedBundle()
        let on = try LaunchSamples.plan(spec, capabilities: caps, slice: .slice2, injection: bundle.apply(to: LaunchInjection(helperPath: helper)))
        LaunchFixtures.assertGolden("slice3/claude/subagent-computers-ask-full.golden", LaunchSamples.render("claude/subagent-computers-ask-full", on))
        #expect(on.argv.injected.contains("--agents") && on.argv.injected.contains("--mcp-config") && on.argv.injected.contains("--plugin-dir"))
        #expect(InjectionValidator.violations(injected: on.argv.injected, launchDirectory: LaunchSamples.launchDirectory, slice: .slice2).isEmpty)
    }
}

// MARK: Texto para o modelo

@Suite("F12 skill e instruções") struct SubagentSkillTextTests {
    @Test func skillAndInstructionsSayWhenToReserveAComputerAndWhenNot() {
        let description = OrchestrationText.skillDescription
        for keyword in ["STUDY", "BROWSE", "SCRAPE", "PORTAL", "ENDPOINT", "VALIDATE DATA SOURCES", "boxes_reserve", "normal"] {
            #expect(description.localizedCaseInsensitiveContains(keyword), "description mentions \(keyword)")
        }
        let skill = OrchestrationText.skill
        #expect(skill.contains("Whenever a subagent is going to study, navigate or scrape"))
        #expect(skill.contains("stays a normal subagent"))
        #expect(skill.contains("\"status\":\"pending\""))
        let instructions = ToolCatalog.parentInstructions
        #expect(instructions.contains("STUDY, BROWSE OR SCRAPE") && instructions.contains("Any other subagent task stays a normal subagent"))
        #expect(instructions.contains("pending"))
    }
}

@Suite("F12 allow_hosts") struct AllowHostsNormalizationTests {
    @Test func schemePortAndPathAreStrippedBecauseTheEgressComparesHostnames() {
        #expect(ComputerToolService.normalizedHost("http://origin:8080/") == "origin")
        #expect(ComputerToolService.normalizedHost("origin:8080") == "origin")
        #expect(ComputerToolService.normalizedHost("HTTPS://Aca-Prod.Accela.com/search?q=1") == "aca-prod.accela.com")
        #expect(ComputerToolService.normalizedHost("*.accela.com") == "*.accela.com")
        #expect(ComputerToolService.normalizedHost("  ") == nil)
        #expect(ToolCatalog.parentTools.first { $0.name == "boxes_reserve" }.map { String(describing: $0.spec).contains("ONLY these hostnames") } == true)
    }
}

// MARK: Fluxo Ask / Full

private struct AskRig {
    let hub: ComputerHub
    let scheduler: ComputerScheduler
    let provisioning: FakeProvisioning
    let approvals: ComputerApprovalCenter
    let parents: ParentDirectory
    let service: ComputerToolService
    let root: URL
    let parent = "parent-aaaaaaaa"

    static func make(mode: SubagentComputersMode?, wait: TimeInterval = 0.4, spawnWait: TimeInterval = 10, sessionID: UUID? = UUID(), provider: TerminalProvider = .claude) async throws -> AskRig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("abx-ask-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let hub = ComputerHub()
        let provisioning = FakeProvisioning()
        let scheduler = ComputerScheduler(
            hub: hub, provisioning: provisioning, capacity: { SchedulerRig.twentyEightGB },
            runDirectory: { p, n in root.appendingPathComponent("\(p)/\(n)", isDirectory: true) }, fixedEstimates: true)
        await scheduler.attach()
        let approvals = ComputerApprovalCenter()
        let parents = ParentDirectory()
        let service = ComputerToolService(hub: hub, orchestrator: scheduler, gate: SubagentComputersGate(parents: parents, approvals: approvals, waitSeconds: wait, spawnWaitSeconds: spawnWait))
        let bundle = try fixedBundle()
        await OrchestrationInjectionBuilder.register(bundle, hub: hub, scheduler: scheduler)
        if let mode { await parents.register(ParentInfo(parentID: "parent-aaaaaaaa", sessionID: sessionID, sessionTitle: "houston-listings", mode: mode, provider: provider)) }
        return AskRig(hub: hub, scheduler: scheduler, provisioning: provisioning, approvals: approvals, parents: parents, service: service, root: root)
    }

    func reserve(_ names: [String], display: String = "headless", proxy: String? = nil) async -> (isError: Bool, json: JSON) {
        var args: [String: JSON] = ["names": .array(names.map { .string($0) }), "display": .string(display)]
        if let proxy { args["proxy"] = .string(proxy) }
        let outcome = await service.call("boxes_reserve", arguments: .object(args), child: parent)
        let text = outcome.content.first?["text"]?.string ?? "null"
        return (outcome.isError, (try? JSON.parse(text)) ?? .null)
    }

    func waitForRequest() async throws -> ComputerApprovalRequest {
        for _ in 0..<200 {
            if let first = await approvals.open.first { return first }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TestFailure("no approval request appeared")
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

@Suite("F12 modo Ask e Full", .serialized) struct SubagentAskFlowTests {
    @Test func askShowsTheCardTextAndAllowCreatesTheComputer() async throws {
        let rig = try await AskRig.make(mode: .ask, wait: 10)
        defer { rig.cleanup() }
        async let reply = rig.reserve(["houston-listings"], display: "headless")
        let request = try await rig.waitForRequest()
        #expect(request.summary == "Claude wants a computer · houston-listings · Headless · Direct")
        #expect(request.sessionTitle == "houston-listings" && request.names == ["houston-listings"])
        #expect(await rig.provisioning.provisioned.isEmpty, "nothing is created before the decision")
        #expect(await rig.approvals.decide(id: request.id, .allow))
        let done = await reply
        #expect(!done.isError && rig.states(done.json) == ["provisioning"] || rig.states(done.json) == ["ready"])
        #expect(await rig.approvals.open.isEmpty)
        #expect(await rig.waitProvisioned("houston-listings"))
    }

    @Test func theCardNamesTheParentAgentProvider() async throws {
        for (provider, agent) in [(TerminalProvider.codex, "Codex"), (.opencode, "OpenCode")] {
            let rig = try await AskRig.make(mode: .ask, wait: 10, provider: provider)
            defer { rig.cleanup() }
            async let reply = rig.reserve(["houston-listings", "austin-tx"], display: "headless")
            let request = try await rig.waitForRequest()
            #expect(request.agentName == agent)
            #expect(request.summary == "\(agent) wants 2 computers · houston-listings, austin-tx · Headless · Direct")
            _ = await rig.approvals.decide(id: request.id, .deny)
            _ = await reply
        }
    }

    @Test func denyReturnsAClearErrorAndCreatesNothing() async throws {
        let rig = try await AskRig.make(mode: .ask, wait: 10)
        defer { rig.cleanup() }
        async let reply = rig.reserve(["houston-listings"], display: "desktop", proxy: "zyte-us")
        let request = try await rig.waitForRequest()
        #expect(request.summary == "Claude wants a computer · houston-listings · Desktop · zyte-us")
        #expect(await rig.approvals.decide(id: request.id, .deny))
        let done = await reply
        #expect(done.isError && done.json["error"] == "blocked_by_policy")
        #expect(done.json["message"]?.string?.contains("denied") == true)
        try await Task.sleep(for: .milliseconds(100))
        let created = await rig.provisioning.provisioned
        let count = await rig.hubComputerCount()
        #expect(created.isEmpty && count == 0)
    }

    @Test func noDecisionAnswersPendingWithoutBlockingAndTheRetryFindsTheDecision() async throws {
        let rig = try await AskRig.make(mode: .ask, wait: 0.2)
        defer { rig.cleanup() }
        let t0 = ContinuousClock.now
        let first = await rig.reserve(["a"])
        #expect(t0.duration(to: .now) < .seconds(2), "the call never blocks for the whole decision")
        #expect(!first.isError && first.json["status"] == "pending" && first.json["request_id"] != nil)
        #expect(first.json["message"]?.string?.contains("again") == true)
        // O pai repete: o mesmo pedido, sem criar outro card.
        let again = await rig.reserve(["a"])
        #expect(again.json["status"] == "pending")
        #expect(await rig.approvals.open.count == 1)
        // O usuário decide com o pai fora da espera; a próxima chamada passa.
        let request = try await rig.waitForRequest()
        #expect(await rig.approvals.decide(id: request.id, .allow))
        let done = await rig.reserve(["a"])
        #expect(!done.isError && done.json["boxes"] != nil)
        #expect(await rig.waitProvisioned("a"))
    }

    @Test func aDenyDecidedWhileTheParentWasAwayIsDeliveredOnTheNextCall() async throws {
        let rig = try await AskRig.make(mode: .ask, wait: 0.1)
        defer { rig.cleanup() }
        _ = await rig.reserve(["a"])
        let request = try await rig.waitForRequest()
        _ = await rig.approvals.decide(id: request.id, .deny)
        let denied = await rig.reserve(["a"])
        #expect(denied.isError && denied.json["error"] == "blocked_by_policy")
    }

    @Test func allowForThisSessionSilencesTheRestOfTheSession() async throws {
        let rig = try await AskRig.make(mode: .ask, wait: 10)
        defer { rig.cleanup() }
        async let first = rig.reserve(["a"])
        let request = try await rig.waitForRequest()
        #expect(await rig.approvals.decide(id: request.id, .allowForSession))
        #expect(!(await first).isError)
        // Outros alvos e outros displays na mesma sessão não perguntam mais.
        let second = await rig.reserve(["b", "c"], display: "desktop")
        #expect(!second.isError && second.json["boxes"] != nil)
        #expect(await rig.approvals.open.isEmpty)
        // Outra sessão continua perguntando.
        let other = ComputerApprovalRequest(parentID: "other", sessionID: UUID(), sessionTitle: "x", names: ["z"], display: .headless, proxy: "direct")
        #expect(await rig.approvals.isSessionAllowed(other) == false)
    }

    @Test func fullCreatesDirectlyWithoutAnyCard() async throws {
        let rig = try await AskRig.make(mode: .full, wait: 5)
        defer { rig.cleanup() }
        let reply = await rig.reserve(["houston-listings"])
        #expect(!reply.isError && reply.json["boxes"] != nil)
        #expect(await rig.approvals.open.isEmpty)
        #expect(await rig.waitProvisioned("houston-listings"))
    }

    @Test func offOrUnknownParentsCannotReserve() async throws {
        let off = try await AskRig.make(mode: .off)
        defer { off.cleanup() }
        let blocked = await off.reserve(["a"])
        #expect(blocked.isError && blocked.json["error"] == "blocked_by_policy" && blocked.json["message"]?.string?.contains("off") == true)
        let unknown = try await AskRig.make(mode: nil)
        defer { unknown.cleanup() }
        #expect(await unknown.reserve(["a"]).isError)
        #expect(await unknown.provisioning.provisioned.isEmpty)
    }

    @Test func endingTheParentCancelsItsWaitingRequests() async throws {
        let rig = try await AskRig.make(mode: .ask, wait: 10)
        defer { rig.cleanup() }
        async let reply = rig.reserve(["a"])
        _ = try await rig.waitForRequest()
        await rig.approvals.cancel(parent: rig.parent)
        let done = await reply
        #expect(done.isError, "the waiting call ends instead of hanging")
        #expect(await rig.approvals.open.isEmpty)
    }

    @Test func observerSeesRequestsComeAndGo() async throws {
        let rig = try await AskRig.make(mode: .ask, wait: 10)
        defer { rig.cleanup() }
        let seen = Rec<Int>()
        await rig.approvals.setObserver { requests in seen.add(requests.count) }
        async let reply = rig.reserve(["a"])
        let request = try await rig.waitForRequest()
        _ = await rig.approvals.decide(id: request.id, .allow)
        _ = await reply
        #expect(seen.items == [0, 1, 0], "the card appears once and disappears with the decision")
    }
}

// MARK: Gatilho de spawn (hook PreToolUse)

@Suite("F12 gatilho de spawn", .serialized) struct SubagentSpawnTriggerTests {
    private let webSpawn = SubagentSpawnGuard.Input(subagentType: "general-purpose", prompt: "spawna um sub agent pra estudar o site http://origin:8080/", description: "Study the site")

    private func rpc(_ rig: AskRig, _ input: SubagentSpawnGuard.Input) async throws -> JSON {
        let params: JSON = ["subagent_type": .string(input.subagentType ?? ""), "prompt": .string(input.prompt), "description": .string(input.description)]
        let message = JSON.object(["jsonrpc": "2.0", "id": 1, "method": "racky/spawn_guard", "params": params]).data()
        let reply = try #require(await ComputerMCPServer(tools: rig.service).handle(message, child: rig.parent))
        return try JSON.parse(String(decoding: reply, as: UTF8.self))["result"] ?? .null
    }

    @Test func settingsCarryASecondPreToolUseGroupOnlyWhenTheModeIsOn() throws {
        func groups(_ guardConfig: SpawnGuardConfig?) throws -> [[String: Any]] {
            let data = try ClaudeHookSettings.settingsJSON(helperPath: helper, denyRules: ["Skill(racky)"], spawnGuard: guardConfig)
            let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            return try #require((root["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])
        }
        #expect(try groups(nil).count == 1)
        let on = try groups(SpawnGuardConfig(child: "parent-aaaaaaaa", capability: "cap", mode: .ask))
        #expect(on.count == 2 && on[0]["matcher"] == nil, "activity hook for every tool stays first")
        #expect(on[1]["matcher"] as? String == "Agent|Task")
        let hook = try #require((on[1]["hooks"] as? [[String: Any]])?.first)
        let command = try #require(hook["command"] as? String)
        #expect(command.contains("hook-guard --child parent-aaaaaaaa --capability cap --mode ask") && hook["timeout"] as? Int == 30)
        // O pacote do orquestrador liga o gatilho com a identidade do pai.
        var bundle = try fixedBundle()
        bundle.spawnGuardMode = .full
        let injection = bundle.apply(to: LaunchInjection(helperPath: helper))
        #expect(injection.claudeSpawnGuard == SpawnGuardConfig(child: "parent-aaaaaaaa", capability: "cap-parent", mode: .full))
        let plan = try LaunchSamples.plan(LaunchSpec(provider: .claude, initialPrompt: "x"), capabilities: LaunchSamples.helpCapabilities(.claude), slice: .slice2, injection: injection)
        #expect(plan.files.contains { $0.name == "settings.json" && String(decoding: $0.contents, as: UTF8.self).contains("hook-guard") })
    }

    @Test func fullBlocksAPlainWebSubagentThroughTheApp() async throws {
        let rig = try await AskRig.make(mode: .full)
        defer { rig.cleanup() }
        let result = try await rpc(rig, webSpawn)
        #expect(result["decision"] == "block" && result["reason"]?.string?.contains("boxes_reserve") == true)
        let worker = SubagentSpawnGuard.Input(subagentType: "racky-worker-1", prompt: "open http://origin:8080/", description: "w")
        #expect(try await rpc(rig, worker)["decision"] == "allow")
        let plain = SubagentSpawnGuard.Input(subagentType: "general-purpose", prompt: "refactor the parser", description: "r")
        #expect(try await rpc(rig, plain)["decision"] == "allow")
    }

    @Test func askAllowBlocksWithTheInstructionAndTheNextReserveHasNoSecondCard() async throws {
        let rig = try await AskRig.make(mode: .ask, wait: 10)
        defer { rig.cleanup() }
        async let verdict = rpc(rig, webSpawn)
        let request = try await rig.waitForRequest()
        #expect(request.kind == .spawn && request.summary.hasPrefix("Give this subagent a computer?") && request.summary.contains("Study the site"))
        #expect(await rig.approvals.decide(id: request.id, .allow))
        let result = try await verdict
        #expect(result["decision"] == "block" && result["reason"]?.string?.contains("racky-worker-N") == true)
        // O Allow já vale para a reserva que Claude faz em seguida.
        let reserved = await rig.reserve(["study-site"])
        let stillOpen = await rig.approvals.open
        #expect(!reserved.isError && reserved.json["boxes"] != nil && stillOpen.isEmpty)
    }

    @Test func askDenyLetsThePlainSubagentRun() async throws {
        let rig = try await AskRig.make(mode: .ask, wait: 10)
        defer { rig.cleanup() }
        async let verdict = rpc(rig, webSpawn)
        let request = try await rig.waitForRequest()
        #expect(await rig.approvals.decide(id: request.id, .deny))
        #expect(try await verdict["decision"] == "allow")
    }

    @Test func askAllowForSessionBlocksLaterSpawnsWithoutAskingAgain() async throws {
        let rig = try await AskRig.make(mode: .ask, wait: 10)
        defer { rig.cleanup() }
        async let first = rpc(rig, webSpawn)
        let request = try await rig.waitForRequest()
        _ = await rig.approvals.decide(id: request.id, .allowForSession)
        #expect(try await first["decision"] == "block")
        #expect(try await rpc(rig, webSpawn)["decision"] == "block")
        let stillOpen = await rig.approvals.open
        #expect(stillOpen.isEmpty)
    }

    @Test func aSlowAppDefaultsToAllowAndTheCardIsWithdrawn() async throws {
        let rig = try await AskRig.make(mode: .ask, wait: 5, spawnWait: 0.15)
        defer { rig.cleanup() }
        let t0 = ContinuousClock.now
        let result = try await rpc(rig, webSpawn)
        #expect(result["decision"] == "allow" && t0.duration(to: .now) < .seconds(3))
        let stillOpen = await rig.approvals.open
        #expect(stillOpen.isEmpty, "no stale card is left behind")
    }

    @Test func offAndUnknownParentsAllowAndOnlyTheParentMayAsk() async throws {
        let off = try await AskRig.make(mode: .off)
        defer { off.cleanup() }
        #expect(try await rpc(off, webSpawn)["decision"] == "allow")
        let rig = try await AskRig.make(mode: .full)
        defer { rig.cleanup() }
        let message = JSON.object(["jsonrpc": "2.0", "id": 1, "method": "racky/spawn_guard", "params": [:]]).data()
        let reply = try #require(await ComputerMCPServer(tools: rig.service).handle(message, child: "parent-aaaaaaaa-w1"))
        #expect(try JSON.parse(String(decoding: reply, as: UTF8.self))["error"] != nil, "a worker identity cannot use the guard method")
    }
}

final class Rec<T: Sendable>: @unchecked Sendable {  // SAFETY: NSLock protege a lista.
    private let lock = NSLock()
    private var list: [T] = []
    func add(_ item: T) { lock.lock(); list.append(item); lock.unlock() }
    var items: [T] { lock.lock(); defer { lock.unlock() }; return list }
}

extension AskRig {
    func hubComputerCount() async -> Int { await hub.allComputers.count }

    func states(_ result: JSON) -> [String] { (result["boxes"]?.array ?? []).compactMap { $0["state"]?.string } }

    func waitProvisioned(_ name: String) async -> Bool {
        for _ in 0..<300 {
            if await provisioning.provisioned.contains(name) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}
