import Foundation

/// O que a UI precisa de um PR para desenhar o chip da sidebar, o bloco do Source Control e a lista de Checks
/// (03 §2.6, §10.2, §10.3). Derivado do `BranchPullRequestInfo` do `GitHubService`; sem texto de UI (a UI traduz).
public struct PullRequestChipModel: Sendable, Equatable {
    public enum State: Sendable, Equatable { case draft, open, merged, closed }

    public let number: Int
    public let title: String
    public let url: String
    public let state: State
    public let checks: ChecksSummaryState
    public let counts: CheckCounts
    public let reviewDecision: PullRequestReviewDecision?
    public let baseRefName: String?
    /// Os checks vêm truncados pela consulta (mais que o limite do lote).
    public let checksTruncated: Bool
    /// A consulta não foi feita neste ciclo (backoff, rate limit): o chip mostra o último estado.
    public let isStale: Bool
    /// O HEAD local difere do HEAD do PR (há commits que o PR ainda não tem, ou o contrário).
    public let headDiffersFromLocal: Bool
    /// "Paused · rate limit" no hover (AC-504); preenchido pelo controlador quando o GitHub respondeu 403 de limite.
    public var pausedReason: String?
    public let items: [CheckItem]

    public init(number: Int, title: String, url: String, state: State, counts: CheckCounts = CheckCounts(), items: [CheckItem] = [],
                reviewDecision: PullRequestReviewDecision? = nil, baseRefName: String? = nil, checksTruncated: Bool = false,
                isStale: Bool = false, headDiffersFromLocal: Bool = false, pausedReason: String? = nil) {
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.counts = counts
        self.checks = items.isEmpty && counts.total == 0 ? .none : (counts.failure > 0 ? .failure : (counts.pending > 0 ? .pending : .success))
        self.reviewDecision = reviewDecision
        self.baseRefName = baseRefName
        self.checksTruncated = checksTruncated
        self.isStale = isStale
        self.headDiffersFromLocal = headDiffersFromLocal
        self.pausedReason = pausedReason
        self.items = items
    }

    public init?(_ info: BranchPullRequestInfo?, pausedReason: String? = nil) {
        guard let pr = info?.pullRequest, let info else { return nil }
        let state: State =
            switch pr.chip {
            case .merged: .merged
            case .closed: .closed
            case .draft: .draft
            default: .open
            }
        self.init(
            number: pr.number, title: pr.title, url: pr.url, state: state, counts: pr.checks.counts, items: pr.checks.items,
            reviewDecision: pr.reviewDecision, baseRefName: pr.baseRefName, checksTruncated: pr.checks.isTruncated,
            isStale: info.isStale, headDiffersFromLocal: info.headMatchesLocal == false, pausedReason: pausedReason)
    }

    /// Falhando + pendentes + passando (skipped não entra no resumo).
    public var failing: Int { counts.failure }
    public var pending: Int { counts.pending }
    public var passing: Int { counts.success }

    /// Checks agrupados como em 03 §10.3: falhando, pendentes, passando (skipped junto dos passando).
    public var failingItems: [CheckItem] { items.filter { $0.outcome == .failure } }
    public var pendingItems: [CheckItem] { items.filter { $0.outcome == .pending } }
    public var passingItems: [CheckItem] { items.filter { $0.outcome == .success || $0.outcome == .skipped } }
}
