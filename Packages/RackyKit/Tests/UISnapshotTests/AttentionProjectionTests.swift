import RackyCore
import RackyDesignSystem
import RackyProtocol
import RackyStore
import Foundation
import Testing

@testable import RackyUI

/// Estado de atividade na projeção da sidebar (02 §2.6, 03 §2.6–§2.7, 01 §6.3): glifo, rótulo, linha de agente,
/// agregação do card e não lido. Funções puras, sem janela.
@MainActor
@Suite(.offscreenAppKit) struct AttentionProjectionTests {
    static let now = Date(timeIntervalSince1970: 1_900_000_000)

    func terminal(_ state: TerminalProcessState = .running, provider: TerminalProvider = .claude, exit: Int? = nil) -> Terminal {
        Terminal(tabID: UUID(), provider: provider, title: "Claude Code", cwd: "/tmp", launchSpec: LaunchSpec(provider: provider), state: state, exitCode: exit)
    }

    func center(_ t: Terminal, _ activity: AgentActivity, unreadDone: Bool = false, children: Int = 0, reason: String? = nil, subtitle: String? = nil) -> AttentionCenter {
        var c = AttentionCenter()
        let ctx = AttentionContext(sessionID: UUID(), sessionTitle: "s", provider: t.provider)
        c.apply(
            TerminalActivity(terminalID: t.id, activity: activity, reason: reason, subtitle: subtitle, liveChildren: children, changedAt: Self.now),
            context: ctx, now: Self.now)
        if activity == .done, !unreadDone { c.markViewed(terminals: [t.id], now: Self.now) }
        return c
    }

    func status(_ t: Terminal, _ c: AttentionCenter) -> SidebarProjector.StatusSample { SidebarProjector.status(for: t, center: c, now: Self.now) }

    @Test func eachActivityMapsToItsGlyphAndLabel() {
        let t = terminal()
        let expectations: [(AgentActivity, DSIndicatorGlyph, String)] = [
            (.starting, .spinner, "Starting…"), (.idle, .dot(DS.ColorSpec.agentIdle), "Idle"), (.working, .working, "Working"),
            (.needsInput(.question), .needsInput, "Needs input"), (.needsInput(.permission), .needsInput, "Needs input"),
            (.done, .done, "Done"), (.failed, .dot(DS.ColorSpec.agentFailed), "Failed"),
            (.interrupted, .dot(DS.ColorSpec.agentInterrupted), "Interrupted"), (.unknown, .unknown, "Status unavailable"),
        ]
        for (activity, glyph, label) in expectations {
            let s = status(t, center(t, activity))
            #expect(s.glyph == glyph && s.label == label, "\(activity)")
        }
        let waiting = status(t, center(t, .waitingOnSubagents, children: 2))
        #expect(waiting.glyph == .waiting && waiting.label == "Waiting on 2 subagents")
        #expect(status(t, center(t, .waitingOnSubagents, children: 1)).label == "Waiting on 1 subagent")
    }

    @Test func withoutHooksAnAliveAgentStaysStatusUnavailableAndShellsHaveNoGlyph() {
        #expect(status(terminal(), AttentionCenter()).glyph == .unknown)
        let shell = terminal(provider: .shell)
        #expect(status(shell, center(shell, .working)).glyph == .none, "shell não tem estado de agente")
    }

    @Test func processStateWinsOverAnOldActivityWhenTheProcessIsGone() {
        let exited = terminal(.exited, exit: 1)
        #expect(status(exited, center(exited, .working)).glyph == .dot(DS.ColorSpec.agentFailed))
        let interrupted = terminal(.interrupted)
        #expect(status(interrupted, center(interrupted, .working)).glyph == .dot(DS.ColorSpec.agentInterrupted))
    }

    @Test func sessionAggregateIsTheWorstStateAndReadDoneRanksBelowUnreadDone() {
        let working = terminal(), asking = terminal(), doneRead = terminal(), doneUnread = terminal()
        func merged(_ pairs: [(Terminal, AgentActivity, Bool)]) -> AttentionCenter {
            var c = AttentionCenter()
            let ctx = AttentionContext(sessionID: UUID(), sessionTitle: "s", provider: .claude)
            for (t, a, unread) in pairs {
                c.apply(TerminalActivity(terminalID: t.id, activity: a, changedAt: Self.now), context: ctx, now: Self.now)
                if a == .done, !unread { c.markViewed(terminals: [t.id], now: Self.now) }
            }
            return c
        }
        let c = merged([(working, .working, false), (asking, .needsInput(.question), false), (doneRead, .done, false), (doneUnread, .done, true)])
        func agg(_ ts: [Terminal]) -> SidebarProjector.StatusSample? {
            SidebarProjector.aggregate(ts.map { status($0, c) })
        }
        #expect(agg([working, asking])?.glyph == .needsInput)
        #expect(agg([working, doneUnread])?.glyph == .working)
        #expect(agg([doneRead, doneUnread])?.rank == 60 && agg([doneRead])?.rank == 30)
        #expect(SidebarProjector.cardGlyph(.done) == .dot(DS.ColorSpec.agentDone), "no card o done é bolinha")
        #expect(SidebarProjector.cardGlyph(.working) == .working)
    }

    @Test func cardsAndRowsCarryStateUnreadAndTheLastMessage() {
        let cast = AttentionFixtures.cast(now: Self.now, home: "/Users/test")
        var c = AttentionCenter()
        func put(_ key: String, _ activity: AgentActivity, message: String? = nil, reason: String? = nil, subtitle: String? = nil, children: Int = 0) {
            let agent = AttentionFixtures.agents.first { $0.key == key }!
            let ctx = AttentionContext.contexts(in: cast.snapshot)[agent.terminalID]
            c.apply(
                TerminalActivity(terminalID: agent.terminalID, activity: activity, lastMessage: message, reason: reason, subtitle: subtitle, liveChildren: children, changedAt: Self.now),
                context: ctx, now: Self.now)
        }
        put("permission", .needsInput(.permission), reason: "Wants to run: `git push origin fix/pagination`")
        put("working", .working, subtitle: "Running Bash")
        put("done", .done, message: "Opened PR #412")
        put("waiting", .waitingOnSubagents, children: 2)
        put("failed", .failed, reason: "exited with 1")
        var snapshot = cast.snapshot
        // A última mensagem vive no terminal (projeção do `ActivityService`).
        snapshot.terminals = snapshot.terminals.map { t in
            var copy = t
            if t.id == AttentionFixtures.agents.first(where: { $0.key == "done" })!.terminalID { copy.lastMessage = "Opened PR #412" }
            return copy
        }
        var input = SidebarInput(snapshot: snapshot, now: Self.now, home: "/Users/test")
        input.attention = c
        let projection = SidebarProjector.build(input)
        let cards = projection.projects.flatMap(\.sessions) + projection.cleanSessions
        func card(_ key: String) -> SessionCardData {
            let title = AttentionFixtures.agents.first { $0.key == key }!.sessionTitle
            return cards.first { $0.title == title }!
        }
        #expect(card("permission").glyph == .needsInput)
        #expect(card("permission").agentRows[0].lead == "Wants to run: `git push origin fix/pagination`")
        #expect(card("working").glyph == .working && card("working").agentRows[0].trail == "Running Bash")
        #expect(card("done").glyph == .dot(DS.ColorSpec.agentDone) && card("done").unread)
        #expect(card("done").agentRows[0].lead == "Opened PR #412" && card("done").agentRows[0].unread && card("done").agentRows[0].glyph == .done)
        #expect(card("waiting").stateLabel == "Waiting on 2 subagents" && card("waiting").agentRows[0].trail == "Waiting on 2 subagents")
        #expect(card("failed").glyph == .dot(DS.ColorSpec.agentFailed) && card("failed").agentRows[0].trail == "Exited with code 1")
        #expect(card("idle").glyph == .unknown, "sem eventos ainda: Status unavailable")
        #expect(!card("working").unread && !card("permission").unread)
        #expect(card("done").a11yLabel.contains("Done") && card("done").a11yLabel.contains("Unread"))
    }

    @Test func unreadBellOnAnyTerminalMakesTheCardUnread() {
        let cast = AttentionFixtures.cast(now: Self.now, home: "/Users/test")
        var c = AttentionCenter()
        c.bell(terminal: AttentionFixtures.agents[0].terminalID)
        var input = SidebarInput(snapshot: cast.snapshot, now: Self.now, home: "/Users/test")
        input.attention = c
        let projection = SidebarProjector.build(input)
        let cards = projection.projects.flatMap(\.sessions) + projection.cleanSessions
        #expect(cards.filter(\.unread).map(\.title) == [AttentionFixtures.agents[0].sessionTitle])
    }

    @Test func idleTimeoutTurnsASeenDoneIntoAnIdleDot() {
        let t = terminal()
        var c = center(t, .done, unreadDone: true)
        c.markViewed(terminals: [t.id], now: Self.now)
        let later = Self.now.addingTimeInterval(31 * 60)
        let s = SidebarProjector.status(for: t, center: c, now: later)
        #expect(s.glyph == .dot(DS.ColorSpec.agentIdle) && s.label == "Idle")
    }
}
