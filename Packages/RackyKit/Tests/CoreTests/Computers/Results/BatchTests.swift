import RackyDocker
import Foundation
import Testing

@testable import RackyCore

// T3-07: agregação do lote, detecção de conclusão, exportação e o prompt do "New Batch…" (puros), mais o fluxo com o scheduler:
// "lote concluído" uma vez só (AC-429, CS-326), pedido de ajuda aberto que segura o lote, falha de criação e `batch_collect`.

private func child(_ name: String, _ status: BatchChildStatus, v: Int = 0, c: Int = 0, n: Int = 0, requests: Int? = nil, seconds: Int? = nil, result: JSON? = nil) -> BatchChild {
    BatchChild(name: name, status: status, verified: v, citedMissing: c, notVerified: n, proxyRequests: requests, durationSeconds: seconds, result: result)
}

@Suite("T3-07 lote: agregação e conclusão") struct BatchAggregationTests {
    @Test func countsProgressAndHeadline() {
        let batch = BatchSummary(name: "listings-oct", sessionTitle: "listings-oct", children: [
            child("a", .done, v: 3, n: 2, requests: 100, seconds: 600), child("b", .done, v: 4, requests: 112, seconds: 900), child("c", .failed, seconds: 300),
            child("d", .running, seconds: 1080), child("e", .needsYou), child("f", .blocked), child("g", .queued),
        ])
        #expect(batch.total == 7 && batch.done == 2 && batch.failed == 1 && batch.running == 4 && batch.needsYou == 1 && batch.blocked == 1)
        #expect(batch.finishedCount == 3 && !batch.isFinished)
        #expect(batch.verifiedFields == 7 && batch.totalFields == 9 && batch.proxyRequests == 212 && batch.durationSeconds == 1080)
        #expect(batch.headline == "3 of 7 done · 212 proxy requests · 18 min")
        #expect(batch.children[0].verifiedText == "3/5" && batch.children[2].verifiedText == "-")
        #expect(batch.children(matching: .needsYou).map(\.name) == ["e"] && batch.children(matching: .done).map(\.name) == ["a", "b"] && batch.children(matching: .all).count == 7)
    }

    @Test func finishedMeansEveryChildIsTerminalAndNobodyNeedsYou() {
        func batch(_ s: [BatchChildStatus]) -> BatchSummary { BatchSummary(name: "b", children: s.enumerated().map { child("c\($0.offset)", $0.element) }) }
        #expect(!batch([]).isFinished, "an empty batch never finishes")
        #expect(batch([.done, .failed, .stopped]).isFinished)
        #expect(!batch([.done, .running]).isFinished && !batch([.done, .queued]).isFinished && !batch([.done, .blocked]).isFinished)
        #expect(!batch([.done, .needsYou]).isFinished, "an open help request holds the batch (CS-326)")
    }

    @Test func notificationTextHasCountsAndNoPageContent() {
        let batch = BatchSummary(name: "listings-oct", sessionTitle: "houston", children: [
            child("a", .done, v: 3, requests: 100, seconds: 540), child("b", .done, v: 4, requests: 112, seconds: 1080), child("c", .done, v: 5), child("d", .done), child("e", .failed, seconds: 60),
        ])
        #expect(batch.notificationTitle == "houston — listings-oct finished")
        #expect(batch.notificationBody == "4 done · 1 failed · 12 verified fields · 18 min · 212 proxy requests")
        #expect(BatchSummary(name: "b", children: [child("a", .done)]).notificationTitle == "b finished")
        #expect(BatchSummary(name: "b", children: [child("a", .done), child("b", .stopped)]).notificationBody == "1 done · 1 failed · 0 verified fields")
    }

    @Test func trackerNotifiesOncePerBatch() {
        var tracker = BatchCompletionTracker()
        let running = BatchSummary(name: "b", children: [child("a", .done), child("b", .running)])
        let finished = BatchSummary(name: "b", children: [child("a", .done), child("b", .failed)])
        let whileRunning = tracker.observe(running, key: "s|b")
        let first = tracker.observe(finished, key: "s|b")
        let second = tracker.observe(finished, key: "s|b")
        let reopened = tracker.observe(running, key: "s|b")
        let again = tracker.observe(finished, key: "s|b")
        #expect(!whileRunning && first)
        #expect(!second, "second batch_collect, panel reopened: no second notification")
        #expect(!reopened && !again, "a reopened batch that ends again is the same batch")
        let other = tracker.observe(finished, key: "s|other")
        #expect(other && tracker.hasNotified("s|other"))
        var restored = BatchCompletionTracker(notified: ["s|b"])
        let afterRestart = restored.observe(finished, key: "s|b")
        #expect(!afterRestart)
    }

    @Test func csvEscapesAndNeutralizesSpreadsheetFormulas() {
        let batch = BatchSummary(name: "b", children: [
            child("phoenix-az", .done, v: 2, n: 1, requests: 10, seconds: 60, result: ["title": "Listings, Phoenix", "note": "say \"hi\"", "multi": "a\nb", "n": 12]),
            child("evil", .done, result: ["title": "=HYPERLINK(\"http://x\")", "note": "+1", "extra": "-2"]),
            child("none", .failed),
        ])
        #expect(batch.resultColumns == ["multi", "n", "note", "title", "extra"])
        let rows = batch.csv().components(separatedBy: "\r\n")
        #expect(rows[0] == "target,status,verified,cited_missing,not_verified,proxy_requests,duration_s,multi,n,note,title,extra")
        #expect(rows[1] == "phoenix-az,done,2,0,1,10,60,\"a\nb\",12,\"say \"\"hi\"\"\",\"Listings, Phoenix\",")
        #expect(rows[2].contains("'=HYPERLINK") && rows[2].contains(",'+1,") && rows[2].hasSuffix(",'-2"), "formula prefixes are neutralized: \(rows[2])")
        #expect(rows[3] == "none,failed,0,0,0,,,,,,," && rows.last == "")
        #expect(BatchSummary(name: "b", children: []).csv() == "target,status,verified,cited_missing,not_verified,proxy_requests,duration_s\r\n")
    }

    @Test func jsonAndJSONLExports() throws {
        let batch = BatchSummary(name: "b", children: [child("a", .done, v: 1, requests: 5, seconds: 9, result: ["k": "v"]), child("b", .failed)])
        let json = batch.json()
        #expect(json["batch"] == "b" && json["finished"] == true && json["counts"]?["done"] == 1 && json["counts"]?["failed"] == 1 && json["counts"]?["verified_fields"] == 1)
        #expect(json["children"]?.array?.first?["result"]?["k"] == "v" && json["children"]?.array?.last?["result"] == nil)
        let lines = String(decoding: batch.resultsJSONL(), as: UTF8.self).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(try JSON.parse(String(lines[0]))["name"] == "a")
        #expect(batch.statusJSON["done"] == 1 && batch.statusJSON["failed"] == 1 && batch.statusJSON["children"]?.array?.first?["activity"] == "done")
        #expect(BatchExporter.suggestedName(batch: "listings oct/../x", format: .csv) == "listings_oct_.._x.csv")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("abx-export-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try BatchExporter.write(batch, format: .json, to: file)
        #expect(try JSON.parse(Data(contentsOf: file))["batch"] == "b")
    }

    @Test func ledgerFoldersCannotEscapeTheSessionFolder() {
        let session = URL(fileURLWithPath: "/tmp/runs/s")
        let folder = BatchLedger.folder(session: session, batch: "../../etc")
        #expect(folder.deletingLastPathComponent().path == "/tmp/runs/s/_batches" && folder.lastPathComponent != ".." && !folder.lastPathComponent.contains("/"), "\(folder.path)")
        #expect(BatchLedger.safe("..") == "batch" && BatchLedger.safe("a/b") == "a_b")
    }
}

@Suite("T3-07 New Batch…: alvos e prompt") struct NewBatchPromptTests {
    @Test func plainListBecomesTargetsWithSlugsAndNoDuplicates() {
        let targets = NewBatchPrompt.parseTargets("Phoenix AZ\n\n  austin-tx \nPhoenix AZ\n../etc\n")
        #expect(targets.map(\.name) == ["phoenix-az", "austin-tx", "etc"])
        #expect(targets[0].columns["target"] == "Phoenix AZ")
        #expect(NewBatchPrompt.parseTargets("").isEmpty && NewBatchPrompt.parseTargets("\n\n").isEmpty)
        let many = (1...150).map { "t\($0)" }.joined(separator: "\n")
        #expect(NewBatchPrompt.parseTargets(many).count == 100)
    }

    @Test func csvKeepsColumnsAndHandlesQuotes() {
        let csv = "city,state,name\nPhoenix,AZ,phoenix-az\n\"Austin, the capital\",TX,austin-tx\r\n\"say \"\"hi\"\"\",NV,vegas\n"
        let targets = NewBatchPrompt.parseTargets(csv)
        #expect(targets.map(\.name) == ["phoenix-az", "austin-tx", "vegas"])
        #expect(targets[1].columns == ["city": "Austin, the capital", "state": "TX", "name": "austin-tx"])
        #expect(targets[2].columns["city"] == "say \"hi\"")
        // Sem coluna `name`, a primeira coluna dá o nome.
        #expect(NewBatchPrompt.parseTargets("city,state\nPhoenix,AZ\n").first?.name == "phoenix")
        #expect(NewBatchPrompt.parseCSV("a,b\n1,\"x\ny\"\n") == [["a", "b"], ["1", "x\ny"]])
    }

    @Test func renderFillsTargetAndColumnsAndLeavesUnknownMarkers() {
        let target = BatchTarget(name: "phoenix-az", columns: ["city": "Phoenix", "state": "AZ"])
        #expect(NewBatchPrompt.render(brief: "Listings in {{city}}, {{state}} ({{target}}) {{missing}}", target: target) == "Listings in Phoenix, AZ (phoenix-az) {{missing}}")
    }

    @Test func promptReservesInOneCallAndTellsTheParentToCollect() {
        let request = NewBatchRequest(
            name: "listings-oct", targets: NewBatchPrompt.parseTargets("city,state\nPhoenix,AZ\nAustin,TX\n"), brief: "TASK: find {{city}}", display: .desktop,
            proxy: "zyte-us", allowedProxies: ["zyte-us", "other"])
        let prompt = NewBatchPrompt.prompt(for: request)
        #expect(prompt.contains(#"boxes_reserve(names: ["phoenix", "austin"], display: "desktop", batch: "listings-oct", proxy: "zyte-us", proxies_allowed: ["zyte-us", "other"])"#))
        #expect(prompt.contains(#"batch_collect("listings-oct")"#) && prompt.contains("1. phoenix (city=Phoenix; state=AZ)") && prompt.contains("TASK: find {{city}}"))
        let plain = NewBatchPrompt.prompt(for: NewBatchRequest(name: "b", targets: [BatchTarget(name: "x")], brief: "B"))
        #expect(plain.contains(#"display: "headless", batch: "b")"#) && !plain.contains("proxy:") && plain.contains("1 target,"))
        #expect(NewBatchPrompt.defaultName(at: Date(timeIntervalSince1970: 0)).hasPrefix("batch-") && NewBatchPrompt.defaultBrief.contains("TASK:") && NewBatchPrompt.defaultBrief.contains("OUTPUT:"))
    }
}

@Suite("T3-07 lote com o scheduler", .serialized) struct BatchFlowTests {
    static let idA = "01ARZ3NDEKTSV4RRFFQ69G5FAV"

    func reserve(_ rig: SchedulerRig, _ names: [String], batch: String = "listings-oct") async throws -> [String: String] {
        let reply = await rig.parentCall("boxes_reserve", ["names": .array(names.map { .string($0) }), "batch": .string(batch)])
        let kids = rig.childIDs(reply.json)
        for name in names { #expect(await rig.wait(name, .ready)); await rig.claim(name, as: try #require(kids[name])) }
        return kids
    }

    @Test func oneNotificationWhenTheLastChildEndsAndNeverAgain() async throws {
        // AC-429: 5 filhos, 4 concluídos e 1 falho; ao terminar o último nasce um único aviso.
        let rig = try await SchedulerRig.make(vm: SchedulerRig.twentyEightGB, workers: 8)
        defer { rig.cleanup() }
        let finished = FinishedBatches()
        await rig.scheduler.setBatchObserver { summary in Task { await finished.add(summary) } }
        let names = ["a", "b", "c", "d", "e"]
        let kids = try await reserve(rig, names)
        try await rig.seedRequest("a", id: Self.idA)
        for name in ["a", "b", "c", "d"] {
            await rig.finish(name, child: try #require(kids[name]), evidence: name == "a" ? ["/listings": [.string(Self.idA)]] : [:])
            #expect(await finished.summaries.isEmpty, "\(name) is not the last child: no notification, and never one per child")
        }
        await rig.finish("e", child: try #require(kids["e"]), result: nil)  // liberou sem entregar resultado: falho
        try await Task.sleep(for: .milliseconds(100))
        let summaries = await finished.summaries
        let summary = try #require(summaries.first)
        #expect(summaries.count == 1 && summary.name == "listings-oct" && summary.done == 4 && summary.failed == 1 && summary.isFinished && summary.verifiedFields == 1)
        #expect(summary.notificationBody.hasPrefix("4 done · 1 failed · 1 verified fields"))
        // Um `batch_collect` depois não gera outro aviso (CA-306).
        let collected = await rig.parentCall("batch_collect", ["batch": "listings-oct"])
        _ = await rig.parentCall("batch_collect", ["batch": "listings-oct"])
        try await Task.sleep(for: .milliseconds(100))
        #expect(await finished.summaries.count == 1)
        #expect(collected.json["finished"] == true && collected.json["summary"]?.array?.count == 5)
        let session = rig.root.appendingPathComponent(rig.parent)
        #expect(BatchLedger.wasNotified(session: session, batch: "listings-oct"))
        let lines = try String(contentsOf: BatchLedger.resultsFile(session: session, batch: "listings-oct"), encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 5 && collected.json["results_jsonl_path"]?.string == BatchLedger.resultsFile(session: session, batch: "listings-oct").path)
        let statuses = collected.json["summary"]?.array?.compactMap { $0["status"]?.string } ?? []
        #expect(statuses == ["done", "done", "done", "done", "failed"])
        #expect(try JSON.parse(String(lines[0]))["result"]?["listings"] == 12)
    }

    @Test func anOpenHelpRequestHoldsTheBatchUntilTheChildEnds() async throws {
        let rig = try await SchedulerRig.make(workers: 4)
        defer { rig.cleanup() }
        let finished = FinishedBatches()
        await rig.scheduler.setBatchObserver { summary in Task { await finished.add(summary) } }
        let kids = try await reserve(rig, ["a", "b"])
        await rig.finish("a", child: try #require(kids["a"]))
        let childB = try #require(kids["b"])
        let help = await rig.parentCall("help_request", ["kind": "captcha", "reason": "hCaptcha on the portal"], as: childB)
        #expect(!help.isError)
        var status = try #require(await rig.scheduler.batchSummary(parent: rig.parent, batch: "listings-oct"))
        #expect(status.needsYou == 1 && !status.isFinished && status.children.map(\.status) == [.done, .needsYou])
        let viaTool = await rig.parentCall("batch_status", ["batch": "listings-oct"])
        #expect(viaTool.json["needs_you"] == 1 && viaTool.json["done"] == 1 && viaTool.json["finished"] == false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await finished.summaries.isEmpty)
        _ = await rig.parentCall("help_cancel", ["request_id": help.json["request_id"] ?? ""], as: childB)
        await rig.finish("b", child: childB)
        try await Task.sleep(for: .milliseconds(100))
        status = try #require(await rig.scheduler.batchSummary(parent: rig.parent, batch: "listings-oct"))
        #expect(status.isFinished && status.done == 2 && status.needsYou == 0)
        #expect(await finished.summaries.count == 1)
    }

    @Test func aComputerThatNeverStartedCountsAsFailed() async throws {
        let rig = try await SchedulerRig.make(workers: 4)
        defer { rig.cleanup() }
        let finished = FinishedBatches()
        await rig.scheduler.setBatchObserver { summary in Task { await finished.add(summary) } }
        await rig.provisioning.setFailing(["bad"])
        let reply = await rig.parentCall("boxes_reserve", ["names": ["good", "bad"], "batch": "b"])
        let kids = rig.childIDs(reply.json)
        #expect(await rig.wait("good", .ready))
        await rig.claim("good", as: try #require(kids["good"]))
        await rig.finish("good", child: try #require(kids["good"]))
        try await Task.sleep(for: .milliseconds(150))
        let summary = try #require(await finished.summaries.first)
        #expect(summary.done == 1 && summary.failed == 1 && summary.children.map(\.name) == ["good", "bad"])
        #expect(rig.runFolder("bad").readMetadata()?.outcome == .failed)
    }

    @Test func batchToolsAreScopedToTheSession() async throws {
        let rig = try await SchedulerRig.make(workers: 2)
        defer { rig.cleanup() }
        _ = try await reserve(rig, ["a"])
        await rig.hub.registerParent(id: "parent-bbbbbbbb", capability: "cap-b")
        #expect(rig.errorCode(await rig.parentCall("batch_status", ["batch": "listings-oct"], as: "parent-bbbbbbbb")) == "not_found")
        #expect(rig.errorCode(await rig.parentCall("batch_collect", ["batch": "listings-oct"], as: "parent-bbbbbbbb")) == "not_found")
        #expect(rig.errorCode(await rig.parentCall("batch_status", ["batch": "nope"])) == "not_found")
        #expect(await rig.scheduler.batchNames(parent: rig.parent) == ["listings-oct"])
    }

    @Test func archiveBatchStopsOnlyThatBatch() async throws {
        let rig = try await SchedulerRig.make(workers: 4)
        defer { rig.cleanup() }
        let reply = await rig.parentCall("boxes_reserve", ["names": ["a", "b"], "batch": "one"])
        _ = await rig.parentCall("boxes_reserve", ["names": ["c"], "batch": "two"])
        for n in ["a", "b", "c"] { #expect(await rig.wait(n, .ready)) }
        _ = reply
        #expect(await rig.scheduler.archiveBatch(parent: rig.parent, batch: "one") == ["a", "b"])
        let tornDown = Set(await rig.provisioning.tornDown)
        let stillThere = await rig.hub.computer(named: "c")
        #expect(tornDown == ["a", "b"] && stillThere != nil)
        let two = try #require(await rig.scheduler.batchSummary(parent: rig.parent, batch: "two"))
        #expect(two.children.map(\.status) == [.running])
        let one = try #require(await rig.scheduler.batchSummary(parent: rig.parent, batch: "one"))
        #expect(one.children.map(\.status) == [.stopped, .stopped] && one.isFinished)
    }
}
