import RackyPlatform
import RackyProtocol
import Foundation
import Testing

@testable import RackyCore

// Subagent computers com Codex e OpenCode como pai: golden do argv/env/arquivos, instruções e o roteamento por thread do servidor
// MCP "pool" dos workers do Codex (o MCP do Codex não é por agente). Provisionador falso.

private let helper = "/Applications/Racky.app/Contents/MacOS/racky"
private let parent = "parent-aaaaaaaa"

private func bundle(_ provider: TerminalProvider) throws -> OrchestrationBundle {
    var options = OrchestrationInjectionBuilder.Options()
    options.workerSlots = 2
    return try OrchestrationInjectionBuilder.make(
        parentID: parent, helperPath: helper, options: options, parentCapability: "cap-parent", workerCapability: { "cap-w\($0)" }, provider: provider, poolCapability: "cap-pool")
}

/// Golden com o conteúdo dos arquivos pequenos (TOML dos agentes) e a config inline do OpenCode, que o `render` do plano só resume.
private func render(_ label: String, _ plan: LaunchPlan, env: [String] = []) -> String {
    var out = LaunchSamples.render(label, plan)
    for name in env { out += "env \(name): \(plan.environment[name] ?? "-")\n" }
    for file in plan.files where file.name.hasSuffix(".toml") { out += "file \(file.name):\n\(String(decoding: file.contents, as: UTF8.self))" }
    return out
}

@Suite("Subagent computers: Codex e OpenCode") struct MultiProviderOrchestrationTests {
    @Test func codexGolden() throws {
        let spec = LaunchSpec(provider: .codex, initialPrompt: "spawn one subagent with its own computer to open https://example.com")
        let caps = LaunchSamples.helpCapabilities(.codex)
        let injection = try bundle(.codex).applied(to: nil)
        let plan = try LaunchSamples.plan(spec, capabilities: caps, slice: .slice2, injection: injection)
        LaunchFixtures.assertGolden("slice3/codex/subagent-computers.golden", render("codex/subagent-computers", plan))
        let injected = plan.argv.injected
        #expect(!injected.contains { $0.hasPrefix("hooks.") }, "orchestration-only injection carries no activity hooks (no probed trust)")
        #expect(injected.contains { $0.hasPrefix("mcp_servers.racky={") } && injected.contains { $0.hasPrefix("mcp_servers.racky_worker={") })
        #expect(injected.contains { $0.hasPrefix("agents.racky-worker-2.config_file=") })
        #expect(InjectionValidator.violations(injected: injected, launchDirectory: LaunchSamples.launchDirectory, slice: .slice2).isEmpty)
        for file in plan.files where file.name.hasPrefix("codex-agents/") { #expect(file.posixMode == 0o600) }
    }

    @Test func codexKeepsActivityHooksWhenTheBaseHasThemAndOffMeansNoInjection() throws {
        let hashes = Dictionary(uniqueKeysWithValues: HookEventName.codexRegistered.map { ($0, "sha256:" + String(repeating: "a", count: 64)) })
        let base = LaunchInjection(helperPath: helper, codexHookHashes: hashes)
        let withHooks = try LaunchSamples.plan(
            LaunchSpec(provider: .codex), capabilities: LaunchSamples.helpCapabilities(.codex), slice: .slice2, injection: try bundle(.codex).applied(to: base))
        #expect(withHooks.argv.injected.contains { $0.hasPrefix("hooks.") } && withHooks.argv.injected.contains { $0.hasPrefix("mcp_servers.racky=") })
        let off = try LaunchSamples.plan(LaunchSpec(provider: .codex), capabilities: LaunchSamples.helpCapabilities(.codex), slice: .slice2, injection: nil)
        #expect(off.argv.injected.isEmpty && off.files.isEmpty)
    }

    @Test func openCodeGolden() throws {
        let spec = LaunchSpec(provider: .opencode, model: "opencode/deepseek-v4.1-flash-free", initialPrompt: "spawn one subagent with its own computer to open https://example.com")
        let caps = LaunchSamples.helpCapabilities(.opencode)
        let injection = try bundle(.opencode).applied(to: nil)
        let plan = try LaunchSamples.plan(spec, capabilities: caps, slice: .slice2, injection: injection)
        // Config inline em JSON legível no golden (o resto do env é o do plano).
        let raw = try #require(plan.environment[OpenCodeOrchestration.environmentName])
        let object = try JSONSerialization.jsonObject(with: Data(raw.utf8))
        let pretty = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]), as: UTF8.self)
        LaunchFixtures.assertGolden("slice3/opencode/subagent-computers.golden", LaunchSamples.render("opencode/subagent-computers", plan) + "env OPENCODE_CONFIG_CONTENT:\n\(pretty)\n")
        #expect(plan.argv.injected.isEmpty, "OpenCode takes everything through env and the launch directory")
        #expect(plan.files.map(\.name) == [OrchestrationText.openCodeInstructionsFile])
        let config = try #require(object as? [String: Any])
        let instructions = try #require(config["instructions"] as? [String])
        #expect(instructions == ["\(LaunchSamples.launchDirectory.path)/orchestration.md"])
        // Cada worker só enxerga o próprio servidor; o pai e os outros workers ficam negados.
        let agents = try #require(config["agent"] as? [String: [String: Any]])
        #expect(Set(agents.keys) == ["racky-worker-1", "racky-worker-2"])
        let tools = try #require(agents["racky-worker-2"]?["tools"] as? [String: Bool])
        #expect(tools["abx-parent-a-w2_*"] == true && tools["racky_*"] == false && tools["task"] == false)
        #expect((config["tools"] as? [String: Bool]) == ["abx-*": false])
    }

    @Test func openCodeParentCanReadTheRunFoldersWithoutAsking() throws {
        var options = OrchestrationInjectionBuilder.Options()
        options.workerSlots = 1
        options.readableDirectories = ["/tmp/ab/computers/runs"]
        let bundle = try OrchestrationInjectionBuilder.make(parentID: parent, helperPath: helper, options: options, provider: .opencode)
        let rendered = try #require(bundle.openCode).render(launchDirectory: LaunchSamples.launchDirectory)
        let raw = try #require(rendered.environment[OpenCodeOrchestration.environmentName])
        let config = try #require(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let permission = try #require(config["permission"] as? [String: [String: String]])
        #expect(permission["external_directory"] == ["/tmp/ab/computers/runs/*": "allow"])
    }

    @Test func noOrchestrationLeavesOpenCodeUntouched() throws {
        let plan = try LaunchSamples.plan(LaunchSpec(provider: .opencode), capabilities: LaunchSamples.helpCapabilities(.opencode), slice: .slice2, injection: nil)
        #expect(plan.environment[OpenCodeOrchestration.environmentName] == nil && plan.files.isEmpty)
    }

    @Test func nothingIsWrittenOutsideTheLaunchDirectory() throws {
        for provider in [TerminalProvider.codex, .opencode] {
            let plan = try LaunchSamples.plan(
                LaunchSpec(provider: provider), capabilities: LaunchSamples.helpCapabilities(provider), slice: .slice2, injection: try bundle(provider).applied(to: nil))
            for file in plan.files { #expect(!file.name.hasPrefix("/") && !file.name.contains("..")) }
            let dump = plan.argv.flattened.joined(separator: "\n") + (plan.environment[OpenCodeOrchestration.environmentName] ?? "")
            for forbidden in ["/.codex", "/.config/opencode", "/.claude"] { #expect(!dump.contains(forbidden), "\(provider) must not reference \(forbidden)") }
        }
    }

    @Test func slotsAndIdentities() throws {
        let codex = try bundle(.codex)
        #expect(codex.poolID == "parent-a-pool" && codex.poolCapability == "cap-pool")
        #expect(codex.workers.map(\.agentType) == ["racky-worker-1", "racky-worker-2"] && codex.agentsJSON.isEmpty && codex.pluginFiles.isEmpty)
        let openCode = try bundle(.opencode)
        #expect(openCode.poolID == nil && openCode.openCode?.workers.count == 2)
        var defaults = OrchestrationInjectionBuilder.Options()
        defaults.workerSlots = OrchestrationInjectionBuilder.defaultWorkerSlots
        let big = try OrchestrationInjectionBuilder.make(parentID: parent, helperPath: helper, options: defaults, provider: .codex)
        #expect(big.workers.count == OrchestrationInjectionBuilder.defaultOtherWorkerSlots, "Codex and OpenCode load every slot up front, so fewer by default")
        let claude = try OrchestrationInjectionBuilder.make(parentID: parent, helperPath: helper, options: defaults)
        #expect(claude.workers.count == OrchestrationInjectionBuilder.defaultWorkerSlots && claude.provider == .claude)
    }

    @Test func instructionsAreProviderSpecific() {
        let codex = OrchestrationText.codexInstructions
        #expect(codex.contains("spawn_agent") && codex.contains("wait_agent") && codex.contains("boxes_reserve") && !codex.contains("run_in_background"))
        let openCode = OrchestrationText.openCodeInstructions
        #expect(openCode.contains("`task` tool") && openCode.contains("racky_boxes_reserve") && !openCode.contains("spawn_agent"))
        #expect(OrchestrationText.codexWorkerPrompt.contains(OrchestrationText.codexWorkerServerName))
    }
}

// MARK: Roteamento por thread (pool de workers do Codex)

@Suite("Subagent computers: pool de workers do Codex", .serialized) struct CodexPoolRoutingTests {
    private struct Reply { var isError: Bool; var text: String }

    private func call(_ server: ComputerMCPServer, as child: String, _ tool: String, _ args: JSON = [:], thread: String?, subagent: Bool = true) async throws -> Reply {
        var meta: [String: JSON] = [:]
        if let thread {
            meta["threadId"] = .string(thread)
            meta["x-codex-turn-metadata"] = ["thread_id": .string(thread), "thread_source": .string(subagent ? "subagent" : "user")]
        }
        let message = JSON.object([
            "jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": ["name": .string(tool), "arguments": args, "_meta": .object(meta)],
        ]).data()
        let data = try #require(await server.handle(message, child: child))
        let result = try #require(try JSON.parse(String(decoding: data, as: UTF8.self))["result"])
        return Reply(isError: result["isError"]?.bool ?? false, text: result["content"]?.array?.first?["text"]?.string ?? "")
    }

    @Test func aThreadBecomesTheSlotOfTheComputerItClaims() async throws {
        let rig = try await SchedulerRig.make(workers: 3)
        defer { rig.cleanup() }
        // O rig registra um pai do Claude; o pool do Codex entra por cima, como `OrchestrationInjectionBuilder.register`.
        await rig.hub.registerPool(id: "pool-1", capability: "cap-pool", parent: rig.parent)
        let server = ComputerMCPServer(tools: rig.service)
        let good = await rig.hub.authorize(child: "pool-1", capability: "cap-pool")
        let bad = await rig.hub.authorize(child: "pool-1", capability: "nope")
        #expect(good && !bad)

        let reserve = await rig.parentCall("boxes_reserve", ["names": ["alpha", "beta"], "display": "headless"])
        let boxes = try #require(reserve.json["boxes"]?.array)
        #expect(boxes.count == 2)
        let alphaReady = await rig.wait("alpha", .ready)
        let poolRole = await rig.hub.role(of: "pool-1")
        #expect(alphaReady && poolRole == .pool)

        // Fora de um subagente (a thread raiz do Codex): negado.
        let root = try await call(server, as: "pool-1", "box_claim", ["name": "alpha", "wait_s": 5], thread: "thread-root", subagent: false)
        #expect(root.isError && root.text.contains("worker tool"))
        // Subagente sem claim: not_claimed. Com claim de um nome que não é do pai: not_found.
        let early = try await call(server, as: "pool-1", "box_status", thread: "thread-A")
        #expect(early.isError && early.text.contains("not_claimed"))
        let wrong = try await call(server, as: "pool-1", "box_claim", ["name": "ghost", "wait_s": 1], thread: "thread-A")
        #expect(wrong.isError && wrong.text.contains("not_found"))

        // Duas threads, dois computadores, duas identidades.
        let a = try await call(server, as: "pool-1", "box_claim", ["name": "alpha", "wait_s": 5], thread: "thread-A")
        let b = try await call(server, as: "pool-1", "box_claim", ["name": "beta", "wait_s": 5], thread: "thread-B")
        #expect(!a.isError && !b.isError)
        let slotA = try #require(boxes[0]["child_id"]?.string), slotB = try #require(boxes[1]["child_id"]?.string)
        #expect(slotA != slotB)
        let claimedA = await rig.hub.claimedComputer(of: slotA)
        let claimedB = await rig.hub.claimedComputer(of: slotB)
        #expect(claimedA == "alpha" && claimedB == "beta")
        let statusA = try await call(server, as: "pool-1", "box_status", thread: "thread-A")
        let statusB = try await call(server, as: "pool-1", "box_status", thread: "thread-B")
        #expect(statusA.text.contains("alpha") && statusB.text.contains("beta") && !statusA.text.contains("\"beta\""))
        // Uma terceira thread não herda nada.
        let other = try await call(server, as: "pool-1", "box_status", thread: "thread-C")
        #expect(other.isError)
    }

    @Test func aSubagentCannotUseTheParentToolsItInheritsFromTheCodexMcpManager() async throws {
        let rig = try await SchedulerRig.make(workers: 2)
        defer { rig.cleanup() }
        let server = ComputerMCPServer(tools: rig.service)
        let fromWorker = try await call(server, as: rig.parent, "boxes_reserve", ["names": ["sneaky"]], thread: "thread-A")
        #expect(fromWorker.isError && fromWorker.text.contains("parent session"))
        let sneaky = await rig.hub.computer(named: "sneaky")
        #expect(sneaky == nil)
        let fromRoot = try await call(server, as: rig.parent, "boxes_reserve", ["names": ["fine"], "display": "headless"], thread: "thread-root", subagent: false)
        #expect(!fromRoot.isError)
        // Sem `_meta` (Claude, OpenCode): igual a antes.
        let plain = try await call(server, as: rig.parent, "boxes_status", thread: nil)
        #expect(!plain.isError)
    }

    @Test func endingTheParentDropsThePool() async throws {
        let hub = ComputerHub()
        await hub.registerPool(id: "pool-1", capability: "cap", parent: parent)
        await hub.bind(thread: "t", pool: "pool-1", to: "x-w1")
        let before = await hub.boundChild(thread: "t", pool: "pool-1")
        #expect(before == "x-w1")
        await hub.unregisterPools(of: parent)
        let role = await hub.role(of: "pool-1")
        let authorized = await hub.authorize(child: "pool-1", capability: "cap")
        let bound = await hub.boundChild(thread: "t", pool: "pool-1")
        #expect(role == nil && !authorized && bound == nil)
    }
}
