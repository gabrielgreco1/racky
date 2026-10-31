import RackyProtocol
import Foundation
import Testing

@testable import RackyCore

// T3-07, AC-429: "lote concluído" vira **um** AttentionItem `batchDone` e **uma** notificação (pelo centro falso); o clique leva ao painel
// `Batch`, não ao pane. Nenhuma notificação por filho.

@Suite("T3-07 lote concluído: atenção e notificação") struct BatchAttentionTests {
    typealias World = AttentionCoordinatorTests.World

    @MainActor func wait(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 { if condition() { return true }; try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    @MainActor @Test func oneItemAndOneNotificationPerBatch() async {
        let w = World()
        var opened: [String] = []
        w.coordinator.openBatch = { opened.append($0) }
        let summary = BatchSummary(name: "listings-oct", sessionTitle: "Fix pagination", children: [
            BatchChild(name: "a", status: .done, verified: 3, proxyRequests: 100, durationSeconds: 600), BatchChild(name: "b", status: .failed, durationSeconds: 120),
        ])
        w.coordinator.batchFinished(batchID: summary.name, title: summary.notificationTitle, body: summary.notificationBody, sessionID: w.session, terminalID: w.terminals[0])
        #expect(await wait { w.center.posted.count == 1 })
        let n = w.center.posted[0]
        #expect(n.title == "Fix pagination — listings-oct finished" && n.body == "1 done · 1 failed · 3 verified fields · 10 min · 100 proxy requests")
        #expect(n.kind == .batchDone && n.target.batchID == "listings-oct" && n.target.terminalID == w.terminals[0] && !n.sound)
        let items = w.coordinator.center.batchItems
        #expect(items.count == 1 && items[0].kind == .batchDone && items[0].batchID == "listings-oct" && items[0].body == n.body)

        // O mesmo lote de novo (segundo `batch_collect`, app reaberto): nem item nem notificação.
        w.coordinator.batchFinished(batchID: summary.name, title: summary.notificationTitle, body: summary.notificationBody, sessionID: w.session, terminalID: w.terminals[0])
        await w.settle()
        #expect(w.center.posted.count == 1 && w.coordinator.center.items.filter { $0.kind == .batchDone }.count == 1)
        #expect(w.badges.last != .some("1"), "prioridade 3: não entra no badge do Dock")

        // Clicar abre o painel do lote e tira o item da fila; o pane do pai não é tocado.
        w.coordinator.open(n.target)
        #expect(opened == ["listings-oct"] && w.navigations.isEmpty)
        #expect(w.coordinator.center.batchItems.isEmpty)
    }

    @MainActor @Test func theBatchNotificationIgnoresTheFiveSecondCooldownOfTheParentTerminal() async {
        let w = World()
        w.coordinator.handle(w.update(0, .done, message: "Spawned the workers."))
        #expect(await wait { w.center.posted.count == 1 })
        w.coordinator.batchFinished(batchID: "b", title: "x — b finished", body: "1 done · 0 failed · 0 verified fields", sessionID: w.session, terminalID: w.terminals[0])
        #expect(await wait { w.center.posted.count == 2 }, "the parent's own `done` just posted, and the batch still gets its notification")
    }

    @MainActor @Test func respectsTheFinishedTogglePermissionAndVisiblePane() async {
        let w = World()
        w.prefs.finished = false
        w.coordinator.batchFinished(batchID: "off", title: "t", body: "b", sessionID: w.session, terminalID: w.terminals[0])
        await w.settle()
        #expect(w.center.posted.isEmpty, "Settings › Notifications › Finished off")
        #expect(w.coordinator.center.batchItems.count == 1, "the Inbox item exists anyway")
        w.prefs.finished = true
        w.key = true
        w.visible = [w.terminals[1]]
        w.coordinator.batchFinished(batchID: "on", title: "t", body: "b", sessionID: w.session, terminalID: w.terminals[1])
        await w.settle()
        #expect(w.center.posted.isEmpty, "the parent pane is visible in the key window: no banner")
        let denied = RecordingNotificationCenter(authorization: .denied)
        let c = AttentionCoordinator(notifier: denied)
        c.windowIsKey = { false }
        c.batchFinished(batchID: "x", title: "t", body: "b", sessionID: w.session, terminalID: w.terminals[0])
        await w.settle()
        #expect(denied.posted.isEmpty && c.center.batchItems.count == 1)
    }

    @Test func notificationTargetStaysCodableAcrossTheClick() throws {
        let target = NotificationTarget(terminalID: UUID(), sessionID: UUID(), batchID: "listings-oct")
        #expect(try JSONDecoder().decode(NotificationTarget.self, from: JSONEncoder().encode(target)) == target)
        let old = Data(#"{"terminalID":"\#(UUID().uuidString)","sessionID":"\#(UUID().uuidString)"}"#.utf8)
        #expect(try JSONDecoder().decode(NotificationTarget.self, from: old).batchID == nil, "payloads without a batch still decode")
    }

    @Test func centerKeepsOneItemPerBatchAndResolvesIt() {
        var center = AttentionCenter()
        let session = UUID(), terminal = UUID(), now = Date()
        #expect(center.openBatchDone(batchID: "b", sessionID: session, terminalID: terminal, title: "t", body: "x", now: now) != nil)
        #expect(center.openBatchDone(batchID: "b", sessionID: session, terminalID: terminal, title: "t", body: "x", now: now) == nil)
        #expect(center.openBatchDone(batchID: "c", sessionID: session, terminalID: terminal, title: "t", body: "x", now: now) != nil)
        #expect(center.batchItems.count == 2 && center.badgeCount == 0 && center.pending.count == 2)
        center.resolveBatch("b", now: now)
        #expect(center.batchItems.map(\.batchID) == ["c"])
        // Ver o pane do pai também resolve o item (o usuário já viu o resultado).
        center.markViewed(terminals: [terminal], now: now)
        #expect(center.batchItems.isEmpty)
    }
}
