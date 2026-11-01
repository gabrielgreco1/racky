import Foundation
import Testing

@testable import RackyCore

private struct FakeRunner: InsightsCommandRunner {
    func run(_ executable: String, arguments: [String]) async -> (status: Int32, stdout: String, stderr: String)? {
        switch executable {
        case "claude": (0, "{\"loggedIn\":true,\"authMethod\":\"claude.ai\",\"subscriptionType\":\"max\"}", "")
        case "codex": (0, "", "Logged in using ChatGPT")
        default: nil
        }
    }
}

private struct FakeAgents: InsightsAgentSource {
    func agentSessions() async -> [AgentSessionRef] {
        [AgentSessionRef(sessionID: "ab-1", title: "Fix pagination", provider: .claude, nativeConversationIDs: ["sess-a"], running: true),
         AgentSessionRef(sessionID: "ab-2", title: "Idle shell", provider: .codex, nativeConversationIDs: ["nope"], running: false)]
    }
}

private struct FakeProxies: InsightsProxySource {
    func proxyUsage(since: Date, calendar: Calendar) async -> [ProxyUsageSummary] {
        [ProxyUsageSummary(id: "p1", name: "Zyte", isDefault: true, requests: 12, bytes: 3456, costMicros: 7_000, daily: [])]
    }
}

private struct FakeComputers: InsightsComputerSource {
    let value: [ContainerSample]?
    func computerSamples() async -> [ContainerSample]? { value }
}

@Suite(.serialized) struct InsightsServiceTests {
    func makeConfig() throws -> (InsightsConfig, URL) {
        let root = try InsightsFixtures.tempDirectory("service")
        let config = InsightsConfig(
            claudeProjects: root.appendingPathComponent("claude/projects"), codexSessions: root.appendingPathComponent("codex/sessions"),
            ledgerURL: root.appendingPathComponent("support/ledger.json"), claudeRateLimitsURL: root.appendingPathComponent("support/rl.json"),
            priceTableURL: nil, machineInterval: 0.05, usageRefreshInterval: 3600)
        return (config, root)
    }

    /// T4-01: o app liga as fontes depois do Store; a status bar pede uma leitura avulsa dos computadores sem ligar a amostragem da máquina.
    @Test func attachedSourcesFeedASingleComputerSampleWithoutStartingTheMachineLoop() async throws {
        let (config, root) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = InsightsService(config: config, runner: FakeRunner())
        await service.start()
        defer { Task { await service.stop() } }
        let before = await service.current
        #expect(before.computers.isEmpty && before.proxies.isEmpty)
        let sample = ContainerSample(id: "c1", name: "phoenix-az", state: "running", memoryBytes: 512 << 20, memoryLimitBytes: 4 << 30, cpuTotalNanos: 0, pids: 9, sessionID: nil)
        await service.attach(proxies: FakeProxies(), computers: FakeComputers(value: [sample]))
        await service.refreshComputers()
        let snap = await service.current
        #expect(snap.dockerAvailable && snap.computers.map(\.name) == ["phoenix-az"] && snap.computers.first?.memoryBytes == 512 << 20)
        #expect(snap.machine == nil, "a leitura avulsa não liga a amostragem da máquina")
        await service.attach(computers: FakeComputers(value: nil))
        await service.refreshComputers()
        let after = await service.current
        #expect(after.dockerAvailable == false && after.computers.isEmpty)
    }

    @Test func scanPublishesBothProvidersPlansAgentsAndProxies() async throws {
        let (config, root) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        try InsightsFixtures.write([
            InsightsFixtures.claudeLine(id: "m1", at: now.addingTimeInterval(-600), input: 1_000_000, output: 1000),
            InsightsFixtures.claudeLine(id: "m2", at: now.addingTimeInterval(-300), input: 500_000, sidechain: true),
        ] + InsightsFixtures.corruptLines, to: config.claudeProjects.appendingPathComponent("proj-a/sess-a.jsonl"))
        try InsightsFixtures.write([
            InsightsFixtures.codexMeta(id: "cx-1", at: now.addingTimeInterval(-900)), InsightsFixtures.codexTurn(model: "gpt-5.6", at: now.addingTimeInterval(-900)),
            InsightsFixtures.codexTokens(input: 100_000, cached: 50_000, output: 2000, at: now.addingTimeInterval(-800),
                                         primary: (33, 300, now.timeIntervalSince1970 + 3600), plan: "pro"),
        ], to: config.codexSessions.appendingPathComponent("2026/10/17/rollout-2026-10-17T10-00-00-cx-1.jsonl"))
        // A status line já entregou os limites reais do Claude.
        let reset = Int(now.timeIntervalSince1970) + 7200
        try ClaudeRateLimitCapture.record(
            statusLineJSON: Data("{\"rate_limits\":{\"five_hour\":{\"used_percentage\":55,\"resets_at\":\(reset)}}}".utf8), to: config.claudeRateLimitsURL)

        let service = InsightsService(config: config, agents: FakeAgents(), proxies: FakeProxies(), computers: FakeComputers(value: nil), runner: FakeRunner())
        await service.start()
        let snap = await service.current
        defer { Task { await service.stop() } }

        #expect(snap.claude.hasData)
        #expect(snap.claude.week.input == 1_500_000)
        #expect(snap.claude.plan?.plan == "max")
        #expect(snap.claude.fiveHour?.source == .reported)
        #expect(snap.claude.fiveHour?.usedFraction == 0.55)
        #expect(snap.claude.topSessions.first?.label == "Fix pagination")  // título do Racky vence a pasta
        #expect(snap.codex.hasData)
        #expect(snap.codex.fiveHour?.source == .reported)
        #expect(snap.codex.fiveHour?.usedFraction == 0.33)
        #expect(snap.codex.plan?.plan == "pro")
        #expect(snap.codex.plan?.authMethod == "ChatGPT")
        #expect(snap.agents.count == 1)  // a sessão ociosa e sem uso some
        #expect(snap.agents.first?.title == "Fix pagination")
        #expect(snap.agents.first?.subagentMessages == 1)
        #expect(snap.agents.first?.running == true)
        #expect(snap.proxies.first?.requests == 12)
        #expect(!snap.scanning)
        // O livro-razão foi persistido e um serviço novo parte dele sem reler os transcripts.
        #expect(FileManager.default.fileExists(atPath: config.ledgerURL.path))
    }

    @Test func rescanOnlyReadsAppendedLines() async throws {
        let (config, root) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = config.claudeProjects.appendingPathComponent("proj/s.jsonl")
        let now = Date()
        try InsightsFixtures.write([InsightsFixtures.claudeLine(id: "a", at: now.addingTimeInterval(-60), input: 100)], to: file)
        let service = InsightsService(config: config, runner: FakeRunner())
        await service.start()
        let first = await service.refreshUsage()
        #expect(first.filesRead == 0)  // nada mudou desde o `start`
        try await Task.sleep(for: .milliseconds(1100))  // mtime com resolução de 1 s em alguns volumes
        try InsightsFixtures.write([InsightsFixtures.claudeLine(id: "b", at: now.addingTimeInterval(-30), input: 50)], to: file, append: true)
        let second = await service.refreshUsage()
        // O watcher do serviço pode ler o append antes desta chamada (máquina carregada): aí ela não lê nada. O que importa é
        // o total (150, nunca 250 = reler o arquivo inteiro).
        #expect(second.filesRead <= 1 && second.messagesAdded <= 1)
        let snap = await service.current
        #expect(snap.claude.week.input == 150)
        await service.stop()

        // Reabrir parte do disco: cursores persistidos, zero releitura.
        let reopened = InsightsService(config: config, runner: FakeRunner())
        await reopened.start()
        #expect(await reopened.current.claude.week.input == 150)
        let again = await reopened.refreshUsage()
        #expect(again.filesRead == 0)
        await reopened.stop()
    }

    @Test func machineTicksPublishOnlyWhileVisible() async throws {
        let (config, root) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: root) }
        let samples = [ContainerSample(id: "c1", name: "phoenix-az", state: "running", memoryBytes: 512, memoryLimitBytes: 1024, cpuTotalNanos: 1_000, pids: 4, sessionID: nil)]
        let service = InsightsService(config: config, computers: FakeComputers(value: samples), runner: FakeRunner())
        await service.start()
        #expect(await service.current.machine == nil)
        await service.setVisible(true)
        try await Task.sleep(for: .milliseconds(700))
        let visible = await service.current
        #expect(visible.machine?.memory != nil)
        #expect(visible.dockerAvailable)
        #expect(visible.computers.first?.name == "phoenix-az")
        #expect(visible.computers.first?.memoryFraction == 0.5)
        await service.setVisible(false)
        try await Task.sleep(for: .milliseconds(200))
        let stamp = await service.current.machine?.at
        try await Task.sleep(for: .milliseconds(400))
        #expect(await service.current.machine?.at == stamp)  // parado fora de vista
        await service.stop()
    }

    @Test func subscribersReceiveCurrentStateAndUpdates() async throws {
        let (config, root) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = InsightsService(config: config, runner: FakeRunner())
        let stream = await service.subscribe()
        var iterator = stream.makeAsyncIterator()
        let initial = await iterator.next()
        #expect(initial?.claude.hasData == false)
        await service.start()
        await service.tickMachine()
        var sawMachine = false
        while let next = await iterator.next() {
            if next.machine != nil { sawMachine = true; break }
        }
        #expect(sawMachine)
        await service.stop()
    }

    @Test func cpuPercentOfComputersComesFromCounterDeltas() async throws {
        let (config, root) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = InsightsService(config: config, runner: FakeRunner())
        let t0 = Date()
        let a = ContainerSample(id: "c", name: "n", state: "running", memoryBytes: 1, memoryLimitBytes: 2, cpuTotalNanos: 0, pids: 1, sessionID: nil)
        var b = a
        b.cpuTotalNanos = 500_000_000
        _ = await service.computerRows([a], now: t0)
        let rows = await service.computerRows([b], now: t0.addingTimeInterval(1))
        #expect(abs(rows[0].cpuPercent - 50) < 0.001)
    }
}
