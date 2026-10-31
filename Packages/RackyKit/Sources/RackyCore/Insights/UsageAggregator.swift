import Foundation

/// Limite reportado pelo provedor (status line do Claude, rollout do Codex), já normalizado para 0…1.
public struct ReportedLimit: Sendable, Equatable {
    public var usedFraction: Double
    public var resetsAt: Date?
    public init(usedFraction: Double, resetsAt: Date?) { self.usedFraction = usedFraction; self.resetsAt = resetsAt }
}

public struct ReportedLimits: Sendable, Equatable {
    public var fiveHour: ReportedLimit?
    public var sevenDay: ReportedLimit?
    public init(fiveHour: ReportedLimit? = nil, sevenDay: ReportedLimit? = nil) { self.fiveHour = fiveHour; self.sevenDay = sevenDay }
}

/// Cálculo puro dos agregados (sem I/O, relógio e calendário injetados).
public enum UsageAggregator {
    public static let blockLength: TimeInterval = 5 * 3600
    public static let weekLength: TimeInterval = 7 * 86_400

    public struct Input: Sendable {
        public var provider: InsightsProvider
        public var buckets: [UsageBucket]
        public var now: Date
        public var calendar: Calendar
        public var prices: PriceTable
        public var reported: ReportedLimits
        public var plan: PlanInfo?
        public var sessionLabels: [String: String]
        /// Preferência do usuário: rótulo exibido por sessão (título da sessão do Racky etc.).
        public var sessionTitles: [String: String]

        public init(provider: InsightsProvider, buckets: [UsageBucket], now: Date, calendar: Calendar = .current,
                    prices: PriceTable = .default, reported: ReportedLimits = .init(), plan: PlanInfo? = nil,
                    sessionLabels: [String: String] = [:], sessionTitles: [String: String] = [:]) {
            self.provider = provider; self.buckets = buckets; self.now = now; self.calendar = calendar; self.prices = prices
            self.reported = reported; self.plan = plan; self.sessionLabels = sessionLabels; self.sessionTitles = sessionTitles
        }
    }

    public static func summarize(_ input: Input) -> ProviderSummary {
        let mine = input.buckets.filter { $0.provider == input.provider }
        var summary = ProviderSummary.empty(input.provider, at: input.now)
        summary.plan = input.plan
        guard !mine.isEmpty else { return summary }
        summary.hasData = true

        let cal = input.calendar
        let now = input.now
        var unpriced = Set<String>()
        func cost(_ b: UsageBucket) -> Double {
            if let c = input.prices.cost(model: b.model, counts: b.counts) { return c }
            if !b.counts.isEmpty { unpriced.insert(b.model) }
            return 0
        }

        // Dias (hoje e os 6 anteriores).
        let todayStart = cal.startOfDay(for: now)
        let days: [Date] = (0..<7).reversed().compactMap { cal.date(byAdding: .day, value: -$0, to: todayStart) }
        var dayMessages = [Date: Int]()
        var dayCounts = [Date: (TokenCounts, Double)]()
        for d in days { dayCounts[d] = (.zero, 0) }
        var hourWeights = Array(repeating: 0.0, count: 24)
        let fourteenAgo = cal.date(byAdding: .day, value: -14, to: todayStart) ?? todayStart
        var models: [String: (TokenCounts, Double)] = [:]
        var sessions: [String: (TokenCounts, Double, Int, Int, Date)] = [:]
        let weekStart = days.first ?? todayStart

        for b in mine {
            let when = b.hourStart
            let c = cost(b)
            if when >= fourteenAgo {
                hourWeights[cal.component(.hour, from: when)] += Double(b.counts.fresh)
            }
            guard when >= weekStart, when <= now else { continue }
            let day = cal.startOfDay(for: when)
            if var entry = dayCounts[day] {
                entry.0 += b.counts; entry.1 += c
                dayCounts[day] = entry
                dayMessages[day, default: 0] += b.messages
            }
            var m = models[b.model] ?? (.zero, 0)
            m.0 += b.counts; m.1 += c
            models[b.model] = m
            var s = sessions[b.session] ?? (.zero, 0, 0, 0, when)
            s.0 += b.counts; s.1 += c; s.2 += b.messages; s.3 += b.sidechainMessages; s.4 = max(s.4, when)
            sessions[b.session] = s
        }

        summary.dailyWeek = days.map { DailyUsage(dayStart: $0, counts: dayCounts[$0]?.0 ?? .zero, costUSD: dayCounts[$0]?.1 ?? 0) }
        summary.today = summary.dailyWeek.last?.counts ?? .zero
        summary.todayCostUSD = summary.dailyWeek.last?.costUSD ?? 0
        summary.todayMessages = dayMessages[todayStart] ?? 0
        summary.week = summary.dailyWeek.reduce(.zero) { $0 + $1.counts }
        summary.weekCostUSD = summary.dailyWeek.reduce(0) { $0 + $1.costUSD }
        summary.hourOfDay = hourWeights

        let freshTotal = max(1, models.values.reduce(0) { $0 + $1.0.fresh })
        summary.topModels = models.map { ModelUsage(model: $0.key, counts: $0.value.0, costUSD: $0.value.1, share: Double($0.value.0.fresh) / Double(freshTotal)) }
            .sorted { ($0.costUSD, $0.counts.fresh) > ($1.costUSD, $1.counts.fresh) }
            .prefix(5).map { $0 }
        summary.topSessions = sessions.map {
            SessionUsage(session: $0.key, label: input.sessionTitles[$0.key] ?? input.sessionLabels[$0.key], counts: $0.value.0,
                         costUSD: $0.value.1, messages: $0.value.2, sidechainMessages: $0.value.3, lastActive: $0.value.4)
        }
        .sorted { ($0.costUSD, $0.counts.fresh) > ($1.costUSD, $1.counts.fresh) }
        .prefix(6).map { $0 }

        // Janelas de limite.
        let hours = collapseByHour(mine, cost: cost)
        summary.fiveHour = fiveHourWindow(hours: hours, now: now, reported: input.reported.fiveHour)
        summary.sevenDay = sevenDayWindow(hours: hours, now: now, calendar: cal, reported: input.reported.sevenDay)
        summary.unpricedModels = unpriced.sorted()
        return summary
    }

    // MARK: Janelas

    struct HourTotals: Sendable {
        var counts: TokenCounts
        var cost: Double
        var messages: Int
    }

    static func collapseByHour(_ buckets: [UsageBucket], cost: (UsageBucket) -> Double) -> [(hour: Int64, totals: HourTotals)] {
        var map: [Int64: HourTotals] = [:]
        for b in buckets {
            var t = map[b.hour] ?? HourTotals(counts: .zero, cost: 0, messages: 0)
            t.counts += b.counts; t.cost += cost(b); t.messages += b.messages
            map[b.hour] = t
        }
        return map.map { (hour: $0.key, totals: $0.value) }.sorted { $0.hour < $1.hour }
    }

    struct Block { var start: Int64; var lastHour: Int64; var totals: HourTotals }

    /// Blocos de 5 h: começam na hora cheia da primeira mensagem após uma pausa ≥ 5 h (mesma regra das ferramentas de uso).
    static func blocks(_ hours: [(hour: Int64, totals: HourTotals)]) -> [Block] {
        var out: [Block] = []
        let len = Int64(blockLength)
        for (hour, t) in hours {
            if var last = out.last, hour < last.start + len, hour - last.lastHour < len {
                last.lastHour = hour
                last.totals.counts += t.counts; last.totals.cost += t.cost; last.totals.messages += t.messages
                out[out.count - 1] = last
            } else {
                out.append(Block(start: hour, lastHour: hour, totals: t))
            }
        }
        return out
    }

    static func fiveHourWindow(hours: [(hour: Int64, totals: HourTotals)], now: Date, reported: ReportedLimit?) -> LimitWindow? {
        let all = blocks(hours)
        let nowTs = Int64(now.timeIntervalSince1970)
        let len = Int64(blockLength)
        var active: Block?
        if let last = all.last, nowTs < last.start + len, nowTs - (last.lastHour + 3600) < len { active = last }
        let counts = active?.totals.counts ?? .zero
        let activeCost = active?.totals.cost ?? 0
        let messages = active?.totals.messages ?? 0
        let end = active.map { Date(timeIntervalSince1970: TimeInterval($0.start + len)) }
        let start = active.map { Date(timeIntervalSince1970: TimeInterval($0.start)) }

        if let reported, reported.resetsAt.map({ $0 > now }) ?? true {
            return LimitWindow(kind: .fiveHour, source: .reported, usedFraction: reported.usedFraction, resetsAt: reported.resetsAt ?? end,
                               startedAt: start, counts: counts, costUSD: activeCost, messages: messages)
        }
        return LimitWindow(kind: .fiveHour, source: .unavailable, usedFraction: nil, resetsAt: nil, startedAt: start,
                           counts: counts, costUSD: activeCost, messages: messages)
    }

    static func sevenDayWindow(hours: [(hour: Int64, totals: HourTotals)], now: Date, calendar: Calendar, reported: ReportedLimit?) -> LimitWindow? {
        let nowTs = Int64(now.timeIntervalSince1970)
        let week = Int64(weekLength)
        func window(ending end: Int64) -> HourTotals {
            var t = HourTotals(counts: .zero, cost: 0, messages: 0)
            for (h, v) in hours where h > end - week && h <= end {
                t.counts += v.counts; t.cost += v.cost; t.messages += v.messages
            }
            return t
        }
        let current = window(ending: nowTs)
        if let reported, reported.resetsAt.map({ $0 > now }) ?? true {
            return LimitWindow(kind: .sevenDay, source: .reported, usedFraction: reported.usedFraction, resetsAt: reported.resetsAt,
                               startedAt: now.addingTimeInterval(-weekLength), counts: current.counts, costUSD: current.cost, messages: current.messages)
        }
        return LimitWindow(kind: .sevenDay, source: .unavailable, usedFraction: nil, resetsAt: nil,
                           startedAt: now.addingTimeInterval(-weekLength), counts: current.counts, costUSD: current.cost,
                           messages: current.messages)
    }
}
