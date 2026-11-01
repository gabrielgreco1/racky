import RackyDocker
import RackyPlatform
import RackyProtocol
import RackyStore
import Foundation
import Testing

@testable import RackyCore

// T3-04: árvore pai -> filhos (persistida e derivada), `waitingOnSubagents`, `agent_message` do pai (P12), injeção por lançamento
// (skill, `--agents` com mcpServers em array, deny de `Skill(racky)`, env) e a correlação com os hooks reais do S-08.

@Suite("T3-04 árvore e estado do pai") struct TreeStateTests {
    typealias Child = OrchestrationTree.ChildSummary

    @Test func parentWaitsOnSubagentsOnlyWhileAChildIsActive() {
        let live = [Child(childID: "w1", state: .claimed, activity: .working), Child(childID: "w2", state: .reserved)]
        #expect(OrchestrationTree.parentActivity(parent: .done, children: live) == .waitingOnSubagents)
        #expect(OrchestrationTree.parentActivity(parent: .idle, children: live) == .waitingOnSubagents)
        #expect(OrchestrationTree.parentActivity(parent: .working, children: live) == .working, "turn still running")
        let finished = [Child(childID: "w1", state: .ended, activity: .done), Child(childID: "w2", state: .released, activity: .done)]
        #expect(OrchestrationTree.parentActivity(parent: .done, children: finished) == .done)
        #expect(OrchestrationTree.parentActivity(parent: .waitingOnSubagents, children: finished) == .done)
        #expect(OrchestrationTree.parentActivity(parent: .failed, children: live) == .failed)
    }

    @Test func aChildNeedingInputRisesToTheParentAndIsNeverHidden() {
        let children = [Child(childID: "w1", state: .claimed, activity: .needsInput(.other)), Child(childID: "w2", state: .claimed, activity: .working)]
        #expect(OrchestrationTree.parentActivity(parent: .done, children: children) == .needsInput(.other))
        #expect(OrchestrationTree.parentActivity(parent: .working, children: children) == .needsInput(.other))
    }

    @Test func cardLabelCountsRunningAndNeedsYou() {
        var children = (1...15).map { Child(childID: "w\($0)", state: .claimed, activity: .working) }
        for i in 0..<13 { children[i] = Child(childID: "w\(i + 1)", state: .ended, activity: .done) }
        children[13] = Child(childID: "w14", state: .claimed, activity: .needsInput(.other))
        #expect(OrchestrationTree.label(children: children) == "2 of 15 running · 1 needs you")
        #expect(OrchestrationTree.label(children: []) == nil)
        #expect(OrchestrationTree.label(children: [Child(childID: "w1", state: .idle)]) == nil, "idle slots are not children yet")
    }

    @Test func reducerPutsTheParentInWaitingOnSubagentsWhenItsTurnEndsWithLiveChildren() throws {
        // Hooks reais do S-08: o pai dispara dois subagentes e o turno dele só fecha depois dos `SubagentStop`.
        let raws = try RealHooks.events(RealHooks.claudeSubagents)
        let events = RealHooks.activityEvents(raws)
        var state = ActivityState()
        var sawWaiting = false
        for event in events {
            state = ActivityReducer.reduce(state, event)
            if state.activity == .waitingOnSubagents { sawWaiting = true }
        }
        #expect(state.activity == .done && state.liveChildCount == 0)
        // Um `Stop` do pai com filho vivo vira `waitingOnSubagents`, e o último `SubagentStop` o leva a `done`.
        var partial = ActivityState()
        for event in events.prefix(while: { $0.name != "SubagentStop" }) { partial = ActivityReducer.reduce(partial, event) }
        let t = events.last { $0.name == "SubagentStart" }!.atNs + 10_000
        partial = ActivityReducer.reduce(partial, ActivityEvent(name: "Stop", payload: ReducedHookPayload(), atNs: t))
        #expect(partial.activity == .waitingOnSubagents && partial.liveChildCount == 2)
        _ = sawWaiting
        for event in events where event.name == "SubagentStop" { partial = ActivityReducer.reduce(partial, event) }
        #expect(partial.activity == .done)
    }
}

@Suite("T3-04 árvore persistida e hooks", .serialized) struct TreePersistenceTests {
    @Test func slotsReservationsMessagesAndQueueSurviveReopeningTheStore() async throws {
        let home = try ActivityHome(); defer { home.remove() }
        let store = try await home.openStore()
        let rig = try await SchedulerRig.make(vm: SchedulerRig.eightGB, workers: 6, store: store)
        defer { rig.cleanup() }

        let slots = try await store.orchestrationChildren(parentID: rig.parent)
        #expect(slots.map(\.slot) == [1, 2, 3, 4, 5, 6] && slots.allSatisfy { $0.state == .idle && $0.agentType == "racky-worker-\($0.slot)" })

        await rig.provisioning.setHolding(true)
        let reply = await rig.parentCall("boxes_reserve", ["names": ["a", "b", "c", "d", "e"], "batch": "listings-oct"])
        let boxes = try #require(reply.json["boxes"]?.array)
        let reserved = try await store.orchestrationChildren(parentID: rig.parent)
        #expect(reserved.filter { $0.state == .reserved }.count == 5)
        #expect(reserved.first { $0.computerName == "e" }?.batchID == "listings-oct")
        #expect(boxes[4]["child_id"]?.string == reserved.first { $0.computerName == "e" }?.id)

        // A fila persistida espelha a posição visível ao pai (CS-131).
        let queue = try await store.computerQueue()
        #expect(queue.count == 1 && queue[0].position == 1 && queue[0].reason == "memory")
        let rows = try await store.computerStates()
        #expect(rows.count == 5 && rows.filter { $0.state == "queued" }.count == 1 && rows.filter { $0.state == "provisioning" }.count == 4)

        await rig.provisioning.openGates()
        for n in ["a", "b", "c", "d"] { #expect(await rig.wait(n, .ready)) }
        _ = await rig.parentCall("boxes_release", ["names": ["a"]])
        #expect(await rig.wait("e", .ready))
        #expect(try await store.computerQueue().isEmpty)
        let afterRelease = try await store.orchestrationChildren(parentID: rig.parent)
        #expect(afterRelease.first { $0.computerName == "a" }?.state == .released)
        try await store.close()

        // Reabrir: a árvore e a fila continuam lá.
        let reopened = try await home.openStore()
        let again = try await reopened.orchestrationChildren(parentID: rig.parent)
        #expect(again.count == 6 && again.filter { $0.state == .reserved }.count == 4)
        try await reopened.close()
    }

    @Test func realSubagentHooksLinkEachWorkerSlotToItsNativeRunAndEndIt() async throws {
        let home = try ActivityHome(); defer { home.remove() }
        let store = try await home.openStore()
        let parentRun = UUID()
        let parentID = parentRun.uuidString.lowercased()
        let rig = try await SchedulerRig.make(workers: 2, parent: parentID, store: store)
        defer { rig.cleanup() }
        let service = ActivityService(store: store, spoolDirectory: home.spoolDirectory)
        let scheduler = rig.scheduler
        await service.setChildObserver { hook in
            await scheduler.handleChildHook(parentRunID: hook.parentRunID, event: hook.event, agentID: hook.agentID, mcpServer: hook.mcpServer)
        }
        let child1 = OrchestrationInjectionBuilder.childID(parent: parentID, slot: 1)
        let child2 = OrchestrationInjectionBuilder.childID(parent: parentID, slot: 2)
        var raws = try RealHooks.events(RealHooks.claudeSubagents)
        for i in raws.indices {
            guard var server = raws[i].object["mcp_server"] as? [String: Any], let name = server["name"] as? String else { continue }
            server["name"] = name == "whoami-a" ? OrchestrationInjectionBuilder.serverName(forChild: child1) : OrchestrationInjectionBuilder.serverName(forChild: child2)
            raws[i].object["mcp_server"] = server
        }
        for e in RealHooks.envelopes(raws, runID: parentRun, paneID: nil) { try await service.ingest(e) }

        let a = try #require(try await store.orchestrationChild(id: child1))
        let b = try #require(try await store.orchestrationChild(id: child2))
        #expect(a.providerAgentID == "a9d32b813be6acccc" && b.providerAgentID == "a69e07ec721dc760d")
        let runA = try #require(a.runID)
        #expect(runA == ActivityProjector.childRunID(parent: parentRun, agentID: "a9d32b813be6acccc"))
        let nativeRun = try #require(try await store.agentRun(id: runA))
        #expect(nativeRun.kind == .nativeSubagent && nativeRun.parentRunID == parentRun)
        #expect(a.state == .ended && b.state == .ended, "SubagentStop closes the slot")
        // O resumo da árvore junta a atividade do `agent_run` do filho.
        let summaries = try await store.orchestrationSummaries(parentID: parentID)
        #expect(summaries.count == 2 && summaries.allSatisfy { $0.activity == .done })
        try await store.close()
    }

    @Test func messagesPersistWithDeliveryStateAndOrder() async throws {
        let home = try ActivityHome(); defer { home.remove() }
        let store = try await home.openStore()
        try await store.registerOrchestrationChild(OrchestrationChild(id: "p-w1", parentID: "p", slot: 1, agentType: "racky-worker-1"))
        let m1 = try await store.appendAgentMessage(parentID: "p", childID: "p-w1", text: "first", delivery: .inbox)
        _ = try await store.appendAgentMessage(parentID: "p", childID: "p-w1", text: "second", delivery: .inbox)
        #expect(try await store.pendingAgentMessages(childID: "p-w1").map(\.text) == ["first", "second"])
        try await store.markAgentMessagesDelivered([m1.id])
        #expect(try await store.pendingAgentMessages(childID: "p-w1").map(\.text) == ["second"])
        #expect(try await store.agentMessages(childID: "p-w1").count == 2)
        await #expect(throws: StoreError.self) { _ = try await store.appendAgentMessage(parentID: "p", childID: "p-w1", text: "", delivery: .inbox) }
        try await store.close()
    }
}

@Suite("T3-04 agent_message (P12)", .serialized) struct AgentMessageTests {
    @Test func parentMessageReachesItsChildWithNextStatusAndIsOnTheTimeline() async throws {
        let home = try ActivityHome(); defer { home.remove() }
        let store = try await home.openStore()
        let rig = try await SchedulerRig.make(workers: 3, store: store)
        defer { rig.cleanup() }
        _ = await rig.parentCall("boxes_reserve", ["names": ["phoenix-az"]])
        #expect(await rig.wait("phoenix-az", .ready))
        let child = try #require(await rig.scheduler.childID(for: "phoenix-az"))
        _ = await rig.parentCall("box_claim", ["name": "phoenix-az", "wait_s": 1], as: child)

        let sent = await rig.parentCall("agent_message", ["child_id": .string(child), "text": "Also check the listings archive page.\nThen submit."])
        #expect(!sent.isError && sent.json["delivered"] == "inbox" && sent.json["message_id"]?.string?.isEmpty == false)
        let status = await rig.parentCall("box_status", [:], as: child)
        let messages = try #require(status.json["parent_messages"]?.array)
        #expect(messages.count == 1 && messages[0]["text"] == "Also check the listings archive page.\nThen submit." && messages[0]["from"] == "parent")
        // Entregue uma vez só.
        #expect(await rig.parentCall("box_status", [:], as: child).json["parent_messages"] == nil)
        // Registrada em logs/messages.jsonl (com hash encadeado) e na timeline.
        let computer = try #require(await rig.hub.computer(named: "phoenix-az"))
        let logged = ChainedLog.read(computer.messages.file)
        #expect(logged.count == 1 && logged[0]["text"]?.string == "Also check the listings archive page.\nThen submit." && logged[0]["from"] == "parent")
        let timeline = await rig.parentCall("timeline", ["format": "md", "include": ["messages"]], as: child)
        let timelineText = timeline.json["content"]?.string ?? timeline.json.text
        #expect(timelineText.contains("Also check the listings archive page"))
        #expect(try await store.agentMessages(childID: child).first?.deliveredAt != nil)
        try await store.close()
    }

    @Test func messageByComputerNameAndQueuedBeforeTheComputerExists() async throws {
        let rig = try await SchedulerRig.make(workers: 3)
        defer { rig.cleanup() }
        let firstChild = OrchestrationInjectionBuilder.childID(parent: rig.parent, slot: 1)
        // Slot ainda sem computador: fica enfileirada e sai no claim.
        let early = await rig.parentCall("agent_message", ["child_id": .string(firstChild), "text": "context: use the open data portal"])
        #expect(early.json["delivered"] == "queued")
        _ = await rig.parentCall("boxes_reserve", ["names": ["austin-tx"]])
        #expect(await rig.wait("austin-tx", .ready))
        let claim = await rig.parentCall("box_claim", ["name": "austin-tx", "wait_s": 1], as: firstChild)
        #expect(claim.json["parent_messages"]?.array?.first?["text"] == "context: use the open data portal")
        // Pelo nome do computador.
        let byName = await rig.parentCall("agent_message", ["child_id": "austin-tx", "text": "second note"])
        #expect(byName.json["delivered"] == "inbox" && byName.json["child_id"]?.string == firstChild)
    }

    @Test func parentCannotMessageSubagentsItDidNotCreate() async throws {
        let rig = try await SchedulerRig.make(workers: 2)
        defer { rig.cleanup() }
        await rig.hub.registerParent(id: "parent-bbbbbbbb", capability: "cap-b")
        await rig.hub.registerChild(id: "parent-bbbbbbbb-w1", capability: "cap-x", parent: "parent-bbbbbbbb")
        let foreign = await rig.parentCall("agent_message", ["child_id": "parent-bbbbbbbb-w1", "text": "hello"])
        #expect(errorCode(foreign) == "blocked_by_policy")
        let unknown = await rig.parentCall("agent_message", ["child_id": "does-not-exist", "text": "hello"])
        #expect(errorCode(unknown) == "blocked_by_policy")
        let empty = await rig.parentCall("agent_message", ["child_id": "x", "text": ""])
        #expect(errorCode(empty) == "invalid_argument")
        // Um worker nunca manda mensagem (ferramenta do pai).
        let worker = OrchestrationInjectionBuilder.childID(parent: rig.parent, slot: 1)
        #expect(errorCode(await rig.parentCall("agent_message", ["child_id": .string(worker), "text": "hi"], as: worker)) == "blocked_by_policy")
    }
}

@Suite("T3-04 injeção por lançamento") struct OrchestrationInjectionTests {
    static let helper = "/Applications/Racky.app/Contents/MacOS/racky"

    func bundle(slots: Int = 4) throws -> OrchestrationBundle {
        var options = OrchestrationInjectionBuilder.Options()
        options.workerSlots = slots
        return try OrchestrationInjectionBuilder.make(parentID: "0f0e0d0c-aaaa-4bbb-8ccc-000000000001", helperPath: Self.helper, options: options)
    }

    @Test func workersUseMcpServersAsArrayWithOneUniqueServerPerChild() throws {
        let b = try bundle(slots: 4)
        let agents = try #require(try JSONSerialization.jsonObject(with: b.agentsJSON) as? [String: [String: Any]])
        #expect(agents.keys.sorted() == ["racky-worker-1", "racky-worker-2", "racky-worker-3", "racky-worker-4"])
        var servers = Set<String>()
        for (type, definition) in agents {
            // S-08: `mcpServers` é ARRAY de objetos de um item; objeto direto foi recusado pelo Claude Code 2.1.302.
            let list = try #require(definition["mcpServers"] as? [[String: [String: Any]]])
            #expect(list.count == 1)
            let (name, config) = try #require(list[0].first)
            servers.insert(name)
            #expect(config["command"] as? String == Self.helper)
            let args = try #require(config["args"] as? [String])
            #expect(args.prefix(3) == ["mcp", "--child", args[2]] && args[2].hasSuffix("-w" + type.dropFirst("racky-worker-".count)) && args.contains("--capability"))
            #expect(name == "abx-" + args[2])
            let tools = try #require(definition["tools"] as? [String])
            #expect(tools.count == ToolCatalog.all.count && tools.allSatisfy { $0.hasPrefix("mcp__\(name)__") }, "a worker only gets the tools of its own server")
            #expect((definition["prompt"] as? String)?.contains("box_claim") == true && (definition["description"] as? String)?.contains("computer") == true)
            #expect(definition["skills"] == nil, "no webscraping-expert unless the skill exists on this Mac")
        }
        #expect(servers.count == 4)
        #expect(Set(b.workers.map(\.capability)).count == 4 && !b.workers.contains { $0.capability == b.parentCapability })
        let mcp = try #require(try JSONSerialization.jsonObject(with: b.mcpConfig) as? [String: [String: [String: Any]]])
        #expect(mcp["mcpServers"]?["racky"]?["command"] as? String == Self.helper)
        #expect(mcp["mcpServers"]?["racky"]?["args"] as? [String] == ["mcp", "--child", b.parentID, "--capability", b.parentCapability])
    }

    @Test func workerSkillsComeOnlyFromTheCatalog() throws {
        var options = OrchestrationInjectionBuilder.Options()
        options.workerSlots = 1
        options.workerSkills = ["webscraping-expert"]
        options.workerModel = "sonnet"
        let b = try OrchestrationInjectionBuilder.make(parentID: "p", helperPath: Self.helper, options: options)
        let agents = try #require(try JSONSerialization.jsonObject(with: b.agentsJSON) as? [String: [String: Any]])
        #expect(agents["racky-worker-1"]?["skills"] as? [String] == ["webscraping-expert"] && agents["racky-worker-1"]?["model"] as? String == "sonnet")
    }

    @Test func skillTeachesTheOrchestrationFlow() throws {
        let b = try bundle()
        let skill = String(decoding: try #require(b.pluginFiles.first { $0.name.hasSuffix("SKILL.md") }).contents, as: UTF8.self)
        #expect(skill.hasPrefix("---\nname: racky-boxes\ndescription: "))
        for needle in ["boxes_reserve", "subagent_type", "run_in_background", "boxes_status", "boxes_release", "agent_message", "COMPUTER:", "TASK:", "WHAT WE ALREADY KNOW:", "OUTPUT:",
                       "queued", "cited_missing", "untrusted", "ONE message", "never buy"] {
            #expect(skill.contains(needle) || skill.lowercased().contains(needle.lowercased()), "skill misses \(needle)")
        }
        #expect(skill.contains("Prefer this over Docker commands."), "specific description so the app skill wins over plain Docker")
        #expect(!skill.contains("racky exec"), "no old CLI commands")
        let manifestFile = try #require(b.pluginFiles.first { $0.name.hasSuffix("plugin.json") })
        let manifest = try #require(try JSONSerialization.jsonObject(with: manifestFile.contents) as? [String: Any])
        #expect(manifest["name"] as? String == "racky-app")
    }

    @Test func settingsDenyTheGlobalSkillAndKeepTheHooks() throws {
        let data = try ClaudeHookSettings.settingsJSON(helperPath: Self.helper, denyRules: [OrchestrationText.denyGlobalSkill])
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((root["permissions"] as? [String: Any])?["deny"] as? [String] == ["Skill(racky)"])
        #expect((root["hooks"] as? [String: Any])?["SubagentStop"] != nil)
        let plain = try #require(try JSONSerialization.jsonObject(with: try ClaudeHookSettings.settingsJSON(helperPath: Self.helper)) as? [String: Any])
        #expect(plain["permissions"] == nil, "default settings stay as before")
    }

    @Test func launchPlanCarriesEveryInjectionPerLaunchAndNothingGlobal() throws {
        let b = try bundle(slots: 3)
        let injection = b.apply(to: LaunchInjection(helperPath: Self.helper))
        var login = LaunchSamples.loginEnvironment
        login["CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"] = "1"
        var input = LaunchSamples.input(
            LaunchSpec(provider: .claude, initialPrompt: "spawn 2 subagents for Phoenix and Austin"), capabilities: LaunchSamples.helpCapabilities(.claude),
            slice: .slice2, injection: injection)
        input.loginEnvironment = login
        let plan = try LaunchPlanner.plan(input, newUUID: { LaunchSamples.fixedID })
        let argv = plan.flattenedArgv
        for flag in ["--settings", "--mcp-config", "--plugin-dir", "--agents"] { #expect(argv.contains(flag), "missing \(flag)") }
        let agentsIndex = try #require(argv.firstIndex(of: "--agents"))
        #expect(argv[agentsIndex + 1] == String(decoding: b.agentsJSON, as: UTF8.self))
        #expect(InjectionValidator.violations(injected: plan.argv.injected, launchDirectory: LaunchSamples.launchDirectory, slice: .slice2).isEmpty)
        // Prompt posicional protegido por `--` e tudo em arquivos do diretório do lançamento (nenhum caminho em ~/.claude).
        #expect(argv.suffix(2) == ["--", "spawn 2 subagents for Phoenix and Austin"])
        #expect(!argv.contains { $0.contains("/.claude") })
        let names = Set(plan.files.map(\.name))
        #expect(names.isSuperset(of: ["settings.json", "mcp.json", "plugin/.claude-plugin/plugin.json", "plugin/skills/racky-boxes/SKILL.md"]))
        let settings = try #require(plan.files.first { $0.name == "settings.json" })
        #expect(String(decoding: settings.contents, as: UTF8.self).contains("Skill(racky)"))
        // Env: limite de subagentes (CS-325) e agent teams ausente mesmo que o shell de login o tenha (CS-310).
        #expect(plan.environment["CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS"] == "3")
        #expect(plan.environment["CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"] == nil)
        // Codex não recebe nada disto.
        let codex = try LaunchSamples.plan(LaunchSpec(provider: .codex, initialPrompt: "x"), slice: .slice2, injection: injection)
        #expect(!codex.flattenedArgv.contains("--agents") && codex.environment["CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS"] == nil)
        // Resume regenera as mesmas peças.
        let resume = try LaunchPlanner.plan(LaunchSamples.input(
            LaunchSpec(provider: .claude, resumeOf: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"), capabilities: LaunchSamples.helpCapabilities(.claude), slice: .slice2, injection: injection),
            newUUID: { LaunchSamples.fixedID })
        #expect(resume.argv.injected == plan.argv.injected)
    }
}
