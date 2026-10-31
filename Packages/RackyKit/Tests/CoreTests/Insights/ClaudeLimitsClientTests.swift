import Foundation
import Testing

@testable import RackyCore

/// Testes do cliente de limites exatos do Claude com respostas fixture. Nenhum teste toca o Keychain nem a rede.
private final class FakeCredentials: ClaudeCredentialSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _reads = 0
    let result: Result<ClaudeOAuthCredential, ClaudeCredentialError>
    init(_ result: Result<ClaudeOAuthCredential, ClaudeCredentialError>) { self.result = result }
    var reads: Int { lock.withLock { _reads } }
    func read() throws -> ClaudeOAuthCredential {
        lock.withLock { _reads += 1 }
        return try result.get()
    }
}

private final class FakeTransport: ClaudeLimitsTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [(URL, [String: String])] = []
    let status: Int
    let body: Data
    init(status: Int, body: String) { self.status = status; self.body = Data(body.utf8) }
    var requests: [(URL, [String: String])] { lock.withLock { _requests } }
    func get(_ url: URL, headers: [String: String]) async throws -> (status: Int, body: Data) {
        lock.withLock { _requests.append((url, headers)) }
        return (status, body)
    }
}

private enum ClaudeLimitsFixtures {
    static let now = Date(timeIntervalSince1970: 1_792_238_400)  // 2026-10-17T12:00:00Z
    /// Resposta no formato do endpoint `/api/oauth/usage` (percentuais, ISO com microssegundos e deslocamento).
    static let usage = """
        {"five_hour":{"utilization":67.0,"resets_at":"2026-10-17T13:54:00.123456+00:00"},
         "seven_day":{"utilization":88.0,"resets_at":"2026-10-20T17:00:00.000000+00:00"},
         "seven_day_opus":null,"seven_day_sonnet":{"utilization":12.0,"resets_at":"2026-10-20T17:00:00+00:00"},
         "extra_usage":{"is_enabled":false,"monthly_limit":null,"used_credits":null,"utilization":null}}
        """
}

@Suite struct ClaudeLimitsClientTests {
    private func client(_ cred: FakeCredentials, _ transport: FakeTransport) -> ClaudeLimitsClient {
        ClaudeLimitsClient(credentials: cred, transport: transport, clock: { ClaudeLimitsFixtures.now })
    }

    private func credential(expiresIn: TimeInterval? = 3600) -> ClaudeOAuthCredential {
        ClaudeOAuthCredential(accessToken: "tok-fixture", expiresAt: expiresIn.map { ClaudeLimitsFixtures.now.addingTimeInterval($0) })
    }

    @Test func parsesTheExactPercentagesAndResetTimes() throws {
        let limits = try #require(ClaudeLimitsClient.parse(Data(ClaudeLimitsFixtures.usage.utf8), now: ClaudeLimitsFixtures.now))
        #expect(limits.fiveHour?.usedFraction == 0.67)
        #expect(limits.sevenDay?.usedFraction == 0.88)
        let reset = try #require(limits.fiveHour?.resetsAt)
        #expect(abs(reset.timeIntervalSince(ClaudeLimitsFixtures.now) - (6840 + 0.123456)) < 0.01)  // 1h 54m
        #expect(limits.reported(now: ClaudeLimitsFixtures.now).fiveHour?.usedFraction == 0.67)
        #expect(limits.reported(now: ClaudeLimitsFixtures.now.addingTimeInterval(86_400)).fiveHour == nil)  // janela já virou
    }

    @Test func parseAcceptsEpochResetsAndOverHundred() throws {
        let body = "{\"five_hour\":{\"utilization\":104.5,\"resets_at\":1792245240},\"seven_day\":null}"
        let limits = try #require(ClaudeLimitsClient.parse(Data(body.utf8), now: ClaudeLimitsFixtures.now))
        #expect(limits.fiveHour?.usedFraction == 1.045)
        #expect(limits.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_792_245_240))
        #expect(limits.sevenDay == nil)
    }

    @Test func parseRejectsGarbageAndEmptyAnswers() {
        for body in ["", "[]", "{}", "{\"five_hour\":null,\"seven_day\":null}", "{\"five_hour\":{\"utilization\":\"x\"}}", "nope"] {
            #expect(ClaudeLimitsClient.parse(Data(body.utf8), now: ClaudeLimitsFixtures.now) == nil, "\(body)")
        }
    }

    @Test func fetchSendsBearerAndBetaHeaderToTheUsageEndpoint() async {
        let cred = FakeCredentials(.success(credential()))
        let transport = FakeTransport(status: 200, body: ClaudeLimitsFixtures.usage)
        let result = await client(cred, transport).fetch()
        guard case .success(let limits) = result else { Issue.record("expected success, got \(result)"); return }
        #expect(limits.fiveHour?.usedFraction == 0.67)
        #expect(transport.requests.count == 1)
        #expect(transport.requests[0].0.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(transport.requests[0].1["Authorization"] == "Bearer tok-fixture")
        #expect(transport.requests[0].1["anthropic-beta"] == "oauth-2025-04-20")
    }

    @Test func credentialIsReadAgainOnEveryCall() async {
        let cred = FakeCredentials(.success(credential()))
        let c = client(cred, FakeTransport(status: 200, body: ClaudeLimitsFixtures.usage))
        _ = await c.fetch()
        _ = await c.fetch()
        #expect(cred.reads == 2)
    }

    @Test func expiredTokenAsksToOpenClaudeCodeWithoutCallingTheNetwork() async {
        let transport = FakeTransport(status: 200, body: ClaudeLimitsFixtures.usage)
        let result = await client(FakeCredentials(.success(credential(expiresIn: -10))), transport).fetch()
        #expect(result == .needsClaudeRefresh)
        #expect(transport.requests.isEmpty)
    }

    @Test func rejectedTokenAsksToOpenClaudeCode() async {
        for status in [401, 403] {
            let result = await client(FakeCredentials(.success(credential())), FakeTransport(status: status, body: "{}")).fetch()
            #expect(result == .needsClaudeRefresh)
        }
    }

    @Test func otherFailuresAreUnavailable() async {
        #expect(await client(FakeCredentials(.failure(.notFound)), FakeTransport(status: 200, body: "{}")).fetch() == .unavailable)
        #expect(await client(FakeCredentials(.failure(.denied)), FakeTransport(status: 200, body: "{}")).fetch() == .unavailable)
        #expect(await client(FakeCredentials(.success(credential())), FakeTransport(status: 429, body: "{}")).fetch() == .unavailable)
        #expect(await client(FakeCredentials(.success(credential())), FakeTransport(status: 200, body: "{\"x\":1}")).fetch() == .unavailable)
    }

    @Test func keychainPayloadYieldsOnlyTheAccessTokenAndExpiry() throws {
        let json = "{\"claudeAiOauth\":{\"accessToken\":\"sk-fixture\",\"refreshToken\":\"r-fixture\",\"expiresAt\":1792242000000,\"scopes\":[\"user:profile\"]}}"
        let c = try KeychainClaudeCredentialSource.parse(Data(json.utf8))
        #expect(c.accessToken == "sk-fixture")
        #expect(c.expiresAt == Date(timeIntervalSince1970: 1_792_242_000))
        #expect(throws: ClaudeCredentialError.malformed) { try KeychainClaudeCredentialSource.parse(Data("{}".utf8)) }
    }

    @Test func consentStoreKeepsOnlyTheDecision() throws {
        let dir = try InsightsFixtures.tempDirectory("consent")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ExactLimitsConsentStore(url: dir.appendingPathComponent("c.json"))
        #expect(store.load(), "P26: ligado por padrão, sem clique")
        store.save(false)
        #expect(!store.load())
        #expect(try String(contentsOf: dir.appendingPathComponent("c.json"), encoding: .utf8) == "{\"enabled\":false}")
    }

    @Test func realEndpointWhenExplicitlyRequested() async {
        // Opcional: `RACKY_REAL_LIMITS=1`. Pode abrir o diálogo do Keychain (clique explícito do dono): nunca roda sozinho.
        guard ProcessInfo.processInfo.environment["RACKY_REAL_LIMITS"] == "1" else { return }
        let result = await ClaudeLimitsClient().fetch()
        if case .success(let l) = result {
            print("RACKY_REAL_LIMITS 5h=\(l.fiveHour?.usedFraction ?? -1) 7d=\(l.sevenDay?.usedFraction ?? -1)")
        } else {
            print("RACKY_REAL_LIMITS result: \(result)")
        }
    }
}

@Suite(.serialized) struct ExactLimitsServiceTests {
    private struct Runner: InsightsCommandRunner {
        func run(_ executable: String, arguments: [String]) async -> (status: Int32, stdout: String, stderr: String)? { nil }
    }

    private func config() throws -> (InsightsConfig, URL) {
        let root = try InsightsFixtures.tempDirectory("exact")
        return (InsightsConfig(
            claudeProjects: root.appendingPathComponent("claude/projects"), codexSessions: root.appendingPathComponent("codex/sessions"),
            ledgerURL: root.appendingPathComponent("support/ledger.json"), claudeRateLimitsURL: root.appendingPathComponent("support/rl.json"),
            machineInterval: 60, usageRefreshInterval: 3600, exactLimitsInterval: 3600), root)
    }

    private func seedTranscript(_ cfg: InsightsConfig) throws {
        try InsightsFixtures.write([InsightsFixtures.claudeLine(id: "m1", at: Date().addingTimeInterval(-600), input: 1_000_000)],
                                   to: cfg.claudeProjects.appendingPathComponent("p/s.jsonl"))
    }

    @Test func exactLimitsAreReadWithoutAnyClick() async throws {
        let (cfg, root) = try config()
        defer { try? FileManager.default.removeItem(at: root) }
        let cred = FakeCredentials(.success(ClaudeOAuthCredential(accessToken: "t", expiresAt: nil)))
        let transport = FakeTransport(status: 200, body: ClaudeLimitsFixtures.usage)
        let service = InsightsService(config: cfg, runner: Runner(), limitsClient: ClaudeLimitsClient(credentials: cred, transport: transport))
        await service.start()
        await service.setVisible(true)
        await service.refreshExactLimits()
        await service.setVisible(false)
        #expect(cred.reads >= 1, "P26: os limites exatos aparecem sem clique e sem diálogo do Keychain")
        #expect(!transport.requests.isEmpty)
        #expect(await service.current.claudeLimits != .notEnabled)
        await service.stop()
    }

    @Test func clickEnablesExactLimitsPersistsOnlyTheDecisionAndDrivesTheWindows() async throws {
        let (cfg, root) = try config()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedTranscript(cfg)
        let now = Date()
        let body = "{\"five_hour\":{\"utilization\":67,\"resets_at\":\"\(InsightsFixtures.iso(now.addingTimeInterval(6840)))\"},"
            + "\"seven_day\":{\"utilization\":88,\"resets_at\":\"\(InsightsFixtures.iso(now.addingTimeInterval(86_400)))\"}}"
        let cred = FakeCredentials(.success(ClaudeOAuthCredential(accessToken: "t", expiresAt: nil)))
        let service = InsightsService(config: cfg, runner: Runner(),
                                      limitsClient: ClaudeLimitsClient(credentials: cred, transport: FakeTransport(status: 200, body: body)))
        await service.start()
        #expect(await service.current.claude.fiveHour?.usedFraction == nil)  // sem dado exato: "—", nunca estimativa
        await service.enableExactLimits()
        let snap = await service.current
        #expect(cred.reads == 1)
        #expect(snap.claude.fiveHour?.usedFraction == 0.67)
        #expect(snap.claude.sevenDay?.usedFraction == 0.88)
        if case .live = snap.claudeLimits {} else { Issue.record("expected live, got \(snap.claudeLimits)") }
        #expect(ExactLimitsConsentStore(url: cfg.exactLimitsConsentURL).load())
        await service.stop()
        // Novo launch: a decisão volta; o token nunca foi guardado (só `{"enabled":true}`).
        let again = InsightsService(config: cfg, runner: Runner(),
                                    limitsClient: ClaudeLimitsClient(credentials: cred, transport: FakeTransport(status: 200, body: body)))
        await again.start()
        // O último valor bom vem do cache em disco: aparece na hora, sem ler o Keychain.
        if case .live = await again.current.claudeLimits {} else { Issue.record("expected cached live limits on relaunch") }
        #expect(cred.reads == 1)  // start não lê o Keychain; só o módulo visível lê
        await again.stop()
    }

    @Test func expiredTokenShowsOpenClaudeCodeState() async throws {
        let (cfg, root) = try config()
        defer { try? FileManager.default.removeItem(at: root) }
        let cred = FakeCredentials(.success(ClaudeOAuthCredential(accessToken: "t", expiresAt: Date(timeIntervalSince1970: 1))))
        let service = InsightsService(config: cfg, runner: Runner(),
                                      limitsClient: ClaudeLimitsClient(credentials: cred, transport: FakeTransport(status: 200, body: "{}")))
        await service.start()
        await service.enableExactLimits()
        #expect(await service.current.claudeLimits == .needsClaudeRefresh)
        await service.stop()
    }

    @Test func statusLineCaptureIsTheFallbackWhenTheEndpointHasNothing() async throws {
        let (cfg, root) = try config()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedTranscript(cfg)
        let reset = Int(Date().timeIntervalSince1970) + 7200
        try ClaudeRateLimitCapture.record(
            statusLineJSON: Data("{\"rate_limits\":{\"five_hour\":{\"used_percentage\":55,\"resets_at\":\(reset)}}}".utf8), to: cfg.claudeRateLimitsURL)
        let service = InsightsService(config: cfg, runner: Runner(),
                                      limitsClient: ClaudeLimitsClient(credentials: FakeCredentials(.failure(.notFound)), transport: FakeTransport(status: 200, body: "{}")))
        await service.start()
        await service.enableExactLimits()
        let snap = await service.current
        #expect(snap.claudeLimits == .unavailable)
        #expect(snap.claude.fiveHour?.usedFraction == 0.55)
        await service.stop()
    }
}

struct ExactLimitsCacheTests {
    @Test func lastGoodLimitsSurviveARestartWithoutTheCredential() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("abx-limits-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ExactLimitsCache(url: dir.appendingPathComponent("c.json"))
        #expect(cache.load() == nil)
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let limits = ClaudeExactLimits(fetchedAt: at, fiveHour: ClaudeExactWindow(usedFraction: 0.34, resetsAt: at.addingTimeInterval(3600)), sevenDay: nil)
        cache.save(limits)
        #expect(cache.load() == limits)
        let raw = try String(contentsOf: dir.appendingPathComponent("c.json"), encoding: .utf8)
        #expect(!raw.contains("token") && !raw.contains("Bearer"))
    }
}
