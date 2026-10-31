import RackyCore
import RackyDesignSystem
import RackyProtocol
import RackyStore
import AppKit
import Foundation
import Testing

@testable import RackyUI

/// Integração ponta a ponta da T2-04: o `racky hook` real (payloads gravados no S-05 e no S-08) entrega eventos ao
/// `app.sock` do `AppEnvironment` da Fatia 2; o estado aparece no card e na tab, a notificação sai pelo centro falso e o
/// badge do Dock acompanha. Nada toca o `UNUserNotificationCenter` real.
@MainActor
@Suite(.serialized, .tags(.integration), .timeLimit(.minutes(1)), .offscreenAppKit) struct AttentionIntegrationTests {
    // MARK: Hooks reais

    nonisolated static let spikes: URL = {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("Tests/SpikeFixtures")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir.deleteLastPathComponent()
        }
        fatalError("Tests/SpikeFixtures not found above \(#filePath)")
    }()

    nonisolated static func fixtureEvents(_ relative: String) throws -> [(name: String, payload: [String: Any])] {
        let data = try Data(contentsOf: spikes.appendingPathComponent(relative))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let list = try #require(root["events"] as? [[String: Any]])
        return list.compactMap { entry in
            guard let tag = entry["tag"] as? String, !tag.hasPrefix("project-"), let payload = entry["payload"] as? [String: Any],
                  let name = payload["hook_event_name"] as? String else { return nil }
            return (name, payload)
        }
    }

    nonisolated static func rackyBinary() -> URL {
        for bundle in Bundle.allBundles where bundle.bundleURL.pathExtension == "xctest" {
            return bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("racky")
        }
        return URL(fileURLWithPath: ".build/debug/racky")
    }

    /// Roda `racky hook` como o Claude o chamaria: payload no stdin, correlação só por env.
    static func runHook(_ event: String, payload: [String: Any], agent: AttentionFixtures.Agent, socket: String) async throws {
        let stdin = try JSONSerialization.data(withJSONObject: payload)
        let status = await spawnHook(event: event, stdin: stdin, runID: agent.runID.uuidString, paneID: agent.terminalID.uuidString, socket: socket)
        #expect(status == 0, "o helper nunca falha para o agente")
    }

    nonisolated static func spawnHook(event: String, stdin: Data, runID: String, paneID: String, socket: String) async -> Int32 {
        let binary = rackyBinary()
        return await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                let process = Process()
                process.executableURL = binary
                process.arguments = ["hook", "--provider", "claude", "--event", event]
                process.environment = [
                    "PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory(), "RACKY_APP_SOCK": socket,
                    "RACKY_RUN_ID": runID, "RACKY_PANE_ID": paneID, "RACKY_HOOK_TIMEOUT_MS": "5000",
                ]
                let input = Pipe(), output = Pipe()
                process.standardInput = input
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                signal(SIGPIPE, SIG_IGN)
                do { try process.run() } catch { continuation.resume(returning: -1); return }
                try? input.fileHandleForWriting.write(contentsOf: stdin)
                try? input.fileHandleForWriting.close()
                _ = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus)
            }
        }
    }

    // MARK: Ambiente

    final class BadgeBox { var values: [String?] = [] }

    final class Rig {
        let env: AppEnvironment
        let home: URL
        let socket: String
        let box: BadgeBox
        init(env: AppEnvironment, home: URL, socket: String, box: BadgeBox) { self.env = env; self.home = home; self.socket = socket; self.box = box }
    }

    static func rig() async throws -> Rig {
        NSApplication.shared.setActivationPolicy(.accessory)  // testes nunca ativam nem mostram o app
        let home = URL(fileURLWithPath: "/tmp/abt-\(UInt32.random(in: 0 ... 0xFFFFFF))", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let socket = home.appendingPathComponent("run/app.sock").path
        try FileManager.default.createDirectory(at: home.appendingPathComponent("run"), withIntermediateDirectories: true)
        let box = BadgeBox()
        let env = AppEnvironment(
            environment: [
                "RACKY_SLICE": "2", "RACKY_NOTIFICATIONS": "fake", "RACKY_HOME": home.path, "RACKY_APP_SOCK": socket,
                "RACKY_SCREEN": AttentionFixtures.screenID, "RACKY_SKIP_ONBOARDING": "1",
            ], dockBadge: { box.values.append($0) })
        DaemonReaper.installExitSweep()
        await env.start()
        return Rig(env: env, home: home, socket: socket, box: box)
    }

    static func wait(_ timeout: Duration = .seconds(8), _ condition: @MainActor () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    static func agent(_ key: String) -> AttentionFixtures.Agent { AttentionFixtures.agents.first { $0.key == key }! }

    static func card(_ env: AppEnvironment, _ key: String) -> SessionCardData? {
        let title = agent(key).sessionTitle
        let projection = env.sidebar.projection
        for p in projection.projects { if let c = p.sessions.first(where: { $0.title == title }) { return c } }
        return projection.cleanSessions.first { $0.title == title }
    }

    static func terminal(_ env: AppEnvironment, _ key: String) -> Terminal? {
        env.sidebar.snapshot.terminals.first { $0.id == agent(key).terminalID }
    }

    static func stop(_ rig: Rig) async {
        await rig.env.stop()
        await DaemonReaper.shutdown(home: rig.home)  // o daemon filho do runtime ignora SIGTERM e fica vivo com sessões (F34)
    }

    // MARK: Cenários

    @Test func realHookEventsDriveCardTabNotificationAndBadge() async throws {
        let rig = try await Self.rig()
        defer { Task { await Self.stop(rig) } }
        let env = rig.env
        let notifier = try #require(env.fakeNotifier)
        let attention = try #require(env.attention)

        // Sem permissão nada é entregue; o usuário aperta "Allow Notifications" (ação do registro) e o centro falso concede.
        #expect(notifier.requestCount == 0, "o app não pede autorização sozinho")
        _ = try await env.registry.perform(.notificationsRequest, nil)
        #expect(notifier.requestCount == 1)

        let basic = try Self.fixtureEvents("S-05/claude-settings-hooks-payloads.json")
        let permission = try Self.fixtureEvents("S-05/claude-permission-request.json")
        let sub = try Self.fixtureEvents("S-08/subagent-hook-payloads.json")
        func payload(_ events: [(name: String, payload: [String: Any])], _ name: String) throws -> [String: Any] {
            try #require(events.first { $0.name == name }).payload
        }

        // 1. Permissão: SessionStart, UserPromptSubmit, PermissionRequest (payload real; o comando é o que a fixture trouxe).
        let asking = Self.agent("permission")
        for name in ["SessionStart", "UserPromptSubmit", "PermissionRequest"] {
            try await Self.runHook(name, payload: try payload(permission, name), agent: asking, socket: rig.socket)
        }
        #expect(await Self.wait { attention.center.statuses[asking.terminalID]?.activity == .needsInput(.permission) })
        let askingCard = try #require(Self.card(env, "permission"))
        #expect(askingCard.glyph == .needsInput && askingCard.stateLabel == "Needs input")
        let row = try #require(askingCard.agentRows.first)
        #expect(row.glyph == .needsInput && row.lead.hasPrefix("Wants to "), "pedido de permissão no lugar da última mensagem: \(row.lead)")
        let askingTerminal = try #require(Self.terminal(env, "permission"))
        #expect(env.workspace.status(of: askingTerminal).glyph == .needsInput, "a tab e o header do pane usam o mesmo estado")
        #expect(await Self.wait { notifier.posted.count == 1 })
        #expect(notifier.posted[0].title == "otter / Fix pagination — Claude needs input")
        #expect(notifier.posted[0].body.hasPrefix("Wants to "), "corpo = pedido de permissão: \(notifier.posted[0].body)")
        #expect(notifier.posted[0].target == NotificationTarget(terminalID: asking.terminalID, sessionID: askingCard.id))
        #expect(await Self.wait { rig.box.values.last == .some("1") })

        // 2. Working.
        let working = Self.agent("working")
        for name in ["SessionStart", "UserPromptSubmit", "PreToolUse"] {
            try await Self.runHook(name, payload: try payload(basic, name), agent: working, socket: rig.socket)
        }
        #expect(await Self.wait { Self.card(env, "working")?.glyph == .working })
        #expect(Self.card(env, "working")?.stateLabel == "Working")
        #expect(notifier.posted.count == 1, "working não notifica")

        // 3. Done: a última mensagem do `Stop` aparece na linha do agente e a sessão fica não lida.
        let done = Self.agent("done")
        for name in ["SessionStart", "UserPromptSubmit", "Stop"] {
            try await Self.runHook(name, payload: try payload(basic, name), agent: done, socket: rig.socket)
        }
        #expect(await Self.wait { attention.center.statuses[done.terminalID]?.activity == .done })
        #expect(await Self.wait { Self.terminal(env, "done")?.lastMessage?.isEmpty == false })
        let doneCard = try #require(Self.card(env, "done"))
        #expect(doneCard.glyph == .dot(DS.ColorSpec.agentDone) && doneCard.unread, "done não lido: bolinha esmeralda e negrito")
        let doneRow = try #require(doneCard.agentRows.first)
        #expect(doneRow.glyph == .done && doneRow.unread)
        #expect(doneRow.lead == Self.terminal(env, "done")?.lastMessage)
        #expect(await Self.wait { notifier.posted.count == 2 })
        #expect(notifier.posted[1].title == "acme-motion / Arizona context recap — Claude finished")
        #expect(!notifier.posted[1].sound)
        #expect(rig.box.values.last == .some("1"), "done é prioridade 3: não entra no badge")

        // 4. Waiting on subagents: o pai parou com dois filhos vivos (S-08 sem os SubagentStop).
        let waiting = Self.agent("waiting")
        var started = 0
        for event in sub where ["SessionStart", "UserPromptSubmit", "SubagentStart", "Stop"].contains(event.name) {
            try await Self.runHook(event.name, payload: event.payload, agent: waiting, socket: rig.socket)
            if event.name == "SubagentStart" { started += 1 }
        }
        #expect(started == 2)
        #expect(await Self.wait { Self.card(env, "waiting")?.glyph == .waiting })
        #expect(Self.card(env, "waiting")?.stateLabel == "Waiting on 2 subagents")

        // 5. Failed.
        let failed = Self.agent("failed")
        for name in ["SessionStart", "UserPromptSubmit"] {
            try await Self.runHook(name, payload: try payload(basic, name), agent: failed, socket: rig.socket)
        }
        var failure = try payload(basic, "Stop")
        failure["hook_event_name"] = "StopFailure"
        failure["error"] = "rate_limit"
        failure["last_assistant_message"] = nil
        try await Self.runHook("StopFailure", payload: failure, agent: failed, socket: rig.socket)
        #expect(await Self.wait { Self.card(env, "failed")?.glyph == .dot(DS.ColorSpec.agentFailed) })
        #expect(await Self.wait { notifier.posted.count == 3 })
        #expect(notifier.posted[2].title.hasSuffix("— Claude failed"))
        #expect(await Self.wait { rig.box.values.last == .some("2") }, "needs input + failed = 2")

        // Inbox: agrupa por estado.
        let feed = env.sidebar.inboxFeed
        #expect(feed.groups.map(\.group) == [.needsYou, .working, .done])
        #expect(feed.groups[0].rows.map(\.id) == [asking.terminalID])
        #expect(Set(feed.groups[1].rows.map(\.id)) == [working.terminalID, waiting.terminalID])
        #expect(Set(feed.groups[2].rows.map(\.id)) == [done.terminalID, failed.terminalID])

        // Clique na notificação: seleciona a sessão e marca lido; o badge cai.
        notifier.simulateClick(notifier.posted[0].target)
        #expect(await Self.wait { env.sidebar.selectedSession == askingCard.id })
        #expect(await Self.wait { rig.box.values.last == .some("1") })
        #expect(env.workspace.rimFlash?.terminalID == asking.terminalID, "clique leva ao pane com rim flash")

        // ⇧⌘A: por prioridade e espera: o failed (prioridade 2), depois o done não lido (prioridade 3), depois nada.
        let result = try await env.registry.perform(.sessionNextNeedingAttention, nil)
        #expect(result.message == failed.terminalID.uuidString)
        #expect(env.workspace.rimFlash?.terminalID == failed.terminalID)
        let last = try await env.registry.perform(.sessionNextNeedingAttention, nil)
        #expect(last.message == done.terminalID.uuidString)
        #expect(env.registry.availability(of: .sessionNextNeedingAttention) == .disabled(reason: "Nothing needs attention"))
        #expect(await Self.wait { rig.box.values.last == .some(nil) }, "todos vistos: o badge some")
    }

    @Test func slice1KeepsTheAgentsAtStatusUnavailableAndHasNoAttention() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)  // testes nunca ativam nem mostram o app
        let home = URL(fileURLWithPath: "/tmp/abt-\(UInt32.random(in: 0 ... 0xFFFFFF))", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let env = AppEnvironment(environment: ["RACKY_SLICE": "1", "RACKY_HOME": home.path, "RACKY_APP_SOCK": home.appendingPathComponent("a.sock").path])
        #expect(env.attention == nil && env.fakeNotifier == nil)
        #expect(!env.registry.isRendered(.pageInbox) && !env.registry.isRendered(.sessionNextNeedingAttention))
        let cast = AttentionFixtures.cast(home: "/Users/test")
        var input = SidebarInput(snapshot: cast.snapshot)
        input.attention = AttentionCenter()
        let projection = SidebarProjector.build(input)
        let glyphs = (projection.projects.flatMap(\.sessions) + projection.cleanSessions).map(\.glyph)
        #expect(!glyphs.isEmpty && glyphs.allSatisfy { $0 == .unknown }, "sem hooks, agente vivo = Status unavailable")
    }

    @Test func settingsNotificationsOnlyAsksForPermissionOnAllow() async throws {
        let rig = try await Self.rig()
        defer { Task { await Self.stop(rig) } }
        let env = rig.env
        let notifier = try #require(env.fakeNotifier)
        _ = try await env.registry.perform(.appSettings, nil)
        _ = try await env.registry.perform(.settingsOpenSection, .select("notifications"))
        await env.settings.refreshNotificationAuthorization()
        #expect(env.settings.section == "notifications" && env.settings.notificationAuthorization == .notDetermined)
        #expect(notifier.requestCount == 0, "abrir a seção só lê o estado")
        // Teste de notificação desabilitado até a permissão, com o motivo exato.
        #expect(env.registry.availability(of: .settingsTestNotification) == .disabled(reason: "Notifications are off for Racky."))
        _ = try await env.registry.perform(.settingsNotificationsTerminalBell, .set("on"))
        _ = try await env.registry.perform(.settingsNotificationsNeedsInput, .set("off"))
        _ = try await env.registry.perform(.settingsNotificationsSound, .select("none"))
        let prefs = env.settings.settings.notifications
        #expect(prefs.terminalBell && !prefs.needsInput && prefs.sound == .none)
        _ = try await env.registry.perform(.notificationsRequest, nil)
        #expect(notifier.requestCount == 1 && env.settings.notificationAuthorization == .authorized)
        #expect(env.registry.availability(of: .notificationsRequest) == .disabled(reason: "Notifications are on."))
        _ = try await env.registry.perform(.settingsTestNotification, nil)
        #expect(await Self.wait { notifier.posted.count == 1 })
    }

    @Test func inboxActionsFilterAndMarkRead() async throws {
        let rig = try await Self.rig()
        defer { Task { await Self.stop(rig) } }
        let env = rig.env
        let attention = try #require(env.attention)
        // Estado direto no coordenador: o helper já foi exercitado no teste principal.
        let asking = Self.agent("permission"), done = Self.agent("done")
        attention.handle(ActivityService.Update(
            runID: asking.runID, terminalID: asking.terminalID, activity: .needsInput(.question), lastMessage: nil, statusReason: nil,
            subtitle: nil, liveChildren: 0))
        attention.handle(ActivityService.Update(
            runID: done.runID, terminalID: done.terminalID, activity: .done, lastMessage: "Fixed.", statusReason: nil, subtitle: nil, liveChildren: 0))
        #expect(await Self.wait { attention.center.statuses.count == 2 })

        _ = try await env.registry.perform(.pageInbox, nil)
        #expect(env.sidebar.inboxOpen)
        #expect(env.sidebar.inboxFeed.rows.count == 2)
        _ = try await env.registry.perform(.inboxFilter, .select("needsYou"))
        #expect(env.sidebar.inboxFeed.rows.map(\.id) == [asking.terminalID])
        _ = try await env.registry.perform(.inboxFilter, .select("unread"))
        #expect(env.sidebar.inboxFeed.rows.count == 1 && env.sidebar.inboxFeed.rows[0].id == done.terminalID, "needs input ainda não é 'não lido'")
        _ = try await env.registry.perform(.inboxFilter, .select("all"))

        // Clicar numa linha vai até a sessão (03 §9.1: "Clique: vai até a sessão, pane ou viewer certo ... e marca lido"): a sidebar
        // volta à lista de sessões e a linha fica lida. Reabrir o Inbox mostra o feed de novo.
        _ = try await env.registry.perform(.notificationOpen, .select(done.terminalID.uuidString))
        #expect(!env.sidebar.inboxOpen && !attention.center.unread.contains(done.terminalID))
        _ = try await env.registry.perform(.pageInbox, nil)
        #expect(env.sidebar.inboxOpen)
        _ = try await env.registry.perform(.inboxMarkRead, .select(asking.terminalID.uuidString))
        #expect(attention.center.badgeCount == 0)
        #expect(env.registry.availability(of: .inboxMarkAllRead) == .disabled(reason: "Nothing unread"))
        // Esc / clicar de novo em Inbox volta à lista de sessões.
        _ = try await env.registry.perform(.pageInbox, nil)
        #expect(!env.sidebar.inboxOpen)
    }
}
