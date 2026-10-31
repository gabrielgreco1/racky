import RackyCore
import RackyDesignSystem
import SwiftUI

/// Textos em inglês do PR e dos checks (P2): chip, hover, bloco do Source Control e resumo da aba Checks.
enum PullRequestText {
    static func stateName(_ state: PullRequestChipModel.State) -> String {
        switch state {
        case .open: String(localized: "Open", bundle: .module)
        case .draft: String(localized: "Draft", bundle: .module)
        case .merged: String(localized: "Merged", bundle: .module)
        case .closed: String(localized: "Closed", bundle: .module)
        }
    }

    static func reviewName(_ decision: PullRequestReviewDecision?) -> String? {
        switch decision {
        case .approved: String(localized: "Approved", bundle: .module)
        case .changesRequested: String(localized: "Changes requested", bundle: .module)
        case .reviewRequired: String(localized: "Review required", bundle: .module)
        case nil: nil
        }
    }

    /// `2 checks failing`, `1 check pending`, `9 checks passing` (o pior primeiro); vazio sem checks.
    static func checksPhrase(_ pr: PullRequestChipModel) -> String? {
        if pr.failing > 0 {
            return pr.failing == 1 ? String(localized: "1 check failing", bundle: .module) : String(localized: "\(pr.failing) checks failing", bundle: .module)
        }
        if pr.pending > 0 {
            return pr.pending == 1 ? String(localized: "1 check pending", bundle: .module) : String(localized: "\(pr.pending) checks pending", bundle: .module)
        }
        if pr.passing > 0 {
            return pr.passing == 1 ? String(localized: "1 check passing", bundle: .module) : String(localized: "\(pr.passing) checks passing", bundle: .module)
        }
        return nil
    }

    /// `Open · 2 checks failing · Review required` (03 §10.2).
    static func detailLine(_ pr: PullRequestChipModel) -> String {
        [stateName(pr.state), checksPhrase(pr), reviewName(pr.reviewDecision)].compactMap { $0 }.joined(separator: " · ")
    }

    /// Hover do chip: título, detalhe e, com o GitHub pausado, o motivo (AC-504).
    static func tooltip(_ pr: PullRequestChipModel) -> String {
        var lines = ["#\(pr.number) \(pr.title)", detailLine(pr)]
        if let paused = pr.pausedReason { lines.append(paused) }
        else if pr.isStale { lines.append(String(localized: "Showing the last known state", bundle: .module)) }
        return lines.joined(separator: "\n")
    }

    /// Rótulo de acessibilidade do chip.
    static func summary(_ pr: PullRequestChipModel) -> String {
        String(localized: "Pull request #\(pr.number), \(detailLine(pr))", bundle: .module)
    }

    /// `2 failing · 1 pending · 9 passing` (03 §10.3); zeros somem.
    static func checksSummary(_ pr: PullRequestChipModel) -> String {
        var parts: [String] = []
        if pr.failing > 0 { parts.append(String(localized: "\(pr.failing) failing", bundle: .module)) }
        if pr.pending > 0 { parts.append(String(localized: "\(pr.pending) pending", bundle: .module)) }
        if pr.passing > 0 { parts.append(String(localized: "\(pr.passing) passing", bundle: .module)) }
        return parts.joined(separator: " · ")
    }
}

enum GitHubMetrics {
    static let chipHeight: CGFloat = 14
    static let stateIcon: CGFloat = 13
    static let checksIcon: CGFloat = 12
    static let blockStateIcon: CGFloat = 16
    static let rowHeight: CGFloat = 24
    static let checkRowHeight: CGFloat = 28
    static let headerHeight: CGFloat = 40
    static let skeletonHeight: CGFloat = 8
    static let skeletonWidth: CGFloat = 120
    static let letterWidth: CGFloat = 14
    static let dot: CGFloat = 6
    static let overlayWidth: CGFloat = 480
}

/// Ícone do estado do PR (13 no chip, 16 no bloco): aberto, rascunho, mergeado, fechado.
struct PRStateGlyph: View {
    let state: PullRequestChipModel.State
    var size: CGFloat = GitHubMetrics.stateIcon

    var body: some View {
        Image(systemName: state == .merged ? "arrow.triangle.merge" : "arrow.triangle.pull")
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch state {
        case .open: DS.Color.prOpen
        case .draft: DS.Color.prDraft
        case .merged: DS.Color.prMerged
        case .closed: DS.Color.prClosed
        }
    }
}

/// Glifo do resultado dos checks (12): falhando, pendente, passando. Sem checks não desenha nada.
struct ChecksGlyph: View {
    let outcome: ChecksSummaryState
    var size: CGFloat = GitHubMetrics.checksIcon

    var body: some View {
        if let symbol {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(color)
                .accessibilityHidden(true)
        }
    }

    private var symbol: String? {
        switch outcome {
        case .none: nil
        case .pending: "circle.dotted"
        case .success: "checkmark.circle.fill"
        case .failure: "xmark.circle.fill"
        }
    }

    private var color: Color {
        switch outcome {
        case .failure: DS.Color.checksFailing
        case .pending: DS.Color.checksPending
        default: DS.Color.checksPassing
        }
    }
}

extension CheckOutcome {
    var summaryState: ChecksSummaryState {
        switch self {
        case .failure: .failure
        case .pending: .pending
        case .success: .success
        case .skipped: .none
        }
    }
}

/// Chip de PR do card (03 §2.6, DS §12.4): ícone de estado + `#n` + glifo de checks. Clique abre o PR no navegador
/// (`git.openPR`, pelo registro de ações).
struct PullRequestChipView: View {
    let pr: PullRequestChipModel
    let sessionID: UUID

    var body: some View {
        ActionButton(.gitOpenPR, id: .sidebarSessionPrChip(sessionID.uuidString), argument: .select(sessionID.uuidString), tooltip: PullRequestText.tooltip(pr)) {
            HStack(spacing: DS.Space.s0_5) {
                PRStateGlyph(state: pr.state)
                Text(verbatim: "#\(pr.number)")
                    .dsFont(DS.Font.microNumeric)
                    .foregroundStyle(DS.Color.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
                ChecksGlyph(outcome: pr.checks)
            }
            .opacity(pr.isStale ? 0.7 : 1)
            .frame(height: GitHubMetrics.chipHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: PullRequestText.summary(pr)))
    }
}
