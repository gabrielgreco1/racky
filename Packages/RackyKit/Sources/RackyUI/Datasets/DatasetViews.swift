import RackyCore
import RackyDesignSystem
import RackyProtocol
import RackyStore
import SwiftUI

// Datasets: a lista (03 §12.5) e a página de um dataset no tom do editor de tabelas do Supabase com o Log Explorer do Datadog:
// números no topo, barra de consulta com período, gráfico de volume, facetas com contagem à esquerda, grade densa e o painel da linha
// com abas. Tudo passa pelo `DatasetsController`; os controles são `ActionButton`/`DSButton` do registro de ações.

enum DatasetMetrics {
    static let notebookLogo: CGFloat = 14
    static let badgeHeight: CGFloat = 26
    static let topBar: CGFloat = 60
    static let queryBar = DS.Space.s10 + DS.Space.s1_5
    static let chartHeight: CGFloat = 92
    static let chartBarGap: CGFloat = 3
    static let legendSwatch = DS.Space.s2
    static let headerHeight = DS.Space.s8 + DS.Space.s0_5
    static let rowHeight = DS.Space.s8
    static let footerHeight = DS.Space.s8 + DS.Space.s0_5
    static let listRowHeight = DS.Space.s10 + DS.Space.s1
    static let cellPadding = DS.Space.s2_5
    static let statGap = DS.Space.s4 + DS.Space.s1
    static let checkColumn: CGFloat = 36
    static let stripeColumn: CGFloat = 26
    static let stripeHeight: CGFloat = 16
    static let stripeWidth: CGFloat = 3
    static let checkbox: CGFloat = 13
    static let facetWidth: CGFloat = 212
    static let facetRow = DS.Space.s6
    static let facetDot: CGFloat = 7
    static let liveDot: CGFloat = 6
    static let iconTile = DS.Space.s6
    static let colName: CGFloat = 220
    static let colSession: CGFloat = 160
    static let colCount: CGFloat = 90
    static let colString: CGFloat = 200
    static let colURL: CGFloat = 300
    static let colNumber: CGFloat = 104
    static let colBoolean: CGFloat = 80
    static let colDate: CGFloat = 116
    static let colDateTime: CGFloat = 176
    static let colJSON: CGFloat = 220
    static let colCaptured: CGFloat = 132
    static let panelWidth: CGFloat = 330
    static let facetsMinWidth: CGFloat = 820
    static let panelInlineMinWidth: CGFloat = 1040
    static let sessionNameMinWidth: CGFloat = 900
    static let buttonLabelsMinWidth: CGFloat = 720
    static let panelLabel: CGFloat = 92
    static let tabUnderline: CGFloat = 2

    static func width(_ type: DatasetColumnType, first: Bool) -> CGFloat {
        switch type {
        case .string: first ? colName : colString
        case .url: colURL
        case .integer, .number: colNumber
        case .boolean: colBoolean
        case .date: colDate
        case .datetime: colDateTime
        case .json: colJSON
        }
    }

    static func isNumeric(_ type: DatasetColumnType) -> Bool { type == .integer || type == .number }
    static func isMono(_ type: DatasetColumnType) -> Bool { type != .string }

    /// Nome do tipo no cabeçalho, no estilo do Supabase.
    static func typeLabel(_ type: DatasetColumnType) -> String {
        switch type {
        case .string: "text"
        case .integer: "int"
        case .number: "numeric"
        case .boolean: "bool"
        case .date: "date"
        case .datetime: "timestamp"
        case .url: "url"
        case .json: "json"
        }
    }
}

// MARK: Peças

/// "● Collecting" numa pílula verde enquanto algum computador da sessão roda.
private struct CollectingPill: View {
    var body: some View {
        HStack(spacing: DS.Space.s1_5) {
            Circle().fill(DS.Color.dataValid).frame(width: DatasetMetrics.liveDot, height: DatasetMetrics.liveDot)
            Text("Collecting", bundle: .module).dsFont(DS.Font.label).foregroundStyle(DS.Color.dataValid)
        }
        .padding(.horizontal, DS.Space.s2)
        .padding(.vertical, DS.Space.s0_5)
        .background(RoundedRectangle(cornerRadius: DS.Radius.sm).fill(DS.Color.dataValid.opacity(0.12)))
        .fixedSize()
    }
}

/// Número em mono com o rótulo pequeno embaixo (topo da página).
private struct StatView: View {
    let value: String
    let label: String
    var tone: Color = DS.Color.textPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: .zero) {
            Text(verbatim: value).dsFont(DS.Font.monoCell).foregroundStyle(tone)
            Text(verbatim: label).dsFont(DS.Font.micro).foregroundStyle(DS.Color.textTertiary)
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// Botão que abre um menu do design system cujos itens levam a própria ação (marcar várias colunas, escolher formato ou período).
struct MenuButton<Label: View>: View {
    let id: A11yID
    let action: ActionID
    let entries: [DSMenuEntry]
    var primary = false
    @ViewBuilder let label: () -> Label
    @State private var anchor: CGRect = .zero
    @State private var hovering = false
    @Environment(\.overlayRouter) private var router
    @Environment(\.actionRegistry) private var registry

    var body: some View {
        // lint-ui: allow buttons abre o popover do menu (apresentação); cada item dispara a ação do registro
        Button { open() } label: {
            HStack(spacing: DS.Space.s1_5) { label() }
                .dsFont(DS.Font.label)
                .foregroundStyle(primary ? DS.Color.textOnPrimary : DS.Color.textPrimary)
                .padding(.horizontal, DS.Space.s2_5)
                .frame(height: DSMetrics.fieldHeightComposer - DS.Space.s1)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.control)
                        .fill(primary ? DS.Color.primary.opacity(hovering ? 0.9 : 1) : (hovering ? DS.Color.secondary : DS.Color.chrome)))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(primary ? Color.clear : DS.Color.borderStrong))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { anchor = $0 }
        .fixedSize()
        .a11y(id, kind: "menu", label: action.spec.label, action: action)
    }

    private func open() {
        guard let router else { return }
        router.presentPopover(
            DSMenuPanel.spec(
                name: id.rawValue, anchor: anchor, width: max(anchor.width, DS.Layout.menuMinWidth), entries: entries, selectedID: nil,
                searchable: false, searchPlaceholder: "", registry: registry))
    }
}

/// Barra de cima das páginas de dataset: conteúdo e o fechar da página (mesmo canto do `PageHeader`).
private struct DatasetBar<Content: View>: View {
    /// Num pane, o X fecha só o pane; na página, fecha a página.
    var closePane: (() -> Void)?
    @ViewBuilder let content: () -> Content
    @Environment(\.pageTrailingInset) private var trailingInset

    var body: some View {
        HStack(spacing: DS.Space.s3) {
            content()
            if let closePane {
                // lint-ui: allow buttons fecha o pane do dataset (layout do workspace, sem ação de registro própria)
                Button(action: closePane) { Image(systemName: "xmark") }
                    .buttonStyle(DSIconButtonStyle(.header))
                    .dsTooltip(String(localized: "Close", bundle: .module), shortcut: nil)
            } else {
                ActionButton(.pageClose, tooltip: String(localized: "Close", bundle: .module)) { Image(systemName: "xmark") }
                    .buttonStyle(DSIconButtonStyle(.header))
            }
        }
        .padding(.leading, DS.Space.s4)
        .padding(.trailing, DS.Space.s3 + trailingInset)
        .frame(height: DatasetMetrics.topBar)
        .background(DS.Color.chrome)
        .overlay(alignment: .bottom) { DS.Color.border.frame(height: ComputersMetrics.separator) }
    }
}

private struct TableIcon: View {
    var body: some View {
        Image(systemName: "tablecells").font(.system(size: DS.Space.s3)).foregroundStyle(DS.Color.textSecondary)
            .frame(width: DatasetMetrics.iconTile, height: DatasetMetrics.iconTile)
            .background(RoundedRectangle(cornerRadius: DS.Radius.sm).fill(DS.Color.secondary))
    }
}

// MARK: Lista

struct DatasetsPageView: View {
    let controller: DatasetsController

    var body: some View {
        let summaries = controller.summaries
        VStack(spacing: 0) {
            DatasetBar {
                Text("Datasets", bundle: .module).dsFont(DS.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary)
                if !summaries.isEmpty {
                    StatView(value: summaries.count.formatted(), label: summaries.count == 1 ? String(localized: "Dataset", bundle: .module).lowercased() : String(localized: "Datasets", bundle: .module).lowercased())
                        .padding(.leading, DS.Space.s2)
                    StatView(value: summaries.reduce(0) { $0 + $1.rowCount }.formatted(), label: String(localized: "Rows", bundle: .module).lowercased())
                }
                Spacer(minLength: 0)
            }
            if summaries.isEmpty {
                VStack(spacing: DS.Space.s1_5) {
                    TableIcon()
                    Text("No datasets yet", bundle: .module).dsFont(DS.Font.bodyStrong).foregroundStyle(DS.Color.textSecondary).padding(.top, DS.Space.s2)
                    Text("Subagents create them when they collect tables of data.", bundle: .module)
                        .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .a11y(.datasetsEmpty, kind: "text")
            } else {
                header
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(summaries) { summary in
                            ActionButton(.datasetOpen, id: .datasetsRow(summary.dataset.id), argument: .select(summary.dataset.id)) {
                                HoverRow { row(summary) }
                            }
                            .buttonStyle(.plain)
                            .a11y(.datasetsRow(summary.dataset.id), kind: "row", label: summary.dataset.name, value: "\(summary.rowCount)")
                        }
                    }
                }
            }
        }
        .background(DS.Color.canvas)
        .a11y(.datasetsPage, kind: "page")
        .task { await controller.reloadList() }
    }

    static func summaryText(_ summaries: [DatasetSummary]) -> String {
        let rows = summaries.reduce(0) { $0 + $1.rowCount }
        let datasets = summaries.count == 1 ? String(localized: "1 dataset", bundle: .module) : String(localized: "\(summaries.count) datasets", bundle: .module)
        let count = rows == 1 ? String(localized: "1 row", bundle: .module) : String(localized: "\(rows.formatted()) rows", bundle: .module)
        return "\(datasets) · \(count)"
    }

    private var header: some View {
        HStack(spacing: 0) {
            column("Name", width: nil)
            column("Session", width: DatasetMetrics.colSession)
            column("Rows", width: DatasetMetrics.colCount, trailing: true)
            column("Invalid", width: DatasetMetrics.colCount, trailing: true)
            column("Updated", width: DatasetMetrics.colSession)
        }
        .padding(.horizontal, DS.Space.s1_5)
        .frame(height: DatasetMetrics.headerHeight)
        .overlay(alignment: .bottom) { DS.Color.borderStrong.frame(height: ComputersMetrics.separator) }
    }

    private func column(_ title: LocalizedStringKey, width: CGFloat?, trailing: Bool = false) -> some View {
        Text(title, bundle: .module).dsFont(DS.Font.label).foregroundStyle(DS.Color.textSecondary).lineLimit(1)
            .padding(.horizontal, DatasetMetrics.cellPadding)
            .frame(maxWidth: width ?? .infinity, alignment: trailing ? .trailing : .leading)
            .frame(width: width)
    }

    private func row(_ summary: DatasetSummary) -> some View {
        let collecting = controller.isCollecting(summary)
        return HStack(spacing: 0) {
            HStack(spacing: DS.Space.s2_5) {
                TableIcon()
                VStack(alignment: .leading, spacing: .zero) {
                    Text(verbatim: summary.dataset.name).dsFont(DS.Font.cell).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                    Text(verbatim: summary.dataset.columns.map(\.name).joined(separator: " · "))
                        .dsFont(DS.Font.monoMicro).foregroundStyle(DS.Color.textTertiary).lineLimit(1)
                }
            }
            .padding(.horizontal, DatasetMetrics.cellPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: controller.title(of: summary)).dsFont(DS.Font.cell).foregroundStyle(DS.Color.textSecondary).lineLimit(1)
                .padding(.horizontal, DatasetMetrics.cellPadding)
                .frame(width: DatasetMetrics.colSession, alignment: .leading)
            number(summary.rowCount, dim: summary.rowCount == 0)
            number(summary.invalidCount, warn: summary.invalidCount > 0, dim: summary.invalidCount == 0)
            Group {
                if collecting {
                    CollectingPill()
                } else {
                    Text(verbatim: controller.relative(summary.dataset.updatedAt)).dsFont(DS.Font.monoCell).foregroundStyle(DS.Color.textTertiary).lineLimit(1)
                }
            }
            .padding(.horizontal, DatasetMetrics.cellPadding)
            .frame(width: DatasetMetrics.colSession, alignment: .leading)
        }
        .padding(.horizontal, DS.Space.s1_5)
        .frame(height: DatasetMetrics.listRowHeight)
        .overlay(alignment: .bottom) { DS.Color.border.frame(height: ComputersMetrics.separator) }
        .contentShape(Rectangle())
    }

    private func number(_ value: Int, warn: Bool = false, dim: Bool = false) -> some View {
        Text(verbatim: value.formatted()).dsFont(DS.Font.monoCell)
            .foregroundStyle(warn ? DS.Color.warning : (dim ? DS.Color.textTertiary : DS.Color.textPrimary)).lineLimit(1)
            .padding(.horizontal, DatasetMetrics.cellPadding)
            .frame(width: DatasetMetrics.colCount, alignment: .trailing)
    }
}

/// Linha clicável com o fundo de hover da grade.
private struct HoverRow<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        content()
            .background(hovering ? DS.Color.hoverRow : Color.clear)
            .onHover { hovering = $0 }
    }
}

// MARK: Dataset

struct DatasetPageView: View {
    let controller: DatasetsController
    @Bindable var model: DatasetViewModel
    @State private var moreColumns = false
    /// Pane que mostra a tabela (`nil` = página do centro): o título arrasta o pane e o X fecha só ele.
    var paneID: UUID?
    var drag: PaneDragController?
    /// Na área Data a barra de localização faz o papel do título: a página não desenha a própria barra.
    var showsBar = true

    /// Página do centro: o dataset ativo.
    init(controller: DatasetsController) {
        self.controller = controller
        self.model = controller.active ?? controller.model(for: "")
    }

    /// Com a área Data por perto, o pane usa a mesma barra de lugar e o mesmo caminho do dado que ela.
    var hub: DataHubController?

    init(controller: DatasetsController, model: DatasetViewModel, paneID: UUID?, drag: PaneDragController?, showsBar: Bool = true, hub: DataHubController? = nil) {
        self.controller = controller
        self.model = model
        self.paneID = paneID
        self.drag = drag
        self.showsBar = showsBar
        self.hub = hub
    }

    var body: some View {
        let snapshot = model.snapshot
        GeometryReader { proxy in
            let width = proxy.size.width
            VStack(spacing: 0) {
                if let hub {
                    // Com a área Data: barra do lugar, o caminho numa linha e as abas; "Data" (a grade) ocupa a tela.
                    if showsBar {
                        DataLocationBar(
                            hub: hub, object: .dataset(model.id), close: paneID.map { id in { controller.closePane(id) } },
                            drag: paneID.flatMap { id in drag.map { (id, $0) } }, besideAgent: paneID.map { controller.paneIsAlone($0) })
                    }
                    // O caminho do dado fica na aba "Who writes here" (e no Overview): a barra de cima é só lugar, nome e ações.
                    let object = DataObject.dataset(model.id)
                    DataTabsBar(hub: hub, object: object)
                    let open = hub.tableTab(object)
                    if open != .data {
                        DataInlinePanel(
                            hub: hub, object: object, available: proxy.size.height,
                            natural: open == .structure ? DataInlinePanel<EmptyView>.gridHeight(rows: (snapshot?.summary.dataset.columns.count ?? 0) + 1) : nil
                        ) {
                            switch open {
                            case .overview: DataOverviewView(hub: hub, object: object)
                            case .structure:
                                if let dataset = snapshot?.summary.dataset { DataColumnsView(dataset: dataset) } else { Spacer(minLength: 0) }
                            case .writers: DataWritersView(hub: hub, object: object)
                            case .data: EmptyView()
                            }
                        }
                    }
                    dataTab(snapshot, width: width)
                } else {
                    if showsBar { topBar(snapshot, width: width) }
                    if let snapshot {
                        DatasetOverviewTiles(snapshot: snapshot, controller: controller)
                        ActivityChart(snapshot: snapshot, controller: controller, rangeMenu: AnyView(rangeMenu))
                    }
                    dataTab(snapshot, width: width)
                }
            }
            // Presa no topo: num pane baixo o que sobra corta embaixo (a grade), nunca a barra com o nome e o lápis em cima.
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .clipped()
        }
        .background(DS.Color.canvas)
        .contentShape(Rectangle())
        .onHover { if $0 { controller.activate(model.id) } }
        .onAppear {
            controller.activate(model.id)
            controller.noteVisible(model.id, true)
        }
        .onDisappear { controller.noteVisible(model.id, false) }
        .a11y(.datasetPage, kind: "page")
    }

    /// A aba dos dados: filtro (com o período) e a grade com as facetas e o painel da linha.
    @ViewBuilder
    private func dataTab(_ snapshot: DatasetPageSnapshot?, width: CGFloat) -> some View {
                if let snapshot {
                    DatasetFilterBar(snapshot: snapshot, controller: controller, model: model, trailing: hub == nil ? nil : AnyView(rangeMenu))
                    ZStack(alignment: .trailing) {
                        HStack(spacing: 0) {
                            if width >= DatasetMetrics.facetsMinWidth { FacetsPanel(snapshot: snapshot, controller: controller, model: model) }
                            grid(snapshot)
                            if let selected = model.selectedRow, width >= DatasetMetrics.panelInlineMinWidth {
                                RowPanel(row: selected, columns: snapshot.summary.dataset.columns, controller: controller, model: model)
                            }
                        }
                        // Estreito: o painel da linha fica por cima da grade, com sombra, em vez de espremer as colunas.
                        if let selected = model.selectedRow, width < DatasetMetrics.panelInlineMinWidth {
                            RowPanel(row: selected, columns: snapshot.summary.dataset.columns, controller: controller, model: model)
                                .shadow(color: .black.opacity(0.35), radius: DS.Space.s4)
                        }
                    }
                } else {
                    Spacer(minLength: 0)
                }
    }

    // MARK: Topo

    private func topBar(_ snapshot: DatasetPageSnapshot?, width: CGFloat) -> some View {
        DatasetBar(closePane: paneID.map { id in { controller.closePane(id) } }) {
            HStack(spacing: DS.Space.s3) {
                TableIcon()
                VStack(alignment: .leading, spacing: .zero) {
                    HStack(spacing: DS.Space.s2) {
                        Text(verbatim: snapshot?.summary.dataset.name ?? "").dsFont(DS.Font.composerTitle).foregroundStyle(DS.Color.textPrimary)
                        if let snapshot {
                            CollectionStatus(
                                collecting: controller.isCollecting(snapshot.summary), computers: snapshot.stats.computers,
                                lastRow: snapshot.stats.lastSeen.map { controller.relative($0) })
                        }
                    }
                    if let snapshot { Text(verbatim: subtitle(snapshot)).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary) }
                }
                .lineLimit(1)
            }
            // O título é a alça do pane: arrastar leva a tabela para outro lado, outra tab ou uma tab própria (como o cabeçalho
            // dos terminais).
            .overlay {
                if let paneID, let drag {
                    PaneDragSource(controller: drag, payload: .otherPane(paneID), title: { snapshot?.summary.dataset.name ?? "" })
                }
            }
            .layoutPriority(1)
            Spacer(minLength: DS.Space.s2)
            if snapshot != nil {
                ActionButton(
                    .datasetOpen, argument: .select("\(model.id)|beside"), tooltip: String(localized: "Open beside the agent", bundle: .module)
                ) { Image(systemName: "rectangle.split.2x1") }
                    .buttonStyle(DSIconButtonStyle(.header))
                DatasetToolbar(model: model, labels: width >= DatasetMetrics.buttonLabelsMinWidth, inSession: paneID != nil)
            }
        }
    }

    /// "Teste dos subagentes · 4 columns · key url · created 5h ago".
    private func subtitle(_ snapshot: DatasetPageSnapshot) -> String {
        let dataset = snapshot.summary.dataset
        var parts = [controller.title(of: snapshot.summary)]
        parts.append(dataset.columns.count == 1 ? String(localized: "1 column", bundle: .module) : String(localized: "\(dataset.columns.count) columns", bundle: .module))
        if !dataset.key.isEmpty { parts.append(String(localized: "key \(dataset.key.joined(separator: ", "))", bundle: .module)) }
        parts.append(String(localized: "created \(controller.relative(dataset.createdAt))", bundle: .module))
        return parts.joined(separator: " · ")
    }

    // MARK: Consulta

    private var rangeMenu: some View {
        MenuButton(id: .datasetRange, action: .datasetRange, entries: rangeEntries) {
            Image(systemName: "clock").font(.system(size: DS.Space.s2_5 + 1)).foregroundStyle(DS.Color.textTertiary)
            Text(verbatim: Self.rangeTitle(model.range))
            Image(systemName: "chevron.down").font(.system(size: DS.Space.s2)).foregroundStyle(DS.Color.textTertiary)
        }
    }

    private var rangeEntries: [DSMenuEntry] {
        DatasetRange.allCases.map { range in
            .item(DSMenuItem(range.rawValue, Self.rangeTitle(range), checked: model.range == range, action: .datasetRange, argument: .select(range.rawValue)))
        }
    }

    static func rangeTitle(_ range: DatasetRange) -> String {
        switch range {
        case .minutes15: String(localized: "Last 15 minutes", bundle: .module)
        case .hour: String(localized: "Last 1 hour", bundle: .module)
        case .hours6: String(localized: "Last 6 hours", bundle: .module)
        case .day: String(localized: "Last 24 hours", bundle: .module)
        case .week: String(localized: "Last 7 days", bundle: .module)
        case .all: String(localized: "All time", bundle: .module)
        }
    }

    // MARK: Grade

    private func grid(_ snapshot: DatasetPageSnapshot) -> some View {
        let columns = model.visibleColumns
        let all = snapshot.summary.dataset.columns
        return VStack(spacing: 0) {
            GeometryReader { viewport in
                ScrollView(.horizontal) {
                    VStack(spacing: 0) {
                        gridHeader(columns, key: snapshot.summary.dataset.key)
                        if snapshot.rows.isEmpty {
                            Text(emptyMessage(snapshot), bundle: .module)
                                .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .a11y(.datasetEmpty, kind: "text")
                        } else {
                            ScrollView {
                                LazyVStack(spacing: 0) {
                                    ForEach(snapshot.rows) { row in
                                        ActionButton(.datasetSelectRow, id: .datasetRow(row.id), argument: .select(row.id)) {
                                            GridRow(
                                                row: row, columns: columns, allColumns: all, selected: model.selectedRowKey == row.id,
                                                captured: controller.clock(row.row.firstSeen))
                                        }
                                        .buttonStyle(.plain)
                                        .a11y(.datasetRow(row.id), kind: "row", label: row.cells.first ?? "", value: row.row.valid ? "valid" : "invalid")
                                    }
                                }
                            }
                        }
                    }
                    // Largura fixa (a soma das colunas, ou a da tela se for maior): dentro do scroll horizontal a largura proposta
                    // era infinita e o LazyVStack media todas as linhas a cada mudança (o hover de uma linha refazia a grade
                    // inteira; era o lag de mexer o mouse sobre uma tabela grande). Com largura conhecida só as visíveis entram.
                    .frame(width: max(viewport.size.width, Self.gridWidth(columns)), height: viewport.size.height, alignment: .top)
                }
                .moreColumnsCue($moreColumns)
            }
            footer(snapshot)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .a11y(.datasetTable, kind: "table")
    }

    /// Largura natural da grade: seleção, faixa de estado, cada coluna e a hora de captura.
    static func gridWidth(_ columns: [DatasetColumn]) -> CGFloat {
        let cells = columns.enumerated().reduce(CGFloat.zero) { $0 + DatasetMetrics.width($1.element.type, first: $1.offset == 0) }
        return DatasetMetrics.checkColumn + DatasetMetrics.stripeColumn + cells + DatasetMetrics.colCaptured
    }

    private func emptyMessage(_ snapshot: DatasetPageSnapshot) -> LocalizedStringKey {
        if snapshot.stats.rows == 0 { return "No rows yet. They appear here as the subagents append them." }
        return "No rows match."
    }

    private func gridHeader(_ columns: [DatasetColumn], key: [String]) -> some View {
        HStack(spacing: 0) {
            CheckSquare(on: false).frame(width: DatasetMetrics.checkColumn)
            Color.clear.frame(width: DatasetMetrics.stripeColumn)
                .overlay(alignment: .trailing) { DS.Color.border.frame(width: ComputersMetrics.separator) }
            ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                let numeric = DatasetMetrics.isNumeric(column.type)
                HStack(spacing: DS.Space.s1_5) {
                    Text(verbatim: column.name).dsFont(DS.Font.label).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                    Text(verbatim: DatasetMetrics.typeLabel(column.type)).dsFont(DS.Font.monoMicro).foregroundStyle(DS.Color.textTertiary)
                    if key.contains(column.name) {
                        Text("KEY", bundle: .module).dsFont(DS.Font.monoMicro).foregroundStyle(DS.Color.warning)
                    }
                }
                .padding(.horizontal, DatasetMetrics.cellPadding)
                .frame(width: DatasetMetrics.width(column.type, first: index == .zero), alignment: numeric ? .trailing : .leading)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .trailing) { DS.Color.border.frame(width: ComputersMetrics.separator) }
            }
            HStack(spacing: DS.Space.s1_5) {
                Text("Captured", bundle: .module).textCase(.lowercase).dsFont(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
                Text(verbatim: "time").dsFont(DS.Font.monoMicro).foregroundStyle(DS.Color.textTertiary)
            }
            .padding(.horizontal, DatasetMetrics.cellPadding)
            .frame(width: DatasetMetrics.colCaptured, alignment: .leading)
            Spacer(minLength: 0)
        }
        .frame(height: DatasetMetrics.headerHeight)
        .background(DS.Color.chrome)
        .overlay(alignment: .bottom) { DS.Color.borderStrong.frame(height: ComputersMetrics.separator) }
    }

    private func footer(_ snapshot: DatasetPageSnapshot) -> some View {
        HStack(spacing: DS.Space.s2) {
            pageButton("chevron.left", id: .datasetPagePrev, argument: "prev", enabled: model.page > 0)
            pageButton("chevron.right", id: .datasetPageNext, argument: "next", enabled: model.page + 1 < model.pageCount)
            Text(verbatim: String(localized: "Page \(model.page + 1) of \(model.pageCount)", bundle: .module))
                .dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary)
                .lineLimit(1).fixedSize()
                .padding(.leading, DS.Space.s1)
            Text(verbatim: "·").dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
            Text(verbatim: snapshot.matching == 1 ? String(localized: "1 record", bundle: .module)
                 : String(localized: "\(snapshot.matching.formatted()) records", bundle: .module))
                .dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary)
                .lineLimit(1).fixedSize()
            Spacer(minLength: DS.Space.s2)
            if moreColumns { MoreColumnsNote() }
            Text(verbatim: footerDetail(snapshot)).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).lineLimit(1)
        }
        .padding(.horizontal, DS.Space.s3)
        .frame(height: DatasetMetrics.footerHeight)
        .background(DS.Color.chrome)
        .overlay(alignment: .top) { DS.Color.border.frame(height: ComputersMetrics.separator) }
    }

    private func pageButton(_ symbol: String, id: A11yID, argument: String, enabled: Bool) -> some View {
        ActionButton(.datasetPage, id: id, argument: .select(argument)) {
            Image(systemName: symbol).font(.system(size: DS.Space.s2_5, weight: .semibold))
                .foregroundStyle(enabled ? DS.Color.textSecondary : DS.Color.textQuaternary)
                .frame(width: DS.Space.s6, height: DS.Space.s6)
                .background(RoundedRectangle(cornerRadius: DS.Radius.sm).strokeBorder(DS.Color.borderStrong))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func footerDetail(_ snapshot: DatasetPageSnapshot) -> String {
        var parts: [String] = []
        let key = snapshot.summary.dataset.key
        if !key.isEmpty { parts.append(String(localized: "Key: \(key.joined(separator: ", "))", bundle: .module)) }
        if snapshot.stats.duplicatesMerged > 0 {
            parts.append(String(localized: "duplicates merged: \(snapshot.stats.duplicatesMerged.formatted())", bundle: .module))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: Linha da grade

/// Uma linha: caixa de seleção, faixa de estado (verde válida, âmbar inválida), células (números em mono à direita, URL em mono,
/// NULL visível, erro como etiqueta âmbar) e a hora de captura.
private struct GridRow: View {
    let row: DatasetDisplayRow
    let columns: [DatasetColumn]
    let allColumns: [DatasetColumn]
    let selected: Bool
    let captured: String
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            CheckSquare(on: selected, tint: DS.Color.dataKey).frame(width: DatasetMetrics.checkColumn)
            RoundedRectangle(cornerRadius: DatasetMetrics.stripeWidth / 2)
                .fill(row.row.valid ? DS.Color.dataValid.opacity(0.8) : DS.Color.warning)
                .frame(width: DatasetMetrics.stripeWidth, height: DatasetMetrics.stripeHeight)
                .frame(width: DatasetMetrics.stripeColumn, height: DatasetMetrics.rowHeight)
                .overlay(alignment: .trailing) { DS.Color.border.frame(width: ComputersMetrics.separator) }
            ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                cell(column: column, first: index == .zero)
            }
            Text(verbatim: captured).dsFont(DS.Font.monoCell).foregroundStyle(DS.Color.textTertiary).lineLimit(1)
                .padding(.horizontal, DatasetMetrics.cellPadding)
                .frame(width: DatasetMetrics.colCaptured, alignment: .leading)
            Spacer(minLength: 0)
        }
        .frame(height: DatasetMetrics.rowHeight)
        .background(selected ? DS.Color.dataKey.opacity(0.08) : (hovering ? DS.Color.hoverRow : Color.clear))
        .overlay(alignment: .bottom) { DS.Color.border.frame(height: ComputersMetrics.separator) }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    @ViewBuilder private func cell(column: DatasetColumn, first: Bool) -> some View {
        let index = allColumns.firstIndex { $0.name == column.name } ?? 0
        let text = index < row.cells.count ? row.cells[index] : ""
        let problem = index < row.problems.count ? row.problems[index] : nil
        let numeric = DatasetMetrics.isNumeric(column.type)
        Group {
            if let problem {
                Text(verbatim: problem).dsFont(DS.Font.monoMicro).foregroundStyle(DS.Color.warning)
                    .padding(.horizontal, DS.Space.s1_5)
                    .padding(.vertical, DS.Space.s0_5)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.xs + 1).fill(DS.Color.warningBackground))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.xs + 1).strokeBorder(DS.Color.warningBorder))
            } else if text.isEmpty {
                Text(verbatim: "NULL").dsFont(DS.Font.monoMicro).foregroundStyle(DS.Color.textQuaternary)
            } else {
                Text(verbatim: column.type == .url ? GridRowText.short(text) : text)
                    .dsFont(DatasetMetrics.isMono(column.type) ? DS.Font.monoCell : DS.Font.cell)
                    .foregroundStyle(column.type == .url ? DS.Color.textSecondary : DS.Color.textPrimary)
            }
        }
        .lineLimit(1).truncationMode(.tail)
        .padding(.horizontal, DatasetMetrics.cellPadding)
        .frame(width: DatasetMetrics.width(column.type, first: first), alignment: numeric ? .trailing : .leading)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .trailing) { DS.Color.border.frame(width: ComputersMetrics.separator) }
    }
}

// MARK: Painel da linha

/// Painel à direita: estado e nome, abas Attributes · Source · History e os botões Open page, Show request e Copy JSON.
private struct RowPanel: View {
    let row: DatasetDisplayRow
    let columns: [DatasetColumn]
    let controller: DatasetsController
    let model: DatasetViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            tabs
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.s3) {
                    switch model.panelTab {
                    case .attributes:
                        attributes
                        SourceCard(row: row.row, compact: true)
                    case .source:
                        SourceCard(row: row.row, compact: false)
                    case .history:
                        history
                    }
                }
                .padding(DS.Space.s4)
            }
            actions
        }
        .frame(width: DatasetMetrics.panelWidth)
        .background(DS.Color.chrome)
        .overlay(alignment: .leading) { DS.Color.border.frame(width: ComputersMetrics.separator) }
        .a11y(.datasetProvenance, kind: "panel")
    }

    private var title: String { row.cells.first.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Row", bundle: .module) }

    private var header: some View {
        HStack(alignment: .top, spacing: DS.Space.s2) {
            VStack(alignment: .leading, spacing: DS.Space.s1) {
                HStack(spacing: DS.Space.s2) {
                    statusPill
                    Text(verbatim: title).dsFont(DS.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                }
                Text(verbatim: subtitle).dsFont(DS.Font.monoMicro).foregroundStyle(DS.Color.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
            ActionButton(.datasetSelectRow, argument: .select(""), tooltip: String(localized: "Close", bundle: .module)) { Image(systemName: "xmark") }
                .buttonStyle(DSIconButtonStyle(.header))
        }
        .padding(.leading, DS.Space.s4)
        .padding(.trailing, DS.Space.s2)
        .padding(.vertical, DS.Space.s3)
    }

    private var subtitle: String {
        let base = String(localized: "captured \(controller.clock(row.row.firstSeen))", bundle: .module)
        return row.row.seenCount > 1 ? base + " · " + String(localized: "seen \(row.row.seenCount)×", bundle: .module) : base
    }

    private var statusPill: some View {
        let valid = row.row.valid
        let tone = valid ? DS.Color.dataValid : DS.Color.warning
        return HStack(spacing: DS.Space.s1) {
            Circle().fill(tone).frame(width: DatasetMetrics.liveDot, height: DatasetMetrics.liveDot)
            Text(valid ? "Valid" : "Invalid", bundle: .module).dsFont(DS.Font.label).foregroundStyle(tone)
        }
        .padding(.horizontal, DS.Space.s1_5)
        .padding(.vertical, DS.Space.s0_5)
        .background(RoundedRectangle(cornerRadius: DS.Radius.sm).fill(tone.opacity(0.12)))
        .fixedSize()
    }

    private var tabs: some View {
        HStack(spacing: DS.Space.s4) {
            tab(.attributes, String(localized: "Attributes", bundle: .module))
            tab(.source, String(localized: "Source", bundle: .module))
            tab(.history, String(localized: "History", bundle: .module))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.s4)
        .overlay(alignment: .bottom) { DS.Color.border.frame(height: ComputersMetrics.separator) }
    }

    private func tab(_ value: DatasetPanelTab, _ title: String) -> some View {
        let on = model.panelTab == value
        return ActionButton(.datasetPanelTab, id: .datasetPanelTab(value.rawValue), argument: .select(value.rawValue)) {
            Text(verbatim: title).dsFont(DS.Font.label).foregroundStyle(on ? DS.Color.textPrimary : DS.Color.textTertiary)
                .padding(.vertical, DS.Space.s2)
                .overlay(alignment: .bottom) { if on { DS.Color.textPrimary.frame(height: DatasetMetrics.tabUnderline) } }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Valores no estilo do Datadog: chave em azul, texto entre aspas em verde, números em branco, ausente como `null`.
    private var attributes: some View {
        VStack(alignment: .leading, spacing: DS.Space.s1_5) {
            ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                let problem = index < row.problems.count ? row.problems[index] : nil
                let value = index < row.cells.count ? row.cells[index] : ""
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
                    Text(verbatim: column.name).dsFont(DS.Font.monoCell).foregroundStyle(DS.Color.dataKey).lineLimit(1)
                        .frame(width: DatasetMetrics.panelLabel, alignment: .leading)
                    attributeValue(column, value: value, problem: problem)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder private func attributeValue(_ column: DatasetColumn, value: String, problem: String?) -> some View {
        if let problem {
            Text(verbatim: problem).dsFont(DS.Font.monoCell).foregroundStyle(DS.Color.warning).lineLimit(1)
        } else if value.isEmpty {
            Text(verbatim: "null").dsFont(DS.Font.monoCell).foregroundStyle(DS.Color.textQuaternary)
        } else if DatasetMetrics.isNumeric(column.type) || column.type == .boolean {
            Text(verbatim: value).dsFont(DS.Font.monoCell).foregroundStyle(DS.Color.textPrimary).textSelection(.enabled)
        } else {
            Text(verbatim: "\"" + (column.type == .url ? GridRowText.short(value) : value) + "\"").dsFont(DS.Font.monoCell)
                .foregroundStyle(DS.Color.dataString).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: DS.Space.s1_5) {
            PanelLine(label: String(localized: "First seen", bundle: .module), value: controller.absolute(row.row.firstSeen))
            PanelLine(label: String(localized: "Last seen", bundle: .module), value: controller.absolute(row.row.lastSeen))
            PanelLine(label: String(localized: "Times seen", bundle: .module), value: row.row.seenCount.formatted(), mono: true)
                .a11y(.datasetProvenanceSeen, kind: "text", value: "\(row.row.seenCount)")
            if !row.row.valid, let error = row.row.error {
                PanelLine(label: String(localized: "Error", bundle: .module), value: error, tone: DS.Color.warning, lines: 4)
                    .a11y(.datasetProvenanceError, kind: "text", value: error)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: DS.Space.s1_5) {
            if row.row.sourceURL.flatMap(DatasetsController.webURL) != nil {
                DSButton(.datasetOpenSource, "Open page", variant: .outline, size: .xs, argument: .select(row.row.rowKey))
            }
            if let request = row.row.requestID, let computer = row.row.computer {
                DSButton(.computerOpenEvidence, "Show request", variant: .outline, size: .xs, argument: .select("\(computer)|\(request)"))
            }
            DSButton(.datasetCopyRow, id: .datasetCopyRow, "Copy JSON", variant: .outline, size: .xs, argument: .select(row.row.rowKey))
            Spacer(minLength: 0)
        }
        .padding(DS.Space.s3)
        .overlay(alignment: .top) { DS.Color.border.frame(height: ComputersMetrics.separator) }
    }
}

/// Rótulo à esquerda, valor à direita (cartão de origem e histórico).
private struct PanelLine: View {
    let label: String
    let value: String
    var mono = false
    var tone: Color = DS.Color.textPrimary
    var lines = 1

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
            Text(verbatim: label).dsFont(DS.Font.cell).foregroundStyle(DS.Color.textTertiary).lineLimit(1)
                .frame(width: DatasetMetrics.panelLabel, alignment: .leading)
            Spacer(minLength: 0)
            Text(verbatim: value).dsFont(mono ? DS.Font.monoCell : DS.Font.cell).foregroundStyle(tone)
                .lineLimit(lines).truncationMode(.middle).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }
}

/// De onde a linha veio: página, computador, pedido (método · status · tempo) e evidência; a versão completa mostra também os ids.
private struct SourceCard: View {
    let row: DatasetRow
    let compact: Bool

    private var trust: (String, Color) {
        switch row.trust {
        case .observed: (String(localized: "Seen in network", bundle: .module), DS.Color.dataValid)
        case .reported: (String(localized: "Agent-reported", bundle: .module), DS.Color.textSecondary)
        case .none: (String(localized: "No source", bundle: .module), DS.Color.textTertiary)
        }
    }

    private var requestText: String? {
        guard let info = row.request else { return nil }
        let head = [info.method, info.status.map { "\($0)" }].compactMap { $0 }.joined(separator: " ")
        if let ms = info.milliseconds { return head.isEmpty ? "\(ms) ms" : "\(head) · \(ms) ms" }
        return head.isEmpty ? nil : head
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s1_5) {
            PanelLine(label: String(localized: "Page", bundle: .module), value: row.sourceURL.map(GridRowText.short) ?? "—", mono: true)
                .a11y(.datasetProvenanceSource, kind: "text", value: row.sourceURL ?? "")
            PanelLine(label: String(localized: "Computer", bundle: .module), value: row.computer ?? "—")
                .a11y(.datasetProvenanceComputer, kind: "text", value: row.computer ?? "")
            PanelLine(label: String(localized: "Request", bundle: .module), value: requestText ?? "—", mono: true)
                .a11y(.datasetProvenanceRequest, kind: "text", value: row.requestID ?? "")
            HStack(spacing: DS.Space.s2) {
                Text("Evidence", bundle: .module).dsFont(DS.Font.cell).foregroundStyle(DS.Color.textTertiary)
                Spacer(minLength: 0)
                Circle().fill(trust.1).frame(width: DatasetMetrics.liveDot, height: DatasetMetrics.liveDot)
                Text(verbatim: trust.0).dsFont(DS.Font.cell).foregroundStyle(trust.1)
            }
            .a11y(.datasetProvenanceTrust, kind: "badge", value: row.trust.rawValue)
            if !compact {
                PanelLine(label: String(localized: "Request ID", bundle: .module), value: row.requestID ?? "—", mono: true)
                PanelLine(label: String(localized: "Run", bundle: .module), value: row.runID ?? "—", mono: true)
                    .a11y(.datasetProvenanceRun, kind: "text", value: row.runID ?? "")
                PanelLine(label: String(localized: "Full URL", bundle: .module), value: row.sourceURL ?? "—", mono: true, lines: 3)
            }
        }
        .padding(DS.Space.s3)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Color.canvas))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Color.border))
    }
}

/// URL sem o esquema, para caber na grade e no painel.
enum GridRowText {
    static func short(_ url: String) -> String {
        for prefix in ["https://", "http://"] where url.hasPrefix(prefix) { return String(url.dropFirst(prefix.count)) }
        return url
    }
}

/// Ações de um dataset (na barra da página e na barra de localização da área Data): exportar como CSV ou JSON, em selos
/// pequenos, e abrir num notebook Python. As colunas vivem na aba Structure e no clique do cabeçalho da grade.
struct DatasetToolbar: View {
    let model: DatasetViewModel
    var labels = true
    /// Dentro de uma sessão (pane do dataset): o notebook abre ao lado do agente, não na área Data.
    var inSession = false

    var body: some View {
        HStack(spacing: DS.Space.s1_5) {
            FormatBadge(model: model, format: .csv, title: "CSV")
            FormatBadge(model: model, format: .json, title: "JSON")
            ActionButton(.datasetNotebook, id: .datasetNotebook, argument: .select(inSession ? "\(model.id)|session" : model.id), tooltip: String(localized: "Open in a Python notebook", bundle: .module)) {
                HStack(spacing: DS.Space.s1_5) {
                    JupyterMark(size: DatasetMetrics.notebookLogo)
                    if labels { Text("Notebook", bundle: .module).dsFont(DS.Font.label) }
                }
                .foregroundStyle(DS.Color.textPrimary)
                .padding(.horizontal, DS.Space.s2_5)
                .frame(height: DatasetMetrics.badgeHeight)
                .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.Color.secondary))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(DS.Color.border))
                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control))
            }
            .buttonStyle(.plain)
        }
    }
}

/// Selo de exportação ("CSV", "JSON"): um clique abre o painel de salvar nesse formato.
private struct FormatBadge: View {
    let model: DatasetViewModel
    let format: DatasetExportFormat
    let title: String
    @State private var hovering = false

    var body: some View {
        ActionButton(.datasetExport, id: .datasetExportWithFormat(format.rawValue), argument: .select(format.rawValue),
                     tooltip: String(localized: "Export valid rows as \(title)", bundle: .module)) {
            HStack(spacing: DS.Space.s1) {
                Image(systemName: "arrow.down").dsFont(DS.Font.micro)
                Text(verbatim: title).dsFont(DS.Font.monoMicro)
            }
            .foregroundStyle(hovering ? DS.Color.textPrimary : DS.Color.textSecondary)
            .padding(.horizontal, DS.Space.s2)
            .frame(height: DatasetMetrics.badgeHeight)
            .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(hovering ? DS.Color.secondary : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(DS.Color.border))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Grade mais larga que a área: a borda direita esmaece (as linhas continuam para o lado) e o rodapé diz "More columns →".
struct MoreColumnsCue: ViewModifier {
    @Binding var more: Bool

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentSize.width - geo.contentOffset.x - geo.containerSize.width > 1
            } action: { _, value in
                more = value
            }
            .overlay(alignment: .trailing) {
                if more {
                    LinearGradient(stops: [.init(color: DS.Color.canvas.opacity(0), location: 0), .init(color: DS.Color.canvas, location: 0.8)], startPoint: .leading, endPoint: .trailing)
                        .frame(width: DS.Space.s10)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// A nota do rodapé quando há colunas fora da área (no lugar de uma seta por cima dos cabeçalhos).
struct MoreColumnsNote: View {
    var body: some View {
        HStack(spacing: DS.Space.s1) {
            Text("More columns", bundle: .module)
            Image(systemName: "arrow.right").font(.system(size: DS.Space.s2_5, weight: .semibold))
        }
        .dsFont(DS.Font.small)
        .foregroundStyle(DS.Color.textSecondary)
        .fixedSize()
        .help(String(localized: "More columns: scroll sideways", bundle: .module))
        .a11y(.dataMoreColumns, kind: "hint")
    }
}

extension View {
    func moreColumnsCue(_ more: Binding<Bool>) -> some View { modifier(MoreColumnsCue(more: more)) }
}
