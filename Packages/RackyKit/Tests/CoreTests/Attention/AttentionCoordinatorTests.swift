import RackyProtocol
import Foundation
import Synchronization
import Testing

@testable import RackyCore

private func wait(timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// Regras de notificação do sistema (06 §3.5, 03 §9.2): toggles, supressão com o pane visível, cooldown e permissão.
@Suite struct NotificationPlannerTests {
    static let now = Date(timeIntervalSince1970: 1_900_000_000)
    static let item = AttentionItem(
        id: "t.needsInput.1", kind: .needsInput, sessionID: UUID(), terminalID: UUID(), title: "otter / Fix pagination — Claude needs input",
        body: "Wants to run: `ls`", createdAt: now)

    func env(
        _ auth: NotificationAuthorization = .authorized, key: Bool = false, visible: Bool = false, last: (Date, Int)? = nil
    ) -> NotificationPlanner.Environment {
        .init(authorization: auth, windowIsKey: key, paneVisible: visible, now: Self.now, last: last.map { (at: $0.0, priority: $0.1) })
    }

    func plan(
        _ env: NotificationPlanner.Environment, item: AttentionItem = item, prefs: AppSettings.Notifications = .init()
    ) -> NotificationPlanner.Decision {
        NotificationPlanner.plan(item, preferences: prefs, environment: env)
    }

    @Test func postsWithTitleBodyThreadAndTarget() throws {
        guard case .post(let n) = plan(env()) else { Issue.record("expected a post"); return }
        #expect(n.title == "otter / Fix pagination — Claude needs input" && n.body == "Wants to run: `ls`")
        #expect(n.threadID == Self.item.sessionID.uuidString.lowercased(), "threadIdentifier = sessão")
        #expect(n.target == NotificationTarget(terminalID: Self.item.terminalID, sessionID: Self.item.sessionID))
        #expect(n.sound, "needs input toca o som do sistema")
    }

    @Test func nothingIsPostedWithoutPermission() {
        #expect(plan(env(.notDetermined)) == .skip(.notAuthorized))
        #expect(plan(env(.denied)) == .skip(.notAuthorized))
    }

    @Test func eachKindHasItsOwnToggleAndFinishedHasNoSound() {
        var prefs = AppSettings.Notifications()
        prefs.needsInput = false
        #expect(plan(env(), item: Self.item, prefs: prefs) == .skip(.kindDisabled))
        var done = Self.item; done.kind = .done
        guard case .post(let n) = plan(env(), item: done, prefs: AppSettings.Notifications()) else { Issue.record("done should post"); return }
        #expect(!n.sound, "Finished: sem som")
        prefs = AppSettings.Notifications(); prefs.finished = false
        #expect(plan(env(), item: done, prefs: prefs) == .skip(.kindDisabled))
        var failed = Self.item; failed.kind = .failed
        prefs = AppSettings.Notifications(); prefs.failed = false
        #expect(plan(env(), item: failed, prefs: prefs) == .skip(.kindDisabled))
    }

    @Test func noSoundWhenTheSettingIsNone() {
        var prefs = AppSettings.Notifications(); prefs.sound = .none
        guard case .post(let n) = plan(env(), item: Self.item, prefs: prefs) else { Issue.record("expected a post"); return }
        #expect(!n.sound)
    }

    @Test func suppressedOnlyWhenTheWindowIsKeyAndThePaneIsVisible() {
        #expect(plan(env(key: true, visible: true)) == .skip(.visible))
        #expect(plan(env(key: true, visible: false)).isPost)
        #expect(plan(env(key: false, visible: true)).isPost, "app em segundo plano")
        var prefs = AppSettings.Notifications(); prefs.suppressWhenVisible = false
        #expect(plan(env(key: true, visible: true), item: Self.item, prefs: prefs).isPost)
    }

    @Test func cooldownIsFiveSecondsPerTerminalButAHigherPriorityPassesThrough() {
        let recent = Self.now.addingTimeInterval(-2)
        #expect(plan(env(last: (recent, 2))) == .skip(.cooldown))
        var done = Self.item; done.kind = .done
        #expect(plan(env(last: (recent, 2)), item: done, prefs: AppSettings.Notifications()) == .skip(.cooldown))
        #expect(plan(env(last: (recent, 3))).isPost, "pergunta depois de um fim de turno recente passa")
        #expect(plan(env(last: (Self.now.addingTimeInterval(-6), 2))).isPost)
    }

    @Test func aNotifiedItemIsNeverPostedTwice() {
        var item = Self.item; item.systemNotified = true
        #expect(plan(env(), item: item, prefs: AppSettings.Notifications()) == .skip(.alreadyNotified))
    }

    @Test func bellIsOffByDefaultAndFollowsTheSameSuppression() {
        let context = AttentionContext(sessionID: UUID(), sessionTitle: "s", provider: .claude)
        let tid = UUID()
        #expect(NotificationPlanner.planBell(terminalID: tid, context: context, preferences: .init(), environment: env()) == .skip(.kindDisabled))
        var prefs = AppSettings.Notifications(); prefs.terminalBell = true
        #expect(NotificationPlanner.planBell(terminalID: tid, context: context, preferences: prefs, environment: env()).isPost)
        #expect(NotificationPlanner.planBell(terminalID: tid, context: context, preferences: prefs, environment: env(key: true, visible: true)) == .skip(.visible))
    }

    @Test func settingsDecodeOldDatabasesWithTheSpecDefaults() throws {
        let old = Data(#"{"general":{},"agents":{},"terminal":{}}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: old)
        #expect(settings.notifications == AppSettings.Notifications())
        let n = settings.notifications
        #expect(n.needsInput && n.finished && n.failed && !n.terminalBell && n.suppressWhenVisible && n.dockBadge && n.sound == .system)
    }
}

extension NotificationPlanner.Decision {
    var isPost: Bool { if case .post = self { true } else { false } }
}

/// `AttentionCoordinator`: estado de atividade -> fila, notificação (centro injetado), badge do Dock e navegação.
@MainActor
@Suite struct AttentionCoordinatorTests {
    @MainActor final class World {
        let center = RecordingNotificationCenter(authorization: .authorized)
        let coordinator: AttentionCoordinator
        let session = UUID()
        let terminals = [UUID(), UUID(), UUID()]
        var badges: [String?] = []
        var navigations: [(UUID, UUID, AttentionNavigation)] = []
        var key = false
        var visible: Set<UUID> = []
        var prefs = AppSettings.Notifications()
        var now = Date(timeIntervalSince1970: 1_900_000_000)

        init() {
            coordinator = AttentionCoordinator(notifier: center)
            let map = Dictionary(uniqueKeysWithValues: terminals.map {
                ($0, AttentionContext(sessionID: session, sessionTitle: "Fix pagination", projectName: "otter", provider: .claude))
            })
            coordinator.contexts = { map }
            coordinator.preferences = { [self] in prefs }
            coordinator.windowIsKey = { [self] in key }
            coordinator.visibleTerminals = { [self] in visible }
            coordinator.setDockBadge = { [self] in badges.append($0) }
            coordinator.navigate = { [self] t, s, source in navigations.append((t, s, source)) }
            coordinator.clock = { [self] in now }
            coordinator.viewDwell = .milliseconds(30)
        }

        func update(_ i: Int, _ activity: AgentActivity, message: String? = nil, reason: String? = nil, children: Int = 0) -> ActivityService.Update {
            ActivityService.Update(
                runID: UUID(), terminalID: terminals[i], activity: activity, lastMessage: message, statusReason: reason, subtitle: nil, liveChildren: children)
        }

        func settle() async { try? await Task.sleep(for: .milliseconds(60)) }
    }

    @Test func needsInputPostsOneNotificationAndRaisesTheDockBadge() async {
        let w = World()
        w.coordinator.handle(w.update(0, .needsInput(.permission), reason: "Wants to run: `git push origin fix/pagination`"))
        #expect(await wait { w.center.posted.count == 1 })
        let n = w.center.posted[0]
        #expect(n.title == "otter / Fix pagination — Claude needs input")
        #expect(n.body == "Wants to run: `git push origin fix/pagination`")
        #expect(w.badges.last == .some("1"))
        // Atualização repetida do mesmo estado não notifica de novo.
        w.coordinator.handle(w.update(0, .needsInput(.permission), reason: "Wants to run: `git push origin fix/pagination`"))
        await w.settle()
        #expect(w.center.posted.count == 1)
    }

    @Test func badgeCountsOnlyPriorityOneAndTwoAndClearsWhenSeen() async {
        let w = World()
        w.coordinator.handle(w.update(0, .needsInput(.question)))
        w.coordinator.handle(w.update(1, .needsInput(.permission)))
        w.coordinator.handle(w.update(2, .done, message: "All good."))
        await w.settle()
        #expect(w.badges.last == .some("2"), "2 agentes em needs input → badge 2; done não conta")
        w.coordinator.markViewed([w.terminals[0], w.terminals[1]])
        #expect(w.badges.last == .some(nil), "ver os dois panes zera e o badge some")
    }

    @Test func dockBadgeFollowsThePreference() async {
        let w = World()
        w.prefs.dockBadge = false
        w.coordinator.handle(w.update(0, .needsInput(.question)))
        await w.settle()
        #expect(w.badges.isEmpty || w.badges.last == .some(nil))
    }

    @Test func suppressedWhileTheWindowIsKeyAndThePaneIsVisible() async {
        let w = World()
        w.key = true
        w.visible = [w.terminals[0]]
        w.coordinator.handle(w.update(0, .needsInput(.question)))
        w.coordinator.handle(w.update(1, .needsInput(.question)))
        #expect(await wait { w.center.posted.count == 1 })
        #expect(w.center.posted.first?.target.terminalID == w.terminals[1], "o pane visível não notifica; o outro sim")
    }

    @Test func nothingIsPostedWithoutPermissionButTheQueueStillFills() async {
        let w = World()
        let denied = RecordingNotificationCenter(authorization: .denied)
        let c = AttentionCoordinator(notifier: denied)
        c.contexts = w.coordinator.contexts
        c.windowIsKey = { false }
        c.handle(w.update(0, .done, message: "x"))
        await w.settle()
        #expect(denied.posted.isEmpty && c.center.unread == [w.terminals[0]])
    }

    @Test func realRequestPermissionOnlyHappensThroughTheExplicitCall() async {
        let w = World()
        let fresh = RecordingNotificationCenter(authorization: .notDetermined)
        let c = AttentionCoordinator(notifier: fresh)
        c.contexts = w.coordinator.contexts
        c.handle(w.update(0, .needsInput(.question)))
        c.bell(terminalID: w.terminals[0])
        _ = await c.sendTest()
        await w.settle()
        #expect(fresh.requestCount == 0, "eventos, bell e teste nunca pedem a autorização")
        #expect(await fresh.authorization() == .notDetermined)
        _ = await fresh.requestAuthorization()
        let after = await fresh.authorization()
        #expect(fresh.requestCount == 1 && after == .authorized)
    }

    @Test func clickingTheNotificationNavigatesToThePaneAndMarksItRead() async throws {
        let w = World()
        w.coordinator.handle(w.update(1, .needsInput(.permission), reason: "Wants to run: `ls`"))
        #expect(await wait { w.center.posted.count == 1 })
        let target = w.center.posted[0].target
        w.center.simulateClick(target)
        #expect(await wait { !w.navigations.isEmpty })
        #expect(w.navigations[0].0 == w.terminals[1] && w.navigations[0].1 == w.session && w.navigations[0].2 == .notification)
        #expect(w.coordinator.center.badgeCount == 0 && w.badges.last == .some(nil))
    }

    @Test func nextNeedingAttentionNavigatesAndWalksTheQueue() async {
        let w = World()
        w.coordinator.handle(w.update(0, .needsInput(.question)))
        w.now = w.now.addingTimeInterval(5)
        w.coordinator.handle(w.update(1, .failed, reason: "exited with 1"))
        let first = w.coordinator.goToNextNeedingAttention(from: nil)
        #expect(first?.terminalID == w.terminals[0])
        let second = w.coordinator.goToNextNeedingAttention(from: w.terminals[0])
        #expect(second?.terminalID == w.terminals[1])
        #expect(w.navigations.map(\.2) == [.shortcut, .shortcut])
        #expect(w.coordinator.goToNextNeedingAttention(from: w.terminals[1]) == nil, "nada pendente: Nothing needs attention")
    }

    @Test func bellMarksUnreadAndOnlyNotifiesWhenEnabled() async {
        let w = World()
        w.coordinator.bell(terminalID: w.terminals[0])
        await w.settle()
        #expect(w.coordinator.center.unread == [w.terminals[0]] && w.coordinator.center.bells == [w.terminals[0]])
        #expect(w.center.posted.isEmpty, "Terminal bell vem desligado")
        w.prefs.terminalBell = true
        w.coordinator.bell(terminalID: w.terminals[1])
        #expect(await wait { w.center.posted.count == 1 })
        // Bell no pane visível com a janela key: nada acontece.
        w.key = true
        w.visible = [w.terminals[2]]
        w.coordinator.bell(terminalID: w.terminals[2])
        #expect(w.coordinator.center.unread == [w.terminals[0], w.terminals[1]])
    }

    @Test func aPaneVisibleWithTheWindowKeyIsMarkedViewedAfterTheDwell() async {
        let w = World()
        w.coordinator.handle(w.update(0, .done, message: "Result"))
        #expect(w.coordinator.center.unread == [w.terminals[0]])
        w.key = true
        w.visible = [w.terminals[0]]
        w.coordinator.scheduleViewCheck()
        #expect(await wait { w.coordinator.center.unread.isEmpty })
    }

    @Test func aPaneThatIsNotVisibleStaysUnread() async {
        let w = World()
        w.coordinator.handle(w.update(0, .done, message: "Result"))
        w.key = true
        w.visible = [w.terminals[1]]
        w.coordinator.scheduleViewCheck()
        await w.settle()
        #expect(w.coordinator.center.unread == [w.terminals[0]])
        w.key = false
        w.visible = [w.terminals[0]]
        w.coordinator.scheduleViewCheck()
        await w.settle()
        #expect(w.coordinator.center.unread == [w.terminals[0]], "sem a janela key nada é visto")
    }

    @Test func sendTestNotificationPostsOnlyWithPermission() async {
        let w = World()
        #expect(await w.coordinator.sendTest() == .authorized)
        #expect(w.center.posted.count == 1 && w.center.posted[0].title.contains("test"))
        let denied = AttentionCoordinator(notifier: RecordingNotificationCenter(authorization: .denied))
        #expect(await denied.sendTest() == .denied)
    }
}
