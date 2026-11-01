import RackyDocker
import RackyProtocol
import RackyStore
import Foundation
import Testing

@testable import RackyCore

// Adoção: o app reinicia com o pai, o subagente e o container ainda vivos. A fonte da verdade é o que o scheduler persistiu (`computer`,
// `orchestration_child`, `orchestration_parent`); o Docker só dá os fatos vivos. Provisionador falso; o Docker real é do teste vivo.

/// Docker falso da "segunda vida" do app: lista containers e devolve o backend falso na adoção.
actor AdoptingProvisioning: ComputerProvisioning {
    var live: [LiveComputer]?
    private(set) var adopted: [String] = []
    private(set) var tornDown: [String] = []
    var failing: Set<String> = []
    let backend = FakeBackend()

    init(live: [LiveComputer]?) { self.live = live }
    func setFailing(_ names: Set<String>) { failing = names }
    func provision(_ spec: ComputerSpec) async throws -> ProvisionedHandle { throw ToolError(.notSupported, "adoption tests never create containers") }
    func liveComputers() async -> [LiveComputer]? { live }
    func adopt(_ live: LiveComputer, spec: ComputerSpec) async throws -> AdoptedComputer {
        if failing.contains(live.name) { throw ToolError(.boxRestarted, "token not readable") }
        adopted.append(live.name)
        let name = live.name
        return AdoptedComputer(handle: ProvisionedHandle(backend: backend) { await self.recordTeardown(name) }, proxy: "residential-us", allowHosts: ["example.com"])
    }
    func recordTeardown(_ name: String) { tornDown.append(name) }
}

@Suite("Adoção de computadores após reiniciar o app", .serialized) struct AdoptionTests {
    /// Primeira vida: pai com 3 slots, computadores `a` (reivindicado pelo slot 1), `b` (reservado, sem dono) e `c` (reservado, container some).
    private struct FirstLife {
        let home: ActivityHome
        let store: RackyStore
        let rig: SchedulerRig
        let sessionID = UUID()
        var parent: String { rig.parent }
        var child1: String { OrchestrationInjectionBuilder.childID(parent: parent, slot: 1) }
        var child2: String { OrchestrationInjectionBuilder.childID(parent: parent, slot: 2) }

        static func make() async throws -> FirstLife {
            let home = try ActivityHome()
            let store = try await home.openStore()
            let life = FirstLife(home: home, store: store, rig: try await SchedulerRig.make(workers: 3, store: store))
            try await store.saveOrchestrationParent(OrchestrationParentRecord(
                id: life.parent, sessionID: life.sessionID, sessionTitle: "houston-listings", mode: "ask", proxy: "residential-us",
                capabilityHash: ComputerHub.fingerprint("cap-parent")))
            _ = await life.rig.parentCall("boxes_reserve", ["names": ["a", "b", "c"], "batch": "listings-oct"])
            for name in ["a", "b", "c"] { #expect(await life.rig.wait(name, .ready)) }
            let slot1 = try #require(await life.rig.scheduler.childID(for: "a"))
            // `box_claim` pelo serviço de ferramentas, como o filho faz: o claim tem de chegar ao store sozinho.
            let claim = await life.rig.parentCall("box_claim", ["name": "a", "wait_s": 0], as: slot1)
            #expect(!claim.isError, "box_claim failed: \(claim.json)")
            let persisted = try await store.orchestrationChildren(parentID: life.parent).first { $0.id == slot1 }
            #expect(persisted?.state == .claimed, "o claim do filho fica no store (adoção devolve o dono e o computador volta in_use)")
            return life
        }

        func liveContainers() async -> [LiveComputer] {
            let specs = await rig.provisioning.specs
            return ["a", "b"].map { name in
                // `b` simula um container criado por build antigo: o id do label não é o da linha (casa pelo nome).
                let id = name == "a" ? specs[name]!.computerID.uuidString.lowercased() : UUID().uuidString.lowercased()
                return LiveComputer(computerID: id, name: name, containerID: "cid-\(name)", running: true, created: 100, batch: "listings-oct")
            }
        }

        func close() async { try? await store.close(); rig.cleanup(); home.remove() }
    }

    private func secondLife(store: RackyStore, live: [LiveComputer]?, root: URL) async -> (hub: ComputerHub, scheduler: ComputerScheduler, parents: ParentDirectory, docker: AdoptingProvisioning) {
        let hub = ComputerHub()
        let docker = AdoptingProvisioning(live: live)
        let scheduler = ComputerScheduler(
            hub: hub, provisioning: docker, capacity: { SchedulerRig.eightGB }, runDirectory: { p, n in root.appendingPathComponent("\(p)/\(n)", isDirectory: true) },
            store: store, fixedEstimates: true)
        await scheduler.attach()
        return (hub, scheduler, ParentDirectory(), docker)
    }

    @Test func runningComputersComeBackWithTheirChildIdentityAndClaim() async throws {
        let life = try await FirstLife.make()
        var containers = await life.liveContainers()
        containers.append(LiveComputer(computerID: UUID().uuidString.lowercased(), name: "stray", containerID: "cid-stray", running: true))  // órfão: sem linha
        let (hub, scheduler, parents, docker) = await secondLife(store: life.store, live: containers, root: life.rig.root)

        await ComputerOrchestrator.restoreIdentities(store: life.store, hub: hub, parents: parents)
        let adopted = await scheduler.adoptRunning()

        #expect(adopted == ["a", "b"], "c's container is gone and stray has no record")
        let (dockerAdopted, dockerTorn) = (await docker.adopted, await docker.tornDown)
        #expect(dockerAdopted == ["a", "b"] && dockerTorn.isEmpty, "nothing is removed")
        let (stray, gone) = (await hub.computer(named: "stray"), await hub.computer(named: "c"))
        #expect(stray == nil && gone == nil)
        // O MCP do pai e do subagente seguem aceitos com as capabilities do lançamento antigo (só o hash foi persistido).
        let (okChild, okParent) = (await hub.authorize(child: life.child1, capability: "cap-w1"), await hub.authorize(child: life.parent, capability: "cap-parent"))
        let (badChild, crossed) = (await hub.authorize(child: life.child1, capability: "cap-w2"), await hub.authorize(child: life.child1, capability: "cap-parent"))
        #expect(okChild && okParent && !badChild && !crossed)
        let (childRole, childParent, parentRole) = (await hub.role(of: life.child1), await hub.parent(of: life.child1), await hub.role(of: life.parent))
        #expect(childRole == .worker && childParent == life.parent && parentRole == .parent)
        // O claim volta: o subagente usa o computador dele sem `box_claim` de novo.
        let a = try #require(await hub.computer(named: "a"))
        let claimed = await hub.claimedComputer(of: life.child1)
        let routed = try await hub.computer(for: life.child1)
        #expect(claimed == "a" && routed === a)
        let (aOwner, aState, aProxy) = (await a.owner, await a.state, await a.proxy)
        #expect(aOwner == life.child1 && aState == .inUse && aProxy == "residential-us")
        let b = try #require(await hub.computer(named: "b"))
        let (bOwner, bState) = (await b.owner, await b.state)
        #expect(bOwner == nil && bState == .ready)
        // O scheduler sabe de quem é cada um (sidebar, Inbox, `boxes_status` do pai).
        let (owner, slot, phase, names) = (await scheduler.parent(of: "a"), await scheduler.childID(for: "a"), await scheduler.phase(of: "a"), await scheduler.computerNames(of: life.parent))
        #expect(owner == life.parent && slot == life.child1 && phase == .active && names == ["a", "b"])
        let info = try #require(await parents.info(life.parent))
        #expect(info.sessionID == life.sessionID && info.sessionTitle == "houston-listings" && info.mode == .ask && info.proxy == "residential-us")
        // O backend adotado responde às ferramentas.
        let ready = try await a.backend.runtime("status", [:], timeout: 5)
        #expect(ready["ok"] == true)
        await life.close()
    }

    @Test func aGoneContainerEndsItsRecordAndNeverBlocksTheRest() async throws {
        let life = try await FirstLife.make()
        let (hub, scheduler, parents, _) = await secondLife(store: life.store, live: await life.liveContainers(), root: life.rig.root)
        await ComputerOrchestrator.restoreIdentities(store: life.store, hub: hub, parents: parents)
        _ = await scheduler.adoptRunning()
        let rows = try await life.store.computerStates()
        #expect(rows.first { $0.name == "c" }?.state == "removed" && rows.first { $0.name == "a" }?.state == "in_use")
        let children = try await life.store.orchestrationChildren(parentID: life.parent)
        #expect(children.first { $0.computerName == "c" }?.state == .released)
        await life.close()
    }

    @Test func dockerDownOrAdoptionFailureLeavesEverythingAlone() async throws {
        let life = try await FirstLife.make()
        // Docker inalcançável: nada muda (nem a linha de `c`).
        let (hubA, schedulerA, _, _) = await secondLife(store: life.store, live: nil, root: life.rig.root)
        let none = await schedulerA.adoptRunning()
        let visible = await hubA.allComputers
        #expect(none.isEmpty && visible.isEmpty)
        #expect(try await life.store.computerStates().first { $0.name == "c" }?.state == "ready")
        // Token ilegível em `a`: não é adotado, `b` é.
        let (hubB, schedulerB, _, dockerB) = await secondLife(store: life.store, live: await life.liveContainers(), root: life.rig.root)
        await dockerB.setFailing(["a"])
        let onlyB = await schedulerB.adoptRunning()
        let (aMissing, torn) = (await hubB.computer(named: "a"), await dockerB.tornDown)
        #expect(onlyB == ["b"] && aMissing == nil && torn.isEmpty)
        await life.close()
    }

    @Test func rowsWithoutAChildRecordAreOrphansAndStayUntouched() async throws {
        let home = try ActivityHome(); defer { home.remove() }
        let store = try await home.openStore()
        let id = UUID()
        try await store.saveComputerState(ComputerStateRow(id: id, name: "loner", display: "headless", state: "ready", ownerParentID: "parent-zzz"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("abx-adopt-\(UUID().uuidString)", isDirectory: true)
        let (hub, scheduler, _, docker) = await secondLife(
            store: store, live: [LiveComputer(computerID: id.uuidString.lowercased(), name: "loner", containerID: "cid", running: true)], root: root)
        let none = await scheduler.adoptRunning()
        let (visible, adoptedList) = (await hub.allComputers, await docker.adopted)
        #expect(none.isEmpty && visible.isEmpty && adoptedList.isEmpty)
        try await store.close()
    }

    @Test func endingTheParentDropsItsPersistedIdentity() async throws {
        let life = try await FirstLife.make()
        try await life.store.deleteOrchestrationParent(id: life.parent)
        let hub = ComputerHub(), parents = ParentDirectory()
        await ComputerOrchestrator.restoreIdentities(store: life.store, hub: hub, parents: parents)
        let (role, accepted) = (await hub.role(of: life.parent), await hub.authorize(child: life.child1, capability: "cap-w1"))
        #expect(role == nil && !accepted)
        await life.close()
    }

    @Test func persistedIdentityIsAHashNeverTheCapability() async throws {
        let life = try await FirstLife.make()
        let parent = try #require(try await life.store.orchestrationParents().first)
        #expect(parent.capabilityHash == ComputerHub.fingerprint("cap-parent") && parent.capabilityHash != "cap-parent" && parent.capabilityHash.count == 64)
        let child = try #require(try await life.store.orchestrationChild(id: life.child1))
        #expect(child.capabilityHash == ComputerHub.fingerprint("cap-w1"))
        await life.close()
    }
}
