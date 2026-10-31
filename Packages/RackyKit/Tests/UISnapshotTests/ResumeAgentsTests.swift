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

/// T2-07: overlay "Resume interrupted agents?" e aba Conversations. Nada de janela, daemon ou dados do dono: o ambiente
/// aponta para uma pasta temporária e os transcripts são fixtures.
@MainActor
@Suite(.serialized, .offscreenAppKit) struct ResumeAgentsUITests {
    nonisolated static let now = Date(timeIntervalSince1970: 1_800_000_000)
    nonisolated static let codexID = "0199aaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    nonisolated static let claudeID = "11111111-1111-1111-1111-111111111111"

    final class Rig {
        let root: URL
        let env: AppEnvironment
        let conversations: ConversationsController
        let resume: ResumeAgentsController
        var copied: [String] = []

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("ab-resume-ui-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("home"), withIntermediateDirectories: true)
            env = AppEnvironment(environment: ["RACKY_HOME": root.appendingPathComponent("home").path])
            conversations = env.conversations!
            resume = env.resumeAgents!
            let history = ConversationHistory(
                claudeProjects: root.appendingPathComponent("claude", isDirectory: true), codexSessions: root.appendingPathComponent("codex", isDirectory: true))
            conversations.history = history
            resume.history = history
            conversations.now = { ResumeAgentsUITests.now }
            conversations.liveConversations = { [ResumeAgentsUITests.codexID] }
            conversations.copyToPasteboard = { [unowned self] in copied.append($0) }
            try seedTranscripts(history)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        private func write(_ lines: [[String: Any]], to url: URL, at date: Date) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let text = lines.map { String(decoding: (try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys])) ?? Data(), as: UTF8.self) }
            try (text.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }

        func seedTranscripts(_ history: ConversationHistory) throws {
            let cwd = "/Users/me/racky"
            let dir = history.claudeProjects.appendingPathComponent(ConversationHistory.claudeDirectoryName(forCwd: cwd))
            try write([
                ["type": "user", "cwd": cwd, "gitBranch": "feat/retry", "message": ["role": "user", "content": "Add retry logic to the HTTP client"]],
                ["type": "assistant", "timestamp": "2026-10-17T08:35:30.006Z", "message": ["id": "m", "model": "claude-x", "content": [["type": "text", "text": "Done."]],
                    "usage": ["input_tokens": 10, "output_tokens": 5, "cache_read_input_tokens": 61_990, "cache_creation_input_tokens": 20_000]]],
            ], to: dir.appendingPathComponent(ResumeAgentsUITests.claudeID + ".jsonl"), at: Self.date(hoursAgo: 3))
            try write([
                ["type": "user", "cwd": cwd, "gitBranch": "main", "message": ["role": "user", "content": "Explain the restore planner"]],
            ], to: dir.appendingPathComponent("22222222-2222-2222-2222-222222222222.jsonl"), at: Self.date(hoursAgo: 30))
            try write([
                ["type": "session_meta", "payload": ["id": ResumeAgentsUITests.codexID, "cwd": cwd, "git": ["branch": "main"]]],
                ["type": "event_msg", "payload": ["type": "user_message", "message": "Fix the flaky insights test"]],
                ["type": "event_msg", "payload": ["type": "agent_message", "message": "Waiting for sampling to stop."]],
            ], to: history.codexSessions.appendingPathComponent("2026/10/17/rollout-2026-10-17T08-00-00-\(ResumeAgentsUITests.codexID).jsonl"), at: Self.date(hoursAgo: 1))
        }

        static func date(hoursAgo: Double) -> Date { ResumeAgentsUITests.now.addingTimeInterval(-hoursAgo * 3600) }
    }

    // MARK: Ações

    @Test func everyNewActionIsRegisteredAndOffered() throws {
        let rig = try Rig()
        defer { rig.remove() }
        let ids: [ActionID] = [
            .sessionResumeAgents, .dialogResumeAgentsConfirm, .dialogResumeAgentsCancel, .dialogResumeAgentsSelectAll, .dialogResumeAgentsSelectNone,
            .dialogResumeAgentsToggleRow, .panelConversations, .tabQuickLaunchResume, .conversationResume, .conversationResumeSplit,
            .conversationShowTranscript, .conversationMenu, .conversationCopyResumeCommand, .conversationCopyId, .conversationSetScope,
            .conversationSetQuery, .conversationBack,
        ]
        for id in ids { #expect(rig.env.registry.isOffered(id), "\(id.rawValue)") }
    }

    @Test func resumeAgentsIsDisabledWithoutInterruptedAgents() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        guard case .disabled(let reason) = rig.env.registry.availability(of: .sessionResumeAgents) else {
            Issue.record("deveria estar desabilitada")
            return
        }
        #expect(reason == "No interrupted agents in this session.")
        await #expect(throws: (any Error).self) { _ = try await rig.env.registry.perform(.sessionResumeAgents, .select(UUID().uuidString)) }
        await #expect(throws: (any Error).self) { _ = try await rig.env.registry.perform(.dialogResumeAgentsToggleRow, .select(UUID().uuidString)) }
    }

    /// Banner "Background agents stopped unexpectedly" (AC-810): o botão `Resume Agents…` abre o overlay da sessão atual; se ela não tem
    /// agente parado, o da sessão que parou por último.
    @Test func daemonLossBannerResumeOpensTheOverlayForTheRightSession() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        func seed(_ title: String, endedAt: Date) -> (Session, RackyProtocol.Tab, Terminal) {
            let session = Session(kind: .folder, folderPath: "/tmp/\(title)", title: title)
            let tabID = UUID()
            var t = Terminal(
                tabID: tabID, provider: .claude, title: "Claude Code", cwd: "/tmp", launchSpec: LaunchSpec(provider: .claude),
                nativeConversationID: UUID().uuidString, state: .interrupted, endedAt: endedAt)
            t.lastMessage = title
            let tab = RackyProtocol.Tab(id: tabID, sessionID: session.id, title: "t", layout: .leaf(Pane(content: .terminal(t.id))))
            return (session, tab, t)
        }
        let older = seed("older", endedAt: Self.now.addingTimeInterval(-600)), newer = seed("newer", endedAt: Self.now)
        let idle = Session(kind: .folder, folderPath: "/tmp/idle", title: "idle")
        rig.env.workspace.ingest(
            StoreSnapshot(sessions: [older.0, newer.0, idle], tabs: [older.1, newer.1], terminals: [older.2, newer.2]))
        let registry = rig.env.registry

        // Sessão atual sem agente parado (ou nenhuma): vai para a que parou por último.
        rig.env.workspace.setSession(idle.id)
        #expect(rig.env.workspace.mostRecentSessionWithInterruptedAgents() == newer.0.id)
        #expect(rig.resume.defaultTarget() == newer.0.id)
        #expect(registry.availability(of: .sessionResumeAgents) == .enabled)
        _ = try await registry.perform(.sessionResumeAgents, .press)
        #expect(rig.resume.isOpen && rig.resume.model?.sessionID == newer.0.id)
        _ = try await registry.perform(.dialogResumeAgentsCancel, nil)
        #expect(!rig.resume.isOpen)

        // Sessão atual com agente parado: ela mesma, mesmo havendo outra mais recente.
        rig.env.workspace.setSession(older.0.id)
        #expect(rig.resume.defaultTarget() == older.0.id)
        _ = try await registry.perform(.sessionResumeAgents, .press)
        #expect(rig.resume.model?.sessionID == older.0.id)
    }

    @Test func conversationsListFiltersAndCopiesTheRightText() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let registry = rig.env.registry
        _ = try await registry.perform(.conversationSetScope, .select("all"))
        let c = rig.conversations
        #expect(c.rows.map(\.nativeID) == [Self.codexID, Self.claudeID, "22222222-2222-2222-2222-222222222222"], "mais recente primeiro")
        let codex = try #require(c.conversation(Self.codexID)), claude = try #require(c.conversation(Self.claudeID))
        #expect(c.isLive(codex) && !c.isLive(claude))
        _ = try await registry.perform(.conversationSetQuery, .set("retry"))
        #expect(c.rows.map(\.nativeID) == [Self.claudeID], "busca por título")
        _ = try await registry.perform(.conversationSetQuery, .set("codex"))
        #expect(c.rows.map(\.nativeID) == [Self.codexID], "busca pelo agente")
        _ = try await registry.perform(.conversationSetQuery, .set(""))

        let command = try await registry.perform(.conversationCopyResumeCommand, .select(Self.claudeID))
        #expect(command.message == "claude --resume \(Self.claudeID)")
        _ = try await registry.perform(.conversationCopyResumeCommand, .select(Self.codexID))
        _ = try await registry.perform(.conversationCopyId, .select(Self.claudeID))
        #expect(rig.copied == ["claude --resume \(Self.claudeID)", "codex resume \(Self.codexID)", Self.claudeID])
    }

    @Test func sessionScopeWithoutASessionIsEmptyAndResumeNeedsASession() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let registry = rig.env.registry
        _ = try await registry.perform(.conversationSetScope, .select("session"))
        #expect(rig.conversations.rows.isEmpty)
        _ = try await registry.perform(.conversationSetScope, .select("all"))
        // Ativa noutro terminal: nunca relançada (AC-205); sem sessão aberta, as outras também falham sem abrir nada.
        await #expect(throws: (any Error).self) { _ = try await registry.perform(.conversationResume, .select(Self.codexID)) }
        await #expect(throws: (any Error).self) { _ = try await registry.perform(.conversationResume, .select(Self.claudeID)) }
        await #expect(throws: (any Error).self) { _ = try await registry.perform(.conversationResume, .select("unknown")) }
    }

    @Test func transcriptOpensInReadModeAndBackClosesIt() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let registry = rig.env.registry
        _ = try await registry.perform(.conversationSetScope, .select("all"))
        await #expect(throws: (any Error).self) { _ = try await registry.perform(.conversationBack, nil) }
        _ = try await registry.perform(.conversationShowTranscript, .select(Self.codexID))
        #expect(rig.conversations.transcript?.blocks.map(\.role) == ["You", "Codex"])
        _ = try await registry.perform(.conversationBack, nil)
        #expect(rig.conversations.transcript == nil)
    }

    @Test func conversationsShortcutOpensTheRightPanelModule() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        rig.env.rightPanel.updateWindow(width: 1440, sidebarWidth: 280)
        #expect(rig.env.rightPanel.module(.conversations) != nil)
        #expect(try await rig.env.registry.perform(.panelConversations, nil).message == "open")
        #expect(rig.env.rightPanel.isOn(.conversations))
        #expect(try await rig.env.registry.perform(.panelConversations, nil).message == "closed")
        #expect(!rig.env.rightPanel.isOn(.conversations))
    }

    // MARK: Snapshots

    func snap<V: View>(_ view: V, size: CGSize, name: String, rig: Rig, line: UInt = #line) {
        DSFonts.registerIfNeeded()
        let root = view
            .environment(\.actionRegistry, rig.env.registry)
            .environment(\.elementStore, rig.env.elements)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        withSnapshotTesting(record: ComponentSnapshotTests.recording) {
            assertSnapshot(of: host, as: .image(precision: 0.98, perceptualPrecision: 0.97), named: name, testName: "resumeAgents", line: line)
        }
    }

    @Test func overlaySnapshot() throws {
        let rig = try Rig()
        defer { rig.remove() }
        func c(_ provider: TerminalProvider, _ msg: String, model: String?, tokens: Int?, live: Bool = false, exited: Bool = false) -> ResumeCandidate {
            ResumeCandidate(
                id: UUID(), sessionTitle: "Add retry logic", provider: provider, model: model, lastMessage: msg, nativeID: UUID().uuidString,
                estimatedTokens: tokens, isLive: live, exited: exited)
        }
        let model = ResumeAgentsModel(
            sessionID: UUID(), sessionTitle: "Add retry logic",
            candidates: [
                c(.claude, "Waiting on your review of the migration plan", model: "opus", tokens: 84_000),
                c(.claude, "All tests pass; want me to open the PR?", model: "sonnet", tokens: 31_500),
                c(.codex, "Refactoring the sampler to stop on cancel", model: "gpt-5", tokens: 12_300),
                c(.claude, "Already running in another Racky", model: "opus", tokens: 52_000, live: true),
                c(.codex, "Exited after the last turn", model: nil, tokens: nil, exited: true),
            ])
        let card = ResumeAgentsView(model: model)
            .frame(width: DS.Layout.dialogWidth)
            .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Color.overlayCard))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Color.borderStrong))
            .padding(DS.Space.s4)
            .background(DS.Color.chrome)
        snap(card, size: CGSize(width: DS.Layout.dialogWidth + 2 * DS.Space.s4, height: 560), name: "overlay", rig: rig)
        #expect(model.count == 3 && model.liveCount == 1)
    }

    @Test func conversationsPageSnapshot() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        _ = try await rig.env.registry.perform(.conversationSetScope, .select("all"))
        snap(ConversationsView(controller: rig.conversations).frame(width: 380), size: CGSize(width: 380, height: 420), name: "conversations", rig: rig)
        _ = try await rig.env.registry.perform(.conversationShowTranscript, .select(Self.codexID))
        snap(ConversationsView(controller: rig.conversations).frame(width: 380), size: CGSize(width: 380, height: 260), name: "transcript", rig: rig)
    }
}
