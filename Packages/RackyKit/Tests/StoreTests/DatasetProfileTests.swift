import Foundation
import RackyProtocol
import Testing

@testable import RackyStore

/// Dados novos da página do dataset: classes de status, sites, janela `until` e perfis por coluna.
@Suite struct DatasetProfileTests {
    private let columns = [
        DatasetColumn(name: "name"), DatasetColumn(name: "price", type: .integer), DatasetColumn(name: "stock"), DatasetColumn(name: "note"),
    ]

    private func seeded(_ home: TempHome) async throws -> (RackyStore, Dataset) {
        let store = try await home.openStore()
        let session = Session(kind: .clean, folderPath: "/tmp/ds", title: "ds")
        try await store.save(session)
        let dataset = Dataset(id: "01PROFILE", sessionID: session.id, name: "hotels", columns: columns, key: ["name"], createdAt: Fixture.t0)
        try await store.createDataset(dataset)
        return (store, dataset)
    }

    private func row(_ i: Int, status: Int?, request: String?, host: String?) -> DatasetRowInput {
        let stock = i % 2 == 0 ? "In stock" : "Sold out"
        return DatasetRowInput(
            rowKey: "r\(i)", data: #"{"name":"N\#(i)","price":\#(i * 10),"stock":"\#(stock)","note":"unique \#(i)"}"#, valid: true, computer: "c1",
            requestID: request, sourceURL: host.map { "https://\($0)/p/\(i)" }, trust: .none,
            request: status.map { DatasetRequestInfo(method: "GET", status: $0, milliseconds: 100) })
    }

    @Test func requestStatusClassesAndTopHosts() async throws {
        let home = try TempHome(); defer { home.remove() }
        let (store, dataset) = try await seeded(home)
        // r0,r1 compartilham a request A (200); B 301; C 404; D 500; E sem status; F sem request.
        let rows = [
            row(0, status: 200, request: "A", host: "a.test"), row(1, status: 200, request: "A", host: "a.test"),
            row(2, status: 301, request: "B", host: "a.test"), row(3, status: 404, request: "C", host: "b.test"),
            row(4, status: 500, request: "D", host: "b.test"), row(5, status: nil, request: "E", host: "c.test"),
            row(6, status: nil, request: nil, host: nil),
        ]
        _ = try await store.upsertDatasetRows(datasetID: dataset.id, rows: rows)
        let stats = try await store.datasetStats(datasetID: dataset.id, columns: ["name"])
        #expect(stats.requestStatus == [2: 1, 3: 1, 4: 1, 5: 1])
        #expect(stats.topHosts == [DatasetHostCount(host: "a.test", rows: 3), DatasetHostCount(host: "b.test", rows: 2), DatasetHostCount(host: "c.test", rows: 1)])
        // Mais de 5 sites: só os 5 primeiros.
        let many = (10..<18).map { row($0, status: 200, request: "X\($0)", host: "h\($0).test") }
        _ = try await store.upsertDatasetRows(datasetID: dataset.id, rows: many)
        #expect(try await store.datasetStats(datasetID: dataset.id, columns: ["name"]).topHosts.count == 5)
        try await store.close()
    }

    @Test func untilIsAnExclusiveUpperBound() async throws {
        let home = try TempHome(); defer { home.remove() }
        let (store, dataset) = try await seeded(home)
        for i in 0..<3 { _ = try await store.upsertDatasetRows(datasetID: dataset.id, rows: [row(i, status: nil, request: nil, host: nil)], at: Fixture.t0.addingTimeInterval(Double(i) * 10)) }
        var query = DatasetQuery(until: Fixture.t0.addingTimeInterval(20))
        #expect(try await store.datasetRowCount(datasetID: dataset.id, query: query) == 2)
        query.since = Fixture.t0.addingTimeInterval(10)
        #expect(try await store.datasetRows(datasetID: dataset.id, query: query, limit: 10, offset: 0).map(\.rowKey) == ["r1"])
        try await store.close()
    }

    @Test func columnProfilesTopValuesAndNumericHistogram() async throws {
        let home = try TempHome(); defer { home.remove() }
        let (store, dataset) = try await seeded(home)
        var rows = (0..<48).map { row($0, status: nil, request: nil, host: nil) }
        rows.append(DatasetRowInput(rowKey: "empty", data: #"{"name":"E","stock":""}"#))
        rows.append(DatasetRowInput(rowKey: "text", data: #"{"name":"T","price":"ninety","stock":"In stock"}"#, valid: false))
        _ = try await store.upsertDatasetRows(datasetID: dataset.id, rows: rows)
        let profiles = try await store.datasetColumnProfiles(datasetID: dataset.id, columns: columns, query: .all)

        let stock = try #require(profiles["stock"])
        #expect(stock.filled == 49 && stock.distinct == 2)
        #expect(stock.topValues == [DatasetValueCount(value: "In stock", count: 25), DatasetValueCount(value: "Sold out", count: 24)])
        #expect(try #require(profiles["note"]).distinct == 48 && profiles["note"]?.topValues.isEmpty == true, "high cardinality has no values facet")
        #expect(profiles["name"]?.topValues.isEmpty == true, "50 distinct names")

        let price = try #require(profiles["price"])
        #expect(price.min == 0 && price.max == 470 && price.topValues.isEmpty)
        #expect(price.histogram.count == 24 && price.histogram.reduce(0, +) == 48, "only numeric cells are binned; 'ninety' is not")
        #expect(price.histogram.last ?? 0 >= 1, "the maximum lands in the last bin")
        try await store.close()
    }

    @Test func profileIgnoresItsOwnColumnConditionButHonorsOthers() async throws {
        let home = try TempHome(); defer { home.remove() }
        let (store, dataset) = try await seeded(home)
        _ = try await store.upsertDatasetRows(datasetID: dataset.id, rows: (0..<10).map { row($0, status: nil, request: nil, host: nil) })
        let query = DatasetQuery(conditions: [
            DatasetCondition(column: "stock", comparison: .equals, value: "In stock"), DatasetCondition(column: "price", comparison: .less, value: "50"),
        ])
        let profiles = try await store.datasetColumnProfiles(datasetID: dataset.id, columns: columns, query: query)
        // price < 50 (r0..r4) restringe stock; o filtro de stock não restringe stock mas restringe price.
        #expect(profiles["stock"]?.filled == 5 && profiles["stock"]?.topValues.map(\.count) == [3, 2])
        #expect(profiles["price"]?.filled == 5 && profiles["price"]?.max == 80, "price ignores price<50 but keeps stock=In stock (r0,r2,r4,r6,r8)")
        try await store.close()
    }
}
