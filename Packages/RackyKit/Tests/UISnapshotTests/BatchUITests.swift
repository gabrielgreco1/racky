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

// T3-07 (AC-429): o painel `Batch` (filtros, consolidado, exportar, arquivar), a linha do Inbox de "lote concluído" e o overlay "New Batch…".

extension ResultsFixture {
    /// O fixture com as ações de lote registradas (e as do overlay "New Batch…" como no-op: o `NewBatchController` as registra no app).
    static func makeWithBatch(automation: Bool = true) async throws -> ResultsFixture {
        let f = try await make()
        try f.controller.registerBatch(in: f.registry, automationEnabled: automation)
        for id in [ActionID.dialogNewBatchConfirm, .dialogNewBatchCancel, .dialogNewBatchImportCSV, .dialogNewBatchSetTargets, .dialogNewBatchSetBrief, .dialogNewBatchSetDisplay,
                   .dialogNewBatchSetProxy, .dialogNewBatchToggleProxy, .dialogNewBatchSetSession, .batchNew] {
            try? f.registry.register(id) { _ in nil }
        }
        return f
    }

    func batch() -> BatchSummary {
        BatchSummary(name: "listings-oct", sessionTitle: "houston", children: [
            BatchChild(name: "phoenix-az", status: .done, computerState: .stopped, verified: 3, citedMissing: 1, notVerified: 1, proxy: "zyte-us", proxyRequests: 120, durationSeconds: 190, runPath: run.root.path),
            BatchChild(name: "austin-tx", status: .running, computerState: .inUse, verified: 0, proxy: "zyte-us", proxyRequests: 44, durationSeconds: 95, lastDoing: "Reading the listing search results", runPath: folder.appendingPathComponent("austin-tx").path),
            BatchChild(name: "dallas-tx", status: .needsYou, computerState: .inUse, proxy: "zyte-us", proxyRequests: 12, durationSeconds: 80, runPath: folder.appendingPathComponent("dallas-tx").path),
            BatchChild(name: "el-paso-tx", status: .failed, computerState: .stopped, proxy: "direct", durationSeconds: 40, runPath: folder.appendingPathComponent("el-paso-tx").path),
        ])
    }
}

@MainActor
@Suite("T3-07 - painel do lote e New Batch…", .serialized, .offscreenAppKit)
struct BatchUITests {
    @Test func aFinishedRunOfABatchOpensWithoutALiveComputer() async throws {
        let f = try await ResultsFixture.makeWithBatch()
        defer { f.remove() }
        f.controller.model.setBatches([f.batch()])
        _ = try await f.registry.perform(.computerShowTab, .select("phoenix-az"))
        #expect(f.controller.detail?.run == f.run.root && f.controller.detailCollected?.hasResult == true)
        await #expect(throws: ActionError.self) { _ = try await f.registry.perform(.computerShowTab, .select("el-paso-tx")) }
    }


    @Test func batchActionsOpenFilterAndExport() async throws {
        let f = try await ResultsFixture.makeWithBatch()
        defer { f.remove() }
        f.controller.model.setBatches([f.batch()])
        let opened = try await f.registry.perform(.batchOpen, .select("listings-oct"))
        #expect(opened.message == "listings-oct" && f.controller.page == .batch("listings-oct") && f.controller.page.batchName == "listings-oct")
        await #expect(throws: ActionError.failed(.batchOpen, message: "No such batch.")) { _ = try await f.registry.perform(.batchOpen, .select("nope")) }
        _ = try await f.registry.perform(.batchFilter, .select("Needs You"))
        #expect(f.controller.batchFilter == .needsYou)
        await #expect(throws: ActionError.self) { _ = try await f.registry.perform(.batchFilter, .select("Weird")) }

        var full = f.batch()
        full.children[0].result = ["title": "Listings, Phoenix", "n": 12]
        f.controller.consolidated["listings-oct"] = full
        let csv = f.folder.appendingPathComponent("out.csv"), json = f.folder.appendingPathComponent("out.json")
        _ = try await f.registry.perform(.batchExportCSV, .set(csv.path))
        _ = try await f.registry.perform(.batchExportJSON, .set(json.path))
        let text = try String(contentsOf: csv, encoding: .utf8)
        #expect(text.hasPrefix("target,status,verified,") && text.contains("phoenix-az,done,3,1,1,120,190,12,\"Listings, Phoenix\""))
        #expect(try JSON.parse(Data(contentsOf: json))["counts"]?["done"] == 1)
    }


    @Test func exportToAPathNeedsTheAutomationFlag() async throws {
        let f = try await ResultsFixture.makeWithBatch(automation: false)
        defer { f.remove() }
        f.controller.model.setBatches([f.batch()])
        await #expect(throws: ActionError.failed(.batchExportCSV, message: "Automation is off")) {
            _ = try await f.registry.perform(.batchExportCSV, .set(f.folder.appendingPathComponent("x.csv").path))
        }
    }


    @Test func archiveAsksOnlyWhenSubagentsAreStillRunning() async throws {
        let f = try await ResultsFixture.makeWithBatch()
        defer { f.remove() }
        let running = f.batch()
        let model = try #require(f.controller.confirmArchive(of: running))
        #expect(model.title == "Stop 2 running subagents?" && model.destructive)
        var one = running
        one.children = [running.children[1]]
        #expect(f.controller.confirmArchive(of: one)?.title == "Stop 1 running subagent?")
        var done = running
        done.children = [running.children[0], running.children[3]]
        #expect(f.controller.confirmArchive(of: done) == nil, "nothing is running: archive without asking")
        f.controller.model.setBatches([done])
        await #expect(throws: ActionError.self) { _ = try await f.registry.perform(.batchArchive, .select("listings-oct")) }  // sem orquestrador
    }


    @Test func batchPanelShowsTargetsStatesFiltersAndTheConsolidatedResults() async throws {
        let f = try await ResultsFixture.makeWithBatch()
        defer { f.remove() }
        var summary = f.batch()
        f.controller.model.setBatches([summary])
        f.render(f.environment(BatchPageView(controller: f.controller, batchID: "listings-oct")), size: CGSize(width: 1000, height: 460), name: "batchPanel")
        summary.children[0].result = ["title": "Phoenix listings", "open": 12, "fee": "$1,250"]
        summary.children[3].result = ["title": "El Paso listings"]
        f.controller.consolidated["listings-oct"] = summary
        f.render(f.environment(BatchPageView(controller: f.controller, batchID: "listings-oct")), size: CGSize(width: 1000, height: 560), name: "batchPanelConsolidated")
        _ = try await f.registry.perform(.batchFilter, .select("Done"))
        f.render(f.environment(BatchPageView(controller: f.controller, batchID: "listings-oct")), size: CGSize(width: 1000, height: 460), name: "batchPanelDoneFilter")
        f.render(f.environment(BatchPageView(controller: f.controller, batchID: "missing")), size: CGSize(width: 1000, height: 200), name: "batchPanelEmpty")
    }


    @Test func inboxRowForAFinishedBatchOpensThePanel() async throws {
        let f = try await ResultsFixture.makeWithBatch()
        defer { f.remove() }
        let item = AttentionItem(
            id: "batch.listings-oct.batchDone", kind: .batchDone, sessionID: UUID(), terminalID: UUID(), title: "houston — listings-oct finished",
            body: "3 done · 1 failed · 11 verified fields · 18 min · 212 proxy requests", createdAt: Date(), batchID: "listings-oct")
        f.render(f.environment(BatchDoneRowView(item: item).background(DS.Color.sidebar)), size: CGSize(width: 300, height: 60), name: "inboxBatchRow")
    }

    // MARK: New Batch…


    @Test func newBatchModelBuildsTheRequestFromWhatWasPasted() {
        let model = NewBatchModel(name: "listings-oct")
        #expect(model.issue == "Add at least one target." && model.countText == "0 targets")
        model.targetsText = "city,state\nPhoenix,AZ\nAustin,TX\n"
        model.proxyNames = ["zyte-us", "office"]
        model.chooseProxy("zyte-us")
        model.toggleAllowed("zyte-us")
        model.toggleAllowed("office")
        model.toggleAllowed("office")
        model.toggleAllowed("ghost")
        model.display = .desktop
        let request = model.request
        #expect(model.issue == nil && model.countText == "2 targets" && request.targets.map(\.name) == ["phoenix", "austin"])
        #expect(request.proxy == "zyte-us" && request.allowedProxies == ["zyte-us"] && request.display == .desktop && request.name == "listings-oct")
        model.chooseProxy("none")
        #expect(model.request.proxy == "none" && model.proxySelection == "none")
        model.chooseProxy("default")
        #expect(model.request.proxy == nil && model.proxySelection == "default")
        model.chooseProxy("ghost")
        #expect(model.proxySelection == "default", "an unknown proxy is ignored")
        var entryIDs: [String] = []
        for entry in model.proxyEntries { if case .item(let item) = entry { entryIDs.append(item.id) } }
        #expect(entryIDs == ["default", "none", "office", "zyte-us"])
        model.targetsText = "one"
        #expect(model.countText == "1 target")
    }


    @Test func newBatchOverlayRendersTheFormWithTargetsBriefAndProxies() async throws {
        let f = try await ResultsFixture.makeWithBatch()
        defer { f.remove() }
        let model = NewBatchModel(name: "listings-oct")
        model.targetsText = "city,state\nPhoenix,AZ\nAustin,TX\nDallas,TX\n"
        model.proxyNames = ["office-socks", "zyte-us"]
        model.defaultProxy = "zyte-us"
        model.allowedProxies = ["zyte-us"]
        model.currentSessionAvailable = true
        f.render(f.environment(f.card(NewBatchView(model: model))), size: CGSize(width: DS.Layout.composerWidth, height: 640), name: "newBatch")
        let empty = NewBatchModel(name: "listings-oct")
        f.render(f.environment(f.card(NewBatchView(model: empty))), size: CGSize(width: DS.Layout.composerWidth, height: 520), name: "newBatchEmpty")
    }
}

@MainActor
@Suite("T3-07 - New Batch… no app", .serialized, .offscreenAppKit)
struct NewBatchFlowTests {
    func app() -> AppEnvironment { AppEnvironment(environment: ["RACKY_SKIP_ONBOARDING": "1"]) }

    @Test func theOverlayOpensEditsItsFieldsAndRefusesToStartWithoutTargets() async throws {
        let env = app()
        let opened = try await env.registry.perform(.batchNew, nil)
        #expect(opened.message == "opened" && env.overlays.top?.spec.name == "newBatch")
        let model = try #require(env.newBatch?.model)
        await #expect(throws: ActionError.failed(.dialogNewBatchConfirm, message: "Add at least one target.")) { _ = try await env.registry.perform(.dialogNewBatchConfirm, nil) }
        #expect(env.overlays.top?.spec.name == "newBatch", "a refused start keeps the overlay open")
        _ = try await env.registry.perform(.dialogNewBatchSetTargets, .set("Phoenix AZ\nAustin TX"))
        _ = try await env.registry.perform(.dialogNewBatchSetBrief, .set("TASK: find {{target}}"))
        _ = try await env.registry.perform(.dialogNewBatchSetDisplay, .select("desktop"))
        #expect(model.targets.count == 2 && model.brief == "TASK: find {{target}}" && model.display == .desktop)
        await #expect(throws: ActionError.self) { _ = try await env.registry.perform(.dialogNewBatchSetDisplay, .select("tablet")) }
        await #expect(throws: ActionError.self) { _ = try await env.registry.perform(.dialogNewBatchToggleProxy, .select("ghost")) }
        await #expect(throws: ActionError.failed(.dialogNewBatchSetSession, message: "Select a session with Claude Code.")) {
            _ = try await env.registry.perform(.dialogNewBatchSetSession, .select("current"))
        }
        // O store ainda não abriu: o lançamento falha e o que foi digitado continua no overlay.
        await #expect(throws: ActionError.self) { _ = try await env.registry.perform(.dialogNewBatchConfirm, nil) }
        #expect(env.overlays.top?.spec.name == "newBatch" && model.targets.count == 2)
        _ = try await env.registry.perform(.dialogNewBatchCancel, nil)
        #expect(env.overlays.top == nil && env.newBatch?.model == nil)
    }

    @Test func importCSVReadsAFileOnlyWithAutomationAndRejectsGarbage() async throws {
        let env = app()
        _ = try await env.registry.perform(.batchNew, nil)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("abx-targets-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("city,state\nPhoenix,AZ\n".utf8).write(to: file)
        do {
            let reply = try await env.registry.perform(.dialogNewBatchImportCSV, .set(file.path))
            #expect(reply.message == "1" && env.newBatch?.model?.targets.first?.columns["city"] == "Phoenix")
        } catch ActionError.failed(_, let message) {
            #expect(message == "Automation is off", "tests run without the automation flag")
        }
        await #expect(throws: ActionError.self) { _ = try await env.registry.perform(.dialogNewBatchImportCSV, .set("/nonexistent/targets.csv")) }
    }
}
