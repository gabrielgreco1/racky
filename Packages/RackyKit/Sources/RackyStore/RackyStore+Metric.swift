import RackyPlatform
import Foundation
import GRDB

// Tabela `metric` (v2_activity, 08 AR-605): durações dos pontos quentes. Só números e tags curtas, nunca conteúdo do usuário.

/// Resumo por nome para a tela Diagnostics (p50/p95 dos últimos 7 dias).
public struct MetricSummary: Sendable, Equatable {
    public var name: String
    public var count: Int
    public var p50: Double
    public var p95: Double
    public var max: Double
    public var unit: String

    /// Percentil "nearest rank" sobre valores já ordenados.
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((Double(sorted.count) * p).rounded(.up)) - 1
        return sorted[Swift.max(0, Swift.min(sorted.count - 1, rank))]
    }
}

public struct StoredMetric: Sendable, Equatable {
    public var name: String
    public var value: Double
    public var unit: String
    public var tags: [String: String]
    public var at: Date

    public init(name: String, value: Double, unit: String = "ms", tags: [String: String] = [:], at: Date = Date()) {
        self.name = name; self.value = value; self.unit = unit; self.tags = tags; self.at = at
    }
}

extension RackyStore {
    public func recordMetrics(_ samples: [MetricSample]) async throws {
        guard !samples.isEmpty else { return }
        try await write { db in
            for sample in samples {
                let tags = (try? JSONSerialization.data(withJSONObject: sample.tags, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                try db.execute(
                    sql: "INSERT INTO metric (id, name, value, unit, tags_json, at) VALUES (?, ?, ?, ?, ?, ?)",
                    arguments: [UUID().uuidString, sample.name, sample.value, sample.unit, tags, Int64(sample.at.timeIntervalSince1970 * 1000)])
            }
        }
    }

    /// Apaga o que passou da retenção (7 dias por padrão) e devolve quantas linhas saíram.
    @discardableResult
    public func pruneMetrics(olderThan cutoff: Date) async throws -> Int {
        let ms = Int64(cutoff.timeIntervalSince1970 * 1000)
        return try await write { db in
            try db.execute(sql: "DELETE FROM metric WHERE at < ?", arguments: [ms])
            return db.changesCount
        }
    }

    public func metrics(since: Date) async throws -> [StoredMetric] {
        let ms = Int64(since.timeIntervalSince1970 * 1000)
        return try await read { db in
            try Row.fetchAll(db, sql: "SELECT name, value, unit, tags_json, at FROM metric WHERE at >= ? ORDER BY at", arguments: [ms]).map { row in
                let tags = (row["tags_json"] as String?).flatMap { $0.data(using: .utf8) }
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
                return StoredMetric(
                    name: row["name"], value: row["value"], unit: row["unit"] ?? "", tags: tags,
                    at: Date(timeIntervalSince1970: Double(row["at"] as Int64) / 1000))
            }
        }
    }

    public func metricSummaries(since: Date) async throws -> [MetricSummary] {
        let all = try await metrics(since: since)
        let grouped = Dictionary(grouping: all, by: \.name)
        return grouped.map { name, rows in
            let values = rows.map(\.value).sorted()
            return MetricSummary(
                name: name, count: values.count, p50: MetricSummary.percentile(values, 0.5), p95: MetricSummary.percentile(values, 0.95),
                max: values.last ?? 0, unit: rows.first?.unit ?? "ms")
        }.sorted { $0.name < $1.name }
    }

    /// Contagem de linhas por tabela, sem conteúdo (pacote de diagnóstico, AR-603).
    public func tableCounts() async throws -> [String: Int] {
        try await read { db in
            var counts: [String: Int] = [:]
            let names = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%' ORDER BY name")
            for name in names {
                counts[name] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(name)\"") ?? 0
            }
            return counts
        }
    }

    /// Migrações aplicadas (o último id é o "schema" do pacote).
    public func appliedMigrations() async throws -> [String] {
        try await read { db in try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid") }
    }
}
