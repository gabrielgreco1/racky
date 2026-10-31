import RackyCore
import RackyDesignSystem
import RackyProtocol
import RackyStore
import Foundation
import Testing

@testable import RackyUI

/// Linhas dos subagentes sob o agente pai (hooks SubagentStart/SubagentStop, com ou sem computador): projeção pura, sem janela.
@MainActor
@Suite struct SubagentRowsTests {
    static let now = Date(timeIntervalSince1970: 1_900_000_000)

    private func fixture(children: [SubagentInfo]) -> (input: SidebarInput, session: Session, terminal: Terminal) {
        let session = Session(kind: .clean, folderPath: "/tmp/s", managedFolder: true, title: "houston", createdAt: Self.now.addingTimeInterval(-7200))
        let tab = Tab(sessionID: session.id, title: "Claude", layout: .leaf(Pane(content: .terminal(UUID()))))
        let terminal = Terminal(
            tabID: tab.id, provider: .claude, title: "Claude Code", cwd: "/tmp/s", launchSpec: LaunchSpec(provider: .claude), state: .running,
            createdAt: Self.now.addingTimeInterval(-7200), startedAt: Self.now.addingTimeInterval(-7200))
        var center = AttentionCenter()
        center.apply(
            TerminalActivity(terminalID: terminal.id, activity: .waitingOnSubagents, liveChildren: children.filter { $0.phase == .running }.count, changedAt: Self.now, children: children),
            context: AttentionContext(sessionID: session.id, sessionTitle: "houston", provider: .claude), now: Self.now)
        var input = SidebarInput(snapshot: StoreSnapshot(sessions: [session], tabs: [tab], terminals: [terminal]))
        input.now = Self.now
        input.attention = center
        return (input, session, terminal)
    }

    private let running = SubagentInfo(agentID: "a1", agentType: "general-purpose", title: "Study the Houston listings portal", phase: .running, startedAt: Self.now.addingTimeInterval(-38 * 60))
    private let done = SubagentInfo(
        agentID: "a2", agentType: "racky-worker-1", title: nil, phase: .done, startedAt: Self.now.addingTimeInterval(-3 * 3600), endedAt: Self.now.addingTimeInterval(-2 * 3600))

    @Test func everySubagentBecomesAChildRowOfItsAgentWithTitleStateAndElapsedTime() throws {
        let (input, session, terminal) = fixture(children: [running, done])
        let projection = SidebarProjector.build(input)
        let card = try #require(projection.cleanSessions.first { $0.id == session.id })
        let agent = try #require(card.agentRows.first { $0.id == terminal.id })
        #expect(agent.children.map(\.id) == ["a1", "a2"])
        #expect(agent.children[0].title == "Study the Houston listings portal" && agent.children[0].glyph == .working)
        #expect(agent.children[1].title == "racky-worker-1", "without a task title the subagent type is shown")
        #expect(agent.children[1].glyph == .done)
        #expect(agent.children[0].elapsedText(now: Self.now) == "38m")
        #expect(agent.children[1].elapsedText(now: Self.now) == "1h", "a finished subagent's time stops at its end")
        #expect(agent.children[0].elapsedText(now: Self.now.addingTimeInterval(3600 * 24 * 2)) == "2d")
        #expect(SubagentRowData(id: "x", title: "t", phase: .running, startedAt: Self.now.addingTimeInterval(-42), endedAt: nil, subtitle: nil, computer: nil).elapsedText(now: Self.now) == "42s")
        #expect(!agent.childrenCollapsed)
    }

    @Test func theChevronCollapsesOnlyThatAgentsChildren() throws {
        var (input, session, terminal) = fixture(children: [running])
        input.collapsedChildren = [terminal.id]
        let card = try #require(SidebarProjector.build(input).cleanSessions.first { $0.id == session.id })
        let agent = try #require(card.agentRows.first)
        #expect(agent.childrenCollapsed && agent.children.count == 1, "the rows stay in the data; the view hides them")
    }

    @Test func aSubagentWithAComputerCarriesItsNameForTheHoverCardAndHidesTheDuplicateComputerRow() throws {
        var (input, session, _) = fixture(children: [running, done])
        input.agentComputers = ["a1": "houston-listings"]
        let snapshot = ViewerSnapshot(name: "houston-listings", state: .inUse, display: "headless", control: .agent, proxy: "direct", url: "https://example.test/", lastDoing: "Opened the search form")
        let computer = ComputerChildRow(ComputerRow(snapshot: snapshot, thumbnail: nil, sessionTitle: "houston", owner: nil, lastActivity: Self.now))
        let reserved = ComputerChildRow(ComputerRow(
            snapshot: ViewerSnapshot(name: "austin-tx", state: .queued, display: "headless", control: .agent, proxy: "direct", queuePosition: 1), thumbnail: nil,
            sessionTitle: "houston", owner: nil, lastActivity: Self.now))
        input.computers = [session.id: [computer, reserved]]
        let card = try #require(SidebarProjector.build(input).cleanSessions.first { $0.id == session.id })
        let agent = try #require(card.agentRows.first)
        #expect(agent.children[0].computer == "houston-listings" && agent.children[1].computer == nil)
        #expect(card.computers.map(\.id) == ["austin-tx"], "a computer already shown by its subagent isn't listed twice; a reserved one still is")
        #expect(reserved.stateLabel == "Queued · 1")
    }

    @Test func nothingForDeadTerminalsOrAgentsWithoutSubagents() throws {
        var (input, session, terminal) = fixture(children: [running])
        input.snapshot.terminals[0].state = .exited
        let exited = try #require(SidebarProjector.build(input).cleanSessions.first { $0.id == session.id })
        #expect(exited.agentRows.first?.children.isEmpty == true)
        _ = terminal
        let (plain, plainSession, _) = fixture(children: [])
        let card = try #require(SidebarProjector.build(plain).cleanSessions.first { $0.id == plainSession.id })
        #expect(card.agentRows.first?.children.isEmpty == true)
    }

    @Test func needsInputAndFailedSubagentsHaveTheirOwnGlyphs() {
        let needs = SubagentRowData(id: "n", title: "t", phase: .needsInput, startedAt: Self.now, endedAt: nil, subtitle: nil, computer: nil)
        let failed = SubagentRowData(id: "f", title: "t", phase: .failed, startedAt: Self.now, endedAt: Self.now, subtitle: nil, computer: nil)
        #expect(needs.glyph == .needsInput && failed.glyph == .dot(DS.ColorSpec.agentFailed))
        #expect(needs.stateLabel == "Needs input" && failed.stateLabel == "Failed")
    }

    @Test func toggleChildrenIsInMemoryAndPerTerminal() {
        let model = SidebarModel()
        let a = UUID(), b = UUID()
        model.toggleChildren(terminal: a)
        #expect(model.collapsedChildren == [a])
        model.toggleChildren(terminal: b)
        model.toggleChildren(terminal: a)
        #expect(model.collapsedChildren == [b])
    }
}
