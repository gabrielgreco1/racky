import RackyCore
import RackyDesignSystem
import RackyProtocol
import RackyStore
import AppKit
import Foundation
import SnapshotTesting
import SwiftUI
import Testing

@testable import RackyUI

// T4-02 (AC-901…905): a página Library, a aba Context e a ativação aditiva por sessão. Pastas nativas de mentira em diretório
// temporário; o editor e o Finder são fakes (nenhum teste abre app de verdade).

private let sessionID = UUID(uuidString: "00000000-0000-4000-8000-0000000000A1")!

@MainActor
final class LibraryFixture {
    let base: URL
    let home: URL
    let project: URL
    let registry: ActionRegistry
    let controller: LibraryController
    let context: ContextController
    var opened: [URL] = []
    var revealed: [URL] = []
    var restarted: [UUID] = []
    var agentsToRestart: [UUID] = []
    var settingsSection: String?
    var page = false

    /// `fixedPath`: só a suíte `LibraryUITests` (serial) o usa, porque o caminho do arquivo aparece nas imagens de referência.
    init(fixedPath: Bool = false) async throws {
        base = URL(fileURLWithPath: fixedPath ? "/private/tmp/abx-library-fixture" : "/private/tmp/abx-library-\(UUID().uuidString.lowercased())", isDirectory: true)
        try? FileManager.default.removeItem(at: base)
        home = base.appendingPathComponent("home", isDirectory: true)
        project = base.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        registry = ActionRegistry(flags: SliceFlags(current: .slice4), surface: FakeSurface())
        controller = LibraryController()
        context = ContextController(library: controller, overlays: OverlayRouter(), showModule: { _ in })
        try populate()
        let home = home
        controller.loadRows = { roots in CatalogScanner.scan(CatalogRoots(home: home, projectRoots: roots)).items }
        controller.projectRoots = { [project] in [project] }
        controller.currentSession = { [project] in LibrarySessionTarget(id: sessionID, title: "Austin listings", folder: project.path) }
        controller.openFile = { [unowned self] url in opened.append(url) }
        controller.reveal = { [unowned self] url in revealed.append(url) }
        controller.showPage = { [unowned self] in page = true }
        controller.hidePage = { [unowned self] in page = false }
        controller.isPageOpen = { [unowned self] in page }
        controller.openSettings = { [unowned self] in settingsSection = $0 }
        context.restartableAgents = { [unowned self] in agentsToRestart }
        context.relaunch = { [unowned self] in restarted.append($0) }
        try controller.register(in: registry)
        try context.register(in: registry)
        // Ações que os botões da página disparam e que pertencem a outros controladores.
        for id in [ActionID.promptInsertItem, .pageClose] { try? registry.register(id) { _ in nil } }
    }

    func remove() { try? FileManager.default.removeItem(at: base) }

    @discardableResult
    func write(_ relative: String, _ text: String, under root: URL? = nil) throws -> URL {
        let url = (root ?? home).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    func populate() throws {
        try write(".claude/agents/data-engineer.md", "---\nname: data-engineer\ndescription: Owns the ingestion pipelines\nmodel: opus\ntools: Read, Grep, Bash\nskills:\n  - portal-playbook\nmcpServers:\n  racky:\n    command: racky\n---\nYou own the pipelines.\nKeep chunks small.\n")
        try write(".claude/agents/qa-engineer.md", "---\nname: qa-engineer\ndescription: Runs tests and reports\n---\nRun the suite.\n")
        try write(".claude/skills/code-review/SKILL.md", "---\nname: code-review\ndescription: Review a diff\n---\n# Code review\nRead the diff first.\n")
        try write(".agents/skills/portal-playbook/SKILL.md", "---\nname: portal-playbook\ndescription: Query the search API feature services\n---\n# Search\nUse the REST query endpoint.\n")
        try write(".agents/skills/portal-playbook/fetch.py", "print('fetch')\n")
        try write(".agents/skills/portal-playbook/notes.md", "notes\n")
        try write(".codex/agents/listing-portal-scout.toml", "name = \"listing-portal-scout\"\ndescription = \"Scouts listing portals\"\ndeveloper_instructions = \"\"\"\nFind the search form.\n\"\"\"\n")
        try write(".config/opencode/agent/reviewer.md", "---\ndescription: Reviews diffs\n---\nReview.\n")
        try write(".claude/skills/proj-skill/SKILL.md", "---\nname: proj-skill\ndescription: Only in this repo\n---\nx\n", under: project)
        let plugin = home.appendingPathComponent(".claude/plugins/cache/mk/vercel/1.0", isDirectory: true)
        try write("skills/nextjs/SKILL.md", "---\nname: nextjs\ndescription: Next.js guidance\n---\nx\n", under: plugin)
        try write(".claude/plugins/installed_plugins.json", #"{"version":2,"plugins":{"vercel@mk":[{"scope":"user","installPath":"\#(plugin.path)","version":"1.0"}]}}"#)
    }

    func fingerprint() -> [String] {
        var out: [String] = []
        let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])!
        for case let url as URL in e {
            let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            out.append("\(url.path)|\(v?.fileSize ?? -1)|\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)")
        }
        return out.sorted()
    }

    func render(_ view: some View, size: CGSize, name: String, line: UInt = #line) {
        DSFonts.registerIfNeeded()
        let previous = MotionPolicy.shared.preference
        MotionPolicy.shared.preference = .on
        defer { MotionPolicy.shared.preference = previous }
        let root = view.environment(\.actionRegistry, registry).environment(\.elementStore, UIElementStore()).frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        withSnapshotTesting(record: ComponentSnapshotTests.recording) {
            assertSnapshot(of: host, as: .image(precision: 0.98, perceptualPrecision: 0.97), named: name, testName: "library", line: line)
        }
    }
}

@MainActor
@Suite("T4-02 - Library", .serialized, .offscreenAppKit)
struct LibraryUITests {
    /// AC-901: as contagens por fonte batem com o disco e cada item tem fonte e CLIs.
    @Test func sourcesListTheDiskCountsAndEveryItemShowsSourceAndClients() async throws {
        let f = try await LibraryFixture(fixedPath: true); defer { f.remove() }
        await f.controller.reload()
        #expect(f.controller.counts[.claude] == 2 && f.controller.counts[.codex] == 1 && f.controller.counts[.opencode] == 1)
        #expect(f.controller.presentCategories == [.claude, .codex, .opencode])
        _ = try await f.registry.perform(.librarySetSection, .select("skills"))
        #expect(f.controller.counts == [.claude: 1, .agents: 1, .plugins: 1, .project: 1])
        #expect(f.controller.items.allSatisfy { !$0.clients.isEmpty && !$0.path.isEmpty })
    }

    @Test func sectionSearchSourceAndSelectionGoThroughRegisteredActions() async throws {
        let f = try await LibraryFixture(fixedPath: true); defer { f.remove() }
        await f.controller.reload()
        #expect(f.controller.section == .agents && f.controller.visibleItems.map(\.name) == ["data-engineer", "listing-portal-scout", "qa-engineer", "reviewer"])
        #expect(f.controller.selectedID == f.controller.visibleItems.first?.id, "o primeiro item abre no detalhe")
        _ = try await f.registry.perform(.librarySetSearch, .set("pipelines"))
        #expect(f.controller.visibleItems.map(\.name) == ["data-engineer"])
        _ = try await f.registry.perform(.librarySetSearch, .set(""))
        _ = try await f.registry.perform(.librarySetSource, .select("codex"))
        #expect(f.controller.visibleItems.map(\.name) == ["listing-portal-scout"] && f.controller.selectedItem?.name == "listing-portal-scout")
        _ = try await f.registry.perform(.librarySetSource, .select("all"))
        let qa = try #require(f.controller.items.first { $0.name == "qa-engineer" })
        _ = try await f.registry.perform(.librarySelectItem, .select(qa.id))
        #expect(f.controller.selectedID == qa.id)
        await #expect(throws: ActionError.self) { _ = try await f.registry.perform(.librarySelectItem, .select("nope")) }
        await #expect(throws: ActionError.self) { _ = try await f.registry.perform(.librarySetSection, .select("weird")) }
        await #expect(throws: ActionError.self) { _ = try await f.registry.perform(.librarySetSource, .select("weird")) }
    }

    @Test func previewLoadsFrontmatterBodyAndSkillFiles() async throws {
        let f = try await LibraryFixture(fixedPath: true); defer { f.remove() }
        await f.controller.reload()
        _ = try await f.registry.perform(.librarySetSection, .select("skills"))
        let skill = try #require(f.controller.items.first { $0.name == "portal-playbook" })
        _ = try await f.registry.perform(.librarySelectItem, .select(skill.id))
        for _ in 0 ..< 100 where f.controller.preview == nil { try await Task.sleep(for: .milliseconds(20)) }
        let preview = try #require(f.controller.preview)
        #expect(preview.body.contains("Use the REST query endpoint.") && preview.files.map(\.path) == ["SKILL.md", "fetch.py", "notes.md"] && preview.hasScripts)
    }

    /// AC-902: Open in Editor abre o arquivo do item; Reveal in Finder o revela.
    @Test func openInEditorAndRevealAct() async throws {
        let f = try await LibraryFixture(fixedPath: true); defer { f.remove() }
        await f.controller.reload()
        let agent = try #require(f.controller.items.first { $0.name == "data-engineer" })
        _ = try await f.registry.perform(.libraryOpenInEditor, .select(agent.id))
        _ = try await f.registry.perform(.libraryReveal, .press)
        #expect(f.opened == [agent.url] && f.revealed == [f.controller.selectedItem?.url ?? agent.url])
        await #expect(throws: ActionError.self) { _ = try await f.registry.perform(.libraryOpenInEditor, .select("nope")) }
    }

    /// AC-903 (parte da UI): ligar a skill vale só na sessão em foco, o aviso `Applies on next launch` aparece depois de um lançamento e
    /// nenhum arquivo nativo muda.
    @Test func enablingASkillIsPerSessionAdditiveAndTouchesNoFile() async throws {
        let f = try await LibraryFixture(fixedPath: true); defer { f.remove() }
        let before = f.fingerprint()
        await f.controller.reload()
        _ = try await f.registry.perform(.librarySetSection, .select("skills"))
        let skill = try #require(f.controller.items.first { $0.name == "portal-playbook" })
        #expect(f.controller.activation(of: skill) == .off)
        await f.controller.activations.noteLaunched(session: sessionID, ids: [])  // o Claude da sessão já rodou
        let result = try await f.registry.perform(.libraryToggleInSession, .select(skill.id))
        #expect(result.message == "on" && f.controller.activation(of: skill) == .thisSession && f.controller.hasPendingChange)
        let refs = await f.controller.activations.refs(for: sessionID)
        let other = await f.controller.activations.refs(for: UUID())
        #expect(refs.map(\.name) == ["portal-playbook"] && other.isEmpty, "em nenhuma outra sessão")
        #expect(f.fingerprint() == before.filter { _ in true }, "nenhum arquivo mudou")
        let off = try await f.registry.perform(.libraryToggleInSession, .select(skill.id))
        #expect(off.message == "off" && f.controller.activation(of: skill) == .off)
    }

    /// AC-905: a skill global não tem como ser desligada só na sessão; o controle diz por quê em vez de prometer.
    @Test func globalSkillsCannotBeTurnedOffAndSayWhy() async throws {
        let f = try await LibraryFixture(fixedPath: true); defer { f.remove() }
        await f.controller.reload()
        let global = try #require(f.controller.items.first { $0.name == "code-review" })
        #expect(f.controller.activation(of: global) == .alwaysOn)
        let message = "Claude Code loads global skills in every session"
        await #expect(throws: ActionError.failed(.libraryToggleInSession, message: message)) { _ = try await f.registry.perform(.libraryToggleInSession, .select(global.id)) }
        await #expect(throws: ActionError.failed(.contextToggleItem, message: message)) { _ = try await f.registry.perform(.contextToggleItem, .select(global.id)) }
        let unsupported = try #require(f.controller.items.first { $0.name == "listing-portal-scout" })
        await #expect(throws: ActionError.failed(.libraryToggleInSession, message: "Not available in Claude Code")) { _ = try await f.registry.perform(.libraryToggleInSession, .select(unsupported.id)) }
    }

    @Test func toggleNeedsASession() async throws {
        let f = try await LibraryFixture(fixedPath: true); defer { f.remove() }
        f.controller.currentSession = { nil }
        await f.controller.reload()
        let skill = try #require(f.controller.items.first { $0.name == "portal-playbook" })
        await #expect(throws: ActionError.disabled(.libraryToggleInSession, reason: "Select a session first.")) { _ = try await f.registry.perform(.libraryToggleInSession, .select(skill.id)) }
    }

    @Test func contextGroupsListSessionItemsFirstThenAvailableThenGlobal() async throws {
        let f = try await LibraryFixture(fixedPath: true); defer { f.remove() }
        await f.controller.reload()
        let skill = try #require(f.controller.items.first { $0.name == "portal-playbook" })
        _ = try await f.registry.perform(.contextToggleItem, .select(skill.id))
        let groups = f.context.groups()
        #expect(groups.map(\.id) == ["agents", "skills"])
        let skills = try #require(groups.last).rows
        #expect(skills.map(\.entry.name) == ["portal-playbook", "code-review", "proj-skill", "vercel:nextjs"])
        #expect(skills.map(\.activation) == [.thisSession, .alwaysOn, .alwaysOn, .alwaysOn])
        #expect(skills.first?.source == "This session" && skills[1].source == "Global · ~/.claude/skills" && skills[2].source == "Project · .claude/" && skills[3].source == "Plugin · vercel")
        let agents = try #require(groups.first).rows
        #expect(agents.map(\.entry.name) == ["data-engineer", "qa-engineer"], "agentes do Codex e do OpenCode não valem para o Claude")
    }

    @Test func restartAgentsAsksThenRelaunchesOnlyTheListedAgents() async throws {
        let f = try await LibraryFixture(fixedPath: true); defer { f.remove() }
        await #expect(throws: ActionError.disabled(.contextRestartWithResume, reason: "No agent in this session can be restarted.")) {
            _ = try await f.registry.perform(.contextRestartWithResume, .press)
        }
        let a = UUID(), b = UUID()
        f.agentsToRestart = [a, b]
        let asked = try await f.registry.perform(.contextRestartWithResume, .press)
        #expect(asked.message == "confirming")
        let done = try await f.registry.perform(.dialogRestartAgentsConfirm, .press)
        #expect(done.message == "restarted 2" && f.restarted == [a, b])
    }

    @Test func pageActionTogglesTheCenterPageAndEditProfilesOpensSettings() async throws {
        let f = try await LibraryFixture(fixedPath: true); defer { f.remove() }
        #expect(try await f.registry.perform(.pageLibrary, .press).message == "open" && f.page)
        #expect(try await f.registry.perform(.pageLibrary, .press).message == "open" && f.page, "pressing again keeps the page open")
        _ = try await f.registry.perform(.libraryEditProfiles, .press)
        #expect(f.settingsSection == "agents")
    }

    // MARK: Imagens

    @Test func pageShowsAgentsSkillsAndProfiles() async throws {
        let f = try await LibraryFixture(fixedPath: true); defer { f.remove() }
        f.controller.profiles = { ProfileCatalog().profiles }
        await f.controller.reload()
        for _ in 0 ..< 100 where f.controller.preview == nil { try await Task.sleep(for: .milliseconds(20)) }
        f.render(LibraryPageView(controller: f.controller), size: CGSize(width: 1100, height: 640), name: "pageAgents")
        let skill = try #require(f.controller.items.first { $0.name == "portal-playbook" })
        _ = try await f.registry.perform(.librarySetSection, .select("skills"))
        _ = try await f.registry.perform(.librarySelectItem, .select(skill.id))
        for _ in 0 ..< 100 where f.controller.preview == nil { try await Task.sleep(for: .milliseconds(20)) }
        f.render(LibraryPageView(controller: f.controller), size: CGSize(width: 1100, height: 700), name: "pageSkillsScripts")
        _ = try await f.registry.perform(.libraryToggleInSession, .select(skill.id))
        await f.controller.activations.noteLaunched(session: sessionID, ids: [])
        _ = try await f.registry.perform(.libraryToggleInSession, .select(skill.id))
        await f.controller.refreshSession()
        _ = try await f.registry.perform(.libraryToggleInSession, .select(skill.id))
        f.render(LibraryPageView(controller: f.controller), size: CGSize(width: 1100, height: 700), name: "pageSkillsPending")
        _ = try await f.registry.perform(.librarySetSection, .select("profiles"))
        f.render(LibraryPageView(controller: f.controller), size: CGSize(width: 1100, height: 520), name: "pageProfiles")
        f.render(LibraryPageView(controller: f.controller), size: CGSize(width: 760, height: 480), name: "pageProfilesMin")
    }

    @Test func emptyLibraryExplainsWhereItLooks() async throws {
        let f = try await LibraryFixture(fixedPath: true); defer { f.remove() }
        f.controller.loadRows = { _ in [] }
        await f.controller.reload()
        f.render(LibraryPageView(controller: f.controller), size: CGSize(width: 900, height: 360), name: "pageEmpty")
    }

    @Test func contextTabShowsGroupsTogglesAndTheBanner() async throws {
        let f = try await LibraryFixture(fixedPath: true); defer { f.remove() }
        await f.controller.reload()
        let skill = try #require(f.controller.items.first { $0.name == "portal-playbook" })
        await f.controller.activations.noteLaunched(session: sessionID, ids: [])
        _ = try await f.registry.perform(.contextToggleItem, .select(skill.id))
        f.agentsToRestart = [UUID()]
        f.render(ContextView(controller: f.context), size: CGSize(width: 310, height: 520), name: "contextTab")
        f.render(ContextView(controller: f.context), size: CGSize(width: 220, height: 420), name: "contextTabNarrow")
    }
}
