import RackyCore
import RackyProtocol
import RackyStore
import AppKit
import Foundation
import Testing

@testable import RackyUI

/// Prints da janela inteira com a lista de datasets e a tabela de hotéis (30 linhas, 2 inválidas, uma linha selecionada com a proveniência),
/// para revisar o visual. Só roda com `RACKY_CAPTURE_DIR=<pasta>`; grava `datasets-list.png` e `dataset-page.png`. O store é de um
/// `RACKY_HOME` temporário.
@MainActor
@Suite(.serialized, .offscreenAppKit, .enabled(if: ProcessInfo.processInfo.environment["RACKY_CAPTURE_DIR"] != nil)) struct DatasetsCaptureTests {
    private func write(_ view: NSView, _ name: String) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RACKY_CAPTURE_DIR"]!)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
    }

    @Test func captureDatasetsPages() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("racky-datasets-capture-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let env = AppEnvironment(environment: ["RACKY_SKIP_ONBOARDING": "1", "RACKY_HOME": home.path, "RACKY_TEST_HEADLESS": "1"])
        // Sem `env.start()` (ele abriria o app.sock e o hub): a sidebar recebe o elenco de exemplo e o store temporário é ligado à mão.
        let cast = SidebarFixtures.full()
        env.sidebar.apply(cast.snapshot)
        let session = try #require(cast.selectedSessionID)
        env.sidebar.select(session)
        let c = await EmptyWindowTreeTests.host(env, size: NSSize(width: 1680, height: 980))
        defer { c.window?.close() }
        let store = try await RackyStore.open(paths: StorePaths(root: home))
        defer { Task { try? await store.close() } }
        try await store.save(Session(id: session, kind: .clean, folderPath: "/tmp/hotels", title: "Hotel prices"))
        await env.datasets.attach(store: store)
        let service = DatasetService(store: store)
        try await DatasetsFixture.seedHotels(service: service, session: session)
        try await store.createDataset(Dataset(
            id: ULID.generate(), sessionID: session, name: "listings", columns: [DatasetColumn(name: "listing_id"), DatasetColumn(name: "status")], key: ["listing_id"]))
        _ = try await service.define(session: session, name: "reviews", columns: [DatasetColumn(name: "hotel"), DatasetColumn(name: "stars", type: .integer)], key: nil)
        _ = try await service.append(session: session, name: "reviews", rows: (0..<240).map { ["hotel": .string("Hotel \($0 % 30)"), "stars": .int(1 + $0 % 5)] }, provenance: .none)
        // Uma coleta "ao vivo": 600 hotéis chegando ao longo da última hora, de dois computadores, com um trecho de bloqueio.
        let live = Dataset(
            id: ULID.generate(), sessionID: session, name: "la_hotels",
            columns: [
                DatasetColumn(name: "name", required: true), DatasetColumn(name: "rating", type: .number),
                DatasetColumn(name: "price", type: .integer, required: true), DatasetColumn(name: "url", type: .url),
            ],
            key: ["url"])
        try await store.createDataset(live)
        let names = ["Grand Plaza", "Harbor View", "The Ritz", "Shutters on the Beach", "Hotel Figueroa", "The Hoxton", "Ace Hotel", "Freehand LA", "Line Hotel", "Hotel Erwin", "Cedar Lodge", "Palm Court"]
        let now = Date()
        for minute in 0..<60 {
            let blocked = (40...43).contains(minute)
            let count = blocked ? 3 : 6 + (minute * 7) % 9
            var batch: [DatasetRowInput] = []
            for i in 0..<count {
                let n = minute * 20 + i
                let site = n % 3 == 0 ? "booking.com/hotel/us/stay-\(n)" : "tripadvisor.com/Hotel_Review-g32655-d\(7_600_000 + n)"
                let bad = blocked && i < 2
                let badRating = !blocked && n % 97 == 0
                let price = 140 + (n * 37) % 480
                let rating = badRating ? "" : #","rating":\#(Double(36 + n % 13) / 10)"#
                let data = bad ? #"{"name":"\#(names[n % names.count]) \#(n)","rating":4.1,"url":"https://\#(site)"}"#
                    : #"{"name":"\#(names[n % names.count]) \#(n)"\#(rating),"price":\#(price),"url":"https://\#(site)"}"#
                let error = bad ? "price: required" : (badRating ? #"rating: expected a number, got "four""# : nil)
                batch.append(DatasetRowInput(
                    rowKey: "k\(n)", data: data, valid: error == nil, error: error, computer: n % 3 == 0 ? "booking-la" : "tripadvisor-la",
                    runID: "01ARZ3NDEKTSV4RRFFQ69G5RUN", requestID: "01ARZ3NDEKTSV4RRFFQ69G\(String(format: "%04d", n % 10000))",
                    sourceURL: "https://\(site)", trust: n % 17 == 0 ? .reported : .observed,
                    request: DatasetRequestInfo(method: "GET", status: 200, milliseconds: 180 + (n * 53) % 700), errorKind: DatasetEngine.errorKind(error)))
            }
            _ = try await store.upsertDatasetRows(datasetID: live.id, rows: batch, at: now.addingTimeInterval(Double(minute - 60) * 60))
        }
        env.datasets.isRunning = { $0 == session }
        await env.datasets.reloadList()

        _ = try? await env.registry.perform(.rightPanelToggle, .press)
        _ = try await env.registry.perform(.pageDatasets, .press)
        await VisualBatchTests.settle(800)
        write(c.window!.contentView!, "datasets-list")

        _ = try await env.registry.perform(.datasetOpen, .select(live.id))
        let selected = try #require(env.datasets.snapshot?.rows.first)
        _ = try await env.registry.perform(.datasetSelectRow, .select(selected.id))
        await VisualBatchTests.settle(800)
        write(c.window!.contentView!, "dataset-page")

        // Uma rajada curta (todas as linhas em segundos), como um lote de páginas que terminou.
        if let hotels = env.datasets.summaries.first(where: { $0.dataset.name == "reviews" }) {
            _ = try await env.registry.perform(.datasetOpen, .select(hotels.dataset.id))
            await VisualBatchTests.settle(800)
            write(c.window!.contentView!, "dataset-burst")
            _ = try await env.registry.perform(.datasetOpen, .select(live.id))
        }

        // Filtro de faceta ativo: o chip aparece embaixo da busca.
        _ = try await env.registry.perform(.datasetSelectRow, .press)
        _ = try await env.registry.perform(.datasetFacet, .select("computer:=booking-la"))
        _ = try await env.registry.perform(.datasetAddFilter, .select("price|>|300"))
        _ = try await env.registry.perform(.datasetAddFilter, .select("name|~|plaza"))
        if let snap = env.datasets.snapshot, let start = snap.activityStart {
            let from = start.addingTimeInterval(snap.bucketSeconds * 20), to = start.addingTimeInterval(snap.bucketSeconds * 34)
            _ = try await env.registry.perform(.datasetTimeWindow, .select("\(Int64(from.timeIntervalSince1970 * 1000))-\(Int64(to.timeIntervalSince1970 * 1000))"))
        }
        await VisualBatchTests.settle(600)
        write(c.window!.contentView!, "dataset-page-filtered")

        // A prévia do painel direito (módulo Data) com a sessão aberta.
        _ = try? await env.registry.perform(.pageClose, .press)
        env.datasets.panelDatasetID = live.id
        _ = try? await env.registry.perform(.rightPanelToggle, .press)
        env.rightPanel.show(.data)
        await VisualBatchTests.settle(1200)
        write(c.window!.contentView!, "data-panel")
    }
}
