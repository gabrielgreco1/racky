import Testing

@testable import RackyCore

struct LiveConversationsTests {
    @Test func picksResumeAndSessionIDArgumentsFromCommandLines() {
        let lines = [
            "/Users/x/.local/bin/claude --resume 34ba98ea-2cc4 --dangerously-skip-permissions",
            "claude --session-id 0b1c-ffee --settings /tmp/s.json",
            "claude --resume=abc",
            "/bin/zsh -l",
            "claude --resume",
        ]
        #expect(LiveConversations.ids(inCommandLines: lines) == ["34ba98ea-2cc4", "0b1c-ffee", "abc"])
    }
}
