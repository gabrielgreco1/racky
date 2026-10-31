import Foundation
import RackyPlatform
import RackyProtocol
import RackyStore
import Testing

@testable import RackyCore

/// Datasets v1 pelo MCP: ferramentas do worker (`dataset_*`) com proveniência resolvida no reqlog do computador, e as do pai.
@Suite struct DatasetToolTests {
    struct Env {
        let rig: Rig
        let store: RackyStore
        let session: UUID
        let service: ComputerToolService
        let root: URL

        static func make() async throws -> Env {
            let rig = try await Rig.make()
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("racky-dstool-\(UUID().uuidString)", isDirectory: true)
            let store = try await RackyStore.open(paths: StorePaths(root: root))
            let session = Session(kind: .clean, folderPath: "/tmp/ds", title: "ds")
            try await store.save(session)
            let sessionID = session.id
            await rig.hub.registerParent(id: "parent-1", capability: "p")
            let backend = DatasetBackend(service: DatasetService(store: store)) { _ in sessionID }
            let service = ComputerToolService(hub: rig.hub, datasets: backend)
            return Env(rig: rig, store: store, session: sessionID, service: service, root: root)
        }

        func cleanup() async { rig.cleanup(); try? await store.close(); try? FileManager.default.removeItem(at: root) }

        func call(_ tool: String, _ args: JSON = [:], child: String = "child-1") async -> (isError: Bool, json: JSON) {
            let outcome = await service.call(tool, arguments: args, child: child)
            return (outcome.isError, (try? JSON.parse(outcome.content.first?["text"]?.string ?? "null")) ?? .null)
        }
    }

    static let observed = "01ARZ3NDEKTSV4RRFFQ69G5FAV", reported = "01ARZ3NDEKTSV4RRFFQ69G5FAW", ghost = "01ARZ3NDEKTSV4RRFFQ69G5FAX"

    private func seedReqlog(_ env: Env) throws {
        try env.rig.seedRequests([
            ["id": .string(Self.observed), "trust": "observed", "method": "GET", "status": 200, "duration_ms": 412, "source": "browser", "url": "https://hotels.test/ritz"],
            ["id": .string(Self.reported), "trust": "reported", "method": "GET", "status": 200, "source": "work", "url": "https://hotels.test/plaza"],
        ])
    }

    private let columns: JSON = [["name": "name", "required": true], ["name": "rating", "type": "number"], ["name": "url", "type": "url"]]

    @Test func defineAppendReadResolveProvenanceAgainstTheComputersReqlog() async throws {
        let env = try await Env.make(); defer { Task { await env.cleanup() } }
        try seedReqlog(env)
        await env.rig.claim()
        let define = await env.call("dataset_define", ["name": "hotels", "columns": columns, "key": ["name"]])
        #expect(!define.isError && define.json["created"] == true && define.json["total_rows"] == 0, "\(define.json.text)")

        let append = await env.call("dataset_append", ["name": "hotels", "rows": [
            ["name": "Ritz", "rating": "4.5", "_request_id": .string(Self.observed)], ["name": "Plaza", "rating": 4, "_request_id": .string(Self.reported)],
            ["name": "Ghost", "_request_id": .string(Self.ghost)], ["rating": 3],
        ]])
        #expect(!append.isError && append.json["inserted"] == 4 && append.json["invalid"] == 1 && append.json["total_rows"] == 4, "\(append.json.text)")
        #expect((append.json["warnings"]?.array ?? []).count == 1, "the unknown request id is warned about")

        let read = await env.call("dataset_read", ["name": "hotels"])
        let rows = try #require(read.json["rows"]?.array)
        #expect(rows.count == 4 && read.json["invalid_rows"] == 1)
        let byName = Dictionary(uniqueKeysWithValues: rows.compactMap { row in row["data"]?["name"]?.string.map { ($0, row) } })
        #expect(byName["Ritz"]?["trust"] == "observed" && byName["Ritz"]?["source_url"] == "https://hotels.test/ritz" && byName["Ritz"]?["request_id"] == .string(Self.observed))
        #expect(byName["Ritz"]?["data"]?["rating"] == 4.5 && byName["Ritz"]?["computer"] == "box-a")
        #expect(byName["Plaza"]?["trust"] == "reported" && byName["Ghost"]?["trust"] == "none" && byName["Ghost"]?["request_id"] == nil)
        let invalid = await env.call("dataset_read", ["name": "hotels", "invalid_only": true])
        #expect(invalid.json["returned"] == 1 && invalid.json["rows"]?.array?[0]["error"] == "name: required")

        // O run do computador entra como run_id da linha.
        let dataset = try #require(try await env.store.dataset(sessionID: env.session, name: "hotels"))
        let stored = try await env.store.datasetRows(datasetID: dataset.id)
        #expect(stored.count == 4 && stored.allSatisfy { $0.runID?.count == 26 }, "the computer's run id (a ULID) is kept per row")
        let ritz = try #require(stored.first { $0.requestID == Self.observed })
        #expect(ritz.request == DatasetRequestInfo(method: "GET", status: 200, milliseconds: 412), "method, status and time come from the reqlog record")
        #expect(stored.first { !$0.valid }?.errorKind == "name missing")
    }

    @Test func importReadsFromWorkAndRefusesEscapes() async throws {
        let env = try await Env.make(); defer { Task { await env.cleanup() } }
        await env.rig.claim()
        try FileManager.default.createDirectory(at: env.rig.temp.folder.work, withIntermediateDirectories: true)
        try Data("Name,Rating,URL\nRitz,4.5,https://hotels.test/ritz\n\"Plaza, NYC\",3,https://hotels.test/plaza\n".utf8)
            .write(to: env.rig.temp.folder.work.appendingPathComponent("hotels.csv"))
        let imported = await env.call("dataset_import", ["name": "hotels", "file": "/work/hotels.csv"])
        #expect(!imported.isError && imported.json["inserted"] == 2 && imported.json["format"] == "csv" && imported.json["created"] == true, "\(imported.json.text)")
        let dataset = try #require(try await env.store.dataset(sessionID: env.session, name: "hotels"))
        let rows = try await env.store.datasetRows(datasetID: dataset.id)
        #expect(rows.map(\.sourceURL) == ["https://hotels.test/ritz", "https://hotels.test/plaza"] && rows.allSatisfy { $0.trust == .none })

        // `..`, fora de /work e symlink: path_rejected; arquivo que não existe: not_found.
        for path in ["/work/../../etc/passwd", "/etc/passwd"] {
            let rejected = await env.call("dataset_import", ["name": "hotels", "file": .string(path)])
            #expect(rejected.isError && rejected.json["error"] == "path_rejected", "\(path)")
        }
        let outside = env.root.appendingPathComponent("secret.csv")
        try Data("a\n1\n".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: env.rig.temp.folder.work.appendingPathComponent("link.csv"), withDestinationURL: outside)
        let link = await env.call("dataset_import", ["name": "hotels", "file": "/work/link.csv"])
        #expect(link.isError && link.json["error"] == "path_rejected")
        let missing = await env.call("dataset_import", ["name": "hotels", "file": "/work/none.csv"])
        #expect(missing.isError && missing.json["error"] == "not_found")
        try Data("{\"a\":1}\n{\"a\":2}\n".utf8).write(to: env.rig.temp.folder.work.appendingPathComponent("rows.jsonl"))
        let lines = await env.call("dataset_import", ["name": "jl", "file": "rows.jsonl"])
        #expect(lines.json["inserted"] == 2 && lines.json["format"] == "jsonl")
        try Data("a,b\n".utf8).write(to: env.rig.temp.folder.work.appendingPathComponent("empty.csv"))
        let empty = await env.call("dataset_import", ["name": "e", "file": "empty.csv"])
        #expect(empty.isError && empty.json["error"] == "invalid_argument")
    }

    @Test func claimAndSchemaRulesApply() async throws {
        let env = try await Env.make(); defer { Task { await env.cleanup() } }
        let early = await env.call("dataset_append", ["name": "x", "rows": [["a": 1]]])
        #expect(early.isError && early.json["error"] == "not_claimed")
        await env.rig.claim()
        let unknown = await env.call("dataset_append", ["name": "x", "rows": [["a": 1]], "bogus": 1])
        #expect(unknown.isError && unknown.json["error"] == "invalid_argument")
        let empty = await env.call("dataset_append", ["name": "x", "rows": []])
        #expect(empty.isError && empty.json["error"] == "invalid_argument")
        let tooMany = await env.call("dataset_append", ["name": "x", "rows": .array((0...5000).map { ["a": .int($0)] })])
        #expect(tooMany.isError && tooMany.json["error"] == "invalid_argument")
        let badName = await env.call("dataset_define", ["name": "Bad Name", "columns": [["name": "a"]]])
        #expect(badName.isError && badName.json["error"] == "invalid_argument")
        let badType = await env.call("dataset_define", ["name": "x", "columns": [["name": "a", "type": "decimal"]]])
        #expect(badType.isError && badType.json["error"] == "invalid_argument")
        // Criado pelo primeiro append; depois mudar o tipo de uma coluna com linhas é recusado.
        let created = await env.call("dataset_append", ["name": "x", "rows": [["a": 1]]])
        #expect(created.json["created"] == true && created.json["inferred"] != nil)
        let change = await env.call("dataset_define", ["name": "x", "columns": [["name": "a", "type": "string"]]])
        #expect(change.isError && change.json["error"] == "invalid_argument")
    }

    @Test func parentSeesTheSessionsDatasetsAndRolesStaySeparated() async throws {
        let env = try await Env.make(); defer { Task { await env.cleanup() } }
        await env.rig.claim()
        _ = await env.call("dataset_append", ["name": "hotels", "rows": [["name": "Ritz"], ["name": "Plaza"]]])
        let list = await env.call("dataset_list", [:], child: "parent-1")
        #expect(!list.isError && list.json["datasets"]?.array?.count == 1 && list.json["datasets"]?.array?[0]["name"] == "hotels" && list.json["datasets"]?.array?[0]["rows"] == 2)
        let read = await env.call("dataset_read", ["name": "hotels", "limit": 1], child: "parent-1")
        #expect(!read.isError && read.json["returned"] == 1 && read.json["total_rows"] == 2)
        // O pai não anexa; o worker não lista a sessão.
        let append = await env.call("dataset_append", ["name": "hotels", "rows": [["name": "X"]]], child: "parent-1")
        #expect(append.isError && append.json["error"] == "blocked_by_policy")
        let workerList = await env.call("dataset_list")
        #expect(workerList.isError && workerList.json["error"] == "blocked_by_policy")
        // A mesma ferramenta `dataset_read` serve aos dois.
        let workerRead = await env.call("dataset_read", ["name": "hotels"])
        #expect(!workerRead.isError && workerRead.json["total_rows"] == 2)
        let missing = await env.call("dataset_read", ["name": "ghost"], child: "parent-1")
        #expect(missing.isError && missing.json["error"] == "not_found")
    }

    @Test func withoutAStoreTheToolsAreNotSupported() async throws {
        let rig = try await Rig.make(); defer { rig.cleanup() }
        await rig.claim()
        let result = await rig.call("dataset_append", ["name": "x", "rows": [["a": 1]]])
        #expect(result.isError && result.json["error"] == "not_supported")
    }

    @Test func toolListsAndPromptsMentionDatasets() {
        #expect(ToolCatalog.byName["dataset_define"] != nil && ToolCatalog.parentByName["dataset_list"] != nil && ToolCatalog.parentByName["dataset_read"] != nil)
        #expect(ToolCatalog.byName["dataset_list"] == nil)
        #expect(ToolCatalog.serverInstructions.count <= 1500 && ToolCatalog.serverInstructions.contains("dataset_append"))
        #expect(OrchestrationText.workerPrompt.contains("dataset_append") && OrchestrationText.workerPrompt.contains("_request_id") && OrchestrationText.workerPrompt.contains("up to 500"))
    }
}
