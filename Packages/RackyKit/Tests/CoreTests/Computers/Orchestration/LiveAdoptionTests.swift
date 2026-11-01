import RackyDocker
import RackyPlatform
import RackyProtocol
import RackyStore
import Foundation
import Testing

@testable import RackyCore

// Adoção com o Docker real (`RACKY_TEST_DOCKER=1`): uma "primeira vida" do app cria um computador (display http, leve) e persiste; a
// "segunda vida" (hub e scheduler novos, mesmo Store) o readota do container que seguiu vivo, relendo o token dele, e o filho continua
// operando com a capability antiga. Só toca recursos `racky.test=1` + `racky.test_run=<id>` e remove tudo ao final.

@Suite("Adoção de computadores - Docker real", .serialized, .enabled(if: LiveC.enabled), .tags(.integration), .timeLimit(.minutes(10)))
struct LiveAdoptionTests {
    @Test func aSecondAppLifeAdoptsTheRunningContainerAndTheChildKeepsWorking() async throws {
        let runID = LiveComputerTests.shortID()
        let detected = try await RuntimeDetector().detect()
        let client = DockerClient(runtime: detected.runtime, defaultTimeout: .seconds(60))
        let testLabels = [RackyLabel.test: "1", "racky.test_run": runID]
        let labelFilter = ["\(RackyLabel.test)=1", "racky.test_run=\(runID)"]
        let home = URL(fileURLWithPath: "/tmp/abx-adopt-\(runID)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        func cleanup() async {
            let gc = GarbageCollector(client: client)
            if let items = try? await gc.inventory(labels: labelFilter) { _ = await gc.remove(items) }
            if let images = try? await client.listImages(filters: ["label": labelFilter]) { for image in images { try? await client.removeImage(image.id, force: true) } }
            try? FileManager.default.removeItem(at: home)
        }
        do {
            let image = try await ImageManager(client: client).ensure(ImageSource(
                repository: "racky-computer-test-\(runID)", contextDirectory: LiveC.repoRoot.appendingPathComponent("runtime/computer"), extraLabels: testLabels))
            let store = try await RackyStore.open(paths: StorePaths(root: home.appendingPathComponent("store", isDirectory: true)))
            let provisioning = DockerComputerProvisioning(
                client: client, image: image.tag, secrets: BoxSecretFiles(root: home), owner: "test-\(runID)", extraLabels: ["racky.test_run": runID], isTest: true)
            let runs = home.appendingPathComponent("runs", isDirectory: true)
            func life() async -> (hub: ComputerHub, scheduler: ComputerScheduler, service: ComputerToolService) {
                let hub = ComputerHub()
                let scheduler = ComputerScheduler(
                    hub: hub, provisioning: provisioning, capacity: { detected.capacity },
                    runDirectory: { parent, name in runs.appendingPathComponent("\(parent.prefix(8))/\(name)", isDirectory: true) }, store: store, fixedEstimates: true)
                await scheduler.attach()
                return (hub, scheduler, ComputerToolService(hub: hub, orchestrator: scheduler))
            }

            // ---- primeira vida
            let first = await life()
            let parentID = UUID().uuidString.lowercased()
            let bundle = try OrchestrationInjectionBuilder.make(parentID: parentID, helperPath: "/usr/local/bin/racky", options: { var o = OrchestrationInjectionBuilder.Options(); o.workerSlots = 2; return o }())
            await OrchestrationInjectionBuilder.register(bundle, hub: first.hub, scheduler: first.scheduler)
            try await store.saveOrchestrationParent(OrchestrationParentRecord(
                id: parentID, sessionTitle: "live-adoption", mode: "full", capabilityHash: ComputerHub.fingerprint(bundle.parentCapability)))
            let reserved = await first.service.call("boxes_reserve", arguments: ["names": ["adopt-me"], "display": "http"], child: parentID)
            #expect(!reserved.isError)
            let worker = bundle.workers[0]
            var claimed = false
            for _ in 0..<240 where !claimed {  // até 2 min
                let reply = await first.service.call("box_claim", arguments: ["name": "adopt-me", "wait_s": 0], child: worker.childID)
                claimed = !reply.isError && (reply.content.first?["text"]?.string ?? "").contains("in_use")
                if !claimed { try await Task.sleep(for: .milliseconds(500)) }
            }
            #expect(claimed, "the first life never got the computer")
            try await store.updateOrchestrationChild(id: worker.childID, state: .claimed)
            let before = await first.service.call("exec", arguments: ["shell": "echo first-life"], child: worker.childID)
            let beforeText = before.content.first?["text"]?.string ?? ""
            #expect(beforeText.contains("first-life"))
            // O app "morre": a primeira vida é abandonada sem teardown (o container fica de pé, como com o app trocado).

            // ---- segunda vida
            let second = await life()
            await ComputerOrchestrator.restoreIdentities(store: store, hub: second.hub, parents: ParentDirectory())
            let adopted = await second.scheduler.adoptRunning()
            #expect(adopted == ["adopt-me"])
            let accepted = await second.hub.authorize(child: worker.childID, capability: worker.capability)
            let rejected = await second.hub.authorize(child: worker.childID, capability: "forged")
            #expect(accepted && !rejected)
            // O filho opera o computador adotado com o token relido do container (nada de `box_claim` de novo).
            let after = await second.service.call("exec", arguments: ["shell": "echo second-life; id -un"], child: worker.childID)
            let text = after.content.first?["text"]?.string ?? ""
            #expect(!after.isError && text.contains("second-life") && text.contains("agent"), "exec after adoption: \(text)")
            let status = await second.service.call("boxes_status", arguments: [:], child: parentID)
            let statusText = status.content.first?["text"]?.string ?? ""
            #expect(statusText.contains("adopt-me"))
            let usage = try await second.hub.computer(named: "adopt-me")?.backend.usage()
            #expect(usage != nil)
            try await store.close()
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
        let leftovers = (try? await GarbageCollector(client: client).inventory(labels: labelFilter)) ?? []
        #expect(leftovers.isEmpty, "the cleanup left resources behind: \(leftovers.map(\.name))")
    }
}
