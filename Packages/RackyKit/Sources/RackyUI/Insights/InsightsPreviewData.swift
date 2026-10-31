import RackyCore
import Foundation

/// Dados sintéticos e determinísticos do módulo (snapshots, previews, Bench). Nada vem do disco do usuário.
public enum InsightsPreviewData {
    public static let now = Date(timeIntervalSince1970: 1_792_238_400)  // 2026-10-17 12:00 UTC

    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .current
        c.locale = Locale(identifier: "en_US")
        return c
    }

    static func counts(_ fresh: Int, cacheRead: Int) -> TokenCounts {
        TokenCounts(input: fresh / 50, output: fresh / 5, cacheRead: cacheRead, cacheWrite5m: fresh - fresh / 50 - fresh / 5)
    }

    /// `exact: false` = sem número do provedor: as janelas ficam sem fração (a UI mostra "—").
    public static func provider(_ p: InsightsProvider, level: Double = 0.67, weekly: Double = 0.88, exact: Bool = true) -> ProviderSummary {
        let dayStart = calendar.startOfDay(for: now)
        let daily: [Int] = [14_200_000, 6_100_000, 21_800_000, 9_400_000, 3_100_000, 17_600_000, 12_900_000]
        let days = daily.enumerated().map { i, tokens in
            DailyUsage(dayStart: calendar.date(byAdding: .day, value: i - 6, to: dayStart) ?? dayStart,
                       counts: counts(tokens, cacheRead: tokens * 40), costUSD: Double(tokens) / 1_000_000 * 14)
        }
        let hours: [Double] = [0, 0, 0, 0, 0, 0, 1.0e5, 6.0e5, 2.4e6, 5.1e6, 6.9e6, 4.2e6, 2.8e6, 3.9e6, 5.5e6, 4.1e6, 2.2e6, 1.1e6, 4.0e5, 9.0e5, 1.6e6, 2.1e6, 1.0e6, 2.0e5]
        let reset = now.addingTimeInterval(1 * 3600 + 54 * 60)
        let source: LimitSource = exact ? .reported : .unavailable
        var s = ProviderSummary.empty(p, at: now)
        s.hasData = true
        s.plan = PlanInfo(loggedIn: true, plan: p == .claude ? "max" : "plus", authMethod: p == .claude ? "claude.ai" : "ChatGPT")
        s.fiveHour = LimitWindow(kind: .fiveHour, source: source, usedFraction: exact ? level : nil, resetsAt: exact ? reset : nil, startedAt: reset.addingTimeInterval(-5 * 3600),
                                 counts: counts(3_900_000, cacheRead: 120_000_000), costUSD: 71.46, messages: 597)
        s.sevenDay = LimitWindow(kind: .sevenDay, source: source, usedFraction: exact ? weekly : nil,
                                 resetsAt: exact ? now.addingTimeInterval(2 * 86_400 + 4 * 3600) : nil, startedAt: now.addingTimeInterval(-4 * 86_400),
                                 counts: counts(85_100_000, cacheRead: 2_900_000_000), costUSD: 1_184, messages: 13_902)
        s.dailyWeek = days
        s.today = days.last?.counts ?? .zero
        s.todayCostUSD = days.last?.costUSD ?? 0
        s.todayMessages = 412
        s.week = days.reduce(.zero) { $0 + $1.counts }
        s.weekCostUSD = days.reduce(0) { $0 + $1.costUSD }
        s.hourOfDay = hours
        s.topModels = p == .claude
            ? [ModelUsage(model: "claude-opus-5-5", counts: counts(52_000_000, cacheRead: 1_900_000_000), costUSD: 812, share: 0.61),
               ModelUsage(model: "claude-sonnet-5-5", counts: counts(30_000_000, cacheRead: 900_000_000), costUSD: 331, share: 0.35),
               ModelUsage(model: "claude-haiku-5-5", counts: counts(3_000_000, cacheRead: 60_000_000), costUSD: 12, share: 0.04)]
            : [ModelUsage(model: "gpt-6.1-sol", counts: counts(9_000_000, cacheRead: 300_000_000), costUSD: 88, share: 0.82),
               ModelUsage(model: "gpt-6-astra", counts: counts(2_000_000, cacheRead: 40_000_000), costUSD: 14, share: 0.18)]
        s.topSessions = [
            SessionUsage(session: "11111111-aaaa", label: "fix-search-pagination", counts: counts(26_000_000, cacheRead: 900_000_000), costUSD: 402, messages: 3_900, sidechainMessages: 1_100, lastActive: now.addingTimeInterval(-240)),
            SessionUsage(session: "22222222-bbbb", label: "phoenix-az", counts: counts(21_000_000, cacheRead: 700_000_000), costUSD: 318, messages: 2_800, sidechainMessages: 0, lastActive: now.addingTimeInterval(-5_400)),
            SessionUsage(session: "33333333-cccc", label: "Insights module", counts: counts(5_200_000, cacheRead: 150_000_000), costUSD: 61, messages: 640, sidechainMessages: 210, lastActive: now.addingTimeInterval(-86_400)),
        ]
        return s
    }

    public static func machine() -> MachineSnapshot {
        let gib: UInt64 = 1_073_741_824
        return MachineSnapshot(
            at: now,
            cpu: CPUSample(total: 0.37, user: 0.26, system: 0.11, perCore: [0.82, 0.64, 0.41, 0.3, 0.22, 0.18, 0.12, 0.1, 0.55, 0.2, 0.08, 0.05, 0.03, 0.02],
                           load1: 4.82, load5: 5.1, load15: 4.4),
            memory: MemorySample(totalBytes: 48 * gib, usedBytes: 34 * gib, appBytes: 21 * gib, wiredBytes: 6 * gib, compressedBytes: 7 * gib, cachedBytes: 9 * gib,
                                 swapUsedBytes: 6 * gib, swapTotalBytes: 8 * gib, pressure: .normal),
            disk: DiskSample(totalBytes: 994 * gib, freeBytes: 52 * gib, readBytesPerSec: 18_400_000, writeBytesPerSec: 4_200_000),
            network: NetworkSample(downBytesPerSec: 2_350_000, upBytesPerSec: 410_000, totalDownBytes: 2_486_000_000, totalUpBytes: 2_166_000_000),
            topByCPU: [AppUsage(name: "Google Chrome", cpuPercent: 118, memoryBytes: 5 * gib, processCount: 21),
                       AppUsage(name: "Docker Desktop", cpuPercent: 64, memoryBytes: 7 * gib, processCount: 6),
                       AppUsage(name: "Racky", cpuPercent: 22, memoryBytes: 1 * gib, processCount: 3),
                       AppUsage(name: "Xcode", cpuPercent: 14, memoryBytes: 3 * gib, processCount: 4)],
            topByMemory: [AppUsage(name: "Docker Desktop", cpuPercent: 64, memoryBytes: 7 * gib, processCount: 6),
                          AppUsage(name: "Google Chrome", cpuPercent: 118, memoryBytes: 5 * gib, processCount: 21),
                          AppUsage(name: "Xcode", cpuPercent: 14, memoryBytes: 3 * gib, processCount: 4),
                          AppUsage(name: "Racky", cpuPercent: 22, memoryBytes: 1 * gib, processCount: 3)],
            thermal: "nominal", uptimeSeconds: 3 * 86_400, coreCount: 14)
    }

    public static func history() -> InsightsHistory {
        var cpu: [Double] = [], mem: [Double] = [], down: [Double] = [], up: [Double] = []
        for i in 0..<InsightsHistory.capacity {
            let t = Double(i)
            let c: Double = 0.25 + 0.2 * sin(t / 5) + 0.1 * sin(t / 1.7)
            let m: Double = 0.66 + 0.04 * sin(t / 9)
            let d: Double = 1_500_000 + 1_200_000 * sin(t / 4) * sin(t / 11)
            let u: Double = 300_000 + 250_000 * sin(t / 6)
            cpu.append(c); mem.append(m); down.append(max(0, d)); up.append(max(0, u))
        }
        return InsightsHistory(cpu: cpu, memory: mem, down: down, up: up)
    }

    public static func snapshot(exact: Bool = true, limits: ClaudeLimitsStatus? = nil) -> InsightsSnapshot {
        let gib: Int64 = 1_073_741_824
        return InsightsSnapshot(
            generatedAt: now, claude: provider(.claude, exact: exact), codex: provider(.codex, level: 0.18, weekly: 0.31, exact: true),
            machine: machine(),
            computers: [ComputerUsage(id: "c1", name: "phoenix-az", state: "running", cpuPercent: 38, memoryBytes: 2 * gib, memoryLimitBytes: 4 * gib, pids: 112, sessionID: nil),
                        ComputerUsage(id: "c2", name: "austin-listings", state: "running", cpuPercent: 4, memoryBytes: gib, memoryLimitBytes: 4 * gib, pids: 64, sessionID: nil)],
            dockerAvailable: true,
            agents: [AgentSessionUsage(sessionID: "s1", title: "fix-search-pagination", provider: .claude, counts: counts(26_000_000, cacheRead: 900_000_000), costUSD: 402, messages: 3_900, subagentMessages: 1_100, running: true),
                     AgentSessionUsage(sessionID: "s2", title: "phoenix-az", provider: .codex, counts: counts(2_000_000, cacheRead: 40_000_000), costUSD: 14, messages: 120, subagentMessages: 0, running: false)],
            proxies: [ProxyUsageSummary(id: "p1", name: "Zyte", isDefault: true, requests: 18_420, bytes: 3_480_000_000, costMicros: 12_400_000,
                                        daily: (0..<30).map { i in ProxyDay(dayStart: now.addingTimeInterval(Double(i - 29) * 86_400), requests: 200 + (i * 37) % 900, bytes: 0, costMicros: 0) }),
                      ProxyUsageSummary(id: "p2", name: "Residential EU", isDefault: false, requests: 640, bytes: 91_000_000, costMicros: 0, daily: [])],
            claudeLimits: limits ?? (exact ? .live(fetchedAt: now) : .notEnabled))
    }

    /// Modelo estático pronto para a view.
    @MainActor public static func model(tab: InsightsTab = .claude, exact: Bool = true, snapshot: InsightsSnapshot? = nil) -> InsightsModel {
        InsightsModel(preview: snapshot ?? Self.snapshot(exact: exact), history: history(), tab: tab, now: now)
    }
}
