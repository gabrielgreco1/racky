import RackyProtocol
import Foundation
import Testing

@testable import RackyCore

/// T2-07: seleção do "Resume Agents…", custo à vista e o índice de conversas (AC-205, AC-207). Só fixtures em pasta temporária.
@Suite struct ResumeSelectionTests {
    func candidate(_ n: Int, live: Bool = false, exited: Bool = false, tokens: Int? = nil) -> ResumeCandidate {
        ResumeCandidate(
            id: UUID(), sessionTitle: "s", provider: .claude, lastMessage: "msg \(n)", nativeID: "native-\(n)", estimatedTokens: tokens, isLive: live,
            exited: exited)
    }

    @Test func everythingStartsCheckedExceptLiveAndExited() {
        let a = candidate(1), b = candidate(2), live = candidate(3, live: true), gone = candidate(4, exited: true)
        let selection = ResumeSelection(candidates: [a, b, live, gone])
        #expect(selection.count == 2 && selection.isSelected(a.id) && selection.isSelected(b.id))
        #expect(!selection.isSelected(live.id) && !selection.isSelected(gone.id))
        #expect(selection.selectableCount == 3)
    }

    @Test func uncheckingTwoOfSixLeavesFour() {
        let all = (1 ... 6).map { candidate($0) }
        var selection = ResumeSelection(candidates: all)
        #expect(selection.count == 6)
        selection.toggle(all[1].id)
        selection.toggle(all[4].id)
        #expect(selection.count == 4)
        #expect(selection.chosen.map(\.nativeID) == ["native-1", "native-3", "native-4", "native-6"], "na ordem da lista")
    }

    @Test func aLiveConversationCanNeverBeChecked() {
        let live = candidate(1, live: true)
        var selection = ResumeSelection(candidates: [live, candidate(2)])
        #expect(selection.toggle(live.id) == false)
        selection.set(live.id, on: true)
        selection.selectAll()
        #expect(!selection.isSelected(live.id) && selection.count == 1)
    }

    @Test func becomingLiveAfterOpeningDropsItFromTheSelection() {
        let a = candidate(1), b = candidate(2)
        var selection = ResumeSelection(candidates: [a, b])
        selection.update(a.id, live: true)
        #expect(selection.chosen.map(\.id) == [b.id])
        selection.selectNone()
        #expect(selection.count == 0)
        selection.selectAll()
        #expect(selection.count == 1)
    }

    @Test func totalCostSumsTheCheckedOnesAndCountsTheUnknown() {
        let a = candidate(1, tokens: 80_000), b = candidate(2, tokens: 4_000), c = candidate(3)
        var selection = ResumeSelection(candidates: [a, b, c])
        #expect(selection.totalTokens == 84_000 && selection.unknownCostCount == 1)
        selection.toggle(a.id)
        #expect(selection.totalTokens == 4_000)
    }

    @Test func costFormatting() {
        #expect(ResumeCost.format(tokens: 850) == "~850 tokens")
        #expect(ResumeCost.format(tokens: 84_300) == "~84k tokens")
        #expect(ResumeCost.format(tokens: 1_250_000) == "~1.2M tokens")
        #expect(ResumeCost.tokens(contextTokens: 5_000, transcriptBytes: 400) == 5_000, "usage do transcript manda")
        #expect(ResumeCost.tokens(contextTokens: nil, transcriptBytes: 4_000) == 1_000, "sem usage: bytes/4")
    }
}

@Suite struct ConversationHistoryTests {
    struct Rig {
        let root: URL
        let history: ConversationHistory
        var claude: URL { history.claudeProjects }
        var codex: URL { history.codexSessions }

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("ab-conv-\(UUID().uuidString)", isDirectory: true)
            history = ConversationHistory(
                claudeProjects: root.appendingPathComponent("claude/projects", isDirectory: true),
                codexSessions: root.appendingPathComponent("codex/sessions", isDirectory: true))
            try FileManager.default.createDirectory(at: history.claudeProjects, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: history.codexSessions, withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func json(_ object: [String: Any]) -> String {
            String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
        }

        @discardableResult
        func claudeSession(cwd: String, id: String, first: String, branch: String = "main", age: TimeInterval = 0, usage: Int? = 90_000) throws -> URL {
            let dir = claude.appendingPathComponent(ConversationHistory.claudeDirectoryName(forCwd: cwd), isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var lines = [
                json(["type": "file-history-snapshot"]),
                json(["type": "user", "isMeta": true, "cwd": cwd, "message": ["role": "user", "content": "<local-command-caveat>x</local-command-caveat>"]]),
                json(["type": "user", "cwd": cwd, "gitBranch": branch, "sessionId": id, "message": ["role": "user", "content": first]]),
                json(["type": "assistant", "cwd": cwd, "message": ["role": "assistant", "content": [["type": "text", "text": "Sure, on it."]]]]),
            ]
            if let usage {
                lines.append(json([
                    "type": "assistant", "timestamp": "2026-10-17T08:35:30.006Z", "cwd": cwd,
                    "message": ["id": "m1", "model": "claude-x", "role": "assistant", "content": [["type": "text", "text": "Done."]],
                                "usage": ["input_tokens": 10, "output_tokens": 50, "cache_read_input_tokens": usage - 20_010, "cache_creation_input_tokens": 20_000]],
                ]))
            }
            let file = dir.appendingPathComponent(id + ".jsonl")
            try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: file.path)
            return file
        }

        @discardableResult
        func codexSession(cwd: String, id: String, first: String, age: TimeInterval = 0, lastInput: Int? = 12_000) throws -> URL {
            let dir = codex.appendingPathComponent("2026/10/17", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var lines = [
                json(["type": "session_meta", "payload": ["id": id, "cwd": cwd, "git": ["branch": "feat/x"]]]),
                json(["type": "event_msg", "payload": ["type": "user_message", "message": first]]),
                json(["type": "event_msg", "payload": ["type": "agent_message", "message": "ok"]]),
            ]
            if let lastInput {
                lines.append(json(["type": "event_msg", "payload": ["type": "token_count", "info": ["last_token_usage": ["input_tokens": lastInput], "total_token_usage": ["total_tokens": 99_999]]]]))
            }
            let file = dir.appendingPathComponent("rollout-2026-10-17T08-00-00-\(id).jsonl")
            try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: file.path)
            return file
        }
    }

    static let cwd = "/Users/me/work/my.project_x"
    static let codexID = "0199aaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

    @Test func listsClaudeAndCodexConversationsOfTheFolderNewestFirst() throws {
        let rig = try Rig()
        defer { rig.remove() }
        try rig.claudeSession(cwd: Self.cwd, id: "11111111-1111-1111-1111-111111111111", first: "Add retry logic\nto the client", age: 3_600)
        try rig.codexSession(cwd: Self.cwd, id: Self.codexID, first: "Fix the flaky test", age: 60)
        try rig.claudeSession(cwd: "/Users/me/other", id: "22222222-2222-2222-2222-222222222222", first: "Not here")
        try rig.codexSession(cwd: "/Users/me/other", id: "0199ffff-bbbb-cccc-dddd-eeeeeeeeeeee", first: "Nor here")
        let scan = rig.history.scan(cwds: [Self.cwd])
        #expect(scan.unreadable.isEmpty)
        #expect(scan.conversations.map(\.nativeID) == [Self.codexID, "11111111-1111-1111-1111-111111111111"])
        let claude = try #require(scan.conversations.last), codex = try #require(scan.conversations.first)
        #expect(claude.provider == .claude && claude.title == "Add retry logic to the client", "pula o bloco de sistema e junta as linhas")
        #expect(claude.branch == "main" && claude.cwd == Self.cwd)
        #expect(claude.messageCount == 3, "1 do usuário + 2 do assistente; snapshot e linha isMeta não contam")
        #expect(claude.contextTokens == 90_000)
        #expect(codex.provider == .codex && codex.title == "Fix the flaky test" && codex.branch == "feat/x")
        #expect(codex.messageCount == 2 && codex.contextTokens == 12_000, "contexto da última volta, não o total acumulado")
    }

    @Test func allScopeReturnsEverythingAndSearchableMetadataOnly() throws {
        let rig = try Rig()
        defer { rig.remove() }
        try rig.claudeSession(cwd: Self.cwd, id: "11111111-1111-1111-1111-111111111111", first: "One")
        try rig.claudeSession(cwd: "/Users/me/other", id: "22222222-2222-2222-2222-222222222222", first: "Two")
        try rig.codexSession(cwd: "/Users/me/third", id: Self.codexID, first: "Three")
        #expect(rig.history.scan(cwds: nil).conversations.count == 3)
        #expect(rig.history.scan(cwds: []).conversations.isEmpty)
        #expect(rig.history.scan(cwds: [Self.cwd, "/Users/me/third"]).conversations.count == 2)
    }

    @Test func missingSourcesAreEmptyAndUnreadableOnesAreReported() throws {
        let rig = try Rig()
        defer { rig.remove() }
        try FileManager.default.removeItem(at: rig.codex)
        #expect(rig.history.scan(cwds: nil) == ConversationScan(), "pasta ausente não é erro")
        try "not a directory".write(to: rig.codex, atomically: true, encoding: .utf8)
        #expect(rig.history.scan(cwds: nil).unreadable == [.codex])
    }

    @Test func locateFindsTheTranscriptByNativeIDForTheCost() throws {
        let rig = try Rig()
        defer { rig.remove() }
        try rig.claudeSession(cwd: Self.cwd, id: "11111111-1111-1111-1111-111111111111", first: "One", usage: 84_000)
        try rig.claudeSession(cwd: Self.cwd, id: "33333333-3333-3333-3333-333333333333", first: "No usage", usage: nil)
        try rig.codexSession(cwd: Self.cwd, id: Self.codexID, first: "Codex one", lastInput: 7_000)
        let a = try #require(rig.history.locate(nativeID: "11111111-1111-1111-1111-111111111111", provider: .claude, cwd: Self.cwd))
        #expect(a.estimatedTokens == 84_000)
        let b = try #require(rig.history.locate(nativeID: "33333333-3333-3333-3333-333333333333", provider: .claude, cwd: nil))
        #expect(b.estimatedTokens == b.sizeBytes / 4, "sem usage: bytes/4")
        #expect(rig.history.locate(nativeID: Self.codexID, provider: .codex, cwd: Self.cwd)?.estimatedTokens == 7_000)
        #expect(rig.history.locate(nativeID: "../etc/passwd", provider: .claude, cwd: nil) == nil)
        #expect(rig.history.locate(nativeID: "nope", provider: .claude, cwd: Self.cwd) == nil)
    }

    @Test func resumeCommandsAndTranscript() throws {
        let rig = try Rig()
        defer { rig.remove() }
        try rig.claudeSession(cwd: Self.cwd, id: "11111111-1111-1111-1111-111111111111", first: "Add retry logic")
        try rig.codexSession(cwd: Self.cwd, id: Self.codexID, first: "Fix it")
        let scan = rig.history.scan(cwds: [Self.cwd])
        let claude = try #require(scan.conversations.first { $0.provider == .claude })
        let codex = try #require(scan.conversations.first { $0.provider == .codex })
        #expect(claude.resumeCommand == "claude --resume 11111111-1111-1111-1111-111111111111")
        #expect(codex.resumeCommand == "codex resume \(Self.codexID)")
        let blocks = rig.history.transcript(of: claude)
        #expect(blocks.map(\.role) == ["You", "Claude Code", "Claude Code"])
        #expect(blocks.first?.text == "Add retry logic")
        #expect(rig.history.transcript(of: codex).map(\.role) == ["You", "Codex"])
    }

    @Test func readingNeverWritesToTheSources() throws {
        let rig = try Rig()
        defer { rig.remove() }
        let file = try rig.claudeSession(cwd: Self.cwd, id: "11111111-1111-1111-1111-111111111111", first: "One")
        let before = try Data(contentsOf: file), mtime = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        _ = rig.history.scan(cwds: nil)
        _ = rig.history.transcript(of: try #require(rig.history.scan(cwds: nil).conversations.first))
        #expect(try Data(contentsOf: file) == before)
        #expect(try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == mtime)
        #expect(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path) == ["11111111-1111-1111-1111-111111111111.jsonl"])
    }
}
