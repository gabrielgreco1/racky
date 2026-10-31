import Foundation
import Testing

@testable import RackyProtocol

/// F12: o gatilho de spawn (heurística de web e decisão por modo).
@Suite struct SubagentSpawnGuardTests {
    @Test(arguments: [
        "spawna um sub agent pra estudar o site http://127.0.0.1:8080/listings",
        "Study the listings portal of Houston and report the search form fields",
        "open https://www.houstontx.gov/listings and list the endpoints",
        "find the hidden API behind the search",
        "scrape the listings from example.com",
        "crawl aca-prod.accela.com for the fee schedule",
        "navegar até o portal da prefeitura",
        "raspar os dados da página",
        "check localhost:3000 and report the title",
        "Validate the data source at 10.0.0.5:8443",
    ])
    func webWorkIsDetected(_ text: String) {
        #expect(SubagentSpawnGuard.involvesWeb(text), "\(text)")
    }

    @Test(arguments: [
        "refactor the parser and run the unit tests",
        "read Package.swift and summarize the targets",
        "fix the failing test in ReducerTests.swift and main.rs",
        "write a changelog entry for the release",
        "review the diff for style problems",
        "campsite inventory spreadsheet",
    ])
    func codeAndWritingWorkIsNot(_ text: String) {
        #expect(!SubagentSpawnGuard.involvesWeb(text), "\(text)")
    }

    @Test func workerSlotsAreRecognized() {
        #expect(SubagentSpawnGuard.isWorker("racky-worker-1") && SubagentSpawnGuard.isWorker("racky-worker-20"))
        #expect(!SubagentSpawnGuard.isWorker("general-purpose") && !SubagentSpawnGuard.isWorker(nil) && !SubagentSpawnGuard.isWorker("Explore"))
    }

    @Test func decisionByModeAndSubagentType() {
        let web = SubagentSpawnGuard.Input(subagentType: "general-purpose", prompt: "study the site https://example.com/listings", description: "Study listings site")
        let plain = SubagentSpawnGuard.Input(subagentType: "general-purpose", prompt: "refactor the parser", description: "Refactor")
        let worker = SubagentSpawnGuard.Input(subagentType: "racky-worker-2", prompt: "open https://example.com/listings", description: "Phoenix")
        let noType = SubagentSpawnGuard.Input(subagentType: nil, prompt: "browse the portal", description: "")
        guard case .block(let reason) = SubagentSpawnGuard.decide(mode: .full, web) else { Issue.record("full must block web subagents"); return }
        #expect(reason.contains("boxes_reserve") && reason.contains("racky-worker-N") && reason.contains("subagent_type"))
        #expect(SubagentSpawnGuard.decide(mode: .ask, web) == .askUser)
        #expect(SubagentSpawnGuard.decide(mode: .ask, noType) == .askUser && SubagentSpawnGuard.decide(mode: .full, noType) != .allow)
        #expect(SubagentSpawnGuard.decide(mode: .off, web) == .allow)
        for mode in [SubagentComputersMode.ask, .full] {
            #expect(SubagentSpawnGuard.decide(mode: mode, worker) == .allow)
            #expect(SubagentSpawnGuard.decide(mode: mode, plain) == .allow)
        }
    }

    @Test func denyOutputIsAPreToolUseDeny() throws {
        let text = SubagentSpawnGuard.denyOutput(reason: "use boxes_reserve")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let output = try #require(object["hookSpecificOutput"] as? [String: Any])
        #expect(output["hookEventName"] as? String == "PreToolUse" && output["permissionDecision"] as? String == "deny")
        #expect(output["permissionDecisionReason"] as? String == "use boxes_reserve")
    }

    @Test func toolInputParsesFromTheRealPayloadShape() {
        let input = SubagentSpawnGuard.Input(toolInput: [
            "description": "Ping child-a agent", "prompt": "Reply to this task as child-a.", "subagent_type": "child-a", "run_in_background": false,
        ])
        #expect(input.subagentType == "child-a" && input.description == "Ping child-a agent" && input.prompt.hasPrefix("Reply"))
        #expect(SubagentSpawnGuard.toolNames.contains("Agent") && SubagentSpawnGuard.matcher == "Agent|Task")
    }
}
