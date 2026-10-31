import RackyProtocol
import Foundation
import Testing

@testable import RackyCore

private func states(_ events: [ActivityEvent]) -> [ActivityState] {
    var s = ActivityState()
    return events.map { e in
        s = ActivityReducer.reduce(s, e)
        return s
    }
}

private func ev(_ name: String, atNs: Int64, _ p: ReducedHookPayload = ReducedHookPayload()) -> ActivityEvent {
    ActivityEvent(name: name, payload: p, atNs: atNs)
}

private let t0: Int64 = 1_800_000_000_000_000_000
private func at(_ n: Int64) -> Int64 { t0 + n * 1_000_000 }

@Suite struct ReducerRealPayloadTests {
    @Test func claudeTurnWithBashFollowsTheStateTable() throws {
        let raws = try RealHooks.events(RealHooks.claudeBasic)
        #expect(raws.map(\.name) == ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd"])
        let s = states(RealHooks.activityEvents(raws))
        #expect(s.map(\.activity) == [.idle, .working, .working, .working, .done, .done])
        #expect(s[2].subtitle == "Running Bash")
        #expect(s[4].lastMessage == "DONE")
        #expect(s[4].subtitle == nil)
        #expect(s[5].sessionEndReason == "other")
        #expect(s[5].nativeSessionID == raws[0].object["session_id"] as? String)
        #expect(s[5].transcriptPath?.hasSuffix(".jsonl") == true)
    }

    @Test func permissionRequestIsNeedsInputPermissionUntilTheTurnEnds() throws {
        let raws = try RealHooks.events(RealHooks.claudePermission)
        #expect(raws.map(\.name) == ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "Stop", "SessionEnd"])
        let s = states(RealHooks.activityEvents(raws))
        #expect(s[2].activity == .working)
        #expect(s[3].activity == .needsInput(.permission))
        #expect(s[3].statusReason == "Wants to edit: `x.txt`")
        #expect(s[4].activity == .done)
        #expect(s[4].statusReason == nil)
        #expect(s[4].lastMessage?.hasPrefix("I couldn't create") == true)
    }

    @Test func approvedPermissionReturnsToWorkingOnPostToolUse() throws {
        var raws = try RealHooks.events(RealHooks.claudePermission)
        let post = RealHooks.Raw(name: "PostToolUse", object: raws[3].object.merging(["hook_event_name": "PostToolUse"]) { _, new in new })
        raws.insert(post, at: 4)
        let s = states(RealHooks.activityEvents(raws))
        #expect(s[3].activity == .needsInput(.permission))
        #expect(s[4].activity == .working)
    }

    @Test func nativeSubagentsRealSequenceEndsDoneWithChildrenTracked() throws {
        let raws = try RealHooks.events(RealHooks.claudeSubagents)
        let s = states(RealHooks.activityEvents(raws))
        let names = raws.map(\.name)
        let a = "a9d32b813be6acccc", b = "a69e07ec721dc760d"
        // Depois dos dois SubagentStart há dois filhos vivos e o pai continua `working`.
        let afterStarts = try #require(names.lastIndex(of: "SubagentStart"))
        #expect(s[afterStarts].liveChildCount == 2)
        #expect(s[afterStarts].activity == .working)
        // Ferramentas MCP do filho não mudam o estado do pai e vão para o subtítulo do filho.
        let childTool = try #require(raws.firstIndex { $0.object["agent_id"] as? String == a && $0.name == "PreToolUse" })
        #expect(s[childTool].activity == .working)
        #expect(s[childTool].children[a]?.subtitle == "Using mcp__whoami-a__whoami")
        #expect(s[childTool].children[a]?.agentType == "child-a")
        // O primeiro SubagentStop deixa um filho vivo.
        let firstStop = try #require(names.firstIndex(of: "SubagentStop"))
        #expect(s[firstStop].liveChildCount == 1)
        // `Stop` do pai chega com 0 filhos vivos -> done, com a última mensagem do pai.
        let stop = try #require(names.lastIndex(of: "Stop"))
        #expect(s[stop].activity == .done)
        #expect(s[stop].lastMessage == "I_AM_A I_AM_B")
        #expect(s[stop].children[a]?.lastMessage == "I_AM_A")
        #expect(s[stop].children[b]?.lastMessage == "I_AM_B")
        #expect(s[stop].children.values.allSatisfy { $0.phase == .done })
    }

    @Test func parentStopWithLiveChildrenWaitsUntilTheLastSubagentStop() throws {
        // Mesmos payloads reais, com o `Stop` do pai movido para antes dos `SubagentStop` (subagentes em background).
        var raws = try RealHooks.events(RealHooks.claudeSubagents)
        let stopIndex = try #require(raws.lastIndex { $0.name == "Stop" })
        let stop = raws.remove(at: stopIndex)
        let firstSubagentStop = try #require(raws.firstIndex { $0.name == "SubagentStop" })
        raws.insert(stop, at: firstSubagentStop)
        let s = states(RealHooks.activityEvents(raws))
        let stopAt = try #require(raws.firstIndex { $0.name == "Stop" })
        #expect(s[stopAt].activity == .waitingOnSubagents)
        #expect(s[stopAt].liveChildCount == 2)
        let stops = raws.indices.filter { raws[$0].name == "SubagentStop" }
        #expect(stops.count == 2)
        #expect(s[stops[0]].activity == .waitingOnSubagents)
        #expect(s[stops[0]].liveChildCount == 1)
        #expect(s[stops[1]].activity == .done)
        #expect(s[stops[1]].liveChildCount == 0)
        #expect(s[stops[1]].lastMessage == "I_AM_A I_AM_B")
    }

    @Test func outOfOrderArrivalProducesTheSameStateWhenSortedByOccurrence() throws {
        let ordered = RealHooks.activityEvents(try RealHooks.events(RealHooks.claudeSubagents))
        let expected = ActivityReducer.fold(ordered)
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<20 {
            let shuffled = ordered.shuffled(using: &rng)
            #expect(ActivityReducer.foldSorted(shuffled) == expected)
        }
        // Sem reordenar, a chegada invertida dá outro estado: a ordenação é o que importa.
        #expect(ActivityReducer.fold(Array(ordered.reversed())) != expected)
    }

    @Test func foldIsDeterministic() throws {
        let events = RealHooks.activityEvents(try RealHooks.events(RealHooks.claudeSubagents))
        #expect(ActivityReducer.fold(events) == ActivityReducer.fold(events))
    }

    @Test func codexRealSessionStartAndPromptGiveIdleThenWorkingWithRolloutPath() throws {
        let raws = try RealHooks.events(RealHooks.codex)
        #expect(raws.map(\.name) == ["SessionStart", "UserPromptSubmit"])
        let s = states(RealHooks.activityEvents(raws))
        #expect(s.map(\.activity) == [.idle, .working])
        #expect(s[1].transcriptPath?.contains("/.codex/sessions/") == true)
        #expect(s[1].nativeSessionID == raws[0].object["session_id"] as? String)
        #expect(raws[1].payload.turnID != nil)
        #expect(raws[0].payload.model != nil)
    }
}

@Suite struct ReducerSyntheticTests {
    private func working() -> ActivityState {
        ActivityReducer.fold([ev("SessionStart", atNs: at(0)), ev("UserPromptSubmit", atNs: at(1))])
    }

    @Test func notificationTypesMapPerSpec() {
        let permission = ActivityReducer.reduce(working(), ev("Notification", atNs: at(2), .init(notificationType: "permission_prompt", message: "Claude needs your permission")))
        #expect(permission.activity == .needsInput(.permission))

        let other = ActivityReducer.reduce(working(), ev("Notification", atNs: at(2), .init(notificationType: "elicitation_dialog", message: "Pick one")))
        #expect(other.activity == .needsInput(.other))
        #expect(other.statusReason == "Pick one")

        let done = ActivityReducer.reduce(working(), ev("Stop", atNs: at(2), .init(lastAssistantMessage: "ok")))
        #expect(ActivityReducer.reduce(done, ev("Notification", atNs: at(3), .init(notificationType: "idle_prompt"))).activity == .done)
        // Com turno ativo, o idle_prompt é o agente esperando o usuário.
        #expect(ActivityReducer.reduce(working(), ev("Notification", atNs: at(2), .init(notificationType: "idle_prompt"))).activity == .needsInput(.other))
        // PostToolUse limpa o pedido.
        #expect(ActivityReducer.reduce(permission, ev("PostToolUse", atNs: at(3))).activity == .working)
    }

    @Test func askUserQuestionIsNeedsInputQuestionUntilTheToolReturns() {
        let asked = ActivityReducer.reduce(working(), ev("PreToolUse", atNs: at(2), .init(toolName: "AskUserQuestion")))
        #expect(asked.activity == .needsInput(.question))
        #expect(ActivityReducer.reduce(asked, ev("PostToolUse", atNs: at(3), .init(toolName: "AskUserQuestion"))).activity == .working)
        #expect(ActivityReducer.reduce(asked, ev("UserPromptSubmit", atNs: at(3))).activity == .working)
    }

    @Test func permissionOutranksQuestionOutranksOther() {
        var s = working()
        s = ActivityReducer.reduce(s, ev("Notification", atNs: at(2), .init(notificationType: "x")))
        #expect(s.activity == .needsInput(.other))
        s.pending["child"] = PendingInput(kind: .question, summary: nil)
        #expect(s.activity == .needsInput(.question))
        s.pending["other-child"] = PendingInput(kind: .permission, summary: nil)
        #expect(s.activity == .needsInput(.permission))
    }

    @Test func stopFailureIsFailedWithReasonAndANewPromptRecovers() {
        let failed = ActivityReducer.reduce(working(), ev("StopFailure", atNs: at(2), .init(error: "Usage limit reached")))
        #expect(failed.activity == .failed)
        #expect(failed.statusReason == "Usage limit reached")
        #expect(ActivityReducer.reduce(working(), ev("StopFailure", atNs: at(2))).statusReason == "Turn failed")
        let recovered = ActivityReducer.reduce(failed, ev("UserPromptSubmit", atNs: at(3)))
        #expect(recovered.activity == .working)
        #expect(recovered.statusReason == nil)
    }

    @Test func daemonExitCodesAndInterruption() {
        let failed = ActivityReducer.reduce(working(), ev(ActivitySyntheticEvent.processExit, atNs: at(5), .init(reason: "1")))
        #expect(failed.activity == .failed)
        #expect(failed.statusReason == "exited with 1")
        #expect(failed.endedAtNs == at(5))

        let done = ActivityReducer.fold([ev("UserPromptSubmit", atNs: at(1)), ev("Stop", atNs: at(2), .init(lastAssistantMessage: "ok"))])
        #expect(ActivityReducer.reduce(done, ev(ActivitySyntheticEvent.processExit, atNs: at(5), .init(reason: "0"))).activity == .done)
        // Saiu sem nenhum evento: sem hooks, `unknown`, não `done`.
        let silent = ActivityReducer.reduce(ActivityState(), ev(ActivitySyntheticEvent.processExit, atNs: at(5), .init(reason: "0")))
        #expect(silent.activity == .unknown)

        let lost = ActivityReducer.reduce(working(), ev(ActivitySyntheticEvent.ptyLost, atNs: at(5)))
        #expect(lost.activity == .interrupted)
        // Eventos atrasados de um processo morto não o ressuscitam; um `done` já visto continua `done`.
        #expect(ActivityReducer.reduce(lost, ev("PostToolUse", atNs: at(6))).activity == .interrupted)
        #expect(ActivityReducer.reduce(done, ev(ActivitySyntheticEvent.ptyLost, atNs: at(5))).activity == .done)
    }

    @Test func unknownEventsAreIgnoredButCounted() {
        let s = ActivityReducer.reduce(working(), ev("SomethingNewInTheFuture", atNs: at(9)))
        #expect(s.activity == .working)
        #expect(s.lastEventAtNs == at(9))
    }

    @Test func childPermissionBlocksTheParentUntilTheChildToolReturns() {
        var s = ActivityReducer.fold([
            ev("SessionStart", atNs: at(0)), ev("UserPromptSubmit", atNs: at(1)),
            ev("SubagentStart", atNs: at(2), .init(agentID: "c1", agentType: "worker")),
            ev("PermissionRequest", atNs: at(3), .init(toolName: "Bash", toolTarget: "rm -rf build", agentID: "c1", agentType: "worker")),
        ])
        #expect(s.activity == .needsInput(.permission))
        #expect(s.statusReason == "Wants to run: `rm -rf build`")
        s = ActivityReducer.reduce(s, ev("PostToolUse", atNs: at(4), .init(toolName: "Bash", agentID: "c1")))
        #expect(s.activity == .working)
    }

    @Test func childWithoutSubagentStartDoesNotKeepTheParentWaiting() {
        let s = ActivityReducer.fold([
            ev("UserPromptSubmit", atNs: at(1)),
            ev("PreToolUse", atNs: at(2), .init(toolName: "Bash", agentID: "ghost")),
            ev("Stop", atNs: at(3), .init(lastAssistantMessage: "x")),
        ])
        #expect(s.children["ghost"]?.implicit == true)
        #expect(s.activity == .done)
    }

    @Test func subagentStartAfterParentStopMovesDoneToWaiting() {
        let s = ActivityReducer.fold([
            ev("UserPromptSubmit", atNs: at(1)), ev("Stop", atNs: at(2)),
            ev("SubagentStart", atNs: at(3), .init(agentID: "late")),
        ])
        #expect(s.activity == .waitingOnSubagents)
        #expect(ActivityReducer.reduce(s, ev("SubagentStop", atNs: at(4), .init(agentID: "late"))).activity == .done)
    }

    @Test func sessionStartDoesNotRewindARunningTurn() {
        let s = ActivityReducer.reduce(working(), ev("SessionStart", atNs: at(2), .init(source: "compact")))
        #expect(s.activity == .working)
    }

    @Test func toolSubtitlesAndPermissionSummaries() {
        #expect(ActivityReducer.toolSubtitle("Edit", "x.swift") == "Editing x.swift")
        #expect(ActivityReducer.toolSubtitle("Read", nil) == "Reading a file")
        #expect(ActivityReducer.toolSubtitle("mcp__box__exec", nil) == "Using mcp__box__exec")
        #expect(ActivityReducer.permissionSummary("Bash", "git push origin main") == "Wants to run: `git push origin main`")
        #expect(ActivityReducer.permissionSummary("WebFetch", "https://x.dev") == "Wants to use WebFetch: `https://x.dev`")
        #expect(ActivityReducer.toolSubtitle(nil, nil) == nil)
    }
}

@Suite struct ActivityProjectionTests {
    @Test func childRunIDIsDeterministicAndPerChild() {
        let parent = UUID()
        #expect(ActivityProjector.childRunID(parent: parent, agentID: "a") == ActivityProjector.childRunID(parent: parent, agentID: "a"))
        #expect(ActivityProjector.childRunID(parent: parent, agentID: "a") != ActivityProjector.childRunID(parent: parent, agentID: "b"))
        #expect(ActivityProjector.childRunID(parent: parent, agentID: "a") != ActivityProjector.childRunID(parent: UUID(), agentID: "a"))
    }

    @Test func projectionOfRealSubagentSequenceHasMainAndTwoChildren() throws {
        let state = ActivityReducer.fold(RealHooks.activityEvents(try RealHooks.events(RealHooks.claudeSubagents)))
        let run = UUID(), terminal = UUID()
        let p = ActivityProjector.projection(runID: run, terminalID: terminal, provider: .claude, state: state)
        #expect(p.runs.count == 3)
        #expect(p.runs[0].kind == .main && p.runs[0].activity == .done && p.runs[0].terminalID == terminal)
        let children = p.runs.dropFirst()
        #expect(children.allSatisfy { $0.kind == .nativeSubagent && $0.parentRunID == run && $0.rootRunID == run && $0.activity == .done })
        #expect(Set(children.compactMap(\.agentType)) == ["child-a", "child-b"])
        #expect(p.terminalUpdate?.lastMessage == "I_AM_A I_AM_B")
        #expect(p.terminalUpdate?.nativeConversationID == state.nativeSessionID)
    }
}

@Suite struct ActivityAggregationTests {
    private func run(_ a: AgentActivity) -> AgentRun { AgentRun(harness: .claude, activity: a) }

    @Test func worstStateWinsInTheDocumentedOrder() {
        let order: [AgentActivity] = [
            .needsInput(.permission), .failed, .working, .waitingOnSubagents, .interrupted, .starting, .done, .idle, .unknown,
        ]
        for i in order.indices {
            let rest = order[i...].map(run)
            #expect(SessionActivity.aggregate(rest.shuffled()) == order[i], "\(order[i])")
        }
        #expect(SessionActivity.aggregate([]) == nil)
    }

    @Test func unreadDoneOutranksInterruptedButReadDoneDoesNot() {
        let done = run(.done), interrupted = run(.interrupted)
        #expect(SessionActivity.aggregate([done, interrupted], unseenDone: [done.id]) == .done)
        #expect(SessionActivity.aggregate([done, interrupted]) == .interrupted)
        #expect(SessionActivity.aggregate([run(.blocked), run(.working)]) == .blocked)
    }

    @Test func seenDoneBecomesIdleAfterThirtyMinutes() {
        let now = Date()
        var r = run(.done)
        r.lastEventAt = now.addingTimeInterval(-31 * 60)
        #expect(ActivityTimeouts.applyingIdleTimeout(r, seen: true, now: now).activity == .idle)
        #expect(ActivityTimeouts.applyingIdleTimeout(r, seen: false, now: now).activity == .done)
        r.lastEventAt = now.addingTimeInterval(-29 * 60)
        #expect(ActivityTimeouts.applyingIdleTimeout(r, seen: true, now: now).activity == .done)
    }
}

/// Subagente parado pelo pai com `TaskStop`: o Claude Code não manda `SubagentStop`, e o pai não pode ficar "Waiting" para sempre.
@Suite struct ReducerTaskStopTests {
    private func spawn(_ ids: [String]) -> [ActivityEvent] {
        var events = [ev("UserPromptSubmit", atNs: at(0))]
        for (i, id) in ids.enumerated() {
            events.append(ev("SubagentStart", atNs: at(Int64(i + 1)), ReducedHookPayload(agentID: id, agentType: "racky-worker-1")))
        }
        events.append(ev("Stop", atNs: at(10)))
        return events
    }

    @Test func taskStopWithTheTaskIDEndsThatChildAndReleasesTheParent() {
        var events = spawn(["a1", "a2"])
        events.append(ev("PostToolUse", atNs: at(20), ReducedHookPayload(toolName: "TaskStop", toolTarget: "a1")))
        let s = ActivityReducer.fold(events)
        #expect(s.children["a1"]?.phase == .done && s.children["a2"]?.phase != .done && s.liveChildCount == 1)
        #expect(s.activity == .waitingOnSubagents)
        let done = ActivityReducer.reduce(s, ev("SubagentStop", atNs: at(30), ReducedHookPayload(agentID: "a2")))
        #expect(done.liveChildCount == 0 && done.activity == .done)
    }

    @Test func taskStopWithoutAnIDEndsTheOnlyLiveChildOnly() {
        var one = spawn(["a1"])
        one.append(ev("PostToolUse", atNs: at(20), ReducedHookPayload(toolName: "TaskStop")))
        let s = ActivityReducer.fold(one)
        #expect(s.children["a1"]?.phase == .done && s.activity == .done, "older events have no task id: the single live child was the one")
        var two = spawn(["a1", "a2"])
        two.append(ev("PostToolUse", atNs: at(20), ReducedHookPayload(toolName: "TaskStop")))
        #expect(ActivityReducer.fold(two).liveChildCount == 2, "ambiguous: nothing ends")
        var unknown = spawn(["a1"])
        unknown.append(ev("PostToolUse", atNs: at(20), ReducedHookPayload(toolName: "TaskStop", toolTarget: "bash-7")))
        #expect(ActivityReducer.fold(unknown).liveChildCount == 1, "stopping a shell task leaves the subagent alone")
    }

    @Test func theHookReducerKeepsTheTaskID() {
        let p = HookPayloadReducer.reduce(["hook_event_name": "PostToolUse", "tool_name": "TaskStop", "tool_input": ["task_id": "a370b3cd79c8336e7"]])
        #expect(p.toolTarget == "a370b3cd79c8336e7")
    }
}
