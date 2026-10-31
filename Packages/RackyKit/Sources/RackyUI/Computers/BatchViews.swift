import RackyCore
import RackyDesignSystem
import RackyProtocol
import SwiftUI

// T3-07, 03 §12.4: o painel do lote. Resumo, filtros, a tabela de alvos (estado, verificados, proxy, duração), o consolidado dos
// resultados e as ações `Collect All`, `Archive Batch` e exportar CSV/JSON.

enum BatchMetrics {
    static let colTarget: CGFloat = 170
    static let colState: CGFloat = 120
    static let colComputer: CGFloat = 100
    static let colVerified: CGFloat = 80
    static let colProxy: CGFloat = 110
    static let colDuration: CGFloat = 90
    static let colResult: CGFloat = 150
    static let maxResultColumns = 5
}

extension BatchChildStatus {
    var glyph: DSIndicatorGlyph {
        switch self {
        case .queued: .spinner
        case .running: .working
        case .needsYou: .needsInput
        case .blocked: .dot(DS.ColorSpec.warning)
        case .done: .done
        case .failed: .dot(DS.ColorSpec.agentFailed)
        case .stopped: .dot(DS.ColorSpec.agentInterrupted)
        }
    }

    var title: String {
        switch self {
        case .queued: String(localized: "Queued", bundle: .module)
        case .running: String(localized: "Running", bundle: .module)
        case .needsYou: String(localized: "Needs You", bundle: .module)
        case .blocked: String(localized: "Blocked", bundle: .module)
        case .done: String(localized: "Done", bundle: .module)
        case .failed: String(localized: "Failed", bundle: .module)
        case .stopped: String(localized: "Stopped", bundle: .module)
        }
    }
}

/// Chip de filtro (03 §12.4): `All` · `Needs You` · `Blocked` · `Done`.
struct BatchFilterChip: View {
    let batchID: String
    let filter: BatchSummary.Filter
    let active: Bool
    let count: Int

    private var title: LocalizedStringKey {
        switch filter {
        case .all: "All"
        case .needsYou: "Needs You"
        case .blocked: "Blocked"
        case .done: "Done"
        }
    }

    var body: some View {
        ActionButton(.batchFilter, id: .batchFilter(batchID, filter.rawValue), argument: .select(filter.rawValue)) {
            HStack(spacing: DS.Space.s1) {
                Text(title, bundle: .module).dsFont(active ? DS.Font.tabActive : DS.Font.tab)
                Text(verbatim: "\(count)").dsFont(DS.Font.microNumeric).foregroundStyle(DS.Color.textTertiary)
            }
            .foregroundStyle(active ? DS.Color.textPrimary : DS.Color.textSecondary)
            .padding(.horizontal, DS.Space.s2_5)
            .padding(.vertical, DS.Space.s1)
            .background(RoundedRectangle(cornerRadius: DS.Radius.full).fill(active ? DS.Color.accent : DS.Color.fg6))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

struct BatchChildRow: View {
    let batchID: String
    let child: BatchChild

    var body: some View {
        ActionButton(.computerShowTab, id: .batchRow(batchID, child.name), argument: .select(child.name)) {
            HStack(spacing: DS.Space.s2) {
                Text(verbatim: child.name).dsFont(DS.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                    .frame(width: BatchMetrics.colTarget, alignment: .leading)
                HStack(spacing: DS.Space.s1_5) {
                    DSAgentIndicator(child.status.glyph, size: .sm)
                    Text(verbatim: child.status.title).dsFont(DS.Font.body).foregroundStyle(DS.Color.textSecondary).lineLimit(1)
                }
                .frame(width: BatchMetrics.colState, alignment: .leading)
                cell(child.computerState.map { $0 == .inUse ? "In use" : $0.rawValue.capitalized } ?? "-", BatchMetrics.colComputer)
                cell(child.verifiedText, BatchMetrics.colVerified)
                cell(child.proxyRequests.map { "\(child.proxy) · \($0)" } ?? child.proxy, BatchMetrics.colProxy)
                cell(child.durationSeconds.map(RunCollector.duration) ?? "-", BatchMetrics.colDuration)
                if let doing = child.lastDoing, !child.status.isTerminal {
                    Text(verbatim: doing).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.s3)
            .frame(height: ComputersMetrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(DSListRowStyle())
        .a11y(.batchRow(batchID, child.name), kind: "row", label: child.name, value: child.status.rawValue)
    }

    private func cell(_ text: String, _ width: CGFloat) -> some View {
        Text(verbatim: text).dsFont(DS.Font.body).foregroundStyle(DS.Color.textSecondary).lineLimit(1).frame(width: width, alignment: .leading)
    }
}

struct BatchPageView: View {
    let controller: ComputersController
    let batchID: String

    var body: some View {
        let batch = controller.model.batch(batchID)
        VStack(spacing: 0) {
            PageHeader(verbatim: String(localized: "Batch · \(batchID)", bundle: .module)) {
                if let batch {
                    Text(verbatim: batch.headline).dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary).lineLimit(1)
                        .a11y(.batchSummary(batchID), kind: "text", value: "\(batch.finishedCount)/\(batch.total)")
                    DSButton(.batchCollectAll, id: .batchCollectAll(batchID), "Collect All", variant: .outline, size: .xs, argument: .select(batchID))
                    DSButton(.batchExportCSV, id: .batchExportCsv(batchID), "Export CSV", variant: .ghost, size: .xs, argument: .select(batchID))
                    DSButton(.batchExportJSON, id: .batchExportJson(batchID), "Export JSON", variant: .ghost, size: .xs, argument: .select(batchID))
                    DSButton(.batchArchive, id: .batchArchive(batchID), "Archive Batch", variant: .ghost, size: .xs, argument: .select(batchID))
                }
            }
            if let batch, !batch.children.isEmpty {
                filters(batch)
                tableHeader
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(batch.children(matching: controller.batchFilter)) { BatchChildRow(batchID: batchID, child: $0) }
                        if let full = controller.consolidated[batchID], !full.resultColumns.isEmpty { results(full) }
                    }
                }
            } else {
                Text("No targets yet.", bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .a11y(.batchEmpty(batchID), kind: "text")
            }
        }
        .background(DS.Color.canvas)
        .a11y(.batchPage(batchID), kind: "page")
        .task(id: batch?.finishedCount) { await controller.loadConsolidated(batchID) }
    }

    private func filters(_ batch: BatchSummary) -> some View {
        HStack(spacing: DS.Space.s1_5) {
            ForEach(BatchSummary.Filter.allCases, id: \.self) { filter in
                BatchFilterChip(batchID: batchID, filter: filter, active: controller.batchFilter == filter, count: batch.children(matching: filter).count)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.s3)
        .padding(.vertical, DS.Space.s2)
    }

    private var tableHeader: some View {
        HStack(spacing: DS.Space.s2) {
            column("Target", BatchMetrics.colTarget)
            column("Subagent", BatchMetrics.colState)
            column("Computer", BatchMetrics.colComputer)
            column("Verified", BatchMetrics.colVerified)
            column("Proxy", BatchMetrics.colProxy)
            column("Duration", BatchMetrics.colDuration)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.s3)
        .frame(height: ComputersMetrics.tableHeader)
        .overlay(alignment: .bottom) { DS.Color.border.frame(height: ComputersMetrics.separator) }
    }

    private func column(_ title: LocalizedStringKey, _ width: CGFloat) -> some View {
        Text(title, bundle: .module).dsFont(DS.Font.label).foregroundStyle(DS.Color.textSecondary).frame(width: width, alignment: .leading)
    }

    /// O consolidado (03 §12.4): uma linha por alvo com os campos de topo dos `result.json`.
    private func results(_ full: BatchSummary) -> some View {
        let columns = Array(full.resultColumns.prefix(BatchMetrics.maxResultColumns))
        return VStack(alignment: .leading, spacing: 0) {
            Text("Results", bundle: .module).dsFont(DS.Font.sectionLabel).foregroundStyle(DS.Color.textPrimary)
                .padding(.horizontal, DS.Space.s3).padding(.top, DS.Space.s4).padding(.bottom, DS.Space.s2)
            HStack(spacing: DS.Space.s2) {
                Text("Target", bundle: .module).dsFont(DS.Font.label).foregroundStyle(DS.Color.textSecondary).frame(width: BatchMetrics.colTarget, alignment: .leading)
                ForEach(columns, id: \.self) { key in
                    Text(verbatim: key).dsFont(DS.Font.label).foregroundStyle(DS.Color.textSecondary).lineLimit(1).frame(width: BatchMetrics.colResult, alignment: .leading)
                }
            }
            .padding(.horizontal, DS.Space.s3)
            .frame(height: ComputersMetrics.tableHeader)
            .overlay(alignment: .bottom) { DS.Color.border.frame(height: ComputersMetrics.separator) }
            ForEach(full.children) { child in
                HStack(spacing: DS.Space.s2) {
                    Text(verbatim: child.name).dsFont(DS.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary).lineLimit(1).frame(width: BatchMetrics.colTarget, alignment: .leading)
                    ForEach(columns, id: \.self) { key in
                        Text(verbatim: BatchSummary.flat(child.result?[key]).replacingOccurrences(of: "\n", with: " "))
                            .dsFont(DS.Font.body).foregroundStyle(DS.Color.textSecondary).lineLimit(1).truncationMode(.tail)
                            .frame(width: BatchMetrics.colResult, alignment: .leading)
                    }
                }
                .padding(.horizontal, DS.Space.s3)
                .frame(height: ComputersMetrics.rowHeight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .a11y(.batchResults(batchID), kind: "table")
    }
}

/// Linha do Inbox de "lote concluído" (07 CS-326): `Done`, título `<sessão> — <lote> finished`, corpo com as contagens; clicar abre o painel.
struct BatchDoneRowView: View {
    let item: AttentionItem
    @State private var hovering = false

    var body: some View {
        let batch = item.batchID ?? ""
        ActionButton(.batchOpen, id: .inboxItem("batch.\(batch)"), argument: .select(batch), tooltip: item.body) {
            VStack(alignment: .leading, spacing: DS.Space.s0_5) {
                HStack(spacing: DS.Space.s1_5) {
                    DSAgentIndicator(.done, size: .sm)
                    Text(verbatim: item.title).dsFont(DS.Font.body).fontWeight(.semibold).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                    Spacer(minLength: DS.Space.s1)
                }
                Text(verbatim: item.body).dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary).lineLimit(1).truncationMode(.tail)
                    .padding(.leading, DSIndicatorSize.sm.box + DS.Space.s1_5)
            }
            .padding(.horizontal, DS.Space.s2_5)
            .padding(.vertical, DS.Space.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: InboxMetrics.rowHeight)
            .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(hovering ? DS.Color.fg8 : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
