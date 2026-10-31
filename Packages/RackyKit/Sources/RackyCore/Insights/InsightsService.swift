import RackyPlatform
import Foundation

public struct InsightsConfig: Sendable {
    public var claudeProjects: URL
    public var codexSessions: URL
    public var ledgerURL: URL
    public var claudeRateLimitsURL: URL
    public var priceTableURL: URL?
    public var retentionDays: Int
    public var machineInterval: TimeInterval
    public var usageRefreshInterval: TimeInterval
    /// Intervalo do endpoint de limites exatos do Claude (só roda com o módulo visível e depois do consentimento).
    public var exactLimitsInterval: TimeInterval
    /// Arquivo que guarda só a decisão "Show exact limits". Padrão: ao lado do livro-razão.
    public var exactLimitsConsentURL: URL

    public init(claudeProjects: URL, codexSessions: URL, ledgerURL: URL, claudeRateLimitsURL: URL, priceTableURL: URL? = nil,
                retentionDays: Int = 35, machineInterval: TimeInterval = 1.5, usageRefreshInterval: TimeInterval = 60,
                exactLimitsInterval: TimeInterval = 300, exactLimitsConsentURL: URL? = nil) {
        self.exactLimitsInterval = exactLimitsInterval
        self.exactLimitsConsentURL = exactLimitsConsentURL ?? ledgerURL.deletingLastPathComponent().appendingPathComponent("exact-limits-consent.json")
        self.claudeProjects = claudeProjects; self.codexSessions = codexSessions; self.ledgerURL = ledgerURL
        self.claudeRateLimitsURL = claudeRateLimitsURL; self.priceTableURL = priceTableURL
        self.retentionDays = retentionDays; self.machineInterval = machineInterval; self.usageRefreshInterval = usageRefreshInterval
    }

    /// Caminhos padrão. `~/.claude` e `~/.codex` são só lidos; o app grava apenas em `supportDirectory/insights`.
    public static func standard(supportDirectory: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> InsightsConfig {
        let dir = supportDirectory.appendingPathComponent("insights", isDirectory: true)
        return InsightsConfig(
            claudeProjects: home.appendingPathComponent(".claude/projects", isDirectory: true),
            codexSessions: home.appendingPathComponent(".codex/sessions", isDirectory: true),
            ledgerURL: dir.appendingPathComponent("usage-ledger.json"),
            claudeRateLimitsURL: dir.appendingPathComponent("claude-rate-limits.json"),
            priceTableURL: dir.appendingPathComponent("prices.json"))
    }
}

/// Serviço do módulo Insights: lê transcripts de forma incremental, amostra a máquina e publica `InsightsSnapshot`.
/// A amostragem da máquina e o relógio de atualização só rodam enquanto o módulo está visível (`setVisible`).
public actor InsightsService {
    public struct ScanReport: Sendable, Equatable {
        public var filesSeen = 0
        public var filesRead = 0
        public var messagesAdded = 0
        public var seconds = 0.0
    }

    private let config: InsightsConfig
    private var agents: (any InsightsAgentSource)?
    private var proxies: (any InsightsProxySource)?
    private var computers: (any InsightsComputerSource)?
    private let runner: any InsightsCommandRunner
    private let calendar: Calendar
    private let clock: @Sendable () -> Date
    private let sampler: MachineSampler
    private let limitsClient: ClaudeLimitsClient

    private var ledger = UsageLedger()
    private var snapshot = InsightsSnapshot.empty
    private var prices = PriceTable.default
    private var subscribers: [UUID: AsyncStream<InsightsSnapshot>.Continuation] = [:]
    private var scanning = false
    private var rescanRequested = false
    private var visible = false
    private var started = false
    private var machineTask: Task<Void, Never>?
    private var usageTask: Task<Void, Never>?
    private var limitsTask: Task<Void, Never>?
    private var exactEnabled = false
    private var exactLimits: ClaudeExactLimits?
    private var watcher: TreeWatcher?
    private var plans: (claude: PlanInfo?, codex: PlanInfo?, at: Date?) = (nil, nil, nil)
    private var agentRefs: [AgentSessionRef] = []
    private var proxySummaries: [ProxyUsageSummary] = []
    private var previousContainers: [String: (nanos: Int64, at: Date)] = [:]
    private var machineTicks = 0
    private var dockerAvailable = false
    private var computerUsage: [ComputerUsage] = []

    public init(config: InsightsConfig, agents: (any InsightsAgentSource)? = nil, proxies: (any InsightsProxySource)? = nil,
                computers: (any InsightsComputerSource)? = nil, runner: any InsightsCommandRunner = SystemInsightsCommandRunner(),
                limitsClient: ClaudeLimitsClient = .offline,
                calendar: Calendar = .current, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.config = config; self.agents = agents; self.proxies = proxies; self.computers = computers
        self.runner = runner; self.calendar = calendar; self.clock = clock
        self.limitsClient = limitsClient
        self.sampler = MachineSampler()
    }

    /// O app liga as fontes do Racky (Store, Docker) depois que o Store abre: o serviço nasce antes dele. Só preenche o que veio.
    public func attach(agents: (any InsightsAgentSource)? = nil, proxies: (any InsightsProxySource)? = nil,
                       computers: (any InsightsComputerSource)? = nil) {
        if let agents { self.agents = agents }
        if let proxies { self.proxies = proxies }
        if let computers { self.computers = computers }
    }

    // MARK: Assinatura

    public var current: InsightsSnapshot { snapshot }

    /// Entrega o estado atual e cada atualização seguinte.
    public func subscribe() -> AsyncStream<InsightsSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<InsightsSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        subscribers[id] = continuation
        continuation.yield(snapshot)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }

    private func publish() {
        snapshot.generatedAt = clock()
        snapshot.scanning = scanning
        for c in subscribers.values { c.yield(snapshot) }
    }

    // MARK: Ciclo de vida

    /// Carrega o livro-razão persistido e faz a primeira leitura. Idempotente.
    public func start() async {
        guard !started else { return }
        started = true
        ledger = UsageLedgerStore.load(from: config.ledgerURL)
        exactEnabled = ExactLimitsConsentStore(url: config.exactLimitsConsentURL).load()
        snapshot.claudeLimits = exactEnabled ? .loading : .notEnabled
        // Último valor bom do disco: aparece na hora ao abrir (janelas que já viraram somem em `reported(now:)`).
        if exactEnabled, let cached = ExactLimitsCache(url: exactLimitsCacheURL).load() {
            exactLimits = cached
            snapshot.claudeLimits = .live(fetchedAt: cached.fetchedAt)
        }
        if let url = config.priceTableURL { prices = PriceTable.load(from: url) }
        recompute()
        publish()
        let paths = [config.claudeProjects.path, config.codexSessions.path]
        let w = TreeWatcher(paths: paths, latency: 2) { [weak self] in
            Task { await self?.usageChanged() }
        }
        w.start()
        watcher = w
        await refreshUsage()
    }

    public func stop() {
        machineTask?.cancel(); machineTask = nil
        usageTask?.cancel(); usageTask = nil
        limitsTask?.cancel(); limitsTask = nil
        watcher?.stop(); watcher = nil
        for c in subscribers.values { c.finish() }
        subscribers.removeAll()
        started = false
        try? UsageLedgerStore.save(ledger, to: config.ledgerURL)
    }

    /// A aba Machine está na tela: amostra na cadência cheia (`machineInterval`).
    private var machineDetail = false
    public func setMachineDetail(_ value: Bool) { machineDetail = value }

    /// Liga/desliga o que custa CPU: amostras da máquina e releitura periódica. Fora de vista, só o watcher fica.
    public func setVisible(_ value: Bool) {
        guard value != visible else { return }
        visible = value
        if value {
            machineTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.tickMachine()
                    // Cadência cheia só com a aba Machine na tela; fora dela (barra de status, outras abas) basta a RAM a cada 5 s.
                    let interval = await self.machineDetail ? self.config.machineInterval : max(self.config.machineInterval, 5)
                    try? await Task.sleep(for: .seconds(interval))
                }
            }
            usageTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let interval = self.config.usageRefreshInterval
                    try? await Task.sleep(for: .seconds(interval))
                    if Task.isCancelled { return }
                    await self.refreshUsage()
                }
            }
            limitsTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    // O endpoint limita a frequência (429): no máximo uma leitura a cada `exactLimitsInterval`; em falha, recuo
                    // de 60 s dobrando até 15 min (o último valor bom continua na tela).
                    let interval = await self.refreshExactLimitsReturningDelay()
                    try? await Task.sleep(for: .seconds(interval))
                }
            }
        } else {
            machineTask?.cancel(); machineTask = nil
            usageTask?.cancel(); usageTask = nil
            limitsTask?.cancel(); limitsTask = nil
        }
    }

    // MARK: Limites exatos do Claude

    /// Chamado pelo clique explícito em "Show exact limits": grava a decisão (só ela) e faz a primeira leitura do Keychain.
    public func enableExactLimits() async {
        ExactLimitsConsentStore(url: config.exactLimitsConsentURL).save(true)
        exactEnabled = true
        snapshot.claudeLimits = .loading
        publish()
        await refreshExactLimits()
    }

    private var exactLimitsFailures = 0
    private var exactLimitsCacheURL: URL { config.exactLimitsConsentURL.deletingLastPathComponent().appendingPathComponent("exact-limits-cache.json") }

    private func refreshExactLimitsReturningDelay() async -> TimeInterval {
        let ok = await refreshExactLimits()
        exactLimitsFailures = ok ? 0 : exactLimitsFailures + 1
        if ok || exactLimitsFailures == 0 { return config.exactLimitsInterval }
        return min(60 * pow(2, Double(exactLimitsFailures - 1)), 900)
    }

    /// Uma leitura do endpoint de uso. Sem consentimento não faz nada (o Keychain nunca é tocado).
    @discardableResult
    public func refreshExactLimits() async -> Bool {
        guard exactEnabled else { return true }
        var ok = false
        switch await limitsClient.fetch() {
        case .success(let limits):
            ok = true
            exactLimits = limits
            ExactLimitsCache(url: exactLimitsCacheURL).save(limits)
            snapshot.claudeLimits = .live(fetchedAt: limits.fetchedAt)
        case .needsClaudeRefresh: snapshot.claudeLimits = .needsClaudeRefresh
        case .unavailable:
            // Falha passageira (rede, 429): mantém o último valor bom na tela e tenta de novo em 30 s.
            if exactLimits == nil { snapshot.claudeLimits = .unavailable }
        }
        recompute()
        publish()
        return ok
    }

    /// Menor intervalo entre duas varreduras disparadas por mudança de transcript (com agentes trabalhando elas chegavam a cada 2 s,
    /// e cada uma lista todo o `~/.claude/projects`).
    static let usageScanInterval: TimeInterval = 30
    private var lastUsageScan: Date?
    private var deferredUsageScan: Task<Void, Never>?

    private func usageChanged() async {
        // Mudança em transcript: relê mesmo fora de vista, mas no máximo uma vez a cada `usageScanInterval` (as mudanças do meio
        // entram na próxima varredura, que é incremental).
        let now = clock()
        if let last = lastUsageScan, now.timeIntervalSince(last) < Self.usageScanInterval {
            guard deferredUsageScan == nil else { return }
            let wait = Self.usageScanInterval - now.timeIntervalSince(last)
            deferredUsageScan = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                await self?.runDeferredUsageScan()
            }
            return
        }
        lastUsageScan = now
        await refreshUsage()
    }

    private func runDeferredUsageScan() async {
        deferredUsageScan = nil
        lastUsageScan = clock()
        await refreshUsage()
    }

    // MARK: Máquina

    public func tickMachine() async {
        let now = clock()
        let sample = await sampler.sample(now: now)
        // Amostra que terminou depois do painel sumir (tarefa cancelada no meio) não entra: fora de vista nada muda.
        guard !Task.isCancelled else { return }
        snapshot.machine = sample
        machineTicks += 1
        if machineTicks % 3 == 1 { await sampleComputers(now: now) }
        snapshot.computers = computerUsage
        snapshot.dockerAvailable = dockerAvailable
        publish()
    }

    private func sampleComputers(now: Date) async {
        guard let computers else { return }
        if let samples = await computers.computerSamples() {
            dockerAvailable = true
            computerUsage = computerRows(samples, now: now)
        } else {
            dockerAvailable = false
            computerUsage = []
        }
    }

    /// Uma leitura avulsa dos computadores (RAM, CPU) sem ligar a amostragem da máquina: a status bar a pede quando a lista de
    /// computadores muda e ao abrir o popover. Não agenda nada.
    public func refreshComputers() async {
        await sampleComputers(now: clock())
        snapshot.computers = computerUsage
        snapshot.dockerAvailable = dockerAvailable
        publish()
    }

    func computerRows(_ samples: [ContainerSample], now: Date) -> [ComputerUsage] {
        var next: [String: (nanos: Int64, at: Date)] = [:]
        var rows: [ComputerUsage] = []
        for s in samples {
            var cpu = 0.0
            if let prev = previousContainers[s.id], now > prev.at, s.cpuTotalNanos >= prev.nanos {
                cpu = Double(s.cpuTotalNanos - prev.nanos) / (now.timeIntervalSince(prev.at) * 1_000_000_000) * 100
            }
            next[s.id] = (s.cpuTotalNanos, now)
            rows.append(ComputerUsage(id: s.id, name: s.name, state: s.state, cpuPercent: cpu, memoryBytes: s.memoryBytes,
                                      memoryLimitBytes: s.memoryLimitBytes, pids: s.pids, sessionID: s.sessionID))
        }
        previousContainers = next
        return rows.sorted { $0.memoryBytes > $1.memoryBytes }
    }

    // MARK: Uso

    /// Lê o que mudou nos transcripts e recalcula. Chamadas concorrentes se fundem em uma releitura extra.
    @discardableResult
    public func refreshUsage() async -> ScanReport {
        if scanning { rescanRequested = true; return ScanReport() }
        scanning = true
        publish()
        let now = clock()
        let cutoff = now.addingTimeInterval(-Double(config.retentionDays) * 86_400)
        let work = ledger
        let cfg = config
        // DETACHED: varredura de GBs de JSONL fora do ator para não travar `current`/`subscribe`; o resultado volta por `await`.
        let (updated, report) = await Task.detached(priority: .utility) {
            Self.scan(ledger: work, config: cfg, cutoff: cutoff)
        }.value
        ledger = updated
        // Nada novo lido: não regrava o livro-razão inteiro (era a cada varredura).
        if report.filesRead > 0 || report.messagesAdded > 0 { try? UsageLedgerStore.save(ledger, to: config.ledgerURL) }
        if let agents { agentRefs = await agents.agentSessions() }
        if let proxies { proxySummaries = await proxies.proxyUsage(since: now.addingTimeInterval(-30 * 86_400), calendar: calendar) }
        await refreshPlansIfNeeded(now: now)
        scanning = false
        recompute()
        publish()
        if rescanRequested {
            rescanRequested = false
            return await refreshUsage()
        }
        return report
    }

    /// Varre os dois diretórios. `nonisolated` e síncrono: roda numa Task desanexada.
    nonisolated static func scan(ledger input: UsageLedger, config: InsightsConfig, cutoff: Date) -> (UsageLedger, ScanReport) {
        var ledger = input
        var report = ScanReport()
        let started = Date()
        let fm = FileManager.default
        var existing = Set<String>()

        func files(under root: URL, where match: (String) -> Bool) -> [(String, Double)] {
            guard let it = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                         options: [.skipsHiddenFiles]) else { return [] }
            var out: [(String, Double)] = []
            for case let url as URL in it where match(url.lastPathComponent) {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values?.isRegularFile == true else { continue }
                out.append((url.path, values?.contentModificationDate?.timeIntervalSince1970 ?? 0))
            }
            return out
        }

        let claudeFiles = files(under: config.claudeProjects) { $0.hasSuffix(".jsonl") }
        let codexFiles = files(under: config.codexSessions) { $0.hasPrefix("rollout-") && $0.hasSuffix(".jsonl") }
        report.filesSeen = claudeFiles.count + codexFiles.count
        let cutoffTs = cutoff.timeIntervalSince1970

        func ingest(_ list: [(String, Double)], _ body: (inout UsageLedger, String) -> Int) {
            for (path, mtime) in list {
                existing.insert(path)
                // Arquivo que não muda desde a última leitura, ou que já saiu da janela de retenção, é pulado sem abrir.
                if let state = ledger.files[path], state.cursor.mtime >= mtime, state.cursor.size > 0 { continue }
                if mtime < cutoffTs, ledger.files[path] == nil { continue }
                report.filesRead += 1
                report.messagesAdded += body(&ledger, path)
            }
        }
        ingest(claudeFiles) { $0.ingestClaude(path: $1, cutoff: cutoff) }
        ingest(codexFiles) { $0.ingestCodex(path: $1, cutoff: cutoff) }
        ledger.prune(before: cutoff, existingPaths: existing)
        // Devolve ao sistema as páginas liberadas por uma varredura grande (o malloc as segura; o app ficava com centenas de MB a mais).
        // Só depois de ler muitos arquivos: o relief percorre todas as zonas e custa caro para as varreduras incrementais de todo minuto.
        if report.filesRead >= 50 { malloc_zone_pressure_relief(nil, 0) }
        report.seconds = Date().timeIntervalSince(started)
        return (ledger, report)
    }

    private func refreshPlansIfNeeded(now: Date) async {
        if let at = plans.at, now.timeIntervalSince(at) < 600 { return }
        let claude = await CLIAuthProbe.claude(runner: runner)
        let codex = await CLIAuthProbe.codex(runner: runner, planType: ledger.codexLimits?.planType)
        plans = (claude, codex, now)
    }

    /// Recalcula os agregados a partir do livro-razão (sem I/O).
    func recompute() {
        let now = clock()
        var titles: [String: String] = [:]
        for ref in agentRefs { for id in ref.nativeConversationIDs { titles[id] = ref.title } }
        // Prioridade: endpoint exato > `rate_limits` capturados da status line/hooks. Sem nenhum dos dois não há fração (nunca estima).
        var claudeReported = ClaudeRateLimitCapture.reported(ClaudeRateLimitCapture.load(from: config.claudeRateLimitsURL), now: now)
        if let exact = exactLimits?.reported(now: now) {
            claudeReported.fiveHour = exact.fiveHour ?? claudeReported.fiveHour
            claudeReported.sevenDay = exact.sevenDay ?? claudeReported.sevenDay
        }
        let all = Array(ledger.buckets.values)

        func input(_ p: InsightsProvider, reported: ReportedLimits, plan: PlanInfo?) -> UsageAggregator.Input {
            UsageAggregator.Input(provider: p, buckets: all, now: now, calendar: calendar, prices: prices, reported: reported,
                                  plan: plan, sessionLabels: ledger.sessionLabels, sessionTitles: titles)
        }
        snapshot.claude = UsageAggregator.summarize(input(.claude, reported: claudeReported, plan: plans.claude))
        var codexPlan = plans.codex
        if codexPlan?.plan == nil, let t = ledger.codexLimits?.planType { codexPlan?.plan = t }
        snapshot.codex = UsageAggregator.summarize(input(.codex, reported: CodexRateLimits.reported(ledger.codexLimits, now: now), plan: codexPlan))
        snapshot.agents = agentRows(all: all, now: now)
        snapshot.proxies = proxySummaries
        snapshot.computers = computerUsage
        snapshot.dockerAvailable = dockerAvailable
        if !exactEnabled { snapshot.claudeLimits = .notEnabled }
    }

    func agentRows(all: [UsageBucket], now: Date) -> [AgentSessionUsage] {
        let since = Int64(now.addingTimeInterval(-7 * 86_400).timeIntervalSince1970)
        var rows: [AgentSessionUsage] = []
        for ref in agentRefs {
            var counts = TokenCounts.zero, cost = 0.0, messages = 0, sub = 0
            for b in all where b.provider == ref.provider && b.hour >= since && ref.nativeConversationIDs.contains(b.session) {
                counts += b.counts
                cost += prices.cost(model: b.model, counts: b.counts) ?? 0
                messages += b.messages; sub += b.sidechainMessages
            }
            guard ref.running || messages > 0 else { continue }
            rows.append(AgentSessionUsage(sessionID: ref.sessionID, title: ref.title, provider: ref.provider, counts: counts,
                                          costUSD: cost, messages: messages, subagentMessages: sub, running: ref.running))
        }
        return rows.sorted { ($0.running ? 1 : 0, $0.costUSD) > ($1.running ? 1 : 0, $1.costUSD) }
    }
}
