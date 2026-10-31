import RackyDocker
import Foundation
import Testing

@testable import RackyCore

// T3-06 (AC-420…423): `box_collect` lê o run folder (mesmo sem o computador), refaz a validação contra o reqlog de hoje e devolve ao pai
// resultado, marcas por afirmação e timeline. Unidade sobre pastas temporárias; a integração com o scheduler está em `ResultFlowTests`.

enum RunFixture {
    static let ids = ["01ARZ3NDEKTSV4RRFFQ69G5FAV", "01ARZ3NDEKTSV4RRFFQ69G5FAW", "01ARZ3NDEKTSV4RRFFQ69G5FAX", "01ARZ3NDEKTSV4RRFFQ69G5FAY"]

    static func temp() throws -> RunFolder {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("abx-run-\(UUID().uuidString.lowercased())/phoenix-az", isDirectory: true)
        let run = RunFolder(root: root)
        try run.ensureLayout()
        return run
    }

    static func cleanup(_ run: RunFolder) { try? FileManager.default.removeItem(at: run.root.deletingLastPathComponent()) }

    /// Registros do reqlog com a cadeia de hash válida (como o egress grava).
    static func seed(_ run: RunFolder, _ records: [(id: String, trust: String)]) async throws {
        let log = ChainedLog(file: run.requestsFile)
        for (n, record) in records.enumerated() {
            try await log.append([
                "id": .string(record.id), "trust": .string(record.trust), "method": "GET", "status": 200, "source": "browser",
                "url": .string("https://aca-prod.example.test/listings/\(n)"),
            ])
        }
    }

    static func write(_ run: RunFolder, result json: String) throws {
        try Data(json.utf8).write(to: run.resultFile)
    }
}

@Suite("T3-06 coleta do run") struct ResultCollectorTests {
    @Test func handwrittenResultWithFiveClaimsIsMarkedPerField() async throws {
        // AC-421: 5 afirmações; 3 citam ids que existem, 1 cita um id inexistente e 1 não cita nada.
        let run = try RunFixture.temp()
        defer { RunFixture.cleanup(run) }
        let ids = RunFixture.ids
        try await RunFixture.seed(run, [(ids[0], "observed"), (ids[1], "observed"), (ids[2], "reported")])
        try RunFixture.write(run, result: """
            {"listings": 12, "owner": "ACME LLC (request \(ids[1]))", "status": "Issued — \(ids[2])", "ghost": "see \(ids[3])", "notes": "looks fine"}
            """)
        let collected = RunCollector.collect(run: run, name: "phoenix-az")
        #expect(collected.handwritten, "result.json was not written by result_submit")
        #expect(collected.totalFields == 5)
        let by = Dictionary(uniqueKeysWithValues: collected.fields.map { ($0.pointer, $0) })
        #expect(by["/owner"]?.status == .verified && by["/status"]?.status == .verified)
        #expect(by["/ghost"]?.status == .citedMissing && by["/ghost"]?.statusLabel == "Cited request not found")
        #expect(by["/notes"]?.status == .notVerified && by["/notes"]?.statusLabel == "Not verified")
        #expect(by["/listings"]?.status == .notVerified)
        #expect(collected.verified == 2 && collected.citedMissing == 1 && collected.notVerified == 2)
        // O link leva ao request do reqlog, com o selo do trust (CS-263).
        let link = try #require(by["/status"]?.links.first)
        #expect(link.kind == .request && link.exists && link.trust == "reported" && link.summary?.hasPrefix("200 GET https://aca-prod") == true)
        #expect(by["/ghost"]?.links.first?.exists == false)
        #expect(collected.integrity == .ok(lines: 3))
    }

    @Test func submittedResultKeepsItsFileCitationsAndAHandEditInvalidatesThem() async throws {
        let run = try RunFixture.temp()
        defer { RunFixture.cleanup(run) }
        let id = RunFixture.ids[0]
        try await RunFixture.seed(run, [(id, "observed")])
        try Data("a,b\n1,2\n".utf8).write(to: run.work.appendingPathComponent("listings.csv"))
        let result: JSON = ["total": 12, "csv": "listings.csv"]
        let data = result.data(pretty: true)
        try data.write(to: run.resultFile)
        let stored: JSON = [
            "result_sha256": .string(RunCollector.sha256(data)),
            "fields": [["pointer": "/total", "citations": [["ref": .string(id)]]], ["pointer": "/csv", "citations": [["ref": "/work/listings.csv"]]]],
        ]
        try stored.data().write(to: run.validationFile)

        var collected = RunCollector.collect(run: run, name: "phoenix-az")
        #expect(!collected.handwritten && collected.verified == 2)
        let file = try #require(collected.fields.first { $0.pointer == "/csv" }?.links.first)
        #expect(file.kind == .file && file.exists && file.fileURL?.lastPathComponent == "listings.csv")

        // Reescrito à mão depois do result_submit: as marcas velhas não valem, volta o padrão de ids.
        try RunFixture.write(run, result: #"{"total": 99, "csv": "listings.csv"}"#)
        collected = RunCollector.collect(run: run, name: "phoenix-az")
        #expect(collected.handwritten && collected.verified == 0 && collected.notVerified == 2)
    }

    @Test func citationsThatEscapeWorkOrFollowSymlinksNeverVerify() async throws {
        let run = try RunFixture.temp()
        defer { RunFixture.cleanup(run) }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("abx-secret-\(UUID().uuidString.lowercased())")
        try Data("secret".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: run.work.appendingPathComponent("leak.txt"), withDestinationURL: outside)
        let data = (["a": "x", "b": "y"] as JSON).data(pretty: true)
        try data.write(to: run.resultFile)
        let stored: JSON = [
            "result_sha256": .string(RunCollector.sha256(data)),
            "fields": [["pointer": "/a", "citations": [["ref": "/work/leak.txt"]]], ["pointer": "/b", "citations": [["ref": "../../etc/passwd"]]]],
        ]
        try stored.data().write(to: run.validationFile)
        let collected = RunCollector.collect(run: run, name: "phoenix-az")
        #expect(collected.verified == 0)
        #expect(collected.fields.allSatisfy { $0.status == .citedMissing && $0.links.allSatisfy { !$0.exists && $0.fileURL == nil } })
    }

    @Test func aSymlinkedResultJSONIsNotFollowed() throws {
        let run = try RunFixture.temp()
        defer { RunFixture.cleanup(run) }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("abx-secret-\(UUID().uuidString.lowercased()).json")
        try Data(#"{"stolen": true}"#.utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: run.resultFile, withDestinationURL: outside)
        let collected = RunCollector.collect(run: run, name: "phoenix-az")
        #expect(collected.result == nil && collected.fields.isEmpty)
        #expect(collected.resultNote?.contains("symlinks") == true)
    }

    @Test func missingOrInvalidResultsExplainThemselves() throws {
        let run = try RunFixture.temp()
        defer { RunFixture.cleanup(run) }
        #expect(RunCollector.collect(run: run, name: "x").resultNote == "No result.json yet")
        try RunFixture.write(run, result: "not json")
        #expect(RunCollector.collect(run: run, name: "x").resultNote == "result.json is not valid JSON")
        try RunFixture.write(run, result: "[1,2]")
        #expect(RunCollector.collect(run: run, name: "x").resultNote == "result.json must be an object")
    }

    @Test func tamperedLogsAreFlagged() async throws {
        let run = try RunFixture.temp()
        defer { RunFixture.cleanup(run) }
        try await RunFixture.seed(run, [(RunFixture.ids[0], "observed"), (RunFixture.ids[1], "observed")])
        var text = try String(contentsOf: run.requestsFile, encoding: .utf8)
        text = text.replacingOccurrences(of: "listings/0", with: "listings/9")
        try Data(text.utf8).write(to: run.requestsFile)
        #expect(RunCollector.collect(run: run, name: "x").integrity == .tampered(line: 2))
    }

    @Test func jsonRespectsIncludeAndKeepsTheSummaryUnder20kCharacters() async throws {
        let run = try RunFixture.temp()
        defer { RunFixture.cleanup(run) }
        try await RunFixture.seed(run, [(RunFixture.ids[0], "observed")])
        var fields: [String: JSON] = [:]
        for i in 0..<400 { fields["field\(i)"] = .string(String(repeating: "x", count: 200) + " \(RunFixture.ids[0])") }
        try JSON.object(fields).data().write(to: run.resultFile)
        try Data(String(repeating: "12:00:00.000  HTTP    200 GET /x\n", count: 2000).utf8).write(to: run.timelineFile)
        let collected = RunCollector.collect(run: run, name: "phoenix-az")
        let full = collected.json()
        #expect(full["summary_md"]?.string?.count ?? .max <= RunCollector.summaryLimit)
        #expect(full["result"]?["truncated"] == true, "a result bigger than the summary limit goes by path, not inline")
        #expect(full["paths"]?["work"]?.string == run.work.path && full["validation"]?["summary"]?["verified"] == 400)
        let only = collected.json(include: [.validation])
        #expect(only["result"] == nil && only["timeline_md"] == nil && only["validation"] != nil && only["summary_md"] != nil)
    }

    @Test func summaryMarksUnverifiedClaimsForTheParent() async throws {
        let run = try RunFixture.temp()
        defer { RunFixture.cleanup(run) }
        try await RunFixture.seed(run, [(RunFixture.ids[0], "observed")])
        try RunFixture.write(run, result: #"{"price": "10 \#(RunFixture.ids[0])", "claim": "unsupported", "ghost": "\#(RunFixture.ids[3])"}"#)
        let md = RunCollector.collect(run: run, name: "phoenix-az").summaryMarkdown()
        #expect(md.contains("phoenix-az: 1 verified · 1 cited request not found · 1 not verified"))
        #expect(md.contains("| /claim | unsupported | Not verified | - |"))
        #expect(md.contains("\(RunFixture.ids[3]) (not found)"))
        #expect(md.contains("Log integrity: OK"))
    }
}

@Suite("T3-06 pasta do run no host") struct RunArchiveTests {
    @Test func metadataRoundTripsAndNeedsNoNetwork() throws {
        let run = try RunFixture.temp()
        defer { RunFixture.cleanup(run) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var meta = RunMetadata(computer: "phoenix-az", display: "headless", proxy: "zyte-us", parent: "parent-1", child: "parent-1-w1", batch: "listings-oct", session: "listings-oct", startedAt: start)
        run.writeMetadata(meta)
        #expect(run.readMetadata() == meta && run.readMetadata()?.outcome == .running && run.readMetadata()?.durationSeconds == nil)
        meta.endedAt = start.addingTimeInterval(125)
        meta.outcome = .released
        run.writeMetadata(meta)
        #expect(run.readMetadata()?.durationSeconds == 125 && run.readMetadata()?.outcome == .released)
        #expect(FileManager.default.fileExists(atPath: run.root.appendingPathComponent("box.json").path))
    }

    @Test func aRepeatedNameArchivesThePreviousRunAndNeverDeletesIt() async throws {
        let run = try RunFixture.temp()
        defer { RunFixture.cleanup(run) }
        #expect(!run.hasContent, "the empty layout is not a previous run")
        #expect(try RunArchive.archivePrevious(run: run, name: "phoenix-az") == nil)
        try RunFixture.write(run, result: #"{"a": 1}"#)
        try Data("ok".utf8).write(to: run.logs.appendingPathComponent("journal.jsonl"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try #require(try RunArchive.archivePrevious(run: run, name: "phoenix-az", now: now))
        #expect(first.deletingLastPathComponent().lastPathComponent == "_archive" && first.lastPathComponent.hasPrefix("phoenix-az-"))
        #expect(FileManager.default.fileExists(atPath: first.appendingPathComponent("work/result.json").path))
        #expect(!FileManager.default.fileExists(atPath: run.root.path), "the live folder is free for the new run")
        // Dois arquivamentos no mesmo segundo não se sobrescrevem.
        try run.ensureLayout()
        try RunFixture.write(run, result: #"{"a": 2}"#)
        let second = try #require(try RunArchive.archivePrevious(run: run, name: "phoenix-az", now: now))
        #expect(second != first && FileManager.default.fileExists(atPath: first.path) && FileManager.default.fileExists(atPath: second.path))
    }

    /// `runs/<sessão>/<computador>` com `box.json` terminado há `daysAgo` dias, `policy` gravada e 4 KB no `work/` (mais o resultado).
    private func finishedRun(_ runs: URL, _ path: String, policy: LeftoversPolicy?, daysAgo: Double, now: Date) throws -> RunFolder {
        let run = RunFolder(root: runs.appendingPathComponent(path, isDirectory: true))
        try run.ensureLayout()
        try FileManager.default.createDirectory(at: run.work.appendingPathComponent("repo"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: run.work.appendingPathComponent("repo/big.bin"))
        try Data(#"{"ok": true}"#.utf8).write(to: run.resultFile)
        try Data("log".utf8).write(to: run.requestsFile)
        let ended = now.addingTimeInterval(-daysAgo * 86_400)
        run.writeMetadata(RunMetadata(
            computer: run.root.lastPathComponent, display: "headless", parent: "p", startedAt: ended.addingTimeInterval(-60), endedAt: ended,
            outcome: .released, leftovers: policy))
        return run
    }

    @Test func theSweepEmptiesOnlyWorkFoldersWhoseDeadlinePassed() throws {
        let runs = FileManager.default.temporaryDirectory.appendingPathComponent("abx-runs-\(UUID().uuidString.lowercased())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: runs) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let due = try finishedRun(runs, "s/due", policy: .days7, daysAgo: 8, now: now)
        let early = try finishedRun(runs, "s/early", policy: .days7, daysAgo: 2, now: now)
        let done = try finishedRun(runs, "s/_archive/done-20261026-120000", policy: .whenDone, daysAgo: 0.01, now: now)
        let kept = try finishedRun(runs, "s/kept", policy: .keep, daysAgo: 90, now: now)
        let legacy = try finishedRun(runs, "s/legacy", policy: nil, daysAgo: 90, now: now)
        let busy = try finishedRun(runs, "s/busy", policy: .whenDone, daysAgo: 1, now: now)
        #expect(RunLeftovers.list(runsRoot: runs).count == 6)
        #expect(RunLeftovers.list(runsRoot: runs).first { $0.key == "s/_archive/done-20261026-120000" } != nil, "archived copies are listed")

        let freed = RunLeftovers.sweep(runsRoot: runs, active: [busy.root.standardizedFileURL.path], now: now)
        #expect(freed > 0)
        for run in [due, done] {
            #expect(!FileManager.default.fileExists(atPath: run.work.appendingPathComponent("repo").path))
            #expect(FileManager.default.fileExists(atPath: run.resultFile.path), "the result stays")
            #expect(FileManager.default.fileExists(atPath: run.requestsFile.path), "logs stay")
            #expect(run.readMetadata()?.leftoversDeletedAt == now)
        }
        for run in [early, kept, legacy, busy] {
            #expect(FileManager.default.fileExists(atPath: run.work.appendingPathComponent("repo/big.bin").path))
        }
        #expect(Set(RunLeftovers.list(runsRoot: runs).map(\.key)) == ["s/early", "s/kept", "s/legacy", "s/busy"])
        #expect(StorageUsage.measure(runsRoot: runs, runtimeRoot: runs.appendingPathComponent("missing")).leftovers > 0)

        // Clean up now: tudo o que terminou e não está em Keep, os runs de antes da escolha também.
        RunLeftovers.cleanAll(runsRoot: runs, active: [busy.root.standardizedFileURL.path], now: now)
        #expect(Set(RunLeftovers.list(runsRoot: runs).map(\.key)) == ["s/kept", "s/busy"])
    }

    @Test func keepRemovesTheDeadlineAndKeysStayInsideTheRunsFolder() throws {
        let runs = FileManager.default.temporaryDirectory.appendingPathComponent("abx-runs-\(UUID().uuidString.lowercased())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: runs) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let run = try finishedRun(runs, "s/chicago", policy: .days7, daysAgo: 1, now: now)
        let item = try #require(RunLeftovers.list(runsRoot: runs).first)
        #expect(item.key == "s/chicago" && item.due == now.addingTimeInterval(6 * 86_400))
        #expect(RunLeftovers.run(key: "s/chicago", runsRoot: runs)?.root.standardizedFileURL == run.root.standardizedFileURL)
        #expect(RunLeftovers.run(key: "../s/chicago", runsRoot: runs) == nil)
        #expect(RunLeftovers.run(key: "s/missing", runsRoot: runs) == nil)
        RunLeftovers.keep(run)
        #expect(RunLeftovers.sweep(runsRoot: runs, now: now.addingTimeInterval(365 * 86_400)) == 0)
        #expect(RunLeftovers.list(runsRoot: runs).first?.policy == .keep)
        // Um run arquivado leva a escolha junto.
        _ = try RunArchive.archivePrevious(run: run, name: "chicago", now: now)
        #expect(RunLeftovers.list(runsRoot: runs).first?.key.hasPrefix("s/_archive/chicago-") == true)
        #expect(RunLeftovers.list(runsRoot: runs).first?.policy == .keep)
    }

    @Test func sessionFoldersListRunsButNotTheArchiveOrBatchMarkers() throws {
        let run = try RunFixture.temp()
        defer { RunFixture.cleanup(run) }
        let session = run.root.deletingLastPathComponent()
        let other = RunFolder(root: session.appendingPathComponent("austin-tx", isDirectory: true))
        try other.ensureLayout()
        try FileManager.default.createDirectory(at: session.appendingPathComponent("_archive/phoenix-az-1"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: session.appendingPathComponent("_batches/listings-oct"), withIntermediateDirectories: true)
        #expect(RunArchive.runs(inSession: session).map { $0.root.lastPathComponent } == ["austin-tx", "phoenix-az"])
    }

    @Test func sessionSlugs() {
        #expect(RunArchive.slug("Listings Oct!", fallback: "p") == "listings-oct")
        #expect(RunArchive.slug("  houston / listings  ", fallback: "p") == "houston-listings")
        #expect(RunArchive.slug("日本語", fallback: "abcd1234") == "abcd1234")
        #expect(RunArchive.slug(nil, fallback: "abcd1234") == "abcd1234")
        #expect(RunArchive.slug("../../etc", fallback: "p") == "etc", "no path separators survive")
    }
}
