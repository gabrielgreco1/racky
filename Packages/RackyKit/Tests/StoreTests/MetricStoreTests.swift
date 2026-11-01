import RackyPlatform
import Foundation
import Testing
@testable import RackyStore

@Suite struct MetricStoreTests {
    @Test func recordsSummarizesAndPrunes() async throws {
        let home = try TempHome(); defer { home.remove() }
        let store = try await home.openStore()
        let now = Date()
        var samples = (1 ... 100).map { MetricSample(name: "attach.replay", value: Double($0), tags: ["mode": "snapshot"], at: now) }
        samples.append(MetricSample(name: "launch.agent", value: 900, tags: [:], at: now))
        samples.append(MetricSample(name: "attach.replay", value: 99_999, at: now.addingTimeInterval(-8 * 86_400)))
        try await store.recordMetrics(samples)

        let summaries = try await store.metricSummaries(since: now.addingTimeInterval(-7 * 86_400))
        #expect(summaries.map(\.name) == ["attach.replay", "launch.agent"])
        let attach = try #require(summaries.first)
        #expect(attach.count == 100 && attach.p50 == 50 && attach.p95 == 95 && attach.max == 100, "o ponto de 8 dias fica de fora")

        #expect(try await store.pruneMetrics(olderThan: now.addingTimeInterval(-7 * 86_400)) == 1)
        let rows = try await store.metrics(since: now.addingTimeInterval(-86_400))
        #expect(rows.count == 101 && rows.first?.tags["mode"] == "snapshot")
        try await store.close()
    }

    @Test func tableCountsHaveNoContentAndMigrationsAreListed() async throws {
        let home = try TempHome(); defer { home.remove() }
        let store = try await home.openStore()
        try await store.save(Fixture.project())
        let counts = try await store.tableCounts()
        #expect(counts["project"] == 1 && counts["metric"] == 0 && counts["session"] == 0)
        #expect(try await store.appliedMigrations().last == "v11_subagent_harness")
        try await store.close()
    }
}
