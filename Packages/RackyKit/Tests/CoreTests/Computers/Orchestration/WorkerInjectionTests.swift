import RackyPlatform
import RackyProtocol
import Foundation
import Testing

@testable import RackyCore

// Spec subagent-harness: injeção do terminal do worker por CLI (só o MCP do próprio filho), o prompt pesado do worker e o texto do pai por
// harness. Nenhum CLI real: o `LaunchCoordinator` fala com um daemon falso.

private let helper = "/Applications/Racky.app/Contents/MacOS/racky"

private func worker(_ harness: WorkerHarness) -> WorkerLaunch {
    WorkerLaunch(parentID: "parent-aaaaaaaa", childID: "parent-a-a1", capability: "cap-worker-1", harness: harness, helperPath: helper)
}

private func coordinator(_ gateway: FakeGateway, prepared: Rec<ParentInfo>) -> LaunchCoordinator {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("wk-\(UUID().uuidString)", isDirectory: true)
    return LaunchCoordinator(
        daemon: gateway,
        configuration: .init(
            launchRoot: root, appSocketPath: "/tmp/app.sock",
            loginEnvironment: { ["PATH": "/usr/bin:/bin", "HOME": "/Users/example", "SHELL": "/bin/zsh"] },
            resolveExecutable: { name, _ in ["claude": "/usr/local/bin/claude", "codex": "/usr/local/bin/codex", "opencode": "/usr/local/bin/opencode"][name] },
            capabilities: { provider, _ in LaunchSamples.helpCapabilities(provider) }, slice: .slice2,
            injection: { provider in provider == .claude ? LaunchInjection(helperPath: helper) : nil },
            prepareOrchestration: { info in prepared.add(info); return try? OrchestrationInjectionBuilder.make(parentID: info.parentID, helperPath: helper, provider: info.provider) }))
}

private func job(_ provider: TerminalProvider, harness: WorkerHarness) -> LaunchJob {
    LaunchJob(
        terminalID: UUID(), spec: LaunchSpec(provider: provider, initialPrompt: "WORKER PROMPT", workerChildID: "parent-a-a1"), cwd: "/tmp",
        // A sessão do pai tem Subagent computers ligado: o terminal do worker ainda assim NÃO é pai de ninguém.
        subagent: SubagentLaunch(sessionID: UUID(), sessionTitle: "houston", mode: .full, harness: .codex), workerOf: worker(harness))
}

@Suite("Subagent harness: injeção do worker") struct WorkerInjectionTests {
    @Test func codexWorkerCarriesOnlyItsOwnAutoApprovedServer() async throws {
        let gateway = FakeGateway(), prepared = Rec<ParentInfo>()
        _ = try await coordinator(gateway, prepared: prepared).launch(job(.codex, harness: .codex), onEvent: { _ in })
        #expect(prepared.items.isEmpty, "a worker skips the parent orchestration")
        let argv = gateway.requests[0].argv
        let servers = argv.filter { $0.hasPrefix("mcp_servers.") }
        #expect(servers.count == 1 && servers[0].hasPrefix("mcp_servers.racky_worker={"))
        let table = servers[0]
        #expect(table.contains("\"--child\",\"parent-a-a1\",\"--capability\",\"cap-worker-1\"") && table.contains("default_tools_approval_mode=\"approve\""))
        #expect(table.contains("command=\"\(helper)\""))
        #expect(!argv.contains { $0.hasPrefix("agents.") || $0.hasPrefix("developer_instructions") || $0.hasPrefix("hooks.") })
        #expect(argv.last == "WORKER PROMPT", "the worker prompt is the initial prompt")
    }

    @Test func openCodeWorkerCarriesOnlyItsOwnServerAndAutoAllowsIt() async throws {
        let gateway = FakeGateway(), prepared = Rec<ParentInfo>()
        _ = try await coordinator(gateway, prepared: prepared).launch(job(.opencode, harness: .opencode), onEvent: { _ in })
        #expect(prepared.items.isEmpty)
        let request = gateway.requests[0]
        let raw = try #require(request.env[OpenCodeOrchestration.environmentName])
        let config = try #require(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let mcp = try #require(config["mcp"] as? [String: [String: Any]])
        #expect(Array(mcp.keys) == ["abx-parent-a-a1"])
        #expect(mcp["abx-parent-a-a1"]?["command"] as? [String] == [helper, "mcp", "--child", "parent-a-a1", "--capability", "cap-worker-1"])
        #expect((config["permission"] as? [String: String]) == ["abx-parent-a-a1_*": "allow"])
        #expect(config["agent"] == nil && config["instructions"] == nil && config["plugin"] == nil)
        #expect(request.argv.contains("--prompt") && request.argv.last == "WORKER PROMPT")
    }

    @Test func claudeWorkerCarriesOnlyItsOwnServerAndAllowsItsTools() async throws {
        let gateway = FakeGateway(), prepared = Rec<ParentInfo>()
        _ = try await coordinator(gateway, prepared: prepared).launch(job(.claude, harness: .claude), onEvent: { _ in })
        #expect(prepared.items.isEmpty)
        let argv = gateway.requests[0].argv
        #expect(!argv.contains("--agents") && !argv.contains("--plugin-dir") && !argv.contains("--allowedTools"), "no variadic flag can swallow the prompt")
        let mcpPath = try #require(argv.firstIndex(of: "--mcp-config").map { argv[$0 + 1] })
        let mcp = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: mcpPath))) as? [String: Any])
        let servers = try #require(mcp["mcpServers"] as? [String: [String: Any]])
        #expect(Array(servers.keys) == ["abx-parent-a-a1"] && servers["abx-parent-a-a1"]?["args"] as? [String] == ["mcp", "--child", "parent-a-a1", "--capability", "cap-worker-1"])
        let settingsPath = try #require(argv.firstIndex(of: "--settings").map { argv[$0 + 1] })
        let settings = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: settingsPath))) as? [String: Any])
        let permissions = try #require(settings["permissions"] as? [String: [String]])
        #expect(permissions["allow"] == ["mcp__abx-parent-a-a1__*"] && permissions["deny"] == ["Skill(racky)"])
        #expect(argv.last == "WORKER PROMPT" && argv[argv.count - 2] == "--")
        // O hook de spawn do pai não vai para o worker.
        #expect(!String(decoding: try Data(contentsOf: URL(fileURLWithPath: settingsPath)), as: UTF8.self).contains("hook-guard"))
    }

    @Test func workerLaunchSpecSurvivesCodingAndOldSpecsDecode() throws {
        let spec = LaunchSpec(provider: .codex, workerChildID: "x-a1")
        let back = try JSONDecoder().decode(LaunchSpec.self, from: JSONEncoder().encode(spec))
        #expect(back.workerChildID == "x-a1")
        let old = try JSONDecoder().decode(LaunchSpec.self, from: Data(#"{"provider":"codex","extraArgs":[],"envOverrides":{}}"#.utf8))
        #expect(old.workerChildID == nil)
    }
}

@Suite("Subagent harness: prompts e texto do pai") struct WorkerPromptTests {
    private func prompt(_ harness: WorkerHarness = .codex, brief: String = "TASK: study X") -> String {
        OrchestrationText.workerPrompt(harness: harness, computer: "houston-tx", brief: brief, title: "Houston listings")
    }

    @Test(arguments: WorkerHarness.allCases)
    func promptHasEveryRequiredStepAndStaysUnderSixKB(_ harness: WorkerHarness) {
        let text = prompt(harness)
        #expect(text.utf8.count < OrchestrationText.workerPromptLimitBytes, "\(text.utf8.count) bytes")
        #expect(text.contains("\"houston-tx\"") && text.contains("Houston listings") && text.contains("TASK: study X"))
        for needle in [
            "box_claim {\"name\":\"houston-tx\"}", "queued or provisioning", "work_path_host", "\"kind\":\"PLAN\"", "\"kind\":\"DOING\"", "\"kind\":\"FOUND\"",
            "\"kind\":\"BLOCKED\"", "http_request {", "\"impersonate\":\"chrome\"", "browser_open", "reqlog_query {\"xhr\":true", "dataset_define", "dataset_append",
            "\"_request_id\"", "PAGE BY PAGE", "/work/scratch", "/work/downloads", "help_request {\"kind\":\"captcha\"", "help_wait {\"request_id\"", "result_submit {\"result\"",
            "\"evidence\"", "box_release {}", "reply exactly DONE", "BRIEF (verbatim)", "TOOLS",
        ] { #expect(text.contains(needle), "missing \(needle)") }
        #expect(text.hasSuffix("TASK: study X"), "the brief comes last, verbatim")
        #expect(text.contains(harness == .codex ? "racky_worker" : "abx-"))
    }

    @Test func everyToolNamedInThePromptReferenceExists() {
        let names = Set(ToolCatalog.all.map(\.name))
        let text = prompt()
        for tool in ["box_claim", "box_status", "box_release", "journal", "http_request", "reqlog_query", "reqlog_get", "dataset_define", "dataset_append", "result_submit",
                     "help_request", "help_wait", "help_cancel", "browser_open", "browser_read", "browser_click", "exec_start", "computer_mode", "timeline", "render"] {
            #expect(names.contains(tool) && text.contains(tool), "\(tool)")
        }
    }

    @Test func theJSONExamplesInThePromptValidateAgainstTheToolSchemas() throws {
        // Os exemplos do prompt são os que o modelo vai copiar: cada um tem de passar na validação do catálogo real.
        let examples: [(String, JSON)] = [
            ("box_claim", ["name": "houston-tx"]),
            ("journal", ["kind": "PLAN", "text": "what I will do"]),
            ("journal", ["kind": "FOUND", "text": "x", "evidence": ["01HX"]]),
            ("http_request", ["method": "GET", "url": "https://example.com/api/items?page=1", "impersonate": "chrome"]),
            ("reqlog_query", ["xhr": true, "last": 30]),
            ("reqlog_query", ["host": "example.com", "grep": "api"]),
            ("dataset_define", ["name": "listings", "columns": [["name": "listing_id", "type": "string", "required": true], ["name": "issued", "type": "date"], ["name": "value", "type": "number"]], "key": ["listing_id"]]),
            ("dataset_append", ["name": "listings", "rows": [["listing_id": "A-1", "issued": "2026-01-02", "value": 1200, "_request_id": "01HX", "_source_url": "https://example.com/p1"]]]),
            ("help_request", ["kind": "captcha", "reason": "what you need", "url": "https://example.com"]),
            ("help_wait", ["request_id": "h1", "wait_s": 45]),
            ("result_submit", ["result": ["dataset": "listings", "rows": 120, "notes": "s"], "evidence": ["/rows": ["01HX"]]]),
            ("box_release", [:]),
        ]
        for (tool, args) in examples {
            let definition = try #require(ToolCatalog.byName[tool])
            #expect(Schema.object(definition.spec).validate(args).isEmpty, "\(tool): \(Schema.object(definition.spec).validate(args))")
        }
        // E o texto do prompt realmente contém esses exemplos (não divergiram do código).
        let text = prompt()
        for needle in ["{\"name\":\"listings\",\"rows\":[{\"listing_id\":\"A-1\"", "\"columns\":[{\"name\":\"listing_id\",\"type\":\"string\",\"required\":true}", "\"key\":[\"listing_id\"]"] {
            #expect(text.contains(needle), "\(needle)")
        }
    }

    @Test func parentTextPerHarnessForAllThreeParents() {
        // Claude: o texto de sempre; as seções entram só com harness diferente de claude.
        #expect(OrchestrationText.skill == OrchestrationText.skill(harness: .claude))
        #expect(!OrchestrationText.skill.contains("agent_spawn") && !OrchestrationText.codexInstructions.contains("agent_spawn") && !OrchestrationText.openCodeInstructions.contains("agent_spawn"))
        for harness in [SubagentHarness.codex, .opencode] {
            let name = harness == .codex ? "Codex" : "OpenCode"
            for (parent, text, prefix) in [("claude", OrchestrationText.skill(harness: harness), ""), ("codex", OrchestrationText.codexInstructions(harness: harness), ""),
                                           ("opencode", OrchestrationText.openCodeInstructions(harness: harness), "racky_")] {
                #expect(text.contains("run as \(name) workers"), "\(parent)/\(harness)")
                #expect(text.contains("`\(prefix)agent_spawn`(harness: \"\(harness.rawValue)\"") && text.contains("`\(prefix)agent_wait`") && text.contains("`\(prefix)box_collect`"))
                #expect(text.contains("do NOT use the native"))
            }
        }
        for text in [OrchestrationText.skill(harness: .mixed), OrchestrationText.codexInstructions(harness: .mixed), OrchestrationText.openCodeInstructions(harness: .mixed)] {
            #expect(text.contains("native and separate sessions") && text.contains("agent_spawn") && text.contains("\"codex\"|\"opencode\"|\"claude\""))
        }
        // O texto do Claude chama o nativo de Agent; o do Codex, spawn_agent; o do OpenCode, task.
        #expect(OrchestrationText.skill(harness: .codex).contains("native Agent tool"))
        #expect(OrchestrationText.codexInstructions(harness: .codex).contains("native spawn_agent tool"))
        #expect(OrchestrationText.openCodeInstructions(harness: .codex).contains("native task tool"))
    }

    @Test func theBuilderPutsTheHarnessSectionInEachParentsInjection() throws {
        var options = OrchestrationInjectionBuilder.Options()
        options.workerSlots = 1
        options.harness = .opencode
        let claude = try OrchestrationInjectionBuilder.make(parentID: "p-aaaaaaaa", helperPath: helper, options: options)
        let skill = try #require(claude.pluginFiles.first { $0.name.hasSuffix("SKILL.md") })
        #expect(String(decoding: skill.contents, as: UTF8.self).contains("run as OpenCode workers"))
        let codex = try #require(OrchestrationInjectionBuilder.make(parentID: "p-aaaaaaaa", helperPath: helper, options: options, provider: .codex).codex)
        #expect(codex.instructions.contains("run as OpenCode workers"))
        let openCode = try #require(OrchestrationInjectionBuilder.make(parentID: "p-aaaaaaaa", helperPath: helper, options: options, provider: .opencode).openCode)
        #expect(openCode.instructions.contains("`racky_agent_spawn`"))
    }
}
