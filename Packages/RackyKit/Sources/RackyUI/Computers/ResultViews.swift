import RackyCore
import RackyDesignSystem
import RackyProtocol
import SwiftUI

// T3-06, 03 §11.7: a aba `Result` do detalhe do computador no painel direito. `result.json` formatado campo a campo, a marca de cada
// afirmação (AC-421: `Verified`, `Cited request not found`, `Not verified`), os links para os requests do reqlog e para os arquivos de
// `/work`, e `Reveal in Finder` / `Open Run Folder`.

enum ResultMetrics {
    static let markIcon: CGFloat = 12
    static let evidenceIndent = DS.Space.s4
    static let refWidth: CGFloat = 220
}

extension FieldStatus {
    var symbol: String {
        switch self {
        case .verified: "checkmark.circle.fill"
        case .citedMissing: "exclamationmark.triangle.fill"
        case .notVerified: "questionmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .verified: DS.Color.success
        case .citedMissing: DS.Color.warning
        case .notVerified: DS.Color.textTertiary
        }
    }
}

/// Marca de uma afirmação: ícone e rótulo na cor do estado.
struct FieldStatusMark: View {
    let status: FieldStatus
    let label: String

    var body: some View {
        HStack(spacing: DS.Space.s1) {
            Image(systemName: status.symbol).font(.system(size: ResultMetrics.markIcon)).foregroundStyle(status.tint)
            Text(verbatim: label).dsFont(DS.Font.small).foregroundStyle(status.tint).lineLimit(1)
        }
        .fixedSize()
    }
}

/// Uma citação: `Observed` / `Agent-reported` (CS-263) ou `not found`; clicar leva ao request (corpo salvo ou reqlog) ou ao arquivo.
struct EvidenceLinkRow: View {
    let computer: String
    let link: EvidenceLink

    private var trustLabel: String? {
        switch link.trust {
        case "reported": String(localized: "Agent-reported", bundle: .module)
        case "observed": String(localized: "Observed", bundle: .module)
        default: nil
        }
    }

    var body: some View {
        ActionButton(.computerOpenEvidence, id: .rightPanelComputerEvidence(computer, link.ref), argument: .select("\(computer)|\(link.ref)")) {
            HStack(spacing: DS.Space.s1_5) {
                Image(systemName: link.kind == .request ? "network" : "doc").font(.system(size: ResultMetrics.markIcon)).foregroundStyle(DS.Color.textTertiary)
                Text(verbatim: link.ref).dsFont(DS.Font.monoMicro).foregroundStyle(link.exists ? DS.Color.textSecondary : DS.Color.warning).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: ResultMetrics.refWidth, alignment: .leading)
                if !link.exists {
                    DSBadge(String(localized: "Cited request not found", bundle: .module), variant: .warning)
                } else if let trustLabel {
                    DSBadge(trustLabel, variant: .neutral)
                }
                if let summary = link.summary {
                    Text(verbatim: summary).dsFont(DS.Font.micro).foregroundStyle(DS.Color.textTertiary).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!link.exists)
    }
}

struct ResultFieldRow: View {
    let computer: String
    let field: FieldReport

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
                Text(verbatim: field.pointer).dsFont(DS.Font.monoMicro).foregroundStyle(DS.Color.textSecondary).lineLimit(1)
                Spacer(minLength: DS.Space.s2)
                FieldStatusMark(status: field.status, label: field.statusLabel)
            }
            if !field.preview.isEmpty {
                Text(verbatim: field.preview).dsFont(DS.Font.body).foregroundStyle(DS.Color.textPrimary).lineLimit(3)
            }
            ForEach(field.links) { link in
                EvidenceLinkRow(computer: computer, link: link).padding(.leading, ResultMetrics.evidenceIndent)
            }
        }
        .padding(.horizontal, DS.Space.s3)
        .padding(.vertical, DS.Space.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { DS.Color.border.frame(height: ComputersMetrics.separator) }
        .a11y(.rightPanelComputerField(computer, field.pointer), kind: "row", label: field.pointer, value: field.status.rawValue)
    }
}

/// O conteúdo da aba `Result`.
struct ComputerResultView: View {
    let name: String
    let collected: CollectedRun?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let collected {
                summary(collected)
                if collected.result == nil {
                    Text(verbatim: collected.resultNote ?? String(localized: "No result.json yet", bundle: .module))
                        .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).padding(DS.Space.s3)
                } else {
                    if collected.handwritten {
                        Text("result.json was not written by result_submit. Evidence ids were found by pattern.", bundle: .module)
                            .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).padding(.horizontal, DS.Space.s3).padding(.bottom, DS.Space.s1)
                    }
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(collected.fields) { ResultFieldRow(computer: name, field: $0) }
                        }
                    }
                }
                footer(collected)
            } else {
                Text("Loading…", bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).padding(DS.Space.s3)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func summary(_ c: CollectedRun) -> some View {
        HStack(spacing: DS.Space.s3) {
            Text(verbatim: "\(c.verified)").dsFont(DS.Font.bodyStrong).foregroundStyle(FieldStatus.verified.tint)
            Text("Verified", bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary)
            Text(verbatim: "\(c.citedMissing)").dsFont(DS.Font.bodyStrong).foregroundStyle(FieldStatus.citedMissing.tint)
            Text("Cited request not found", bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary).lineLimit(1)
            Text(verbatim: "\(c.notVerified)").dsFont(DS.Font.bodyStrong).foregroundStyle(FieldStatus.notVerified.tint)
            Text("Not verified", bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(DS.Space.s3)
        .a11y(.rightPanelComputerSummary(name), kind: "text", value: "\(c.verified)/\(c.totalFields)")
    }

    private func footer(_ c: CollectedRun) -> some View {
        HStack(spacing: DS.Space.s2) {
            Text(verbatim: c.integrity.message).dsFont(DS.Font.small)
                .foregroundStyle({ if case .tampered = c.integrity { DS.Color.destructive } else { DS.Color.textTertiary } }())
                .a11y(.rightPanelComputerIntegrity(name), kind: "text", value: c.integrity.message)
            Spacer(minLength: DS.Space.s2)
            DSButton(.computerRevealResult, id: .rightPanelComputerReveal(name), "Reveal in Finder", variant: .outline, size: .xs, argument: .select(name))
            DSButton(.computerOpenRunFolder, id: .rightPanelComputerOpenRun(name), "Open Run Folder", variant: .ghost, size: .xs, argument: .select(name))
        }
        .padding(DS.Space.s3)
        .overlay(alignment: .top) { DS.Color.border.frame(height: ComputersMetrics.separator) }
    }
}

/// Detalhe do computador no painel direito (03 §11.7): `← Back`, o segmented de abas e a aba `Result`. As abas sem dados não aparecem;
/// só `Result` existe nesta entrega.
struct ComputerDetailView: View {
    let controller: ComputersController
    let detail: ComputerDetail

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.s2) {
                ActionButton(.computerShowTab, id: .rightPanelComputerBack(detail.name), tooltip: String(localized: "Back", bundle: .module)) {
                    HStack(spacing: DS.Space.s1) {
                        Image(systemName: "chevron.left")
                        Text("Back", bundle: .module)
                    }
                    .dsFont(DS.Font.label)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DS.Color.textSecondary)
                Spacer(minLength: DS.Space.s2)
                Text(verbatim: detail.name).dsFont(DS.Font.label).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
            }
            .padding(.horizontal, DS.Space.s3)
            .padding(.vertical, DS.Space.s2)
            HStack {
                DSSegmented(
                    [.init("\(detail.name):result", "Result")], selection: "\(detail.name):\(detail.tab)", action: .computerShowTab,
                    id: .rightPanelComputerTab(detail.name, detail.tab))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.s3)
            ComputerResultView(name: detail.name, collected: controller.detailCollected)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Color.panel)
    }
}
