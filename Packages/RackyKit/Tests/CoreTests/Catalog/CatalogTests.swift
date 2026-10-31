import RackyPlatform
import RackyStore
import CryptoKit
import Foundation
import Testing

@testable import RackyCore

/// Árvore de pastas nativas falsa (`~/.claude`, `~/.codex`, `~/.agents`) montada em diretório temporário.
struct CatalogFixture {
    let home: URL
    let project: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("racky-catalog-\(UUID().uuidString)", isDirectory: true)
        home = base.appendingPathComponent("home", isDirectory: true)
        project = base.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    var base: URL { home.deletingLastPathComponent() }
    func remove() { try? FileManager.default.removeItem(at: base) }

    @discardableResult
    func write(_ relative: String, _ text: String, under root: URL? = nil) throws -> URL {
        let url = (root ?? home).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// Conjunto padrão: o suficiente para exercitar cada fonte, conflito e erro do catálogo.
    func populate() throws {
        try write(".claude/agents/data-engineer.md", "---\nname: data-engineer\ndescription: Owns pipelines\nmodel: opus\ntools: Read, Grep\n---\nBODY-MARKER-AGENT-1 secret instructions\n")
        try write(".claude/agents/nested/qa.md", "---\nname: qa-engineer\ndescription: >\n  Runs tests\n  and reports\n---\nBODY-MARKER-AGENT-2\n")
        try write(".claude/agents/broken.md", "---\nname: broken\ndescription: ok\n\toops: tab\n---\nBODY\n")
        try write(".claude/agents/plain.md", "No frontmatter at all\n")
        try write(".claude/skills/code-review/SKILL.md", "---\nname: code-review\ndescription: Review code\n---\nBODY-MARKER-SKILL-1\n")
        try write(".claude/skills/no-name/SKILL.md", "---\ndescription: Skill without a name\n---\nbody\n")
        try write(".claude/skills/packed.zip", "PK-not-really-a-zip")
        try write(".claude/skills/.hidden/SKILL.md", "---\nname: hidden\n---\n")
        try write(".agents/skills/shared/SKILL.md", "---\nname: shared\ndescription: Shared skill\n---\nbody\n")
        try write(".agents/skills/code-review/SKILL.md", "---\nname: code-review\ndescription: Review code (codex copy)\n---\nbody\n")
        try write(".codex/agents/data-engineer.toml", "name = \"data-engineer\"\ndescription = \"Owns pipelines, differently\"\ndeveloper_instructions = \"\"\"\nBODY-MARKER-TOML\nmore\n\"\"\"\n")
        try write(".codex/agents/only-codex.toml", "name = \"only-codex\"\ndescription = 'Codex only'\n")
        try write(".codex/agents/bad.toml", "this is not toml\n")
        try write(".codex/skills/legacy/SKILL.md", "---\nname: legacy\n---\n")
        try write(".claude/CLAUDE.md", "# global instructions\n")
        try write(".codex/AGENTS.md", "# codex instructions\n")
        // Plugin instalado: agents/ e skills/ próprios, nomes com namespace.
        let plugin = home.appendingPathComponent(".claude/plugins/cache/mk/vercel/1.0", isDirectory: true)
        try write("agents/deploy.md", "---\nname: deploy\ndescription: Plugin agent\n---\n", under: plugin)
        try write("skills/nextjs/SKILL.md", "---\nname: nextjs\ndescription: Plugin skill\n---\n", under: plugin)
        try write(".claude/plugins/installed_plugins.json",
                  #"{"version":2,"plugins":{"vercel@mk":[{"scope":"user","installPath":"\#(plugin.path)","version":"1.0"}]}}"#)
        // Projeto: mesmo nome de agente que o do usuário (o de projeto vence) + instruções.
        try write(".claude/agents/data-engineer.md", "---\nname: data-engineer\ndescription: Project override\n---\n", under: project)
        try write("AGENTS.md", "# project agents\n", under: project)
    }

    /// Impressão digital da árvore (caminho, tamanho, mtime, hash) para provar que nada foi escrito.
    func fingerprint() -> [String] {
        var out: [String] = []
        let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])!
        for case let url as URL in e {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let hash = isDir.boolValue ? "-" : ((try? Data(contentsOf: url)).map { SHA256.hash(data: $0).description } ?? "?")
            out.append("\(url.path)|\(values?.fileSize ?? -1)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(hash)")
        }
        return out.sorted()
    }
}

@Suite struct FrontmatterTests {
    @Test func parsesScalarsBlocksListsAndKeepsNestedAsRaw() {
        let text = """
        ---
        name: "quoted: name"
        description: >
          folded line one
          folded line two
        tools: Read, Grep
        skills: [a, "b c", 'd']
        mcpServers:
          - server: x
            command: y
        list:
          - one
          - two
        literal: |
          keep
          lines
        comment: value # trailing
        ---
        body
        """
        let r = FrontmatterParser.parse(text)
        #expect(r.error == nil && r.hasFrontmatter)
        #expect(r.fields["name"] == .string("quoted: name"))
        #expect(r.fields["description"] == .string("folded line one folded line two"))
        #expect(r.fields["tools"] == .string("Read, Grep"))
        #expect(r.fields["skills"] == .list(["a", "b c", "d"]))
        #expect(r.fields["list"] == .list(["one", "two"]))
        #expect(r.fields["literal"] == .string("keep\nlines"))
        #expect(r.fields["comment"] == .string("value"))
        if case .raw(let raw)? = r.fields["mcpServers"] { #expect(raw.contains("command: y")) } else { Issue.record("mcpServers should be raw") }
    }

    @Test func reportsErrorsWithLineNumbers() {
        #expect(FrontmatterParser.parse("---\nname: a\nthis is wrong\n---\n").error == FrontmatterError(line: 3, message: "expected `key: value`"))
        #expect(FrontmatterParser.parse("---\nname: a\n\tx: y\n---\n").error?.line == 3)
        #expect(FrontmatterParser.parse("---\nname: a\n").error == FrontmatterError(line: 1, message: "frontmatter is never closed"))
        #expect(FrontmatterParser.parse("---\nname: \"open\n---\n").error?.line == 2)
        #expect(FrontmatterParser.parse("---\nskills: [a, b\n---\n").error?.message == "list is never closed")
        #expect(FrontmatterParser.parse("---\nname: a\nthis\n---\n").error?.summary == "Invalid frontmatter (line 3): expected `key: value`")
        // Campos lidos antes do erro sobrevivem.
        #expect(FrontmatterParser.parse("---\nname: a\nnope\n---\n").fields["name"] == .string("a"))
    }

    @Test func fileWithoutFrontmatterIsNotAnError() {
        let r = FrontmatterParser.parse("# Title\n---\nnot frontmatter\n")
        #expect(!r.hasFrontmatter && r.error == nil && r.fields.isEmpty)
        #expect(FrontmatterParser.parse("\u{FEFF}---\nname: bom\n---\n").fields["name"] == .string("bom"))
        #expect(FrontmatterParser.parse("---\r\nname: crlf\r\n---\r\n").fields["name"] == .string("crlf"))
    }

    @Test func tomlReadsTopLevelStringsAndMultilineBodies() {
        let r = AgentTOML.parse("name = \"a\"\ndescription = 'single'\nmodel = \"x\" \ndeveloper_instructions = \"\"\"\nline1\nline2\n\"\"\"\n[tools]\nfoo = \"ignored\"\n")
        #expect(r.error == nil)
        #expect(r.fields["name"] == "a" && r.fields["description"] == "single" && r.fields["model"] == "x")
        #expect(r.fields["developer_instructions"] == "line1\nline2\n" || r.fields["developer_instructions"] == "\nline1\nline2\n")
        #expect(r.fields["foo"] == nil)
        #expect(AgentTOML.parse("garbage\n").error?.line == 1)
        #expect(AgentTOML.parse("a = \"\"\"\nnever closed\n").error?.line == 1)
    }
}

@Suite struct CatalogScannerTests {
    @Test func indexesEverySourceByReferenceWithErrorsAndNamespacing() throws {
        let f = try CatalogFixture(); defer { f.remove() }
        try f.populate()
        let scan = CatalogScanner.scan(CatalogRoots(home: f.home, projectRoots: [f.project]))

        func items(_ kind: String, source: String? = nil, scope: String? = nil) -> [CatalogRow] {
            scan.items.filter { $0.kind == kind && (source == nil || $0.source == source) && (scope == nil || $0.scope == scope) }
        }
        #expect(Set(items("agent", source: "claude", scope: "user").map(\.name)) == ["data-engineer", "qa-engineer", "broken", "plain"])
        #expect(Set(items("skill", source: "claude", scope: "user").map(\.name)) == ["code-review", "no-name", "packed"])
        #expect(Set(items("skill", source: "agents").map(\.name)) == ["shared", "code-review"])
        #expect(Set(items("agent", source: "codex").map(\.name)) == ["data-engineer", "only-codex", "bad"])
        #expect(Set(items("skill", source: "codex").map(\.name)) == ["legacy"])
        #expect(Set(items("instructions").map(\.name)) == ["CLAUDE.md", "AGENTS.md"])
        #expect(Set(items("agent", source: "plugin").map(\.name)) == ["vercel:deploy"])
        #expect(Set(items("skill", source: "plugin").map(\.name)) == ["vercel:nextjs"])
        #expect(!scan.items.contains { $0.name == "hidden" }, "pastas ocultas não entram")

        let broken = try #require(scan.items.first { $0.name == "broken" && $0.kind == "agent" })
        #expect(broken.parseError == "Invalid frontmatter (line 4): tab used for indentation")
        let zip = try #require(scan.items.first { $0.name == "packed" })
        #expect(zip.description == "Packaged skill (.zip)")
        let noName = try #require(scan.items.first { $0.name == "no-name" })
        #expect(noName.description == "Skill without a name" && noName.parseError == nil)
        let qa = try #require(scan.items.first { $0.name == "qa-engineer" })
        #expect(qa.description == "Runs tests and reports")
        let toml = try #require(scan.items.first { $0.name == "only-codex" })
        #expect(toml.description == "Codex only" && toml.clients == ["codex"])
        #expect(try #require(scan.items.first { $0.name == "bad" }).parseError?.hasPrefix("Invalid TOML") == true)

        let report = Dictionary(uniqueKeysWithValues: scan.sources.map { ($0.label, $0) })
        #expect(report["~/.claude/agents"]?.count == 4 && report["~/.claude/agents"]?.invalid == 1)
        #expect(report["~/.codex/agents"]?.invalid == 1)
        #expect(report["~/.claude/CLAUDE.md"]?.present == true)
    }

    @Test func databaseRowsHoldMetadataAndHashOnlyNeverTheBody() throws {
        let f = try CatalogFixture(); defer { f.remove() }
        try f.populate()
        let scan = CatalogScanner.scan(CatalogRoots(home: f.home))
        let all = scan.items.map { [$0.name, $0.description ?? "", $0.path, $0.frontmatterJSON ?? "", $0.parseError ?? ""].joined(separator: "|") }.joined()
        #expect(!all.contains("BODY-MARKER"))
        let agent = try #require(scan.items.first { $0.name == "data-engineer" && $0.source == "claude" })
        let file = f.home.appendingPathComponent(".claude/agents/data-engineer.md")
        #expect(agent.contentHash == SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined())
        #expect(agent.frontmatterJSON == #"{"description":"Owns pipelines","model":"opus","name":"data-engineer","tools":"Read, Grep"}"#)
        #expect(agent.mtime != nil)
    }

    @Test func projectWinsOverUserAndShadowsAreMarkedPerClient() throws {
        let f = try CatalogFixture(); defer { f.remove() }
        try f.populate()
        let scan = CatalogScanner.scan(CatalogRoots(home: f.home, projectRoots: [f.project]))
        let user = try #require(scan.items.first { $0.name == "data-engineer" && $0.source == "claude" && $0.scope == "user" })
        let project = try #require(scan.items.first { $0.name == "data-engineer" && $0.scope == "project" })
        let codex = try #require(scan.items.first { $0.name == "data-engineer" && $0.source == "codex" })
        #expect(user.shadowedBy == project.id)
        #expect(project.shadowedBy == nil)
        #expect(codex.shadowedBy == nil, "o agente do Codex é de outro cliente: não compete")
        let conflict = try #require(scan.conflicts.first { $0.name == "data-engineer" && $0.client == "claude" })
        #expect(conflict.winnerID == project.id && conflict.shadowedIDs == [user.id])
        // Skill com o mesmo nome em Claude e `~/.agents`: clientes diferentes, sem sombra.
        #expect(scan.items.filter { $0.name == "code-review" }.allSatisfy { $0.shadowedBy == nil })
        #expect(scan.items.first { $0.name == "vercel:deploy" }?.shadowedBy == nil, "plugin é namespaced")
    }

    @Test func legacyCodexSkillsLoseToSharedAgentsSkillsOfTheSameName() throws {
        let f = try CatalogFixture(); defer { f.remove() }
        try f.write(".agents/skills/dup/SKILL.md", "---\nname: dup\n---\n")
        try f.write(".codex/skills/dup/SKILL.md", "---\nname: dup\n---\n")
        let scan = CatalogScanner.scan(CatalogRoots(home: f.home))
        let shared = try #require(scan.items.first { $0.name == "dup" && $0.source == "agents" })
        let legacy = try #require(scan.items.first { $0.name == "dup" && $0.source == "codex" })
        #expect(shared.shadowedBy == nil && legacy.shadowedBy == shared.id)
    }

    @Test func detectsMirrorsOutOfSyncBetweenMarkdownAndToml() throws {
        let f = try CatalogFixture(); defer { f.remove() }
        try f.populate()
        #expect(CatalogScanner.scan(CatalogRoots(home: f.home)).outOfSync == ["data-engineer"])
    }

    @Test func scanNeverWritesToTheNativeFolders() throws {
        let f = try CatalogFixture(); defer { f.remove() }
        try f.populate()
        let before = f.fingerprint()
        _ = CatalogScanner.scan(CatalogRoots(home: f.home, projectRoots: [f.project]))
        #expect(f.fingerprint() == before)
    }

    @Test func missingFoldersAreReportedAbsentNotErrors() throws {
        let f = try CatalogFixture(); defer { f.remove() }
        let scan = CatalogScanner.scan(CatalogRoots(home: f.home))
        #expect(scan.items.isEmpty)
        #expect(scan.sources.allSatisfy { !$0.present && $0.count == 0 })
    }

    @Test func symlinkedSkillFoldersAreFollowed() throws {
        let f = try CatalogFixture(); defer { f.remove() }
        try f.write(".agents/skills/real/SKILL.md", "---\nname: real\ndescription: via link\n---\n")
        try FileManager.default.createDirectory(at: f.home.appendingPathComponent(".claude/skills"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.home.appendingPathComponent(".claude/skills/real"),
                                                   withDestinationURL: f.home.appendingPathComponent(".agents/skills/real"))
        let scan = CatalogScanner.scan(CatalogRoots(home: f.home))
        #expect(scan.items.filter { $0.name == "real" }.count == 2)
    }
}

@Suite struct CatalogServiceTests {
    private func open(_ f: CatalogFixture, debounce: Duration = .seconds(1)) async throws -> (RackyStore, CatalogService) {
        let store = try await RackyStore.open(paths: StorePaths(root: f.base.appendingPathComponent("ab", isDirectory: true)))
        return (store, CatalogService(store: store, roots: CatalogRoots(home: f.home), debounce: debounce))
    }

    @Test func refreshReconcilesAddedChangedAndRemovedKeepingHistory() async throws {
        let f = try CatalogFixture(); defer { f.remove() }
        try f.populate()
        let (store, service) = try await open(f)
        let first = try await service.refresh()
        #expect(first.added.count == (try await store.catalogItems()).count && first.changed.isEmpty && first.removed.isEmpty)

        #expect(try await service.refresh().isEmpty, "sem mudanças, nada é reescrito")

        try f.write(".claude/agents/new-agent.md", "---\nname: new-agent\ndescription: fresh\n---\n")
        try f.write(".claude/agents/data-engineer.md", "---\nname: data-engineer\ndescription: Edited\n---\n")
        try FileManager.default.removeItem(at: f.home.appendingPathComponent(".claude/agents/plain.md"))
        let diff = try await service.refresh()
        #expect(diff.added.count == 1 && diff.changed.count == 1 && diff.removed.count == 1)

        let live = try await store.catalogItems()
        #expect(live.contains { $0.name == "new-agent" })
        #expect(!live.contains { $0.name == "plain" })
        let all = try await store.catalogItems(includeMissing: true)
        let gone = try #require(all.first { $0.name == "plain" })
        #expect(gone.missingAt != nil, "item removido fica no histórico com missing_at")
        #expect(live.first { $0.name == "data-engineer" && $0.source == "claude" }?.description == "Edited")

        // Voltou: reaparece sem duplicar.
        try f.write(".claude/agents/plain.md", "No frontmatter\n")
        let back = try await service.refresh()
        #expect(back.added.count == 1)
        #expect(try await store.catalogItems(includeMissing: true).filter { $0.name == "plain" }.count == 1)
        try await store.close()
    }

    @Test func dryRunReportsWithoutTouchingAnyDatabase() async throws {
        let f = try CatalogFixture(); defer { f.remove() }
        try f.populate()
        let scan = await CatalogService.dryRun(roots: CatalogRoots(home: f.home))
        #expect(scan.items.count > 10)
        #expect(!FileManager.default.fileExists(atPath: f.base.appendingPathComponent("ab").path))
    }

    @Test func watchPicksUpANewAgentFileWithinTwoSeconds() async throws {
        let f = try CatalogFixture(); defer { f.remove() }
        try f.populate()
        let (store, service) = try await open(f)   // debounce padrão de 1 s (06 §4.1)
        let changes = try await service.startWatching()
        let started = ContinuousClock.now
        try f.write(".claude/agents/hot.md", "---\nname: hot\ndescription: appears live\n---\n")
        var elapsed: Duration?
        for await diff in changes where diff.added.count == 1 { elapsed = ContinuousClock.now - started; break }
        await service.stopWatching()
        let took = try #require(elapsed)
        #expect(took < .seconds(2), "TA-401: aparece em até 2 s (levou \(took))")
        #expect(try await store.catalogItems().contains { $0.name == "hot" })
        try await store.close()
    }

    @Test func watchFollowsNewSkillFoldersAndEditsInsideThem() async throws {
        let f = try CatalogFixture(); defer { f.remove() }
        try f.populate()
        let (store, service) = try await open(f, debounce: .milliseconds(150))
        let changes = try await service.startWatching()
        try f.write(".claude/skills/fresh/SKILL.md", "---\nname: fresh\ndescription: v1\n---\n")
        for await diff in changes where !diff.added.isEmpty { break }
        // Edição atômica (rename) dentro da pasta nova da skill também é vista.
        let skillDir = f.home.appendingPathComponent(".claude/skills/fresh")
        let tmp = skillDir.appendingPathComponent("SKILL.md.tmp")
        try Data("---\nname: fresh\ndescription: v2\n---\n".utf8).write(to: tmp)
        _ = try FileManager.default.replaceItemAt(skillDir.appendingPathComponent("SKILL.md"), withItemAt: tmp)
        for await diff in changes where !diff.changed.isEmpty { break }
        await service.stopWatching()
        #expect(try await store.catalogItems().first { $0.name == "fresh" }?.description == "v2")
        try await store.close()
    }

    @Test func serviceNeverWritesToNativeFolders() async throws {
        let f = try CatalogFixture(); defer { f.remove() }
        try f.populate()
        let before = f.fingerprint()
        let store = try await RackyStore.open(paths: StorePaths(root: f.base.appendingPathComponent("ab-elsewhere", isDirectory: true)))
        let service = CatalogService(store: store, roots: CatalogRoots(home: f.home, projectRoots: [f.project]))
        try await service.refresh()
        try await store.close()
        let after = f.fingerprint().filter { !$0.contains("/ab-elsewhere") }
        #expect(after == before.filter { !$0.contains("/ab-elsewhere") })
    }
}
