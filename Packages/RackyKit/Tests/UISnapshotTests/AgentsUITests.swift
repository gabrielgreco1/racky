import RackyCore
import RackyDesignSystem
import RackyProtocol
import AppKit
import Foundation
import SnapshotTesting
import SwiftUI
import Testing

@testable import RackyUI

// Backlog 25 (a, b): seção Agents da sidebar com seções recolhíveis e a página do agente. Pasta de agentes em diretório temporário
// (`RACKY_AGENTS_ROOT`); nada toca ~/Racky nem as pastas dos CLIs.

@MainActor
final class AgentsFixture {
    let base: URL
    let controller: AgentsController
    let registry: ActionRegistry
    var pages: [CenterPage] = []
    var started: [String] = []
    var secrets = ["zyte", "accela-pass"]

    init(seed: Bool = true) async throws {
        base = URL(fileURLWithPath: "/private/tmp/abx-agents-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        controller = AgentsController(home: base, root: base.appendingPathComponent("agents", isDirectory: true))
        registry = ActionRegistry(flags: SliceFlags(current: .slice4), surface: FakeSurface())
        if seed {
            for (name, desc) in [("qa-engineer", "Tests and regression checks"), ("web-scraper", "Extracts data from websites"), ("data-engineer", "Ingestion pipelines")] {
                try controller.store.create(AgentDefinition(name: name, description: desc, instructions: "You are \(name).", skills: ["tdd"], tone: "Short and direct"))
            }
        }
        controller.showPage = { [unowned self] in pages.append($0) }
        controller.startSession = { [unowned self] in started.append($0) }
        let names = secrets
        controller.loadSecretNames = { names }
        controller.attachables = { [AgentAttachable(kind: .computer, title: "wi-milwaukee", reference: "wi-milwaukee"), AgentAttachable(kind: .dataset, title: "silver permits", reference: "01HZ")] }
        try controller.register(in: registry)
        await controller.reload()
    }

    func remove() { try? FileManager.default.removeItem(at: base) }

    func render(_ view: some View, size: CGSize, name: String, test: String = "agents", line: UInt = #line) {
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
            assertSnapshot(of: host, as: .image(precision: 0.98, perceptualPrecision: 0.97), named: name, testName: test, line: line)
        }
    }
}

@MainActor
@Suite("Backlog 25 - Agents", .serialized, .offscreenAppKit)
struct AgentsUITests {
    @Test func openingAnAgentSelectsItAndShowsItsPage() async throws {
        let f = try await AgentsFixture(); defer { f.remove() }
        #expect(f.controller.agents.map(\.name) == ["data-engineer", "qa-engineer", "web-scraper"])
        #expect(f.controller.images.count == 3, "cada agente tem rosto: o SVG gerado ao criar")
        _ = try await f.registry.perform(.agentsOpen, .select("qa-engineer"))
        #expect(f.controller.selectedName == "qa-engineer" && f.pages == [.agent("qa-engineer")])
        await #expect(throws: ActionError.self) { _ = try await f.registry.perform(.agentsOpen, .select("nobody")) }
    }

    @Test func fieldsComputerPresetAndSkillsPersistToDisk() async throws {
        let f = try await AgentsFixture(); defer { f.remove() }
        _ = try await f.registry.perform(.agentsOpen, .select("qa-engineer"))
        _ = try await f.registry.perform(.agentsSetField, .set("tone=Seco e direto"))
        _ = try await f.registry.perform(.agentsSetField, .set("instructions=Line one\nLine = two"))
        _ = try await f.registry.perform(.agentsSetField, .select("computer.enabled=on"))
        _ = try await f.registry.perform(.agentsSetField, .select("computer.screen=on"))
        _ = try await f.registry.perform(.agentsSetField, .select("computer.memory=4096"))
        _ = try await f.registry.perform(.agentsSetField, .set("computer.country=us"))
        _ = try await f.registry.perform(.agentsSetField, .set("computer.packages=pytest, playwright"))
        _ = try await f.registry.perform(.agentsSetField, .set("skills=tdd, qa"))
        let onDisk = try f.controller.store.load("qa-engineer")
        #expect(onDisk.tone == "Seco e direto" && onDisk.instructions == "Line one\nLine = two" && onDisk.skills == ["tdd", "qa"])
        #expect(onDisk.computer == AgentComputerPreset(screen: true, memoryMB: 4096, proxyCountry: "US", packages: ["pytest", "playwright"]))
        _ = try await f.registry.perform(.agentsSetField, .select("computer.enabled=off"))
        #expect(try f.controller.store.load("qa-engineer").computer == nil)
        await #expect(throws: ActionError.self) { _ = try await f.registry.perform(.agentsSetField, .set("nope=1")) }
    }

    @Test func avatarRegeneratesAndPhotoReplacesIt() async throws {
        let f = try await AgentsFixture(); defer { f.remove() }
        _ = try await f.registry.perform(.agentsOpen, .select("web-scraper"))
        let before = f.controller.images["web-scraper"]
        _ = try await f.registry.perform(.agentsRegenerateAvatar, .press)
        #expect(f.controller.agent("web-scraper")?.avatar.variant == 1 && f.controller.images["web-scraper"] !== before)
        let photo = f.base.appendingPathComponent("me.png")
        let png = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try png.representation(using: .png, properties: [:])!.write(to: photo)
        _ = try await f.registry.perform(.agentsSetPhoto, .select(photo.path))
        #expect(f.controller.agent("web-scraper")?.avatar.kind == .photo)
        await #expect(throws: ActionError.self) { _ = try await f.registry.perform(.agentsSetPhoto, .select(f.base.appendingPathComponent("x.exe").path)) }
    }

    @Test func variablesAreCheckedAgainstTheVaultAndSitesNeedAHost() async throws {
        let f = try await AgentsFixture(); defer { f.remove() }
        _ = try await f.registry.perform(.agentsOpen, .select("qa-engineer"))
        _ = try await f.registry.perform(.agentsSetVariable, .set("ZYTE_API_KEY=zyte"))
        #expect(try f.controller.store.load("qa-engineer").variables == [AgentVariable(envName: "ZYTE_API_KEY", secretName: "zyte")])
        await #expect(throws: ActionError.self) { _ = try await f.registry.perform(.agentsSetVariable, .set("X=missing")) }
        await #expect(throws: ActionError.self) { _ = try await f.registry.perform(.agentsSetVariable, .set("RACKY_X=zyte")) }
        await #expect(throws: ActionError.self) { _ = try await f.registry.perform(.agentsSetVariable, .set("1BAD=zyte")) }
        _ = try await f.registry.perform(.agentsRemoveVariable, .select("ZYTE_API_KEY"))
        #expect(try f.controller.store.load("qa-engineer").variables.isEmpty)
        _ = try await f.registry.perform(.agentsAddSite, .set("GitHub.com"))
        #expect(try f.controller.store.load("qa-engineer").sites.map(\.host) == ["github.com"])
        await #expect(throws: ActionError.self) { _ = try await f.registry.perform(.agentsAddSite, .set("https://x.com/a")) }
        _ = try await f.registry.perform(.agentsRemoveSite, .select("github.com"))
        #expect(try f.controller.store.load("qa-engineer").sites.isEmpty)
    }

    @Test func attachmentsAndMemoryRoundTripThroughActions() async throws {
        let f = try await AgentsFixture(); defer { f.remove() }
        _ = try await f.registry.perform(.agentsOpen, .select("qa-engineer"))
        _ = try await f.registry.perform(.agentsAddAttachment, .select("dataset|silver permits|01HZ"))
        #expect(f.controller.attachments.attachments.map(\.title) == ["silver permits"])
        #expect(try f.controller.store.attachments("qa-engineer").attachments.count == 1)
        let id = f.controller.attachments.attachments[0].id.uuidString
        _ = try await f.registry.perform(.agentsRemoveAttachment, .select(id))
        #expect(f.controller.attachments.attachments.isEmpty)
        _ = try await f.registry.perform(.agentsMemoryAdd, .set("milwaukee smoke|fails when the permit type is empty"))
        #expect(f.controller.memoryEntries.count == 1)
        let entry = f.controller.memoryEntries[0]
        _ = try await f.registry.perform(.agentsMemoryEdit, .set("\(entry.id)|milwaukee|uses overrides.yaml"))
        _ = try await f.registry.perform(.agentsMemorySearch, .set("overrides"))
        #expect(f.controller.visibleMemory.map(\.id) == [entry.id])
        _ = try await f.registry.perform(.agentsMemorySearch, .set("zzz"))
        #expect(f.controller.visibleMemory.isEmpty)
        _ = try await f.registry.perform(.agentsMemoryDelete, .select("\(entry.id)"))
        #expect(f.controller.memoryEntries.isEmpty)
    }

    @Test func deleteAsksFirstAndRemovesTheFolderOnTheSecondStep() async throws {
        let f = try await AgentsFixture(); defer { f.remove() }
        _ = try await f.registry.perform(.agentsOpen, .select("web-scraper"))
        _ = try await f.registry.perform(.agentsDelete, .press)
        #expect(f.controller.confirmingDelete == "web-scraper" && f.controller.store.exists("web-scraper"))
        _ = try await f.registry.perform(.agentsDelete, .select("web-scraper"))
        #expect(!f.controller.store.exists("web-scraper") && f.controller.agent("web-scraper") == nil)
    }

    @Test func sidebarSectionsCollapseAndRemember() throws {
        let model = SidebarModel()
        let registry = ActionRegistry(flags: SliceFlags(current: .slice4), surface: FakeSurface())
        try model.registerActions(in: registry)
        #expect(!model.isCollapsed(section: "agents"))
        model.toggleSection("agents")
        model.toggleSection("projects")
        #expect(model.isCollapsed(section: "agents") && model.isCollapsed(section: "projects") && !model.isCollapsed(section: "sessions"))
        model.toggleSection("agents")
        #expect(!model.isCollapsed(section: "agents"))
    }

    @Test func sidebarToggleActionRejectsUnknownSections() async throws {
        let model = SidebarModel()
        let registry = ActionRegistry(flags: SliceFlags(current: .slice4), surface: FakeSurface())
        try model.registerActions(in: registry)
        _ = try await registry.perform(.sidebarToggleSection, .select("sessions"))
        #expect(model.isCollapsed(section: "sessions"))
        await #expect(throws: ActionError.self) { _ = try await registry.perform(.sidebarToggleSection, .select("other")) }
    }

    @Test func agentPageAndSidebarRows() async throws {
        let f = try await AgentsFixture(); defer { f.remove() }
        try f.controller.store.update({
            var a = try f.controller.store.load("qa-engineer")
            a.computer = AgentComputerPreset(screen: true, memoryMB: 4096, proxyCountry: "US", packages: ["pytest", "playwright"])
            a.variables = [AgentVariable(envName: "ZYTE_API_KEY", secretName: "zyte"), AgentVariable(envName: "ACCELA_USER", secretName: "accela-pass")]
            a.sites = [AgentSite(host: "aca-prod.accela.com", secretName: "s1", savedAt: Date().addingTimeInterval(-86400 * 2), expiresAt: Date().addingTimeInterval(86400)),
                       AgentSite(host: "app.hubspot.com", secretName: "s2", savedAt: Date().addingTimeInterval(-86400 * 9), expiresAt: Date().addingTimeInterval(-60))]
            return a
        }())
        await f.controller.reload()
        _ = try await f.registry.perform(.agentsOpen, .select("qa-engineer"))
        _ = try await f.registry.perform(.agentsAddAttachment, .select("computer|wi-milwaukee|wi-milwaukee"))
        _ = try await f.registry.perform(.agentsMemoryAdd, .set("milwaukee smoke|fails when the permit type is empty, override in overrides.yaml"))
        f.render(AgentPageView(controller: f.controller, name: "qa-engineer"), size: CGSize(width: 1100, height: 1300), name: "page")
        f.render(
            VStack(alignment: .leading, spacing: 0) { ForEach(f.controller.agents) { SidebarAgentRow(controller: f.controller, agent: $0) } }.padding(DS.Space.s2).background(DS.Color.sidebar),
            size: CGSize(width: 280, height: 140), name: "sidebarRows")
        #expect(f.controller.needsLogin == ["qa-engineer"])
    }
}

@MainActor
@Suite("Backlog 25 - Library merged by name", .serialized, .offscreenAppKit)
struct AgentsLibraryTests {
    @Test func theSameAgentInClaudeAndCodexIsOneRowAndRackyAgentsJoinIt() async throws {
        let f = try await AgentsFixture(); defer { f.remove() }
        let home = f.base.appendingPathComponent("home", isDirectory: true)
        func write(_ rel: String, _ text: String) throws {
            let url = home.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try write(".claude/agents/data-engineer.md", "---\nname: data-engineer\ndescription: Owns ingestion\n---\nBody\n")
        try write(".codex/agents/data-engineer.toml", "name = \"data-engineer\"\ndescription = \"Owns ingestion\"\ndeveloper_instructions = \"\"\"\nBody\n\"\"\"\n")
        try write(".claude/agents/only-claude.md", "---\ndescription: Claude only\n---\nBody\n")
        let library = LibraryController()
        library.loadRows = { roots in CatalogScanner.scan(CatalogRoots(home: home, projectRoots: roots)).items }
        library.rackyAgents = { f.controller.libraryEntries }
        await library.reload()
        let names = library.visibleItems.map(\.name)
        #expect(names.filter { $0 == "data-engineer" }.count == 1, "um agente por nome")
        let merged = try #require(library.visibleItems.first { $0.name == "data-engineer" })
        #expect(merged.category == .racky, "a cópia do Racky vence a das pastas dos CLIs")
        #expect(merged.clients == [.claude, .codex, .opencode] && merged.otherPaths.count == 2)
        let claudeOnly = try #require(library.visibleItems.first { $0.name == "only-claude" })
        #expect(claudeOnly.clients == [.claude] && claudeOnly.otherPaths.isEmpty)
        #expect(names.contains("qa-engineer") && names.contains("web-scraper"))
    }

    @Test func draggedRackyAgentBecomesAnActivationTheLaunchTurnsIntoAnAgentDefinition() async throws {
        let f = try await AgentsFixture(); defer { f.remove() }
        let entry = f.controller.libraryEntry(try #require(f.controller.agent("qa-engineer")))
        #expect(entry.activation(sessionFolder: nil, added: []) == .off, "agente do Racky não é global: liga por sessão")
        #expect(entry.activation(sessionFolder: nil, added: [entry.id]) == .thisSession)
        let injection = try #require(SessionLibraryBuilder.build([ActivationRef(entry)]))
        let def = try #require(injection.agents["qa-engineer"])
        guard case .string(let prompt) = def["prompt"] else { Issue.record("no prompt"); return }
        #expect(prompt == "You are qa-engineer.")
        #expect(AgentsController.agentName(fromDrag: AgentsController.dragPayload("qa-engineer")) == "qa-engineer")
        #expect(AgentsController.agentName(fromDrag: "something else") == nil)
    }
}
