import Foundation
import GRDB
import Testing
@testable import RackyStore

/// `v6_agent_tree` (T3-04): migração encadeada após `v5_proxy_ext`, restrições do schema e o espelho de computadores e fila.
@Suite struct AgentTreeMigrationTests {
    private func writer(_ home: TempHome) throws -> DatabaseQueue {
        try DatabaseQueue(path: home.paths.databaseFile.path)
    }

    @Test func migratesFromV5KeepingDataAndBackingUpFirst() async throws {
        let home = try TempHome(); defer { home.remove() }
        let chain = Array(StoreMigrations.all.prefix(5))
        #expect(chain.last?.id == "v5_proxy_ext")
        let before = try await home.openStore(day: 0, migrations: chain)
        try await before.save(Fixture.project())
        try await before.close()
        #expect(!(try tableNames(at: home.paths.databaseFile)).contains("orchestration_child"))

        let after = try await home.openStore(day: 1)
        #expect(after.openNotices.isEmpty)
        try await after.close()
        #expect(home.backups.filter { $0.hasPrefix("pre-migration-v6_agent_tree-") }.count == 1)
        #expect(try rowCount(at: home.paths.databaseFile, table: "project") == 1, "N-1 data preserved")
        for table in ["orchestration_child", "agent_message"] { #expect(try rowCount(at: home.paths.databaseFile, table: table) == 0) }
    }

    @Test func treeAndMessageRoundTripWithStateTimestamps() async throws {
        let home = try TempHome(); defer { home.remove() }
        let store = try await home.openStore()
        let parent = "0f0e0d0c-aaaa-4bbb-8ccc-000000000001"
        for slot in 1...3 {
            try await store.registerOrchestrationChild(OrchestrationChild(id: "\(parent.prefix(8))-w\(slot)", parentID: parent, slot: slot, agentType: "racky-worker-\(slot)"))
        }
        // Registrar de novo é idempotente (relançar o pai regenera os mesmos slots) e não zera o estado.
        let w1 = "\(parent.prefix(8))-w1"
        try await store.updateOrchestrationChild(id: w1, state: .reserved, computerName: .some("phoenix-az"), batchID: .some("listings-oct"))
        try await store.registerOrchestrationChild(OrchestrationChild(id: w1, parentID: parent, slot: 1, agentType: "racky-worker-1"))
        let again = try #require(try await store.orchestrationChild(id: w1))
        #expect(again.state == .reserved && again.computerName == "phoenix-az" && again.batchID == "listings-oct" && again.reservedAt != nil)
        try await store.updateOrchestrationChild(id: w1, state: .claimed)
        #expect(try await store.orchestrationChild(parentID: parent, computerName: "phoenix-az")?.claimedAt != nil)
        try await store.linkOrchestrationChild(id: w1, runID: UUID(), providerAgentID: "agent-abc")
        try await store.updateOrchestrationChild(id: w1, state: .ended)
        let ended = try #require(try await store.orchestrationChild(id: w1))
        #expect(ended.state == .ended && ended.endedAt != nil && ended.providerAgentID == "agent-abc" && ended.runID != nil)
        #expect(try await store.orchestrationChildren(parentID: parent).map(\.slot) == [1, 2, 3])
        #expect(OrchestrationChildState.reserved.isActive && OrchestrationChildState.claimed.isActive && !OrchestrationChildState.ended.isActive)
        try await store.updateOrchestrationChild(id: w1, state: .idle)
        let reset = try #require(try await store.orchestrationChild(id: w1))
        #expect(reset.computerName == nil && reset.runID == nil && reset.state == .idle, "a freed slot forgets its computer")
        try await store.close()
    }

    @Test func checkConstraintsAndForeignKeysHold() async throws {
        let home = try TempHome(); defer { home.remove() }
        let store = try await home.openStore()
        try await store.close()
        let db = try writer(home)
        await #expect(throws: DatabaseError.self) {
            try await db.write { try $0.execute(sql: "INSERT INTO orchestration_child (id, parent_id, slot, agent_type, state, created_at) VALUES ('c', 'p', 1, 't', 'bogus', 1)") }
        }
        await #expect(throws: DatabaseError.self) {
            try await db.write { try $0.execute(sql: "INSERT INTO orchestration_child (id, parent_id, slot, agent_type, created_at) VALUES ('c', 'p', 0, 't', 1)") }
        }
        try await db.write { try $0.execute(sql: "INSERT INTO orchestration_child (id, parent_id, slot, agent_type, created_at) VALUES ('c', 'p', 1, 't', 1)") }
        await #expect(throws: DatabaseError.self, "one slot per parent") {
            try await db.write { try $0.execute(sql: "INSERT INTO orchestration_child (id, parent_id, slot, agent_type, created_at) VALUES ('d', 'p', 1, 't', 1)") }
        }
        await #expect(throws: DatabaseError.self, "message needs an existing child") {
            try await db.write { try $0.execute(sql: "INSERT INTO agent_message (id, parent_id, child_id, text, delivery, created_at) VALUES ('m', 'p', 'nope', 'x', 'inbox', 1)") }
        }
        await #expect(throws: DatabaseError.self, "delivery is a closed set") {
            try await db.write { try $0.execute(sql: "INSERT INTO agent_message (id, parent_id, child_id, text, delivery, created_at) VALUES ('m', 'p', 'c', 'x', 'carrier-pigeon', 1)") }
        }
        try await db.write { try $0.execute(sql: "INSERT INTO agent_message (id, parent_id, child_id, text, delivery, created_at) VALUES ('m', 'p', 'c', 'x', 'inbox', 1)") }
        try await db.write { try $0.execute(sql: "DELETE FROM orchestration_child WHERE id = 'c'") }
        #expect(try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM agent_message") } == 0, "messages follow the child")
    }

    @Test func computerMirrorAndPersistentQueue() async throws {
        let home = try TempHome(); defer { home.remove() }
        let store = try await home.openStore()
        let a = UUID(), b = UUID(), c = UUID()
        try await store.saveComputerState(ComputerStateRow(id: a, name: "a", display: "headless", state: "provisioning", ownerParentID: "p"))
        try await store.saveComputerState(ComputerStateRow(id: b, name: "b", display: "headless", state: "queued", ownerParentID: "p"))
        try await store.saveComputerState(ComputerStateRow(id: c, name: "c", display: "http", state: "queued", ownerParentID: "p"))
        try await store.replaceComputerQueue([ComputerQueueRow(computerID: b, position: 1, requestedAt: Date()), ComputerQueueRow(computerID: c, position: 2, requestedAt: Date())])
        #expect(try await store.computerQueue().map(\.position) == [1, 2])
        try await store.saveComputerState(ComputerStateRow(id: b, name: "b", display: "headless", state: "ready", ownerParentID: "p"))
        try await store.replaceComputerQueue([ComputerQueueRow(computerID: c, position: 1, requestedAt: Date())])
        let rows = try await store.computerStates()
        #expect(rows.map(\.state).sorted() == ["provisioning", "queued", "ready"])
        #expect(try await store.computerQueue().map(\.computerID) == [c])
        await #expect(throws: StoreError.self) { try await store.saveComputerState(ComputerStateRow(id: UUID(), name: "x", display: "http", state: "bogus")) }
        try await store.close()
    }
}
