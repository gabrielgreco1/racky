import RackyCore
import RackyDesignSystem
import RackyDocker
import RackyProtocol
import RackyStore
import AppKit
import Foundation
import SnapshotTesting
import SwiftUI
import Testing

@testable import RackyUI

/// Suporte compartilhado dos testes de resultado e lote: uma pasta de run com as cinco afirmações do AC-421 e o `render` das imagens
/// de referência (todas em `__Snapshots__/ResultsUITests/`).
@MainActor
struct ResultsFixture {
    static let ids = ["01ARZ3NDEKTSV4RRFFQ69G5FAV", "01ARZ3NDEKTSV4RRFFQ69G5FAW", "01ARZ3NDEKTSV4RRFFQ69G5FAX", "01ARZ3NDEKTSV4RRFFQ69G5FAY"]

    let controller = ComputersController()
    let registry: ActionRegistry
    let folder: URL
    var run: RunFolder { RunFolder(root: folder.appendingPathComponent("phoenix-az", isDirectory: true)) }

    /// Um run com o resultado das cinco afirmações do AC-421 (3 verificadas, 1 id inexistente, 1 sem citação).
    static func make() async throws -> ResultsFixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("abx-results-\(UUID().uuidString.lowercased())", isDirectory: true)
        let registry = ActionRegistry(flags: SliceFlags(current: .slice3), surface: FakeSurface())
        let fixture = ResultsFixture(registry: registry, folder: folder)
        try fixture.controller.register(in: registry)
        try fixture.controller.registerResults(in: registry)
        try fixture.run.ensureLayout()
        let log = ChainedLog(file: fixture.run.requestsFile)
        for (n, record) in [(ids[0], "observed"), (ids[1], "observed"), (ids[2], "reported")].enumerated() {
            try await log.append([
                "id": .string(record.0), "trust": .string(record.1), "method": "GET", "status": 200, "source": "browser",
                "url": .string("https://aca-prod.example.test/listings/\(n)"),
            ])
        }
        let result = "{\"listings\": 12, \"owner\": \"ACME LLC (\(ids[0]))\", \"status\": \"Issued (\(ids[2]))\", \"export\": \"see request \(ids[1])\", \"ghost\": \"\(ids[3])\", \"note\": \"looks fine\"}"
        try Data(result.utf8).write(to: fixture.run.resultFile)
        var meta = RunMetadata(computer: "phoenix-az", display: "headless", parent: "p", batch: "listings-oct", startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        meta.endedAt = meta.startedAt.addingTimeInterval(190)
        meta.outcome = .released
        fixture.run.writeMetadata(meta)
        return fixture
    }

    func remove() { try? FileManager.default.removeItem(at: folder) }

    func render(_ view: some View, size: CGSize, name: String, line: UInt = #line) {
        DSFonts.registerIfNeeded()
        let previous = MotionPolicy.shared.preference
        MotionPolicy.shared.preference = .on
        defer { MotionPolicy.shared.preference = previous }
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).environment(\.colorScheme, .dark))
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        withSnapshotTesting(record: ComponentSnapshotTests.recording) {
            assertSnapshot(of: host, as: .image(precision: 0.98, perceptualPrecision: 0.97), named: name, testName: "results", line: line)
        }
    }

    /// O cartão do overlay (fundo e borda do host), para o conteúdo claro não sumir no fundo branco da captura.
    func card(_ view: some View) -> some View {
        view
            .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Color.overlayCard))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Color.borderStrong))
    }

    func environment(_ view: some View) -> some View {
        view.environment(\.actionRegistry, registry).environment(\.elementStore, UIElementStore())
    }
}


// T3-06 (AC-420, AC-421): a aba `Result` do detalhe no painel direito. Ações pelo registro, como a automação as chama; imagens offscreen.

@MainActor
@Suite("T3-06 - aba Result", .serialized, .offscreenAppKit)
struct ResultsUITests {
    @Test func showTabOpensTheResultDetailInThePanelAndBackReturnsToTheList() async throws {
        let f = try await ResultsFixture.make()
        defer { f.remove() }
        let computer = try ManagedComputer(name: "phoenix-az", display: .headless, run: f.run, backend: LazyComputerBackend())
        await f.controller.add(computer)
        let reply = try await f.registry.perform(.computerShowTab, .select("phoenix-az"))
        #expect(reply.message == "phoenix-az:result" && f.controller.detail?.name == "phoenix-az" && f.controller.panelOpen)
        let collected = try #require(f.controller.detailCollected)
        #expect(collected.verified == 3 && collected.citedMissing == 1 && collected.notVerified == 2)
        let missing = collected.fields.filter { $0.status == .citedMissing }
        #expect(missing.count == 1 && missing[0].statusLabel == "Cited request not found")
        _ = try await f.registry.perform(.computerShowTab, .select("phoenix-az:result"))
        #expect(f.controller.detail != nil)
        await #expect(throws: ActionError.self) { _ = try await f.registry.perform(.computerShowTab, .select("phoenix-az:network")) }
        _ = try await f.registry.perform(.computerShowTab, .press)
        #expect(f.controller.detail == nil && f.controller.detailCollected == nil)
        await #expect(throws: ActionError.failed(.computerShowTab, message: "No run folder for this computer.")) { _ = try await f.registry.perform(.computerShowTab, .select("ghost")) }
    }

    @Test func evidenceActionsFailWithTheSpecMessageWhenThereIsNothingToShow() async throws {
        let f = try await ResultsFixture.make()
        defer { f.remove() }
        let computer = try ManagedComputer(name: "phoenix-az", display: .headless, run: f.run, backend: LazyComputerBackend())
        await f.controller.add(computer)
        await #expect(throws: ActionError.failed(.computerOpenEvidence, message: "Cited request not found")) {
            _ = try await f.registry.perform(.computerOpenEvidence, .select("phoenix-az|\(ResultsFixture.ids[3])"))
        }
        await #expect(throws: ActionError.self) { _ = try await f.registry.perform(.computerOpenEvidence, .select("ghost|\(ResultsFixture.ids[0])")) }
        await #expect(throws: ActionError.self) { _ = try await f.registry.perform(.computerOpenRunFolder, .select("ghost")) }
        await #expect(throws: ActionError.self) { _ = try await f.registry.perform(.computerRevealResult, .select("ghost")) }
    }

    @Test func resultPanelMarksEachClaimAndLinksTheEvidence() async throws {
        let f = try await ResultsFixture.make()
        defer { f.remove() }
        let computer = try ManagedComputer(name: "phoenix-az", display: .headless, run: f.run, backend: LazyComputerBackend())
        await f.controller.add(computer)
        _ = try await f.registry.perform(.computerShowTab, .select("phoenix-az"))
        let detail = try #require(f.controller.detail)
        f.render(f.environment(ComputerDetailView(controller: f.controller, detail: detail)), size: CGSize(width: 420, height: 640), name: "resultPanel")
        let empty = CollectedRun(name: "phoenix-az", run: f.run, resultNote: "No result.json yet")
        f.controller.setDetailForTesting(detail, collected: empty)
        f.render(f.environment(ComputerDetailView(controller: f.controller, detail: detail)), size: CGSize(width: 420, height: 220), name: "resultPanelEmpty")
    }
}
