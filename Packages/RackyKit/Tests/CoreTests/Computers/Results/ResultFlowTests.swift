import RackyDocker
import Foundation
import Testing

@testable import RackyCore

// T3-06 / T3-07 com o scheduler e o backend falso: o filho entrega o resultado e libera, o computador sai e o pai coleta pelo run folder
// (AC-420…423); lote concluído uma vez só (AC-429). O Docker real fica no teste vivo.

actor FinishedBatches {
    private(set) var summaries: [BatchSummary] = []
    func add(_ s: BatchSummary) { summaries.append(s) }
}

extension SchedulerRig {
    func childIDs(_ reply: JSON) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (reply.json_boxes).compactMap { box in
            guard let name = box["name"]?.string, let child = box["child_id"]?.string else { return nil }
            return (name, child)
        })
    }

    func claim(_ name: String, as child: String) async {
        let r = await parentCall("box_claim", ["name": .string(name), "wait_s": 0], as: child)
        #expect(!r.isError, "claim \(name): \(r.json.text)")
    }

    /// O filho grava um request no reqlog do computador (o egress faz isso de verdade) e devolve o id.
    func seedRequest(_ name: String, id: String, trust: String = "observed") async throws {
        let computer = try #require(await hub.computer(named: name))
        try await ChainedLog(file: computer.run.requestsFile).append([
            "id": .string(id), "trust": .string(trust), "method": "GET", "status": 200, "source": "browser", "url": .string("https://aca-prod.example.test/\(name)"),
        ])
    }

    func runFolder(_ name: String, parent: String? = nil) -> RunFolder {
        RunFolder(root: root.appendingPathComponent("\(parent ?? self.parent)/\(name)", isDirectory: true))
    }

    /// result_submit + box_release de um filho. `evidence` cita o request do reqlog.
    func finish(_ name: String, child: String, result: JSON? = ["listings": 12, "owner": "ACME"], evidence: [String: JSON] = [:], release: Bool = true) async {
        if let result {
            let r = await parentCall("result_submit", ["result": result, "evidence": .object(evidence)], as: child)
            #expect(!r.isError, "result_submit \(name): \(r.json.text)")
        }
        if release {
            let r = await parentCall("box_release", [:], as: child)
            #expect(!r.isError, "box_release \(name): \(r.json.text)")
        }
    }
}

extension JSON {
    var json_boxes: [JSON] { self["boxes"]?.array ?? [] }
}

@Suite("T3-06 resultado e evidência", .serialized) struct ResultFlowTests {
    static let idA = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
    static let idMissing = "01ARZ3NDEKTSV4RRFFQ69G5FAZ"

    @Test func boxCollectWorksAfterTheChildReleasedAndTheRunFolderStays() async throws {
        let rig = try await SchedulerRig.make(workers: 4)
        defer { rig.cleanup() }
        let reply = await rig.parentCall("boxes_reserve", ["names": ["phoenix-az"], "batch": "listings-oct"])
        let child = try #require(rig.childIDs(reply.json)["phoenix-az"])
        #expect(await rig.wait("phoenix-az", .ready))
        await rig.claim("phoenix-az", as: child)
        try await rig.seedRequest("phoenix-az", id: Self.idA)
        await rig.finish("phoenix-az", child: child, result: ["listings": 12, "owner": "ACME", "ghost": "x"], evidence: ["/listings": [.string(Self.idA)], "/ghost": [.string(Self.idMissing)]])

        // AC-422: o computador saiu (container, rede, volume), o run folder e o perfil ficam.
        #expect(await rig.provisioning.tornDown == ["phoenix-az"])
        #expect(await rig.hub.computer(named: "phoenix-az") == nil)
        let run = rig.runFolder("phoenix-az")
        for file in ["work/result.json", "logs/timeline.md", "logs/usage.json", "logs/integrity.json", "logs/journal.jsonl", "logs/validation.json", "box.json"] {
            #expect(FileManager.default.fileExists(atPath: run.root.appendingPathComponent(file).path), "\(file) stays on the host")
        }
        let meta = try #require(run.readMetadata())
        #expect(meta.outcome == .released && meta.endedAt != nil && meta.batch == "listings-oct" && meta.child == child && meta.parent == rig.parent)

        // O pai coleta pelo nome, sem o computador: resultado, marcas, timeline e caminhos.
        let collected = await rig.parentCall("box_collect", ["name": "phoenix-az"])
        #expect(!collected.isError, "\(collected.json.text)")
        #expect(collected.json["result"]?["listings"] == 12)
        #expect(collected.json["validation"]?["summary"] == ["verified": 1, "cited_missing": 1, "not_verified": 1])
        #expect(collected.json["usage"]?["requests"] == 4, "usage kept from the moment the computer left")
        #expect(collected.json["timeline_md"]?.string?.contains("result submitted: 1 verified, 1 cited_missing, 1 not_verified") == true)
        #expect(collected.json["paths"]?["run"]?.string == run.root.path && collected.json["run"] == "released")
        let md = try #require(collected.json["summary_md"]?.string)
        #expect(md.contains("| /ghost | x | Cited request not found |") && md.contains("| /owner | ACME | Not verified | - |"))
        let fields = try #require(collected.json["validation"]?["fields"]?.array)
        #expect(fields.first { $0["pointer"] == "/listings" }?["citations"]?.array?.first?["summary"]?.string?.hasPrefix("200 GET https://aca-prod") == true)
    }

    @Test func boxCollectOfALiveComputerAndOfOtherParents() async throws {
        let rig = try await SchedulerRig.make(workers: 4)
        defer { rig.cleanup() }
        let reply = await rig.parentCall("boxes_reserve", ["names": ["live"]])
        let child = try #require(rig.childIDs(reply.json)["live"])
        #expect(await rig.wait("live", .ready))
        await rig.claim("live", as: child)
        let none = await rig.parentCall("box_collect", ["name": "live", "include": ["validation"]])
        #expect(!none.isError && none.json["result"] == nil && none.json["run"] == "running" && none.json["usage"]?["requests"] == 4)
        #expect(none.json["summary_md"]?.string?.contains("No result: No result.json yet") == true)

        // Nome que não existe e computador de outro pai: not_found (o caminho sai da identidade do pai).
        #expect(rig.errorCode(await rig.parentCall("box_collect", ["name": "ghost"])) == "not_found")
        await rig.hub.registerParent(id: "parent-bbbbbbbb", capability: "cap-b")
        #expect(rig.errorCode(await rig.parentCall("box_collect", ["name": "live"], as: "parent-bbbbbbbb")) == "not_found")
        // Um filho (worker) não chama ferramentas do pai.
        #expect(rig.errorCode(await rig.parentCall("box_collect", ["name": "live"], as: child)) == "blocked_by_policy")
        #expect(rig.errorCode(await rig.parentCall("box_collect", [:])) == "invalid_argument")
    }

    @Test func aRepeatedNameInTheSessionArchivesThePreviousRun() async throws {
        let rig = try await SchedulerRig.make(workers: 4)
        defer { rig.cleanup() }
        var reply = await rig.parentCall("boxes_reserve", ["names": ["phoenix-az"]])
        var child = try #require(rig.childIDs(reply.json)["phoenix-az"])
        #expect(await rig.wait("phoenix-az", .ready))
        await rig.claim("phoenix-az", as: child)
        await rig.finish("phoenix-az", child: child, result: ["v": 1])

        reply = await rig.parentCall("boxes_reserve", ["names": ["phoenix-az"]])
        child = try #require(rig.childIDs(reply.json)["phoenix-az"])
        #expect(await rig.wait("phoenix-az", .ready))
        let session = rig.root.appendingPathComponent(rig.parent)
        let archived = try FileManager.default.contentsOfDirectory(atPath: session.appendingPathComponent("_archive").path)
        #expect(archived.count == 1 && archived[0].hasPrefix("phoenix-az-"))
        let old = session.appendingPathComponent("_archive/\(archived[0])/work/result.json")
        #expect(FileManager.default.fileExists(atPath: old.path), "nothing is deleted on the archive path")
        // O run novo começa limpo e o `box_collect` vê o novo, não o arquivado.
        let collected = await rig.parentCall("box_collect", ["name": "phoenix-az"])
        #expect(collected.json["result"] == .null && collected.json["run"] == "running")
        #expect(RunArchive.runs(inSession: session).map { $0.root.lastPathComponent } == ["phoenix-az"])
        _ = child
    }

    @Test func subagentStopStopsTheComputerAndKeepsTheRun() async throws {
        // AC-422: o `SubagentStop` do filho que não chamou `box_release`.
        let rig = try await SchedulerRig.make(workers: 4)
        defer { rig.cleanup() }
        let reply = await rig.parentCall("boxes_reserve", ["names": ["phoenix-az"], "batch": "listings-oct"])
        let child = try #require(rig.childIDs(reply.json)["phoenix-az"])
        #expect(await rig.wait("phoenix-az", .ready))
        await rig.claim("phoenix-az", as: child)
        await rig.finish("phoenix-az", child: child, release: false)
        let parentRun = UUID()
        await rig.scheduler.handleChildHook(parentRunID: parentRun, event: "PreToolUse", agentID: "agent-1", mcpServer: "abx-\(child)")
        #expect(await rig.provisioning.tornDown.isEmpty)
        await rig.scheduler.handleChildHook(parentRunID: parentRun, event: "SubagentStop", agentID: "agent-1", mcpServer: nil)
        #expect(await rig.provisioning.tornDown == ["phoenix-az"])
        #expect(await rig.hub.computer(named: "phoenix-az") == nil)
        let run = rig.runFolder("phoenix-az")
        #expect(run.readMetadata()?.outcome == .released && FileManager.default.fileExists(atPath: run.resultFile.path))
        // Depois do stop o filho recebe `box_released` e o resultado segue coletável.
        #expect(rig.errorCode(await rig.parentCall("box_status", [:], as: child)) == "box_released")
        #expect((await rig.parentCall("box_collect", ["name": "phoenix-az"])).json["result"]?["listings"] == 12)
    }

    @Test func archiveComputersRemovesContainersButKeepsRunsAndResults() async throws {
        // AC-423: dois computadores parados; arquivar tira containers e volumes e deixa os run folders.
        let rig = try await SchedulerRig.make(workers: 4)
        defer { rig.cleanup() }
        let reply = await rig.parentCall("boxes_reserve", ["names": ["a", "b"], "batch": "listings-oct"])
        let kids = rig.childIDs(reply.json)
        for name in ["a", "b"] {
            #expect(await rig.wait(name, .ready))
            await rig.claim(name, as: try #require(kids[name]))
            await rig.finish(name, child: try #require(kids[name]), release: false)
        }
        let before = try #require(await rig.scheduler.batchSummary(parent: rig.parent, batch: "listings-oct"))
        #expect(before.children.allSatisfy { $0.status == .running })
        let archived = await rig.scheduler.archiveComputers(names: ["a", "b", "ghost"])
        #expect(archived == ["a", "b"])
        #expect(Set(await rig.provisioning.tornDown) == ["a", "b"])
        #expect((await rig.parentCall("boxes_status", [:])).json["boxes"]?.array?.isEmpty == true)
        for name in ["a", "b"] {
            let run = rig.runFolder(name)
            #expect(FileManager.default.fileExists(atPath: run.resultFile.path) && run.readMetadata()?.outcome == .stopped)
        }
        let after = try #require(await rig.scheduler.batchSummary(parent: rig.parent, batch: "listings-oct"))
        #expect(after.children.map(\.status) == [.stopped, .stopped])
        #expect((await rig.parentCall("box_collect", ["name": "a"])).json["result"]?["listings"] == 12)
    }

    @Test func resultsViewMatchesCollectForTheUI() async throws {
        // O mesmo CollectedRun alimenta a aba `Result`: marcas, links e `Reveal`.
        let rig = try await SchedulerRig.make(workers: 2)
        defer { rig.cleanup() }
        let reply = await rig.parentCall("boxes_reserve", ["names": ["phoenix-az"]])
        let child = try #require(rig.childIDs(reply.json)["phoenix-az"])
        #expect(await rig.wait("phoenix-az", .ready))
        await rig.claim("phoenix-az", as: child)
        try await rig.seedRequest("phoenix-az", id: Self.idA, trust: "reported")
        await rig.finish("phoenix-az", child: child, evidence: ["/listings": [.string(Self.idA)]])
        let run = rig.runFolder("phoenix-az")
        let loader = RunResultLoader()
        let collected = await loader.collect(run: run.root, name: "phoenix-az")
        #expect(collected.verified == 1 && collected.notVerified == 1 && !collected.handwritten)
        #expect(collected.fields.first { $0.pointer == "/listings" }?.links.first?.trust == "reported")
        #expect(await loader.evidenceTarget(run: run.root, ref: Self.idA) == run.requestsFile)
        #expect(await loader.evidenceTarget(run: run.root, ref: Self.idMissing) == nil)
        #expect(await loader.evidenceTarget(run: run.root, ref: "../../etc/passwd") == nil)
        #expect(await loader.revealTarget(run: run.root) == run.resultFile)
        let present = await loader.runExists(run.root)
        let absent = await loader.runExists(run.root.appendingPathComponent("nope"))
        #expect(present && !absent)
    }
}

extension SchedulerRig {
    func errorCode(_ r: (isError: Bool, json: JSON, outcome: ToolOutcome)) -> String? { r.isError ? r.json["error"]?.string : nil }
}
