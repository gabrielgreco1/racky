@testable import RackyPlatform
import RackyProtocol
import Foundation
import Testing

@testable import RackyCore

@Suite struct NativeIDCaptureTests {
    // MARK: Claude: o app gera o ID

    @Test func claudeIDIsGeneratedByTheAppBeforeSpawn() throws {
        let plan = try LaunchSamples.plan(LaunchSpec(provider: .claude, initialPrompt: "hi"))
        let id = LaunchSamples.fixedID.uuidString.lowercased()
        #expect(plan.capture == .assigned(id))
        #expect(plan.nativeConversationID == id)
        // Cada lançamento novo gera um UUID novo quando o spec não traz um.
        let a = try LaunchPlanner.plan(LaunchSamples.input(LaunchSpec(provider: .claude)))
        let b = try LaunchPlanner.plan(LaunchSamples.input(LaunchSpec(provider: .claude)))
        #expect(a.nativeConversationID != b.nativeConversationID)
        #expect(UUID(uuidString: a.nativeConversationID ?? "") != nil)
    }

    @Test func codexAndOpenCodeUseCaptureStrategies() throws {
        let codex = try LaunchSamples.plan(LaunchSpec(provider: .codex, initialPrompt: "hi"))
        #expect(codex.capture == .codexRollout(cwd: LaunchSamples.cwd))
        #expect(codex.nativeConversationID == nil)
        let oc = try LaunchSamples.plan(LaunchSpec(provider: .opencode, initialPrompt: "hi"))
        #expect(oc.capture == .openCodeSessionList(cwd: LaunchSamples.cwd))
        #expect(oc.nativeConversationID == nil)
    }

    // MARK: Codex: rollout

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ab-codex-\(UUID().uuidString)/sessions")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func writeRollout(root: URL, day: Date, id: String, cwd: String, timestamp: Date, name: String? = nil) throws -> URL {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: day)
        let dir = root.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = timestamp.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        let meta = "{\"timestamp\":\"\(stamp)\",\"ordinal\":0,\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\",\"timestamp\":\"\(stamp)\",\"cwd\":\"\(cwd)\",\"base_instructions\":\"\(String(repeating: "x", count: 100_000))\"}}\n"
        let url = dir.appendingPathComponent(name ?? "rollout-\(id).jsonl")
        try Data((meta + "{\"type\":\"event_msg\"}\n").utf8).write(to: url)
        return url
    }

    @Test func rolloutMatchesCwdAndTimestamp() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let spawn = Date()
        try writeRollout(root: root, day: spawn, id: "old-session", cwd: "/work/repo", timestamp: spawn.addingTimeInterval(-3600))
        try writeRollout(root: root, day: spawn, id: "other-cwd", cwd: "/work/other", timestamp: spawn.addingTimeInterval(1))
        try writeRollout(root: root, day: spawn, id: "just-before", cwd: "/work/repo", timestamp: spawn.addingTimeInterval(-1.5)) // dentro da folga de 2 s
        try writeRollout(root: root, day: spawn, id: "later-one", cwd: "/work/repo", timestamp: spawn.addingTimeInterval(5))
        let match = CodexRolloutScanner.find(root: root, cwd: "/work/repo", spawnedAt: spawn)
        #expect(match?.id == "just-before") // o primeiro criado a partir de spawn − 2 s
        #expect(CodexRolloutScanner.find(root: root, cwd: "/work/nowhere", spawnedAt: spawn) == nil)
    }

    @Test func rolloutSymlinkedCwdMatches() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let spawn = Date()
        // /tmp -> /private/tmp: o Codex grava o caminho real.
        try writeRollout(root: root, day: spawn, id: "real-path", cwd: "/private/tmp", timestamp: spawn.addingTimeInterval(1))
        #expect(CodexRolloutScanner.find(root: root, cwd: "/tmp", spawnedAt: spawn)?.id == "real-path")
    }

    @Test func rolloutPastMidnightLooksAtAdjacentDay() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let spawn = Date()
        let tomorrow = spawn.addingTimeInterval(86_400)
        try writeRollout(root: root, day: tomorrow, id: "next-day", cwd: "/work/repo", timestamp: spawn.addingTimeInterval(2))
        #expect(CodexRolloutScanner.find(root: root, cwd: "/work/repo", spawnedAt: spawn)?.id == "next-day")
    }

    @Test func rolloutIgnoresMalformedAndNonMetaFiles() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let spawn = Date()
        let c = Calendar.current.dateComponents([.year, .month, .day], from: spawn)
        let dir = root.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json\n".utf8).write(to: dir.appendingPathComponent("rollout-bad.jsonl"))
        try Data("{\"type\":\"event_msg\"}\n".utf8).write(to: dir.appendingPathComponent("rollout-notmeta.jsonl"))
        try Data().write(to: dir.appendingPathComponent("rollout-empty.jsonl"))
        try Data("{}\n".utf8).write(to: dir.appendingPathComponent("unrelated.txt"))
        #expect(CodexRolloutScanner.find(root: root, cwd: "/work/repo", spawnedAt: spawn) == nil)
        #expect(CodexRolloutScanner.find(root: root.appendingPathComponent("missing"), cwd: "/work/repo", spawnedAt: spawn) == nil)
    }

    @Test func realFixtureShapeParses() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ab-meta-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        try LaunchFixtures.data("codex-session-meta.jsonl").write(to: file)
        let meta = try #require(CodexRolloutScanner.sessionMeta(of: file))
        #expect(meta.id == "01a147e5-72b7-7c52-a686-6e002673cc8b")
        #expect(meta.cwd == "/Users/example/work")
        #expect(abs(meta.timestamp.timeIntervalSince1970 - 1_792_207_581.890) < 1) // 2026-10-17T03:26:21.890Z
    }

    @Test func threadNameFromSessionIndexLastLineWins() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ab-index-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let lines = [
            #"{"id":"a1","thread_name":"First","updated_at":"2026-08-03T19:49:19Z"}"#,
            #"{"id":"b2","thread_name":"Other","updated_at":"2026-08-03T19:49:19Z"}"#,
            #"{"id":"a1","thread_name":"Renamed","updated_at":"2026-08-04T19:49:19Z"}"#,
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        #expect(CodexRolloutScanner.threadName(forID: "a1", indexFile: file) == "Renamed")
        #expect(CodexRolloutScanner.threadName(forID: "zz", indexFile: file) == nil)
    }

    @Test func capturerPollsUntilTheRolloutAppears() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let spawn = Date()
        let polls = Counter()
        let capturer = NativeIDCapturer(
            runner: FakeCommandRunner([:]),
            pause: { _ in
                if await polls.increment() == 3 {
                    _ = try? self.writeRollout(root: root, day: spawn, id: "appeared", cwd: "/work/repo", timestamp: Date())
                }
            }
        )
        let id = await capturer.captureCodex(root: root, cwd: "/work/repo", spawnedAt: spawn, timeout: .seconds(60), interval: .milliseconds(1))
        #expect(id == "appeared")
        #expect(await polls.value == 3)
    }

    @Test func capturerGivesUpAfterTimeout() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let clock = ClockBox()
        let capturer = NativeIDCapturer(runner: FakeCommandRunner([:]), pause: { _ in clock.advance(4) }, clock: { clock.now })
        let id = await capturer.captureCodex(root: root, cwd: "/work/repo", spawnedAt: clock.now, timeout: .seconds(10))
        #expect(id == nil)
    }

    // MARK: OpenCode: session list

    @Test func openCodeSessionListParsesRealShape() {
        let sessions = OpenCodeSessionList.parse(LaunchFixtures.data("opencode-session-list.json"))
        #expect(sessions.count == 2)
        #expect(sessions[1].directory == "/Users/example/work")
        #expect(OpenCodeSessionList.parse(Data("warning: noise\n".utf8) + LaunchFixtures.data("opencode-session-list.json")).count == 2)
        #expect(OpenCodeSessionList.parse(Data("garbage".utf8)).isEmpty)
    }

    @Test func openCodeNewSessionIsTheOneAddedInTheSameDirectory() {
        let after = OpenCodeSessionList.parse(LaunchFixtures.data("opencode-session-list.json"))
        let before = [after[0]]
        #expect(OpenCodeSessionList.newSession(before: before, after: after, cwd: "/Users/example/work")?.id == "ses_bbbbbbbbbbbbbbbbbbbbbbbb02")
        #expect(OpenCodeSessionList.newSession(before: before, after: after, cwd: "/Users/example/elsewhere") == nil)
        #expect(OpenCodeSessionList.newSession(before: after, after: after, cwd: "/Users/example/work") == nil)
    }

    @Test func openCodeCaptureRunsOnlySessionList() async throws {
        let runner = FakeCommandRunner([
            "opencode session list --format json": .init(stdout: LaunchFixtures.text("opencode-session-list.json")),
        ])
        let delays = Counter()
        let capturer = NativeIDCapturer(runner: runner, pause: { _ in _ = await delays.increment() })
        let before = [OpenCodeSessionList.parse(LaunchFixtures.data("opencode-session-list.json"))[0]]
        let id = await capturer.captureOpenCode(before: before, executable: "/usr/local/bin/opencode", environment: [:], cwd: "/Users/example/work")
        #expect(id == "ses_bbbbbbbbbbbbbbbbbbbbbbbb02")
        #expect(await delays.value == 1) // um poll depois de 5 s
        #expect(await runner.commands() == ["opencode session list --format json"])
    }
}

actor Counter {
    private(set) var value = 0
    func increment() -> Int { value += 1; return value }
}

final class ClockBox: @unchecked Sendable { // SAFETY: relógio de teste avançado só pelo chamador sequencial.
    private var t = Date()
    var now: Date { t }
    func advance(_ seconds: TimeInterval) { t = t.addingTimeInterval(seconds) }
}
