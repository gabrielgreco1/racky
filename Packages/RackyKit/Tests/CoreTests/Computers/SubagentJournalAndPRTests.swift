import Foundation
import Testing
@testable import RackyCore

/// 24b: o "#N" na linha do subagente e o diário inteiro na aba dele.
struct SubagentJournalAndPRTests {
    @Test func theLastPullRequestLinkInTheMessageIsTheOneShown() {
        let message = """
            Done. Draft was https://github.com/acme/crawlers/pull/41 (closed); final PR: https://github.com/acme/crawlers/pull/57.
            """
        let url = SubagentInfo.pullRequest(in: message)
        #expect(url?.absoluteString == "https://github.com/acme/crawlers/pull/57")
        #expect(url.map(SubagentInfo.pullRequestLabel) == "#57")
    }

    @Test func textWithoutAPullRequestHasNone() {
        #expect(SubagentInfo.pullRequest(in: "see https://github.com/acme/crawlers/tree/main") == nil)
        #expect(SubagentInfo.pullRequest(in: "https://evil.example/acme/x/pull/3") == nil)
        #expect(SubagentInfo.pullRequest(in: nil) == nil)
    }

    @Test func theSidebarInfoCarriesThePullRequestFromTheFullMessage() {
        var state = ActivityState()
        let long = String(repeating: "x", count: 300) + " https://github.com/acme/crawlers/pull/9"
        state.children["a1"] = ChildActivity(
            agentID: "a1", agentType: "racky-worker-1", phase: .done, implicit: false, startedAtNs: 1, lastEventAtNs: 2, endedAtNs: 2,
            lastMessage: long, subtitle: nil, title: "tn-memphis")
        #expect(state.subagentInfos.first?.pullRequest?.lastPathComponent == "9", "o link vem do texto inteiro, não do resumo de 120 letras")
    }

    @Test func theJournalIsReadInOrderWithKindTimeAndSystemFlag() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let log = ChainedLog(file: RunFolder(root: root).file("journal.jsonl"))
        try await log.append(["id": .string("A"), "kind": .string("PLAN"), "text": .string("clone and sample"), "ts": .double(1_700_000_000)])
        try await log.append(["id": .string("B"), "kind": .string("NOTE"), "text": .string("proxy -> zyte"), "system": .bool(true)])
        try await log.append(["id": .string("C"), "kind": .string("DOING"), "text": .string("")])
        let lines = JournalLine.read(run: root)
        #expect(lines.map(\.id) == ["A", "B"], "linha sem texto fica de fora")
        #expect(lines[0].kind == "PLAN")
        #expect(lines[0].at == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(lines[1].system)
    }
}
