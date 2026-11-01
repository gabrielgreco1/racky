import RackyProtocol
import RackyStore
import Foundation
import Testing

@testable import RackyCore

// T4-02 (AC-901…905): índice da Library por fonte, preview sob demanda, ativação aditiva por sessão e o plugin gerado por
// lançamento. Tudo sobre uma home de mentira em diretório temporário; nada toca `~/.claude`, `~/.codex` nem `~/.agents`.

private func items(_ f: CatalogFixture, projects: [URL] = []) -> [LibraryEntry] {
    let scan = CatalogScanner.scan(CatalogRoots(home: f.home, projectRoots: projects))
    return LibraryIndex.items(from: scan.items.map { $0 })
}

@Suite struct LibraryIndexTests {
    /// AC-901: contagens por fonte batem com o disco; cada item tem fonte e CLIs.
    @Test func countsPerSourceMatchTheDiskAndEachItemHasSourceAndClients() throws {
        let f = try CatalogFixture(); defer { f.remove() }
        try f.populate()
        try f.write(".config/opencode/agent/reviewer.md", "---\ndescription: Reviews diffs\nmode: subagent\n---\nBODY\n")
        try f.write(".codex/prompts/ship.md", "---\ndescription: Ship it\n---\nBODY\n")
        let all = items(f, projects: [f.project])
        let agents = LibraryIndex.counts(all, kind: .agent)
        #expect(agents[.claude] == 4 && agents[.codex] == 3 && agents[.plugins] == 1 && agents[.project] == 1 && agents[.opencode] == 1)
        let skills = LibraryIndex.counts(all, kind: .skill)
        #expect(skills[.claude] == 3 && skills[.agents] == 2 && skills[.plugins] == 1 && skills[.codex] == 2, "skills do Claude (zip incluso), ~/.agents, plugin e legado + prompts do Codex")
        #expect(all.allSatisfy { !$0.clients.isEmpty })
        let reviewer = try #require(all.first { $0.name == "reviewer" })
        #expect(reviewer.clients == [.opencode] && reviewer.category == .opencode)
        let prompt = try #require(all.first { $0.name == "prompts:ship" })
        #expect(prompt.clients == [.codex] && prompt.category == .codex && prompt.kind == .skill)
        #expect(all.first { $0.name == "vercel:nextjs" }?.category == .plugins)
    }

    @Test func searchFiltersByNameDescriptionAndSourceAndKeepsSections() throws {
        let f = try CatalogFixture(); defer { f.remove() }
        try f.populate()
        let all = items(f, projects: [f.project])
        #expect(LibraryIndex.filter(all, kind: .agent, category: nil, query: "pipelines").map(\.name).contains("data-engineer"))
        #expect(LibraryIndex.filter(all, kind: .agent, category: .project, query: "").map(\.name) == ["data-engineer"])
        #expect(LibraryIndex.filter(all, kind: .skill, category: nil, query: "REVIEW").allSatisfy { $0.kind == .skill && $0.name.contains("review") || ($0.summary ?? "").lowercased().contains("review") })
        #expect(LibraryIndex.filter(all, kind: .skill, category: nil, query: "~/.agents").allSatisfy { $0.category == .agents })
        #expect(LibraryIndex.filter(all, kind: .agent, category: nil, query: "zzz").isEmpty)
    }

    @Test func frontmatterFieldsBecomeModelToolsSkillsAndServers() throws {
        let f = try CatalogFixture(); defer { f.remove() }
        try f.write(".claude/agents/scout.md", "---\nname: scout\ndescription: Scouts portals\nmodel: sonnet\ntools: Read, Grep\nskills:\n  - portal-playbook\n  - webscraping-expert\nmcpServers:\n  racky:\n    command: racky\n---\nBODY\n")
        let scout = try #require(items(f).first { $0.name == "scout" })
        #expect(scout.model == "sonnet" && scout.tools == ["Read", "Grep"] && scout.skills == ["portal-playbook", "webscraping-expert"])
        #expect(scout.mcpServers == ["racky"])
    }

    @Test func activationFollowsTheNativeLoadingRules() throws {
        let f = try CatalogFixture(); defer { f.remove() }
        try f.populate()
        try f.write(".claude/skills/proj-skill/SKILL.md", "---\nname: proj-skill\n---\n", under: f.project)
        try f.write(".claude/skills/other-skill/SKILL.md", "---\nname: other-skill\n---\n", under: f.project.deletingLastPathComponent().appendingPathComponent("other", isDirectory: true))
        let other = f.project.deletingLastPathComponent().appendingPathComponent("other", isDirectory: true)
        let all = items(f, projects: [f.project, other])
        func item(_ name: String, _ category: LibraryCategory? = nil) throws -> LibraryEntry { try #require(all.first { $0.name == name && (category == nil || $0.category == category) }) }
        let folder = f.project.path
        #expect(try item("code-review", .claude).activation(sessionFolder: folder, added: []) == .alwaysOn)
        #expect(try item("vercel:nextjs").activation(sessionFolder: folder, added: []) == .alwaysOn)
        #expect(try item("proj-skill").activation(sessionFolder: folder, added: []) == .alwaysOn, "skill do projeto da própria sessão")
        let foreign = try item("other-skill")
        #expect(foreign.activation(sessionFolder: folder, added: []) == .off)
        #expect(foreign.activation(sessionFolder: folder, added: [foreign.id]) == .thisSession)
        let shared = try item("shared")
        #expect(shared.activation(sessionFolder: folder, added: []) == .off && shared.activation(sessionFolder: nil, added: [shared.id]) == .thisSession)
        #expect(try item("only-codex").activation(sessionFolder: folder, added: []) == .unavailable("Not available in Claude Code"))
        #expect(try item("packed").activation(sessionFolder: folder, added: []) == .unavailable("Packaged skills can't be added yet."))
        #expect(try item("broken").activation(sessionFolder: folder, added: []).canToggle == false)
        #expect(LibraryActivation.alwaysOn.canToggle == false && LibraryActivation.off.canToggle && LibraryActivation.thisSession.canToggle)
    }
}

@Suite struct LibraryPreviewTests {
    @Test func previewShowsFrontmatterBodyAndSkillFilesWithScriptsMarked() throws {
        let f = try CatalogFixture(); defer { f.remove() }
        try f.write(".claude/skills/searchkit/SKILL.md", "---\nname: searchkit\ndescription: Query the search API\n---\n\n# Playbook\nstep one\n")
        try f.write(".claude/skills/searchkit/notes/readme.txt", "notes")
        try f.write(".claude/skills/searchkit/fetch.py", "print('hi')")
        let skill = try #require(items(f).first { $0.name == "searchkit" })
        let preview = LibraryPreviewLoader.load(skill)
        #expect(preview.fields.map(\.key) == ["description", "name"] && preview.body == "# Playbook\nstep one\n")
        #expect(preview.files.map(\.path) == ["SKILL.md", "fetch.py", "notes/readme.txt"])
        #expect(preview.files.first { $0.path == "fetch.py" }?.isScript == true && preview.hasScripts)
        #expect(preview.files.first { $0.path == "notes/readme.txt" }?.isScript == false)
        #expect(preview.error == nil && !preview.truncated)
    }

    @Test func tomlAgentsShowInstructionsAsBodyAndInvalidFilesReportTheError() throws {
        let f = try CatalogFixture(); defer { f.remove() }
        try f.populate()
        let all = items(f)
        let toml = LibraryPreviewLoader.load(try #require(all.first { $0.name == "data-engineer" && $0.category == .codex }))
        #expect(toml.body.contains("BODY-MARKER-TOML") && toml.fields.contains { $0.key == "description" })
        let broken = LibraryPreviewLoader.load(try #require(all.first { $0.name == "broken" }))
        #expect(broken.error?.hasPrefix("Invalid frontmatter (line") == true)
    }

    @Test func bodyOfFollowsTheClosingMarkerAndHandlesFilesWithoutFrontmatter() {
        #expect(FrontmatterParser.body(of: "---\nname: x\n---\n\nhello\nworld") == "hello\nworld")
        #expect(FrontmatterParser.body(of: "no frontmatter\nat all") == "no frontmatter\nat all")
        #expect(FrontmatterParser.body(of: "---\nname: x\nnever closed") == "")
    }

    @Test func largeFilesAreCutAtTheLimit() throws {
        let f = try CatalogFixture(); defer { f.remove() }
        try f.write(".claude/agents/big.md", "---\nname: big\n---\n" + String(repeating: "x", count: LibraryPreviewLoader.bodyLimit + 500))
        let preview = LibraryPreviewLoader.load(try #require(items(f).first { $0.name == "big" }))
        #expect(preview.truncated && preview.body.count <= LibraryPreviewLoader.bodyLimit)
    }
}

@Suite struct SessionLibraryInjectionTests {
    /// AC-903 (parte Core): o plugin do lançamento leva a skill ativada e nada global muda.
    @Test func generatedPluginHoldsOnlyTheActivatedSkillAndTouchesNothingGlobal() throws {
        let f = try CatalogFixture(); defer { f.remove() }
        try f.write(".agents/skills/portal-playbook/SKILL.md", "---\nname: portal-playbook\ndescription: Search\n---\nstep\n")
        let script = try f.write(".agents/skills/portal-playbook/run.sh", "echo hi")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try f.write(".agents/skills/other/SKILL.md", "---\nname: other\n---\n")
        let before = f.fingerprint()
        let skill = try #require(items(f).first { $0.name == "portal-playbook" })
        let built = try #require(SessionLibraryBuilder.build([ActivationRef(skill)]))
        let names = built.pluginFiles.map(\.name)
        #expect(names.contains("plugin-session/.claude-plugin/plugin.json"))
        #expect(names.contains("plugin-session/skills/portal-playbook/SKILL.md") && names.contains("plugin-session/skills/portal-playbook/run.sh"))
        #expect(!names.contains { $0.contains("/other/") })
        #expect(built.pluginFiles.first { $0.name.hasSuffix("run.sh") }?.posixMode == 0o700)
        let manifestFile = try #require(built.pluginFiles.first { $0.name.hasSuffix("plugin.json") })
        let manifest = try #require(JSONSerialization.jsonObject(with: manifestFile.contents) as? [String: Any])
        #expect(manifest["name"] as? String == "racky-session")
        #expect(f.fingerprint() == before, "a origem só foi lida")
    }

    @Test func activatedAgentsBecomeAgentsJSONAndMergeWithExistingOnesWithoutOverridingThem() throws {
        let f = try CatalogFixture(); defer { f.remove() }
        try f.write(".claude/agents/scout.md", "---\nname: scout\ndescription: Scouts portals\nmodel: sonnet\ntools: Read, Grep\nskills: [searchkit]\n---\nYou scout portals.\n")
        let agent = try #require(items(f).first { $0.name == "scout" })
        let built = try #require(SessionLibraryBuilder.build([ActivationRef(agent)]))
        #expect(built.pluginFiles.isEmpty && built.agents.keys.sorted() == ["scout"])
        let base = Data(#"{"racky-worker-1":{"description":"w","prompt":"p"},"scout":{"description":"already there","prompt":"keep"}}"#.utf8)
        let merged = try #require(built.mergedAgentsJSON(into: base))
        let object = try #require(JSONSerialization.jsonObject(with: merged) as? [String: [String: Any]])
        #expect(object.keys.sorted() == ["racky-worker-1", "scout"])
        #expect(object["scout"]?["description"] as? String == "already there", "o agente que já veio vence")
        let aloneData = try #require(built.mergedAgentsJSON(into: nil))
        let alone = try #require(JSONSerialization.jsonObject(with: aloneData) as? [String: [String: Any]])
        #expect(alone["scout"]?["prompt"] as? String == "You scout portals." && alone["scout"]?["model"] as? String == "sonnet")
        #expect(alone["scout"]?["tools"] as? [String] == ["Read", "Grep"] && alone["scout"]?["skills"] as? [String] == ["searchkit"])
    }

    @Test func missingOrUnreadableSourcesAreSkippedNotFatal() throws {
        let gone = ActivationRef(id: "x", kind: "skill", name: "gone", path: "/nonexistent/skills/gone/SKILL.md")
        #expect(SessionLibraryBuilder.build([gone]) == nil)
        #expect(SessionLibraryBuilder.build([]) == nil)
    }

    /// O argv do Claude ganha o segundo `--plugin-dir`, o `--agents` somado, e o validador aceita (tudo dentro do diretório do lançamento).
    @Test func claudeArgvCarriesThePluginDirAndTheMergedAgentsInsideTheLaunchDirectory() throws {
        let f = try CatalogFixture(); defer { f.remove() }
        try f.write(".agents/skills/portal-playbook/SKILL.md", "---\nname: portal-playbook\n---\nx\n")
        try f.write(".claude/agents/scout.md", "---\nname: scout\ndescription: d\n---\nbody\n", under: f.project)
        let all = items(f, projects: [f.project])
        let library = try #require(SessionLibraryBuilder.build(all.filter { $0.name == "portal-playbook" || $0.name == "scout" }.map(ActivationRef.init)))
        var injection = LaunchInjection(helperPath: "/Applications/Racky.app/Contents/MacOS/racky", claudePluginFiles: [
            LaunchFile(name: "plugin/.claude-plugin/plugin.json", contents: Data(#"{"name":"racky-app"}"#.utf8)),
        ], claudeAgentsJSON: Data(#"{"w":{"description":"d","prompt":"p"}}"#.utf8))
        injection.claudeSessionLibrary = library
        let plan = try LaunchSamples.plan(LaunchSpec(provider: .claude, initialPrompt: "hello"), capabilities: LaunchSamples.helpCapabilities(.claude), slice: .slice2, injection: injection)
        let dir = LaunchSamples.launchDirectory.standardizedFileURL.path
        let injected = plan.argv.injected
        let pluginDirs = injected.enumerated().filter { $0.element == "--plugin-dir" }.map { injected[$0.offset + 1] }
        #expect(pluginDirs == ["\(dir)/plugin", "\(dir)/plugin-session"])
        let agentsIndex = try #require(injected.firstIndex(of: "--agents"))
        let agents = try #require(JSONSerialization.jsonObject(with: Data(injected[agentsIndex + 1].utf8)) as? [String: Any])
        #expect(agents.keys.sorted() == ["scout", "w"])
        #expect(plan.files.map(\.name).contains("plugin-session/skills/portal-playbook/SKILL.md"))
        #expect(InjectionValidator.violations(injected: injected, launchDirectory: LaunchSamples.launchDirectory, slice: .slice2).isEmpty)
        // O prompt posicional continua depois de `--` (as flags variádicas não o engolem).
        #expect(plan.argv.prompt == ["--", "hello"])
    }

    @Test func materializingWritesThePluginIntoTheLaunchDirectoryOnly() throws {
        let f = try CatalogFixture(); defer { f.remove() }
        try f.write(".agents/skills/s1/SKILL.md", "---\nname: s1\n---\nx\n")
        let before = f.fingerprint()
        let skill = try #require(items(f).first { $0.name == "s1" })
        let library = try #require(SessionLibraryBuilder.build([ActivationRef(skill)]))
        let launch = f.base.appendingPathComponent("run/launch/abc", isDirectory: true)
        var injection = LaunchInjection(helperPath: "/h/racky")
        injection.claudeSessionLibrary = library
        let built = try injection.claudeInjection(launchDirectory: launch)
        let plan = LaunchPlan(
            provider: .claude, argv: ResolvedArgv(executable: ["claude"], identity: [], profile: [], injected: built.injected, prompt: []), environment: [:], envKeys: [],
            cwd: "/", nativeConversationID: nil, capture: .none, skipsPermissions: nil, warnings: [], files: built.files, launchDirectory: launch,
            profile: nil, spec: LaunchSpec(provider: .claude))
        try LaunchFileWriter.materialize(plan)
        #expect(FileManager.default.fileExists(atPath: launch.appendingPathComponent("plugin-session/.claude-plugin/plugin.json").path))
        #expect(FileManager.default.fileExists(atPath: launch.appendingPathComponent("plugin-session/skills/s1/SKILL.md").path))
        let native = { (lines: [String]) in lines.filter { $0.contains("/home/") || $0.contains("/repo|") } }
        #expect(native(f.fingerprint()) == native(before), "nada nas pastas nativas mudou")
    }
}

@Suite struct SessionActivationStoreTests {
    @Test func togglesPersistPerSessionAndNeverLeakToOthers() async throws {
        let f = try CatalogFixture(); defer { f.remove() }
        let store = try await RackyStore.open(paths: StorePaths(root: f.base.appendingPathComponent("ab", isDirectory: true)))
        let a = UUID(), b = UUID()
        let ref = ActivationRef(id: "i1", kind: "skill", name: "portal-playbook", path: "/x/SKILL.md")
        let first = SessionActivationStore(store: store)
        let added = await first.set(ref, on: true, session: a)
        let again = await first.set(ref, on: true, session: a)
        #expect(added && !again, "idempotente")
        let idsA = await first.ids(for: a), idsB = await first.ids(for: b)
        #expect(idsA == ["i1"] && idsB.isEmpty)
        let reopened = SessionActivationStore()
        await reopened.attach(store: store)
        let reopenedA = await reopened.refs(for: a), reopenedB = await reopened.refs(for: b)
        #expect(reopenedA == [ref] && reopenedB.isEmpty)
        let removed = await reopened.set(ref, on: false, session: a)
        let afterOff = await reopened.refs(for: a)
        #expect(removed && afterOff.isEmpty)
        let third = SessionActivationStore()
        await third.attach(store: store)
        let persistedOff = await third.refs(for: a)
        #expect(persistedOff.isEmpty, "desligar também persiste")
    }

    @Test func pendingChangeAppearsOnlyAfterAnAgentLaunchedAndClearsOnTheNextLaunch() async throws {
        let store = SessionActivationStore()
        let s = UUID()
        let ref = ActivationRef(id: "i1", kind: "skill", name: "n", path: "/p")
        let beforeLaunch = await store.hasPendingChange(session: s)
        #expect(!beforeLaunch, "sem lançamento, nada a aplicar")
        await store.noteLaunched(session: s, ids: [])
        let afterLaunch = await store.hasPendingChange(session: s)
        #expect(!afterLaunch)
        await store.set(ref, on: true, session: s)
        let pending = await store.hasPendingChange(session: s)
        #expect(pending, "Applies on next launch")
        await store.noteLaunched(session: s, ids: ["i1"])
        let applied = await store.hasPendingChange(session: s)
        #expect(!applied)
    }
}

@Suite struct LibraryInvocationTests {
    private func item(_ kind: LibraryKind, _ name: String, clients: [LibraryClient], folder: Bool = false, scope: String = "user") -> LibraryEntry {
        LibraryEntry(id: name, kind: kind, name: name, path: folder ? "/s/\(name)/SKILL.md" : "/a/\(name).md", category: .claude, source: "claude", scope: scope, clients: clients)
    }

    @Test func eachCLIDefinesItsInvocationText() {
        let skill = item(.skill, "code-review", clients: [.claude], folder: true)
        #expect(LibraryInvocation.text(for: skill, provider: .claude, addedToSession: false) == "/code-review")
        #expect(LibraryInvocation.text(for: skill, provider: .claude, addedToSession: true) == "/racky-session:code-review")
        #expect(LibraryInvocation.text(for: item(.skill, "vercel:nextjs", clients: [.claude], folder: true, scope: "plugin"), provider: .claude, addedToSession: false) == "/vercel:nextjs")
        #expect(LibraryInvocation.text(for: item(.agent, "qa-engineer", clients: [.claude]), provider: .claude, addedToSession: false) == "@agent-qa-engineer")
        #expect(LibraryInvocation.text(for: item(.skill, "shared", clients: [.codex], folder: true), provider: .codex, addedToSession: false) == "$shared")
        #expect(LibraryInvocation.text(for: item(.skill, "prompts:ship", clients: [.codex]), provider: .codex, addedToSession: false) == "/prompts:ship")
        #expect(LibraryInvocation.text(for: item(.agent, "reviewer", clients: [.opencode]), provider: .opencode, addedToSession: false) == "@reviewer")
        #expect(LibraryInvocation.text(for: item(.agent, "only-codex", clients: [.codex]), provider: .codex, addedToSession: false) == nil)
        #expect(LibraryInvocation.text(for: item(.agent, "qa-engineer", clients: [.claude]), provider: .codex, addedToSession: false) == nil)
    }
}
