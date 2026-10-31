import Foundation
import GRDB
import RackyProtocol
import Testing

@testable import RackyStore

/// Datasets v1: migração `v10_datasets`, upsert/dedupe por chave, filtros e cascata ao apagar a sessão.
@Suite struct DatasetStoreTests {
    private func seeded(_ home: TempHome) async throws -> (RackyStore, Session, Dataset) {
        let store = try await home.openStore()
        let session = Session(kind: .clean, folderPath: "/tmp/ds", title: "ds")
        try await store.save(session)
        let dataset = Dataset(
            id: "01DATASET", sessionID: session.id, name: "hotels",
            columns: [DatasetColumn(name: "name", required: true), DatasetColumn(name: "rating", type: .number)], key: ["name"], createdAt: Fixture.t0)
        try await store.createDataset(dataset)
        return (store, session, dataset)
    }

    private func input(_ key: String, _ data: String, valid: Bool = true) -> DatasetRowInput {
        DatasetRowInput(rowKey: key, data: data, valid: valid, error: valid ? nil : "bad", computer: "c1", trust: .none)
    }

    @Test func migrationIsLastInTheChain() {
        #expect(StoreMigrations.all.last?.id == "v11_subagent_harness")
    }

    @Test func createsAndReadsBackTheSchema() async throws {
        let home = try TempHome(); defer { home.remove() }
        let (store, session, dataset) = try await seeded(home)
        let loaded = try #require(try await store.dataset(sessionID: session.id, name: "hotels"))
        #expect(loaded == dataset)
        #expect(try await store.dataset(id: "01DATASET")?.columns.count == 2)
        // Nome é único por sessão.
        await #expect(throws: (any Error).self) { try await store.createDataset(Dataset(id: "01OTHER", sessionID: session.id, name: "hotels", columns: [], key: [])) }
        try await store.updateDatasetSchema(id: dataset.id, columns: dataset.columns + [DatasetColumn(name: "url", type: .url)], key: ["name"], at: Fixture.t0.addingTimeInterval(5))
        #expect(try await store.dataset(id: dataset.id)?.columns.last?.name == "url")
        try await store.close()
    }

    @Test func upsertCountsInsertedUpdatedAndDuplicate() async throws {
        let home = try TempHome(); defer { home.remove() }
        let (store, _, dataset) = try await seeded(home)
        let t1 = Fixture.t0.addingTimeInterval(10), t2 = Fixture.t0.addingTimeInterval(20), t3 = Fixture.t0.addingTimeInterval(30)
        let first = try await store.upsertDatasetRows(datasetID: dataset.id, rows: [input("a", #"{"name":"A","rating":4}"#), input("b", #"{"name":"B","rating":3}"#)], at: t1)
        #expect(first == DatasetUpsertCounts(inserted: 2, updated: 0, duplicate: 0))
        let second = try await store.upsertDatasetRows(datasetID: dataset.id, rows: [input("a", #"{"name":"A","rating":4}"#), input("b", #"{"name":"B","rating":5}"#), input("c", #"{"name":"C"}"#)], at: t2)
        #expect(second == DatasetUpsertCounts(inserted: 1, updated: 1, duplicate: 1))
        // Duas vezes a mesma chave no mesmo lote: a segunda é duplicata da primeira.
        let same = try await store.upsertDatasetRows(datasetID: dataset.id, rows: [input("d", "{}"), input("d", "{}")], at: t3)
        #expect(same == DatasetUpsertCounts(inserted: 1, updated: 0, duplicate: 1))

        let a = try #require(try await store.datasetRow(datasetID: dataset.id, rowKey: "a"))
        #expect(a.seenCount == 2 && a.firstSeen == t1 && a.lastSeen == t2)
        let b = try #require(try await store.datasetRow(datasetID: dataset.id, rowKey: "b"))
        #expect(b.data.contains("5") && b.seenCount == 2 && b.firstSeen == t1)
        #expect(try await store.dataset(id: dataset.id)?.updatedAt == t3)
        try await store.close()
    }

    @Test func summariesCountRowsAndInvalidOnes() async throws {
        let home = try TempHome(); defer { home.remove() }
        let (store, session, dataset) = try await seeded(home)
        _ = try await store.upsertDatasetRows(datasetID: dataset.id, rows: [input("a", "{}"), input("b", "{}", valid: false), input("c", "{}", valid: false)])
        let summary = try #require(try await store.datasetSummaries(sessionID: session.id).first)
        #expect(summary.rowCount == 3 && summary.invalidCount == 2)
        #expect(try await store.datasetSummaries().count == 1)
        #expect(try await store.datasetSummaries(sessionID: UUID()).isEmpty)
        // Dataset vazio aparece com zero linhas.
        try await store.createDataset(Dataset(id: "01EMPTY", sessionID: session.id, name: "empty", columns: [], key: []))
        let all = try await store.datasetSummaries()
        #expect(all.first { $0.dataset.name == "empty" }?.rowCount == 0)
        try await store.close()
    }

    @Test func rowsPageFilterAndSearch() async throws {
        let home = try TempHome(); defer { home.remove() }
        let (store, _, dataset) = try await seeded(home)
        var rows: [DatasetRowInput] = []
        for i in 0..<25 { rows.append(input("k\(i)", #"{"name":"Hotel \#(i)"}"#, valid: i % 5 != 0)) }
        rows.append(DatasetRowInput(rowKey: "pct", data: #"{"name":"100% real_deal"}"#, sourceURL: "https://example.com/p"))
        _ = try await store.upsertDatasetRows(datasetID: dataset.id, rows: rows)
        #expect(try await store.datasetRowCount(datasetID: dataset.id) == 26)
        #expect(try await store.datasetRowCount(datasetID: dataset.id, filter: .invalid) == 5)
        let page = try await store.datasetRows(datasetID: dataset.id, limit: 10, offset: 10)
        #expect(page.map(\.rowKey) == (10..<20).map { "k\($0)" }, "arrival order, paged")
        #expect(try await store.datasetRows(datasetID: dataset.id, filter: .invalid, limit: 100).count == 5)
        #expect(try await store.datasetRows(datasetID: dataset.id, search: "Hotel 1", limit: 100).count == 11)
        // `%` e `_` são texto, não curinga.
        #expect(try await store.datasetRows(datasetID: dataset.id, search: "100%").map(\.rowKey) == ["pct"])
        #expect(try await store.datasetRows(datasetID: dataset.id, search: "real_deal").count == 1)
        #expect(try await store.datasetRows(datasetID: dataset.id, search: "l_deal").count == 1)
        #expect(try await store.datasetRows(datasetID: dataset.id, search: "example.com").count == 1)
        #expect(try await store.datasetRowCount(datasetID: dataset.id, filter: .invalid, search: "Hotel 5") == 1)
        try await store.close()
    }

    @Test func newestFirstAndActivityBuckets() async throws {
        let home = try TempHome(); defer { home.remove() }
        let (store, _, dataset) = try await seeded(home)
        let t0 = Date(timeIntervalSince1970: 1_900_000_000)
        // 3 linhas no primeiro minuto (1 inválida), 2 no terceiro; nada no segundo.
        _ = try await store.upsertDatasetRows(datasetID: dataset.id, rows: [input("a", "{}"), input("b", "{}"), input("c", "{}", valid: false)], at: t0)
        _ = try await store.upsertDatasetRows(datasetID: dataset.id, rows: [input("d", "{}"), input("e", "{}")], at: t0.addingTimeInterval(130))
        #expect(try await store.datasetRows(datasetID: dataset.id, newestFirst: true).map(\.rowKey) == ["e", "d", "c", "b", "a"])
        let buckets = try await store.datasetActivity(datasetID: dataset.id, until: t0.addingTimeInterval(180), bucket: 60, buckets: 3)
        #expect(buckets.map(\.valid) == [2, 0, 2])
        #expect(buckets.map(\.invalid) == [1, 0, 0])
        #expect(buckets.first?.start == t0)
        // Fora da janela não conta.
        let later = try await store.datasetActivity(datasetID: dataset.id, until: t0.addingTimeInterval(3600), bucket: 60, buckets: 3)
        #expect(later.allSatisfy { $0.valid == 0 && $0.invalid == 0 })
        try await store.close()
    }

    @Test func queryFacetsConditionsRangeAndStats() async throws {
        let home = try TempHome(); defer { home.remove() }
        let (store, _, dataset) = try await seeded(home)
        let t0 = Date(timeIntervalSince1970: 1_900_000_000)
        func row(_ key: String, _ name: String, _ rating: Double?, computer: String, url: String, trust: DatasetTrust, kind: String? = nil) -> DatasetRowInput {
            let data = rating.map { #"{"name":"\#(name)","rating":\#($0)}"# } ?? #"{"name":"\#(name)"}"#
            return DatasetRowInput(
                rowKey: key, data: data, valid: kind == nil, error: kind.map { _ in "rating: required" }, computer: computer, sourceURL: url, trust: trust,
                request: DatasetRequestInfo(method: "GET", status: 200, milliseconds: 412), errorKind: kind)
        }
        _ = try await store.upsertDatasetRows(datasetID: dataset.id, rows: [
            row("a", "Grand Plaza", 4.5, computer: "ta", url: "https://www.tripadvisor.com/a", trust: .observed),
            row("b", "Harbor View", 3.9, computer: "ta", url: "https://www.tripadvisor.com/b", trust: .observed),
        ], at: t0)
        _ = try await store.upsertDatasetRows(datasetID: dataset.id, rows: [
            row("c", "The Ritz", 4.8, computer: "bk", url: "https://booking.com/c", trust: .reported),
            row("d", "Palm Court", nil, computer: "bk", url: "https://booking.com/d", trust: .none, kind: "rating missing"),
        ], at: t0.addingTimeInterval(600))
        // Duplicada: a mesma linha de novo (seen 2x).
        _ = try await store.upsertDatasetRows(datasetID: dataset.id, rows: [row("a", "Grand Plaza", 4.5, computer: "ta", url: "https://www.tripadvisor.com/a", trust: .observed)], at: t0.addingTimeInterval(700))

        func keys(_ q: DatasetQuery) async throws -> [String] { try await store.datasetRows(datasetID: dataset.id, query: q, limit: 50, offset: 0).map(\.rowKey) }
        #expect(try await keys(.all) == ["d", "c", "b", "a"], "newest first")
        #expect(try await keys(DatasetQuery(conditions: [DatasetCondition(column: "rating", comparison: .greaterOrEqual, value: "4.5")])) == ["c", "a"])
        #expect(try await keys(DatasetQuery(conditions: [DatasetCondition(column: "name", comparison: .contains, value: "pla")])) == ["a"])
        #expect(try await keys(DatasetQuery(conditions: [DatasetCondition(column: "name", comparison: .equals, value: "the ritz")])) == ["c"], "text equality ignores case")
        #expect(try await keys(DatasetQuery(excluded: [.computer: ["ta"]])) == ["d", "c"])
        #expect(try await keys(DatasetQuery(excluded: [.status: ["valid"]])) == ["d"])
        #expect(try await keys(DatasetQuery(errorKinds: ["rating missing"])) == ["d"])
        #expect(try await keys(DatasetQuery(text: "harbor")) == ["b"])
        #expect(try await keys(DatasetQuery(since: t0.addingTimeInterval(300))) == ["d", "c"], "range uses first_seen")
        #expect(try await store.datasetRowCount(datasetID: dataset.id, query: DatasetQuery(excluded: [.evidence: ["none"]])) == 3)

        let facets = try await store.datasetFacets(datasetID: dataset.id, query: DatasetQuery(excluded: [.computer: ["ta"]]))
        #expect(facets[.computer] == [DatasetFacetCount(value: "bk", count: 2), DatasetFacetCount(value: "ta", count: 2)], "a facet ignores its own exclusions")
        #expect(facets[.source] == [DatasetFacetCount(value: "booking.com", count: 2)], "the source facet drops www. and applies the computer filter")
        #expect(facets[.status] == [DatasetFacetCount(value: "invalid", count: 1), DatasetFacetCount(value: "valid", count: 1)])
        #expect(facets[.error] == [DatasetFacetCount(value: "rating missing", count: 1)])

        let stats = try await store.datasetStats(datasetID: dataset.id, columns: ["name", "rating"])
        #expect(stats.rows == 4 && stats.invalid == 1 && stats.computers == 2 && stats.duplicatesMerged == 1)
        #expect(abs(stats.filled - 7.0 / 8.0) < 0.0001, "7 of 8 cells are filled")
        let detail = try #require(try await store.datasetRow(datasetID: dataset.id, rowKey: "a"))
        #expect(detail.request == DatasetRequestInfo(method: "GET", status: 200, milliseconds: 412))
        try await store.close()
    }

    @Test func deletingTheSessionCascadesToDatasetsAndRows() async throws {
        let home = try TempHome(); defer { home.remove() }
        let (store, session, dataset) = try await seeded(home)
        _ = try await store.upsertDatasetRows(datasetID: dataset.id, rows: [input("a", "{}")])
        try await store.deleteSession(id: session.id)
        #expect(try await store.dataset(id: dataset.id) == nil)
        #expect(try await store.datasetRows(datasetID: dataset.id).isEmpty)
        try await store.close()
        let db = try DatabaseQueue(path: home.paths.databaseFile.path)
        #expect(try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM dataset_row") } == 0)
    }

    @Test func rowTableRejectsABadTrust() async throws {
        let home = try TempHome(); defer { home.remove() }
        let (store, _, dataset) = try await seeded(home)
        try await store.close()
        let db = try DatabaseQueue(path: home.paths.databaseFile.path)
        await #expect(throws: (any Error).self) {
            try await db.write { try $0.execute(sql: "INSERT INTO dataset_row (dataset_id, row_key, data, valid, trust, first_seen, last_seen) VALUES (?, 'x', '{}', 1, 'bogus', 1, 1)", arguments: [dataset.id]) }
        }
    }
}
