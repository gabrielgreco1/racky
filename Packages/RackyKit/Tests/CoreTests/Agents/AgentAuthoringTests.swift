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
