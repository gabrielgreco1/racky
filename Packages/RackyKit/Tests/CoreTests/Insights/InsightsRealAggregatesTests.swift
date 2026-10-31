import Foundation
import Testing

@testable import RackyCore

/// Roda o agregador contra os dados reais do usuário (SÓ LEITURA de `~/.claude` e `~/.codex`) e grava apenas números
/// agregados. Desligado por padrão: `AB_INSIGHTS_REAL_OUT=<arquivo.json> swift test --filter InsightsRealAggregates`.
/// Nada de prompts, transcripts, rótulos de sessão, e-mails ou caminhos entra na saída.
@Suite(.serialized) struct InsightsRealAggregatesTests {
    func nn<T>(_ v: T?) -> Any { v.map { $0 as Any } ?? NSNull() }

    @Test func writeRealAggregates() async throws {
        guard let out = ProcessInfo.processInfo.environment["AB_INSIGHTS_REAL_OUT"] else { return }
        let scratch = try InsightsFixtures.tempDirectory("real")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let config = InsightsConfig(
            claudeProjects: home.appendingPathComponent(".claude/projects"), codexSessions: home.appendingPathComponent(".codex/sessions"),
            ledgerURL: scratch.appendingPathComponent("ledger.json"), claudeRateLimitsURL: scratch.appendingPathComponent("rl.json"))
        let service = InsightsService(config: config, runner: SystemInsightsCommandRunner())

        let started = Date()
        let report = await service.refreshUsage()  // primeira leitura completa (sem `start`: sem watcher)
        let firstScan = Date().timeIntervalSince(started)
        let second = await service.refreshUsage()  // incremental: deve ler zero arquivos
        await service.tickMachine()
        try await Task.sleep(for: .milliseconds(1200))
        await service.tickMachine()
        let snap = await service.current

        func provider(_ s: ProviderSummary) -> [String: Any] {
            func counts(_ c: TokenCounts) -> [String: Int] {
                ["input": c.input, "output": c.output, "cache_read": c.cacheRead, "cache_write": c.cacheWrite, "fresh": c.fresh, "total": c.total]
            }
            func window(_ w: LimitWindow?) -> Any {
                guard let w else { return NSNull() }
                return ["source": w.source.rawValue, "used_fraction": nn(w.usedFraction.map { ($0 * 1000).rounded() / 1000 }),
                        "has_reset": w.resetsAt != nil, "messages": w.messages,
                        "cost_usd": (w.costUSD * 100).rounded() / 100, "fresh_tokens": w.counts.fresh] as [String: Any]
            }
            let peakHour = s.hourOfDay.enumerated().max { $0.element < $1.element }?.offset
            return [
                "has_data": s.hasData, "plan": nn(s.plan?.plan), "logged_in": nn(s.plan?.loggedIn),
                "today": counts(s.today), "today_cost_usd": (s.todayCostUSD * 100).rounded() / 100,
                "week": counts(s.week), "week_cost_usd": (s.weekCostUSD * 100).rounded() / 100,
                "five_hour": window(s.fiveHour), "seven_day": window(s.sevenDay),
                "daily_week_fresh_tokens": s.dailyWeek.map(\.counts.fresh),
                "daily_week_cost_usd": s.dailyWeek.map { ($0.costUSD * 100).rounded() / 100 },
                "hour_of_day_peak_hour": nn(peakHour),
                "hour_of_day_active_hours": s.hourOfDay.filter { $0 > 0 }.count,
                "top_models": s.topModels.map { ["model": $0.model, "share": ($0.share * 1000).rounded() / 1000, "cost_usd": ($0.costUSD * 100).rounded() / 100] as [String: Any] },
                "top_sessions_count": s.topSessions.count,
                "top_session_shares_of_week_cost": s.topSessions.map { s.weekCostUSD > 0 ? (($0.costUSD / s.weekCostUSD) * 1000).rounded() / 1000 : 0 },
                "unpriced_models": s.unpricedModels,
            ]
        }
        var machine: [String: Any] = [:]
        if let m = snap.machine {
            machine = [
                "cores": m.coreCount, "cpu_total": nn(m.cpu.map { ($0.total * 1000).rounded() / 1000 }),
                "memory_total_gb": nn(m.memory.map { Double($0.totalBytes) / 1_073_741_824 }),
                "memory_used_fraction": nn(m.memory.map { ($0.usedFraction * 1000).rounded() / 1000 }),
                "memory_pressure": nn(m.memory?.pressure.rawValue),
                "swap_used_mb": nn(m.memory.map { $0.swapUsedBytes / 1_048_576 }),
                "disk_used_fraction": nn(m.disk.map { ($0.usedFraction * 1000).rounded() / 1000 }),
                "network_totals_gb": nn(m.network.map { [Double($0.totalDownBytes) / 1e9, Double($0.totalUpBytes) / 1e9] }),
                "top_cpu_apps_count": m.topByCPU.count, "top_memory_apps_count": m.topByMemory.count,
                "thermal": m.thermal,
            ]
        }
        let result: [String: Any] = [
            "generated_by": "InsightsRealAggregatesTests",
            "note": "Somente agregados numéricos; sem prompts, transcripts, rótulos de sessão, e-mails ou caminhos.",
            "scan": ["first_scan_seconds": (firstScan * 100).rounded() / 100, "files_seen": report.filesSeen, "files_read": report.filesRead,
                     "messages_counted": report.messagesAdded, "incremental_files_read": second.filesRead],
            "claude": provider(snap.claude), "codex": provider(snap.codex), "machine": machine,
            "ledger_file_bytes": FileManager.default.fileExists(atPath: config.ledgerURL.path)
                ? ((try? FileManager.default.attributesOfItem(atPath: config.ledgerURL.path)[.size] as? Int) ?? 0) : 0,
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: out))
        #expect(report.filesSeen > 0)
        #expect(second.filesRead <= 5)  // só transcripts ativos mudam entre as duas leituras
    }
}
