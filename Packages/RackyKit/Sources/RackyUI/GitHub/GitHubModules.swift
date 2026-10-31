import RackyCore
import RackyDesignSystem
import RackyProtocol
import SwiftUI

extension PanelModuleID {
    static let sourceControl: PanelModuleID = "sourceControl"
    static let checks: PanelModuleID = "checks"
}

/// Source Control (03 §10.2): só lista. Branch, PR da sessão, "Create Pull Request…" e os arquivos alterados contra a base.
/// Sem stage, commit nem push pela UI. Abre por ⇧⌘G.
@MainActor
final class SourceControlModule: RightPanelModule {
    let id = PanelModuleID.sourceControl
    let title = String(localized: "Source Control", bundle: .module)
    let icon = "arrow.triangle.branch"
    private let controller: GitHubController

    init(controller: GitHubController) { self.controller = controller }

    func makeView(context: RightPanelModuleContext) -> AnyView {
        AnyView(SourceControlView(controller: controller, compact: context.isCompact))
    }
}

/// Checks (03 §10.3): os checks de CI do PR da sessão, agrupados em falhando, pendentes e passando. Sem rede própria: lê o que
/// a consulta do PR já trouxe.
@MainActor
final class ChecksModule: RightPanelModule {
    let id = PanelModuleID.checks
    let title = String(localized: "Checks", bundle: .module)
    let icon = "checklist"
    private let controller: GitHubController

    init(controller: GitHubController) { self.controller = controller }

    func makeView(context: RightPanelModuleContext) -> AnyView {
        AnyView(ChecksView(controller: controller, compact: context.isCompact))
    }
}

// MARK: Peças comuns

private struct SkeletonRows: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: DS.Radius.xs)
                    .fill(DS.Color.fg5)
                    .frame(width: GitHubMetrics.skeletonWidth, height: GitHubMetrics.skeletonHeight)
            }
        }
        .padding(DS.Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }
}

private struct GitSectionHeader: View {
    let title: String
    var count: Int?

    var body: some View {
        HStack(spacing: DS.Space.s1_5) {
            Text(verbatim: title)
                .dsFont(DS.Font.sectionLabel)
                .foregroundStyle(DS.Color.textSecondary)
            if let count {
                Text(verbatim: "\(count)")
                    .dsFont(DS.Font.microNumeric)
                    .foregroundStyle(DS.Color.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.s3)
        .frame(height: GitHubMetrics.rowHeight)
    }
}

// MARK: Source Control

struct SourceControlView: View {
    let controller: GitHubController
    let compact: Bool

    var body: some View {
        let session = controller.source.selected()
        VStack(spacing: 0) {
            if let session {
                if session.branch == nil, session.status == nil {
                    DSEmptyState(String(localized: "This session isn't a Git repository.", bundle: .module))
                        .frame(maxHeight: .infinity)
                } else {
                    header(session)
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            pullRequestBlock(session)
                            changesList(session)
                        }
                    }
                    .scrollIndicators(.never)
                    footer(session)
                }
            } else {
                DSEmptyState(String(localized: "Select a session to see its changes.", bundle: .module))
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(DS.Color.panel)
        .onAppear { controller.viewAppeared() }
        .onDisappear { controller.viewDisappeared() }
        .task(id: session?.id) { await controller.refreshPanel(force: false) }
        .a11y(.rightPanelModule("sourceControl.body"), kind: "container")
    }

    // Cabeçalho (40): branch + ↑↓ + Refresh; abaixo, a base.
    private func header(_ session: GitHubSessionRef) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.s1_5) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: GitHubMetrics.checksIcon))
                    .foregroundStyle(DS.Color.textSecondary)
                Text(verbatim: session.branch ?? String(localized: "Detached", bundle: .module))
                    .dsFont(DS.Font.monoMicro)
                    .foregroundStyle(DS.Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .a11y(.rightPanelSourceControlBranch, kind: "text", label: session.branch ?? "")
                if let status = session.status, status.upstream != nil {
                    Text(verbatim: "↑\(status.ahead ?? 0) ↓\(status.behind ?? 0)")
                        .dsFont(DS.Font.microNumeric)
                        .foregroundStyle(DS.Color.textTertiary)
                        .fixedSize()
                }
                Spacer(minLength: DS.Space.s1)
                if controller.refreshing { DSSpinner(size: GitHubMetrics.checksIcon, delayed: false) }
                DSIconButton(
                    .panelRefresh, id: .rightPanelSourceControlRefresh, symbol: "arrow.clockwise",
                    name: String(localized: "Refresh", bundle: .module), variant: .row)
            }
            if let base = controller.baseRef, !compact {
                Text("Based on \(base)", bundle: .module)
                    .dsFont(DS.Font.small)
                    .foregroundStyle(DS.Color.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, DS.Space.s3)
        .padding(.vertical, DS.Space.s1)
        .frame(minHeight: GitHubMetrics.headerHeight, alignment: .center)
        .overlay(alignment: .bottom) { DS.Color.border.frame(height: DSMetrics.hairline) }
    }

    // Bloco do PR: estado + título + detalhe + ações; sem PR, o botão de criar.
    @ViewBuilder private func pullRequestBlock(_ session: GitHubSessionRef) -> some View {
        if let pr = controller.chips[session.id] {
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                HStack(alignment: .top, spacing: DS.Space.s2) {
                    PRStateGlyph(state: pr.state, size: GitHubMetrics.blockStateIcon)
                    VStack(alignment: .leading, spacing: DS.Space.s0_5) {
                        Text(verbatim: "#\(pr.number) \(pr.title)")
                            .dsFont(DS.Font.bodyStrong)
                            .foregroundStyle(DS.Color.textPrimary)
                            .lineLimit(2)
                        HStack(spacing: DS.Space.s1) {
                            ChecksGlyph(outcome: pr.checks)
                            Text(verbatim: PullRequestText.detailLine(pr))
                                .dsFont(DS.Font.small)
                                .foregroundStyle(DS.Color.textSecondary)
                                .lineLimit(1)
                        }
                        if let paused = pr.pausedReason {
                            Text(verbatim: paused)
                                .dsFont(DS.Font.small)
                                .foregroundStyle(DS.Color.warning)
                        }
                    }
                }
                HStack(spacing: DS.Space.s1) {
                    DSButton(
                        .gitOpenPR, id: .rightPanelSourceControlOpenPR, "Open on GitHub", variant: .ghost, size: .xs, symbol: "arrow.up.right.square",
                        argument: .select(session.id.uuidString))
                    DSButton(
                        .gitCopyPRURL, id: .rightPanelSourceControlCopyURL, "Copy URL", variant: .ghost, size: .xs, symbol: "doc.on.doc",
                        argument: .select(session.id.uuidString))
                }
            }
            .padding(DS.Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { DS.Color.border.frame(height: DSMetrics.hairline) }
            .a11y(.rightPanelSourceControlPr, kind: "container", label: PullRequestText.summary(pr))
        } else if controller.access == .loggedOut || controller.access == .ghMissing {
            Text(
                controller.access == .ghMissing
                    ? String(localized: "Install the GitHub CLI to see pull requests.", bundle: .module)
                    : String(localized: "Log in to GitHub CLI to see pull requests.", bundle: .module)
            )
            .dsFont(DS.Font.small)
            .foregroundStyle(DS.Color.textTertiary)
            .padding(DS.Space.s3)
        } else if !(session.branch ?? "").isEmpty, !controller.notOnGitHub.contains(session.folderPath) {
            VStack(alignment: .leading, spacing: DS.Space.s1_5) {
                DSButton(
                    .gitCreatePR, id: .rightPanelSourceControlCreatePR, "Create Pull Request…", variant: .outline, size: .sm,
                    argument: .select(session.id.uuidString))
                Text("Pushes \(session.branch ?? "") and opens a pull request on GitHub.", bundle: .module)
                    .dsFont(DS.Font.small)
                    .foregroundStyle(DS.Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DS.Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { DS.Color.border.frame(height: DSMetrics.hairline) }
        }
    }

    @ViewBuilder private func changesList(_ session: GitHubSessionRef) -> some View {
        GitSectionHeader(
            title: String(localized: "Changes", bundle: .module), count: controller.changesLoad == .loaded ? controller.changes.count : nil)
        switch controller.changesLoad {
        case .idle, .loading:
            SkeletonRows()
        case .failed:
            VStack(spacing: DS.Space.s2) {
                Text("Couldn't read Git status.", bundle: .module)
                    .dsFont(DS.Font.small)
                    .foregroundStyle(DS.Color.textSecondary)
                DSButton(.panelRefresh, id: .rightPanelSourceControlRetry, "Try Again", variant: .outline, size: .sm)
            }
            .frame(maxWidth: .infinity)
            .padding(DS.Space.s3)
        case .loaded:
            if controller.changes.isEmpty {
                Text("No changes.", bundle: .module)
                    .dsFont(DS.Font.small)
                    .foregroundStyle(DS.Color.textTertiary)
                    .padding(.horizontal, DS.Space.s3)
                    .padding(.vertical, DS.Space.s2)
            } else {
                ForEach(controller.changes) { change in
                    ChangeRow(change: change, compact: compact)
                }
            }
        }
    }

    private func footer(_ session: GitHubSessionRef) -> some View {
        HStack(spacing: DS.Space.s1) {
            DSButton(
                .itemOpenInEditor, id: .rightPanelSourceControlOpenInEditor, "Open in Editor", variant: .ghost, size: .xs,
                argument: .select(session.id.uuidString))
            DSButton(
                .itemRevealInFinder, id: .rightPanelSourceControlRevealInFinder, "Reveal in Finder", variant: .ghost, size: .xs,
                argument: .select(session.id.uuidString))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.s2)
        .frame(height: GitHubMetrics.headerHeight - DS.Space.s2)
        .overlay(alignment: .top) { DS.Color.border.frame(height: DSMetrics.hairline) }
    }
}

private struct ChangeRow: View {
    let change: GitFileChange
    let compact: Bool

    var body: some View {
        ActionButton(.gitOpenChange, id: .rightPanelSourceControlChange(change.path), argument: .select(change.path), tooltip: change.path) {
            HStack(spacing: DS.Space.s1_5) {
                Text(verbatim: change.kind.letter)
                    .dsFont(DS.Font.monoMicro)
                    .foregroundStyle(color)
                    .frame(width: GitHubMetrics.letterWidth)
                Text(verbatim: change.name)
                    .dsFont(DS.Font.tab)
                    .foregroundStyle(DS.Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !compact, !change.directory.isEmpty {
                    Text(verbatim: change.directory)
                        .dsFont(DS.Font.small)
                        .foregroundStyle(DS.Color.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: DS.Space.s1)
                if let added = change.additions, let removed = change.deletions {
                    HStack(spacing: DS.Space.s1) {
                        Text(verbatim: "+\(added)").foregroundStyle(DS.Color.gitAdded)
                        Text(verbatim: "−\(removed)").foregroundStyle(DS.Color.gitDeleted)
                    }
                    .dsFont(DS.Font.microNumeric)
                    .fixedSize()
                }
            }
            .padding(.horizontal, DS.Space.s3)
            .frame(height: GitHubMetrics.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(DSListRowStyle(selected: false))
    }

    private var color: Color {
        switch change.kind {
        case .added: DS.Color.gitAdded
        case .modified: DS.Color.gitModified
        case .deleted: DS.Color.gitDeleted
        case .untracked: DS.Color.gitUntracked
        }
    }
}

// MARK: Checks

struct ChecksView: View {
    let controller: GitHubController
    let compact: Bool
    @State private var passingOpen = false

    var body: some View {
        let session = controller.source.selected()
        VStack(spacing: 0) {
            if let session {
                content(session)
            } else {
                DSEmptyState(String(localized: "Select a session to see its checks.", bundle: .module))
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(DS.Color.panel)
        .onAppear { controller.viewAppeared() }
        .onDisappear { controller.viewDisappeared() }
        .task(id: session?.id) { await controller.refreshPanel(force: false) }
        .a11y(.rightPanelModule("checks.body"), kind: "container")
    }

    @ViewBuilder private func content(_ session: GitHubSessionRef) -> some View {
        if let pr = controller.chips[session.id] {
            toolbar(pr)
            if pr.items.isEmpty {
                DSEmptyState(String(localized: "No checks reported.", bundle: .module)).frame(maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        group(String(localized: "Failing", bundle: .module), pr.failingItems, outcome: .failure)
                        group(String(localized: "Pending", bundle: .module), pr.pendingItems, outcome: .pending)
                        passingGroup(pr)
                        if pr.checksTruncated {
                            Text("Showing the first \(pr.items.count) checks.", bundle: .module)
                                .dsFont(DS.Font.small)
                                .foregroundStyle(DS.Color.textTertiary)
                                .padding(DS.Space.s3)
                        }
                    }
                }
                .scrollIndicators(.never)
            }
            updated
        } else if controller.access == .loggedOut || controller.access == .ghMissing {
            DSEmptyState(
                controller.access == .ghMissing
                    ? String(localized: "Install the GitHub CLI to see checks.", bundle: .module)
                    : String(localized: "Log in to GitHub CLI to see checks.", bundle: .module)
            )
            .frame(maxHeight: .infinity)
        } else if controller.updatedAt == nil, !controller.notOnGitHub.contains(session.folderPath) {
            SkeletonRows()
            Spacer(minLength: 0)
        } else {
            DSEmptyState(String(localized: "No pull request for this branch.", bundle: .module)).frame(maxHeight: .infinity)
        }
    }

    private func toolbar(_ pr: PullRequestChipModel) -> some View {
        HStack(spacing: DS.Space.s1_5) {
            Text(verbatim: pr.counts.total == 0 ? "#\(pr.number)" : PullRequestText.checksSummary(pr))
                .dsFont(DS.Font.small)
                .foregroundStyle(DS.Color.textSecondary)
                .lineLimit(1)
            Spacer(minLength: DS.Space.s1)
            DSIconButton(
                .panelRefresh, id: .rightPanelChecksRefresh, symbol: "arrow.clockwise", name: String(localized: "Refresh", bundle: .module),
                variant: .row)
        }
        .padding(.horizontal, DS.Space.s3)
        .frame(height: GitHubMetrics.headerHeight - DS.Space.s2)
        .overlay(alignment: .bottom) { DS.Color.border.frame(height: DSMetrics.hairline) }
    }

    @ViewBuilder private func group(_ title: String, _ items: [CheckItem], outcome: ChecksSummaryState) -> some View {
        if !items.isEmpty {
            GitSectionHeader(title: title, count: items.count)
            ForEach(items) { CheckRow(item: $0, compact: compact) }
        }
    }

    /// Passando fica recolhido por padrão (03 §10.3).
    @ViewBuilder private func passingGroup(_ pr: PullRequestChipModel) -> some View {
        let items = pr.passingItems
        if !items.isEmpty {
            // lint-ui: allow buttons só alterna o recolhimento local da lista (sem efeito de domínio)
            Button {
                passingOpen.toggle()
            } label: {
                HStack(spacing: DS.Space.s1) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: DS.Space.s2, weight: .medium))
                        .rotationEffect(.degrees(passingOpen ? 90 : 0))
                    GitSectionHeader(title: String(localized: "Passing", bundle: .module), count: items.count)
                }
                .padding(.leading, DS.Space.s2)
            }
            .buttonStyle(.plain)
            .accessibilityValue(Text(verbatim: passingOpen ? "expanded" : "collapsed"))
            if passingOpen { ForEach(items) { CheckRow(item: $0, compact: compact) } }
        }
    }

    @ViewBuilder private var updated: some View {
        if let at = controller.updatedAt {
            Text("Updated \(SidebarProjector.relativeTime(since: at, now: controller.clock()))", bundle: .module)
                .dsFont(DS.Font.small)
                .foregroundStyle(DS.Color.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Space.s3)
                .frame(height: GitHubMetrics.rowHeight)
                .overlay(alignment: .top) { DS.Color.border.frame(height: DSMetrics.hairline) }
        }
    }
}

private struct CheckRow: View {
    let item: CheckItem
    let compact: Bool
    @State private var hovering = false

    var body: some View {
        ActionButton(.gitOpenCheck, id: .rightPanelChecksRow(item.name), argument: .select(item.name), tooltip: item.name) {
            HStack(spacing: DS.Space.s2) {
                ChecksGlyph(outcome: item.outcome.summaryState)
                    .frame(width: GitHubMetrics.checksIcon)
                Text(verbatim: item.name)
                    .dsFont(DS.Font.tab)
                    .foregroundStyle(DS.Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: DS.Space.s1)
                if hovering, item.url != nil {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: GitHubMetrics.checksIcon))
                        .foregroundStyle(DS.Color.textTertiary)
                }
            }
            .padding(.horizontal, DS.Space.s3)
            .frame(height: GitHubMetrics.checkRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(DSListRowStyle(selected: false))
        .onHover { hovering = $0 }
    }
}
