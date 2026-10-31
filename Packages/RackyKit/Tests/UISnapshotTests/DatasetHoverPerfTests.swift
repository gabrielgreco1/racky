import RackyCore
import RackyProtocol
import RackyStore
import AppKit
import Foundation
import Testing

@testable import RackyUI

/// Mexer o mouse sobre uma tabela grande (300 linhas, 8 colunas) aberta numa tab da sessão: cada movimento muda o hover de uma
/// linha e não pode refazer o layout da grade inteira (era o lag que o dono sentia com a tabela aberta).
@MainActor
@Suite(.serialized, .offscreenAppKit, .tags(.integration)) struct DatasetHoverPerfTests {
    @Test func hoveringRowsOfABigTableIsCheap() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("racky-hover-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let env = AppEnvironment(environment: ["RACKY_SKIP_ONBOARDING": "1", "RACKY_HOME": home.path, "RACKY_TEST_HEADLESS": "1"])
        let cast = SidebarFixtures.full()
        env.sidebar.apply(cast.snapshot)
        let session = try #require(cast.selectedSessionID)
        env.sidebar.select(session)
        let c = await EmptyWindowTreeTests.host(env, size: NSSize(width: 1500, height: 900))
        let window = try #require(c.window)
        window.makeKeyAndOrderFront(nil)
        window.acceptsMouseMovedEvents = true
        defer { window.close() }
        let store = try await RackyStore.open(paths: StorePaths(root: home))
        try await store.save(Session(id: session, kind: .clean, folderPath: "/tmp/hover", title: "Hover"))
        await env.datasets.attach(store: store)
        let service = DatasetService(store: store)
        let names = ["title", "city", "price", "rating", "url", "date", "notes", "code"]
        _ = try await service.define(session: session, name: "big", columns: names.map { DatasetColumn(name: $0, required: false) }, key: ["title"])
        let rows: [[String: JSON]] = (0 ..< 300).map { i in
            Dictionary(uniqueKeysWithValues: names.map { ($0, JSON.string("\($0)-\(i) value with some length")) })
        }
        _ = try await service.append(session: session, name: "big", rows: rows, provenance: .none)
        await env.datasets.reloadList()
        let id = try #require(env.datasets.summaries.first { $0.dataset.name == "big" }?.dataset.id)
        _ = try await env.registry.perform(.datasetOpen, .select(id))
        await VisualBatchTests.settle(800)

        let content = try #require(window.contentView)
        // Mudar a seleção de linha muda o estado de uma linha, como o hover (que o mouse sintético não aciona offscreen).
        let model = try #require(env.datasets.active)
        let keys = try #require(model.snapshot?.rows.map(\.id))
        func change(_ key: String) async throws {
            _ = try await env.registry.perform(.datasetSelectRow, .select(key))
            content.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        for key in keys.prefix(10) { try await change(key) }  // aquecimento
        var times: [Double] = []
        for key in keys.dropFirst(10).prefix(40) {
            let t0 = CFAbsoluteTimeGetCurrent()
            try await change(key)
            times.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
        times.sort()
        let median = times[times.count / 2]
        print(String(format: "ROWSTATE median=%.2fms p90=%.2fms max=%.2fms n=%d", median, times[times.count * 9 / 10], times.last ?? 0, times.count))
        #expect(median < 16, "uma mudança de linha cabe num quadro")

        // Redimensionar a janela com a tabela aberta (o pico real do dono: relayout da tabela inteira quadro a quadro).
        var resize: [Double] = []
        for step in 0 ..< 30 {
            let width = 1500 - CGFloat(step % 15) * 20
            let t0 = CFAbsoluteTimeGetCurrent()
            window.setContentSize(NSSize(width: width, height: 900))
            content.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            resize.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
        resize.sort()
        print(String(format: "RESIZE median=%.2fms p90=%.2fms max=%.2fms", resize[resize.count / 2], resize[resize.count * 9 / 10], resize.last ?? 0))
        try? await store.close()
    }
}
