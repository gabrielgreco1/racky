import RackyProtocol
import Foundation
import Testing

@testable import RackyCore

private let helper = "/Applications/Racky.app/Contents/MacOS/racky"

@Suite struct ClaudeHookSettingsTests {
    private func parse(_ data: Data) throws -> [String: Any] { try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any]) }

    @Test func settingsRegisterEveryClaudeEventWithTheCanonicalCommandAndTimeout() throws {
        let root = try parse(try ClaudeHookSettings.settingsJSON(helperPath: helper))
        #expect(Set(root.keys) == ["hooks"])
        let hooks = try #require(root["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == Set(HookEventName.claudeRegistered.map(\.rawValue)))
        #expect(hooks.count == 12)
        for event in HookEventName.claudeRegistered {
            let groups = try #require(hooks[event.rawValue] as? [[String: Any]])
            #expect(groups.count == 1)
            let handlers = try #require(groups[0]["hooks"] as? [[String: Any]])
            #expect(handlers.count == 1)
            #expect(handlers[0]["type"] as? String == "command")
            #expect(handlers[0]["timeout"] as? Int == 5)
            #expect(handlers[0]["command"] as? String == "\"\(helper)\" hook --provider claude --event \(event.rawValue)")
            #expect(groups[0]["matcher"] == nil, "sem matcher: vale para toda ferramenta")
        }
    }

    @Test func outputIsDeterministicAndCarriesNoRunOrPaneIDs() throws {
        let a = try ClaudeHookSettings.settingsJSON(helperPath: helper)
        let b = try ClaudeHookSettings.settingsJSON(helperPath: helper)
        #expect(a == b)
        let text = String(decoding: a, as: UTF8.self)
        #expect(!text.contains("RACKY_") && !text.contains("python") && !text.contains("--run"))
    }

    @Test func hostileHelperPathsAreQuotedForTheShell() throws {
        let nasty = "/tmp/a \"b\" $(touch x) `id` \\z/racky"
        let cmd = HookCommandLine.command(helperPath: nasty, provider: .claude, event: .stop)
        #expect(cmd == "\"/tmp/a \\\"b\\\" \\$(touch x) \\`id\\` \\\\z/racky\" hook --provider claude --event Stop")
        let json = try parse(try ClaudeHookSettings.settingsJSON(helperPath: nasty))
        let hooks = try #require(json["hooks"] as? [String: Any])
        let stop = try #require((hooks["Stop"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])
        #expect(stop.first?["command"] as? String == cmd)
    }

    @Test func launchFileIsOwnerOnlySettingsJSONAndArgvFormIsSeparate() throws {
        let file = try ClaudeHookSettings.launchFile(helperPath: helper)
        #expect(file.name == "settings.json" && file.posixMode == 0o600)
        #expect(ClaudeHookSettings.injectedArguments(settingsPath: "/x/launch/r/settings.json") == ["--settings", "/x/launch/r/settings.json"])
    }
}

@Suite struct CodexHookConfigTests {
    private func fixtureHashes() throws -> [HookEventName: String] {
        CodexHookConfig.parseCurrentHashes(hooksList: try RealHooks.data("S-05/codex-hooks-list-sessionflags.json"))
    }

    @Test func realHooksListFixtureYieldsTheFiveProbedHashes() throws {
        let hashes = try fixtureHashes()
        #expect(Set(hashes.keys) == [.sessionStart, .userPromptSubmit, .preToolUse, .postToolUse, .stop])
        #expect(hashes[.stop] == "sha256:719c5beac76c364484396e2f05d5b92cf497bdc3b242a89d4b100a26d014ffbc")
        #expect(hashes.values.allSatisfy { CodexHookConfig.isValidHash($0) })
    }

    @Test func parsesTheAppServerResponseShapeAndIgnoresOtherSources() throws {
        let response = """
        {"id":2,"result":{"data":[{"cwd":"/x","hooks":[
          {"key":"/<session-flags>/config.toml:stop:0:0","source":"sessionFlags","currentHash":"sha256:\(String(repeating: "a", count: 64))"},
          {"key":"/Users/u/.codex/hooks.json:stop:0:0","source":"user","currentHash":"sha256:\(String(repeating: "b", count: 64))"},
          {"key":"/<session-flags>/config.toml:session_start:0:0","source":"sessionFlags","currentHash":"not-a-hash"}
        ]}]}}
        """
        let hashes = CodexHookConfig.parseCurrentHashes(hooksList: Data(response.utf8))
        #expect(hashes == [.stop: "sha256:" + String(repeating: "a", count: 64)])
        #expect(CodexHookConfig.parseCurrentHashes(hooksList: Data("garbage".utf8)).isEmpty)
    }

    @Test func hookOverridesDefineEveryCodexEventWithConstantCommandAndTimeout() {
        let args = CodexHookConfig.hookOverrides(helperPath: helper)
        #expect(args.count == 16)
        #expect(stride(from: 0, to: args.count, by: 2).allSatisfy { args[$0] == "-c" })
        let values = stride(from: 1, to: args.count, by: 2).map { args[$0] }
        #expect(values.count == HookEventName.codexRegistered.count)
        for (event, value) in zip(HookEventName.codexRegistered, values) {
            let expectedCommand = CodexAdapter.tomlString("\"\(helper)\" hook --provider codex --event \(event.rawValue)")
            #expect(value == "hooks.\(event.rawValue)=[{hooks=[{type=\"command\",command=\(expectedCommand),timeout=5}]}]")
        }
        #expect(args == CodexHookConfig.hookOverrides(helperPath: helper), "estável: o hash de trust não muda entre lançamentos")
        #expect(!args.joined().contains("RACKY_RUN_ID") && !args.joined().contains("dangerously"))
    }

    @Test func trustOverrideUsesTheInlineTableFormAndTheSessionFlagsKeys() throws {
        let hashes = try fixtureHashes()
        let override = try CodexHookConfig.trustOverride(hashes: hashes)
        #expect(override.count == 2 && override[0] == "-c")
        let value = override[1]
        #expect(value.hasPrefix("hooks.state={\"/<session-flags>/config.toml:session_start:0:0\"={trusted_hash=\"sha256:"))
        #expect(value.hasSuffix("\"}}"))
        for event in [HookEventName.sessionStart, .userPromptSubmit, .preToolUse, .postToolUse, .stop] {
            #expect(value.contains("\"\(CodexHookConfig.stateKey(event))\"={trusted_hash=\"\(hashes[event] ?? "?")\"}"))
        }
        #expect(!value.contains("hooks.state.\""), "a forma pontilhada é ignorada pelo Codex (S-05)")
        #expect(try CodexHookConfig.trustOverride(hashes: [:]).isEmpty)
        #expect(CodexHookConfig.stateKey(.userPromptSubmit) == "/<session-flags>/config.toml:user_prompt_submit:0:0")
        #expect(CodexHookConfig.stateKey(.subagentStop) == "/<session-flags>/config.toml:subagent_stop:0:0")
    }

    @Test func malformedHashIsRefusedAndNeverReachesTheCommandLine() {
        #expect(throws: CodexHookConfig.Failure.invalidHash("sha256:zz")) { try CodexHookConfig.trustOverride(hashes: [.stop: "sha256:zz"]) }
        #expect(throws: CodexHookConfig.Failure.self) { try CodexHookConfig.trustOverride(hashes: [.stop: "sha256:" + String(repeating: "A", count: 64)]) }
        #expect(throws: CodexHookConfig.Failure.self) { try CodexHookConfig.trustOverride(hashes: [.stop: "x\"}); rm -rf /"]) }
    }

    @Test func argumentsWithoutHashesAreUntrustedSoTheCallerFallsBackToRolloutEstimated() throws {
        let untrusted = try CodexHookConfig.arguments(helperPath: helper, hashes: [:])
        #expect(!untrusted.trusted && untrusted.arguments.count == 16)
        let trusted = try CodexHookConfig.arguments(helperPath: helper, hashes: try fixtureHashes())
        #expect(trusted.trusted && trusted.arguments.count == 18)
        #expect(trusted.arguments.starts(with: untrusted.arguments))
        #expect(!trusted.arguments.contains("--dangerously-bypass-hook-trust"))
    }

    @Test func eventSetsMatchTheSpec() {
        #expect(HookEventName.codexRegistered.map(\.rawValue) == [
            "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "SubagentStart", "SubagentStop",
        ])
        #expect(!HookEventName.codexRegistered.contains(.notification) && !HookEventName.codexRegistered.contains(.stopFailure))
    }
}
