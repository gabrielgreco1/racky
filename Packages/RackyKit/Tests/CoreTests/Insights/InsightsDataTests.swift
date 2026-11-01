import Foundation
import Testing

@testable import RackyCore

@Suite struct InsightsParsingTests {
    @Test func isoTimestamps() {
        #expect(ISOTimestamp.parse("2026-10-17T12:00:00.000Z") == InsightsFixtures.now)
        #expect(ISOTimestamp.parse("2026-10-17T12:00:00Z") == InsightsFixtures.now)
        #expect(ISOTimestamp.parse("2026-10-17T09:00:00-03:00") == InsightsFixtures.now)
        #expect(ISOTimestamp.parse("2026-10-17T12:00:00.500Z")!.timeIntervalSince(InsightsFixtures.now) == 0.5)
        #expect(ISOTimestamp.parse("2026-13-17T12:00:00Z") == nil)
        #expect(ISOTimestamp.parse("garbage") == nil)
        #expect(ISOTimestamp.parse("") == nil)
    }

    @Test func claudeLineParsesUsageAndCacheBreakdown() throws {
        let line = InsightsFixtures.claudeLine(id: "m1", at: InsightsFixtures.now, input: 5, output: 7, cacheRead: 100, cache5m: 11, cache1h: 13, sidechain: true)
        let parsed = try #require(ClaudeTranscriptParser.parse(Data(line.utf8)))
        #expect(parsed.counts == TokenCounts(input: 5, output: 7, cacheRead: 100, cacheWrite5m: 11, cacheWrite1h: 13))
        #expect(parsed.model == "claude-opus-4-5")
        #expect(parsed.sessionID == "sess-a")
        #expect(parsed.isSidechain)
        #expect(parsed.timestamp == InsightsFixtures.now)
    }

    @Test func claudeLineWithoutBreakdownCountsCacheCreationAs5m() throws {
        let line = InsightsFixtures.claudeLine(id: "m1", at: InsightsFixtures.now, cache5m: 40, breakdown: false)
        let parsed = try #require(ClaudeTranscriptParser.parse(Data(line.utf8)))
        #expect(parsed.counts.cacheWrite5m == 40)
        #expect(parsed.counts.cacheWrite1h == 0)
    }

    @Test func corruptAndIrrelevantLinesAreIgnored() {
        for l in InsightsFixtures.corruptLines + [InsightsFixtures.userLine] {
            #expect(ClaudeTranscriptParser.parse(Data(l.utf8)) == nil)
        }
        let synthetic = InsightsFixtures.claudeLine(id: "x", model: "<synthetic>", at: InsightsFixtures.now)
        #expect(ClaudeTranscriptParser.parse(Data(synthetic.utf8)) == nil)
        let negative = InsightsFixtures.claudeLine(id: "x", at: InsightsFixtures.now, input: 0, output: 0)
        #expect(ClaudeTranscriptParser.parse(Data(negative.utf8)) == nil)
    }

    @Test func codexEvents() {
        let t = InsightsFixtures.now
        #expect(CodexRolloutParser.parse(Data(InsightsFixtures.codexMeta(id: "c1", at: t).utf8)) == [.sessionMeta(id: "c1", cwd: "/work/beta")])
        #expect(CodexRolloutParser.parse(Data(InsightsFixtures.codexTurn(model: "gpt-5.6", at: t).utf8)) == [.model("gpt-5.6")])
        let line = InsightsFixtures.codexTokens(input: 1000, cached: 400, output: 50, at: t, primary: (12.5, 300, t.timeIntervalSince1970 + 600),
                                                secondary: (3, 10_080, t.timeIntervalSince1970 + 9000), plan: "plus")
        let events = CodexRolloutParser.parse(Data(line.utf8))
        #expect(events.count == 2)
        #expect(events[0] == .tokenTotals(TokenCounts(input: 600, output: 50, cacheRead: 400), at: t))
        guard case .limits(let snap) = events[1] else { Issue.record("sem limites"); return }
        #expect(snap.primary?.usedPercent == 12.5)
        #expect(snap.primary?.windowMinutes == 300)
        #expect(snap.secondary?.windowMinutes == 10_080)
        #expect(snap.planType == "plus")
    }

    @Test func codexLimitsAcceptRelativeResetsInSeconds() {
        let t = InsightsFixtures.now
        let line = "{\"timestamp\":\"\(InsightsFixtures.iso(t))\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":null,"
            + "\"rate_limits\":{\"primary\":{\"used_percent\":67.5,\"window_minutes\":300,\"resets_in_seconds\":6840},"
            + "\"secondary\":{\"used_percent\":88,\"window_minutes\":10080,\"resets_in_seconds\":172800},\"plan_type\":\"pro\"}}}"
        guard case .limits(let snap)? = CodexRolloutParser.parse(Data(line.utf8)).first else { Issue.record("sem limites"); return }
        #expect(snap.primary?.resetsAt == t.addingTimeInterval(6840))
        #expect(snap.secondary?.resetsAt == t.addingTimeInterval(172_800))
        let reported = CodexRateLimits.reported(snap, now: t)
        #expect(reported.fiveHour?.usedFraction == 0.675)
        #expect(reported.sevenDay?.usedFraction == 0.88)
    }

    @Test func codexLimitsNullAndCorruptLines() {
        let t = InsightsFixtures.now
        let nulls = InsightsFixtures.codexTokens(input: 10, cached: 0, output: 1, at: t)
        let events = CodexRolloutParser.parse(Data(nulls.utf8))
        #expect(events.count == 1)  // só tokens: limites null não geram evento
        for l in InsightsFixtures.corruptLines { #expect(CodexRolloutParser.parse(Data(l.utf8)).isEmpty) }
    }
}

@Suite struct InsightsReaderTests {
    @Test func incrementalReadConsumesOnlyCompleteLines() throws {
        let dir = try InsightsFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.jsonl")
        try Data("one\ntwo\npartial".utf8).write(to: file)
        var seen: [String] = []
        let c1 = JSONLReader.readLines(path: file.path, cursor: nil) { seen.append(String(decoding: $0, as: UTF8.self)) }
        #expect(seen == ["one", "two"])
        // A linha parcial só é consumida quando completa.
        let h = try FileHandle(forWritingTo: file)
        try h.seekToEnd()
        try h.write(contentsOf: Data("-done\nthree\n".utf8))
        try h.close()
        let c2 = JSONLReader.readLines(path: file.path, cursor: c1) { seen.append(String(decoding: $0, as: UTF8.self)) }
        #expect(seen == ["one", "two", "partial-done", "three"])
        // Sem mudança: nada novo.
        var again = 0
        _ = JSONLReader.readLines(path: file.path, cursor: c2) { _ in again += 1 }
        #expect(again == 0)
    }

    @Test func truncatedFileRestartsFromTheBeginning() throws {
        let dir = try InsightsFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.jsonl")
        try Data("aaaaaaaa\nbbbbbbbb\n".utf8).write(to: file)
        let c1 = JSONLReader.readLines(path: file.path, cursor: nil) { _ in }
        try Data("x\n".utf8).write(to: file)
        var seen: [String] = []
        _ = JSONLReader.readLines(path: file.path, cursor: c1) { seen.append(String(decoding: $0, as: UTF8.self)) }
        #expect(seen == ["x"])
    }

    @Test func missingFileYieldsNilAndHugeLinesAreSkipped() throws {
        #expect(JSONLReader.readLines(path: "/nonexistent/racky.jsonl", cursor: nil) { _ in } == nil)
        let dir = try InsightsFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("big.jsonl")
        let huge = String(repeating: "x", count: JSONLReader.maxLineBytes + 10)
        try Data(("ok1\n" + huge + "\nok2\n").utf8).write(to: file)
        var seen: [String] = []
        _ = JSONLReader.readLines(path: file.path, cursor: nil, chunkBytes: 8 * 1024 * 1024) { seen.append(String(decoding: $0.prefix(8), as: UTF8.self)) }
        #expect(seen.first == "ok1")
        #expect(seen.last == "ok2")
    }
}

@Suite struct InsightsLedgerTests {
    let now = InsightsFixtures.now

    func ledgerFor(_ lines: [String], cutoffDays: Double = 35, file: String = "s.jsonl") throws -> (UsageLedger, URL, URL) {
        let dir = try InsightsFixtures.tempDirectory()
        let url = dir.appendingPathComponent(file)
        try InsightsFixtures.write(lines, to: url)
        var ledger = UsageLedger()
        ledger.ingestClaude(path: url.path, cutoff: now.addingTimeInterval(-cutoffDays * 86_400))
        return (ledger, url, dir)
    }

    @Test func streamingLinesOfOneMessageCountOnceWithMaxUsage() throws {
        let lines = [
            InsightsFixtures.claudeLine(id: "m1", at: now, input: 10, output: 1),
            InsightsFixtures.claudeLine(id: "m1", at: now, input: 10, output: 30),
            InsightsFixtures.userLine,
            InsightsFixtures.claudeLine(id: "m2", at: now, input: 5, output: 5, sidechain: true),
        ] + InsightsFixtures.corruptLines
        let (ledger, _, dir) = try ledgerFor(lines)
        defer { try? FileManager.default.removeItem(at: dir) }
        let total = ledger.buckets.values.reduce(TokenCounts.zero) { $0 + $1.counts }
        #expect(total == TokenCounts(input: 15, output: 35))
        #expect(ledger.buckets.values.reduce(0) { $0 + $1.messages } == 2)
        #expect(ledger.buckets.values.reduce(0) { $0 + $1.sidechainMessages } == 1)
        #expect(ledger.sessionLabels["sess-a"] == "alpha")
    }

    @Test func messageSplitAcrossTwoReadsIsNotDoubleCounted() throws {
        let (first, url, dir) = try ledgerFor([InsightsFixtures.claudeLine(id: "m1", at: now, input: 10, output: 1)])
        defer { try? FileManager.default.removeItem(at: dir) }
        var ledger = first
        try InsightsFixtures.write([InsightsFixtures.claudeLine(id: "m1", at: now, input: 10, output: 40)], to: url, append: true)
        ledger.ingestClaude(path: url.path, cutoff: now.addingTimeInterval(-86_400))
        let total = ledger.buckets.values.reduce(TokenCounts.zero) { $0 + $1.counts }
        #expect(total == TokenCounts(input: 10, output: 40))
        #expect(ledger.buckets.values.reduce(0) { $0 + $1.messages } == 1)
    }

    @Test func sameMessageInAnotherFileIsSkipped() throws {
        let line = InsightsFixtures.claudeLine(id: "dup", at: now, input: 3, output: 4)
        let (first, _, dir) = try ledgerFor([line])
        defer { try? FileManager.default.removeItem(at: dir) }
        var ledger = first
        let other = dir.appendingPathComponent("resumed.jsonl")
        try InsightsFixtures.write([line, InsightsFixtures.claudeLine(id: "new", at: now, input: 1, output: 1)], to: other)
        ledger.ingestClaude(path: other.path, cutoff: now.addingTimeInterval(-86_400))
        #expect(ledger.buckets.values.reduce(0) { $0 + $1.messages } == 2)
        #expect(ledger.buckets.values.reduce(TokenCounts.zero) { $0 + $1.counts }.input == 4)
    }

    @Test func eventsBeforeTheCutoffAreDropped() throws {
        let old = InsightsFixtures.claudeLine(id: "old", at: now.addingTimeInterval(-40 * 86_400))
        let fresh = InsightsFixtures.claudeLine(id: "fresh", at: now.addingTimeInterval(-3600))
        let (ledger, _, dir) = try ledgerFor([old, fresh])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ledger.buckets.values.reduce(0) { $0 + $1.messages } == 1)
    }

    @Test func codexDeltasFromCumulativeTotals() throws {
        let dir = try InsightsFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("rollout-2026-10-17T12-00-00-x.jsonl")
        let t = now
        try InsightsFixtures.write([
            InsightsFixtures.codexMeta(id: "c1", at: t), InsightsFixtures.codexTurn(model: "gpt-5.6-luna", at: t),
            InsightsFixtures.codexTokens(input: 1000, cached: 200, output: 100, at: t.addingTimeInterval(10)),
            InsightsFixtures.codexTokens(input: 1000, cached: 200, output: 100, at: t.addingTimeInterval(11)),  // repetido: delta 0
            InsightsFixtures.codexTokens(input: 3000, cached: 1200, output: 160, at: t.addingTimeInterval(20),
                                         primary: (40, 300, t.timeIntervalSince1970 + 3600), secondary: (10, 10_080, t.timeIntervalSince1970 + 86_400), plan: "pro"),
        ], to: url)
        var ledger = UsageLedger()
        let added = ledger.ingestCodex(path: url.path, cutoff: t.addingTimeInterval(-86_400))
        #expect(added == 2)
        let total = ledger.buckets.values.reduce(TokenCounts.zero) { $0 + $1.counts }
        #expect(total == TokenCounts(input: 1800, output: 160, cacheRead: 1200))
        #expect(ledger.buckets.values.allSatisfy { $0.model == "gpt-5.6-luna" && $0.session == "c1" })
        #expect(ledger.codexLimits?.primary?.usedPercent == 40)
        #expect(ledger.codexLimits?.planType == "pro")
    }

    @Test func pruneRemovesOldBucketsAndMissingFiles() throws {
        let (first, url, dir) = try ledgerFor([InsightsFixtures.claudeLine(id: "a", at: now.addingTimeInterval(-3600))])
        defer { try? FileManager.default.removeItem(at: dir) }
        var ledger = first
        ledger.prune(before: now, existingPaths: [url.path])
        #expect(ledger.buckets.isEmpty)
        #expect(ledger.files[url.path] != nil)
        ledger.prune(before: now.addingTimeInterval(-86_400), existingPaths: [])
        #expect(ledger.files.isEmpty)
    }

    @Test func ledgerRoundTripsThroughDisk() throws {
        let (ledger, _, dir) = try ledgerFor([InsightsFixtures.claudeLine(id: "a", at: now.addingTimeInterval(-3600))])
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = dir.appendingPathComponent("ledger.json")
        try UsageLedgerStore.save(ledger, to: store)
        #expect(UsageLedgerStore.load(from: store) == ledger)
        try Data("{broken".utf8).write(to: store)
        #expect(UsageLedgerStore.load(from: store) == UsageLedger())
        // Nenhum texto de conversa entra no livro-razão.
        let text = String(decoding: try JSONEncoder().encode(ledger), as: UTF8.self)
        #expect(!text.contains("SYNTHETIC-CONTENT"))
    }
}
