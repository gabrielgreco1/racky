import RackyCore
import Foundation

/// Conteúdo da status bar (03 §5): função pura do que o Insights já publica (`InsightsSnapshot`) e dos computadores vivos
/// (`ComputerRow`). A barra só lê: nenhum polling novo, nenhum número estimado (segmento sem dado não aparece).

enum StatusBarLevel: Equatable {
    case normal, warning, destructive

    init(fraction: Double) {
        self = fraction >= InsightsTone.criticalAt ? .destructive : fraction >= InsightsTone.warnAt ? .warning : .normal
    }

    var worst: Int { self == .destructive ? 2 : self == .warning ? 1 : 0 }
    static func max(_ a: StatusBarLevel, _ b: StatusBarLevel) -> StatusBarLevel { a.worst >= b.worst ? a : b }
}

struct StatusBarWindow: Equatable {
    var label: String
    var fraction: Double
    var resetsAt: Date?
    var level: StatusBarLevel { StatusBarLevel(fraction: fraction) }
    var percentText: String { InsightsFormat.percent(fraction) }
}

struct StatusBarUsage: Equatable {
    var provider: InsightsProvider
    var windows: [StatusBarWindow]
    /// `From Claude Code statusline` / `From Codex session logs` (popover).
    var source: String
    var level: StatusBarLevel { windows.reduce(.normal) { StatusBarLevel.max($0, $1.level) } }
    /// `5h 62% · 7d 31%`.
    var text: String { windows.map { "\($0.label) \($0.percentText)" }.joined(separator: " · ") }
}

struct StatusBarComputerLine: Equatable, Identifiable {
    var id: String { name }
    var name: String
    var session: String?
    var state: String
    var mode: String
    var proxy: String
    var cpuPercent: Double?
    var memoryBytes: Int64?
    /// Uso do proxy escolhido hoje, quando o provedor informa.
    var proxyUsage: String?
    /// O proxy escolhido existe mas o provedor não informa uso: `Usage unavailable`, sem estimativa.
    var proxyUsageUnavailable = false
}

struct StatusBarComputers: Equatable {
    var active: Int
    var queued: Int
    var memoryBytes: Int64?
    var lines: [StatusBarComputerLine]
    /// `3 computers · 6.1 GB` (`· 2 queued` quando há fila).
    var text: String {
        var parts = [active == 1 ? "1 computer" : "\(active) computers"]
        if queued > 0 { parts.append("\(queued) queued") }
        if let memoryBytes, memoryBytes > 0 { parts.append(InsightsFormat.bytes(UInt64(memoryBytes))) }
        return parts.joined(separator: " · ")
    }
}

struct StatusBarProxyLine: Equatable, Identifiable {
    var id: String
    var name: String
    var requests: Int
    /// Custo de hoje informado pelo provedor; `nil` = "Usage unavailable" (nenhuma estimativa).
    var todayMicros: Int64?
}

struct StatusBarProxy: Equatable {
    /// Soma informada hoje, em micro-dólares.
    var todayMicros: Int64
    var lines: [StatusBarProxyLine]
    var text: String { "Proxy \(StatusBarProxy.money(todayMicros)) today" }

    static func money(_ micros: Int64) -> String { InsightsFormat.cost(Double(micros) / 1_000_000) }
}

struct StatusBarContent: Equatable {
    var claude: StatusBarUsage?
    var codex: StatusBarUsage?
    var computers: StatusBarComputers?
    var proxy: StatusBarProxy?
    /// Docker fora do ar com computadores esperados (`Docker isn't running`).
    var dockerProblem = false

    var isEmpty: Bool { claude == nil && codex == nil && computers == nil && proxy == nil && !dockerProblem }

    /// - Parameters:
    ///   - rows: computadores do `ComputersModel` (estado, sessão, proxy escolhido).
    ///   - dockerExpected: há computadores ou fila, então "Docker parado" é problema (não é quando nada usa Docker).
    static func make(snapshot: InsightsSnapshot, rows: [ComputerRow], dockerStopped: Bool = false, now: Date, calendar: Calendar = .current) -> StatusBarContent {
        var out = StatusBarContent()
        out.claude = usage(snapshot.claude, provider: .claude, now: now, source: snapshot.claudeLimits.isLive ? "From Claude Code usage" : "From Claude Code statusline")
        out.codex = usage(snapshot.codex, provider: .codex, now: now, source: "From Codex session logs")
        out.proxy = proxy(snapshot.proxies, now: now, calendar: calendar)
        out.computers = computers(snapshot: snapshot, rows: rows, proxies: out.proxy, summaries: snapshot.proxies)
        out.dockerProblem = dockerStopped && out.computers != nil
        return out
    }

    private static func usage(_ summary: ProviderSummary, provider: InsightsProvider, now: Date, source: String) -> StatusBarUsage? {
        var windows: [StatusBarWindow] = []
        for (label, window) in [("5h", summary.fiveHour), ("7d", summary.sevenDay)] {
            guard let window, window.source == .reported, let fraction = window.usedFraction else { continue }
            // Janela que já virou (o Insights só recalcula com novo dado): some em vez de mostrar o número velho.
            if let resets = window.resetsAt, resets <= now { continue }
            windows.append(StatusBarWindow(label: label, fraction: fraction, resetsAt: window.resetsAt))
        }
        return windows.isEmpty ? nil : StatusBarUsage(provider: provider, windows: windows, source: source)
    }

    private static func proxy(_ summaries: [ProxyUsageSummary], now: Date, calendar: Calendar) -> StatusBarProxy? {
        let reporting = summaries.filter(\.reportsCost)
        guard !reporting.isEmpty else { return nil }
        let today = calendar.startOfDay(for: now)
        var lines: [StatusBarProxyLine] = []
        var total: Int64 = 0
        for summary in summaries {
            let day = summary.daily.first { calendar.startOfDay(for: $0.dayStart) == today }
            let micros: Int64? = summary.reportsCost ? (day?.costMicros ?? 0) : nil
            total += micros ?? 0
            lines.append(StatusBarProxyLine(id: summary.id, name: summary.name, requests: day?.requests ?? 0, todayMicros: micros))
        }
        return StatusBarProxy(todayMicros: total, lines: lines.sorted { $0.name < $1.name })
    }

    private static func computers(snapshot: InsightsSnapshot, rows: [ComputerRow], proxies: StatusBarProxy?, summaries: [ProxyUsageSummary]) -> StatusBarComputers? {
        let activeStates: Set<BoxState> = [.ready, .inUse, .provisioning]
        let live = rows.filter { activeStates.contains($0.snapshot.state) }
        let queued = rows.filter { $0.snapshot.state == .queued }.count
        guard !live.isEmpty || queued > 0 else { return nil }
        let samples = Dictionary(snapshot.computers.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var lines: [StatusBarComputerLine] = []
        for row in live {
            let sample = samples[row.id]
            let proxyName = row.snapshot.proxy
            let proxyLine = proxies?.lines.first { $0.name == proxyName }
            lines.append(StatusBarComputerLine(
                name: row.id, session: row.sessionTitle, state: stateText(row.snapshot.state), mode: row.snapshot.display, proxy: proxyName,
                cpuPercent: sample?.cpuPercent, memoryBytes: sample?.memoryBytes, proxyUsage: proxyLine?.todayMicros.map(StatusBarProxy.money),
                proxyUsageUnavailable: proxyLine != nil && proxyLine?.todayMicros == nil))
        }
        let memory = live.compactMap { samples[$0.id]?.memoryBytes }.reduce(0, +)
        return StatusBarComputers(active: live.count, queued: queued, memoryBytes: samples.isEmpty ? nil : memory, lines: lines)
    }

    static func stateText(_ state: BoxState) -> String {
        switch state {
        case .inUse: "In use"
        case .ready: "Ready"
        case .provisioning: "Starting"
        case .queued: "Queued"
        case .stopped: "Stopped"
        case .failed: "Failed"
        }
    }

    // MARK: Reset

    /// `Resets at 2:20 PM` (hoje) ou `Resets Mon 9:00 AM` (outro dia). Sem calendário injetado usa o corrente.
    static func resetText(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.dateFormat = "h:mm a"
            return "Resets at \(formatter.string(from: date))"
        }
        formatter.dateFormat = "EEE h:mm a"
        return "Resets \(formatter.string(from: date))"
    }
}

extension ClaudeLimitsStatus {
    var isLive: Bool { if case .live = self { true } else { false } }
}
