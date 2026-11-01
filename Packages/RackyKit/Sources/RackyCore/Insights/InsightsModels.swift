import Foundation

/// Modelos do módulo Insights (uso de IA + monitor da máquina). Tudo `Sendable`/`Codable`: o que é persistido são
/// agregados numéricos por hora, nunca conteúdo de prompt ou de transcript.

public enum InsightsProvider: String, Codable, Sendable, CaseIterable {
    case claude, codex
}

/// Contagem de tokens de uma mensagem ou de um agregado.
public struct TokenCounts: Codable, Hashable, Sendable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite5m: Int
    public var cacheWrite1h: Int

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite5m: Int = 0, cacheWrite1h: Int = 0) {
        self.input = input; self.output = output; self.cacheRead = cacheRead
        self.cacheWrite5m = cacheWrite5m; self.cacheWrite1h = cacheWrite1h
    }

    public static let zero = TokenCounts()

    public var cacheWrite: Int { cacheWrite5m + cacheWrite1h }
    /// Tudo que passou pelo modelo (inclui leitura de cache).
    public var total: Int { input + output + cacheRead + cacheWrite }
    /// Tokens "novos": o que o usuário costuma chamar de uso (sem reler cache).
    public var fresh: Int { input + output + cacheWrite }
    public var isEmpty: Bool { total == 0 }

    public static func + (a: TokenCounts, b: TokenCounts) -> TokenCounts {
        TokenCounts(input: a.input + b.input, output: a.output + b.output, cacheRead: a.cacheRead + b.cacheRead,
                    cacheWrite5m: a.cacheWrite5m + b.cacheWrite5m, cacheWrite1h: a.cacheWrite1h + b.cacheWrite1h)
    }

    public static func += (a: inout TokenCounts, b: TokenCounts) { a = a + b }

    /// Diferença campo a campo, nunca negativa (mensagem em streaming que cresce entre duas leituras).
    public func delta(since old: TokenCounts) -> TokenCounts {
        TokenCounts(input: max(0, input - old.input), output: max(0, output - old.output),
                    cacheRead: max(0, cacheRead - old.cacheRead),
                    cacheWrite5m: max(0, cacheWrite5m - old.cacheWrite5m), cacheWrite1h: max(0, cacheWrite1h - old.cacheWrite1h))
    }

    /// Maior valor por campo (várias linhas da mesma mensagem carregam o uso parcial até o final).
    public func merged(max other: TokenCounts) -> TokenCounts {
        TokenCounts(input: Swift.max(input, other.input), output: Swift.max(output, other.output),
                    cacheRead: Swift.max(cacheRead, other.cacheRead),
                    cacheWrite5m: Swift.max(cacheWrite5m, other.cacheWrite5m), cacheWrite1h: Swift.max(cacheWrite1h, other.cacheWrite1h))
    }
}

/// Uso agregado por (provider, sessão, modelo, hora). É a unidade persistida.
public struct UsageBucket: Codable, Hashable, Sendable {
    public var provider: InsightsProvider
    public var session: String
    public var model: String
    /// Início da hora, em segundos desde 1970 (UTC).
    public var hour: Int64
    public var counts: TokenCounts
    public var messages: Int
    public var sidechainMessages: Int

    public init(provider: InsightsProvider, session: String, model: String, hour: Int64, counts: TokenCounts = .zero,
                messages: Int = 0, sidechainMessages: Int = 0) {
        self.provider = provider; self.session = session; self.model = model; self.hour = hour
        self.counts = counts; self.messages = messages; self.sidechainMessages = sidechainMessages
    }

    public var key: String { Self.key(provider, session, model, hour) }
    public static func key(_ p: InsightsProvider, _ s: String, _ m: String, _ h: Int64) -> String { "\(p.rawValue)|\(s)|\(m)|\(h)" }
    public var hourStart: Date { Date(timeIntervalSince1970: TimeInterval(hour)) }
}

public enum LimitKind: String, Codable, Sendable { case fiveHour, sevenDay }

public enum LimitSource: String, Codable, Sendable {
    /// Número exato do provedor: endpoint de uso do Claude Code, `rate_limits` da status line/hooks ou do rollout do Codex.
    case reported
    /// Sem número exato do provedor: só os totais locais da janela. A fração fica `nil` (a UI mostra "—"); nunca se estima.
    case unavailable
}

/// Uma janela de limite (5 h ou 7 d).
public struct LimitWindow: Codable, Sendable, Equatable {
    public var kind: LimitKind
    public var source: LimitSource
    /// 0…1 (pode passar de 1 se o provedor reportar). `nil` = sem número exato.
    public var usedFraction: Double?
    public var resetsAt: Date?
    public var startedAt: Date?
    public var counts: TokenCounts
    public var costUSD: Double
    public var messages: Int

    public init(kind: LimitKind, source: LimitSource, usedFraction: Double?, resetsAt: Date?, startedAt: Date? = nil,
                counts: TokenCounts = .zero, costUSD: Double = 0, messages: Int = 0) {
        self.kind = kind; self.source = source; self.usedFraction = usedFraction; self.resetsAt = resetsAt
        self.startedAt = startedAt; self.counts = counts; self.costUSD = costUSD; self.messages = messages
    }
}

public struct PlanInfo: Codable, Sendable, Equatable {
    public var loggedIn: Bool
    /// `pro`, `max`, `team`, `plus`… exatamente como o CLI informa; `nil` se não informou.
    public var plan: String?
    public var authMethod: String?
    public var organization: String?

    public init(loggedIn: Bool, plan: String? = nil, authMethod: String? = nil, organization: String? = nil) {
        self.loggedIn = loggedIn; self.plan = plan; self.authMethod = authMethod; self.organization = organization
    }
}

public struct DailyUsage: Codable, Sendable, Equatable, Identifiable {
    public var dayStart: Date
    public var counts: TokenCounts
    public var costUSD: Double
    public var id: Date { dayStart }
    public init(dayStart: Date, counts: TokenCounts, costUSD: Double) {
        self.dayStart = dayStart; self.counts = counts; self.costUSD = costUSD
    }
}

public struct ModelUsage: Codable, Sendable, Equatable, Identifiable {
    public var model: String
    public var counts: TokenCounts
    public var costUSD: Double
    public var share: Double
    public var id: String { model }
    public init(model: String, counts: TokenCounts, costUSD: Double, share: Double) {
        self.model = model; self.counts = counts; self.costUSD = costUSD; self.share = share
    }
}

public struct SessionUsage: Codable, Sendable, Equatable, Identifiable {
    public var session: String
    public var label: String?
    public var counts: TokenCounts
    public var costUSD: Double
    public var messages: Int
    public var sidechainMessages: Int
    public var lastActive: Date
    public var id: String { session }
    public init(session: String, label: String?, counts: TokenCounts, costUSD: Double, messages: Int, sidechainMessages: Int, lastActive: Date) {
        self.session = session; self.label = label; self.counts = counts; self.costUSD = costUSD
        self.messages = messages; self.sidechainMessages = sidechainMessages; self.lastActive = lastActive
    }
}

/// Tudo que a aba de um provedor mostra.
public struct ProviderSummary: Codable, Sendable, Equatable {
    public var provider: InsightsProvider
    public var generatedAt: Date
    public var plan: PlanInfo?
    public var fiveHour: LimitWindow?
    public var sevenDay: LimitWindow?
    public var today: TokenCounts
    public var todayCostUSD: Double
    public var todayMessages: Int
    public var week: TokenCounts
    public var weekCostUSD: Double
    /// 24 posições (hora local do dia), peso = tokens novos dos últimos 14 dias.
    public var hourOfDay: [Double]
    /// Sete dias, o mais antigo primeiro, o último é hoje.
    public var dailyWeek: [DailyUsage]
    public var topModels: [ModelUsage]
    public var topSessions: [SessionUsage]
    public var unpricedModels: [String]
    public var hasData: Bool

    public static func empty(_ provider: InsightsProvider, at date: Date = Date()) -> ProviderSummary {
        ProviderSummary(provider: provider, generatedAt: date, plan: nil, fiveHour: nil, sevenDay: nil, today: .zero,
                        todayCostUSD: 0, todayMessages: 0, week: .zero, weekCostUSD: 0, hourOfDay: Array(repeating: 0, count: 24),
                        dailyWeek: [], topModels: [], topSessions: [], unpricedModels: [], hasData: false)
    }
}
