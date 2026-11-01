import Foundation
import RackyStore
import Testing

@testable import RackyCore

/// Datasets v1: validação, coerção, chave estável, esquema inferido e evolução.
@Suite struct DatasetEngineTests {
    static let hotels = Dataset(
        id: "01D", sessionID: UUID(), name: "hotels",
        columns: [
            DatasetColumn(name: "name", type: .string, required: true), DatasetColumn(name: "rating", type: .number), DatasetColumn(name: "stars", type: .integer),
            DatasetColumn(name: "open", type: .boolean), DatasetColumn(name: "since", type: .date), DatasetColumn(name: "seen", type: .datetime),
            DatasetColumn(name: "url", type: .url), DatasetColumn(name: "meta", type: .json),
        ], key: ["name"])

    @Test func errorKindIsShortAndGroupable() {
        #expect(DatasetEngine.errorKind(nil) == nil)
        #expect(DatasetEngine.errorKind("price: required") == "price missing")
        #expect(DatasetEngine.errorKind(#"rating: expected a number, got "four"; price: required"#) == "rating not a number")
        #expect(DatasetEngine.errorKind("row is larger than 1 MiB") == "row too large")
        // A mensagem real do motor vira o mesmo tipo, qualquer que seja o valor.
        let dataset = Dataset(id: "d", sessionID: UUID(), name: "h", columns: [DatasetColumn(name: "rating", type: .number)], key: [])
        let a = DatasetEngine.process(["rating": "four"], dataset: dataset)
        let b = DatasetEngine.process(["rating": "five"], dataset: dataset)
        #expect(!a.valid && DatasetEngine.errorKind(a.error) == DatasetEngine.errorKind(b.error))
    }

    @Test func namesFollowTheSlugAndColumnRules() {
        #expect(DatasetEngine.isValidName("hotels-2026_a") && DatasetEngine.isValidName(String(repeating: "a", count: 64)))
        #expect(!DatasetEngine.isValidName("") && !DatasetEngine.isValidName("Hotels") && !DatasetEngine.isValidName("a b") && !DatasetEngine.isValidName(String(repeating: "a", count: 65)))
        #expect(DatasetEngine.isValidColumnName("price_usd") && !DatasetEngine.isValidColumnName("_request_id") && !DatasetEngine.isValidColumnName("1st") && !DatasetEngine.isValidColumnName("a-b"))
        #expect(DatasetEngine.normalizedColumnName(" Hotel Name ") == "hotel_name" && DatasetEngine.normalizedColumnName("Price ($)") == "price")
    }

    @Test func coercesNumbersFromTextButKeepsCommaDecimalsInvalid() {
        #expect(DatasetEngine.coerce("12", to: .integer) == .success(.int(12)))
        #expect(DatasetEngine.coerce(.double(12), to: .integer) == .success(.int(12)))
        if case .failure = DatasetEngine.coerce(.double(12.5), to: .integer) {} else { Issue.record("12.5 is not an integer") }
        #expect(DatasetEngine.coerce("4.5", to: .number) == .success(.double(4.5)))
        #expect(DatasetEngine.coerce("4.0", to: .number) == .success(.int(4)), "4.0 and 4 are the same number")
        if case .failure = DatasetEngine.coerce("4,5", to: .number) {} else { Issue.record("4,5 must stay invalid") }
        if case .failure = DatasetEngine.coerce("1,234", to: .number) {} else { Issue.record("thousands separator must stay invalid") }
        if case .failure = DatasetEngine.coerce("abc", to: .integer) {} else { Issue.record("abc") }
        if case .failure = DatasetEngine.coerce("NaN", to: .number) {} else { Issue.record("NaN") }
        #expect(DatasetEngine.coerce(.int(7), to: .string) == .success(.string("7")))
        #expect(DatasetEngine.coerce("yes", to: .boolean) == .success(.bool(true)) && DatasetEngine.coerce("0", to: .boolean) == .success(.bool(false)))
        #expect(DatasetEngine.coerce(.null, to: .integer) == .success(nil) && DatasetEngine.coerce("  ", to: .url) == .success(nil))
    }

    @Test func datesUrlsAndJSON() {
        #expect(DatasetEngine.coerce("2026-10-20", to: .date) == .success(.string("2026-10-20")))
        for bad in ["2026-02-30", "20/10/2026", "2026-13-01", "2026-10-20T10:00"] {
            if case .failure = DatasetEngine.coerce(.string(bad), to: .date) {} else { Issue.record("\(bad) is not a date") }
        }
        #expect(DatasetEngine.coerce("2026-10-20 14:30:05Z", to: .datetime) == .success(.string("2026-10-20T14:30:05Z")))
        #expect(DatasetEngine.coerce("2026-10-20T14:30:05.123+02:00", to: .datetime) == .success(.string("2026-10-20T14:30:05.123+02:00")))
        for bad in ["2026-10-20", "2026-10-20T25:00", "yesterday"] {
            if case .failure = DatasetEngine.coerce(.string(bad), to: .datetime) {} else { Issue.record("\(bad) is not a datetime") }
        }
        #expect(DatasetEngine.coerce("https://example.com/a?b=1", to: .url) == .success(.string("https://example.com/a?b=1")))
        for bad in ["ftp://example.com", "example.com", "javascript:alert(1)", "https://exa mple.com", "https://"] {
            if case .failure = DatasetEngine.coerce(.string(bad), to: .url) {} else { Issue.record("\(bad) is not an http(s) URL") }
        }
        #expect(DatasetEngine.coerce(#"{"a":1}"#, to: .json) == .success(["a": 1]))
        #expect(DatasetEngine.coerce("plain", to: .json) == .success("plain"))
    }

    @Test func processDropsUnknownColumnsAndFlagsInvalidRowsWithoutLosingThem() {
        let ok = DatasetEngine.process(["name": "Ritz", "rating": "4.5", "stars": 5, "colour": "red", "_request_id": "X", "_source_url": "https://a.test"], dataset: Self.hotels)
        #expect(ok.valid && ok.error == nil && ok.droppedColumns == ["colour"])
        #expect(ok.data == ["name": "Ritz", "rating": 4.5, "stars": 5])
        #expect(ok.requestID == "X" && ok.sourceURL == "https://a.test")

        let missing = DatasetEngine.process(["rating": 4], dataset: Self.hotels)
        #expect(!missing.valid && missing.error == "name: required")

        let bad = DatasetEngine.process(["name": "Ritz", "rating": "4,5", "url": "ftp://x"], dataset: Self.hotels)
        #expect(!bad.valid && bad.error?.contains("rating: expected a number") == true && bad.error?.contains("url: expected an http(s) URL") == true)
        // A chave está saudável: corrigir a linha depois substitui esta.
        #expect(bad.rowKey == DatasetEngine.process(["name": "Ritz", "rating": 4.5], dataset: Self.hotels).rowKey)
    }

    @Test func invalidRowsWithoutAKeyDoNotCollapseIntoOne() {
        let a = DatasetEngine.process(["rating": 1], dataset: Self.hotels), b = DatasetEngine.process(["rating": 2], dataset: Self.hotels)
        #expect(a.rowKey != b.rowKey)
        #expect(a.rowKey == DatasetEngine.process(["rating": 1], dataset: Self.hotels).rowKey, "and it is stable")
    }

    @Test func rowKeyIsStableAcrossKeyAndFieldOrder() {
        let a = DatasetEngine.rowKey(key: ["city", "name"], data: ["name": "Ritz", "city": "Paris", "x": 1])
        let b = DatasetEngine.rowKey(key: ["name", "city"], data: ["x": 2, "city": "Paris", "name": "Ritz"])
        #expect(a == b && a.count == 64)
        #expect(a != DatasetEngine.rowKey(key: ["city", "name"], data: ["name": "Ritz", "city": "Lyon"]))
        // Chave vazia: a linha inteira.
        let whole = DatasetEngine.rowKey(key: [], data: ["a": 1, "b": "x"])
        #expect(whole == DatasetEngine.rowKey(key: [], data: ["b": "x", "a": 1]) && whole != DatasetEngine.rowKey(key: [], data: ["a": 1, "b": "y"]))
    }

    @Test func oversizedRowsAreStoredInvalid() {
        let dataset = Dataset(id: "x", sessionID: UUID(), name: "big", columns: [DatasetColumn(name: "k"), DatasetColumn(name: "blob")], key: ["k"])
        let row = DatasetEngine.process(["k": "a", "blob": .string(String(repeating: "x", count: DatasetEngine.maxRowBytes + 1))], dataset: dataset)
        #expect(!row.valid && row.error == "row is larger than 1 MiB" && row.data.isEmpty)
    }

    @Test func inferColumnsPicksNativeTypes() {
        let columns = DatasetEngine.inferColumns(from: ["name": "Ritz", "stars": 5, "rating": 4.5, "open": true, "tags": ["a"], "_request_id": "x", "bad-name": 1])
        #expect(columns.map(\.name) == ["name", "open", "rating", "stars", "tags"])
        #expect(columns.map(\.type) == [.string, .boolean, .number, .integer, .json])
    }

    @Test func evolveAddsColumnsButProtectsTypesAndKeyOnceThereAreRows() throws {
        let base = Dataset(id: "x", sessionID: UUID(), name: "h", columns: [DatasetColumn(name: "name"), DatasetColumn(name: "rating", type: .number)], key: ["name"])
        let added = try DatasetEngine.evolve(existing: base, columns: [DatasetColumn(name: "url", type: .url)], key: nil, hasRows: true).get()
        #expect(added.columns.map(\.name) == ["name", "rating", "url"] && added.key == ["name"])
        // Mesma definição de novo: nada muda (idempotente).
        let same = try DatasetEngine.evolve(existing: base, columns: base.columns, key: ["name"], hasRows: true).get()
        #expect(same.columns == base.columns && same.key == base.key)
        if case .success = DatasetEngine.evolve(existing: base, columns: [DatasetColumn(name: "rating", type: .string)], key: nil, hasRows: true) { Issue.record("type change with rows") }
        if case .success = DatasetEngine.evolve(existing: base, columns: [], key: ["rating"], hasRows: true) { Issue.record("key change with rows") }
        #expect((try? DatasetEngine.evolve(existing: base, columns: [DatasetColumn(name: "rating", type: .string)], key: ["rating"], hasRows: false).get()) != nil, "free while empty")
        if case .success = DatasetEngine.evolve(existing: base, columns: [], key: ["ghost"], hasRows: false) { Issue.record("unknown key column") }
    }
}
