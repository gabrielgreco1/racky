import RackyDocker
import RackyStore
import RackyPlatform
import Foundation
import Testing

@testable import RackyCore

@Suite struct AgentAuthoringTests {
    @Test func parsesTheDraftBlockAndKeepsTheReplyClean() {
        let response = "Got it, short reviews with file and line.\n\n```draft\n{\"name\": \"PR Swift!\", \"description\": \"Reviews Swift PRs\", \"instructions\": \"Review the diff.\", \"tone\": \"short\", \"skills\": [\"code-review\"], \"computer\": false}\n```\n"
        let (reply, patch) = AgentAuthoring.parse(response)
        #expect(reply == "Got it, short reviews with file and line.")
        var draft = AuthoringDraft()
        draft.apply(try! #require(patch))
        #expect(draft.name == "pr-swift" && draft.description == "Reviews Swift PRs" && draft.skills == ["code-review"] && !draft.needsComputer)
        #expect(draft.instructions == "Review the diff." && draft.tone == "short")
    }

    @Test func aMissingOrBrokenBlockLeavesTheDraftAlone() {
        let plain = AgentAuthoring.parse("Just text, no block.")
        #expect(plain.reply == "Just text, no block." && plain.patch == nil)
        let broken = AgentAuthoring.parse("Reply\n```draft\n{not json\n```")
        #expect(broken.reply == "Reply" && broken.patch == nil)
        var draft = AuthoringDraft(); draft.name = "keep"
        draft.apply(["tone": "calm"])
        #expect(draft.name == "keep" && draft.tone == "calm", "só os campos que vieram mudam")
    }

    @Test func slugsAreSafeFolderNames() {
        #expect(AuthoringDraft.slug("Revisão de PRs / Swift") == "revisao-de-prs-swift")
        #expect(AuthoringDraft.slug("../etc") == "etc")
        #expect(AgentDefinition.isValidName(AuthoringDraft.slug("  QA Engineer  ")))
        #expect(AuthoringDraft.slug("***") == "")
    }

    @Test func promptCarriesTranscriptDraftAndUploadsWithinBudget() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("racky-auth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "# Review\nVerdict: ok\n".write(to: dir.appendingPathComponent("review.md"), atomically: true, encoding: .utf8)
        try Data([0x50, 0x4b, 0x00, 0x03, 0x04]).write(to: dir.appendingPathComponent("sheet.xlsx"))
        try String(repeating: "x", count: 30_000).write(to: dir.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)
        let uploads = ["review.md", "sheet.xlsx", "big.txt"].map { AuthoringUpload(url: dir.appendingPathComponent($0)) }
        #expect(uploads[0].text?.contains("Verdict") == true && uploads[1].text == nil)
        #expect(uploads[2].truncated && uploads[2].text?.count == AuthoringUpload.maxCharacters)
        var draft = AuthoringDraft(); draft.name = "pr-swift"
        let prompt = AgentAuthoring.prompt(
            messages: [AuthoringMessage(role: .user, text: "Review my Swift PRs"), AuthoringMessage(role: .assistant, text: "Short?"), AuthoringMessage(role: .user, text: "Yes")],
            uploads: uploads, draft: draft)
        #expect(prompt.contains("User: Review my Swift PRs") && prompt.contains("Assistant: Short?") && prompt.hasSuffix("Assistant:"))
        #expect(prompt.contains("\"name\" : \"pr-swift\"") && prompt.contains("Verdict: ok") && prompt.contains("sheet.xlsx") && prompt.contains("not readable as text"))
        #expect(prompt.count < AuthoringUpload.maxTotalCharacters + 5_000)
    }

    @Test func systemPromptsDifferByKindAndAskForTheDraftBlock() {
        let a = AgentAuthoring.systemPrompt(for: .agent), s = AgentAuthoring.systemPrompt(for: .skill)
        #expect(a.contains("```draft") && s.contains("```draft") && a.contains("computer") && s.contains("SKILL.md") && a != s)
    }

    @Test func claudeRunnerUsesNoToolsAndNoSavedSession() {
        let runner = ClaudeCLIAuthoringRunner(searchPath: "/nope", model: "sonnet")
        let args = runner.arguments(system: "SYS")
        #expect(args.starts(with: ["-p", "--no-session-persistence", "--tools", ""]) && args.contains("SYS") && args.suffix(2) == ["--model", "sonnet"])
    }

    @Test func runnerReportsAMissingClaude() async {
        let runner = ClaudeCLIAuthoringRunner(searchPath: "/definitely/not/here", override: "/definitely/not/claude")
        await #expect(throws: AuthoringError.claudeNotFound) { _ = try await runner.complete(system: "s", prompt: "p") }
    }
}

@Suite struct SkillStoreTests {
    @Test func createsSkillFolderWithReferencesAndExamples() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("racky-skills-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SkillStore(root: dir)
        try store.create(
            name: "silver-permits", description: "Builds the silver table: \"permits\"", body: "1. Compare with the schema",
            files: [("schema.json", Data("{}".utf8), "references"), ("austin.parquet", Data([1]), "examples"), ("../evil.txt", Data([2]), "references"), (".hidden", Data([3]), "x")])
        let folder = dir.appendingPathComponent("silver-permits")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("references/schema.json").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("examples/austin.parquet").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("references/evil.txt").path), "só o nome do arquivo conta")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("evil.txt").path) && !FileManager.default.fileExists(atPath: folder.appendingPathComponent("references/.hidden").path))
        let loaded = try store.load("silver-permits")
        #expect(loaded.description == "Builds the silver table: \"permits\"" && loaded.body == "1. Compare with the schema")
        #expect(store.list().map(\.name) == ["silver-permits"])
        #expect(throws: SkillStoreError.alreadyExists("silver-permits")) { try store.create(name: "silver-permits", description: "", body: "") }
        #expect(throws: SkillStoreError.invalidName("../x")) { try store.create(name: "../x", description: "", body: "") }
        try store.delete("silver-permits")
        #expect(store.list().isEmpty)
    }
}

@Suite struct AgentSiteSessionsTests {
    @Test func domainMatchingFollowsCookieRules() {
        let c = { (d: String) in AgentSiteSessions.Cookie(name: "s", value: "v", domain: d) }
        #expect(AgentSiteSessions.matches(c(".github.com"), host: "api.github.com"))
        #expect(AgentSiteSessions.matches(c("github.com"), host: "github.com"))
        #expect(!AgentSiteSessions.matches(c("github.com"), host: "evilgithub.com"))
        #expect(!AgentSiteSessions.matches(c("api.github.com"), host: "github.com"))
    }

    @Test func savesEncryptedInTheVaultAndLoadsOnlyUnexpiredCookiesOfThatHost() async throws {
        let h = try await VaultHarness(); defer { h.remove() }
        let now = Date().timeIntervalSince1970
        let cookies = [
            AgentSiteSessions.Cookie(name: "sid", value: "SECRET-SESSION-ID", domain: ".hubspot.com", expires: now + 3600, secure: true, httpOnly: true, sameSite: "Lax"),
            AgentSiteSessions.Cookie(name: "old", value: "gone", domain: "app.hubspot.com", expires: now - 10),
            AgentSiteSessions.Cookie(name: "tmp", value: "session-only", domain: "app.hubspot.com"),
            AgentSiteSessions.Cookie(name: "other", value: "NOT-MINE", domain: "github.com", expires: now + 3600),
        ]
        let expiry = try await AgentSiteSessions.save(vault: h.vault, agent: "qa", host: "app.hubspot.com", cookies: cookies)
        #expect(expiry.map { Int($0.timeIntervalSince1970) } == Int(now + 3600))
        let infos = try await h.vault.list()
        let info = try #require(infos.first { $0.name == "site:qa:app.hubspot.com" })
        #expect(info.name.hasPrefix("site:") && info.delivery == SecretDelivery.sidecarOnly.rawValue)
        let injection = try await h.vault.injection(for: [SecretSelection(secretID: info.id, envName: "COOKIES")])
        #expect(injection.environment.isEmpty, "site logado nunca vira variável de ambiente")
        let raw = try Data(contentsOf: StorePaths(root: h.root).databaseFile)
        #expect(raw.range(of: Data("SECRET-SESSION-ID".utf8)) == nil)
        let loaded = try await AgentSiteSessions.load(vault: h.vault, agent: "qa", host: "app.hubspot.com")
        #expect(Set(loaded.map(\.name)) == ["sid", "tmp"], "vencido e de outro site ficam de fora")
        #expect(loaded.first { $0.name == "sid" }?.runtimeObject["httpOnly"] as? Bool == true)
        try await AgentSiteSessions.save(vault: h.vault, agent: "qa", host: "app.hubspot.com", cookies: [AgentSiteSessions.Cookie(name: "sid", value: "NEW", domain: "app.hubspot.com", expires: now + 99)])
        let again = try await AgentSiteSessions.load(vault: h.vault, agent: "qa", host: "app.hubspot.com")
        #expect(again.map(\.value) == ["NEW"])
        #expect(try await AgentSiteSessions.load(vault: h.vault, agent: "qa", host: "nope.com").isEmpty)
    }

    @Test func parsesRuntimeCookieJSON() throws {
        let c = try #require(AgentSiteSessions.Cookie(json: ["name": "a", "value": "b", "domain": ".x.com", "expires": -1, "secure": true]))
        #expect(c.expires == nil && c.secure && c.path == "/")
        #expect(AgentSiteSessions.Cookie(json: ["name": "a"]) == nil)
    }
}

@Suite struct RackyAgentLaunchTests {
    private func tempStore() throws -> (AgentStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("racky-launch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (AgentStore(root: dir.appendingPathComponent("agents")), dir)
    }

    @Test func cavemanCompressionKeepsUrlsCodeAndNumbers() {
        let text = "The smoke test is basically failing when the permit type is empty, see `overrides.yaml` and https://example.com/a?b=1 for the 2019 backfill."
        let out = AgentMemoryText.compress(text)
        #expect(out == "smoke test is failing when permit type is empty, see `overrides.yaml` and https://example.com/a?b=1 for 2019 backfill.")
        #expect(AgentMemoryText.compress("Use ```\nthe code  stays\n``` here") == "Use ```\nthe code  stays\n``` here")
        #expect(AgentMemoryText.compress("   ") == "")
    }

    @Test func promptTeachesMemoryCommandsWithQuotedHelperAndTheIndex() {
        let agent = AgentDefinition(name: "qa-engineer", instructions: "Be QA.")
        let prompt = AgentCLIGenerator.prompt(for: agent, memoryIndex: "#3 smoke fails on empty type", memoryHelper: "/Applications/Racky App/racky")
        #expect(prompt.contains("#3 smoke fails on empty type"))
        let n = HookCommandLine.shellQuote("qa-engineer")
        #expect(prompt.contains("memory_search: run `\(HookCommandLine.shellQuote("/Applications/Racky App/racky")) memory search --agent \(n)"))
        #expect(prompt.contains("memory_read: run `") && prompt.contains("memory add --agent \(n) --title"))
        let empty = AgentCLIGenerator.prompt(for: agent, memoryHelper: "/h/racky")
        #expect(empty.contains("(empty)"))
        #expect(!AgentCLIGenerator.prompt(for: agent).contains("memory"), "sem o helper e sem memória, nada de memória no prompt")
    }

    @Test func buildsClaudeCodexAndOpenCodeVersionsFromTheStoreAtLaunch() async throws {
        let (store, dir) = try tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
        try store.create(AgentDefinition(name: "qa-engineer", description: "Tests", instructions: "Be QA.", tone: "Curto", variables: [AgentVariable(envName: "ZYTE_API_KEY", secretName: "zyte")]))
        var manifest = AgentAttachmentManifest(); manifest.add(AgentAttachment(kind: .dataset, title: "silver permits", reference: "01HZ"))
        try store.setAttachments("qa-engineer", manifest)
        let memory = try AgentMemoryStore(path: try store.memoryURL(for: "qa-engineer"))
        _ = try await memory.add(title: "milwaukee smoke", body: "empty type fails")
        let entry = ActivationRef(id: "racky:qa-engineer", kind: "agent", name: "qa-engineer", path: dir.appendingPathComponent("agents/qa-engineer/agent.md").path)
        let injection = try #require(await RackyAgentLaunch.build(refs: [entry, ActivationRef(id: "racky:ghost", kind: "agent", name: "ghost", path: "/nope")], agentStore: store, helperPath: "/h/racky"))
        #expect(injection.skipped == ["ghost"])
        guard case .string(let prompt)? = injection.agents["qa-engineer"]?["prompt"] else { Issue.record("no claude prompt"); return }
        #expect(prompt.contains("Be QA.") && prompt.contains("Curto") && prompt.contains("dataset: silver permits (01HZ)") && prompt.contains("#1 milwaukee smoke") && prompt.contains("ZYTE_API_KEY"))
        #expect(!prompt.contains("zyte"), "o nome do segredo no cofre também não vai no prompt")
        let generated = try #require(injection.rackyAgents.first)
        #expect(String(decoding: generated.codexTOML, as: UTF8.self).contains("developer_instructions") && String(decoding: generated.openCodeMarkdown, as: UTF8.self).contains("mode: subagent"))
        #expect(String(decoding: generated.codexTOML, as: UTF8.self).contains("memory search"))
    }

    @Test func codexGetsConfigFileFlagsAndOpenCodeGetsItsConfigDirInsideTheLaunchFolder() throws {
        let launch = URL(fileURLWithPath: "/tmp/abx/launch/run1", isDirectory: true)
        var inj = LaunchInjection(helperPath: "/h/racky")
        inj.rackyAgents = [
            RackyGeneratedAgent(name: "qa-engineer", description: "Tests \"all\"", codexTOML: Data("developer_instructions = \"x\"".utf8), openCodeMarkdown: Data("---\nmode: subagent\n---\nx".utf8)),
            RackyGeneratedAgent(name: "../evil", description: "", codexTOML: Data(), openCodeMarkdown: Data()),
        ]
        let codex = try inj.codexInjection(launchDirectory: launch)
        #expect(codex.injected.contains("agents.qa-engineer.config_file=\"/tmp/abx/launch/run1/agents-codex/agents/qa-engineer.toml\""))
        #expect(codex.injected.contains("agents.qa-engineer.description=\"Tests \\\"all\\\"\""))
        #expect(codex.files.map(\.name).filter { $0.hasPrefix("agents-codex") } == ["agents-codex/agents/qa-engineer.toml"], "nome inseguro fica de fora")
        let open = try inj.openCodeInjection(launchDirectory: launch)
        #expect(open.environment["OPENCODE_CONFIG_DIR"] == "/tmp/abx/launch/run1/agents-opencode")
        #expect(open.files.map(\.name) == ["agents-opencode/agent/qa-engineer.md"])
        let none = try LaunchInjection(helperPath: "/h/racky").openCodeInjection(launchDirectory: launch)
        #expect(none.environment.isEmpty && none.files.isEmpty)
    }
}

@Suite struct AgentSiteSessionsBackendTests {
    @Test func capturesOnlyTheHostsCookiesFromTheBrowserAndRestoresThemWithTheRuntimeShape() async throws {
        let backend = FakeBackend()
        await backend.setRuntime("cookies", [
            "cookies": [
                ["name": "sid", "value": "S1", "domain": ".hubspot.com", "path": "/", "expires": 4_102_444_800.0, "secure": true, "httpOnly": true, "sameSite": "Lax"],
                ["name": "other", "value": "X", "domain": "github.com", "path": "/", "expires": -1],
            ]
        ])
        let captured = try await AgentSiteSessions.capture(from: backend, host: "app.hubspot.com")
        #expect(captured.map(\.name) == ["sid"] && captured[0].httpOnly && captured[0].expires == 4_102_444_800)
        try await AgentSiteSessions.restore(captured, into: backend)
        try await AgentSiteSessions.restore([], into: backend)
        let calls = await backend.runtimeCalls
        #expect(calls.count == 2, "sem cookies não chama o runtime de novo")
        #expect(calls[1].op == "cookies" && calls[1].args["action"]?.string == "set")
        let sent = try #require(calls[1].args["cookies"]?.array?.first)
        #expect(sent["name"]?.string == "sid" && sent["domain"]?.string == ".hubspot.com" && sent["sameSite"]?.string == "Lax")
    }
}
