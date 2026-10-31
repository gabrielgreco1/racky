import RackyCore
import RackyDesignSystem
import RackyProtocol
import RackyTerminalCore
import AppKit
import Foundation
import SwiftUI
import Synchronization
import Testing

@testable import RackyUI

// T4-03 (AC-909, TA-411): `Insert Skill or Agent…` na palette, `[Insert in Prompt]` na Library e na aba Context. A colagem é a da T2-06:
// bracketed paste, origem `app-paste` (0x02), nunca Enter.

private let terminalID = UUID(uuidString: "00000000-0000-4000-8000-0000000000B1")!

@MainActor
final class InsertFixture {
    let lib: LibraryFixture
    let inserter: PromptInsertController
    let palette: PaletteController
    let overlays = OverlayRouter()
    var pasted: [(terminal: String, text: String)] = []
    var agent: FocusedAgent? = FocusedAgent(terminal: terminalID, provider: .claude)
    var focusReturned = 0
    var pageClosed = 0

    init() async throws {
        lib = try await LibraryFixture()
        let library = lib.controller
        // Registro próprio: o do `LibraryFixture` tem `prompt.insertItem` como no-op (a Library só precisa que o botão apareça).
        let registry = ActionRegistry(flags: SliceFlags(current: .slice4), surface: FakeSurface())
        self.registry = registry
        inserter = PromptInsertController(library: library, registry: { registry })
        let sidebar = SidebarModel()
        let workspace = WorkspaceModel(runtime: TerminalRuntime(
            configuration: .init(daemonHome: URL(fileURLWithPath: "/tmp/x"), daemonExecutable: nil, stopDaemonOnQuit: false, appSocketPath: "", loginEnvironment: { [:] }),
            registry: nil, elements: nil))
        palette = PaletteController(inserter: inserter, overlays: overlays, sidebar: sidebar, workspace: workspace, registry: { registry })
        inserter.focusedAgent = { [unowned self] in agent }
        inserter.returnFocusToTerminal = { [unowned self] in focusReturned += 1 }
        inserter.closeLibraryPage = { [unowned self] in pageClosed += 1 }
        inserter.openPalette = { [palette] in palette.open(insertMode: $0) }
        let fresh = registry
        try library.register(in: fresh)
        try inserter.register(in: fresh)
        try palette.register(in: fresh)
        try fresh.register(.dialogPasteToAgentConfirm) { [unowned self] arg in
            struct Payload: Decodable { var terminal: String; var text: String }
            let payload = try JSONDecoder().decode(Payload.self, from: Data((arg.value ?? "").utf8))
            pasted.append((payload.terminal, payload.text))
            return "pasted"
        }
        await library.reload()
    }

    let registry: ActionRegistry
    func remove() { lib.remove() }
}

@MainActor
@Suite("T4-03 - Insert Skill or Agent", .serialized, .offscreenAppKit)
struct PromptInsertTests {
    /// TA-411: a colagem é bracketed paste, origem 0x02 e nunca termina em Enter.
    @Test func theCommandIsPastedWithBracketedPasteAndNoEnter() async throws {
        let sent = SentBox()
        let sender = AgentPasteSender(bracketedPasteActive: true, send: { origin, data in sent.add(origin, data) }, copy: { _ in })
        let outcome = try await sender.paste("/code-review", provider: .claude)
        #expect(outcome == .pasted)
        let (origin, data) = try #require(sent.first)
        #expect(origin == .appPaste && Array(data) == AgentPaste.start + Array("/code-review".utf8) + AgentPaste.end)
        #expect(!data.contains(0x0d) && !data.contains(0x0a))
    }

    @Test func candidatesAreWhatTheFocusedAgentUnderstands() async throws {
        let f = try await InsertFixture(); defer { f.remove() }
        #expect(f.inserter.candidates().map(\.text) == ["/code-review", "@agent-data-engineer", "/proj-skill", "@agent-qa-engineer", "/vercel:nextjs"])
        f.agent = FocusedAgent(terminal: terminalID, provider: .codex)
        #expect(f.inserter.candidates().map(\.text) == ["$portal-playbook"])
        f.agent = FocusedAgent(terminal: terminalID, provider: .opencode)
        #expect(f.inserter.candidates().map(\.text) == ["@reviewer"])
        f.agent = FocusedAgent(terminal: terminalID, provider: .shell)
        #expect(f.inserter.candidates().isEmpty)
        f.agent = nil
        #expect(f.inserter.candidates().isEmpty)
    }

    @Test func insertInPromptPastesTheInvocationThenClosesTheLibraryAndReturnsFocus() async throws {
        let f = try await InsertFixture(); defer { f.remove() }
        let skill = try #require(f.lib.controller.items.first { $0.name == "code-review" })
        let result = try await f.registry.perform(.promptInsertItem, .select(skill.id))
        #expect(result.message == "pasted" && f.pasted.count == 1)
        #expect(f.pasted[0].terminal == terminalID.uuidString.lowercased() && f.pasted[0].text == "/code-review")
        #expect(f.focusReturned == 1 && f.pageClosed == 1)
        let agent = try #require(f.lib.controller.items.first { $0.name == "qa-engineer" })
        _ = try await f.registry.perform(.promptInsertItem, .select(agent.id))
        #expect(f.pasted.last?.text == "@agent-qa-engineer")
    }

    @Test func aSkillAddedToTheSessionIsInvokedThroughTheSessionPlugin() async throws {
        let f = try await InsertFixture(); defer { f.remove() }
        let skill = try #require(f.lib.controller.items.first { $0.name == "portal-playbook" })
        #expect(f.inserter.candidates().contains { $0.entry.id == skill.id } == false, "ainda não vale para o Claude desta sessão")
        _ = try await f.registry.perform(.libraryToggleInSession, .select(skill.id))
        _ = try await f.registry.perform(.promptInsertItem, .select(skill.id))
        #expect(f.pasted.last?.text == "/racky-session:portal-playbook")
    }

    @Test func withoutAnAgentFocusedTheActionIsDisabledWithTheReason() async throws {
        let f = try await InsertFixture(); defer { f.remove() }
        f.agent = nil
        let skill = try #require(f.lib.controller.items.first { $0.name == "code-review" })
        let reason = "Focus an agent terminal first."
        await #expect(throws: ActionError.disabled(.promptInsertItem, reason: reason)) { _ = try await f.registry.perform(.promptInsertItem, .select(skill.id)) }
        await #expect(throws: ActionError.disabled(.promptInsertSkillOrAgent, reason: reason)) { _ = try await f.registry.perform(.promptInsertSkillOrAgent, .press) }
        #expect(f.pasted.isEmpty)
    }

    @Test func theCommandOpensThePaletteInInsertModeAndEnterInsertsWithoutSendingAnything() async throws {
        let f = try await InsertFixture(); defer { f.remove() }
        _ = try await f.registry.perform(.promptInsertSkillOrAgent, .press)
        #expect(f.palette.isOpen && f.palette.model.insertMode && f.palette.model.placeholder == "Insert a skill or agent into the focused prompt…")
        #expect(f.palette.model.rows.map(\.title) == ["code-review", "data-engineer", "proj-skill", "qa-engineer", "vercel:nextjs"])
        #expect(f.palette.model.rows.allSatisfy { $0.disabledReason == nil })
        f.palette.model.query = "review"
        f.palette.model.queryChanged()
        let review = try #require(f.lib.controller.items.first { $0.name == "code-review" })
        #expect(f.palette.model.rows.map(\.title) == ["code-review"] && f.palette.model.highlighted == "skill.\(review.id)")
        let done = try await f.registry.perform(.paletteOpenRow, .press)
        #expect(done.message == "pasted" && f.pasted.map(\.text) == ["/code-review"] && !f.palette.isOpen && f.focusReturned == 1)
    }

    @Test func aLeadingSlashSwitchesTheOpenPaletteToInsertMode() async throws {
        let f = try await InsertFixture(); defer { f.remove() }
        #expect(try await f.registry.perform(.paletteOpen, .press).message == "open")
        #expect(!f.palette.model.insertMode)
        f.palette.model.query = "/qa"
        f.palette.model.queryChanged()
        #expect(f.palette.model.insertMode && f.palette.model.query == "qa" && f.palette.model.rows.map(\.title) == ["qa-engineer"])
        #expect(try await f.registry.perform(.paletteOpen, .press).message == "closed")
    }

    @Test func insertModeRowsAreDisabledWithoutAnAgentAndEnterSaysWhy() async throws {
        let f = try await InsertFixture(); defer { f.remove() }
        f.agent = nil
        f.palette.open(insertMode: true)
        let rows = f.palette.model.rows
        #expect(!rows.isEmpty && rows.allSatisfy { $0.disabledReason == "Focus an agent terminal first." })
        await #expect(throws: ActionError.failed(.paletteOpenRow, message: "Focus an agent terminal first.")) {
            _ = try await f.registry.perform(.paletteOpenRow, .select(rows[0].id))
        }
        #expect(f.pasted.isEmpty)
    }

    @Test func theCommandsGroupOffersInsertSkillOrAgentAndReopensInInsertMode() async throws {
        let f = try await InsertFixture(); defer { f.remove() }
        f.palette.open(insertMode: false)
        f.palette.model.query = "insert"
        f.palette.model.queryChanged()
        let row = try #require(f.palette.model.rows.first { $0.kind == "command" })
        #expect(row.title == "Insert Skill or Agent…" && row.group == "Commands")
        _ = try await f.registry.perform(.paletteOpenRow, .select(row.id))
        #expect(f.palette.isOpen && f.palette.model.insertMode)
    }

    @Test func paletteImages() async throws {
        let f = try await InsertFixture(); defer { f.remove() }
        f.palette.open(insertMode: true)
        f.lib.render(PaletteView(model: f.palette.model).background(DS.Color.overlayCard), size: CGSize(width: 720, height: 340), name: "paletteInsert")
        f.agent = nil
        f.palette.model.refresh()
        f.lib.render(PaletteView(model: f.palette.model).background(DS.Color.overlayCard), size: CGSize(width: 720, height: 340), name: "paletteInsertDisabled")
        f.palette.model.insertMode = false
        f.palette.model.query = ""
        f.palette.model.refresh()
        f.lib.render(PaletteView(model: f.palette.model).background(DS.Color.overlayCard), size: CGSize(width: 720, height: 220), name: "paletteDefault")
    }
}

nonisolated final class SentBox: Sendable {
    private let items = Mutex<[(InputOrigin, Data)]>([])
    func add(_ origin: InputOrigin, _ data: Data) { items.withLock { $0.append((origin, data)) } }
    var first: (InputOrigin, Data)? { items.withLock { $0.first } }
}
