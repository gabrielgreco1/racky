import Foundation
import Testing

@testable import RackyCore

@Suite struct InsightsAggregateTests {
    let now = InsightsFixtures.now
    let cal = InsightsFixtures.utc

    func bucket(_ hoursAgo: Double, model: String = "claude-opus-4-5", session: String = "s1", input: Int = 1_000_000, output: Int = 0,
                provider: InsightsProvider = .claude, sidechain: Int = 0) -> UsageBucket {
        let ts = now.addingTimeInterval(-hoursAgo * 3600)
        let hour = Int64(floor(ts.timeIntervalSince1970 / 3600)) * 3600
        return UsageBucket(provider: provider, session: session, model: model, hour: hour,
                           counts: TokenCounts(input: input, output: output), messages: 1, sidechainMessages: sidechain)
    }

    func summarize(_ buckets: [UsageBucket], reported: ReportedLimits = .init(), provider: InsightsProvider = .claude) -> ProviderSummary {
        UsageAggregator.summarize(.init(provider: provider, buckets: buckets, now: now, calendar: cal, reported: reported,
                                        sessionLabels: ["s1": "alpha"]))
    }

    @Test func pricingUsesTheConfigurableTable() {
        let table = PriceTable.default
        // 1M input de Opus = US$ 5; 1M de saída = US$ 25; cache read = 10% da entrada.
        #expect(table.cost(model: "claude-opus-4-5", counts: TokenCounts(input: 1_000_000, output: 1_000_000))! == 30)
        #expect(abs(table.cost(model: "claude-sonnet-4-5", counts: TokenCounts(cacheRead: 1_000_000))! - 0.3) < 1e-9)
        #expect(table.cost(model: "mystery-model", counts: TokenCounts(input: 1)) == nil)
        let custom = PriceTable(entries: [.init(match: "opus", price: ModelPrice(input: 1, output: 1, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0))])
        #expect(custom.cost(model: "Claude-OPUS", counts: TokenCounts(input: 2_000_000))! == 2)
    }

    @Test func priceTableOverrideFileFallsBackOnGarbage() throws {
        let dir = try InsightsFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("prices.json")
        try Data("nope".utf8).write(to: url)
        #expect(PriceTable.load(from: url) == .default)
        let custom = PriceTable(entries: [.init(match: "x", price: ModelPrice(input: 9, output: 9, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0))])
        try JSONEncoder().encode(custom).write(to: url)
        #expect(PriceTable.load(from: url) == custom)
    }

    @Test func emptyInputYieldsEmptySummary() {
        let s = summarize([])
        #expect(!s.hasData)
        #expect(s.fiveHour == nil && s.sevenDay == nil)
        #expect(s.hourOfDay == Array(repeating: 0, count: 24))
    }

    @Test func fiveHourBlockKeepsLocalTotalsButNeverEstimatesAFraction() throws {
        // Bloco antigo grande há ~30 h; bloco ativo menor começando há 2 h. Sem número do provedor não há fração.
        let old = [bucket(31, input: 4_000_000), bucket(30, input: 4_000_000)]
        let active = [bucket(2, input: 1_000_000), bucket(1, input: 1_000_000)]  // US$ 10
        let w = try #require(summarize(old + active).fiveHour)
        #expect(w.source == .unavailable)
        #expect(w.usedFraction == nil)
        #expect(w.resetsAt == nil)
        #expect(w.costUSD == 10)
        #expect(w.messages == 2)
    }

    @Test func fiveHourWindowExpiresAfterFiveHoursOfSilence() throws {
        let w = try #require(summarize([bucket(8, input: 1_000_000)]).fiveHour)
        #expect(w.usedFraction == nil)
        #expect(w.costUSD == 0)
    }

    @Test func reportedLimitsCarryTheProvidersNumbers() throws {
        let reset = now.addingTimeInterval(7200)
        let s = summarize([bucket(1)], reported: ReportedLimits(fiveHour: .init(usedFraction: 0.67, resetsAt: reset),
                                                                sevenDay: .init(usedFraction: 0.88, resetsAt: now.addingTimeInterval(86_400))))
        #expect(s.fiveHour?.source == .reported)
        #expect(s.fiveHour?.usedFraction == 0.67)
        #expect(s.fiveHour?.resetsAt == reset)
        #expect(s.fiveHour?.costUSD == 5)
        #expect(s.sevenDay?.source == .reported)
        #expect(s.sevenDay?.usedFraction == 0.88)
    }

    @Test func expiredReportedWindowShowsNothingInsteadOfEstimating() throws {
        let s = summarize([bucket(1)], reported: ReportedLimits(fiveHour: .init(usedFraction: 0.9, resetsAt: now.addingTimeInterval(-60))))
        #expect(s.fiveHour?.source == .unavailable)
        #expect(s.fiveHour?.usedFraction == nil)
        #expect(s.sevenDay?.usedFraction == nil)
        #expect(s.sevenDay?.costUSD == 5)
    }

    @Test func dayHourModelAndSessionBreakdowns() throws {
        let buckets = [
            bucket(1, model: "claude-opus-4-5", session: "s1", input: 1_000_000, sidechain: 1),
            bucket(2, model: "claude-sonnet-4-5", session: "s2", input: 1_000_000),
            bucket(27, model: "claude-opus-4-5", session: "s1", input: 1_000_000),
            bucket(24 * 20, model: "claude-opus-4-5", session: "s9", input: 1_000_000),  // fora da semana
            bucket(1, model: "novo-modelo", session: "s3", input: 10),
            bucket(1, model: "gpt-5", session: "cx", input: 1_000_000, provider: .codex),
        ]
        let s = summarize(buckets)
        #expect(s.dailyWeek.count == 7)
        #expect(s.dailyWeek.last?.counts.input == 2_000_010)  // 11:00 e 10:00 de hoje
        #expect(s.today.input == 2_000_010)
        #expect(s.week.input == 3_000_010)
        #expect(s.todayCostUSD == 8)
        #expect(s.topModels.first?.model == "claude-opus-4-5")
        #expect(s.topModels.map(\.model).contains("claude-sonnet-4-5"))
        #expect(abs(s.topModels.map(\.share).reduce(0, +) - 1) < 0.0001)
        #expect(s.topSessions.first?.session == "s1")
        #expect(s.topSessions.first?.label == "alpha")
        #expect(s.topSessions.first?.sidechainMessages == 1)
        #expect(!s.topSessions.contains { $0.session == "s9" })
        #expect(s.unpricedModels == ["novo-modelo"])
        // Hora do dia (UTC): 11h e 10h hoje; 09h de ontem (27 h atrás = 09:00).
        #expect(s.hourOfDay[11] > 0 && s.hourOfDay[10] > 0 && s.hourOfDay[9] > 0)
        #expect(s.hourOfDay[3] == 0)
        // Codex é isolado do Claude.
        #expect(summarize(buckets, provider: .codex).week.input == 1_000_000)
    }

    @Test func sessionTitlesFromRackyWinOverFolderLabels() {
        let s = UsageAggregator.summarize(.init(provider: .claude, buckets: [bucket(1)], now: now, calendar: cal,
                                                sessionLabels: ["s1": "alpha"], sessionTitles: ["s1": "Fix pagination"]))
        #expect(s.topSessions.first?.label == "Fix pagination")
    }
}

@Suite struct InsightsSourcesTests {
    @Test func claudeRateLimitCaptureParsesOnlyNumbers() throws {
        let reset = InsightsFixtures.now.timeIntervalSince1970 + 3600
        let json = "{\"model\":{\"id\":\"x\"},\"prompt\":\"SECRET-PROMPT\",\"rate_limits\":{\"five_hour\":{\"used_percentage\":23.5,\"resets_at\":\(Int(reset))},\"seven_day\":{\"used_percentage\":61,\"resets_at\":\(Int(reset) + 86_400)}}}"
        let snap = try #require(ClaudeRateLimitCapture.parse(statusLineJSON: Data(json.utf8), at: InsightsFixtures.now))
        #expect(snap.fiveHour?.usedPercentage == 23.5)
        #expect(snap.sevenDay?.usedPercentage == 61)
        let encoded = String(decoding: try JSONEncoder().encode(snap), as: UTF8.self)
        #expect(!encoded.contains("SECRET-PROMPT"))
        #expect(ClaudeRateLimitCapture.parse(statusLineJSON: Data("{}".utf8)) == nil)
        #expect(ClaudeRateLimitCapture.parse(statusLineJSON: Data("junk".utf8)) == nil)
    }

    @Test func recordMergesWindowsAndExpiredOnesAreDropped() throws {
        let dir = try InsightsFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("rl.json")
        let now = InsightsFixtures.now
        let reset = Int(now.timeIntervalSince1970) + 600
        try ClaudeRateLimitCapture.record(statusLineJSON: Data("{\"rate_limits\":{\"five_hour\":{\"used_percentage\":10,\"resets_at\":\(reset)}}}".utf8), to: url, now: now)
        try ClaudeRateLimitCapture.record(statusLineJSON: Data("{\"rate_limits\":{\"seven_day\":{\"used_percentage\":50,\"resets_at\":\(reset + 99_999)}}}".utf8), to: url, now: now)
        let snap = try #require(ClaudeRateLimitCapture.load(from: url))
        #expect(snap.fiveHour?.usedPercentage == 10)
        #expect(snap.sevenDay?.usedPercentage == 50)
        let live = ClaudeRateLimitCapture.reported(snap, now: now)
        #expect(live.fiveHour?.usedFraction == 0.1)
        let later = ClaudeRateLimitCapture.reported(snap, now: now.addingTimeInterval(700))
        #expect(later.fiveHour == nil)
        #expect(later.sevenDay != nil)
    }

    @Test func codexWindowsMapByMinutes() {
        let now = InsightsFixtures.now
        let snap = CodexLimitSnapshot(
            observedAt: now, primary: CodexLimitWindow(usedPercent: 20, windowMinutes: 300, resetsAt: now.addingTimeInterval(60)),
            secondary: CodexLimitWindow(usedPercent: 5, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(9999)), planType: nil)
        let r = CodexRateLimits.reported(snap, now: now)
        #expect(r.fiveHour?.usedFraction == 0.2)
        #expect(r.sevenDay?.usedFraction == 0.05)
        // `primary` com janela longa vira a semanal.
        let weekly = CodexLimitSnapshot(observedAt: now, primary: CodexLimitWindow(usedPercent: 70, windowMinutes: 10_080, resetsAt: nil), secondary: nil, planType: nil)
        let w = CodexRateLimits.reported(weekly, now: now)
        #expect(w.fiveHour == nil)
        #expect(w.sevenDay?.usedFraction == 0.7)
    }

    @Test func cliAuthParsing() {
        let claude = CLIAuthProbe.parseClaude("{\"loggedIn\":true,\"authMethod\":\"claude.ai\",\"subscriptionType\":\"team\",\"orgName\":\"Org\",\"email\":\"a@b.c\"}")
        #expect(claude == PlanInfo(loggedIn: true, plan: "team", authMethod: "claude.ai", organization: "Org"))
        #expect(CLIAuthProbe.parseClaude("not json") == nil)
        #expect(CLIAuthProbe.parseClaude("{\"loggedIn\":false}")?.loggedIn == false)
        let codex = CLIAuthProbe.parseCodex("Logged in using ChatGPT\n", planType: "plus")
        #expect(codex == PlanInfo(loggedIn: true, plan: "plus", authMethod: "ChatGPT", organization: nil))
        #expect(CLIAuthProbe.parseCodex("Not logged in", planType: nil).loggedIn == false)
    }
}

@Suite struct MachineMathTests {
    @Test func cpuFractionFromTicks() throws {
        let a = MachineMath.CPUTicks(user: 100, system: 50, idle: 850, nice: 0)
        let b = MachineMath.CPUTicks(user: 160, system: 70, idle: 870, nice: 0)
        let r = try #require(MachineMath.cpu(from: a, to: b))
        #expect(abs(r.total - 0.8) < 0.0001)  // 80 busy de 100
        #expect(abs(r.user - 0.6) < 0.0001)
        #expect(abs(r.system - 0.2) < 0.0001)
        #expect(MachineMath.cpu(from: b, to: a) == nil)
        #expect(MachineMath.cpu(from: a, to: a) == nil)
    }

    @Test func ratesHandleCounterResets() {
        #expect(MachineMath.rate(from: 1000, to: 3000, seconds: 2) == 1000)
        #expect(MachineMath.rate(from: 5000, to: 100, seconds: 1) == 0)
        #expect(MachineMath.rate(from: 0, to: 10, seconds: 0) == 0)
    }

    @Test func processCpuPercent() {
        #expect(MachineMath.cpuPercent(cpuNanos: 1_500_000_000, previous: 500_000_000, wallNanos: 1_000_000_000) == 100)
        #expect(MachineMath.cpuPercent(cpuNanos: 100, previous: 500, wallNanos: 1000) == 0)
    }

    @Test func appNameGroupsHelpersUnderTheirApp() {
        #expect(MachineMath.appName(path: "/Applications/Google Chrome.app/Contents/Frameworks/X.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper") == "Google Chrome")
        #expect(MachineMath.appName(path: "/usr/bin/ssh") == nil)
        let grouped = MachineMath.group([("a", "Chrome", 10, 100), ("b", "Chrome", 5, 50), ("zsh", nil, 1, 10)])
        #expect(grouped.first { $0.name == "Chrome" }?.processCount == 2)
        #expect(grouped.first { $0.name == "Chrome" }?.memoryBytes == 150)
        #expect(grouped.count == 2)
    }

    @Test func networkInterfaceFilter() {
        #expect(MachineMath.includesInterface("en0"))
        #expect(!MachineMath.includesInterface("lo0"))
        #expect(!MachineMath.includesInterface("utun3"))
        #expect(!MachineMath.includesInterface("awdl0"))
    }

    @Test func realSamplerProducesSaneNumbers() async throws {
        let sampler = MachineSampler()
        let first = await sampler.sample()
        try await Task.sleep(for: .milliseconds(400))
        var second = await sampler.sample()
        // Com a máquina carregada o delta de CPU pode sair vazio num intervalo curto: mais duas leituras antes de reprovar.
        for _ in 0..<2 where second.cpu == nil {
            try await Task.sleep(for: .milliseconds(500))
            second = await sampler.sample()
        }
        let memory = try #require(second.memory)
        #expect(memory.totalBytes > 1_000_000_000)
        #expect(memory.usedBytes > 0 && memory.usedBytes <= memory.totalBytes)
        let disk = try #require(second.disk)
        #expect(disk.totalBytes > 0 && disk.usedFraction >= 0 && disk.usedFraction <= 1)
        let cpu = try #require(second.cpu)
        #expect(cpu.total >= 0 && cpu.total <= 1)
        #expect(second.coreCount > 0)
        #expect(first.cpu == nil)  // primeira leitura não tem delta
        #expect(second.network != nil)
        #expect(!second.topByCPU.isEmpty)
        #expect(!second.topByMemory.isEmpty)
    }
}
