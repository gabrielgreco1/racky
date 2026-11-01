import RackyDocker
import RackyPlatform
import RackyProtocol
import RackyStore
import Foundation

// MARK: - Limites reportados pelo Claude (status line)

/// Snapshot dos limites que o Claude Code entrega à status line (`rate_limits.five_hour|seven_day`). O Racky grava
/// este arquivo a partir do JSON da status line; o `InsightsService` só lê. Só números: nunca o resto do JSON.
public struct ClaudeRateLimitSnapshot: Codable, Sendable, Equatable {
    public struct Window: Codable, Sendable, Equatable {
        /// 0…100, como o Claude reporta.
        public var usedPercentage: Double
        public var resetsAt: Date?
        public init(usedPercentage: Double, resetsAt: Date?) { self.usedPercentage = usedPercentage; self.resetsAt = resetsAt }
    }

    public var capturedAt: Date
    public var fiveHour: Window?
    public var sevenDay: Window?

    public init(capturedAt: Date, fiveHour: Window?, sevenDay: Window?) {
        self.capturedAt = capturedAt; self.fiveHour = fiveHour; self.sevenDay = sevenDay
    }
}

public enum ClaudeRateLimitCapture {
    /// Extrai `rate_limits` do JSON entregue à status line. `nil` se não houver nenhuma janela.
    public static func parse(statusLineJSON data: Data, at now: Date = Date()) -> ClaudeRateLimitSnapshot? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let limits = obj["rate_limits"] as? [String: Any] else { return nil }
        func window(_ key: String) -> ClaudeRateLimitSnapshot.Window? {
            guard let w = limits[key] as? [String: Any], let used = (w["used_percentage"] as? NSNumber)?.doubleValue else { return nil }
            let resets = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return .init(usedPercentage: used, resetsAt: resets)
        }
        let five = window("five_hour")
        let seven = window("seven_day")
        guard five != nil || seven != nil else { return nil }
        return ClaudeRateLimitSnapshot(capturedAt: now, fiveHour: five, sevenDay: seven)
    }

    /// Grava o snapshot (mescla com o anterior: uma status line sem uma das janelas não apaga a outra).
    public static func record(statusLineJSON data: Data, to url: URL, now: Date = Date()) throws {
        guard var snapshot = parse(statusLineJSON: data, at: now) else { return }
        if let old = load(from: url) {
            snapshot.fiveHour = snapshot.fiveHour ?? old.fiveHour
            snapshot.sevenDay = snapshot.sevenDay ?? old.sevenDay
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }

    public static func load(from url: URL) -> ClaudeRateLimitSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ClaudeRateLimitSnapshot.self, from: data)
    }

    /// Normaliza para o agregador. Janela cujo `resetsAt` já passou virou outra janela: não vale mais.
    public static func reported(_ snapshot: ClaudeRateLimitSnapshot?, now: Date) -> ReportedLimits {
        guard let snapshot else { return .init() }
        func convert(_ w: ClaudeRateLimitSnapshot.Window?) -> ReportedLimit? {
            guard let w else { return nil }
            if let r = w.resetsAt, r <= now { return nil }
            return ReportedLimit(usedFraction: max(0, w.usedPercentage / 100), resetsAt: w.resetsAt)
        }
        return ReportedLimits(fiveHour: convert(snapshot.fiveHour), sevenDay: convert(snapshot.sevenDay))
    }
}

public enum CodexRateLimits {
    /// `primary` costuma ser a janela de 5 h e `secondary` a de 7 d; `window_minutes` decide quando presente.
    public static func reported(_ snapshot: CodexLimitSnapshot?, now: Date) -> ReportedLimits {
        guard let snapshot else { return .init() }
        var out = ReportedLimits()
        func place(_ w: CodexLimitWindow?, fallbackFive: Bool) {
            guard let w else { return }
            if let r = w.resetsAt, r <= now { return }
            let value = ReportedLimit(usedFraction: max(0, w.usedPercent / 100), resetsAt: w.resetsAt)
            let isFive = w.windowMinutes.map { $0 <= 360 } ?? fallbackFive
            if isFive { out.fiveHour = out.fiveHour ?? value } else { out.sevenDay = out.sevenDay ?? value }
        }
        place(snapshot.primary, fallbackFive: true)
        place(snapshot.secondary, fallbackFive: false)
        return out
    }
}

// MARK: - Plano (CLI)

/// Executa um comando e devolve a saída. Injetável: testes não rodam CLIs reais.
public protocol InsightsCommandRunner: Sendable {
    func run(_ executable: String, arguments: [String]) async -> (status: Int32, stdout: String, stderr: String)?
}

/// Procura o executável nos lugares usuais (o app não herda o PATH do shell) e roda com prazo curto.
public struct SystemInsightsCommandRunner: InsightsCommandRunner {
    public let timeout: Duration
    public let extraDirectories: [String]

    public init(timeout: Duration = .seconds(8), extraDirectories: [String] = []) {
        self.timeout = timeout; self.extraDirectories = extraDirectories
    }

    public func resolve(_ name: String) -> URL? {
        let home = NSHomeDirectory()
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let dirs = extraDirectories + ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin",
                                       "\(home)/.npm-global/bin", "\(home)/.bun/bin"] + pathDirs
        for d in dirs {
            let url = URL(fileURLWithPath: d).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    public func run(_ executable: String, arguments: [String]) async -> (status: Int32, stdout: String, stderr: String)? {
        guard let url = resolve(executable) else { return nil }
        let request = ProcessRequest(executable: url, arguments: arguments, timeout: timeout, maxOutputBytes: 64 * 1024)
        guard let out = try? await ProcessRunner.run(request) else { return nil }
        return (out.exitCode, out.stdoutString, out.stderrString)
    }
}

public enum CLIAuthProbe {
    /// `claude auth status` imprime JSON (`loggedIn`, `subscriptionType`, `authMethod`, `orgName`). O e-mail é ignorado.
    public static func claude(runner: any InsightsCommandRunner) async -> PlanInfo? {
        guard let out = await runner.run("claude", arguments: ["auth", "status"]) else { return nil }
        return parseClaude(out.stdout)
    }

    public static func parseClaude(_ text: String) -> PlanInfo? {
        guard let data = text.data(using: .utf8), let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let logged = (obj["loggedIn"] as? Bool) ?? false
        return PlanInfo(loggedIn: logged, plan: obj["subscriptionType"] as? String, authMethod: obj["authMethod"] as? String,
                        organization: obj["orgName"] as? String)
    }

    /// `codex login status` imprime uma linha (`Logged in using ChatGPT`). O plano vem do `rate_limits.plan_type` do rollout.
    public static func codex(runner: any InsightsCommandRunner, planType: String?) async -> PlanInfo? {
        guard let out = await runner.run("codex", arguments: ["login", "status"]) else { return nil }
        // O `codex login status` escreve a linha em stderr em algumas versões.
        return parseCodex(out.stdout + "\n" + out.stderr, planType: planType)
    }

    public static func parseCodex(_ text: String, planType: String?) -> PlanInfo {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = line.lowercased()
        let logged = lower.contains("logged in") && !lower.contains("not logged in")
        var method: String?
        if let r = lower.range(of: "using ") { method = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces) }
        return PlanInfo(loggedIn: logged, plan: planType, authMethod: method, organization: nil)
    }
}

// MARK: - Fontes do Racky (Store, Docker)

public struct AgentSessionRef: Sendable, Equatable {
    public var sessionID: String
    public var title: String
    public var provider: InsightsProvider
    /// IDs de conversa nativa (Claude `sessionId`, Codex `session_meta.id`) dos terminais dessa sessão.
    public var nativeConversationIDs: Set<String>
    public var running: Bool

    public init(sessionID: String, title: String, provider: InsightsProvider, nativeConversationIDs: Set<String>, running: Bool) {
        self.sessionID = sessionID; self.title = title; self.provider = provider
        self.nativeConversationIDs = nativeConversationIDs; self.running = running
    }
}

public protocol InsightsAgentSource: Sendable {
    func agentSessions() async -> [AgentSessionRef]
}

public protocol InsightsProxySource: Sendable {
    func proxyUsage(since: Date, calendar: Calendar) async -> [ProxyUsageSummary]
}

public struct ContainerSample: Sendable, Equatable {
    public var id: String
    public var name: String
    public var state: String
    public var memoryBytes: Int64
    public var memoryLimitBytes: Int64
    public var cpuTotalNanos: Int64
    public var pids: Int
    public var sessionID: String?

    public init(id: String, name: String, state: String, memoryBytes: Int64, memoryLimitBytes: Int64, cpuTotalNanos: Int64, pids: Int, sessionID: String?) {
        self.id = id; self.name = name; self.state = state; self.memoryBytes = memoryBytes
        self.memoryLimitBytes = memoryLimitBytes; self.cpuTotalNanos = cpuTotalNanos; self.pids = pids; self.sessionID = sessionID
    }
}

public protocol InsightsComputerSource: Sendable {
    /// `nil` = Docker indisponível; lista vazia = nenhum computador rodando.
    func computerSamples() async -> [ContainerSample]?
}

/// Sessões, abas e terminais do Store, reduzidos ao que Insights precisa.
public struct StoreAgentSource: InsightsAgentSource {
    private let store: RackyStore
    public init(store: RackyStore) { self.store = store }

    public func agentSessions() async -> [AgentSessionRef] {
        guard let sessions = try? await store.sessions() else { return [] }
        var out: [AgentSessionRef] = []
        for session in sessions {
            guard let tabs = try? await store.tabs(sessionID: session.id) else { continue }
            var byProvider: [InsightsProvider: (ids: Set<String>, running: Bool)] = [:]
            for tab in tabs {
                guard let terminals = try? await store.terminals(tabID: tab.id) else { continue }
                for t in terminals {
                    let provider: InsightsProvider
                    switch t.provider {
                    case .claude: provider = .claude
                    case .codex: provider = .codex
                    default: continue
                    }
                    var entry = byProvider[provider] ?? ([], false)
                    for id in [t.nativeConversationID, t.launchSpec.nativeSessionID, t.launchSpec.resumeOf] {
                        if let id, !id.isEmpty { entry.ids.insert(id) }
                    }
                    if t.state == .running || t.state == .launching { entry.running = true }
                    byProvider[provider] = entry
                }
            }
            for (provider, entry) in byProvider {
                out.append(AgentSessionRef(sessionID: session.id.uuidString, title: session.title, provider: provider,
                                           nativeConversationIDs: entry.ids, running: entry.running))
            }
        }
        return out
    }
}

public struct StoreProxySource: InsightsProxySource {
    private let store: RackyStore
    public init(store: RackyStore) { self.store = store }

    public func proxyUsage(since: Date, calendar: Calendar) async -> [ProxyUsageSummary] {
        guard let proxies = try? await store.proxies() else { return [] }
        var out: [ProxyUsageSummary] = []
        for proxy in proxies {
            let rows = (try? await store.proxyUsage(proxyID: proxy.id, since: since)) ?? []
            var byDay: [Date: ProxyDay] = [:]
            let reportsCost = rows.contains { $0.costMicros != nil }
            for row in rows {
                let day = calendar.startOfDay(for: row.periodStart)
                var d = byDay[day] ?? ProxyDay(dayStart: day, requests: 0, bytes: 0, costMicros: 0)
                d.requests += row.requests; d.bytes += row.bytes; d.costMicros += row.costMicros ?? 0
                byDay[day] = d
            }
            let daily = byDay.values.sorted { $0.dayStart < $1.dayStart }
            out.append(ProxyUsageSummary(id: proxy.id.uuidString, name: proxy.name, isDefault: proxy.isDefault,
                                         requests: daily.reduce(0) { $0 + $1.requests }, bytes: daily.reduce(0) { $0 + $1.bytes },
                                         costMicros: daily.reduce(0) { $0 + $1.costMicros }, daily: daily, reportsCost: reportsCost))
        }
        return out
    }
}

/// Containers do Racky (label `racky.owner`) com uma amostra de `stats` cada.
public struct DockerComputerSource: InsightsComputerSource {
    private let client: DockerClient
    private let owner: String?
    /// `owner`: valor do label `racky.owner` desta instância (um app isolado nunca lê os computadores de outro). `nil` = qualquer dono.
    public init(client: DockerClient, owner: String? = nil) { self.client = client; self.owner = owner }

    public func computerSamples() async -> [ContainerSample]? {
        let label = owner.map { "\(RackyLabel.owner)=\($0)" } ?? RackyLabel.owner
        guard let current = try? await client.listContainers(all: false, filters: ["label": [label]]) else { return nil }
        var seen = Set<String>()
        var out: [ContainerSample] = []
        for c in current where seen.insert(c.id).inserted && RackyLabel.value(RackyLabel.test, in: c.labels) != "1" {
            let stats = try? await client.statsSnapshot(c.id)
            let name = RackyLabel.value(RackyLabel.computerName, in: c.labels) ?? c.names.first ?? String(c.id.prefix(12))
            out.append(ContainerSample(id: c.id, name: name, state: c.state, memoryBytes: stats?.memoryUsageBytes ?? 0,
                                       memoryLimitBytes: stats?.memoryLimitBytes ?? 0, cpuTotalNanos: stats?.cpuTotalUsageNanos ?? 0,
                                       pids: stats?.pids ?? 0, sessionID: RackyLabel.value(RackyLabel.session, in: c.labels)))
        }
        return out
    }
}
