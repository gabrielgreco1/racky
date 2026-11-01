import Foundation
import Testing

@testable import RackyProtocol

private func spikePayloads(_ relative: String) throws -> [[String: Any]] {
    var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while dir.path != "/", !FileManager.default.fileExists(atPath: dir.appendingPathComponent("Tests/SpikeFixtures").path) {
        dir.deleteLastPathComponent()
    }
    let data = try Data(contentsOf: dir.appendingPathComponent("Tests/SpikeFixtures/\(relative)"))
    let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    return (root["events"] as! [[String: Any]]).map { $0["payload"] as! [String: Any] }
}

@Suite struct HookPayloadReducerTests {
    @Test func realClaudePayloadsKeepOnlyTheSpecFields() throws {
        for raw in try spikePayloads("S-05/claude-settings-hooks-payloads.json") {
            let reduced = HookPayloadReducer.reduce(raw)
            #expect(reduced.sessionID == raw["session_id"] as? String)
            #expect(reduced.transcriptPath == raw["transcript_path"] as? String)
            let encoded = String(decoding: try HookCodec.encoder().encode(reduced), as: UTF8.self)
            #expect(!encoded.contains("tool_response") && !encoded.contains("\"prompt\""))
            if raw["hook_event_name"] as? String == "UserPromptSubmit" {
                #expect(!encoded.contains("Run the shell command"), "o texto do prompt nunca é guardado")
            }
            #expect(encoded.utf8.count < HookLimits.maxStoredPayloadBytes)
        }
    }

    @Test func stopCarriesTheLastAssistantMessageAndBashCarriesItsShortTarget() throws {
        let payloads = try spikePayloads("S-05/claude-settings-hooks-payloads.json")
        let stop = HookPayloadReducer.reduce(try #require(payloads.first { $0["hook_event_name"] as? String == "Stop" }))
        #expect(stop.lastAssistantMessage == "DONE")
        let pre = HookPayloadReducer.reduce(try #require(payloads.first { $0["hook_event_name"] as? String == "PreToolUse" }))
        #expect(pre.toolName == "Bash" && pre.toolTarget == "echo spike-ok")
        #expect(pre.toolUseID?.hasPrefix("toolu_") == true)
        let end = HookPayloadReducer.reduce(try #require(payloads.first { $0["hook_event_name"] as? String == "SessionEnd" }))
        #expect(end.reason == "other")
    }

    @Test func fileToolsUseTheBaseNameAndSubagentPayloadsCarryAgentFields() throws {
        let write = HookPayloadReducer.reduce(try #require(try spikePayloads("S-05/claude-permission-request.json").first { $0["hook_event_name"] as? String == "PermissionRequest" }))
        #expect(write.toolName == "Write" && write.toolTarget == "x.txt")
        let sub = try spikePayloads("S-08/subagent-hook-payloads.json")
        let start = HookPayloadReducer.reduce(try #require(sub.first { $0["hook_event_name"] as? String == "SubagentStart" }))
        #expect(start.agentID == "a9d32b813be6acccc" && start.agentType == "child-a")
        let stop = HookPayloadReducer.reduce(try #require(sub.first { $0["hook_event_name"] as? String == "SubagentStop" }))
        #expect(stop.lastAssistantMessage == "I_AM_A")
        let childTool = HookPayloadReducer.reduce(try #require(sub.first { ($0["agent_id"] as? String) != nil && $0["hook_event_name"] as? String == "PreToolUse" }))
        #expect(childTool.agentID != nil && childTool.toolName?.hasPrefix("mcp__") == true)
        #expect(childTool.mcpServer != nil)
        let parentTool = HookPayloadReducer.reduce(try #require(sub.first { $0["tool_name"] as? String == "Agent" }))
        #expect(parentTool.agentID == nil && parentTool.toolUseID != nil)
    }

    @Test func realCodexPayloadsCarryRolloutPathAndTurnID() throws {
        let payloads = try spikePayloads("S-05/codex-hook-payloads.json")
        let start = HookPayloadReducer.reduce(payloads[0])
        #expect(start.transcriptPath?.contains("/.codex/sessions/") == true && start.model != nil && start.source == "startup")
        let prompt = HookPayloadReducer.reduce(payloads[1])
        #expect(prompt.turnID != nil)
    }

    @Test func garbageAndOversizedInputsAreHandled() {
        #expect(HookPayloadReducer.reduce(Data()) == ReducedHookPayload())
        #expect(HookPayloadReducer.reduce(Data("not json".utf8)) == ReducedHookPayload())
        #expect(HookPayloadReducer.reduce(Data("[1,2,3]".utf8)) == ReducedHookPayload())
        let long = String(repeating: "x", count: 100_000)
        let reduced = HookPayloadReducer.reduce(["last_assistant_message": long, "message": long, "tool_name": "Bash", "tool_input": ["command": long], "cwd": long])
        #expect(reduced.lastAssistantMessage?.count == 500 && reduced.message?.count == 500)
        #expect(reduced.toolTarget?.count == 160 && (reduced.cwd?.count ?? 0) <= 1024)
    }

    @Test func stopFailureErrorIsFoundUnderTheCandidateFieldNames() {
        #expect(HookPayloadReducer.reduce(["error": "rate_limit"]).error == "rate_limit")
        #expect(HookPayloadReducer.reduce(["error": ["message": "Usage limit reached"]]).error == "Usage limit reached")
        #expect(HookPayloadReducer.reduce(["error_message": "boom"]).error == "boom")
        #expect(HookPayloadReducer.reduce(["session_id": "s"]).error == nil)
    }
}

@Suite struct HookTextSanitizerTests {
    @Test func stripsAnsiControlsAndCollapsesWhitespace() {
        let raw = "\u{1B}[1;32mDone\u{1B}[0m \u{1B}]0;title\u{07}  all\ttests\n\npassed\u{0}\u{7}\u{1B}(B ✓ "
        #expect(HookTextSanitizer.sanitize(raw) == "Done all tests passed ✓")
        #expect(HookTextSanitizer.sanitize("\u{1B}]8;;https://x\u{1B}\\link\u{1B}]8;;\u{1B}\\") == "link")
        #expect(HookTextSanitizer.sanitize("   \n\t ") == "")
        #expect(HookTextSanitizer.sanitize("a\u{85}b\u{7F}c") == "abc")
    }

    @Test func truncatesAtFiveHundredScalarsWithoutSplittingAGrapheme() {
        #expect(HookTextSanitizer.sanitize(String(repeating: "a", count: 501)).count == 500)
        let family = "👨‍👩‍👧"  // um grafema, 5 pontos de código
        let text = String(repeating: "a", count: 497) + family
        let cut = HookTextSanitizer.sanitize(text)
        #expect(cut.unicodeScalars.count <= 500)
        #expect(!cut.contains(family), "o grafema que não cabe inteiro sai inteiro")
        #expect(HookTextSanitizer.sanitize(String(repeating: "é", count: 600)).unicodeScalars.count == 500)
    }
}

@Suite struct HookWireTests {
    @Test func envelopeRoundTripsAndMarkersAndGarbageAreClassified() throws {
        let e = HookEnvelope(provider: .codex, event: "Stop", runID: UUID().uuidString, paneID: UUID().uuidString, atNs: 42, payload: .init(lastAssistantMessage: "x"))
        let line = try HookCodec.line(e)
        #expect(!line.contains(0x0A))
        #expect(HookSpoolLine.parse(line) == .event(e))
        let marker = try HookCodec.encoder().encode(HookSpoolMarker(dropped: 9, atNs: 1))
        #expect(HookSpoolLine.parse(marker) == .marker(HookSpoolMarker(dropped: 9, atNs: 1)))
        if case .invalid = HookSpoolLine.parse(Data("{".utf8)) {} else { Issue.record("truncated JSON must be invalid") }
        if case .invalid = HookSpoolLine.parse(Data("{\"v\":1}".utf8)) {} else { Issue.record("missing fields must be invalid") }
        var future = e; future.v = 99
        if case .invalid = HookSpoolLine.parse(try HookCodec.line(future)) {} else { Issue.record("newer envelope version must be invalid") }
    }

    @Test func canonicalConstants() {
        #expect(HookLimits.deliveryTimeoutMs == 200 && HookLimits.cliHookTimeoutSeconds == 5)
        #expect(HookLimits.spoolFileLimitBytes == 4 * 1024 * 1024 && HookLimits.lastMessageMaxCharacters == 500)
        #expect(HookEventName.claudeRegistered.count == 12)
    }
}
