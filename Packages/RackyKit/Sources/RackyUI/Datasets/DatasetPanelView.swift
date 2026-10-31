import RackyCore
import RackyDesignSystem
import RackyProtocol
import RackyStore
import SwiftUI

/// Módulo Data do painel direito: o dataset da sessão aberta enquanto os subagentes coletam, no lugar dos Insights. Mostra se está
/// chegando, de onde, quanto está bom e as linhas mais novas com as colunas nomeadas. Abre sozinho quando os dados começam a entrar;
/// "Open table" leva para a tabela inteira numa tab da sessão e fecha a prévia (não ficam as duas).
@MainActor
final class DataModule: RightPanelModule {
    let id = PanelModuleID.data
    let title = String(localized: "Data", bundle: .module)
    let icon = "tablecells"
    let toggleAction: ActionID? = .rightPanelToggleData
    let stripButtonID: A11yID? = .tabsDataToggle
    private let datasets: DatasetsController

    init(datasets: DatasetsController) { self.datasets = datasets }

    func makeView(context: RightPanelModuleContext) -> AnyView {
        AnyView(DatasetPanelView(controller: datasets))
    }
}

enum DatasetPanelMetrics {
    static let rowHeight = DS.Space.s6 + DS.Space.s1
    static let headerRow = DS.Space.s6
    static let numberColumn: CGFloat = 64
    static let maxColumns = 3
    static let maxRows = 50
    static let stripe: CGFloat = 2
    /// Linha que chegou há menos disso fica destacada de leve.
    static let freshFor: TimeInterval = 8
}

struct DatasetPanelView: View {
    let controller: DatasetsController

    var body: some View {
        Group {
            if let summary = controller.panelSummary {
                DatasetPanelContent(controller: controller, model: controller.model(for: summary.dataset.id), summary: summary)
                    .id(summary.dataset.id)
            } else {
                VStack(spacing: DS.Space.s2) {
                    Image(systemName: "tablecells").font(.system(size: DS.Space.s6)).foregroundStyle(DS.Color.textQuaternary)
                    Text("No data in this session yet", bundle: .module).dsFont(DS.Font.label).foregroundStyle(DS.Color.textSecondary)
                    Text("Tables that subagents collect show up here as rows arrive.", bundle: .module)
                        .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).multilineTextAlignment(.center)
                }
                .padding(DS.Space.s6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .a11y(.rightPanelDataEmpty, kind: "text")
            }
        }
        .background(DS.Color.canvas)
        .a11y(.rightPanelData, kind: "container")
    }
}

private struct DatasetPanelContent: View {
    let controller: DatasetsController
    let model: DatasetViewModel
    let summary: DatasetSummary

    private var columns: [PanelColumn] {
        summary.dataset.columns.enumerated().prefix(DatasetPanelMetrics.maxColumns).map { PanelColumn(index: $0.offset, column: $0.element) }
    }

    var body: some View {
        // Tudo rola junto (com o cabeçalho da tabela preso no topo): num espaço baixo nada fica cortado.
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                header
                if let snapshot = model.snapshot {
                    numbers(snapshot)
                    Section {
                        tableRows(snapshot)
                    } header: {
                        tableHeader
                    }
                }
            }
            // Rolador sobreposto: as linhas se redesenham a cada segundo e a barra do sistema piscava ao aparecer e sumir.
            .background(OverlayScrollerConfigurator())
        }
        .scrollIndicators(.automatic, axes: .vertical)
        .onAppear { controller.noteVisible(model.id, true) }
        .onDisappear { controller.noteVisible(model.id, false) }
    }

    // MARK: Cabeçalho

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            HStack(spacing: DS.Space.s2) {
                pickerOrName
                Spacer(minLength: DS.Space.s1)
                // A tabela inteira numa tab da sessão, ou ao lado do agente (tela dividida, os dois juntos).
                DSButton(
                    .datasetOpen, id: .rightPanelDataOpen, "Open in a tab", variant: .outline, size: .xs, symbol: "arrow.up.right",
                    argument: .select("\(summary.dataset.id)|panel"))
                ActionButton(
                    .datasetOpen, id: .rightPanelDataBeside, argument: .select("\(summary.dataset.id)|beside|panel"),
                    tooltip: String(localized: "Open beside the agent", bundle: .module)
                ) { Image(systemName: "rectangle.split.2x1") }
                    .buttonStyle(DSIconButtonStyle(.header))
            }
            HStack(spacing: DS.Space.s2) {
                CollectionStatus(
                    collecting: controller.isCollecting(summary), computers: model.snapshot?.stats.computers ?? 0,
                    lastRow: model.snapshot?.stats.lastSeen.map { controller.relative($0) })
                if let source = sourceLine {
                    Text(verbatim: source).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .padding(.horizontal, DS.Space.s3)
        .padding(.top, DS.Space.s2_5)
        .padding(.bottom, DS.Space.s2)
    }

    @ViewBuilder private var pickerOrName: some View {
        let list = controller.sessionSummaries
        if list.count > 1 {
            DSCombobox(
                id: .rightPanelDataPick, selection: summary.dataset.id,
                entries: list.map { .item(DSMenuItem($0.dataset.id, controller.displayName($0), detail: $0.rowCount.formatted(), detailMono: true)) },
                action: .rightPanelDataPick, height: DSMetrics.fieldHeightComposer - DS.Space.s1)
                .fixedSize()
        } else {
            Text(verbatim: controller.displayName(summary)).dsFont(DS.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
        }
    }

    /// "books.toscrape.com · Codex 1, Codex 2": o site e quem está coletando.
    private var sourceLine: String? {
        guard let facets = model.snapshot?.facets else { return nil }
        let hosts = (facets[.source] ?? []).map(\.value).filter { !$0.isEmpty }
        let agents = (facets[.computer] ?? []).map { controller.computerLabel($0.value) ?? $0.value }
        var parts: [String] = []
        if let host = hosts.first { parts.append(hosts.count == 1 ? host : String(localized: "\(hosts.count) sites", bundle: .module)) }
        if !agents.isEmpty { parts.append(agents.joined(separator: ", ")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Números

    /// Quatro cartões compactos (2 × 2), os mesmos da página: quanto veio, ritmo, válidas e campos preenchidos.
    private func numbers(_ snapshot: DatasetPageSnapshot) -> some View {
        let s = snapshot.stats
        let valid = s.rows == 0 ? 0 : Double(s.rows - s.invalid) / Double(s.rows)
        let columns = summary.dataset.columns.map(\.name)
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: DS.Space.s2), GridItem(.flexible())], spacing: DS.Space.s2) {
            CompactTile(
                title: String(localized: "Rows collected", bundle: .module), value: s.rows.formatted(), unit: nil,
                detail: s.recent > 0 ? String(localized: "+\(s.recent.formatted()) in 5 min", bundle: .module) : nil, detailTone: DS.Color.dataValid
            ) { CumulativeLine(values: snapshot.activity.map { $0.valid + $0.invalid }) }
            CompactTile(
                title: String(localized: "Throughput", bundle: .module), value: ActivityChart.short(snapshot.perMinute),
                unit: String(localized: "rows/min", bundle: .module), detail: nil
            ) { MiniBars(values: snapshot.activity.suffix(20).map { $0.valid + $0.invalid }) }
            CompactTile(
                title: String(localized: "Valid rows", bundle: .module), value: DatasetOverviewTiles.percent(valid), unit: nil,
                detail: s.invalid > 0 ? String(localized: "\(s.invalid.formatted()) invalid", bundle: .module) : nil, detailTone: DS.Color.warning
            ) { SegmentBar(segments: [(Double(s.rows - s.invalid), DS.Color.dataValid), (Double(s.invalid), DS.Color.warning)]) }
            CompactTile(
                title: String(localized: "Fields filled", bundle: .module), value: DatasetOverviewTiles.percent(s.filled), unit: nil,
                detail: s.weakestColumn.map { "\($0.name) \(DatasetOverviewTiles.percent($0.fill))" }, detailTone: DS.Color.warning
            ) { ColumnFillBars(names: columns, fills: columns.map { s.columnFill[$0] ?? 0 }) }
        }
        .padding(.horizontal, DS.Space.s3)
        .padding(.bottom, DS.Space.s3)
        .a11y(.rightPanelDataStats, kind: "group", value: "\(s.rows)")
    }

    // MARK: Tabela

    @ViewBuilder private func tableRows(_ snapshot: DatasetPageSnapshot) -> some View {
        if snapshot.rows.isEmpty {
            Text("No rows yet.", bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.Space.s6)
        } else {
            // Um relógio só para a lista (antes era um por linha): o destaque de "acabou de chegar" some sozinho.
            let rows = Array(snapshot.rows.prefix(DatasetPanelMetrics.maxRows))
            TimelineView(.periodic(from: .now, by: 1)) { context in
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        PanelRow(row: row, columns: columns, datasetID: summary.dataset.id, now: context.date)
                    }
                }
            }
            footer(snapshot)
        }
    }

    private var tableHeader: some View {
        HStack(spacing: DS.Space.s2) {
            Color.clear.frame(width: DatasetPanelMetrics.stripe)
            ForEach(columns) { entry in
                Text(verbatim: entry.column.name).dsFont(DS.Font.micro).foregroundStyle(DS.Color.textTertiary).lineLimit(1)
                    .frame(width: entry.isFirst ? nil : DatasetPanelMetrics.numberColumn, alignment: entry.isNumeric ? .trailing : .leading)
                    .frame(maxWidth: entry.isFirst ? .infinity : nil, alignment: .leading)
            }
        }
        .padding(.horizontal, DS.Space.s3)
        .frame(height: DatasetPanelMetrics.headerRow)
        .background(DS.Color.chrome)
        .overlay(alignment: .top) { DS.Color.border.frame(height: ComputersMetrics.separator) }
        .overlay(alignment: .bottom) { DS.Color.border.frame(height: ComputersMetrics.separator) }
    }

    private func footer(_ snapshot: DatasetPageSnapshot) -> some View {
        let shown = min(snapshot.rows.count, DatasetPanelMetrics.maxRows)
        return Text(verbatim: String(localized: "Latest \(shown) of \(snapshot.stats.rows.formatted()) rows", bundle: .module))
            .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Space.s3)
            .frame(height: DatasetPanelMetrics.headerRow)
            .overlay(alignment: .top) { DS.Color.border.frame(height: ComputersMetrics.separator) }
    }
}

private struct PanelColumn: Identifiable {
    let index: Int
    let column: DatasetColumn
    var id: Int { index }
    var isFirst: Bool { index == .zero }
    var isNumeric: Bool { DatasetMetrics.isNumeric(column.type) }
}

/// Uma linha compacta: faixa de estado, a primeira coluna (texto) e as outras à direita. Linha recém-chegada fica destacada de leve
/// por alguns segundos; o clique abre a tabela inteira.
private struct PanelRow: View {
    let row: DatasetDisplayRow
    let columns: [PanelColumn]
    let datasetID: String
    let now: Date
    @State private var hovering = false

    var body: some View {
        do {
            let fresh = now.timeIntervalSince(row.row.firstSeen) < DatasetPanelMetrics.freshFor
            ActionButton(.datasetOpen, id: .rightPanelDataRow(row.id), argument: .select("\(datasetID)|panel")) {
                HStack(spacing: DS.Space.s2) {
                    RoundedRectangle(cornerRadius: DatasetPanelMetrics.stripe / 2)
                        .fill(row.row.valid ? DS.Color.dataValid.opacity(0.8) : DS.Color.warning)
                        .frame(width: DatasetPanelMetrics.stripe, height: DS.Space.s3)
                    ForEach(columns) { entry in cell(entry) }
                }
                .padding(.horizontal, DS.Space.s3)
                .frame(height: DatasetPanelMetrics.rowHeight)
                .background(fresh ? DS.Color.dataValid.opacity(0.08) : (hovering ? DS.Color.hoverAgentRow : Color.clear))
                .overlay(alignment: .bottom) { DS.Color.border.frame(height: ComputersMetrics.separator) }
                .contentShape(Rectangle())
                .animation(MotionPolicy.shared.animation(MotionTokens.Easing.ease, MotionTokens.Duration.panel), value: fresh)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
    }

    private func cell(_ entry: PanelColumn) -> some View {
        let text = entry.index < row.cells.count ? row.cells[entry.index] : ""
        let problem = entry.index < row.problems.count ? row.problems[entry.index] : nil
        return Text(verbatim: problem ?? (text.isEmpty ? "–" : GridRowText.short(text)))
            .dsFont(entry.isNumeric || problem != nil ? DS.Font.monoCell : DS.Font.cell)
            .foregroundStyle(problem != nil ? DS.Color.warning : (entry.isFirst ? DS.Color.textPrimary : DS.Color.textSecondary))
            .lineLimit(1).truncationMode(.tail)
            .frame(width: entry.isFirst ? nil : DatasetPanelMetrics.numberColumn, alignment: entry.isNumeric ? .trailing : .leading)
            .frame(maxWidth: entry.isFirst ? .infinity : nil, alignment: .leading)
    }
}

/// Cartão pequeno do painel: nome, número e o desenho embaixo.
struct CompactTile<Visual: View>: View {
    let title: String
    let value: String
    let unit: String?
    let detail: String?
    var detailTone: Color = DS.Color.textTertiary
    @ViewBuilder var visual: () -> Visual

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            Text(verbatim: title).dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s1) {
                Text(verbatim: value).dsFont(DS.Font.composerTitle).monospacedDigit().foregroundStyle(DS.Color.textPrimary)
                    .contentTransition(.numericText())
                if let unit { Text(verbatim: unit).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary) }
                Spacer(minLength: 0)
                if let detail { Text(verbatim: detail).dsFont(DS.Font.small).foregroundStyle(detailTone).lineLimit(1) }
            }
            .lineLimit(1)
            visual().frame(height: DS.Space.s4, alignment: .bottom)
        }
        .padding(DS.Space.s2_5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.md).fill(DS.Color.panel))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).strokeBorder(DS.Color.border))
        .accessibilityElement(children: .combine)
    }
}
