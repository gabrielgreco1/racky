import RackyPlatform
import RackyProtocol
import RackyStore
import Foundation
import Testing

@testable import RackyCore

// Backlog 25: modelo e store de agentes em ~/Racky/agents, importador só leitura, geração por CLI, avatar determinístico,
// memória SQLite, anexos e variáveis do cofre mascaradas. Tudo em diretório temporário; nada toca a casa real.

private func tempDir() throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("racky-agents-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}
private func write(_ root: URL, _ rel: String, _ text: String) throws {
    let u = root.appendingPathComponent(rel)
    try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: u, atomically: true, encoding: .utf8)
}

@Suite struct AgentAvatarTests {
    /// Strings geradas pelo `avatar()` de docs/design/agents.html (node): as duas implementações têm que concordar byte a byte.
    static let golden: [(String, Int, String)] = [
        ("qa-engineer",0,"<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 64 64\"><rect width=\"64\" height=\"64\" fill=\"#46463a\"/><path d=\"M4 64L12 53Q32 45 52 53L60 64Z\" fill=\"#d6d0c4\"/><path d=\"M22 43V27a12 12 0 0 1 24 0V43Z\" fill=\"#d6d0c4\"/><circle cx=\"29\" cy=\"29\" r=\"2\" fill=\"#22201e\"/><circle cx=\"39\" cy=\"29\" r=\"2\" fill=\"#22201e\"/><path d=\"M30 36Q34 40 38 36\" fill=\"none\" stroke=\"#22201e\" stroke-width=\"2\"/><rect x=\"21\" y=\"20\" width=\"26\" height=\"4\" fill=\"#4a3c42\"/></svg>"),
        ("web-scraper",3,"<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 64 64\"><rect width=\"64\" height=\"64\" fill=\"#3c4a41\"/><path d=\"M4 64L12 53Q32 45 52 53L60 64Z\" fill=\"#e8d9c4\"/><circle cx=\"31\" cy=\"28\" r=\"13\" fill=\"#e8d9c4\"/><rect x=\"23\" y=\"28\" width=\"5\" height=\"2\" rx=\"1\" fill=\"#22201e\"/><rect x=\"34\" y=\"28\" width=\"5\" height=\"2\" rx=\"1\" fill=\"#22201e\"/><path d=\"M27 36Q31 40 35 36\" fill=\"none\" stroke=\"#22201e\" stroke-width=\"2\"/><rect x=\"21\" y=\"25\" width=\"8\" height=\"7\" rx=\"1\" fill=\"none\" stroke=\"#22201e\" stroke-width=\"2\"/><rect x=\"33\" y=\"25\" width=\"8\" height=\"7\" rx=\"1\" fill=\"none\" stroke=\"#22201e\" stroke-width=\"2\"/></svg>"),
        ("pr-swift",4,"<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 64 64\"><rect width=\"64\" height=\"64\" fill=\"#44403c\"/><rect x=\"8\" y=\"50\" width=\"48\" height=\"30\" rx=\"14\" fill=\"#b8a58f\"/><ellipse cx=\"30\" cy=\"29\" rx=\"11\" ry=\"15\" fill=\"#b8a58f\"/><rect x=\"21\" y=\"27\" width=\"18\" height=\"4\" rx=\"2\" fill=\"#22201e\"/><rect x=\"27\" y=\"37\" width=\"6\" height=\"2\" rx=\"1\" fill=\"#22201e\"/></svg>"),
    ]

    @Test func matchesTheMockupFunctionByteForByte() {
        for (name, v, svg) in Self.golden { #expect(AgentAvatarGenerator.svg(name: name, variant: v) == svg, "\(name)#\(v)") }
    }

    @Test func isDeterministicAndVariantsDiffer() {
        #expect(AgentAvatarGenerator.svg(name: "x") == AgentAvatarGenerator.svg(name: "x"))
        let set = Set((0..<6).map { AgentAvatarGenerator.svg(name: "pr-swift", variant: $0) })
        #expect(set.count == 6)
        #expect(AgentAvatarGenerator.svg(name: "a") != AgentAvatarGenerator.svg(name: "b"))
    }
}

@Suite struct AgentStoreTests {
    @Test func createLoadRoundTripWritesTheFolderLayoutAndAnAvatar() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = AgentStore(root: dir)
        var a = AgentDefinition(name: "qa-engineer", description: "Tests: \"all\" of it", instructions: "Line 1\n\n## Heading\nLine 3", model: "sonnet",
                                tools: ["Read", "Bash"], skills: ["tdd", "qa"], tone: "Seco e direto")
        a.computer = AgentComputerPreset(screen: true, memoryMB: 4096, proxyCountry: "US", proxyRegion: "TX", packages: ["pytest"])
        a.variables = [AgentVariable(envName: "ZYTE_API_KEY", secretName: "zyte")]
        a.sites = [AgentSite(host: "github.com", secretName: "site:github.com")]
        try store.create(a)
        let folder = dir.appendingPathComponent("qa-engineer")
        for f in ["agent.md", "agent.json", "avatar.svg"] { #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(f).path), "\(f)") }
        let back = try store.load("qa-engineer")
        #expect(back.description == a.description && back.instructions == a.instructions && back.model == "sonnet")
        #expect(back.tools == a.tools && back.skills == a.skills && back.tone == a.tone)
        #expect(back.computer == a.computer && back.variables == a.variables && back.sites == a.sites)
        #expect(try String(contentsOf: folder.appendingPathComponent("avatar.svg"), encoding: .utf8) == AgentAvatarGenerator.svg(name: "qa-engineer"))
        #expect(store.list().map(\.name) == ["qa-engineer"])
        #expect(throws: AgentStoreError.alreadyExists("qa-engineer")) { try store.create(a) }
    }

    @Test func rejectsNamesThatCouldEscapeTheFolder() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = AgentStore(root: dir)
        for bad in ["../evil", "a/b", "", ".hidden", "a..b", String(repeating: "x", count: 65)] {
            #expect(throws: AgentStoreError.invalidName(bad)) { try store.create(AgentDefinition(name: bad)) }
        }
    }

    @Test func regenerateChangesTheVariantAndPhotoReplacesTheSVG() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = AgentStore(root: dir)
        try store.create(AgentDefinition(name: "web-scraper"))
        let before = try String(contentsOf: store.avatarURL("web-scraper")!, encoding: .utf8)
        let r = try store.regenerateAvatar("web-scraper")
        #expect(r.avatar.variant == 1)
        #expect(try String(contentsOf: store.avatarURL("web-scraper")!, encoding: .utf8) != before)
        let p = try store.setPhoto("web-scraper", data: Data([1, 2, 3]), fileExtension: "PNG")
        #expect(p.avatar.kind == .photo && store.avatarURL("web-scraper")?.lastPathComponent == "photo.png")
        #expect(throws: AgentStoreError.unsupportedPhoto) { try store.setPhoto("web-scraper", data: Data([1]), fileExtension: "exe") }
        #expect(throws: AgentStoreError.photoTooLarge) { try store.setPhoto("web-scraper", data: Data(count: AgentStore.maxPhotoBytes + 1), fileExtension: "png") }
        let again = try store.regenerateAvatar("web-scraper")
        #expect(again.avatar.kind == .generated && store.avatarURL("web-scraper")?.lastPathComponent == "avatar.svg")
    }

    @Test func attachmentsManifestPersistsAndRendersIntoThePrompt() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = AgentStore(root: dir)
        try store.create(AgentDefinition(name: "qa"))
        var m = AgentAttachmentManifest()
        m.add(AgentAttachment(kind: .dataset, title: "silver permits", reference: "ds-1"))
        m.add(AgentAttachment(kind: .file, title: "rubrica.md", reference: "/nope/rubrica.md"))
        m.add(AgentAttachment(kind: .dataset, title: "silver permits v2", reference: "ds-1"))
        #expect(m.attachments.count == 2, "mesmo tipo e referência só entra uma vez")
        try store.setAttachments("qa", m)
        let back = try store.attachments("qa")
        #expect(back == m)
        let section = back.promptSection { _ in false }
        #expect(section.contains("dataset: silver permits v2 (ds-1)") && section.contains("[file missing]") && !section.contains("dataset: silver permits (ds-1)"))
        var m2 = back; m2.remove(id: back.attachments[0].id)
        #expect(m2.attachments.count == 1)
    }
}

@Suite struct AgentImporterTests {
    @Test func mergesClaudeAndCodexByNameAndNeverWritesToTheSources() throws {
        let home = try tempDir(); defer { try? FileManager.default.removeItem(at: home) }
        try write(home, ".claude/agents/qa-engineer.md", "---\nname: qa-engineer\ndescription: Tests everything\n---\n\nYou are QA.\n")
        try write(home, ".claude/agents/only-claude.md", "---\ndescription: Claude only\ntools: Read, Grep\n---\nBody\n")
        try write(home, ".codex/agents/qa-engineer.toml", "name = \"qa-engineer\"\ndescription = \"Tests everything (codex)\"\ndeveloper_instructions = \"\"\"\nYou are QA, codex.\nLine \"two\"\n\"\"\"\n")
        try write(home, ".codex/agents/only-codex.toml", "name = \"only-codex\"\ndescription = \"Codex only\"\nmodel = \"gpt\"\ndeveloper_instructions = \"\"\"\nHi\n\"\"\"\n")
        try write(home, ".claude/agents/../agents/bad name.md", "---\ndescription: x\n---\nb")
        let before = try snapshot(home)
        let found = AgentImporter.discover(home: home)
        #expect(found.map(\.name) == ["only-claude", "only-codex", "qa-engineer"])
        let qa = try #require(found.first { $0.name == "qa-engineer" })
        #expect(qa.clients == [.claude, .codex], "um agente só, com os dois CLIs")
        #expect(qa.description == "Tests everything" && qa.instructions == "You are QA.", "o Claude vence nos campos")
        #expect(found.first { $0.name == "only-claude" }?.tools == ["Read", "Grep"])
        let oc = try #require(found.first { $0.name == "only-codex" })
        #expect(oc.clients == [.codex] && oc.instructions == "Hi" && oc.model == "gpt")
        #expect(try snapshot(home) == before, "leitura pura: nenhum arquivo mudou nem apareceu")
    }

    @Test func codexInstructionsWithQuotesAndDefinitionConversion() throws {
        let home = try tempDir(); defer { try? FileManager.default.removeItem(at: home) }
        try write(home, ".codex/agents/c.toml", "description = \"d\"\ndeveloper_instructions = \"\"\"\nLine \"two\"\nThree\n\"\"\"\n")
        let a = try #require(AgentImporter.discover(home: home).first)
        #expect(a.name == "c" && a.instructions == "Line \"two\"\nThree")
        #expect(a.definition().instructions == a.instructions)
    }

    @Test func importsALooseMarkdownFile() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try write(dir, "my-agent.md", "---\ndescription: Mine\nmodel: opus\n---\nDo things\n")
        let a = try #require(AgentImporter.importMarkdown(at: dir.appendingPathComponent("my-agent.md")))
        #expect(a.name == "my-agent" && a.description == "Mine" && a.model == "opus" && a.instructions == "Do things")
        try write(dir, "plain.md", "Just text, no frontmatter")
        #expect(AgentImporter.importMarkdown(at: dir.appendingPathComponent("plain.md"))?.instructions == "Just text, no frontmatter")
    }

    private func snapshot(_ root: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        for case let u as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)! where !u.hasDirectoryPath {
            out[u.path] = try Data(contentsOf: u)
        }
        return out
    }
}

@Suite struct AgentCLIGeneratorTests {
    private func agent() -> AgentDefinition {
        AgentDefinition(name: "qa-engineer", description: "Tests", instructions: "Be QA.\nUse \"\"\" carefully \\ ok", model: "sonnet", tools: ["Read"], skills: ["tdd"],
                        tone: "Curto", variables: [AgentVariable(envName: "ZYTE_API_KEY", secretName: "zyte")])
    }

    @Test func claudeGoesInAgentsJSONWithPromptToneAttachmentsAndMemoryIndex() {
        var m = AgentAttachmentManifest(); m.add(AgentAttachment(kind: .computer, title: "wi-milwaukee", reference: "c-1"))
        let out = AgentCLIGenerator.generate(agent(), for: .claude, attachments: m, memoryIndex: "#1 smoke fails on empty type")
        #expect(out.files.isEmpty)
        let def = try! #require(out.claudeAgents["qa-engineer"])
        guard case .string(let prompt) = def["prompt"] else { Issue.record("no prompt"); return }
        #expect(prompt.hasPrefix("Be QA."))
        #expect(prompt.contains("Voice and tone") && prompt.contains("Curto"))
        #expect(prompt.contains("computer: wi-milwaukee (c-1)"))
        #expect(prompt.contains("#1 smoke fails on empty type") && prompt.contains("memory_search"))
        #expect(prompt.contains("ZYTE_API_KEY"), "só o nome da variável")
        #expect(def["model"] == .string("sonnet") && def["tools"] == .strings(["Read"]) && def["skills"] == .strings(["tdd"]))
    }

    @Test func codexTOMLAndOpenCodeMarkdownAreFilesInRackysOwnLaunchDirAndRoundTrip() throws {
        let c = AgentCLIGenerator.generate(agent(), for: .codex)
        let file = try #require(c.files.first)
        #expect(file.name == "agents-codex/agents/qa-engineer.toml")
        let toml = String(decoding: file.contents, as: UTF8.self)
        let parsed = AgentImporter.parseTOMLStrings(toml)
        #expect(parsed["name"] == "qa-engineer" && parsed["model"] == "sonnet")
        #expect(parsed["developer_instructions"]?.contains("Be QA.") == true)
        let o = AgentCLIGenerator.generate(agent(), for: .opencode)
        #expect(o.files.first?.name == "agents-opencode/agent/qa-engineer.md")
        let md = String(decoding: o.files[0].contents, as: UTF8.self)
        #expect(md.contains("mode: subagent") && md.contains("Be QA."))
        for f in c.files + o.files { #expect(!f.name.hasPrefix("/") && !f.name.contains("..") && !f.name.contains(".claude") && !f.name.contains(".codex/")) }
    }
}

@Suite struct AgentMemoryTests {
    private func store(_ dir: URL, now: @escaping @Sendable () -> Date = { Date() }) throws -> AgentMemoryStore {
        try AgentMemoryStore(path: dir.appendingPathComponent("a/memory.sqlite"), clock: now)
    }

    @Test func addSearchReadUpdateDelete() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = try store(dir)
        let a = try await m.add(title: "milwaukee smoke", body: "smoke falha se tipo de permit vem vazio, override em overrides.yaml")
        _ = try await m.add(title: "acreage", body: "1 casa decimal sempre")
        let hits = try await m.search("permit vazio")
        #expect(hits.map(\.id) == [a])
        #expect(try await m.search("overri").map(\.id) == [a], "prefixo")
        #expect(try await m.search("\"*) OR (").isEmpty, "texto estranho não quebra a consulta")
        #expect(try await m.search("   ").isEmpty)
        #expect(try await m.read(id: a).body.contains("overrides.yaml"))
        try await m.update(id: a, title: "milwaukee", body: "agora usa fallback")
        let oldHits = try await m.search("overrides"), newHits = try await m.search("fallback")
        #expect(oldHits.isEmpty && !newHits.isEmpty, "a busca acompanha a edição")
        try await m.delete(id: a)
        let remaining = try await m.count(), gone = try await m.search("fallback")
        #expect(remaining == 1 && gone.isEmpty)
        await #expect(throws: AgentMemoryError.notFound(a)) { _ = try await m.read(id: a) }
        await #expect(throws: AgentMemoryError.emptyEntry) { try await m.add(title: " ", body: "") }
    }

    @Test func persistsAcrossReopens() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        do { let m = try store(dir); _ = try await m.add(title: "t", body: "durable fact") }
        let m2 = try store(dir)
        #expect(try await m2.search("durable").count == 1)
    }

    @Test func indexIsShortNewestFirstAndSaysWhatWasLeftOut() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        final class Tick: @unchecked Sendable { var t = 1_800_000_000.0 }  // SAFETY: uso sequencial no teste.
        let tick = Tick()
        let m = try store(dir) { tick.t += 60; return Date(timeIntervalSince1970: tick.t) }
        for i in 1...30 { _ = try await m.add(title: "entry number \(i)", body: "body \(i)") }
        let idx = try await m.index(maxCharacters: 200)
        let lines = idx.split(separator: "\n").map(String.init)
        #expect(lines.first == "#30 entry number 30")
        #expect(lines.last?.hasPrefix("(+") == true && lines.last?.contains("memory_search") == true)
        #expect(idx.count <= 260)
        #expect(try await m.index(maxCharacters: 10_000).split(separator: "\n").count == 30)
    }

    @Test func compactionMergesOldEntriesAndKeepsThemSearchable() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        final class Tick: @unchecked Sendable { var t = 1_800_000_000.0 }  // SAFETY: uso sequencial no teste.
        let tick = Tick()
        let m = try store(dir) { tick.t += 60; return Date(timeIntervalSince1970: tick.t) }
        for i in 1...10 { _ = try await m.add(title: "task \(i)", body: "detail \(i) zebra\(i)") }
        #expect(try await m.compact(keepRecent: 3) == 7)
        #expect(try await m.count() == 4)
        let all = try await m.all()
        #expect(all.filter(\.compacted).count == 1 && all.contains { $0.title == "task 10" })
        #expect(try await m.search("zebra2").count == 1, "o conteúdo antigo continua achável")
        #expect(try await m.compact(keepRecent: 10) == 0)
    }
}

@Suite struct AgentVariableEnvironmentTests {
    @Test func resolvesVaultVariablesIntoEnvAndMasksThemEverywhere() async throws {
        let h = try await VaultHarness(); defer { h.remove() }
        let key = "zyte-SECRET-key-123456", pass = "p@ss w0rd/9"
        _ = try await h.vault.create(NewSecret(name: "zyte", value: key))
        _ = try await h.vault.create(NewSecret(name: "accela-pass", value: pass))
        _ = try await h.vault.create(NewSecret(name: "sidecar", value: "hidden", delivery: .sidecarOnly))
        let agent = AgentDefinition(name: "qa", variables: [
            AgentVariable(envName: "ZYTE_API_KEY", secretName: "zyte"), AgentVariable(envName: "ACCELA_PASS", secretName: "accela-pass"),
            AgentVariable(envName: "NOPE", secretName: "does-not-exist"), AgentVariable(envName: "SIDE", secretName: "sidecar"),
        ])
        let env = try await AgentEnvironment.resolve(for: agent, vault: h.vault)
        #expect(env.environment == ["ZYTE_API_KEY": key, "ACCELA_PASS": pass])
        #expect(Set(env.skipped.map(\.envName)) == ["NOPE", "SIDE"])
        let log = "curl -H 'X: \(key)' login \(pass) enc \(pass.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)"
        let masked = env.masker.mask(log)
        #expect(!masked.contains(key) && !masked.contains(pass) && !masked.contains("w0rd"))
        #expect(masked.contains("•••"))
        #expect(!"\(env)".contains(key) && !"\(env)".contains(pass), "descrição só tem nomes")
        let prompt = AgentCLIGenerator.prompt(for: agent)
        #expect(!prompt.contains(key) && !prompt.contains(pass))
        #expect(env.masker.mask("nothing secret") == "nothing secret")
    }
}
