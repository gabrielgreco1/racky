import RackyProtocol
import Foundation
import Testing

@testable import RackyCore

/// Os subagentes que a sidebar lista (todos, com ou sem computador): título do spawn emparelhado com o `SubagentStart`, fase e tempos.
@Suite struct SubagentInfoTests {
    private func event(_ name: String, tool: String? = nil, target: String? = nil, agent: String? = nil, type: String? = nil, at: Int64) -> ActivityEvent {
        ActivityEvent(
            name: name, payload: ReducedHookPayload(toolName: tool, toolTarget: target, agentID: agent, agentType: type), atNs: at * 1_000_000_000)
    }

    @Test func spawnDescriptionsAreMatchedInOrderToTheSubagentsThatStart() {
        var s = ActivityState()
        for e in [
            event("SessionStart", at: 1),
            event("PreToolUse", tool: "Agent", target: "Study the Houston listings site", at: 2),
            event("PreToolUse", tool: "Agent", target: "Check the Austin fee schedule", at: 3),
            event("SubagentStart", agent: "a1", type: "racky-worker-1", at: 4),
            event("SubagentStart", agent: "a2", type: "general-purpose", at: 5),
        ] { s = ActivityReducer.reduce(s, e) }
        let infos = s.subagentInfos
        #expect(infos.map(\.agentID) == ["a1", "a2"])
        #expect(infos.map(\.title) == ["Study the Houston listings site", "Check the Austin fee schedule"])
        #expect(infos.allSatisfy { $0.phase == .running } && infos[0].displayTitle == "Study the Houston listings site")
        #expect(s.pendingTitles.isEmpty)
    }

    @Test func stopMarksDoneWithItsEndTimeAndNeedsInputShowsWhilePending() {
        var s = ActivityState()
        for e in [
            event("PreToolUse", tool: "Task", target: "Read the docs", at: 1),
            event("SubagentStart", agent: "a1", type: "Explore", at: 2),
            event("SubagentStop", agent: "a1", type: "Explore", at: 62),
        ] { s = ActivityReducer.reduce(s, e) }
        let info = s.subagentInfos[0]
        #expect(info.phase == .done && info.title == "Read the docs")
        #expect(info.endedAt?.timeIntervalSince(info.startedAt) == 60)
        var waiting = ActivityState()
        for e in [event("SubagentStart", agent: "b1", type: "Explore", at: 1)] { waiting = ActivityReducer.reduce(waiting, e) }
        waiting.pending["b1"] = PendingInput(kind: .permission, summary: "Wants to run: ls")
        #expect(waiting.subagentInfos[0].phase == .needsInput)
        #expect(waiting.subagentInfos[0].displayTitle == "Explore", "no spawn description: the subagent type is the title")
    }

    @Test func internalUntypedSubagentsAreHidden() {
        // Subagentes internos do Claude Code (sem spawn pela ferramenta, sem tipo) não viram linha na sidebar.
        var s = ActivityState()
        s = ActivityReducer.reduce(s, event("SubagentStart", agent: "z", at: 1))
        s = ActivityReducer.reduce(s, event("SubagentStop", agent: "z", at: 1))
        #expect(s.subagentInfos.isEmpty)
    }
}
