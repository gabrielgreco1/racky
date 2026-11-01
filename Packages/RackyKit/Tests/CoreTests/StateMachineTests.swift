import RackyProtocol
import Foundation
import Testing
@testable import RackyCore

// Todas as combinações estado x evento: a tabela de válidas é explícita; todo o resto tem de ser inválido.

@Suite struct SessionLifecycleMachineTests {
    typealias M = SessionLifecycleMachine
    static let valid: [SessionLifecycle: [SessionEvent: SessionLifecycle]] = [
        .creating: [.createSucceeded: .active, .createFailed: .failedToCreate],
        .failedToCreate: [.retryCreate: .creating, .discard: .deleted],
        .active: [.archive: .archived, .folderMissing: .missing],
        .archived: [.restore: .active, .delete: .deleted],
        .missing: [.folderLocated: .active, .delete: .deleted],
        .deleted: [:],
    ]

    @Test func everyStateEventPair() {
        var validCount = 0, invalidCount = 0
        for state in SessionLifecycle.allCases {
            for event in SessionEvent.allCases {
                let expected = Self.valid[state]?[event]
                #expect(M.next(state, event) == expected, "\(state) + \(event)")
                if let expected {
                    validCount += 1
                    #expect(throws: Never.self) { try M.reduce(state, event) }
                    #expect((try? M.reduce(state, event)) == expected)
                } else {
                    invalidCount += 1
                    #expect(throws: InvalidTransition<SessionLifecycle, SessionEvent>(state: state, event: event)) {
                        try M.reduce(state, event)
                    }
                }
            }
        }
        #expect(validCount == 10)
        #expect(invalidCount == SessionLifecycle.allCases.count * SessionEvent.allCases.count - 10)
    }

    @Test func deletedIsTerminal() {
        for e in SessionEvent.allCases { #expect(M.next(.deleted, e) == nil) }
    }

    @Test func confirmationOnlyWhenProcessesRunning() {
        #expect(M.confirmationRequired(.archive, runningTerminals: 2))
        #expect(M.confirmationRequired(.delete, runningTerminals: 1))
        #expect(!M.confirmationRequired(.archive, runningTerminals: 0))
        #expect(!M.confirmationRequired(.restore, runningTerminals: 3))
    }

    @Test func onlyActiveAndArchivedArePersistable() {
        for s in SessionLifecycle.allCases { #expect(s.isPersistable == (s == .active || s == .archived)) }
    }
}

@Suite struct TerminalProcessMachineTests {
    typealias M = TerminalProcessMachine
    static let events: [TerminalProcessEvent] = [
        .launch, .firstByte, .spawnFailed, .exited(code: 0), .exited(code: 2), .killedByUser, .signaled(9), .ptyLost, .containerStopped,
    ]

    static func expected(_ s: TerminalProcessState, _ e: TerminalProcessEvent) -> TerminalProcessState? {
        switch (s, e) {
        case (.notStarted, .launch), (.exited, .launch), (.killed, .launch), (.failedToStart, .launch),
             (.interrupted, .launch), (.containerStopped, .launch): .launching
        case (.launching, .firstByte): .running
        case (.launching, .spawnFailed): .failedToStart
        case (.launching, .exited), (.running, .exited): .exited
        case (.launching, .killedByUser), (.running, .killedByUser), (.launching, .signaled), (.running, .signaled): .killed
        case (.launching, .ptyLost), (.running, .ptyLost): .interrupted
        case (.running, .containerStopped): .containerStopped
        default: nil
        }
    }

    @Test func everyStateEventPair() {
        var valid = 0
        for s in TerminalProcessState.allCases {
            for e in Self.events {
                let exp = Self.expected(s, e)
                #expect(M.next(s, e) == exp, "\(s) + \(e)")
                if let exp {
                    valid += 1
                    #expect((try? M.reduce(s, e)) == exp)
                } else {
                    #expect(throws: InvalidTransition<TerminalProcessState, TerminalProcessEvent>(state: s, event: e)) { try M.reduce(s, e) }
                }
            }
        }
        #expect(valid == 19)  // launch 6, firstByte 1, spawnFailed 1, exited 4, killedByUser 2, signaled 2, ptyLost 2, containerStopped 1
    }

    @Test func spawnFailureAndRestartCycle() throws {
        var s = TerminalProcessState.notStarted
        s = try M.reduce(s, .launch); #expect(s == .launching)
        s = try M.reduce(s, .spawnFailed); #expect(s == .failedToStart)
        s = try M.reduce(s, .launch); #expect(s == .launching)
        s = try M.reduce(s, .firstByte); #expect(s == .running)
        s = try M.reduce(s, .ptyLost); #expect(s == .interrupted)
        s = try M.reduce(s, .launch); #expect(s == .launching)
    }

    @Test func runningCannotBeRelaunchedWithoutStopping() {
        #expect(!M.isRestartable(.running))
        #expect(!M.isRestartable(.launching))
        for s in [TerminalProcessState.exited, .killed, .failedToStart, .interrupted, .notStarted, .containerStopped] {
            #expect(M.isRestartable(s))
        }
    }

    @Test func applyKeepsExitFieldsCoherent() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var t = Terminal(tabID: .v7(), provider: .claude, title: "Claude", cwd: "/tmp", launchSpec: LaunchSpec(provider: .claude))
        t = try M.apply(.launch, to: t, at: now)
        #expect(t.state == .launching && t.startedAt == now && t.exitCode == nil)
        t = try M.apply(.firstByte, to: t, at: now)
        t = try M.apply(.exited(code: 3), to: t, at: now.addingTimeInterval(5))
        #expect(t.state == .exited && t.exitCode == 3 && t.endedAt == now.addingTimeInterval(5))
        t = try M.apply(.launch, to: t, at: now.addingTimeInterval(9))
        #expect(t.exitCode == nil && t.endedAt == nil && t.startedAt == now.addingTimeInterval(9))
        t = try M.apply(.firstByte, to: t, at: now)
        t = try M.apply(.signaled(15), to: t, at: now.addingTimeInterval(20))
        #expect(t.state == .killed && t.exitSignal == 15)
        #expect(throws: InvalidTransition<TerminalProcessState, TerminalProcessEvent>.self) {
            try M.apply(.firstByte, to: t, at: now)
        }
    }

    @Test func labels() {
        #expect(M.label(state: .exited, exitCode: 0, exitSignal: nil) == "Exited")
        #expect(M.label(state: .exited, exitCode: 2, exitSignal: nil) == "Exited with code 2")
        #expect(M.label(state: .killed, exitCode: nil, exitSignal: nil) == "Stopped")
        #expect(M.label(state: .killed, exitCode: nil, exitSignal: 9) == "Killed (SIGKILL)")
        #expect(M.label(state: .failedToStart, exitCode: nil, exitSignal: nil) == "Couldn't start")
        #expect(M.label(state: .interrupted, exitCode: nil, exitSignal: nil) == "Interrupted")
        #expect(M.label(state: .running, exitCode: nil, exitSignal: nil) == nil)
    }
}

@Suite struct AgentActivityMachineTests {
    typealias M = AgentActivityMachine
    static let states: [AgentActivity] = [
        .starting, .idle, .working, .needsInput(.question), .waitingOnSubagents, .done, .failed, .blocked, .interrupted, .unknown,
    ]
    static let events: [AgentActivityEvent] = [
        .launched, .sessionStarted, .promptSubmitted, .needsInput(.permission), .turnEnded(activeChildren: false),
        .turnEnded(activeChildren: true), .childrenFinished, .failure, .blocked, .unblocked, .interrupted, .idleTimeout, .hooksUnavailable,
    ]

    @Test func launchAlwaysRestartsToStarting() {
        for s in Self.states { #expect(M.next(s, .launched) == .starting) }
    }

    @Test func validTransitionsFromTable() {
        #expect(M.next(.starting, .sessionStarted) == .idle)
        #expect(M.next(.idle, .promptSubmitted) == .working)
        #expect(M.next(.working, .needsInput(.permission)) == .needsInput(.permission))
        #expect(M.next(.needsInput(.question), .promptSubmitted) == .working)
        #expect(M.next(.working, .turnEnded(activeChildren: false)) == .done)
        #expect(M.next(.working, .turnEnded(activeChildren: true)) == .waitingOnSubagents)
        #expect(M.next(.waitingOnSubagents, .childrenFinished) == .done)
        #expect(M.next(.done, .promptSubmitted) == .working)
        #expect(M.next(.done, .idleTimeout) == .idle)
        #expect(M.next(.working, .failure) == .failed)
        #expect(M.next(.failed, .promptSubmitted) == .working)
        #expect(M.next(.working, .blocked) == .blocked)
        #expect(M.next(.blocked, .unblocked) == .working)
        #expect(M.next(.working, .interrupted) == .interrupted)
        #expect(M.next(.working, .hooksUnavailable) == .unknown)
        #expect(M.next(.unknown, .promptSubmitted) == .working)
    }

    @Test func invalidTransitionsAreRejected() {
        #expect(M.next(.idle, .turnEnded(activeChildren: false)) == nil)
        #expect(M.next(.done, .needsInput(.question)) == nil)
        #expect(M.next(.working, .childrenFinished) == nil)
        #expect(M.next(.done, .unblocked) == nil)
        #expect(M.next(.interrupted, .promptSubmitted) == nil)
        #expect(M.next(.interrupted, .interrupted) == nil)
        #expect(M.next(.unknown, .failure) == nil)
        #expect(M.next(.done, .idleTimeout) != nil)
        #expect(M.next(.idle, .idleTimeout) == nil)
        #expect(throws: InvalidTransition<AgentActivity, AgentActivityEvent>.self) { try M.reduce(.done, .failure) }
    }

    @Test func tableCountIsStable() {
        // Guarda contra mudança silenciosa da tabela: conta pares válidos entre os estados e eventos acima.
        var valid = 0
        for s in Self.states { for e in Self.events where M.next(s, e) != nil { valid += 1 } }
        #expect(valid == 40)  // launched 10, sessionStarted 1, prompt 7, needsInput 1, turnEnded 2, childrenFinished 1, failure 4, blocked 1, unblocked 1, interrupted 6, idleTimeout 1, hooksUnavailable 5
    }

    @Test func slice1DerivationHasNoHooks() {
        #expect(M.derivedActivity(provider: .shell, process: .running, exitCode: nil) == nil)
        #expect(M.derivedActivity(provider: .custom, process: .running, exitCode: nil) == nil)
        #expect(M.derivedActivity(provider: .claude, process: .running, exitCode: nil) == .unknown)
        #expect(M.derivedActivity(provider: .codex, process: .launching, exitCode: nil) == .starting)
        #expect(M.derivedActivity(provider: .claude, process: .exited, exitCode: 1) == .failed)
        #expect(M.derivedActivity(provider: .claude, process: .exited, exitCode: 0) == .unknown)
        #expect(M.derivedActivity(provider: .claude, process: .failedToStart, exitCode: nil) == .failed)
        #expect(M.derivedActivity(provider: .claude, process: .interrupted, exitCode: nil) == .interrupted)
    }

    @Test func aggregationWorstWins() {
        typealias S = AgentActivityMachine.Sample
        #expect(M.aggregate([]) == nil)
        #expect(M.aggregate([S(.unknown), S(.idle), S(.working)]) == .working)
        #expect(M.aggregate([S(.working), S(.needsInput(.permission)), S(.failed)]) == .needsInput(.permission))
        #expect(M.aggregate([S(.blocked), S(.failed)]) == .failed)
        #expect(M.aggregate([S(.working), S(.failed)]) == .failed)
        #expect(M.aggregate([S(.waitingOnSubagents), S(.working)]) == .working)
        #expect(M.aggregate([S(.done, unseen: true), S(.interrupted)]) == .done)
        #expect(M.aggregate([S(.done, unseen: false), S(.interrupted)]) == .interrupted)
        #expect(M.aggregate([S(.starting), S(.interrupted)]) == .interrupted)
        #expect(M.aggregate([S(.done, unseen: false), S(.starting)]) == .starting)
        #expect(M.aggregate([S(.idle), S(.done, unseen: false)]) == .done)
        #expect(M.aggregate([S(.unknown), S(.idle)]) == .idle)
    }
}
