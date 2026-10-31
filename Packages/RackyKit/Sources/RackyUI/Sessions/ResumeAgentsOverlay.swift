import RackyCore
import RackyDesignSystem
import RackyProtocol
import Observation
import SwiftUI

/// Estado do overlay "Resume interrupted agents?" (03 §16.7): a seleção pura do Core mais o que a view precisa mostrar.
@MainActor @Observable
final class ResumeAgentsModel {
    let sessionID: UUID
    private(set) var selection: ResumeSelection
    /// Mais de uma sessão na lista: cada linha mostra a sessão. Aqui sempre uma, mas o texto de linha já a cita.
    let sessionTitle: String

    init(sessionID: UUID, sessionTitle: String, candidates: [ResumeCandidate]) {
        self.sessionID = sessionID
        self.sessionTitle = sessionTitle
        selection = ResumeSelection(candidates: candidates)
    }

    var candidates: [ResumeCandidate] { selection.candidates }
    var count: Int { selection.count }
    func isSelected(_ id: UUID) -> Bool { selection.isSelected(id) }
    func toggle(_ id: UUID) -> Bool { selection.toggle(id) }
    func selectAll() { selection.selectAll() }
    func selectNone() { selection.selectNone() }
    func markLive(_ id: UUID) { selection.update(id, live: true) }

    var liveCount: Int { candidates.filter(\.isLive).count }

    /// "3 agents stopped. Resuming uses your usage limits."
    var summary: String {
        let n = candidates.count
        return n == 1
            ? String(localized: "1 agent stopped. Resuming uses your usage limits.", bundle: .module)
            : String(localized: "\(n) agents stopped. Resuming uses your usage limits.", bundle: .module)
    }

    /// "About ~84k tokens of context to reload." Vazio sem nenhuma estimativa.
    var costLine: String? {
        let total = selection.totalTokens
        guard selection.count > 0, total > 0 else { return nil }
        let text = ResumeCost.format(tokens: total)
        return selection.unknownCostCount > 0
            ? String(localized: "Reloads at least \(text) of context.", bundle: .module)
            : String(localized: "Reloads about \(text) of context.", bundle: .module)
    }
}

enum ResumeAgentsMetrics {
    static let rowHeight: CGFloat = 44
    static let listMaxHeight: CGFloat = 308
    static let logo: CGFloat = 16
}

struct ResumeAgentsView: View {
    let model: ResumeAgentsModel

    var body: some View {
        VStack(alignment: .leading, spacing: DSMetrics.overlayGap) {
            VStack(alignment: .leading, spacing: DS.Space.s1) {
                Text("Resume interrupted agents?", bundle: .module)
                    .dsFont(DS.Font.composerTitle)
                    .foregroundStyle(DS.Color.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: model.summary)
                    .dsFont(DS.Font.dialogBody)
                    .foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let cost = model.costLine {
                    Text(verbatim: cost)
                        .dsFont(DS.Font.small)
                        .foregroundStyle(DS.Color.textTertiary)
                }
            }
            .overlayGroup(0)
            ScrollView(.vertical) {
                VStack(spacing: DS.Space.s0_5) {
                    ForEach(model.candidates) { row($0) }
                }
            }
            .scrollIndicators(.never)
            .frame(maxHeight: ResumeAgentsMetrics.listMaxHeight)
            .fixedSize(horizontal: false, vertical: true)
            .overlayGroup(1)
            footer.overlayGroup(2)
        }
        .padding(DSMetrics.overlayPadding)
    }

    private func row(_ c: ResumeCandidate) -> some View {
        DSListRow(.dialogResumeAgentsToggleRow, id: .overlayResumeRow(c.id.uuidString), argument: .select(c.id.uuidString)) {
            HStack(spacing: DS.Space.s3) {
                DSCheckboxVisual(isOn: model.isSelected(c.id))
                DSAgentLogo(c.provider, size: ResumeAgentsMetrics.logo)
                VStack(alignment: .leading, spacing: DS.Space.s0_5) {
                    HStack(spacing: DS.Space.s1_5) {
                        Text(verbatim: ProviderAdapters.adapter(for: c.provider).displayName)
                            .dsFont(DS.Font.bodyStrong)
                            .foregroundStyle(DS.Color.textPrimary)
                        Text(verbatim: c.sessionTitle)
                            .dsFont(DS.Font.small)
                            .foregroundStyle(DS.Color.textTertiary)
                            .lineLimit(1)
                    }
                    Text(verbatim: c.isLive ? String(localized: "Open in another terminal", bundle: .module) : (c.lastMessage ?? ""))
                        .dsFont(DS.Font.small)
                        .foregroundStyle(c.isLive ? DS.Color.warning : DS.Color.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: DS.Space.s2)
                VStack(alignment: .trailing, spacing: DS.Space.s0_5) {
                    if let model = c.model, !model.isEmpty {
                        Text(verbatim: model).dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary).lineLimit(1)
                    }
                    if let tokens = c.estimatedTokens {
                        Text(verbatim: ResumeCost.format(tokens: tokens)).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                    }
                }
            }
            .padding(.horizontal, DS.Space.s3)
            .frame(maxWidth: .infinity, minHeight: ResumeAgentsMetrics.rowHeight, maxHeight: ResumeAgentsMetrics.rowHeight, alignment: .leading)
            .opacity(c.isLive ? 0.6 : 1)
        }
        .disabled(c.isLive)
    }

    private var footer: some View {
        HStack(spacing: DS.Space.s2) {
            DSButton(.dialogResumeAgentsSelectAll, id: .overlayResumeSelectAll, "Select All", variant: .ghost, size: .sm)
            DSButton(.dialogResumeAgentsSelectNone, id: .overlayResumeSelectNone, "Select None", variant: .ghost, size: .sm)
            Spacer(minLength: DS.Space.s2)
            DSButton(.dialogResumeAgentsCancel, id: .overlayResumeCancel, "Not Now", variant: .outline)
            DSButton(.dialogResumeAgentsConfirm, id: .overlayResumeConfirm, "Resume \(model.count)", variant: .primary)
                .disabled(model.count == 0)
        }
    }
}
