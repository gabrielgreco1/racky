import Foundation

public enum MemoryPressureLevel: String, Codable, Sendable { case normal, warning, critical }

public struct CPUSample: Codable, Sendable, Equatable {
    /// 0…1 sobre todos os núcleos.
    public var total: Double
    public var user: Double
    public var system: Double
    public var perCore: [Double]
    public var load1: Double
    public var load5: Double
    public var load15: Double

    public init(total: Double, user: Double, system: Double, perCore: [Double], load1: Double, load5: Double, load15: Double) {
        self.total = total; self.user = user; self.system = system; self.perCore = perCore
        self.load1 = load1; self.load5 = load5; self.load15 = load15
    }
}

public struct MemorySample: Codable, Sendable, Equatable {
    public var totalBytes: UInt64
    /// "Memória usada" do Monitor de Atividade: app + wired + comprimida.
    public var usedBytes: UInt64
    public var appBytes: UInt64
    public var wiredBytes: UInt64
    public var compressedBytes: UInt64
    public var cachedBytes: UInt64
    public var swapUsedBytes: UInt64
    public var swapTotalBytes: UInt64
    public var pressure: MemoryPressureLevel

    public var usedFraction: Double { totalBytes == 0 ? 0 : min(1, Double(usedBytes) / Double(totalBytes)) }

    public init(totalBytes: UInt64, usedBytes: UInt64, appBytes: UInt64, wiredBytes: UInt64, compressedBytes: UInt64,
                cachedBytes: UInt64, swapUsedBytes: UInt64, swapTotalBytes: UInt64, pressure: MemoryPressureLevel) {
        self.totalBytes = totalBytes; self.usedBytes = usedBytes; self.appBytes = appBytes; self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes; self.cachedBytes = cachedBytes
        self.swapUsedBytes = swapUsedBytes; self.swapTotalBytes = swapTotalBytes; self.pressure = pressure
    }
}

public struct DiskSample: Codable, Sendable, Equatable {
    public var totalBytes: UInt64
    public var freeBytes: UInt64
    public var readBytesPerSec: Double
    public var writeBytesPerSec: Double

    public var usedFraction: Double { totalBytes == 0 ? 0 : min(1, Double(totalBytes - min(freeBytes, totalBytes)) / Double(totalBytes)) }

    public init(totalBytes: UInt64, freeBytes: UInt64, readBytesPerSec: Double, writeBytesPerSec: Double) {
        self.totalBytes = totalBytes; self.freeBytes = freeBytes
        self.readBytesPerSec = readBytesPerSec; self.writeBytesPerSec = writeBytesPerSec
    }
}

public struct NetworkSample: Codable, Sendable, Equatable {
    public var downBytesPerSec: Double
    public var upBytesPerSec: Double
    public var totalDownBytes: UInt64
    public var totalUpBytes: UInt64

    public init(downBytesPerSec: Double, upBytesPerSec: Double, totalDownBytes: UInt64, totalUpBytes: UInt64) {
        self.downBytesPerSec = downBytesPerSec; self.upBytesPerSec = upBytesPerSec
        self.totalDownBytes = totalDownBytes; self.totalUpBytes = totalUpBytes
    }
}

/// Um app (processos agrupados pelo `.app` que os contém) ou um processo solto.
public struct AppUsage: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    /// Percentual de UM núcleo (como o Monitor de Atividade: pode passar de 100).
    public var cpuPercent: Double
    public var memoryBytes: UInt64
    public var processCount: Int
    public var id: String { name }

    public init(name: String, cpuPercent: Double, memoryBytes: UInt64, processCount: Int) {
        self.name = name; self.cpuPercent = cpuPercent; self.memoryBytes = memoryBytes; self.processCount = processCount
    }
}

public struct MachineSnapshot: Codable, Sendable, Equatable {
    public var at: Date
    public var cpu: CPUSample?
    public var memory: MemorySample?
    public var disk: DiskSample?
    public var network: NetworkSample?
    public var topByCPU: [AppUsage]
    public var topByMemory: [AppUsage]
    public var thermal: String
    public var uptimeSeconds: Double
    public var coreCount: Int

    public init(at: Date, cpu: CPUSample?, memory: MemorySample?, disk: DiskSample?, network: NetworkSample?, topByCPU: [AppUsage],
                topByMemory: [AppUsage], thermal: String, uptimeSeconds: Double, coreCount: Int) {
        self.at = at; self.cpu = cpu; self.memory = memory; self.disk = disk; self.network = network
        self.topByCPU = topByCPU; self.topByMemory = topByMemory; self.thermal = thermal
        self.uptimeSeconds = uptimeSeconds; self.coreCount = coreCount
    }
}

/// Um computador (container Docker) do Racky.
public struct ComputerUsage: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var state: String
    public var cpuPercent: Double
    public var memoryBytes: Int64
    public var memoryLimitBytes: Int64
    public var pids: Int
    /// Sessão do Racky a que o computador pertence (label `racky.session`), quando existe.
    public var sessionID: String?

    public var memoryFraction: Double { memoryLimitBytes <= 0 ? 0 : min(1, Double(memoryBytes) / Double(memoryLimitBytes)) }

    public init(id: String, name: String, state: String, cpuPercent: Double, memoryBytes: Int64, memoryLimitBytes: Int64, pids: Int, sessionID: String?) {
        self.id = id; self.name = name; self.state = state; self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes; self.memoryLimitBytes = memoryLimitBytes; self.pids = pids; self.sessionID = sessionID
    }
}

/// Uso de IA por sessão do Racky (agentes e subagentes), juntando transcripts e o Store.
public struct AgentSessionUsage: Codable, Sendable, Equatable, Identifiable {
    public var sessionID: String
    public var title: String
    public var provider: InsightsProvider
    public var counts: TokenCounts
    public var costUSD: Double
    public var messages: Int
    public var subagentMessages: Int
    public var running: Bool
    public var id: String { sessionID + provider.rawValue }

    public init(sessionID: String, title: String, provider: InsightsProvider, counts: TokenCounts, costUSD: Double, messages: Int,
                subagentMessages: Int, running: Bool) {
        self.sessionID = sessionID; self.title = title; self.provider = provider; self.counts = counts
        self.costUSD = costUSD; self.messages = messages; self.subagentMessages = subagentMessages; self.running = running
    }
}

public struct ProxyDay: Codable, Sendable, Equatable, Identifiable {
    public var dayStart: Date
    public var requests: Int
    public var bytes: Int
    public var costMicros: Int64
    public var id: Date { dayStart }
    public init(dayStart: Date, requests: Int, bytes: Int, costMicros: Int64) {
        self.dayStart = dayStart; self.requests = requests; self.bytes = bytes; self.costMicros = costMicros
    }
}

public struct ProxyUsageSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var isDefault: Bool
    public var requests: Int
    public var bytes: Int
    public var costMicros: Int64
    public var daily: [ProxyDay]
    /// O provedor informa custo (alguma linha de uso com `cost_micros`). `false` = "Usage unavailable": nada é estimado (P13).
    public var reportsCost: Bool
    public init(id: String, name: String, isDefault: Bool, requests: Int, bytes: Int, costMicros: Int64, daily: [ProxyDay], reportsCost: Bool = false) {
        self.id = id; self.name = name; self.isDefault = isDefault; self.requests = requests; self.bytes = bytes
        self.costMicros = costMicros; self.daily = daily; self.reportsCost = reportsCost
    }
}

/// Estado da fonte exata dos limites do Claude (endpoint de uso do Claude Code). O app só toca o Keychain depois do clique
/// explícito em "Show exact limits" (P23); a decisão é guardada, o token nunca.
public enum ClaudeLimitsStatus: Sendable, Equatable {
    /// O usuário ainda não pediu os limites exatos: nada leu o Keychain.
    case notEnabled
    /// Habilitado; aguardando a primeira resposta.
    case loading
    /// Última leitura bem-sucedida.
    case live(fetchedAt: Date)
    /// Token do Claude Code expirado ou recusado: abrir o Claude Code o renova.
    case needsClaudeRefresh
    /// Sem credencial do Claude Code, sem rede ou resposta inesperada. A última leitura boa (se houver) segue valendo até o reset.
    case unavailable
}

/// Estado completo do módulo, publicado pelo `InsightsService`.
public struct InsightsSnapshot: Sendable, Equatable {
    public var generatedAt: Date
    public var claude: ProviderSummary
    public var codex: ProviderSummary
    public var machine: MachineSnapshot?
    public var computers: [ComputerUsage]
    public var dockerAvailable: Bool
    public var agents: [AgentSessionUsage]
    public var proxies: [ProxyUsageSummary]
    public var scanning: Bool
    public var claudeLimits: ClaudeLimitsStatus

    public init(generatedAt: Date = Date(), claude: ProviderSummary = .empty(.claude), codex: ProviderSummary = .empty(.codex),
                machine: MachineSnapshot? = nil, computers: [ComputerUsage] = [], dockerAvailable: Bool = false,
                agents: [AgentSessionUsage] = [], proxies: [ProxyUsageSummary] = [], scanning: Bool = false,
                claudeLimits: ClaudeLimitsStatus = .notEnabled) {
        self.generatedAt = generatedAt; self.claude = claude; self.codex = codex; self.machine = machine
        self.computers = computers; self.dockerAvailable = dockerAvailable; self.agents = agents
        self.proxies = proxies; self.scanning = scanning; self.claudeLimits = claudeLimits
    }

    public static let empty = InsightsSnapshot()
}
