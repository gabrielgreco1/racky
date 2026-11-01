import RackyCore
import RackyDesignSystem
import RackyProtocol
import SwiftUI

enum CloneMetrics {
    static let rowHeight: CGFloat = 44
    static let listMaxHeight: CGFloat = 264
    static let barHeight: CGFloat = 4
    static let rowIcon: CGFloat = 16
}

/// Overlay "Clone from GitHub" (03 §16.9b): campo para colar URL ou `owner/repo`, lista de repositórios recentes com busca por
/// teclado e, ao clonar, o progresso no próprio painel.
struct CloneRepoView: View {
    let model: CloneRepoModel
    let submit: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DSMetrics.overlayGap) {
            Text(verbatim: "Clone from GitHub")
                .dsFont(DS.Font.composerTitle)
                .foregroundStyle(DS.Color.textPrimary)
                .accessibilityAddTraits(.isHeader)
            switch model.phase {
            case .cloning:
                progress.overlayGroup(0)
            case .browsing, .failed:
                browser.overlayGroup(0)
            }
            footer.overlayGroup(1)
        }
        .padding(DSMetrics.overlayPadding)
    }

    // MARK: Navegação

    private var browser: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            DSTextField(
                "Paste a repository URL or owner/repo",
                text: Binding(get: { model.source }, set: { model.setSource($0) }), id: .overlayCloneRepoInput,
                action: .dialogCloneRepoSetSource, autofocus: true, compact: true, mono: false)
                .onKeyPress(.upArrow) {
                    model.move(-1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    model.move(1)
                    return .handled
                }
                .onSubmit { submit() }
            if case .failed(let message) = model.phase { failureBox(message) }
            switch model.listing {
            case .loggedOut: loginBanner
            case .ghMissing: ghMissingBanner
            case .failed(let message): note(message)
            case .loading, .ready: EmptyView()
            }
            list
        }
    }

    private var loginBanner: some View {
        HStack(spacing: DS.Space.s3) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: CloneMetrics.rowIcon))
                .foregroundStyle(DS.Color.textSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.s0_5) {
                Text("Log in to GitHub to see your repositories.", bundle: .module)
                    .dsFont(DS.Font.body)
                    .foregroundStyle(DS.Color.textPrimary)
                Text("You can still paste a public repository URL.", bundle: .module)
                    .dsFont(DS.Font.small)
                    .foregroundStyle(DS.Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DS.Space.s2)
            DSButton(.dialogCloneRepoLogIn, id: .overlayCloneRepoLogIn, "Log in to GitHub", variant: .outline, size: .sm)
        }
        .padding(DS.Space.s3)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Color.secondary))
    }

    private var ghMissingBanner: some View {
        HStack(spacing: DS.Space.s3) {
            Image(systemName: "terminal")
                .font(.system(size: CloneMetrics.rowIcon))
                .foregroundStyle(DS.Color.textSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.s0_5) {
                Text("Install the GitHub CLI to see your repositories.", bundle: .module)
                    .dsFont(DS.Font.body)
                    .foregroundStyle(DS.Color.textPrimary)
                Text("brew install gh · or paste a public repository URL.", bundle: .module)
                    .dsFont(DS.Font.small)
                    .foregroundStyle(DS.Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DS.Space.s2)
        }
        .padding(DS.Space.s3)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Color.secondary))
    }

    private func note(_ message: String) -> some View {
        Text(verbatim: message)
            .dsFont(DS.Font.small)
            .foregroundStyle(DS.Color.textTertiary)
    }

    private func failureBox(_ message: String) -> some View {
        HStack(alignment: .top, spacing: DS.Space.s2) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(DS.Color.destructive)
            Text(verbatim: message)
                .dsFont(DS.Font.body)
                .foregroundStyle(DS.Color.destructive)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DS.Space.s2)
            DSButton(.dialogCloneRepoRetry, id: .overlayCloneRepoRetry, "Try Again", variant: .outline, size: .sm)
        }
        .padding(DS.Space.s3)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Color.destructiveBackground))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Color.destructiveBorder))
        .a11y(.overlayCloneRepoError, kind: "text", label: message)
    }

    @ViewBuilder private var list: some View {
        let rows = model.rows
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            Text(verbatim: model.sectionTitle.uppercased())
                .dsFont(DS.Font.label)
                .foregroundStyle(DS.Color.textSecondary)
            if rows.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(spacing: DS.Space.s0_5) {
                            ForEach(rows) { row in
                                repoRow(row).id(row.id)
                            }
                        }
                    }
                    .scrollIndicators(.never)
                    .frame(maxHeight: CloneMetrics.listMaxHeight)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: model.selectedID) { _, id in
                        guard let id else { return }
                        proxy.scrollTo(id)
                    }
                }
            }
        }
        .a11y(.overlayCloneRepoList, kind: "list")
    }

    @ViewBuilder private var emptyState: some View {
        switch model.listing {
        case .loading:
            HStack(spacing: DS.Space.s2) {
                DSSpinner(size: DS.Space.s4, delayed: false)
                Text("Loading your repositories…", bundle: .module)
                    .dsFont(DS.Font.body)
                    .foregroundStyle(DS.Color.textTertiary)
            }
            .frame(height: CloneMetrics.rowHeight)
        default:
            Text(model.isSearching ? "No repositories match." : "No repositories yet.", bundle: .module)
                .dsFont(DS.Font.body)
                .foregroundStyle(DS.Color.textTertiary)
                .frame(height: CloneMetrics.rowHeight, alignment: .leading)
        }
    }

    private func repoRow(_ row: CloneRepoModel.Row) -> some View {
        DSListRow(.dialogCloneRepoSelect, id: .overlayCloneRepoRow(row.id), selected: model.selectedID == row.id, argument: .select(row.id)) {
            HStack(spacing: DS.Space.s3) {
                Image(systemName: icon(for: row))
                    .font(.system(size: CloneMetrics.rowIcon))
                    .foregroundStyle(DS.Color.textSecondary)
                    .frame(width: CloneMetrics.rowIcon)
                switch row.kind {
                case .typed(let reference):
                    VStack(alignment: .leading, spacing: DS.Space.s0_5) {
                        Text("Clone \(reference.displayName)", bundle: .module)
                            .dsFont(DS.Font.bodyStrong)
                            .foregroundStyle(DS.Color.textPrimary)
                            .lineLimit(1)
                        Text(verbatim: reference.cloneURL)
                            .dsFont(DS.Font.monoMicro)
                            .foregroundStyle(DS.Color.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: DS.Space.s2)
                case .repository(let repo):
                    VStack(alignment: .leading, spacing: DS.Space.s0_5) {
                        HStack(spacing: DS.Space.s1_5) {
                            Text(verbatim: repo.name)
                                .dsFont(DS.Font.bodyStrong)
                                .foregroundStyle(DS.Color.textPrimary)
                                .lineLimit(1)
                            Text(verbatim: repo.owner)
                                .dsFont(DS.Font.small)
                                .foregroundStyle(DS.Color.textTertiary)
                                .lineLimit(1)
                        }
                        Text(verbatim: detail(for: repo))
                            .dsFont(DS.Font.small)
                            .foregroundStyle(DS.Color.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: DS.Space.s2)
                    DSBadge(repo.isPrivate ? String(localized: "Private", bundle: .module) : String(localized: "Public", bundle: .module))
                }
            }
            .padding(.horizontal, DS.Space.s3)
            .frame(maxWidth: .infinity, minHeight: CloneMetrics.rowHeight, maxHeight: CloneMetrics.rowHeight, alignment: .leading)
        }
    }

    private func icon(for row: CloneRepoModel.Row) -> String {
        switch row.kind {
        case .typed: "arrow.down.circle"
        case .repository(let repo): repo.isPrivate ? "lock" : "book.closed"
        }
    }

    private func detail(for repo: GitHubRepository) -> String {
        [repo.language, model.updatedText(for: repo)].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Progresso

    private var progress: some View {
        let value = model.progress
        let fraction = CGFloat(value?.overall ?? 0)
        return VStack(alignment: .leading, spacing: DS.Space.s3) {
            HStack(spacing: DS.Space.s2) {
                DSSpinner(size: DS.Space.s4, delayed: false)
                Text("Cloning \(model.cloningName)…", bundle: .module)
                    .dsFont(DS.Font.bodyStrong)
                    .foregroundStyle(DS.Color.textPrimary)
                    .lineLimit(1)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.Color.secondary)
                    Capsule().fill(DS.Color.textPrimary)
                        .frame(width: max(CloneMetrics.barHeight, proxy.size.width * fraction))
                }
            }
            .frame(height: CloneMetrics.barHeight)
            .animation(MotionPolicy.shared.animation(MotionTokens.Easing.standard, MotionTokens.Duration.fast), value: value?.overall)
            Text(verbatim: value?.text ?? "")
                .dsFont(DS.Font.small)
                .foregroundStyle(DS.Color.textTertiary)
        }
        .padding(.vertical, DS.Space.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .a11y(.overlayCloneRepoProgress, kind: "progress", label: "Cloning \(model.cloningName)", value: value?.text ?? "")
    }

    // MARK: Rodapé

    private var footer: some View {
        HStack(spacing: DS.Space.s2) {
            Group {
                if model.isCloning {
                    Text("Esc Cancel", bundle: .module)
                } else {
                    Text("↑↓ Choose · ↵ Clone · Esc Cancel", bundle: .module)
                }
            }
            .dsFont(DS.Font.small)
            .foregroundStyle(DS.Color.textTertiary)
            Spacer(minLength: DS.Space.s2)
            DSButton(.dialogCloneRepoCancel, id: .overlayCloneRepoCancel, "Cancel", variant: .outline)
            if !model.isCloning {
                DSButton(.dialogCloneRepoSubmit, id: .overlayCloneRepoSubmit, "Clone", variant: .primary)
            }
        }
    }
}
