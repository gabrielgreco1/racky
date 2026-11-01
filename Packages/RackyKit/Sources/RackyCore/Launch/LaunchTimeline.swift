import Foundation

/// Checklist da ignição (04 §7.2.2, M-503): uma linha por etapa real que tem texto. Puro, alimentado só por `LaunchEvent`.
public struct LaunchTimeline: Sendable, Equatable {
    public struct Row: Sendable, Equatable, Identifiable {
        public var key: LaunchStepKey
        public var title: String
        public var status: LaunchStepStatus
        public var detail: String?
        public var id: String { key.rawValue }
    }

    public var agentName: String
    public var startedAt: Date
    public var runID: UUID?
    public private(set) var rows: [Row] = []
    public private(set) var firstOutputAt: Date?
    public private(set) var failure: String?

    /// Máximo de linhas visíveis (04 §7.2.2); as concluídas mais antigas colapsam em "N steps done".
    public static let maxVisibleRows = 6

    public init(agentName: String, startedAt: Date = Date()) {
        self.agentName = agentName
        self.startedAt = startedAt
    }

    public var hasSeenFirstOutput: Bool { firstOutputAt != nil }

    public mutating func apply(_ event: LaunchEvent) {
        switch event {
        case .step(let progress):
            if runID == nil { runID = progress.runID }
            guard let title = progress.step.title(agent: agentName) else {
                if progress.status == .failed { failure = progress.detail }
                return
            }
            if progress.status == .skipped {
                rows.removeAll { $0.key == progress.step }
                return
            }
            if progress.status == .failed { failure = progress.detail }
            if let i = rows.firstIndex(where: { $0.key == progress.step }) {
                rows[i].status = progress.status
                if let detail = progress.detail { rows[i].detail = detail }
            } else {
                rows.append(Row(key: progress.step, title: title, status: progress.status, detail: progress.detail))
                rows.sort { Self.order($0.key) < Self.order($1.key) }
            }
        case .firstOutput:
            firstOutputAt = Date()
        case .nativeID:
            break
        }
    }

    private static func order(_ key: LaunchStepKey) -> Int { LaunchStepKey.allCases.firstIndex(of: key) ?? 0 }

    /// Linhas que a UI mostra e quantas concluídas colapsaram.
    public var visible: (rows: [Row], collapsedDone: Int) {
        guard rows.count > Self.maxVisibleRows else { return (rows, 0) }
        let overflow = rows.count - Self.maxVisibleRows + 1 // +1: a linha "N steps done" ocupa uma vaga
        var collapsed = 0
        var kept: [Row] = []
        for row in rows {
            if collapsed < overflow, row.status == .done { collapsed += 1 } else { kept.append(row) }
        }
        return (kept, collapsed)
    }
}
