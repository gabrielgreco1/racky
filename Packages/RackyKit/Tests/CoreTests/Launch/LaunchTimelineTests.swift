import Foundation
import Testing

@testable import RackyCore

@Suite struct LaunchTimelineTests {
    private let run = UUID()

    private func step(_ key: LaunchStepKey, _ status: LaunchStepStatus, _ detail: String? = nil) -> LaunchEvent {
        .step(LaunchProgress(runID: run, step: key, status: status, detail: detail))
    }

    @Test func onlyVisibleStepsBecomeRowsInCanonicalOrder() {
        var t = LaunchTimeline(agentName: "Claude Code")
        for e in [
            step(.envLogin, .running), step(.envLogin, .done), step(.gitFetch, .skipped), step(.launchConfig, .running),
            step(.launchConfig, .done), step(.ptySpawn, .running), step(.cliExec, .running),
        ] { t.apply(e) }
        #expect(t.rows.map(\.title) == ["Preparing launch", "Starting Claude Code…"])
        #expect(t.rows.map(\.status) == [.done, .running])
        #expect(t.runID == run)
    }

    @Test func gitRowsComeBeforeConfigAndSkippedRowsDisappear() {
        var t = LaunchTimeline(agentName: "Codex")
        t.apply(step(.launchConfig, .running))
        t.apply(step(.gitWorktree, .running))
        t.apply(step(.gitFetch, .running))
        #expect(t.rows.map(\.key) == [.gitFetch, .gitWorktree, .launchConfig])
        t.apply(step(.gitFetch, .skipped))
        #expect(t.rows.map(\.key) == [.gitWorktree, .launchConfig])
    }

    @Test func failureIsRecordedOnTheRow() {
        var t = LaunchTimeline(agentName: "Claude Code")
        t.apply(step(.launchConfig, .running))
        t.apply(step(.launchConfig, .failed, "boom"))
        #expect(t.rows.first?.status == .failed)
        #expect(t.failure == "boom")
        var hidden = LaunchTimeline(agentName: "Claude Code")
        hidden.apply(step(.cliResolve, .failed, "Claude Code isn't installed or isn't on your PATH."))
        #expect(hidden.rows.isEmpty)
        #expect(hidden.failure != nil)
    }

    @Test func firstOutputIsRemembered() {
        var t = LaunchTimeline(agentName: "x")
        #expect(!t.hasSeenFirstOutput)
        t.apply(.firstOutput(runID: run))
        #expect(t.hasSeenFirstOutput)
    }
}
