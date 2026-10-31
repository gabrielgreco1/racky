import RackyProtocol
import Foundation
import GRDB
import Testing
@testable import RackyStore

private func seedTerminal(_ store: RackyStore, currentRunID: UUID? = nil) async throws -> Terminal {
    let session = Fixture.cleanSession()
    let tabID = UUID.v7()
    let terminal = Terminal(
        tabID: tabID, provider: .claude, title: "Claude", cwd: "/x", launchSpec: LaunchSpec(provider: .claude),
        currentRunID: currentRunID, state: .running, createdAt: Fixture.t0)
    let tab = Tab(id: tabID, sessionID: session.id, title: "Agent", layout: .leaf(Pane(content: .terminal(terminal.id))), createdAt: Fixture.t0)
    if try await store.hasSubagentColumn() {
        try await store.saveBundle(session: session, tabs: [tab], terminals: [terminal])
    } else {
        try await store.savePreV7(session)
        try await store.save(tab)
        try await store.save(terminal)
    }
    return terminal
}

private func event(_ run: UUID, _ id: String, type: String = "Stop", atNs: Int64 = 1_800_000_000_000_000_000, payload: String = "{}") -> NewAgentEvent {
    NewAgentEvent(runID: run, eventID: id, type: type, payloadJSON: payload, atNs: atNs)
}

@Suite struct V2ActivityMigrationTests {
    @Test func sliceOneDatabaseUpgradesWithDataIntactAndAPreMigrationBackup() async throws {
        let home = try TempHome(); defer { home.remove() }
        let v1 = try await home.openStore(day: 0, migrations: [StoreMigrations.v1Initial])
        let project = Fixture.project()
        try await v1.save(project)
        let terminal = try await seedTerminal(v1)
        try await v1.close()

        let v2 = try await home.openStore(day: 1, migrations: [StoreMigrations.v1Initial, StoreMigrations.v2Activity])
        #expect(v2.openNotices.isEmpty)
        #expect(await v2.mode == .readWrite)
        #expect(try await v2.project(id: project.id)?.name == project.name)
        #expect(try await v2.terminal(id: terminal.id)?.title == "Claude")
        #expect(home.backups.contains { $0.hasPrefix("pre-migration-v2_activity-") })
        // As tabelas novas existem e aceitam gravação.
        let run = AgentRun(terminalID: terminal.id, harness: .claude, activity: .working, startedAt: Fixture.t0)
        #expect(try await v2.recordAgentEvent(event(run.id, "e1"), ensuringRun: run))
        try await v2.close()
    }

    @Test func v2ActivityIsRegisteredAfterV1AndTablesAreStrict() async throws {
        #expect(StoreMigrations.all.map(\.id) == ["v1_initial", "v2_activity", "v3_computers", "v4_vault_catalog", "v5_proxy_ext", "v6_agent_tree", "v7_subagent_computers", "v8_orchestration_identity", "v9_orchestration_pool", "v10_datasets", "v11_subagent_harness"])
        let home = try TempHome(); defer { home.remove() }
        let store = try await home.openStore()
        await #expect(throws: DatabaseError.self) {
            try await store.writer.write { db in
                try db.execute(sql: "INSERT INTO agent_run(id, root_run_id, kind, harness, status, started_at) VALUES (?, ?, 'main', 'claude', 'bogus', 0)",
                               arguments: [UUID().uuidString, UUID().uuidString])
            }
        }
        await #expect(throws: DatabaseError.self) {
            try await store.writer.write { db in
                try db.execute(sql: "INSERT INTO agent_run(id, root_run_id, kind, harness, status, status_kind, started_at) VALUES (?, ?, 'main', 'claude', 'working', 'nope', 0)",
                               arguments: [UUID().uuidString, UUID().uuidString])
            }
        }
        try await store.close()
    }
}

@Suite struct AgentEventStoreTests {
    @Test func eventsAreIdempotentPerRunAndSequenceIsMonotonic() async throws {
        let home = try TempHome(); defer { home.remove() }
        let store = try await home.openStore()
        let a = AgentRun(harness: .claude, startedAt: Fixture.t0), b = AgentRun(harness: .codex, startedAt: Fixture.t0)
        #expect(try await store.recordAgentEvent(event(a.id, "e1"), ensuringRun: a))
        #expect(try await store.recordAgentEvent(event(a.id, "e2", atNs: 1_800_000_000_000_000_001), ensuringRun: a))
        #expect(try await !store.recordAgentEvent(event(a.id, "e1"), ensuringRun: a), "mesmo id na mesma execução é duplicado")
        #expect(try await store.recordAgentEvent(event(b.id, "e1"), ensuringRun: b), "o id só é único dentro da execução")
        let events = try await store.agentEvents(runID: a.id)
        #expect(events.map(\.seq) == [1, 2] && events.map(\.eventID) == ["e1", "e2"])
        #expect(try await store.agentEventCount(runID: a.id) == 2)
        try await store.close()
    }

    @Test func eventsComeBackInOccurrenceOrderNotArrivalOrder() async throws {
        let home = try TempHome(); defer { home.remove() }
        let store = try await home.openStore()
        let run = AgentRun(harness: .claude, startedAt: Fixture.t0)
        let base: Int64 = 1_800_000_000_000_000_000
        for (id, ns) in [("late", base + 30), ("early", base + 10), ("mid", base + 20), ("tie-first", base + 40), ("tie-second", base + 40)] {
            _ = try await store.recordAgentEvent(event(run.id, id, atNs: ns), ensuringRun: run)
        }
        #expect(try await store.agentEvents(runID: run.id).map(\.eventID) == ["early", "mid", "late", "tie-first", "tie-second"])
        try await store.close()
    }

    @Test func oversizedOrInvalidPayloadIsRefused() async throws {
        let home = try TempHome(); defer { home.remove() }
        let store = try await home.openStore()
        let run = AgentRun(harness: .claude, startedAt: Fixture.t0)
        let big = "{\"x\":\"" + String(repeating: "a", count: 16_400) + "\"}"
        await #expect(throws: StoreError.self) { try await store.recordAgentEvent(event(run.id, "big", payload: big), ensuringRun: run) }
        await #expect(throws: DatabaseError.self) { try await store.recordAgentEvent(event(run.id, "bad", payload: "{nope"), ensuringRun: run) }
        try await store.close()
    }

    @Test func runOfAnUnknownTerminalIsStoredWithoutTerminal() async throws {
        let home = try TempHome(); defer { home.remove() }
        let store = try await home.openStore()
        let run = AgentRun(terminalID: UUID(), harness: .claude, startedAt: Fixture.t0)
        #expect(try await store.recordAgentEvent(event(run.id, "e"), ensuringRun: run))
        #expect(try await store.agentRun(id: run.id)?.terminalID == nil)
        try await store.close()
    }

    @Test func deletingTheTerminalKeepsRunsAndDeletingTheRunCascades() async throws {
        let home = try TempHome(); defer { home.remove() }
        let store = try await home.openStore()
        let terminal = try await seedTerminal(store)
        let main = AgentRun(terminalID: terminal.id, harness: .claude, startedAt: Fixture.t0)
        let child = AgentRun(terminalID: terminal.id, parentRunID: main.id, rootRunID: main.id, kind: .nativeSubagent, harness: .claude, startedAt: Fixture.t0)
        _ = try await store.recordAgentEvent(event(main.id, "e"), ensuringRun: main)
        try await store.saveActivity(ActivityProjection(runs: [main, child], guardRunID: main.id))
        #expect(try await store.childRuns(parentRunID: main.id).map(\.id) == [child.id])
        #expect(try await store.agentRuns(terminalID: terminal.id).map(\.id) == [main.id], "agentRuns lista só as principais")

        try await store.writer.write { db in try db.execute(sql: "DELETE FROM terminal WHERE id = ?", arguments: [terminal.id.uuidString]) }
        #expect(try await store.agentRun(id: main.id)?.terminalID == nil, "histórico de execuções sobrevive ao terminal")

        try await store.writer.write { db in try db.execute(sql: "DELETE FROM agent_run WHERE id = ?", arguments: [main.id.uuidString]) }
        #expect(try await store.agentRun(id: child.id) == nil)
        #expect(try await store.agentEventCount(runID: main.id) == 0)
        try await store.close()
    }

    @Test func saveActivityUpdatesTerminalOnlyForTheCurrentRun() async throws {
        let home = try TempHome(); defer { home.remove() }
        let store = try await home.openStore()
        let current = UUID(), stale = UUID()
        let terminal = try await seedTerminal(store, currentRunID: current)
        let staleRun = AgentRun(id: stale, terminalID: terminal.id, harness: .claude, startedAt: Fixture.t0)
        let currentRun = AgentRun(id: current, terminalID: terminal.id, harness: .claude, activity: .done, startedAt: Fixture.t0)
        try await store.saveActivity(ActivityProjection(
            runs: [staleRun], terminalUpdate: TerminalActivityUpdate(terminalID: terminal.id, lastMessage: "old", nativeConversationID: "old-id"), guardRunID: stale))
        #expect(try await store.terminal(id: terminal.id)?.lastMessage == nil)
        try await store.saveActivity(ActivityProjection(
            runs: [currentRun], terminalUpdate: TerminalActivityUpdate(terminalID: terminal.id, lastMessage: String(repeating: "é", count: 600), nativeConversationID: "new-id"), guardRunID: current))
        let t = try #require(try await store.terminal(id: terminal.id))
        #expect(t.lastMessage?.count == 500, "o banco guarda no máximo 500 caracteres")
        #expect(t.nativeConversationID == "new-id")
        try await store.close()
    }

    @Test func everyActivityRoundTripsThroughStatusColumns() async throws {
        let home = try TempHome(); defer { home.remove() }
        let store = try await home.openStore()
        let all: [AgentActivity] = [
            .starting, .idle, .working, .needsInput(.question), .needsInput(.permission), .needsInput(.other),
            .waitingOnSubagents, .done, .failed, .blocked, .interrupted, .unknown,
        ]
        for activity in all {
            var run = AgentRun(harness: .codex, activity: activity, estimated: true, statusReason: "why", subtitle: "Running Bash", startedAt: Fixture.t0, lastEventAt: Fixture.t0.addingTimeInterval(5))
            run.agentType = "t"; run.providerSessionID = "s"
            try await store.saveActivity(ActivityProjection(runs: [run], guardRunID: run.id))
            #expect(try await store.agentRun(id: run.id) == run, "\(activity)")
        }
        try await store.close()
    }

    @Test func retentionKeepsThirtyDaysAndTenThousandEventsPerRun() async throws {
        let home = try TempHome(); defer { home.remove() }
        let store = try await home.openStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let nowNs = Int64(now.timeIntervalSince1970 * 1e9)
        let day: Int64 = 86_400 * 1_000_000_000
        let run = AgentRun(harness: .claude, startedAt: now)
        _ = try await store.recordAgentEvent(event(run.id, "old-31d", atNs: nowNs - 31 * day), ensuringRun: run)
        _ = try await store.recordAgentEvent(event(run.id, "old-29d", atNs: nowNs - 29 * day), ensuringRun: run)
        for i in 0..<12 { _ = try await store.recordAgentEvent(event(run.id, "n\(i)", atNs: nowNs - Int64(12 - i) * 1_000_000), ensuringRun: run) }
        let removedByAge = try await store.pruneAgentEvents(now: now, maxPerRun: 100)
        #expect(removedByAge == 1)
        #expect(try await store.agentEventCount(runID: run.id) == 13)
        let removedByCount = try await store.pruneAgentEvents(now: now, maxPerRun: 5)
        #expect(removedByCount == 8)
        let kept = try await store.agentEvents(runID: run.id).map(\.eventID)
        #expect(kept == ["n7", "n8", "n9", "n10", "n11"], "ficam os 5 mais novos")
        #expect(HookLimits.retentionMaxEventsPerRun == 10_000 && HookLimits.retentionDays == 30)
        try await store.close()
    }

    @Test func staleProjectionIsDetectedForReconcile() async throws {
        let home = try TempHome(); defer { home.remove() }
        let store = try await home.openStore()
        var run = AgentRun(harness: .claude, startedAt: Fixture.t0)
        _ = try await store.recordAgentEvent(event(run.id, "e", atNs: 1_800_000_000_000_000_000), ensuringRun: run)
        #expect(try await store.runsNeedingReconcile() == [run.id])
        run.lastEventAt = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.saveActivity(ActivityProjection(runs: [run], guardRunID: run.id))
        #expect(try await store.runsNeedingReconcile().isEmpty)
        try await store.close()
    }
}
