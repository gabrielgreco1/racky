import Foundation
import RackyPlatform
import RackyProtocol
import RackyStore
import Testing

@testable import RackyCore

/// Datasets v1: define / append / import / read / list em cima de um store temporário.
@Suite struct DatasetServiceTests {
    struct Rig {
        let root: URL
        let store: RackyStore
        let service: DatasetService
        let session: UUID

        static func make() async throws -> Rig {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("racky-datasets-\(UUID().uuidString)", isDirectory: true)
            let store = try await RackyStore.open(paths: StorePaths(root: root))
            let session = Session(kind: .clean, folderPath: "/tmp/ds", title: "ds")
            try await store.save(session)
            return Rig(root: root, store: store, service: DatasetService(store: store), session: session.id)
        }

        func cleanup() async { try? await store.close(); try? FileManager.default.removeItem(at: root) }
    }

    static let columns = [DatasetColumn(name: "name", required: true), DatasetColumn(name: "rating", type: .number), DatasetColumn(name: "url", type: .url)]

    private func error(_ body: () async throws -> JSON) async -> ToolError? {
        do { _ = try await body(); return nil } catch { return error as? ToolError }
    }

    @Test func defineIsIdempotentAndProtectsTypesAndKeyOnceThereAreRows() async throws {
        let rig = try await Rig.make(); defer { Task { await rig.cleanup() } }
        let first = try await rig.service.define(session: rig.session, name: "hotels", columns: Self.columns, key: ["name"])
        #expect(first["created"] == true && first["total_rows"] == 0)
        let again = try await rig.service.define(session: rig.session, name: "hotels", columns: Self.columns, key: ["name"])
        #expect(again["created"] == false)
        let extended = try await rig.service.define(session: rig.session, name: "hotels", columns: [DatasetColumn(name: "city")], key: nil)
        #expect(extended["columns"]?.array?.count == 4 && extended["key"] == ["name"])

        _ = try await rig.service.append(session: rig.session, name: "hotels", rows: [["name": "Ritz"]], provenance: .none)
        let typeChange = await error { try await rig.service.define(session: rig.session, name: "hotels", columns: [DatasetColumn(name: "rating", type: .string)], key: nil) }
        #expect(typeChange?.code == .invalidArgument)
        let keyChange = await error { try await rig.service.define(session: rig.session, name: "hotels", columns: [], key: ["name", "city"]) }
        #expect(keyChange?.code == .invalidArgument)
        let badName = await error { try await rig.service.define(session: rig.session, name: "Bad Name", columns: [], key: nil) }
        #expect(badName?.code == .invalidArgument)
        let badKey = await error { try await rig.service.define(session: rig.session, name: "x", columns: [DatasetColumn(name: "a")], key: ["b"]) }
        #expect(badKey?.code == .invalidArgument)
    }

    @Test func appendCountsInsertedUpdatedDuplicateAndInvalid() async throws {
        let rig = try await Rig.make(); defer { Task { await rig.cleanup() } }
        _ = try await rig.service.define(session: rig.session, name: "hotels", columns: Self.columns, key: ["name"])
        let r1 = try await rig.service.append(
            session: rig.session, name: "hotels",
            rows: [["name": "Ritz", "rating": "4.5", "extra": 1], ["name": "Plaza", "rating": "4,5"], ["rating": 3], ["name": "Ritz", "rating": 4.5, "x": 1]], provenance: .none)
        // Ritz duas vezes no lote: a segunda é duplicata; Plaza (rating inválido) e a linha sem nome ficam armazenadas como inválidas.
        #expect(r1["inserted"] == 3 && r1["duplicate"] == 1 && r1["updated"] == 0 && r1["invalid"] == 2 && r1["total_rows"] == 3)
        let warnings = r1["warnings"]?.array?.compactMap(\.string) ?? []
        #expect(warnings.count == 1 && warnings[0].contains("unknown columns dropped: extra, x"), "dropped columns are reported once")
        #expect(r1["invalid_examples"]?.array?.count == 2)

        let r2 = try await rig.service.append(session: rig.session, name: "hotels", rows: [["name": "Ritz", "rating": 5], ["name": "Plaza", "rating": 4.5]], provenance: .none)
        #expect(r2["updated"] == 2 && r2["inserted"] == 0, "correcting Plaza replaces the invalid row")
        let summary = try #require(try await rig.store.datasetSummaries(sessionID: rig.session).first)
        #expect(summary.rowCount == 3 && summary.invalidCount == 1)
    }

    @Test func appendToAMissingDatasetInfersTheSchemaAndSaysSo() async throws {
        let rig = try await Rig.make(); defer { Task { await rig.cleanup() } }
        let result = try await rig.service.append(session: rig.session, name: "auto", rows: [["name": "A", "stars": 5, "rating": 4.5]], provenance: .none)
        #expect(result["created"] == true && result["inserted"] == 1)
        #expect(result["inferred"]?["columns"]?.array?.count == 3)
        let dataset = try #require(try await rig.store.dataset(sessionID: rig.session, name: "auto"))
        #expect(dataset.columns.map(\.type) == [.string, .number, .integer] && dataset.key.isEmpty)
        let note = result["warnings"]?.array?.first?.string ?? ""
        #expect(note.contains("did not exist"))
        // Sem chave: linha idêntica é duplicata.
        let again = try await rig.service.append(session: rig.session, name: "auto", rows: [["name": "A", "stars": 5, "rating": 4.5]], provenance: .none)
        #expect(again["duplicate"] == 1)
        let missing = await error { try await rig.service.append(session: rig.session, name: "ghost", rows: [], provenance: .none) }
        #expect(missing?.code == .notFound)
    }

    @Test func limitsAreEnforced() async throws {
        let rig = try await Rig.make(); defer { Task { await rig.cleanup() } }
        _ = try await rig.service.define(session: rig.session, name: "big", columns: [DatasetColumn(name: "n", type: .integer)], key: ["n"])
        let tooMany = await error { try await rig.service.append(session: rig.session, name: "big", rows: (0...5000).map { ["n": .int($0)] }, provenance: .none) }
        #expect(tooMany?.code == .invalidArgument)
        let exactly = try await rig.service.append(session: rig.session, name: "big", rows: (0..<5000).map { ["n": .int($0)] }, provenance: .none)
        #expect(exactly["inserted"] == 5000 && exactly["total_rows"] == 5000)
    }

    @Test func provenanceComesFromTheReqlogOrFallsBackToNone() async throws {
        let rig = try await Rig.make(); defer { Task { await rig.cleanup() } }
        _ = try await rig.service.define(session: rig.session, name: "hotels", columns: Self.columns, key: ["name"])
        let known = "01ARZ3NDEKTSV4RRFFQ69G5FAV", reported = "01ARZ3NDEKTSV4RRFFQ69G5FAW", ghost = "01ARZ3NDEKTSV4RRFFQ69G5FAX"
        let provenance = DatasetProvenance(computer: "phoenix", runID: "RUN1") { id in
            switch id {
            case known: .init(url: "https://hotels.test/ritz", trust: .observed, info: DatasetRequestInfo(method: "GET", status: 200, milliseconds: 412))
            case reported: .init(url: "https://hotels.test/plaza", trust: .reported)
            default: nil
            }
        }
        let result = try await rig.service.append(
            session: rig.session, name: "hotels",
            rows: [
                ["name": "Ritz", "_request_id": .string(known), "_source_url": "https://ignored.test"], ["name": "Plaza", "_request_id": .string(reported)],
                ["name": "Ghost", "_request_id": .string(ghost), "_source_url": "https://claimed.test"], ["name": "Odd", "_request_id": "not-a-ulid"], ["name": "Plain"],
            ], provenance: provenance)
        #expect(result["inserted"] == 5)
        let notFound = (result["warnings"]?.array ?? []).compactMap(\.string).filter { $0.contains("2 _request_id value(s) were not found") }
        #expect(notFound.count == 1)
        func row(_ name: String) async throws -> DatasetRow {
            let key = DatasetEngine.rowKey(key: ["name"], data: ["name": .string(name)])
            let dataset = try #require(try await rig.store.dataset(sessionID: rig.session, name: "hotels"))
            return try #require(try await rig.store.datasetRow(datasetID: dataset.id, rowKey: key))
        }
        let ritz = try await row("Ritz")
        #expect(ritz.trust == .observed && ritz.requestID == known && ritz.sourceURL == "https://hotels.test/ritz" && ritz.computer == "phoenix" && ritz.runID == "RUN1")
        #expect(ritz.request == DatasetRequestInfo(method: "GET", status: 200, milliseconds: 412), "method, status and time come from the reqlog")
        #expect(try await row("Plaza").trust == .reported)
        let ghostRow = try await row("Ghost")
        #expect(ghostRow.trust == .none && ghostRow.requestID == nil && ghostRow.sourceURL == "https://claimed.test", "unknown request id: stored, trust none, own url kept")
        let odd = try await row("Odd"), plain = try await row("Plain")
        #expect(odd.trust == .none && plain.sourceURL == nil)
    }

    @Test func importCSVCreatesTheDatasetAndTakesTheSourceFromTheUrlColumn() async throws {
        let rig = try await Rig.make(); defer { Task { await rig.cleanup() } }
        let csv = "Name,Rating,URL\n\"Ritz, Paris\",4.5,https://hotels.test/ritz\nPlaza,,https://hotels.test/plaza\n"
        let parsed = try DatasetImportParser.parse(Data(csv.utf8), format: .csv)
        let result = try await rig.service.importRows(session: rig.session, name: "imp", parsed: parsed, format: .csv, provenance: DatasetProvenance(computer: "phoenix"))
        #expect(result["inserted"] == 2 && result["created"] == true && result["format"] == "csv" && result["rows_read"] == 2)
        let dataset = try #require(try await rig.store.dataset(sessionID: rig.session, name: "imp"))
        #expect(dataset.columns.map(\.name) == ["name", "rating", "url"])
        let rows = try await rig.store.datasetRows(datasetID: dataset.id)
        #expect(rows.map(\.sourceURL) == ["https://hotels.test/ritz", "https://hotels.test/plaza"] && rows.allSatisfy { $0.trust == .none && $0.computer == "phoenix" })
        // Importar de novo: tudo duplicata.
        let again = try await rig.service.importRows(session: rig.session, name: "imp", parsed: parsed, format: .csv, provenance: .none)
        #expect(again["duplicate"] == 2 && again["inserted"] == 0 && again["total_rows"] == 2)
    }

    @Test func importKeepsBrokenJSONLinesAsInvalidRowsAndChunksBigFiles() async throws {
        let rig = try await Rig.make(); defer { Task { await rig.cleanup() } }
        var text = "{\"n\":1}\nnot json\n"
        for i in 2..<6001 { text += "{\"n\":\(i)}\n" }
        let parsed = try DatasetImportParser.parse(Data(text.utf8), format: .jsonl)
        let result = try await rig.service.importRows(session: rig.session, name: "lines", parsed: parsed, format: .jsonl, provenance: .none)
        #expect(result["inserted"] == 6001 && result["invalid"] == 1 && result["total_rows"] == 6001)
        let dataset = try #require(try await rig.store.dataset(sessionID: rig.session, name: "lines"))
        let invalid = try await rig.store.datasetRows(datasetID: dataset.id, filter: .invalid)
        #expect(invalid.count == 1 && invalid[0].error?.contains("line 2") == true)
    }

    @Test func readPagesAndCapsAt500AndListSummarisesTheSession() async throws {
        let rig = try await Rig.make(); defer { Task { await rig.cleanup() } }
        _ = try await rig.service.define(session: rig.session, name: "n", columns: [DatasetColumn(name: "n", type: .integer, required: true)], key: ["n"])
        _ = try await rig.service.append(session: rig.session, name: "n", rows: (0..<700).map { ["n": .int($0)] } + [["n": "x"]], provenance: DatasetProvenance(computer: "c"))
        let page = try await rig.service.read(session: rig.session, name: "n", limit: 9999, offset: 10, invalidOnly: false)
        #expect(page["returned"] == 500 && page["total_rows"] == 701 && page["invalid_rows"] == 1 && page["rows"]?.array?[0]["data"]?["n"] == 10)
        let invalid = try await rig.service.read(session: rig.session, name: "n", limit: nil, offset: nil, invalidOnly: true)
        #expect(invalid["returned"] == 1 && invalid["rows"]?.array?[0]["valid"] == false && invalid["rows"]?.array?[0]["error"]?.string?.contains("n: expected an integer") == true)
        let list = try await rig.service.list(session: rig.session)
        #expect(list["datasets"]?.array?.count == 1 && list["datasets"]?.array?[0]["rows"] == 701 && list["datasets"]?.array?[0]["invalid"] == 1)
        let other = try await rig.service.list(session: UUID())
        #expect(other["datasets"]?.array?.isEmpty == true)
        let missing = await error { try await rig.service.read(session: UUID(), name: "n", limit: nil, offset: nil, invalidOnly: false) }
        #expect(missing?.code == .notFound)
    }
}

extension DatasetServiceTests {
    @Test func exportWritesOnlyValidRowsInEveryFormat() async throws {
        let rig = try await Rig.make(); defer { Task { await rig.cleanup() } }
        _ = try await rig.service.define(session: rig.session, name: "hotels", columns: Self.columns, key: ["name"])
        _ = try await rig.service.append(session: rig.session, name: "hotels", rows: (0..<4000).map { ["name": .string("H\($0)"), "rating": 4] }, provenance: .none)
        _ = try await rig.service.append(session: rig.session, name: "hotels", rows: (4000..<6001).map { ["name": .string("H\($0)"), "rating": 4] } + [["rating": 1]], provenance: .none)
        let dataset = try #require(try await rig.store.dataset(sessionID: rig.session, name: "hotels"))
        for format in DatasetExporter.Format.allCases {
            let url = rig.root.appendingPathComponent(DatasetExporter.suggestedName(dataset: "hotels", format: format))
            let count = try await DatasetExporter.write(store: rig.store, dataset: dataset, format: format, to: url)
            #expect(count == 6001, "the invalid row stays out of the file (\(format))")
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text.contains("H6000") && !text.contains("\"rating\":1}"))
        }
        let csv = try String(contentsOf: rig.root.appendingPathComponent("hotels.csv"), encoding: .utf8)
        #expect(csv.hasPrefix("name,rating,url\r\nH0,4,\r\n"))
    }
}
