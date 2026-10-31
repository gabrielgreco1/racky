import RackyDocker
import Foundation
import Testing

@testable import RackyCore

/// T3-05: diretório de computadores, Inbox de pedidos de ajuda, notificação (uma por `request_id`) e badge do Dock.
@Suite("T3-05 - computadores, Inbox e notificação")
@MainActor
struct ComputersModelTests {
    func row(_ name: String, needsYou: Bool = false, at seconds: Double = 0) -> ComputerRow {
        ComputerRow(
            snapshot: ViewerSnapshot(
                name: name, state: .inUse, display: "headless", control: .agent, proxy: "direct",
                help: needsYou ? HelpSummary(id: "h-\(name)", kind: .captcha, reason: "", host: "x.test") : nil),
            thumbnail: nil, sessionTitle: nil, owner: nil, lastActivity: Date(timeIntervalSince1970: seconds))
    }

    @Test func needsYouFirstThenRecentActivityThenName() {
        let sorted = ComputersModel.sorted([row("zeta", at: 50), row("alpha", at: 10), row("beta", needsYou: true, at: 1), row("gamma", at: 50)])
        #expect(sorted.map(\.id) == ["beta", "gamma", "zeta", "alpha"])
    }

    @Test func notificationFollowsTheSpecAndCarriesNoPageContent() {
        let summary = HelpSummary(id: "r1", kind: .captcha, reason: "secret page text: card 4111", host: "aca-prod.accela.com")
        let content = HelpNotificationContent.make(session: "listings-oct", computer: "phoenix-az", summary: summary)
        #expect(content.title == "listings-oct — phoenix-az needs you")
        #expect(content.body == "CAPTCHA on aca-prod.accela.com")
        #expect(!content.body.contains("4111") && !content.title.contains("4111"))
        #expect(HelpNotificationContent.make(session: nil, computer: "phoenix-az", summary: summary).title == "phoenix-az needs you")
    }

    @Test func helpRequestFlowsToInboxDockBadgeAndOneNotificationPerRequest() async throws {
        let rig = try await Rig.make(name: "phoenix-az")
        defer { rig.cleanup() }
        await rig.claim()
        let model = ComputersModel()
        model.sessionTitle = { _ in "listings-oct" }
        var notifications: [(InboxItem, HelpNotificationContent)] = []
        var badges: [Int] = []
        model.onHelpRequested = { notifications.append(($0, $1)) }
        model.onAttentionChange = { badges.append($0) }
        await model.attach(rig.computer)

        let id = try #require(await rig.call("help_request", ["kind": "captcha", "reason": "hCaptcha", "url": "http://aca-prod.accela.com/search"]).json["request_id"]?.string)
        try await waitFor { !model.inbox.isEmpty }
        // repetir o mesmo pedido (mesmo kind + url) devolve o mesmo id e não gera outra notificação nem outro item
        for _ in 0..<3 { _ = await rig.call("help_request", ["kind": "captcha", "reason": "again", "url": "http://aca-prod.accela.com/search"]) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(notifications.count == 1 && model.inbox.count == 1)
        #expect(notifications[0].0.id == id && notifications[0].1.title == "listings-oct — phoenix-az needs you" && notifications[0].1.body == "CAPTCHA on aca-prod.accela.com")
        #expect(model.attentionCount == 1 && badges.last == 1 && model.unreadCount == 1)
        #expect(model.inbox[0].message == "phoenix-az needs you · CAPTCHA on aca-prod.accela.com")
        await model.refresh()
        #expect(model.rows.first?.needsYou == true)

        // o humano resolve: o item sai de "precisa de você" e o badge zera; o help_wait do filho retorna
        try await rig.computer.resolveHelp(id, note: "solved")
        try await waitFor { model.attentionCount == 0 }
        #expect(model.inbox[0].phase == .resolved && badges.last == 0)
        let done = await rig.call("help_wait", ["request_id": .string(id), "wait_s": 1])
        #expect(done.json["status"] == "resolved" && done.json["human_note"] == "solved")
        model.markAllRead()
        #expect(model.unreadCount == 0)
    }

    @Test func declineGoesBackAsDeclinedWithTheReason() async throws {
        let rig = try await Rig.make(name: "phoenix-az")
        defer { rig.cleanup() }
        await rig.claim()
        let model = ComputersModel()
        await model.attach(rig.computer)
        let id = try #require(await rig.call("help_request", ["kind": "login", "reason": "sign in"]).json["request_id"]?.string)
        try await waitFor { !model.inbox.isEmpty }
        await rig.computer.declineHelp(id, reason: "skip this city")
        try await waitFor { model.attentionCount == 0 }
        #expect(model.inbox[0].phase == .declined)
        let waited = await rig.call("help_wait", ["request_id": .string(id), "wait_s": 1])
        #expect(waited.json["status"] == "declined" && waited.json["decline_reason"] == "skip this city")
    }

    @Test func thumbnailsAreFetchedAtMostOncePerSecondPerComputer() async throws {
        let rig = try await Rig.make(name: "phoenix-az")
        defer { rig.cleanup() }
        await rig.backend.setRuntime("frame", ["jpeg_b64": .string(Data([0xFF, 0xD8, 1, 2]).base64EncodedString()), "url": "http://x/"])
        let model = ComputersModel()
        await model.attach(rig.computer)
        let t0 = Date(timeIntervalSince1970: 1000)
        await model.refresh(now: t0, withThumbnails: true)
        await model.refresh(now: t0.addingTimeInterval(0.4), withThumbnails: true)
        await model.refresh(now: t0.addingTimeInterval(0.9), withThumbnails: true)
        #expect(await rig.backend.runtimeCalls.filter { $0.op == "frame" }.count == 1)
        await model.refresh(now: t0.addingTimeInterval(1.1), withThumbnails: true)
        #expect(await rig.backend.runtimeCalls.filter { $0.op == "frame" }.count == 2)
        #expect(model.rows.first?.thumbnail == Data([0xFF, 0xD8, 1, 2]))
        await model.refresh(now: t0.addingTimeInterval(5), withThumbnails: false)  // sem painel aberto, nenhum quadro é pedido
        #expect(await rig.backend.runtimeCalls.filter { $0.op == "frame" }.count == 2)
    }

    func waitFor(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(30)) }
        #expect(condition())
    }
}
