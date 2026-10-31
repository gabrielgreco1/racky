import RackyProtocol
import RackyStore
import Foundation
import Testing

@testable import RackyCore

/// Reabertura (T1-23, 06 §1.4 e §2.6): classificação do motivo, cold log, Resume/Start Fresh e a reconciliação com o daemon.
@Suite(.tags(.integration), .serialized, .timeLimit(.minutes(1))) struct RestoreTests {
    // MARK: Motivo da interrupção

    @Test func reasonFollowsBootTimeThenCleanExit() {
        let boot = Date(timeIntervalSince1970: 1_000_000)
        let before = boot.addingTimeInterval(-3600), after = boot.addingTimeInterval(3600)
        #expect(InterruptionClassifier.reason(startedAt: before, bootTime: boot, previousRunWasClean: true) == .macRestarted)
        #expect(InterruptionClassifier.reason(startedAt: after, bootTime: boot, previousRunWasClean: true) == .appClosed)
        #expect(InterruptionClassifier.reason(startedAt: after, bootTime: boot, previousRunWasClean: false) == .unexpected)
        #expect(InterruptionClassifier.reason(startedAt: nil, bootTime: boot, previousRunWasClean: nil) == .unexpected)
        #expect(InterruptionReason.macRestarted.bannerText == "This terminal stopped when your Mac restarted.")
        #expect(InterruptionReason.appClosed.bannerText == "This terminal stopped while Racky was closed.")
        #expect(InterruptionReason.unexpected.bannerText == "This terminal stopped unexpectedly.")
    }

    // MARK: Cold log

    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/abrestore-\(UInt32.random(in: 0 ... 0xFFFFFF))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func coldLogTailKeepsTheEndAndStartsOnALineBoundary() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = root.appendingPathComponent("S1", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let lines = (1 ... 200).map { "line-\($0)\r\n" }.joined()
        try lines.write(to: session.appendingPathComponent("output.log"), atomically: true, encoding: .utf8)
        let reader = ColdLogReader(sessionsDirectory: root)

        let whole = try #require(reader.tail(sessionID: "S1", maxBytes: 1 << 20))
        #expect(!whole.truncated)
        #expect(String(decoding: whole.bytes, as: UTF8.self) == lines)

        let cut = try #require(reader.tail(sessionID: "S1", maxBytes: 100))
        #expect(cut.truncated)
        let text = String(decoding: cut.bytes, as: UTF8.self)
        #expect(text.hasPrefix("line-"), "o corte começa depois de uma quebra de linha, nunca no meio de uma linha")
        #expect(text.hasSuffix("line-200\r\n"))
        #expect(reader.tail(sessionID: "missing") == nil)
        #expect(reader.tail(sessionID: "../S1") == nil)
    }

    @Test func coldLogTailJoinsTheRotatedSegment() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = root.appendingPathComponent("S2", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try "old-1\nold-2\n".write(to: session.appendingPathComponent("output.log.1"), atomically: true, encoding: .utf8)
        try "new-1\nnew-2\n".write(to: session.appendingPathComponent("output.log"), atomically: true, encoding: .utf8)
        let tail = try #require(ColdLogReader(sessionsDirectory: root).tail(sessionID: "S2"))
        #expect(String(decoding: tail.bytes, as: UTF8.self) == "old-1\nold-2\nnew-1\nnew-2\n")
    }

    // MARK: Resume e Start Fresh

    private func launchedClaude(prompt: String? = "hello") -> Terminal {
        // Como o app grava depois do primeiro start: `LaunchSpec` do plano (com o `--session-id` gerado) e o ID capturado.
        var spec = LaunchSpec(provider: .claude, permissionMode: "bypassPermissions", initialPrompt: prompt, nativeSessionID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        spec.model = "opus"
        var t = Terminal(tabID: UUID(), provider: .claude, title: "Claude Code", cwd: "/work", launchSpec: spec)
        t.nativeConversationID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        t.state = .interrupted
        return t
    }

    @Test func resumeDropsThePromptAndUsesTheCapturedID() {
        let plan = RestorePlanner.resume(launchedClaude())
        #expect(plan.mode == .resume(nativeID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"))
        #expect(plan.spec.initialPrompt == nil)
        #expect(plan.spec.resumeOf == "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        #expect(plan.spec.nativeSessionID == nil, "--session-id e --resume nunca juntos")
        #expect(plan.spec.model == "opus", "o resto do perfil do lançamento original é preservado")
    }

    @Test func resumeWithoutACapturedIDFallsBackToContinueLast() {
        var t = launchedClaude()
        t.nativeConversationID = nil
        t.launchSpec.nativeSessionID = nil
        let plan = RestorePlanner.resume(t)
        #expect(plan.mode == .continueLast)
        #expect(!RestorePlanner.hasExactResume(t))
        #expect(RestorePlanner.hasExactResume(launchedClaude()))
        var shell = Terminal(tabID: UUID(), provider: .shell, title: "zsh", cwd: "/", launchSpec: LaunchSpec(provider: .shell))
        shell.nativeConversationID = "x"
        #expect(!RestorePlanner.hasExactResume(shell), "shell nunca tem Resume")
    }

    @Test func startFreshKeepsTheConfigurationButForgetsTheConversation() {
        let spec = RestorePlanner.startFresh(launchedClaude())
        #expect(spec.nativeSessionID == nil && spec.resumeOf == nil && spec.initialPrompt == nil)
        #expect(spec.model == "opus" && spec.permissionMode == "bypassPermissions")
    }

    /// Golden (AC-806): o argv do Resume é regerado do `LaunchSpec`, com `--resume <id>` e as flags do perfil original, sem prompt.
    @Test func resumeArgvGolden() throws {
        let claudeCaps = LaunchSamples.helpCapabilities(.claude)
        let codexCaps = LaunchSamples.helpCapabilities(.codex)
        var out: [String] = []
        func add(_ name: String, _ plan: LaunchPlan) { out.append("## \(name)\n" + plan.argv.flattened.joined(separator: "\n")) }

        let claude = launchedClaude()
        let resume = RestorePlanner.resume(claude)
        add("claude resume (id captured, flags regenerated)", try LaunchSamples.plan(resume.spec, mode: resume.mode, capabilities: claudeCaps))
        add("claude resume after first launch (automatic mode, resumeOf set)", try LaunchSamples.plan(resume.spec, capabilities: claudeCaps))
        add("claude start fresh", try LaunchSamples.plan(RestorePlanner.startFresh(claude), capabilities: claudeCaps))

        var noID = claude
        noID.nativeConversationID = nil
        noID.launchSpec.nativeSessionID = nil
        let continueLast = RestorePlanner.resume(noID)
        add("claude continue last (no id)", try LaunchSamples.plan(continueLast.spec, mode: continueLast.mode, capabilities: claudeCaps))

        var codex = Terminal(tabID: UUID(), provider: .codex, title: "Codex", cwd: "/work", launchSpec: LaunchSpec(provider: .codex, initialPrompt: "hello"))
        codex.nativeConversationID = "01a147e5-72b7-7c52-a686-6e002673cc8b"
        let codexResume = RestorePlanner.resume(codex)
        add("codex resume", try LaunchSamples.plan(codexResume.spec, mode: codexResume.mode, capabilities: codexCaps))

        LaunchFixtures.assertGolden("restore/resume-argv.txt", out.joined(separator: "\n\n") + "\n")
        // O essencial, por extenso (o golden guarda o resto):
        let first = try LaunchSamples.plan(resume.spec, mode: resume.mode, capabilities: claudeCaps).argv
        #expect(first.identity == ["--resume", "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"])
        #expect(first.prompt.isEmpty)
        #expect(first.injected.isEmpty)
    }

    // MARK: Reconciliação com o daemon

    private func openStore() async throws -> (RackyStore, URL) {
        let root = try temporaryDirectory()
        let store = try await RackyStore.open(paths: StorePaths(root: root))
        return (store, root)
    }

    private func seed(_ store: RackyStore, states: [TerminalProcessState], startedAt: Date) async throws -> [Terminal] {
        let session = Session(kind: .clean, folderPath: "/tmp", title: "s")
        let tabID = UUID.v7()
        var terminals: [Terminal] = []
        for (i, state) in states.enumerated() {
            var t = Terminal(tabID: tabID, provider: .claude, title: "t\(i)", cwd: "/tmp", launchSpec: LaunchSpec(provider: .claude))
            t.state = state
            t.ptySessionID = SessionID().description
            t.startedAt = startedAt
            terminals.append(t)
        }
        let layout = PaneLayout.leaf(Pane(content: .terminal(terminals[0].id)))
        let tab = Tab(id: tabID, sessionID: session.id, title: "t", layout: layout, focusedTerminalID: terminals[0].id)
        try await store.saveBundle(session: session, tabs: [tab], terminals: terminals)
        return terminals
    }

    private func summary(_ t: Terminal, state: SessionState, exit: ExitInfo? = nil) -> SessionSummary {
        SessionSummary(sessionID: SessionID(string: t.ptySessionID!)!, pid: 123, argv0: "claude", cwd: "/tmp", state: state, startedAt: Date(), exit: exit, endSeq: 0)
    }

    @Test func reconcileKeepsLiveRecordsExitedAndInterruptsTheRestWithoutRelaunching() async throws {
        let (store, root) = try await openStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let terminals = try await seed(store, states: [.running, .running, .running, .launching, .exited], startedAt: now.addingTimeInterval(-60))
        let sessions = [
            summary(terminals[0], state: .running),
            summary(terminals[1], state: .exited, exit: ExitInfo(code: 3, at: now)),
        ]
        let boot = now.addingTimeInterval(-3600)
        let report = try await SessionReconciler.reconcile(store: store, daemonSessions: sessions, now: now, bootTime: boot)

        #expect(report.alive == [terminals[0].id])
        #expect(report.exited == [terminals[1].id])
        #expect(Set(report.interrupted.keys) == [terminals[2].id, terminals[3].id])
        // Primeira execução do app (sem estado salvo) conta como saída limpa anterior: morreu com o app fechado.
        #expect(report.interrupted.values.allSatisfy { $0 == .appClosed })

        let stored = try await store.snapshot().terminals
        func state(_ i: Int) -> TerminalProcessState? { stored.first { $0.id == terminals[i].id }?.state }
        #expect(state(0) == .running)
        #expect(state(1) == .exited)
        #expect(stored.first { $0.id == terminals[1].id }?.exitCode == 3)
        #expect(state(2) == .interrupted && state(3) == .interrupted)
        #expect(state(4) == .exited, "terminal já encerrado não é tocado")
        #expect(!stored.contains { $0.state == .launching || ($0.id == terminals[2].id && $0.state == .running) }, "nada fica pendurado")
        let reasons = await SessionReconciler.interruptions(store: store)
        #expect(reasons[terminals[2].id] == .appClosed)
    }

    @Test func interruptedByMistakeButAliveInTheDaemonComesBackRunning() async throws {
        let (store, root) = try await openStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        // Uma abertura que não alcançou o daemon (fallback para daemon filho) marcou tudo `interrupted`; o daemon do launchd seguiu vivo.
        let terminals = try await seed(store, states: [.interrupted, .interrupted], startedAt: now.addingTimeInterval(-60))
        let report = try await SessionReconciler.reconcile(store: store, daemonSessions: [summary(terminals[0], state: .running)], now: now)
        #expect(report.alive == [terminals[0].id])
        let stored = try await store.snapshot().terminals
        #expect(stored.first { $0.id == terminals[0].id }?.state == .running, "vivo no daemon: religado, nunca retomado em duplicata")
        #expect(stored.first { $0.id == terminals[1].id }?.state == .interrupted, "sem sessão viva continua interrompido")
    }

    @Test func aLiveSessionWhoseIDWasOverwrittenIsMatchedByTheLaunchRunID() async throws {
        let (store, root) = try await openStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        var terminals = try await seed(store, states: [.interrupted], startedAt: now.addingTimeInterval(-60))
        let run = UUID()
        terminals[0].currentRunID = run
        try await store.save(terminals[0])
        // A sessão viva no daemon tem outro ID (o salvo era de uma retomada que falhou num daemon que já morreu).
        let live = SessionSummary(sessionID: SessionID(), pid: 4242, argv0: "claude", cwd: "/tmp", state: .running, startedAt: now, endSeq: 0)
        let report = try await SessionReconciler.reconcile(
            store: store, daemonSessions: [live], now: now, runIDOfProcess: { pid in pid == 4242 ? run : nil })
        #expect(report.alive == [terminals[0].id])
        let stored = try await store.snapshot().terminals.first { $0.id == terminals[0].id }
        #expect(stored?.state == .running && stored?.ptySessionID == live.sessionID.description)
    }

    @Test func reconcileWithoutADaemonInterruptsEverythingAndSeparatesRebootFromCrash() async throws {
        let (store, root) = try await openStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        // Iniciado antes do boot atual: o Mac reiniciou.
        let terminals = try await seed(store, states: [.running], startedAt: now.addingTimeInterval(-7200))
        let reboot = try await SessionReconciler.reconcile(store: store, daemonSessions: nil, now: now, bootTime: now.addingTimeInterval(-3600))
        #expect(reboot.interrupted[terminals[0].id] == .macRestarted)

        // Segunda abertura sem saída limpa registrada entre elas (crash do app): morte sem aviso.
        var again = terminals[0]
        again.state = .running
        again.startedAt = now
        try await store.save(again)
        let crash = try await SessionReconciler.reconcile(store: store, daemonSessions: nil, now: now, bootTime: now.addingTimeInterval(-3600))
        #expect(crash.interrupted[terminals[0].id] == .unexpected, "o app anterior não saiu limpo")

        again.state = .running
        try await store.save(again)
        await SessionReconciler.markCleanExit(store: store)
        let clean = try await SessionReconciler.reconcile(store: store, daemonSessions: nil, now: now, bootTime: now.addingTimeInterval(-3600))
        #expect(clean.interrupted[terminals[0].id] == .appClosed)
    }
}
