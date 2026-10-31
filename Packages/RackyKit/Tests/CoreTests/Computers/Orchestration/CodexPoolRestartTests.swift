import RackyProtocol
import RackyStore
import Foundation
import Testing

@testable import RackyCore

// Codex: os workers falam pelo servidor `racky_worker` (identidade por `_meta.threadId`). Depois de reiniciar o app o pool, o CLI do pai
// e a thread de cada worker voltam do Store (só hashes e ids); sem isso o worker de um Codex pai que seguiu vivo seria recusado.

@Suite("Pool de workers do Codex depois de reiniciar o app", .serialized) struct CodexPoolRestartTests {
    private func orchestrator(store: RackyStore, root: URL) -> ComputerOrchestrator {
        ComputerOrchestrator(
            helperPath: "/Applications/Racky.app/Contents/MacOS/racky", store: store,
            provisioning: AppComputerProvisioning(config: .init(runtimeRoot: nil, secretsRoot: root, owner: "test-pool-restart")),
            runsRoot: root.appendingPathComponent("runs", isDirectory: true), waitSeconds: 1, fixedEstimates: true)
    }

    private func meta(thread: String) -> JSON {
        ["_meta": ["threadId": .string(thread), "x-codex-turn-metadata": ["thread_id": .string(thread), "thread_source": "subagent"]]]
    }

    @Test func aRestartedAppStillRoutesAWorkerOfARunningCodexParent() async throws {
        let home = try ActivityHome()
        defer { home.remove() }
        let store = try await home.openStore()
        defer { Task { try? await store.close() } }
        let parent = "0a1b2c3d-parent-codex"
        let session = UUID()

        // Primeira vida: o app prepara o pai Codex e uma thread de worker vira o slot 1.
        let first = orchestrator(store: store, root: home.root)
        var options = OrchestrationInjectionBuilder.Options()
        options.workerSlots = 2
        let bundle = try await first.prepareParent(
            ParentInfo(parentID: parent, sessionID: session, sessionTitle: "houston-listings", mode: .ask, provider: .codex), options: options)
        let pool = try #require(bundle.poolID)
        let poolCapability = try #require(bundle.poolCapability)
        let slot1 = try #require(bundle.workers.first?.childID)
        await first.hub.bind(thread: "thread-A", pool: pool, to: slot1)
        for _ in 0..<200 {
            if try await store.orchestrationChild(id: slot1)?.boundThread == "thread-A" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await store.orchestrationChild(id: slot1)?.boundThread == "thread-A")

        // O que foi para o disco são hashes, nunca a capability pura.
        let record = try #require(try await store.orchestrationParents().first)
        #expect(record.provider == "codex" && record.poolID == pool)
        #expect(record.poolCapabilityHash == ComputerHub.fingerprint(poolCapability) && record.poolCapabilityHash != poolCapability)

        // Segunda vida: orquestrador novo sobre o mesmo Store (o Codex pai segue vivo com os argumentos antigos).
        let second = orchestrator(store: store, root: home.root)
        let before = await second.hub.role(of: pool)
        #expect(before == nil, "sem a restauração o pool é desconhecido")
        await second.restoreIdentities()

        let role = await second.hub.role(of: pool)
        let owner = await second.hub.poolParent(of: pool)
        let good = await second.hub.authorize(child: pool, capability: poolCapability)
        let bad = await second.hub.authorize(child: pool, capability: "nope")
        #expect(role == .pool && owner == parent && good && !bad)
        let info = await second.parents.info(parent)
        #expect(info?.provider == .codex)
        let agent = await second.hub.boundChild(thread: "thread-A", pool: pool)
        #expect(agent == slot1)

        // O worker (subagente do Codex) chama pelo pool e cai no slot dele; outra thread continua sem identidade; fora de subagente é negado.
        let server = second.server
        let routed = await server.route("box_status", arguments: [:], params: meta(thread: "thread-A"), child: pool)
        guard case .child(let effective) = routed else { Issue.record("worker recusado depois do restart"); return }
        #expect(effective == slot1)
        let stranger = await server.route("box_status", arguments: [:], params: meta(thread: "thread-Z"), child: pool)
        guard case .failure = stranger else { Issue.record("thread desconhecida deveria falhar"); return }
        let nonSubagent = await server.route("box_status", arguments: [:], params: ["_meta": ["threadId": "thread-A"]], child: pool)
        guard case .failure = nonSubagent else { Issue.record("fora de subagente deveria falhar"); return }

        // Terminando o pai, o pool sai do hub (e a thread do disco).
        await second.endParent(parent)
        let gone = await second.hub.role(of: pool)
        #expect(gone == nil)
        #expect(try await store.orchestrationChild(id: slot1)?.boundThread == nil)
    }
}
