import RackyCore
import RackyDesignSystem
import RackyProtocol
import RackyStore
import SwiftUI

// O conteúdo de cada objeto aberto na área Data: dataset do Racky (a página de dataset), tabela de uma conexão, consulta SQL,
// pasta de bucket, aba de planilha e webhook. Mais a folha "Add connection".

struct DataObjectView: View {
    let hub: DataHubController
    let object: DataObject

    var body: some View {
        switch object {
        case .dataset(let id):
            if let model = hub.datasets.models[id] {
                DatasetPageView(controller: hub.datasets, model: model, paneID: nil, drag: nil, showsBar: false, hub: hub)
            } else {
                Color.clear
            }
        case .table: TableObjectView(hub: hub, object: object)
        case .query: QueryObjectView(hub: hub, object: object)
        case .folder(let connection, let path):
            if hub.isLiveS3(connection) { S3FolderView(hub: hub, object: object, connection: connection, path: path) } else { FolderObjectView(hub: hub, connection: connection, path: path) }
        case .webhook: WebhookObjectView(hub: hub, object: object)
        case .tab: DataGridView(grid: DataHubFixtures.grid(for: object), footer: String(localized: "Columns A–C · first 10 rows", bundle: .module))
        case .runs(let connection): PrefectRunsView(hub: hub, connectionID: connection)
        case .notebook(let id): NotebookObjectView(hub: hub, id: id)
        }
    }
}

/// Ações à direita da barra de localização, por tipo de objeto.
struct DataObjectActions: View {
    let hub: DataHubController
    let object: DataObject
    /// Pouco espaço: só os ícones (o nome vai no tooltip).
    var compact = false
    /// Um pouco de espaço a menos: nomes curtos ("Copy…") antes de virar só ícones.
    var short = false
    /// Num pane da sessão: `true` = sozinho numa tab ("Beside the agent"); `false` = ao lado do agente ("Own tab"); `nil` = fora da sessão.
    var besideAgent: Bool? = nil

    var body: some View {
        HStack(spacing: DS.Space.s2) {
            switch object {
            case .dataset(let id):
                // Numa tab sozinha da sessão: leva a tabela para o lado do agente (os dois juntos na tela).
                if besideAgent == nil {
                    // Na área Data: leva a tabela para uma tab da sessão que a coletou (lá ela divide a tela com o agente).
                    ActionButton(.datasetOpen, id: .dataOpenInSession, argument: .select(id), tooltip: String(localized: "Open in session", bundle: .module)) {
                        Image(systemName: "rectangle.stack")
                    }
                    .buttonStyle(DSIconButtonStyle(.header))
                }
                if let besideAgent {
                    // Sozinha numa tab: leva para o lado do agente. Já ao lado: devolve para uma tab própria.
                    if besideAgent {
                        button(.datasetOpen, id: .dataBeside, String(localized: "Beside the agent", bundle: .module), "rectangle.split.2x1", .select("\(id)|beside"))
                    } else {
                        button(.datasetOpen, id: .dataOwnTab, String(localized: "Own tab", bundle: .module), "rectangle", .select("\(id)|tab"))
                    }
                }
                // "Copy to…" volta com a etapa de entrega (cópias de verdade para um banco); um botão que não faz nada não fica na tela.
                if let model = hub.datasets.models[id] { DatasetToolbar(model: model, labels: !compact) }
            case .table(let connection, _, _):
                button(.dataNewQuery, id: .dataQueryTarget, String(localized: "New query", bundle: .module), "terminal", .select(connection))
                if hub.isLivePostgres(connection) {
                    RemoveConnectionControl(hub: hub, connection: connection, compact: compact)
                }
            case .query(let connection, _):
                if hub.isLivePostgres(connection) {
                    RemoveConnectionControl(hub: hub, connection: connection, compact: compact)
                }
                if compact {
                    button(.dataQueryRun, id: .dataQueryRun, String(localized: "Run", bundle: .module), "play.fill", .press)
                } else {
                    DSButton(.dataQueryRun, id: .dataQueryRun, "Run", variant: .primary, size: .sm, symbol: "play.fill", keycap: "⌘Return")
                }
            case .webhook:
                button(.dataWebhookTest, id: .dataWebhookTest, String(localized: "Test: post 2 sample rows to this URL…", bundle: .module), "paperplane", .press)
            case .folder, .tab, .runs, .notebook:
                EmptyView()
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private func button(_ action: ActionID, id: A11yID, _ title: String, _ symbol: String, _ argument: ActionArgument) -> some View {
        if compact {
            ActionButton(action, id: id, argument: argument, tooltip: title) { Image(systemName: symbol) }
                .buttonStyle(DSIconButtonStyle(.header))
        } else {
            DSButton(action, id: id, LocalizedStringKey(title), variant: .outline, size: .sm, symbol: symbol, argument: argument)
        }
    }
}

// MARK: Grade

/// Grade de leitura (tabela, resultado, arquivo, planilha): cabeçalho com nome e tipo, números à direita em mono, rodapé com o total.
struct DataGridView: View {
    let grid: DataGrid
    var footer: String? = nil
    @State private var moreColumns = false
    /// Anterior/seguinte habilitados (tabelas de conexão paginadas); `nil` = sem paginação.
    var pager: (previous: Bool, next: Bool)? = nil
    /// Colunas encolhem para caber na largura (até um mínimo) em vez de cortar à direita (tabelas de leitura, como os flow runs).
    var fit = false
    /// Poucas colunas: elas alargam até ocupar a largura (no máximo 3×), em vez de deixar o resto da tela vazio.
    var fill = false

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { viewport in
            let natural = grid.columns.reduce(0) { $0 + width($1) }
            let ratio = natural > 0 ? viewport.size.width / natural : 1
            let scale = fit && ratio < 1 ? ratio : 1
            // Sobra de largura vai para as colunas de texto (números e datas ficam no tamanho natural), até 2× a largura natural.
            let textColumns = grid.columns.filter { !numeric($0) && !$0.type.contains("time") }.count
            let bonus = fill && ratio > 1 && textColumns > 0 ? min(viewport.size.width - natural, natural * 2) / CGFloat(textColumns) : 0
            ScrollView([.horizontal, .vertical]) {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(Array(grid.columns.enumerated()), id: \.offset) { _, column in
                            HStack(spacing: DS.Space.s1_5) {
                                Text(verbatim: column.name).dsFont(DS.Font.label).foregroundStyle(DS.Color.textPrimary).lineLimit(1).fixedSize()
                                Text(verbatim: column.type).dsFont(DS.Font.monoMicro).foregroundStyle(DS.Color.textTertiary).lineLimit(1).fixedSize()
                                if column.key { Text("KEY", bundle: .module).dsFont(DS.Font.monoMicro).foregroundStyle(DS.Color.warning) }
                            }
                            .padding(.horizontal, DatasetMetrics.cellPadding)
                            .frame(width: width(column, scale, bonus), height: DatasetMetrics.headerHeight, alignment: numeric(column) ? .trailing : .leading)
                            .overlay(alignment: .trailing) { DS.Color.border.frame(width: ComputersMetrics.separator) }
                        }
                    }
                    .background(DS.Color.chrome)
                    .overlay(alignment: .bottom) { DS.Color.borderStrong.frame(height: ComputersMetrics.separator) }
                    ForEach(Array(grid.rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 0) {
                            ForEach(Array(grid.columns.enumerated()), id: \.offset) { index, column in
                                let text = index < row.count ? row[index] : ""
                                // NULL do banco aparece apagado e em itálico, para não parecer o texto "NULL".
                                let isNull = text == "NULL"
                                Text(verbatim: text).dsFont(numeric(column) || column.type.contains("time") ? DS.Font.monoCell : DS.Font.cell)
                                    .italic(isNull)
                                    .foregroundStyle(isNull ? DS.Color.textTertiary : column.key ? DS.Color.textSecondary : DS.Color.textPrimary)
                                    .lineLimit(1).truncationMode(.tail)
                                    .padding(.horizontal, DatasetMetrics.cellPadding)
                                    .frame(width: width(column, scale, bonus), height: DatasetMetrics.rowHeight, alignment: numeric(column) ? .trailing : .leading)
                                    .overlay(alignment: .trailing) { DS.Color.border.frame(width: ComputersMetrics.separator) }
                            }
                        }
                        .overlay(alignment: .bottom) { DS.Color.border.frame(height: ComputersMetrics.separator) }
                    }
                }
                // A grade começa no canto de cima, mesmo com poucas linhas.
                .frame(minWidth: viewport.size.width, minHeight: viewport.size.height, alignment: .topLeading)
            }
            .moreColumnsCue($moreColumns)
            }
            HStack(spacing: DS.Space.s2) {
                if let pager {
                    pageButton("chevron.left", id: .dataTablePagePrev, argument: "prev", enabled: pager.previous)
                    pageButton("chevron.right", id: .dataTablePageNext, argument: "next", enabled: pager.next)
                }
                Text(verbatim: footer ?? String(localized: "Showing \(grid.rows.count) of \(grid.total.formatted()) rows", bundle: .module))
                    .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                Spacer(minLength: 0)
                if moreColumns { MoreColumnsNote() }
            }
            .padding(.horizontal, DS.Space.s3)
            .frame(height: DatasetMetrics.footerHeight)
            .background(DS.Color.chrome)
            .overlay(alignment: .top) { DS.Color.border.frame(height: ComputersMetrics.separator) }
        }
        .a11y(.dataTableGrid, kind: "table", value: "\(grid.rows.count)")
    }

    private func pageButton(_ symbol: String, id: A11yID, argument: String, enabled: Bool) -> some View {
        ActionButton(.dataTablePage, id: id, argument: .select(argument)) {
            Image(systemName: symbol).font(.system(size: DS.Space.s2_5, weight: .semibold))
                .foregroundStyle(enabled ? DS.Color.textSecondary : DS.Color.textQuaternary)
                .frame(width: DS.Space.s6, height: DS.Space.s6)
                .background(RoundedRectangle(cornerRadius: DS.Radius.sm).strokeBorder(DS.Color.borderStrong))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func numeric(_ column: DataGrid.Column) -> Bool {
        ["int", "numeric", "double", "number", "int4", "int8", "int32", "float"].contains { column.type.hasPrefix($0) }
    }

    private func width(_ column: DataGrid.Column, _ scale: CGFloat, _ bonus: CGFloat = 0) -> CGFloat {
        let extra = numeric(column) || column.type.contains("time") ? 0 : bonus.rounded(.down)
        return extra + base(column, scale)
    }

    private func base(_ column: DataGrid.Column, _ scale: CGFloat) -> CGFloat {
        scale >= 1 ? width(column) : max(width(column) * scale, DatasetMetrics.colNumber)
    }

    private func width(_ column: DataGrid.Column) -> CGFloat {
        // Largo o bastante para "avg_price numeric" e "2026-10-22 11:59:04" numa linha.
        if numeric(column) { return DatasetMetrics.colNumber + DS.Space.s10 }
        if column.type.contains("time") { return DatasetMetrics.colDateTime + DS.Space.s8 }
        return column.key ? DatasetMetrics.colURL : DatasetMetrics.colName
    }
}

// MARK: Tabela

/// Tabela de uma conexão: Data (grade), Structure (colunas) e Writers (quem grava aqui), com o selo de edição.
struct TableObjectView: View {
    let hub: DataHubController
    let object: DataObject

    var body: some View {
        let live = hub.isLivePostgres(object.connectionID)
        let grid = live ? hub.tableGrid(object) : DataHubFixtures.grid(for: object)
        let open = hub.tableTab(object)
        VStack(spacing: 0) {
            DataTabsBar(hub: hub, object: object)
            if open != .data {
                DataInlinePanel(hub: hub, object: object, natural: open == .structure ? DataInlinePanel<EmptyView>.gridHeight(rows: grid.columns.count) : nil) {
                    panel(open, live: live, grid: grid)
                }
            }
            // A grade fica sempre na tela; o painel aberto só a empurra para baixo.
            Group {
                let page = hub.tablePage(object)
                let pages = hub.pageCount(for: object)
                if live {
                    LiveTableData(hub: hub, object: object, page: page, pages: pages)
                } else {
                    DataGridView(
                        grid: DataHubFixtures.grid(for: object, page: page),
                        footer: String(localized: "Page \(page + 1) of \(pages.formatted()) · \(grid.total.formatted()) rows", bundle: .module),
                        pager: (page > 0, page + 1 < pages))
                }
            }
        }
    }

    @ViewBuilder private func panel(_ open: DataTableTab, live: Bool, grid: DataGrid) -> some View {
            switch open {
            case .data: EmptyView()
            case .overview: DataOverviewView(hub: hub, object: object)
            case .structure:
                VStack(spacing: 0) {
                    if live, let error = hub.tableStates[object]?.error { DataErrorBanner(error: error, id: .dataTableError) }
                    DataGridView(
                        grid: DataGrid(
                            columns: [.init(name: "column", type: "name"), .init(name: "type", type: "text"), .init(name: "nullable", type: "bool"), .init(name: "key", type: "text")],
                            rows: grid.columns.map { [$0.name, $0.type, $0.nullable ? "yes" : "no", $0.key ? "primary key" : ""] },
                            total: grid.columns.count),
                        footer: grid.columns.count == 1 ? String(localized: "1 column", bundle: .module) : String(localized: "\(grid.columns.count) columns", bundle: .module), fit: true)
                }
            case .writers: DataWritersView(hub: hub, object: object)
            }
    }
}

/// Dados de uma tabela de uma conexão Postgres de verdade: a página lida do servidor (100 linhas), o erro se a leitura falhou.
struct LiveTableData: View {
    let hub: DataHubController
    let object: DataObject
    let page: Int
    let pages: Int

    var body: some View {
        let state = hub.tableStates[object] ?? PostgresTableState()
        VStack(spacing: 0) {
            if let error = state.error { DataErrorBanner(error: error, id: .dataTableError) }
            if !state.loaded {
                Text(verbatim: state.error == nil ? String(localized: "Reading the table…", bundle: .module) : "")
                    .dsFont(DS.Font.body).foregroundStyle(DS.Color.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let total = state.total.formatted()
                // "Rows 101–200 of 250": quantas linhas a página mostra (só "page 2 of 3" não dizia).
                let rowCount = hub.tableGrid(object).rows.count
                let first = rowCount == 0 ? 0 : page * DataHubController.livePageSize + 1
                let last = page * DataHubController.livePageSize + rowCount
                DataGridView(
                    grid: hub.tableGrid(object),
                    footer: state.approximate
                        ? String(localized: "Rows \(first)–\(last) of about \(total) · page \(page + 1) of \(pages.formatted())", bundle: .module)
                        : String(localized: "Rows \(first)–\(last) of \(total) · page \(page + 1) of \(pages.formatted())", bundle: .module),
                    pager: (page > 0, page + 1 < pages), fill: true)
            }
        }
    }
}

/// Faixa de erro de leitura (conexão, SQL): em âmbar, sem derrubar a tela.
struct DataErrorBanner: View {
    let error: String
    let id: A11yID

    var body: some View {
        HStack(spacing: DS.Space.s2) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: DS.Space.s3))
            Text(verbatim: error).dsFont(DS.Font.small).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(DS.Color.warning)
        .padding(.horizontal, DS.Space.s4)
        .padding(.vertical, DS.Space.s2)
        .a11y(id, kind: "text", label: error)
    }
}

/// As abas de um dataset ou tabela, sempre as mesmas para o que os agentes alimentam. À direita, uma linha sobre o que dá para fazer.
struct DataTabsBar: View {
    let hub: DataHubController
    let object: DataObject

    var body: some View {
        let open = hub.tableTab(object)
        HStack(spacing: DS.Space.s1_5) {
            // A grade fica sempre na tela: Overview, Structure e Who writes here abrem um painel em cima dela e fecham no mesmo botão
            // (antes cada um trocava a tela inteira).
            ForEach(hub.tabs(for: object).filter { $0 != .data }, id: \.self) { item in
                let isOpen = open == item
                // O objeto vai junto: num pane da sessão o painel é deste dataset, não do que a área Data tem aberto.
                ActionButton(.dataTableTab, id: .dataTableTab(item.rawValue), argument: .select("\(isOpen ? DataTableTab.data.rawValue : item.rawValue)|\(object.key)")) {
                    HStack(spacing: DS.Space.s1) {
                        Text(verbatim: title(item)).dsFont(DS.Font.label)
                            .foregroundStyle(isOpen ? DS.Color.textPrimary : DS.Color.textSecondary)
                        if item == .writers, !hub.writers(of: object).isEmpty {
                            Text(verbatim: "\(hub.writers(of: object).count)").dsFont(DS.Font.small).monospacedDigit().foregroundStyle(DS.Color.textTertiary)
                        }
                        Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                            .font(.system(size: DS.Space.s2_5, weight: .semibold)).foregroundStyle(DS.Color.textTertiary)
                    }
                    .padding(.horizontal, DS.Space.s2)
                    .frame(height: DataMetrics.chipHeight)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.sm).fill(isOpen ? DS.Color.secondary : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.sm).strokeBorder(DS.Color.border))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
            if open != .data {
                // Recolhe o painel aberto (o mesmo que clicar de novo no botão dele); fica na barra, nunca em cima do conteúdo.
                ActionButton(.dataTableTab, id: .dataPanelCollapse, argument: .select("\(DataTableTab.data.rawValue)|\(object.key)"), tooltip: String(localized: "Minimize", bundle: .module)) {
                    HStack(spacing: DS.Space.s1) {
                        Image(systemName: "chevron.up").font(.system(size: DS.Space.s2_5, weight: .semibold))
                        Text("Minimize", bundle: .module).dsFont(DS.Font.small)
                    }
                    .foregroundStyle(DS.Color.textSecondary)
                    .padding(.horizontal, DS.Space.s1_5)
                    .frame(height: DataMetrics.chipHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
            Spacer(minLength: DS.Space.s2)
            if let note { Text(verbatim: note).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).lineLimit(1) }
        }
        .padding(.horizontal, DS.Space.s4)
        .padding(.vertical, DS.Space.s1_5)
        .overlay(alignment: .bottom) { DS.Color.border.frame(height: ComputersMetrics.separator) }
    }

    /// Tabela que o Racky não alimenta: dizer que é só navegação.
    private var note: String? {
        guard case .table = object, hub.copySource(of: object) == nil else { return nil }
        return String(localized: "Browsing your database · Racky doesn't write here", bundle: .module)
    }

    private func title(_ tab: DataTableTab) -> String {
        switch tab {
        case .data: String(localized: "Data", bundle: .module)
        case .overview: String(localized: "Overview", bundle: .module)
        case .structure: String(localized: "Structure", bundle: .module)
        case .writers: String(localized: "Who writes here", bundle: .module)
        }
    }
}

/// O painel aberto pela barra (Overview, Structure ou Who writes here) em cima da grade: altura fixa, rola por dentro, e um botão
/// no canto recolhe de volta (o mesmo que clicar de novo no botão da barra).
struct DataInlinePanel<Content: View>: View {
    let hub: DataHubController
    let object: DataObject
    var available: CGFloat?
    /// Altura já conhecida (Structure: cabeçalho, uma linha por coluna e rodapé); sem ela o painel mede o conteúdo.
    var natural: CGFloat? = nil
    @ViewBuilder let content: Content
    @State private var measured: CGFloat = 0

    /// Teto: até metade do que o pane tem (num pane baixo a grade ainda aparece), nunca menos que o mínimo legível.
    private var cap: CGFloat {
        guard let available else { return DataMetrics.panelHeight }
        return min(DataMetrics.panelHeight, max(available / 2, DataMetrics.panelMinHeight))
    }

    private var measuredHeight: CGFloat { measured > .zero ? min(measured, cap) : cap }

    /// Altura de uma grade de `rows` linhas (a de Structure), com a folga das bordas e do espaço entre a grade e o rodapé.
    static func gridHeight(rows: Int) -> CGFloat {
        DatasetMetrics.headerHeight + CGFloat(rows) * DatasetMetrics.rowHeight + DatasetMetrics.footerHeight + DS.Space.s4 + DS.Space.s1
    }

    var body: some View {
        // Do tamanho do conteúdo (Who writes here com uma linha fica baixo); passou do teto, rola por dentro.
        Group {
            if let natural {
                content.frame(height: min(natural, cap))
            } else {
                ScrollView {
                    content.frame(maxWidth: .infinity, alignment: .topLeading)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured = $0 }
                }
                .frame(height: measuredHeight)
            }
        }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .clipped()
            .background(DS.Color.chrome.opacity(0.5))
            .overlay(alignment: .bottom) { DS.Color.border.frame(height: ComputersMetrics.separator) }
    }
}

/// Visão geral: o caminho inteiro do dado e os números da coleta (os mesmos no Mac e na cópia, porque vêm da coleta no Mac).
struct DataOverviewView: View {
    let hub: DataHubController
    let object: DataObject

    var body: some View {
        Group {  // quem rola é o painel (DataInlinePanel), só quando não cabe
            VStack(alignment: .leading, spacing: 0) {
                // O caminho já está em cima (numa linha); aqui fica só a frase de qual é o original e para que lado o dado anda.
                if let sentence = DataLineageStrip(hub: hub, object: object).explanation {
                    Text(verbatim: sentence).dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary)
                        .padding(.horizontal, DS.Space.s4).padding(.top, DS.Space.s3)
                        .padding(.trailing, DS.Space.s8)
                }
                if let id = hub.feedingDataset(of: object), let snapshot = hub.datasets.models[id]?.snapshot {
                    if case .dataset = object {} else {
                        // Os números são da coleta no Mac que alimenta esta cópia (não do banco): dito como título da seção.
                        HStack(spacing: DS.Space.s1_5) {
                            Image(systemName: "laptopcomputer").font(.system(size: DS.Space.s3)).foregroundStyle(DS.Color.textSecondary)
                            Text(verbatim: String(localized: "Collection on this Mac that feeds this table: \(hub.datasets.name(of: id) ?? "")", bundle: .module))
                                .dsFont(DS.Font.sectionLabel).foregroundStyle(DS.Color.textPrimary)
                        }
                        .padding(.horizontal, DS.Space.s4)
                        .padding(.top, DS.Space.s4)
                    }
                    DatasetOverviewTiles(snapshot: snapshot, controller: hub.datasets, wrap: true)
                    // Poucas linhas não desenham curva nenhuma: o painel fica só com os números e a tabela continua com espaço.
                    if snapshot.stats.rows >= InsightMetrics.tallChartMinRows {
                        ActivityChart(snapshot: snapshot, controller: hub.datasets, rangeMenu: AnyView(EmptyView()), height: InsightMetrics.chartHeight)
                    }
                }
            }
        }
    }
}

/// Quem grava aqui: agentes (com a sessão) e cópias, com pausar.
struct DataWritersView: View {
    let hub: DataHubController
    let object: DataObject

    var body: some View {
        let list = hub.writers(of: object)
        Group {  // quem rola é o painel (DataInlinePanel), só quando não cabe
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                if list.isEmpty {
                    Text("Nothing in Racky writes here. Pick it under Save data to when you start a session.", bundle: .module)
                        .dsFont(DS.Font.body).foregroundStyle(DS.Color.textTertiary)
                }
                ForEach(list) { writer in
                    HStack(spacing: DS.Space.s3) {
                        let info = HStack(spacing: DS.Space.s3) {
                            mark(writer)
                                .frame(width: DS.Space.s8, height: DS.Space.s8)
                                .background(RoundedRectangle(cornerRadius: DS.Radius.sm).fill(DS.Color.secondary))
                            VStack(alignment: .leading, spacing: .zero) {
                                HStack(spacing: DS.Space.s1_5) {
                                    Text(verbatim: name(writer))
                                        .dsFont(DS.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary)
                                    if writer.live { LiveDot() }
                                }
                                Text(verbatim: detail(writer)).dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary)
                            }
                            Spacer(minLength: 0)
                        }
                        // A linha leva a quem grava: o agente abre o terminal dele, a cópia abre o original no Mac (antes clicar não fazia nada).
                        if let action = open(writer) {
                            ActionButton(action.0, id: .dataWriterOpen(writer.id), argument: action.1) {
                                HStack(spacing: DS.Space.s2) {
                                    info
                                    Text(verbatim: goLabel(writer)).dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary)
                                    Image(systemName: "chevron.right").font(.system(size: DS.Space.s3, weight: .semibold)).foregroundStyle(DS.Color.textSecondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        } else {
                            info
                        }
                        if writer.live || hub.paused.contains(writer.id) {
                            DSButton(
                                .dataPauseWriter, id: .dataWriterPause(writer.id), hub.paused.contains(writer.id) ? "Resume" : "Pause",
                                variant: .outline, size: .xs, symbol: hub.paused.contains(writer.id) ? "play.fill" : "pause.fill", argument: .select(writer.id))
                        }
                    }
                    .padding(DS.Space.s3)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.md).fill(DS.Color.panel))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).strokeBorder(DS.Color.border))
                }
            }
            .padding(DS.Space.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "Agents" sozinho não dizia quem: o CLI da sessão (Claude Code, Codex…) e a sessão.
    private func name(_ writer: DataWriter) -> String {
        switch writer.kind {
        case .sync: return String(localized: "Racky, copying from \(hub.displayName(ofDatasetNamed: writer.name)) (this Mac)", bundle: .module)
        case .agent(let session):
            guard writer.name == String(localized: "Agents", bundle: .module) else { return writer.name }
            let provider = hub.feedingDataset(of: object).flatMap { hub.summary(ofDataset: $0) }.flatMap { hub.datasets.sessionAgent($0.dataset.sessionID) } ?? .claude
            return String(localized: "\(DataLineageStrip.agentTitle(provider)) in session \(session)", bundle: .module)
        }
    }

    private func goLabel(_ writer: DataWriter) -> String {
        if case .agent = writer.kind { return String(localized: "Open its terminal", bundle: .module) }
        return String(localized: "Open the original", bundle: .module)
    }

    private func open(_ writer: DataWriter) -> (ActionID, ActionArgument)? {
        switch writer.kind {
        case .agent:
            guard let id = hub.feedingDataset(of: object), let session = hub.summary(ofDataset: id)?.dataset.sessionID else { return nil }
            return (.sessionSelect, .select("\(session.uuidString)|agent"))
        case .sync(let from):
            if case .dataset(let name) = from, let id = hub.datasetID(named: name) { return (.dataOpen, .select(DataObject.dataset(id).key)) }
            return (.dataOpen, .select(from.key))
        }
    }

    @ViewBuilder private func mark(_ writer: DataWriter) -> some View {
        switch writer.kind {
        case .agent:
            if let provider = DataLineageStrip.provider(named: writer.name) {
                DSAgentLogo(QuickLaunchModel.kind(provider), size: DS.Space.s4)
            } else {
                DSAgentLogo(QuickLaunchModel.kind(TerminalProvider.claude), size: DS.Space.s4)
            }
        case .sync: Image(systemName: "laptopcomputer").font(.system(size: DS.Space.s3 + 2)).foregroundStyle(DS.Color.textSecondary)
        }
    }

    private func detail(_ writer: DataWriter) -> String {
        switch writer.kind {
        case .agent(let session):
            writer.detail.isEmpty
                // "Pause" só aparece com o agente gravando agora; sem o botão, a frase não fala dele.
                ? (writer.live || hub.paused.contains(writer.id)
                    ? String(localized: "Writes the rows it collects into this table. Pause stops its new writes; rows already written stay.", bundle: .module)
                    : String(localized: "Writes the rows it collects into this table.", bundle: .module))
                : String(localized: "Agent in session \(session) · \(writer.detail). Pause stops its new writes; rows already written stay.", bundle: .module)
        case .sync(let from):
            if case .dataset(let name) = from { String(localized: "One-way: rows go from \(hub.displayName(ofDatasetNamed: name)) on this Mac (the original) to here · \(writer.detail)", bundle: .module) } else { writer.detail }
        }
    }
}

/// Colunas de um dataset do Mac: nome, tipo, obrigatória, chave.
struct DataColumnsView: View {
    let dataset: Dataset

    var body: some View {
        DataGridView(
            grid: DataGrid(
                columns: [.init(name: "column", type: "name"), .init(name: "type", type: "text"), .init(name: "required", type: "bool"), .init(name: "key", type: "text")],
                rows: dataset.columns.map { [$0.name, DatasetMetrics.typeLabel($0.type), $0.required ? "yes" : "no", dataset.key.contains($0.name) ? "key" : ""] }
                    // A grade mostra também "captured" (quando a linha chegou); sem ela aqui, Structure dizia 1 coluna e a grade tinha 2.
                    + [["captured", String(localized: "time · added by Racky", bundle: .module), "yes", ""]],
                total: dataset.columns.count + 1),
            footer: String(localized: "\(dataset.columns.count + 1) columns", bundle: .module), fit: true)
    }
}

// MARK: Consulta

/// Editor SQL: a conexão alvo bem à vista (em âmbar se for produção), o texto e o resultado.
struct QueryObjectView: View {
    let hub: DataHubController
    let object: DataObject

    var body: some View {
        let connection = hub.connection(object.connectionID)
        // Produção já tem a faixa âmbar em cima; aqui só a conexão alvo.
        let prod = false
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.s1_5) {
                Image(systemName: prod ? "exclamationmark.triangle.fill" : "play.circle").font(.system(size: DS.Space.s3))
                Text(verbatim: connection.map { $0.kind.title == $0.name ? String(localized: "Runs on \($0.name)", bundle: .module) : String(localized: "Runs on \($0.name) · \($0.kind.title)", bundle: .module) } ?? "")
                    .dsFont(DS.Font.label)
                if let connection { ConnectionBadges(connection) }
                if prod {
                    Text("This connection is protected: changes ask you to confirm.", bundle: .module).dsFont(DS.Font.small)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(prod ? DS.Color.warning : DS.Color.textSecondary)
            .padding(.horizontal, DS.Space.s4)
            .frame(height: DS.Space.s8)
            .background(prod ? DS.Color.warning.opacity(0.06) : Color.clear)
            .overlay(alignment: .bottom) { DS.Color.border.frame(height: ComputersMetrics.separator) }
            .a11y(.dataQueryTarget, kind: "text", label: connection?.name ?? "")
            TextEditor(text: Binding(get: { hub.queryText[object] ?? "" }, set: { hub.queryText[object] = $0 }))
                .font(.system(size: DS.Space.s3 + 1, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(DS.Space.s3)
                .frame(height: DataMetrics.editorHeight)
                .background(DS.Color.canvas)
                .overlay(alignment: .bottom) { DS.Color.border.frame(height: ComputersMetrics.separator) }
                .a11y(.dataQueryEditor, kind: "textarea")
            if let error = hub.queryErrors[object] {
                DataErrorBanner(error: error, id: .dataQueryError)
                Spacer(minLength: 0)
            } else if let result = hub.queryResult[object] {
                DataGridView(
                    grid: result.grid,
                    footer: hub.queryTruncated.contains(object)
                        ? String(localized: "First \(result.grid.rows.count.formatted()) rows only · \(result.milliseconds) ms", bundle: .module)
                        : String(localized: "\(result.grid.rows.count) rows · \(result.milliseconds) ms", bundle: .module))
                    .a11y(.dataQueryResult, kind: "table")
            } else if hub.queryBusy.contains(object) {
                Text("Running…", bundle: .module).dsFont(DS.Font.body).foregroundStyle(DS.Color.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Run the query to see the result here.", bundle: .module).dsFont(DS.Font.body).foregroundStyle(DS.Color.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: Pasta

/// Pasta de um bucket: arquivos com formato, tamanho e data; clicar num arquivo de dados mostra a prévia ao lado.
struct FolderObjectView: View {
    let hub: DataHubController
    let connection: String
    let path: [String]
    @State private var selected: String?

    var body: some View {
        let entries = DataHubFixtures.files(in: path)
        HStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(entries) { entry in
                        let open: DataObject? = entry.folder ? .folder(connection: connection, path: path + [entry.name]) : nil
                        Group {
                            if let open {
                                ActionButton(.dataOpen, id: .dataFolderEntry(entry.name), argument: .select(open.key)) { row(entry) }.buttonStyle(.plain)
                            } else {
                                // lint-ui: allow buttons escolhe o arquivo para a prévia (estado local)
                                Button { selected = entry.name } label: { row(entry) }
                                    .buttonStyle(.plain)
                                    .a11y(.dataFolderEntry(entry.name), kind: "row", label: entry.name)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .onAppear { if selected == nil { selected = entries.first { !$0.folder && $0.format != "JSON" }?.name } }
            if let selected, let entry = entries.first(where: { $0.name == selected }), entry.format != "JSON" {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(verbatim: entry.name).dsFont(DS.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary)
                        Text(verbatim: entry.format).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, DS.Space.s3)
                    .frame(height: DS.Space.s8 + DS.Space.s1)
                    .overlay(alignment: .bottom) { DS.Color.border.frame(height: ComputersMetrics.separator) }
                    DataGridView(grid: DataHubFixtures.grid(for: .folder(connection: connection, path: path)), footer: String(localized: "Preview · first 10 of 80 rows", bundle: .module))
                }
                .frame(width: DataMetrics.previewWidth)
                .overlay(alignment: .leading) { DS.Color.border.frame(width: ComputersMetrics.separator) }
                .a11y(.dataFolderPreview, kind: "container", label: entry.name)
            }
        }
    }

    private func row(_ entry: DataHubFixtures.FileEntry) -> some View {
        HStack(spacing: DS.Space.s2) {
            Image(systemName: entry.folder ? "folder" : "doc").font(.system(size: DataMetrics.icon)).foregroundStyle(DS.Color.textSecondary)
                .frame(width: DS.Space.s4)
            Text(verbatim: entry.name).dsFont(DS.Font.cell).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
            Spacer(minLength: DS.Space.s2)
            Text(verbatim: entry.folder ? String(localized: "Folder", bundle: .module) : entry.format).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                .frame(width: DatasetMetrics.colCount, alignment: .leading)
            Text(verbatim: entry.folder ? "–" : ByteCountFormatter.string(fromByteCount: Int64(entry.bytes), countStyle: .file))
                .dsFont(DS.Font.monoCell).foregroundStyle(DS.Color.textSecondary)
                .frame(width: DatasetMetrics.colCount, alignment: .trailing)
            Text(verbatim: entry.modified).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                .frame(width: DatasetMetrics.colCount, alignment: .trailing)
        }
        .padding(.horizontal, DS.Space.s4)
        .frame(height: DatasetMetrics.rowHeight)
        .background(selected == entry.name ? DS.Color.dataKey.opacity(0.08) : Color.clear)
        .overlay(alignment: .bottom) { DS.Color.border.frame(height: ComputersMetrics.separator) }
        .contentShape(Rectangle())
    }
}

// MARK: Webhook

/// Webhook: só recebe. Mostra para onde vai, como vai e o log das entregas.
struct WebhookObjectView: View {
    let hub: DataHubController
    let object: DataObject

    var body: some View {
        let connection = hub.connection(object.connectionID)
        let deliveries = DataHubFixtures.deliveries(now: hub.now())
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.s6) {
                fact(String(localized: "Endpoint", bundle: .module), "POST " + (connection?.address ?? ""))
                fact(String(localized: "Body", bundle: .module), String(localized: "JSON array of the new rows, as they arrive", bundle: .module))
                fact(String(localized: "Delivered today", bundle: .module), String(localized: "\(deliveries.count) of \(deliveries.count), 1 after a retry", bundle: .module))
                Spacer(minLength: 0)
            }
            .padding(DS.Space.s4)
            .overlay(alignment: .bottom) { DS.Color.border.frame(height: ComputersMetrics.separator) }
            Text("A webhook only receives data: Racky posts rows to this address. There is nothing to browse, so this shows what each delivery carries and the log of deliveries.", bundle: .module)
                .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                .padding(.horizontal, DS.Space.s4)
                .padding(.top, DS.Space.s3)
            VStack(alignment: .leading, spacing: DS.Space.s1_5) {
                Text("Each delivery looks like this", bundle: .module).dsFont(DS.Font.label).foregroundStyle(DS.Color.textSecondary)
                Text(verbatim: DataHubFixtures.samplePayload).dsFont(DS.Font.monoCell).foregroundStyle(DS.Color.textPrimary)
                    .padding(DS.Space.s3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.md).fill(DS.Color.chrome))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).strokeBorder(DS.Color.border))
            }
            .padding(DS.Space.s4)
            .a11y(.dataWebhookPayload, kind: "text")
            Text("Deliveries", bundle: .module).dsFont(DS.Font.label).foregroundStyle(DS.Color.textSecondary)
                .padding(.horizontal, DS.Space.s4)
                .padding(.bottom, DS.Space.s2)
            DataGridView(
                grid: DataGrid(
                    columns: [.init(name: "sent", type: "time"), .init(name: "status", type: "int"), .init(name: "rows", type: "int"), .init(name: "duration", type: "int")],
                    rows: deliveries.map { [hub.datasets.clock($0.at), "\($0.status)", "\($0.rows)", "\($0.milliseconds) ms"] },
                    total: deliveries.count),
                footer: String(localized: "\(deliveries.count) deliveries · the 502 was retried and went through", bundle: .module))
                .a11y(.dataWebhookLog, kind: "table")
        }
    }

    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s0_5) {
            Text(verbatim: title).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
            Text(verbatim: value).dsFont(DS.Font.monoCell).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
        }
    }
}

// MARK: Adicionar conexão

/// Folha de tipos: agrupados por família, cada um com o logo, o nome e o que é; o grupo diz se dá para navegar e gravar ou só gravar.
struct DataConnectSheet: View {
    let hub: DataHubController
    /// "Coming soon" começa recolhido: 12 cards desabilitados ocupavam mais que os que conectam de verdade.
    @State private var showSoon = false

    var body: some View {
        GeometryReader { geo in
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(alignment: .leading, spacing: DS.Space.s6) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: DS.Space.s1) {
                        Text("Add connection", bundle: .module).dsFont(DS.Font.dialogTitle).foregroundStyle(DS.Color.textPrimary)
                        Text("A place outside Racky: browse it here, and let agents write to it.", bundle: .module).dsFont(DS.Font.body).foregroundStyle(DS.Color.textTertiary)
                    }
                    Spacer(minLength: 0)
                    ActionButton(.dataAddConnection, argument: .select("close"), tooltip: String(localized: "Close", bundle: .module)) { Image(systemName: "xmark") }
                        .buttonStyle(DSIconButtonStyle(.header))
                }
                if let kind = hub.connecting {
                    if kind == .s3 { S3ConnectFormView(hub: hub, kind: kind) } else { ConnectFormView(hub: hub, kind: kind) }
                } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.s6) {
                        // O que conecta de verdade hoje vem primeiro (antes ficava no fim da lista, cortado, e parecia que nada funcionava).
                        VStack(alignment: .leading, spacing: DS.Space.s2) {
                            Text("Connect now", bundle: .module).dsFont(DS.Font.sectionLabel).foregroundStyle(DS.Color.textPrimary)
                            // Lugares de dados numa linha; orquestradores (só acompanhar o que roda) num grupo próprio, em vez do Prefect
                            // sozinho numa segunda linha parecendo mais um banco.
                            connectGroup(String(localized: "Data", bundle: .module), DataConnectionKind.allCases.filter { $0.connectable && $0.family != .orchestrator })
                            connectGroup(String(localized: "Monitor runs", bundle: .module), DataConnectionKind.allCases.filter { $0.connectable && $0.family == .orchestrator })
                        }
                        let soonCount = DataConnectionKind.allCases.filter { !$0.connectable }.count
                        // lint-ui: allow buttons abre/fecha a lista de "Coming soon" (estado local da folha, sem ação de registro)
                        Button { showSoon.toggle() } label: {
                            HStack(spacing: DS.Space.s1_5) {
                                Image(systemName: showSoon ? "chevron.down" : "chevron.right").font(.system(size: DS.Space.s2_5, weight: .semibold))
                                Text(verbatim: String(localized: "Coming soon (\(soonCount))", bundle: .module)).dsFont(DS.Font.sectionLabel)
                                Text(verbatim: soonPreview).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).lineLimit(1)
                            }
                            .foregroundStyle(DS.Color.textSecondary)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if showSoon {
                        ForEach(DataConnectionKind.Family.allCases.filter { f in DataConnectionKind.allCases.contains { $0.family == f && !$0.connectable } }, id: \.self) { family in
                            VStack(alignment: .leading, spacing: DS.Space.s2) {
                                HStack(spacing: DS.Space.s2) {
                                    Text(verbatim: Self.title(family)).dsFont(DS.Font.sectionLabel).foregroundStyle(DS.Color.textPrimary)
                                    Text(verbatim: family == .outgoing ? String(localized: "Write only", bundle: .module) : String(localized: "Browse and write", bundle: .module))
                                        .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                                }
                                // Ainda de exemplo: cards baixos (logo, nome, "Soon"; o que é fica no tooltip) para a lista inteira caber
                                // sem rolar; antes a última seção ficava cortada no pé da folha.
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DS.Space.s2), count: 3), spacing: DS.Space.s2) {
                                    ForEach(DataConnectionKind.allCases.filter { $0.family == family && !$0.connectable }, id: \.self) { kind in
                                        KindCard(kind: kind, compact: true)
                                    }
                                }
                            }
                        }
                        }
                    }
                    .padding(.bottom, DS.Space.s6)
                }
                // A lista continua abaixo da borda: o pé esmaece (antes a seção "Outgoing" parecia cortada, sem sinal de rolagem).
                .scrollIndicators(.visible)
                .mask {
                    VStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: DS.Space.s6)
                    }
                }
                }
            }
            .padding(DS.Space.s6)
            // Cabe tudo quando a janela deixa; senão, a lista rola dentro da folha.
            .frame(width: DataMetrics.connectWidth)
            // Do tamanho do conteúdo; numa janela baixa, para na altura disponível e a lista rola.
            .frame(maxHeight: min(DataMetrics.connectHeight, geo.size.height - DataMetrics.connectMargin))
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: DS.Radius.large).fill(DS.Color.panel))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.large).strokeBorder(DS.Color.borderStrong))
            .shadow(color: .black.opacity(0.45), radius: DS.Space.s6, y: DS.Space.s2)
            .a11y(.dataConnectSheet, kind: "dialog")
        }
        .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// Um tipo: logo da marca num ladrilho, o nome e uma linha do que é.
    private struct KindCard: View {
        let kind: DataConnectionKind
        var compact = false
        @State private var hovering = false

        var body: some View {
            HStack(spacing: DS.Space.s2_5) {
                DSDataLogo(kind.brand, size: DataMetrics.connectLogo, tile: true)
                VStack(alignment: .leading, spacing: .zero) {
                    HStack(spacing: DS.Space.s1_5) {
                        Text(verbatim: kind.title).dsFont(DS.Font.label).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                        if !kind.connectable {
                            Text("Soon", bundle: .module).dsFont(DS.Font.keycap).foregroundStyle(DS.Color.textTertiary)
                                .padding(.horizontal, DS.Space.s1).padding(.vertical, DataMetrics.badgePadding)
                                .background(RoundedRectangle(cornerRadius: DS.Radius.xs).fill(DS.Color.secondary))
                        }
                    }
                    if !compact {
                        Text(verbatim: kind.tagline).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).lineLimit(2, reservesSpace: true)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, compact ? DS.Space.s2_5 : DS.Space.s3)
            .frame(height: compact ? DataMetrics.connectCardCompact : DataMetrics.connectCard)
            .background(RoundedRectangle(cornerRadius: DS.Radius.md).fill(hovering ? DS.Color.secondary : DS.Color.chrome))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).strokeBorder(hovering ? DS.Color.borderStrong : DS.Color.border))
            .onHover { hovering = $0 }
            .animation(MotionPolicy.shared.animation(MotionTokens.Easing.ease, MotionTokens.Duration.hover), value: hovering)
            .opacity(kind.connectable ? 1 : 0.8)
            .help(kind.connectable ? kind.tagline : kind.tagline + " · " + String(localized: "Coming soon: for now this one is a sample.", bundle: .module))
        }
    }

    @ViewBuilder private func connectGroup(_ title: String, _ kinds: [DataConnectionKind]) -> some View {
        if !kinds.isEmpty {
            Text(verbatim: title).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DS.Space.s2), count: 3), spacing: DS.Space.s2) {
                ForEach(kinds, id: \.self) { kind in
                    ActionButton(.dataConnectStart, id: .dataConnectKind(kind.rawValue), argument: .select(kind.rawValue)) {
                        KindCard(kind: kind)
                            .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).strokeBorder(DS.Color.textTertiary))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// "MySQL, BigQuery, Snowflake, Google Sheets…": o que vem, numa linha, com a lista recolhida.
    private var soonPreview: String {
        let names = DataConnectionKind.allCases.filter { !$0.connectable }.map(\.title)
        return names.prefix(5).joined(separator: ", ") + (names.count > 5 ? "…" : "")
    }

    static func title(_ family: DataConnectionKind.Family) -> String {
        switch family {
        case .database: String(localized: "Databases", bundle: .module)
        case .warehouse: String(localized: "Warehouses", bundle: .module)
        case .storage: String(localized: "Storage", bundle: .module)
        case .spreadsheet: String(localized: "Spreadsheets", bundle: .module)
        case .outgoing: String(localized: "Outgoing", bundle: .module)
        case .orchestrator: String(localized: "Orchestrators", bundle: .module)
        }
    }
}

// MARK: Prefect

/// O que está rodando no Prefect: filtro (rodando, agendados, falhas das últimas 24 h) e a tabela, relida a cada 5 s enquanto está na
/// tela. Só lê: nada aqui muda o Prefect.
struct PrefectRunsView: View {
    let hub: DataHubController
    let connectionID: String

    static let refreshEvery: Duration = .seconds(5)

    var body: some View {
        let state = hub.runs[connectionID] ?? PrefectRunsState()
        let filter = hub.filter(of: connectionID)
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.s3) {
                DSSegmented(
                    PrefectRunsFilter.allCases.map { .init($0.rawValue, LocalizedStringKey(Self.title($0))) },
                    selection: filter.rawValue, action: .dataRunsFilter, id: .dataRunsFilter)
                Spacer(minLength: DS.Space.s2)
                if let at = state.loadedAt {
                    Text(verbatim: String(localized: "Updated \(at.formatted(.dateTime.hour(DatasetsController.hourStyle(.current)).minute(.twoDigits).second(.twoDigits)))", bundle: .module))
                        .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                }
                if let saved = hub.saved.first(where: { $0.id == connectionID }) {
                    RemoveConnectionControl(hub: hub, connection: saved.id, compact: true)
                }
            }
            .padding(.horizontal, DS.Space.s4)
            .frame(height: DataMetrics.locationHeight)
            .overlay(alignment: .bottom) { DS.Color.border.frame(height: ComputersMetrics.separator) }
            if let error = state.error {
                HStack(spacing: DS.Space.s2) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: DS.Space.s3))
                    Text(verbatim: error).dsFont(DS.Font.small)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(DS.Color.warning)
                .padding(.horizontal, DS.Space.s4)
                .padding(.vertical, DS.Space.s2)
                .a11y(.dataRunsError, kind: "text", label: error)
            }
            if state.rows.isEmpty, state.error == nil {
                Text(verbatim: state.loadedAt == nil ? String(localized: "Reading the server…", bundle: .module) : Self.empty(filter))
                    .dsFont(DS.Font.body).foregroundStyle(DS.Color.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DataGridView(grid: Self.grid(state), footer: String(localized: "\(state.rows.count) flow runs · read only", bundle: .module), fit: true)
            }
        }
        .a11y(.dataRuns, kind: "table", value: "\(state.rows.count)")
        .task(id: "\(connectionID)-\(filter.rawValue)") {
            while !Task.isCancelled {
                await hub.refreshRuns(connectionID)
                try? await Task.sleep(for: Self.refreshEvery)
            }
        }
    }

    static func title(_ filter: PrefectRunsFilter) -> String {
        switch filter {
        case .running: String(localized: "Running", bundle: .module)
        case .scheduled: String(localized: "Scheduled", bundle: .module)
        case .failed: String(localized: "Failed (24 h)", bundle: .module)
        }
    }

    static func empty(_ filter: PrefectRunsFilter) -> String {
        switch filter {
        case .running: String(localized: "Nothing is running right now.", bundle: .module)
        case .scheduled: String(localized: "Nothing is scheduled.", bundle: .module)
        case .failed: String(localized: "No failures in the last 24 hours.", bundle: .module)
        }
    }

    /// Estado, run, deployment, início, duração, pool e tags; o mais recente em cima.
    static func grid(_ state: PrefectRunsState) -> DataGrid {
        let columns: [DataGrid.Column] = [
            .init(name: "state", type: "text"), .init(name: "flow run", type: "text"), .init(name: "deployment", type: "text"),
            .init(name: "started", type: "timestamptz"), .init(name: "duration", type: "text"), .init(name: "work pool", type: "text"),
            .init(name: "tags", type: "text"),
        ]
        let rows = state.rows.map { run -> [String] in
            let started = (run.start ?? run.expectedStart).map { $0.formatted(.dateTime.day().month(.abbreviated).hour().minute()) } ?? ""
            let seconds = run.end.flatMap { end in run.start.map { end.timeIntervalSince($0) } } ?? run.start.map { Date().timeIntervalSince($0) } ?? run.totalRunTime
            let duration = run.start == nil ? "" : Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
            return [run.stateName, run.name, run.deploymentID.flatMap { state.deployments[$0] } ?? "", started, duration, run.workPool ?? "", run.tags.joined(separator: ", ")]
        }
        return DataGrid(columns: columns, rows: rows, total: rows.count)
    }
}

/// Formulário de uma conexão de verdade (hoje: Prefect). Testa antes de salvar; a senha vai para o cofre do app.
struct ConnectFormView: View {
    let hub: DataHubController
    let kind: DataConnectionKind
    @State private var name = ""
    @State private var url = ""
    @State private var auth = SavedConnection.AuthKind.basic
    @State private var user = ""
    @State private var secret = ""

    private var payload: String {
        let form: [String: String] = ["name": name, "url": url, "auth": auth.rawValue, "user": user, "secret": secret]
        return (try? String(data: JSONSerialization.data(withJSONObject: form), encoding: .utf8)) ?? "{}"
    }

    @ViewBuilder var body: some View {
        if kind.speaksPostgres { postgresBody } else { prefectBody }
    }

    /// Postgres, RDS e Supabase: uma connection string, que é o segredo inteiro (vai para o cofre; o estado do app só guarda host e banco).
    private var postgresBody: some View {
        let form: [String: String] = ["name": name, "url": "", "auth": SavedConnection.AuthKind.connectionString.rawValue, "user": "", "secret": secret]
        let payload = (try? String(data: JSONSerialization.data(withJSONObject: form), encoding: .utf8)) ?? "{}"
        return VStack(alignment: .leading, spacing: DS.Space.s4) {
            HStack(spacing: DS.Space.s2_5) {
                DSDataLogo(kind.brand, size: DataMetrics.connectLogo, tile: true)
                VStack(alignment: .leading, spacing: .zero) {
                    Text(verbatim: kind.title).dsFont(DS.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary)
                    Text(verbatim: kind.tagline).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                }
            }
            field("Name (optional)") {
                DSTextField(kind == .supabase ? "e.g. Supabase prod" : "e.g. Analytics", text: $name, id: .dataConnectName, compact: true)
            }
            field("Connection string (required)") {
                DSTextField(
                    kind == .supabase
                        ? "postgresql://postgres.[ref]:[password]@…pooler.supabase.com:6543/postgres"
                        : "postgresql://user:password@host:5432/postgres",
                    text: $secret, id: .dataConnectSecret, compact: true, mono: true, secure: true)
            }
            Text(kind == .supabase
                 ? "Supabase: Project Settings → Database → Connection string (Session pooler)."
                 : "Any Postgres, RDS included. Add ?sslmode=require (TLS is always on unless the string says sslmode=disable).", bundle: .module)
                .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).fixedSize(horizontal: false, vertical: true)
            Text("Racky only reads: every query runs in a read-only transaction. The connection string stays in this Mac's secure vault.", bundle: .module)
                .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).fixedSize(horizontal: false, vertical: true)
            if let error = hub.connectError {
                HStack(spacing: DS.Space.s1_5) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: DS.Space.s3))
                    Text(verbatim: error).dsFont(DS.Font.small).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(DS.Color.destructive)
                .a11y(.dataConnectError, kind: "text", label: error)
            }
            HStack(spacing: DS.Space.s2) {
                DSButton(.dataConnectStart, id: nil, "Back", variant: .ghost, size: .sm, symbol: "chevron.left", argument: .select("close"))
                Spacer(minLength: 0)
                if hub.connectBusy { ProgressView().controlSize(.small) }
                if secret.isEmpty {
                    Label { Text("Fill in the connection string", bundle: .module) } icon: { Image(systemName: "info.circle") }
                        .dsFont(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
                }
                DSButton(.dataConnectSave, id: .dataConnectSave, "Test and connect", variant: .primary, size: .sm, argument: .set(payload))
                    .disabled(secret.isEmpty || hub.connectBusy)
            }
        }
        .a11y(.dataConnectForm, kind: "form", label: kind.title)
    }

    private var prefectBody: some View {
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            HStack(spacing: DS.Space.s2_5) {
                DSDataLogo(kind.brand, size: DataMetrics.connectLogo, tile: true)
                VStack(alignment: .leading, spacing: .zero) {
                    Text(verbatim: kind.title).dsFont(DS.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary)
                    Text(verbatim: kind.tagline).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                }
            }
            field("Name (optional)") {
                DSTextField("e.g. Prefect prod", text: $name, id: .dataConnectName, compact: true)
            }
            field("Server URL (required)") {
                DSTextField("prefect.yourcompany.com", text: $url, id: .dataConnectUrl, compact: true, mono: true)
            }
            field("Authentication") {
                // Segmentos do próprio DS (o segmentado do sistema tinha um divisor solto e a seleção quase não aparecia).
                HStack(spacing: .zero) {
                    authChoice(.basic, String(localized: "Basic auth (self-hosted)", bundle: .module))
                    authChoice(.apiKey, String(localized: "API key (Prefect Cloud)", bundle: .module))
                    authChoice(.none, String(localized: "None", bundle: .module))
                }
                .padding(DSMetrics.segmentedPadding)
                .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.Color.fg6))
                .a11y(.dataConnectAuth, kind: "segmented", value: auth.rawValue)
            }
            if auth == .basic {
                HStack(spacing: DS.Space.s2) {
                    field("User") { DSTextField("admin", text: $user, id: .dataConnectUser, compact: true) }
                    field("Password") { DSTextField("Password", text: $secret, id: .dataConnectSecret, compact: true, secure: true) }
                }
            } else if auth == .apiKey {
                field("API key") { DSTextField("pnu_…", text: $secret, id: .dataConnectSecret, compact: true, secure: true) }
            }
            Text("Racky only reads from Prefect (what runs, when, and how it ended). The password stays in this Mac's secure vault.", bundle: .module)
                .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).fixedSize(horizontal: false, vertical: true)
            if let error = hub.connectError {
                HStack(spacing: DS.Space.s1_5) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: DS.Space.s3))
                    Text(verbatim: error).dsFont(DS.Font.small).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(DS.Color.destructive)
                .a11y(.dataConnectError, kind: "text", label: error)
            }
            HStack(spacing: DS.Space.s2) {
                DSButton(.dataConnectStart, id: nil, "Back", variant: .ghost, size: .sm, symbol: "chevron.left", argument: .select("close"))
                Spacer(minLength: 0)
                if hub.connectBusy { ProgressView().controlSize(.small) }
                if url.isEmpty {
                    // O porquê do botão apagado, no tom do texto (antes era cinza claro e passava despercebido).
                    Label { Text("Fill in the server URL", bundle: .module) } icon: { Image(systemName: "info.circle") }
                        .dsFont(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
                }
                DSButton(.dataConnectSave, id: .dataConnectSave, "Test and connect", variant: .primary, size: .sm, argument: .set(payload))
                    .disabled(url.isEmpty || hub.connectBusy)
            }
        }
        .a11y(.dataConnectForm, kind: "form", label: kind.title)
    }

    private func field(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            Text(title, bundle: .module).dsFont(DS.Font.label).foregroundStyle(DS.Color.textSecondary)
            content()
        }
    }

    private func authChoice(_ kind: SavedConnection.AuthKind, _ title: String) -> some View {
        // lint-ui: allow buttons escolha local do formulário (estado da folha, sem ação de registro; o salvar passa pela ação)
        Button { auth = kind } label: { Text(verbatim: title) }
            .buttonStyle(DSSegmentStyle(active: auth == kind, fillWidth: true))
            .background {
                if auth == kind { RoundedRectangle(cornerRadius: DS.Radius.sm).fill(DS.Color.textPrimary.opacity(0.16)) }
            }
            // Borda na opção ativa: só o fundo um pouco mais claro não deixava claro qual estava escolhida.
            .overlay {
                if auth == kind { RoundedRectangle(cornerRadius: DS.Radius.sm).strokeBorder(DS.Color.textSecondary) }
            }
    }
}

/// "Remove connection" com confirmação no lugar: o primeiro clique troca o botão por "Remove connection and its saved password?"
/// com Remove e Cancel. Remover apaga a conexão e a senha do cofre.
struct RemoveConnectionControl: View {
    let hub: DataHubController
    let connection: String
    var compact = false

    var body: some View {
        if hub.confirmingRemoval == connection {
            HStack(spacing: DS.Space.s1_5) {
                Text("Remove connection and its saved password?", bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary)
                    .lineLimit(1).fixedSize()
                DSButton(.dataConnectionRemove, id: .dataConnectionRemoveCancel, "Cancel", variant: .outline, size: .xs, argument: .select("cancel"))
                DSButton(.dataConnectionRemove, id: .dataConnectionRemoveConfirm, "Remove", variant: .destructive, size: .xs, argument: .select("\(connection)|confirm"))
            }
        } else if compact {
            ActionButton(.dataConnectionRemove, id: .dataConnectionRemove, argument: .select(connection), tooltip: String(localized: "Remove connection", bundle: .module)) {
                Image(systemName: "trash")
            }
            .buttonStyle(DSIconButtonStyle(.header))
        } else {
            DSButton(.dataConnectionRemove, id: .dataConnectionRemove, "Remove connection", variant: .outline, size: .sm, symbol: "trash", argument: .select(connection))
        }
    }
}
