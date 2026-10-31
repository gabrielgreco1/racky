import RackyProtocol
import Foundation
import Testing

@testable import RackyCore

/// Fila de atenção, leitura, agregação e Inbox (01 §5.12, 06 §3.5–§3.6): lógica pura, sem relógio nem UI.
@Suite struct AttentionCenterTests {
    static let t0 = Date(timeIntervalSince1970: 1_900_000_000)
    static let session = UUID()
    static let context = AttentionContext(sessionID: session, sessionTitle: "Fix pagination", projectName: "otter", provider: .claude)

    func status(_ id: UUID, _ activity: AgentActivity, message: String? = nil, reason: String? = nil, children: Int = 0, at: Date = t0) -> TerminalActivity {
        TerminalActivity(terminalID: id, runID: UUID(), activity: activity, lastMessage: message, reason: reason, liveChildren: children, changedAt: at)
    }

    func at(_ seconds: Double) -> Date { Self.t0.addingTimeInterval(seconds) }

    // MARK: - Itens por transição

    @Test func enteringNeedsInputOpensAPriorityTwoItemWithTheNotificationTitle() throws {
        var center = AttentionCenter()
        let id = UUID()
        let applied = center.apply(
            status(id, .needsInput(.permission), reason: "Wants to run: `git push origin fix/pagination`"), context: Self.context, now: at(1))
        let item = try #require(applied)
        #expect(item.kind == .needsInput && item.priority == 2)
        #expect(item.title == "otter / Fix pagination — Claude needs input")
        #expect(item.body == "Wants to run: `git push origin fix/pagination`")
        #expect(center.badgeCount == 1)
        #expect(center.pending.map(\.id) == [item.id])
    }

    @Test func repeatedUpdatesOfTheSameStateNeverOpenASecondItem() {
        var center = AttentionCenter()
        let id = UUID()
        let first = center.apply(status(id, .needsInput(.question)), context: Self.context, now: at(1))
        #expect(first != nil)
        let second = center.apply(status(id, .needsInput(.question)), context: Self.context, now: at(2))
        #expect(second == nil)
        let third = center.apply(status(id, .needsInput(.permission)), context: Self.context, now: at(3))
        #expect(third == nil, "mudar o subtipo é o mesmo pedido")
        #expect(center.items.count == 1 && center.badgeCount == 1)
    }

    @Test func leavingNeedsInputResolvesTheItem() {
        var center = AttentionCenter()
        let id = UUID()
        center.apply(status(id, .needsInput(.permission)), context: Self.context, now: at(1))
        center.apply(status(id, .working), context: Self.context, now: at(2))
        #expect(center.badgeCount == 0 && center.pending.isEmpty)
        #expect(center.items.first?.resolvedAt == at(2))
    }

    @Test func doneIsPriorityThreeAndDoesNotCountForTheBadge() throws {
        var center = AttentionCenter()
        let id = UUID()
        let applied = center.apply(status(id, .done, message: "Fixed the pagination bug."), context: Self.context, now: at(1))
        let item = try #require(applied)
        #expect(item.kind == .done && item.priority == 3 && item.body == "Fixed the pagination bug.")
        #expect(item.title.hasSuffix("— Claude finished"))
        #expect(center.badgeCount == 0)
        #expect(center.unread == [id], "done fica não lido até o pane ser visto")
    }

    @Test func failedIsPriorityTwoAndReadsExitCodes() throws {
        var center = AttentionCenter()
        let id = UUID()
        let applied = center.apply(status(id, .failed, reason: "exited with 1"), context: Self.context, now: at(1))
        let item = try #require(applied)
        #expect(item.kind == .failed && item.body == "Exited with code 1")
        #expect(item.title.hasSuffix("— Claude failed"))
        #expect(center.badgeCount == 1 && center.unread == [id])
    }

    @Test func cleanSessionTitleHasNoProject() throws {
        var center = AttentionCenter()
        let clean = AttentionContext(sessionID: UUID(), sessionTitle: "quiet-harbor", projectName: nil, provider: .codex)
        let applied = center.apply(status(UUID(), .done), context: clean, now: at(1))
        let item = try #require(applied)
        #expect(item.title == "quiet-harbor — Codex finished")
    }

    @Test func aNewPromptClearsUnreadAndOldItems() {
        var center = AttentionCenter()
        let id = UUID()
        center.apply(status(id, .done), context: Self.context, now: at(1))
        center.apply(status(id, .working), context: Self.context, now: at(2))
        #expect(center.unread.isEmpty && center.pending.isEmpty)
    }

    @Test func unknownTerminalContextKeepsTheStatusWithoutOpeningAnItem() {
        var center = AttentionCenter()
        let id = UUID()
        let applied = center.apply(status(id, .needsInput(.other)), context: nil, now: at(1))
        #expect(applied == nil)
        #expect(center.statuses[id]?.activity == .needsInput(.other) && center.items.isEmpty)
    }

    // MARK: - Leitura

    @Test func viewingTheTerminalsResolvesTheItemsAndZeroesTheBadge() {
        var center = AttentionCenter()
        let a = UUID(), b = UUID()
        center.apply(status(a, .needsInput(.permission)), context: Self.context, now: at(1))
        center.apply(status(b, .needsInput(.question)), context: Self.context, now: at(2))
        center.apply(status(UUID(), .done), context: Self.context, now: at(3))
        #expect(center.badgeCount == 2, "2 agentes em needs input → badge 2")
        let changed = center.markViewed(terminals: [a], now: at(4))
        #expect(changed)
        #expect(center.badgeCount == 1)
        center.markViewed(terminals: [b], now: at(5))
        #expect(center.badgeCount == 0, "ver os dois panes zera")
        #expect(center.items.filter { $0.kind == .needsInput }.allSatisfy { $0.seenAt != nil })
    }

    @Test func markViewedOnACleanTerminalChangesNothing() {
        var center = AttentionCenter()
        let changed = center.markViewed(terminals: [UUID()], now: at(1))
        #expect(!changed)
    }

    @Test func bellMarksTheTerminalUnreadUntilViewed() {
        var center = AttentionCenter()
        let id = UUID()
        let flagged = center.bell(terminal: id)
        #expect(flagged)
        #expect(center.unread == [id] && center.bells == [id] && center.badgeCount == 0)
        center.markViewed(terminals: [id], now: at(1))
        #expect(center.unread.isEmpty && center.bells.isEmpty)
    }

    @Test func markAllReadClearsEverything() {
        var center = AttentionCenter()
        center.apply(status(UUID(), .done), context: Self.context, now: at(1))
        center.apply(status(UUID(), .failed, reason: "x"), context: Self.context, now: at(2))
        center.bell(terminal: UUID())
        center.markAllRead(now: at(3))
        #expect(center.unread.isEmpty && center.pending.isEmpty && center.badgeCount == 0)
    }

    @Test func seenDoneBecomesIdleAfterThirtyMinutes() {
        var center = AttentionCenter()
        let id = UUID()
        center.apply(status(id, .done, at: at(0)), context: Self.context, now: at(0))
        #expect(center.effectiveActivity(of: id, now: at(3600)) == .done, "não visto: continua done")
        center.markViewed(terminals: [id], now: at(10))
        #expect(center.effectiveActivity(of: id, now: at(10 + 29 * 60)) == .done)
        #expect(center.effectiveActivity(of: id, now: at(30 * 60 + 1)) == .idle)
    }

    @Test func closingATerminalDropsItFromTheQueue() {
        var center = AttentionCenter()
        let id = UUID()
        center.apply(status(id, .needsInput(.other)), context: Self.context, now: at(1))
        center.remove(terminal: id)
        #expect(center.items.isEmpty && center.statuses.isEmpty && center.badgeCount == 0)
    }

    // MARK: - Semeadura (app reaberto)

    @Test func seedingKeepsPendingNeedsInputButOnlyUnreadDoneAndFailed() {
        var center = AttentionCenter()
        let asking = UUID(), doneRead = UUID(), doneUnread = UUID(), failedRead = UUID()
        let a = center.apply(status(asking, .needsInput(.permission)), context: Self.context, now: at(1), seeding: true)
        let b = center.apply(status(doneRead, .done), context: Self.context, now: at(1), seeding: true, unreadHint: false)
        let c = center.apply(status(doneUnread, .done), context: Self.context, now: at(1), seeding: true, unreadHint: true)
        let d = center.apply(status(failedRead, .failed, reason: "x"), context: Self.context, now: at(1), seeding: true)
        #expect(a != nil && b == nil && c != nil && d == nil)
        #expect(center.unread == [doneUnread] && center.badgeCount == 1)
    }

    // MARK: - Próximo que precisa de atenção

    @Test func nextNeedingAttentionWalksByPriorityThenWaitOrderAndWraps() throws {
        var center = AttentionCenter()
        let done = UUID(), firstAsk = UUID(), secondAsk = UUID(), failed = UUID()
        center.apply(status(done, .done), context: Self.context, now: at(1))
        center.apply(status(firstAsk, .needsInput(.question)), context: Self.context, now: at(2))
        center.apply(status(failed, .failed, reason: "x"), context: Self.context, now: at(3))
        center.apply(status(secondAsk, .needsInput(.permission)), context: Self.context, now: at(4))
        #expect(center.pending.map(\.terminalID) == [firstAsk, failed, secondAsk, done], "prioridade 2 por ordem de espera, depois a 3")
        #expect(center.next(after: nil)?.terminalID == firstAsk)
        #expect(center.next(after: firstAsk)?.terminalID == failed)
        #expect(center.next(after: secondAsk)?.terminalID == done)
        #expect(center.next(after: done)?.terminalID == firstAsk, "dá a volta")
        #expect(center.next(after: UUID())?.terminalID == firstAsk, "terminal que não está na fila: começa do primeiro")
    }

    @Test func nextNeedingAttentionIsNilWhenNothingIsPending() {
        #expect(AttentionCenter().next(after: nil) == nil)
    }

    // MARK: - Agregação (01 §6.3) com filhos

    @Test func aggregateFollowsTheSpecOrder() {
        var center = AttentionCenter()
        let working = UUID(), waiting = UUID(), doneUnread = UUID(), idle = UUID()
        center.apply(status(working, .working), context: Self.context, now: at(1))
        center.apply(status(waiting, .waitingOnSubagents, children: 2), context: Self.context, now: at(1))
        center.apply(status(doneUnread, .done), context: Self.context, now: at(1))
        center.apply(status(idle, .idle), context: Self.context, now: at(1))
        #expect(center.aggregate([idle, doneUnread], now: at(2)) == .done)
        #expect(center.aggregate([doneUnread, waiting], now: at(2)) == .waitingOnSubagents)
        #expect(center.aggregate([waiting, working, idle], now: at(2)) == .working)
        let asking = UUID(), failed = UUID()
        center.apply(status(asking, .needsInput(.question)), context: Self.context, now: at(3))
        center.apply(status(failed, .failed, reason: "x"), context: Self.context, now: at(3))
        #expect(center.aggregate([working, failed], now: at(4)) == .failed)
        #expect(center.aggregate([failed, asking, working], now: at(4)) == .needsInput(.question))
        #expect(center.aggregate([], now: at(4)) == nil)
    }

    @Test func parentStateAccountsForItsChildrenThroughTheReducer() {
        // O pai parou com 2 subagentes vivos: waiting; um filho pede permissão: o pai aparece como needsInput; ao
        // aprovar e terminar o último filho, vira done.
        func event(_ name: String, _ n: Int, _ payload: ReducedHookPayload = ReducedHookPayload()) -> ActivityEvent {
            ActivityEvent(name: name, payload: payload, atNs: Int64(1_900_000_000_000_000_000) + Int64(n) * 1_000_000)
        }
        let childA = ReducedHookPayload(agentID: "a"), childB = ReducedHookPayload(agentID: "b")
        let permission = ReducedHookPayload(toolName: "Bash", toolTarget: "rm -rf build", agentID: "a")
        let stop = ReducedHookPayload(lastAssistantMessage: "Launched two researchers.")
        var state = ActivityReducer.fold([
            event("UserPromptSubmit", 1), event("SubagentStart", 2, childA), event("SubagentStart", 3, childB), event("Stop", 4, stop),
        ])
        #expect(state.activity == .waitingOnSubagents && state.liveChildCount == 2)
        state = ActivityReducer.reduce(state, event("PermissionRequest", 5, permission))
        #expect(state.activity == .needsInput(.permission), "filho pedindo permissão faz o pai aparecer como needs input")
        state = ActivityReducer.reduce(state, event("PostToolUse", 6, permission))
        state = ActivityReducer.reduce(state, event("SubagentStop", 7, childA))
        #expect(state.activity == .waitingOnSubagents && state.liveChildCount == 1)
        state = ActivityReducer.reduce(state, event("SubagentStop", 8, childB))
        #expect(state.activity == .done)
    }

    // MARK: - Inbox

    @Test func inboxGroupsRowsAndFilters() {
        var center = AttentionCenter()
        let asking = UUID(), working = UUID(), waiting = UUID(), doneUnread = UUID(), doneRead = UUID(), failedUnread = UUID()
        var contexts: [UUID: AttentionContext] = [:]
        for (i, id) in [asking, working, waiting, doneUnread, doneRead, failedUnread].enumerated() {
            contexts[id] = AttentionContext(sessionID: UUID(), sessionTitle: "s\(i)", projectName: "p", provider: .claude)
        }
        center.apply(status(asking, .needsInput(.permission), reason: "Wants to run: `ls`", at: at(1)), context: contexts[asking], now: at(1))
        center.apply(status(working, .working, at: at(2)), context: contexts[working], now: at(2))
        center.apply(status(waiting, .waitingOnSubagents, children: 2, at: at(3)), context: contexts[waiting], now: at(3))
        center.apply(status(doneRead, .done, message: "Old news", at: at(4)), context: contexts[doneRead], now: at(4))
        center.markViewed(terminals: [doneRead], now: at(5))
        center.apply(status(doneUnread, .done, message: "Fresh result", at: at(6)), context: contexts[doneUnread], now: at(6))
        center.apply(status(failedUnread, .failed, reason: "exited with 2", at: at(7)), context: contexts[failedUnread], now: at(7))

        let feed = center.inbox(contexts: contexts, now: at(10))
        #expect(feed.groups.map(\.group) == [.needsYou, .working, .done, .earlier])
        #expect(feed.groups[0].rows.map(\.message) == ["Wants to run: `ls`"])
        #expect(Set(feed.groups[1].rows.map(\.message)) == ["Working…", "Waiting on 2 subagents"])
        #expect(feed.groups[2].rows.map(\.message) == ["Exited with code 2", "Fresh result"], "mais recente primeiro")
        #expect(feed.groups[3].rows.map(\.message) == ["Old news"])
        #expect(feed.unreadCount == 2)
        #expect(center.inbox(contexts: contexts, filter: .needsYou, now: at(10)).rows.count == 1)
        #expect(center.inbox(contexts: contexts, filter: .unread, now: at(10)).rows.allSatisfy { $0.unread })
        #expect(AttentionCenter().inbox(contexts: [:], now: at(10)).isEmpty, "vazio: Nothing needs you.")
    }

    @Test func inboxSkipsTerminalsWithoutContextAndOrdersWaitingOldestFirst() {
        var center = AttentionCenter()
        let first = UUID(), second = UUID(), stranger = UUID()
        let ctx = AttentionContext(sessionID: UUID(), sessionTitle: "s", provider: .claude)
        center.apply(status(first, .needsInput(.other), at: at(1)), context: ctx, now: at(1))
        center.apply(status(second, .needsInput(.other), at: at(5)), context: ctx, now: at(5))
        center.apply(status(stranger, .needsInput(.other), at: at(3)), context: nil, now: at(3))
        let feed = center.inbox(contexts: [first: ctx, second: ctx], now: at(9))
        #expect(feed.rows.map(\.id) == [first, second], "quem espera há mais tempo vem primeiro")
    }
}
