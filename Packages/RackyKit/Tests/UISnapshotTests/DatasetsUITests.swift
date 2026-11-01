import RackyCore
import RackyDesignSystem
import RackyPlatform
import RackyProtocol
import RackyStore
import AppKit
import Foundation
import SnapshotTesting
import SwiftUI
import Testing

@testable import RackyUI

/// Fixture dos testes de datasets: um store temporário com a tabela de hotéis (30 linhas, 2 inválidas, proveniência no reqlog de um
/// computador) e o `DatasetsController` ligado a um registro de ações de teste.
@MainActor
struct DatasetsFixture {
    static let session = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    /// Instante fixo do relógio do store e dos textos de data (as imagens não mudam com a hora em que o teste roda).
    nonisolated static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let observed = "01ARZ3NDEKTSV4RRFFQ69G5FAV", reported = "01ARZ3NDEKTSV4RRFFQ69G5FAW"

    let root: URL
    let store: RackyStore
    let controller = DatasetsController()
    let registry: ActionRegistry
    let service: DatasetService

    static func make(automation: Bool = true, seed: Bool = true) async throws -> DatasetsFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("racky-datasets-ui-\(UUID().uuidString.lowercased())", isDirectory: true)
        let store = try await RackyStore.open(paths: StorePaths(root: root), clock: { Self.t0 })
        try await store.save(Session(id: session, kind: .clean, folderPath: "/tmp/hotels", title: "Hotel prices", createdAt: Self.t0))
        let registry = ActionRegistry(flags: SliceFlags(current: .slice3), surface: FakeSurface())
        let fixture = DatasetsFixture(root: root, store: store, registry: registry, service: DatasetService(store: store))
        fixture.controller.sessionTitle = { $0 == session ? "Hotel prices" : nil }
        fixture.controller.automationEnabled = automation
        fixture.controller.now = { t0.addingTimeInterval(190) }
        fixture.controller.timeZone = TimeZone(identifier: "UTC")!
        fixture.controller.locale = Locale(identifier: "en_US")
        try fixture.controller.register(in: registry)
        try? registry.register(.computerOpenEvidence) { _ in nil }
        await fixture.controller.attach(store: store)
        if seed { try await fixture.seedHotels() }
        return fixture
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    /// `hotels`: 30 linhas (name, rating, price, url), duas com preço inválido; as duas primeiras citam requests do reqlog do `phoenix-az`.
    func seedHotels() async throws {
        try await Self.seedHotels(service: service, session: Self.session)
        await controller.reloadList()
    }

    static func seedHotels(service: DatasetService, session: UUID) async throws {
        _ = try await service.define(
            session: session, name: "hotels",
            columns: [
                DatasetColumn(name: "name", required: true), DatasetColumn(name: "rating", type: .number), DatasetColumn(name: "price", type: .integer),
                DatasetColumn(name: "url", type: .url),
            ], key: ["name"])
        let provenance = DatasetProvenance(computer: "phoenix-az", runID: "01ARZ3NDEKTSV4RRFFQ69G5RUN") { id in
            switch id {
            case observed: .init(url: "https://hotels.example.test/grand-plaza", trust: .observed)
            case reported: .init(url: "https://hotels.example.test/hotel-2", trust: .reported)
            default: nil
            }
        }
        let names = ["Grand Plaza", "Harbor View", "Maple Inn", "Skyline Suites", "The Ritz", "Cedar Lodge", "Lakeside Hotel", "Union Square Stay", "Palm Court", "Old Town Inn"]
        var rows: [[String: JSON]] = []
        for i in 0..<30 {
            var row: [String: JSON] = [
                "name": .string(i < names.count ? names[i] : "Hotel \(i + 1)"), "rating": .double(3.0 + Double(i % 20) / 10), "price": .int(90 + i * 7),
                "url": .string("https://hotels.example.test/hotel-\(i + 1)"),
            ]
            if i == 0 { row["_request_id"] = .string(observed) }
            if i == 1 { row["_request_id"] = .string(reported) }
            if i == 7 || i == 19 { row["price"] = "ninety" }
            rows.append(row)
        }
        _ = try await service.append(session: session, name: "hotels", rows: rows, provenance: provenance)
    }

    func datasetID() async throws -> String { try #require(try await store.dataset(sessionID: Self.session, name: "hotels")).id }

    func render(_ view: some View, size: CGSize, name: String, line: UInt = #line) {
        DSFonts.registerIfNeeded()
        let previous = MotionPolicy.shared.preference
        MotionPolicy.shared.preference = .on
        defer { MotionPolicy.shared.preference = previous }
        let content = view.environment(\.actionRegistry, registry).environment(\.elementStore, UIElementStore()).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: content.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        withSnapshotTesting(record: ComponentSnapshotTests.recording) {
            assertSnapshot(of: host, as: .image(precision: 0.98, perceptualPrecision: 0.97), named: name, testName: "datasets", line: line)
        }
    }
}

@MainActor
@Suite("Datasets - lista, tabela viva, proveniência e exportação", .serialized, .offscreenAppKit)
struct DatasetsUITests {
    @Test func openingADatasetLoadsTheTableWithItsSummary() async throws {
        let f = try await DatasetsFixture.make()
        defer { f.remove() }
        #expect(f.controller.summaries.count == 1 && f.controller.summaries[0].rowCount == 30 && f.controller.summaries[0].invalidCount == 2)
        let id = try await f.datasetID()
        var shown: [CenterPage] = []
        f.controller.showPage = { shown.append($0) }
        let reply = try await f.registry.perform(.datasetOpen, .select(id))
        #expect(reply.message == id && shown == [.dataset(id)])
        let snapshot = try #require(f.controller.snapshot)
        #expect(snapshot.rows.count == 30 && snapshot.matching == 30 && snapshot.summary.invalidCount == 2)
        #expect(snapshot.rows.last?.cells == ["Grand Plaza", "3", "90", "https://hotels.example.test/hotel-1"], "cells follow the schema order: 3.0 prints as 3, not 3.0")
        #expect(snapshot.rows.first?.cells.first == "Hotel 30", "the live table shows the newest row first")
        #expect(snapshot.activity.count == DatasetLoader.activityBuckets)
        await #expect(throws: ActionError.failed(.datasetOpen, message: "No such dataset.")) { _ = try await f.registry.perform(.datasetOpen, .select("ghost")) }
    }

    @Test func filterSearchAndLoadMoreNarrowTheRows() async throws {
        let f = try await DatasetsFixture.make()
        defer { f.remove() }
        _ = try await f.registry.perform(.datasetOpen, .select(try await f.datasetID()))
        _ = try await f.registry.perform(.datasetFilter, .select("invalid"))
        #expect(f.controller.snapshot?.rows.count == 2 && f.controller.snapshot?.rows.allSatisfy { !$0.row.valid } == true)
        _ = try await f.registry.perform(.datasetFilter, .select("all"))
        _ = try await f.registry.perform(.datasetSearch, .set("harbor"))
        #expect(f.controller.snapshot?.rows.map { $0.cells[0] } == ["Harbor View"])
        _ = try await f.registry.perform(.datasetSearch, .set("hotel-2"))
        #expect((f.controller.snapshot?.rows.count ?? 0) >= 1, "the search also covers the source URL and the cells")
        _ = try await f.registry.perform(.datasetSearch, .set(""))
        #expect(f.controller.snapshot?.rows.count == 30)
        await #expect(throws: ActionError.self) { _ = try await f.registry.perform(.datasetFilter, .select("weird")) }

        // Mais de uma página: 50 por página, `dataset.page` anda entre elas.
        _ = try await f.service.define(session: DatasetsFixture.session, name: "big", columns: [DatasetColumn(name: "n", type: .integer)], key: ["n"])
        for start in stride(from: 0, to: 1500, by: 500) {
            _ = try await f.service.append(session: DatasetsFixture.session, name: "big", rows: (start..<start + 500).map { ["n": .int($0)] }, provenance: .none)
        }
        let big = try #require(try await f.store.dataset(sessionID: DatasetsFixture.session, name: "big")).id
        _ = try await f.registry.perform(.datasetOpen, .select(big))
        #expect(f.controller.snapshot?.rows.count == 50 && f.controller.snapshot?.matching == 1500 && f.controller.pageCount == 30)
        #expect(f.controller.snapshot?.rows.first?.cells == ["1499"], "newest first")
        _ = try await f.registry.perform(.datasetPage, .select("next"))
        #expect(f.controller.page == 1 && f.controller.snapshot?.rows.first?.cells == ["1449"])
        _ = try await f.registry.perform(.datasetPage, .select("prev"))
        _ = try await f.registry.perform(.datasetPage, .select("prev"))
        #expect(f.controller.page == 0, "prev stops at the first page")
        await #expect(throws: ActionError.self) { _ = try await f.registry.perform(.datasetPage, .select("sideways")) }
    }

    @Test func queryBarParsesColumnConditionsAndKeepsTheRestAsText() {
        let columns = [DatasetColumn(name: "name"), DatasetColumn(name: "rating", type: .number), DatasetColumn(name: "price", type: .integer)]
        let parsed = DatasetLoader.parse(#"price:>200 rating:>=4.5 name:"grand plaza" union note:x"#, columns: columns)
        #expect(parsed.conditions == [
            DatasetCondition(column: "price", comparison: .greater, value: "200"),
            DatasetCondition(column: "rating", comparison: .greaterOrEqual, value: "4.5"),
            DatasetCondition(column: "name", comparison: .contains, value: "grand plaza"),
        ])
        #expect(parsed.text == "union note:x", "unknown columns stay as text")
        #expect(DatasetLoader.parse("price:300", columns: columns).conditions == [DatasetCondition(column: "price", comparison: .equals, value: "300")])
        #expect(DatasetLoader.parse("price:", columns: columns).text == "price:", "an empty value is just text")
    }

    @Test func facetsRangeColumnsTabsAndCopy() async throws {
        let f = try await DatasetsFixture.make()
        defer { f.remove() }
        var copied: [String] = []
        f.controller.copyText = { copied.append($0) }
        _ = try await f.registry.perform(.datasetOpen, .select(try await f.datasetID()))
        let facets = try #require(f.controller.snapshot?.facets)
        #expect(facets[.status]?.map(\.value).sorted() == ["invalid", "valid"])
        #expect(facets[.error]?.isEmpty == false, "invalid rows group by error kind")

        _ = try await f.registry.perform(.datasetFacet, .select("status:valid"))
        #expect(f.controller.snapshot?.rows.allSatisfy { !$0.row.valid } == true && f.controller.filter == .invalid)
        #expect(!f.controller.isChecked(.status, "valid"))
        _ = try await f.registry.perform(.datasetFacet, .select("status:*"))
        #expect(f.controller.snapshot?.matching == 30)
        let kind = try #require(facets[.error]?.first?.value)
        _ = try await f.registry.perform(.datasetFacet, .select("error:\(kind)"))
        #expect(f.controller.isChecked(.error, kind) && f.controller.snapshot?.rows.allSatisfy { $0.row.errorKind == kind } == true)
        _ = try await f.registry.perform(.datasetFacet, .select("error:*"))
        await #expect(throws: ActionError.self) { _ = try await f.registry.perform(.datasetFacet, .select("planet:mars")) }

        _ = try await f.registry.perform(.datasetSearch, .set("price:>200"))
        #expect(f.controller.snapshot?.rows.isEmpty == false)
        #expect(f.controller.snapshot?.rows.allSatisfy { Int($0.cells[2]) ?? 0 > 200 } == true)
        _ = try await f.registry.perform(.datasetSearch, .set(""))

        _ = try await f.registry.perform(.datasetRange, .select("15m"))
        #expect(f.controller.range == .minutes15 && f.controller.snapshot?.activity.count == DatasetLoader.activityBuckets)
        await #expect(throws: ActionError.self) { _ = try await f.registry.perform(.datasetRange, .select("forever")) }
        _ = try await f.registry.perform(.datasetRange, .select("all"))

        _ = try await f.registry.perform(.datasetColumns, .select("url"))
        #expect(f.controller.visibleColumns.map(\.name) == ["name", "rating", "price"])
        _ = try await f.registry.perform(.datasetColumns, .select("url"))
        #expect(f.controller.visibleColumns.count == 4)
        await #expect(throws: ActionError.self) { _ = try await f.registry.perform(.datasetColumns, .select("ghost")) }

        _ = try await f.registry.perform(.datasetPanelTab, .select("history"))
        #expect(f.controller.panelTab == .history)
        await #expect(throws: ActionError.self) { _ = try await f.registry.perform(.datasetCopyRow, .press) }
        let first = try #require(f.controller.snapshot?.rows.last)
        _ = try await f.registry.perform(.datasetSelectRow, .select(first.id))
        _ = try await f.registry.perform(.datasetCopyRow, .press)
        #expect(copied.count == 1 && copied[0].contains("\"Grand Plaza\""))
        #expect(f.controller.snapshot?.stats.rows == 30 && f.controller.snapshot?.stats.invalid == 2)
    }

    @Test func newDataShowsInTheRightPanelOnceAndNeverAgainAfterClosing() async throws {
        let f = try await DatasetsFixture.make(seed: false)
        defer { f.remove() }
        var panelShown = 0
        f.controller.now = { Date() }  // o dataset nasce com a hora real
        f.controller.currentSession = { DatasetsFixture.session }
        f.controller.showDataPanel = { panelShown += 1 }
        // Dataset definido mas vazio: nada aparece.
        _ = try await f.service.define(session: DatasetsFixture.session, name: "hotels", columns: [DatasetColumn(name: "name")], key: nil)
        await f.controller.autoOpenNewData()
        #expect(panelShown == 0)
        // Primeiras linhas: o painel Data aparece (no lugar dos Insights), uma vez, com esse dataset; a tela do usuário não muda.
        _ = try await f.service.append(session: DatasetsFixture.session, name: "hotels", rows: [["name": "A"]], provenance: .none)
        await f.controller.autoOpenNewData()
        let id = try await f.datasetID()
        #expect(panelShown == 1)
        #expect(f.controller.panelSummary?.dataset.id == id)
        // O usuário fechou: mais linhas não reabrem, nem depois de reiniciar o controlador (gravado no store).
        _ = try await f.service.append(session: DatasetsFixture.session, name: "hotels", rows: [["name": "B"]], provenance: .none)
        await f.controller.autoOpenNewData()
        #expect(panelShown == 1)
        let fresh = DatasetsController()
        fresh.now = f.controller.now
        fresh.currentSession = { DatasetsFixture.session }
        fresh.showDataPanel = { panelShown += 1 }
        await fresh.attach(store: f.store)
        await fresh.autoOpenNewData()
        #expect(panelShown == 1)
        // Dataset antigo (criado há mais de 10 min): não aparece.
        _ = try await f.service.define(session: DatasetsFixture.session, name: "old", columns: [DatasetColumn(name: "x")], key: nil)
        _ = try await f.service.append(session: DatasetsFixture.session, name: "old", rows: [["x": "1"]], provenance: .none)
        fresh.now = { Date().addingTimeInterval(3600) }
        await fresh.autoOpenNewData()
        #expect(panelShown == 1, "datasets older than the window don't pop up")
    }

    @Test func selectingARowShowsItsProvenance() async throws {
        let f = try await DatasetsFixture.make()
        defer { f.remove() }
        _ = try await f.registry.perform(.datasetOpen, .select(try await f.datasetID()))
        let first = try #require(f.controller.snapshot?.rows.last)
        _ = try await f.registry.perform(.datasetSelectRow, .select(first.id))
        let row = try #require(f.controller.selectedRow?.row)
        #expect(row.trust == .observed && row.requestID == DatasetsFixture.observed && row.computer == "phoenix-az" && row.sourceURL == "https://hotels.example.test/grand-plaza")
        _ = try await f.registry.perform(.datasetSelectRow, .press)
        #expect(f.controller.selectedRow == nil)
    }

    @Test func openSourceOnlyOpensWebURLs() async throws {
        let f = try await DatasetsFixture.make()
        defer { f.remove() }
        var opened: [URL] = []
        f.controller.openURL = { opened.append($0) }
        _ = try await f.registry.perform(.datasetOpen, .select(try await f.datasetID()))
        let first = try #require(f.controller.snapshot?.rows.last)
        let reply = try await f.registry.perform(.datasetOpenSource, .select(first.id))
        #expect(reply.message == "https://hotels.example.test/grand-plaza" && opened.count == 1)
        #expect(DatasetsController.webURL("javascript:alert(1)") == nil && DatasetsController.webURL("file:///etc/passwd") == nil && DatasetsController.webURL("https://a.test/x") != nil)
        await #expect(throws: ActionError.self) { _ = try await f.registry.perform(.datasetOpenSource, .select("ghost")) }
    }

    @Test func exportWritesTheValidRowsToAPathOnlyWithAutomation() async throws {
        let f = try await DatasetsFixture.make()
        defer { f.remove() }
        _ = try await f.registry.perform(.datasetOpen, .select(try await f.datasetID()))
        let csv = f.root.appendingPathComponent("out.csv"), jsonl = f.root.appendingPathComponent("out.jsonl"), json = f.root.appendingPathComponent("out.json")
        _ = try await f.registry.perform(.datasetExport, .set("csv=\(csv.path)"))
        _ = try await f.registry.perform(.datasetExport, .set("jsonl=\(jsonl.path)"))
        _ = try await f.registry.perform(.datasetExport, .set("json=\(json.path)"))
        let text = try String(contentsOf: csv, encoding: .utf8)
        #expect(text.hasPrefix("name,rating,price,url\r\nGrand Plaza,3,90,https://hotels.example.test/hotel-1\r\n"))
        #expect(text.components(separatedBy: "\r\n").count == 30, "header + 28 valid rows + the empty piece after the trailing newline")
        #expect(try String(contentsOf: jsonl, encoding: .utf8).split(separator: "\n").count == 28)
        #expect(try JSON.parse(Data(contentsOf: json)).array?.count == 28)
        await #expect(throws: ActionError.self) { _ = try await f.registry.perform(.datasetExport, .set("xlsx=\(f.root.path)/x")) }
        await #expect(throws: ActionError.self) { _ = try await f.registry.perform(.datasetExport, .select("pdf")) }

        let off = try await DatasetsFixture.make(automation: false)
        defer { off.remove() }
        _ = try await off.registry.perform(.datasetOpen, .select(try await off.datasetID()))
        await #expect(throws: ActionError.failed(.datasetExport, message: "Automation is off")) {
            _ = try await off.registry.perform(.datasetExport, .set("csv=\(off.root.path)/nope.csv"))
        }
        #expect(!FileManager.default.fileExists(atPath: off.root.appendingPathComponent("nope.csv").path))
    }

    @Test func pageActionTogglesTheListAndNeedsADatasetForTheRest() async throws {
        let f = try await DatasetsFixture.make()
        defer { f.remove() }
        var page: CenterPage = .workspace
        f.controller.currentPage = { page }
        f.controller.showPage = { page = $0 }
        f.controller.hidePage = { page = .workspace }
        #expect(try await f.registry.perform(.pageDatasets, .press).message == "datasets" && page == .datasets)
        #expect(try await f.registry.perform(.pageDatasets, .press).message == "datasets" && page == .datasets, "pressing again keeps the page open")
        await #expect(throws: ActionError.self) { _ = try await f.registry.perform(.datasetFilter, .select("all")) }
        await #expect(throws: ActionError.self) { _ = try await f.registry.perform(.datasetExport, .select("csv")) }
    }

    // MARK: Imagens

    @Test func listPageSnapshot() async throws {
        let f = try await DatasetsFixture.make()
        defer { f.remove() }
        try await f.store.createDataset(Dataset(
            id: "01LISTINGS", sessionID: DatasetsFixture.session, name: "listings", columns: [DatasetColumn(name: "id"), DatasetColumn(name: "status")], key: ["id"],
            createdAt: DatasetsFixture.t0.addingTimeInterval(-3600)))
        await f.controller.reloadList()
        f.render(DatasetsPageView(controller: f.controller), size: CGSize(width: 900, height: 360), name: "list")
    }

    @Test func emptyListSnapshot() async throws {
        let f = try await DatasetsFixture.make(seed: false)
        defer { f.remove() }
        f.render(DatasetsPageView(controller: f.controller), size: CGSize(width: 900, height: 360), name: "listEmpty")
    }

    @Test func datasetPageSnapshots() async throws {
        let previous = MotionPolicy.shared.mode
        MotionPolicy.shared.mode = .instant
        defer { MotionPolicy.shared.mode = previous }
        let f = try await DatasetsFixture.make()
        defer { f.remove() }
        _ = try await f.registry.perform(.datasetOpen, .select(try await f.datasetID()))
        let first = try #require(f.controller.snapshot?.rows.last)
        _ = try await f.registry.perform(.datasetSelectRow, .select(first.id))
        f.render(DatasetPageView(controller: f.controller), size: CGSize(width: 1000, height: 640), name: "datasetProvenance")
        _ = try await f.registry.perform(.datasetFilter, .select("invalid"))
        let invalid = try #require(f.controller.snapshot?.rows.first)
        _ = try await f.registry.perform(.datasetSelectRow, .select(invalid.id))
        f.render(DatasetPageView(controller: f.controller), size: CGSize(width: 1000, height: 640), name: "datasetInvalid")
        _ = try await f.registry.perform(.datasetSearch, .set("zzz"))
        f.render(DatasetPageView(controller: f.controller), size: CGSize(width: 1000, height: 420), name: "datasetNoMatch")
    }
}
