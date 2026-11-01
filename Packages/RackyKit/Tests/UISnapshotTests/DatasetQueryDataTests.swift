import RackyProtocol
import RackyStore
import Foundation
import Testing

@testable import RackyUI

/// Camada de dados da página do dataset: pills da barra de consulta, janela do gráfico e perfis de coluna.
@MainActor
@Suite("Datasets - consulta, janela e perfis", .serialized, .offscreenAppKit) struct DatasetQueryDataTests {
    private let columns = [
        DatasetColumn(name: "title"), DatasetColumn(name: "price", type: .integer), DatasetColumn(name: "availability"),
    ]

    @Test func splitFindsPillsAndKeepsRawTokens() {
        let (pills, free) = DatasetSearchText.split(#"plaza price:>20 title:"a b" availability:="In stock" note:x"#, columns: columns)
        #expect(pills.map(\.raw) == ["price:>20", #"title:"a b""#, #"availability:="In stock""#])
        #expect(pills.map(\.column) == ["price", "title", "availability"])
        #expect(pills.map(\.comparison) == [.greater, .contains, .equals])
        #expect(pills.map(\.value) == ["20", "a b", "In stock"])
        #expect(free == "plaza note:x")
        #expect(DatasetSearchText.split("price:", columns: columns).pills.isEmpty)
    }

    @Test func removingAddingAndReplacingRoundTrip() {
        let text = #"plaza price:>20 title:"a b" availability:="In stock""#
        #expect(DatasetSearchText.removing(pillAt: 1, from: text, columns: columns) == #"plaza price:>20 availability:="In stock""#)
        #expect(DatasetSearchText.removing(pillAt: 9, from: text, columns: columns) == text)

        var built = DatasetSearchText.adding(column: "price", comparison: .greater, value: "20", to: "", columns: columns)
        built = DatasetSearchText.adding(column: "title", comparison: .contains, value: "a b", to: built, columns: columns)
        built = DatasetSearchText.adding(column: "availability", comparison: .equals, value: "In stock", to: built, columns: columns)
        #expect(built == #"price:>20 title:"a b" availability:="In stock""#)
        let pills = DatasetSearchText.split(built, columns: columns).pills
        #expect(pills.map(\.comparison) == [.greater, .contains, .equals] && pills.map(\.value) == ["20", "a b", "In stock"])
        // Contains numa coluna numérica mantém o `~`.
        #expect(DatasetSearchText.adding(column: "price", comparison: .contains, value: "2", to: "", columns: columns) == "price:~2")

        let ranged = DatasetSearchText.replacingRange(column: "price", min: 10, max: 99.5, in: "price:>1 plaza price:<=7 title:x", columns: columns)
        #expect(ranged == "plaza title:x price:>=10 price:<=99.5")
        #expect(DatasetSearchText.replacingRange(column: "price", min: nil, max: 5, in: ranged, columns: columns) == "plaza title:x price:<=5")
        #expect(DatasetSearchText.replacingRange(column: "price", min: nil, max: nil, in: ranged, columns: columns) == "plaza title:x")
        #expect(DatasetSearchText.replacingRange(column: "price", min: 1, max: nil, in: "price:=3", columns: columns) == "price:=3 price:>=1", "equals is not a range bound")
    }

    @Test func filterActionsChangeSearchAndRows() async throws {
        let f = try await DatasetsFixture.make()
        defer { f.remove() }
        _ = try await f.registry.perform(.datasetOpen, .select(try await f.datasetID()))
        _ = try await f.registry.perform(.datasetAddFilter, .select("price|>|250"))
        #expect(f.controller.search == "price:>250")
        let high = try #require(f.controller.snapshot).rows.map(\.cells[0])
        #expect(!high.isEmpty && high.count < 30 && f.controller.snapshot?.matching == high.count)
        _ = try await f.registry.perform(.datasetAddFilter, .select("name|=|Hotel 30"))
        #expect(f.controller.search == #"price:>250 name:="Hotel 30""#)
        #expect(f.controller.snapshot?.rows.map(\.cells[0]) == ["Hotel 30"])
        _ = try await f.registry.perform(.datasetRemoveFilter, .select("1"))
        #expect(f.controller.search == "price:>250" && f.controller.snapshot?.matching == high.count)
        _ = try await f.registry.perform(.datasetColumnRange, .select("price|100|130"))
        #expect(f.controller.search == "price:>=100 price:<=130")
        let ranged = try #require(f.controller.snapshot).rows.compactMap { Int($0.cells[2]) }
        #expect(!ranged.isEmpty && ranged.allSatisfy { (100...130).contains($0) })
        let profile = try #require(f.controller.snapshot?.profiles["price"])
        #expect(profile.max ?? 0 > 130, "the profile of price ignores the price range itself")
        _ = try await f.registry.perform(.datasetColumnRange, .select("price||"))
        #expect(f.controller.search == "" && f.controller.snapshot?.matching == 30)
        await #expect(throws: ActionError.self) { _ = try await f.registry.perform(.datasetAddFilter, .select("price|??|1")) }
        await #expect(throws: ActionError.self) { _ = try await f.registry.perform(.datasetRemoveFilter, .select("x")) }
        await #expect(throws: ActionError.self) { _ = try await f.registry.perform(.datasetColumnRange, .select("price|a|b")) }
    }

    @Test func timeWindowNarrowsRowsAndRangeClearsIt() async throws {
        let f = try await DatasetsFixture.make(seed: false)
        defer { f.remove() }
        let dataset = Dataset(
            id: "01TIMED", sessionID: DatasetsFixture.session, name: "timed", columns: [DatasetColumn(name: "n", type: .integer)], key: ["n"], createdAt: DatasetsFixture.t0)
        try await f.store.createDataset(dataset)
        for i in 0..<10 {
            _ = try await f.store.upsertDatasetRows(
                datasetID: dataset.id, rows: [DatasetRowInput(rowKey: "k\(i)", data: #"{"n":\#(i)}"#)], at: DatasetsFixture.t0.addingTimeInterval(Double(i) * 10))
        }
        _ = try await f.registry.perform(.datasetOpen, .select(dataset.id))
        #expect(f.controller.snapshot?.matching == 10)
        let base = DatasetsFixture.t0.timeIntervalSince1970 * 1000
        _ = try await f.registry.perform(.datasetTimeWindow, .select("\(Int(base + 20_000))-\(Int(base + 50_000))"))
        let narrowed = try #require(f.controller.snapshot)
        #expect(narrowed.matching == 4 && narrowed.rows.map(\.cells[0]) == ["5", "4", "3", "2"], "a window is closed on both ends")
        #expect(narrowed.window != nil && f.controller.active?.window == narrowed.window)
        #expect(narrowed.activity.reduce(0) { $0 + $1.valid } == 10, "the chart keeps the whole range")
        #expect(narrowed.profiles["n"]?.filled == 4 && narrowed.profiles["n"]?.min == 2 && narrowed.profiles["n"]?.max == 5)

        _ = try await f.registry.perform(.datasetTimeWindow, .select("clear"))
        #expect(f.controller.snapshot?.matching == 10 && f.controller.snapshot?.window == nil)
        _ = try await f.registry.perform(.datasetTimeWindow, .select("\(Int(base))-\(Int(base + 10_000))"))
        #expect(f.controller.snapshot?.matching == 2)
        _ = try await f.registry.perform(.datasetRange, .select("all"))
        #expect(f.controller.active?.window == nil && f.controller.snapshot?.matching == 10)
        await #expect(throws: ActionError.self) { _ = try await f.registry.perform(.datasetTimeWindow, .select("100-50")) }
    }
}
