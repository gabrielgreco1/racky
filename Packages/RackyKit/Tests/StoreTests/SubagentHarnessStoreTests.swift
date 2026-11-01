import RackyProtocol
import Foundation
import GRDB
import Testing

@testable import RackyStore

/// Spec subagent-harness: migração `v11_subagent_harness`, harness por sessão e por filho, terminal do worker.
@Suite struct SubagentHarnessStoreTests {
    @Test func migrationIsLast() {
        #expect(StoreMigrations.all.last?.id == "v11_subagent_harness")
    }

    @Test func harnessDefaultsToClaudeAndPersists() async throws {
        let home = try TempHome(); defer { home.remove() }
        let store = try await home.openStore()
        var a = Session(kind: .clean, folderPath: "/tmp/a", title: "a")
        var b = Session(kind: .clean, folderPath: "/tmp/b", title: "b")
        #expect(a.subagentHarness == .claude)
        b.subagentHarness = .opencode
        for session in [a, b] { try await store.save(session) }
        try await store.setSubagentHarness(sessionID: a.id, harness: .mixed)
        a.title = "a"
        try await store.close()
        let reopened = try await home.openStore(day: 1)
        let loaded = Dictionary(uniqueKeysWithValues: try await reopened.sessions().map { ($0.title, $0.subagentHarness) })
        #expect(loaded == ["a": .mixed, "b": .opencode])
        try await reopened.close()
    }

    @Test func workerChildKeepsHarnessTitleAndTerminal() async throws {
        let home = try TempHome(); defer { home.remove() }
        let store = try await home.openStore()
        try await store.registerOrchestrationChild(OrchestrationChild(id: "p-w1", parentID: "p", slot: 1, agentType: "racky-worker-1"))
        try await store.registerOrchestrationChild(OrchestrationChild(
            id: "p-a1", parentID: "p", slot: 101, agentType: "app-worker", capabilityHash: "h", harness: "codex", title: "Houston listings"))
        let terminal = UUID()
        try await store.setOrchestrationWorkerTerminal(id: "p-a1", terminalID: terminal)
        let workers = try await store.orchestrationWorkers(parentID: "p")
        #expect(workers.map(\.id) == ["p-a1"])
        #expect(workers[0].harness == "codex" && workers[0].title == "Houston listings" && workers[0].workerTerminalID == terminal)
        let native = try #require(try await store.orchestrationChild(id: "p-w1"))
        #expect(native.harness == nil && native.workerTerminalID == nil)
        try await store.close()
    }
}
