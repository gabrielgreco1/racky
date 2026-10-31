import RackyCore
import RackyDesignSystem
import RackyProtocol
import AppKit
import ImageIO
import SwiftUI

/// Imagem decodificada fora do main thread (audit/09 N13). `CGImage` é imutável.
struct DecodedThumbnail: @unchecked Sendable {  // SAFETY: CGImage é imutável depois de criada.
    let image: CGImage
}

/// Decodifica o JPEG da miniatura num ator próprio: o main thread nunca decodifica.
actor ThumbnailDecoder {
    static let shared = ThumbnailDecoder()
    func decode(_ data: Data) -> DecodedThumbnail? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return DecodedThumbnail(image: image)
    }
}

enum ComputersMetrics {
    static let pageHeader = DS.Space.s8 + DS.Space.s1
    static let rowHeight = DS.Space.s8 + DS.Space.s4
    static let tableHeader = DS.Layout.paneHeaderHeight + DS.Space.s1
    static let thumbWidth: CGFloat = 286
    static let thumbHeight: CGFloat = 179
    static let rowThumbWidth: CGFloat = 64
    static let rowThumbHeight: CGFloat = 40
    static let stateBorder: CGFloat = 1.5
    static let separator: CGFloat = 1
    static let needsBand = DS.Space.s6
    static let colName: CGFloat = 160
    /// O nome estica até aqui de mínimo antes de uma coluna sair.
    static let colNameMin: CGFloat = 140
    /// Lugar dos botões `Result` e `Open Run Folder`, que ficam por cima da ponta direita da linha.
    static let rowActions: CGFloat = 196
    static let leftoversRow = DS.Space.s8 + DS.Space.s1
    static let leftoversActions: CGFloat = 120
    static let leftoversSize: CGFloat = 56
    static let colSession: CGFloat = 140
    static let colMode: CGFloat = 80
    static let colState: CGFloat = 110
    static let colLease: CGFloat = 90
    static let colProxy: CGFloat = 100
    static let colAge: CGFloat = 90
}

/// Miniatura (DS §12.25): frame vivo (≤ 1 fps), borda de estado, rodapé com nome e estado; faixa laranja com `Needs you · CAPTCHA`.
struct ComputerThumbnailView: View {
    let row: ComputerRow
    var compact = false
    @State private var decoded: DecodedThumbnail?

    private var border: Color {
        if row.needsYou { return DS.Color.agentNeedsInput }
        switch row.snapshot.control {
        case .human: return DS.Color.textPrimary
        case .revoking: return DS.Color.fg10
        case .agent: return row.snapshot.state == .inUse ? DS.Color.fg18 : DS.Color.border
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                DS.Color.canvas
                if let decoded {
                    Image(decorative: decoded.image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: row.snapshot.display == "http" ? "network" : "display").foregroundStyle(DS.Color.textQuaternary)
                }
                if let help = row.snapshot.help {
                    HStack(spacing: DS.Space.s2) {
                        Text(verbatim: "Needs you · \(help.kind.rawValue.uppercased())").dsFont(DS.Font.label).foregroundStyle(DS.Color.textOnPrimary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, DS.Space.s2)
                    .frame(height: ComputersMetrics.needsBand)
                    .background(DS.Color.agentNeedsInput)
                }
            }
            .frame(height: compact ? ComputersMetrics.rowThumbHeight : ComputersMetrics.thumbHeight)
            if !compact {
                HStack(spacing: DS.Space.s1_5) {
                    Text(verbatim: row.snapshot.name).dsFont(DS.Font.label).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                    Spacer(minLength: DS.Space.s1)
                    Text(verbatim: stateText).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                }
                .padding(.horizontal, DS.Space.s2)
                .frame(height: DS.Space.s6 - DS.Space.s1)
                .background(DS.Color.chrome)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).strokeBorder(border, lineWidth: ComputersMetrics.stateBorder))
        .task(id: row.thumbnail?.count ?? 0) {
            guard let data = row.thumbnail else { return }
            decoded = await ThumbnailDecoder.shared.decode(data)
        }
    }

    private var stateText: String {
        if row.snapshot.control == .human { return String(localized: "You're in control", bundle: .module) }
        switch row.snapshot.state {
        case .inUse: return String(localized: "In use", bundle: .module)
        case .ready: return String(localized: "Ready", bundle: .module)
        case .stopped: return String(localized: "Stopped", bundle: .module)
        case .queued: return String(localized: "Queued", bundle: .module)
        case .provisioning: return String(localized: "Starting", bundle: .module)
        case .failed: return String(localized: "Failed", bundle: .module)
        }
    }
}

// MARK: Painel direito: aba Computers (03 §10.4)

/// Corpo do módulo Computers do painel direito (03 §10.4). O header (título e resumo) é do contêiner (`ComputersModule`).
struct ComputersPanelView: View {
    let controller: ComputersController

    var body: some View {
        if let detail = controller.detail {
            ComputerDetailView(controller: controller, detail: detail)
        } else {
            list
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: DS.Space.s3) {
                if controller.model.rows.isEmpty {
                    Text("No computers in this session. Agents create them when they need a browser.", bundle: .module)
                        .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).multilineTextAlignment(.center)
                        .padding(DS.Space.s4)
                        .a11y(.rightPanelComputersEmpty, kind: "text")
                }
                ForEach(controller.model.rows) { row in
                    ZStack(alignment: .bottomTrailing) {
                        ActionButton(.computerOpenViewer, argument: .select(row.id)) {
                            ComputerThumbnailView(row: row)
                        }
                        .buttonStyle(.plain)
                        if row.snapshot.control == .agent {
                            DSButton(.computerTakeOver, id: .rightPanelComputersThumbTakeOver(row.id), "Take Over", variant: .primary, size: .xs, argument: .select(row.id))
                                .padding(.trailing, DS.Space.s2).padding(.bottom, DS.Space.s8)
                        }
                    }
                    .a11y(.rightPanelComputersThumb(row.id), kind: "thumbnail", label: row.id, value: row.snapshot.control.rawValue)
                }
            }
            .padding(DS.Space.s3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Color.panel)
    }
}

// MARK: Página Computers (03 §12.3)

struct PageHeader<Trailing: View>: View {
    let title: Text
    let trailing: Trailing
    /// Canto dos botões Files · Insights · painel da janela (overlay): o header não passa por baixo deles.
    @Environment(\.pageTrailingInset) private var trailingInset

    init(title: LocalizedStringKey, @ViewBuilder trailing: () -> Trailing) {
        self.title = Text(title, bundle: .module)
        self.trailing = trailing()
    }

    /// Título já montado (nome do lote).
    init(verbatim title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = Text(verbatim: title)
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: DS.Space.s2) {
            title.dsFont(DS.Font.sectionLabel).foregroundStyle(DS.Color.textPrimary)
            Spacer(minLength: DS.Space.s2)
            trailing
            ActionButton(.pageClose, tooltip: String(localized: "Close", bundle: .module)) { Image(systemName: "xmark") }
                .buttonStyle(DSIconButtonStyle(.header))
        }
        .padding(.leading, DS.Space.s3)
        .padding(.trailing, DS.Space.s3 + trailingInset)
        .frame(height: ComputersMetrics.pageHeader)
        .background(DS.Color.chrome)
        .overlay(alignment: .bottom) { DS.Color.border.frame(height: ComputersMetrics.separator) }
    }
}

struct ComputersPageView: View {
    let controller: ComputersController
    let settings: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Computers") {
                Text(verbatim: controller.model.summaryText).dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary)
                DSIconButton(.batchNew, id: .computersNewBatch, symbol: "plus", name: String(localized: "Start a new batch", bundle: .module), variant: .header)
            }
            if controller.model.rows.isEmpty {
                // Sem computadores: a página é a escolha de onde eles rodam (BK-12); o vazio vira uma linha embaixo.
                // Rola junto com Left on disk: com dezenas de runs terminados a lista passava da janela e empurrava o header pra fora.
                ScrollView {
                    VStack(spacing: 0) {
                        ComputersWhereView(
                            settings: settings, compact: false,
                            emptyNote: AnyView(
                                Text("No computers yet. Agents create them when they need a browser.", bundle: .module)
                                    .dsFont(DS.Font.small).foregroundStyle(DS.Color.textQuaternary)
                                    .a11y(.computersEmpty, kind: "text")),
                            embedded: true)
                        // Na mesma coluna da escolha de cima.
                        LeftoversSection(controller: controller, columns: ComputersColumns.fitting(WhereMetrics.column))
                            .frame(width: WhereMetrics.column)
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, DS.Space.s10)
                    }
                }
                .frame(maxHeight: .infinity)
            } else {
                ComputersWhereView(settings: settings, compact: true)
                GeometryReader { proxy in
                    let columns = ComputersColumns.fitting(proxy.size.width)
                    VStack(spacing: 0) {
                        header(columns)
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(controller.model.rows) { row in
                                    ZStack(alignment: .trailing) {
                                        ActionButton(.computerOpenViewer, argument: .select(row.id)) { ComputersRow(row: row, columns: columns) }
                                            .buttonStyle(DSListRowStyle())
                                            .a11y(.computersRow(row.id), kind: "row", label: row.id, value: row.snapshot.control.rawValue)
                                        // Irmãos da linha (botão dentro de botão não clica): `Result` (03 §11.7) e `Open Run Folder` (AC-420).
                                        HStack(spacing: DS.Space.s1) {
                                            DSButton(.computerShowTab, id: .computersRowResult(row.id), "Result", variant: .ghost, size: .xs, argument: .select(row.id))
                                            DSButton(.computerOpenRunFolder, id: .computersRowRunFolder(row.id), "Open Run Folder", variant: .ghost, size: .xs, argument: .select(row.id))
                                        }
                                        .padding(.trailing, DS.Space.s3)
                                    }
                                }
                                LeftoversSection(controller: controller, columns: columns).padding(DS.Space.s3).padding(.top, DS.Space.s2)
                            }
                        }
                    }
                }
            }
        }
        .background(DS.Color.canvas)
        .task { await controller.refreshLeftovers() }
        .onChange(of: controller.model.rows.count) { Task { await controller.refreshLeftovers() } }
        .a11y(.computersPage, kind: "page")
    }

    private func header(_ columns: ComputersColumns) -> some View {
        HStack(spacing: DS.Space.s2) {
            Color.clear.frame(width: ComputersMetrics.rowThumbWidth)
            Text("Name", bundle: .module).dsFont(DS.Font.label).foregroundStyle(DS.Color.textSecondary)
                .frame(minWidth: ComputersMetrics.colNameMin, maxWidth: .infinity, alignment: .leading)
            if columns.shows(.session) { column("Session", ComputersMetrics.colSession) }
            if columns.shows(.mode) { column("Mode", ComputersMetrics.colMode) }
            column("State", ComputersMetrics.colState)
            if columns.shows(.lease) { column("Lease", ComputersMetrics.colLease) }
            if columns.shows(.proxy) { column("Proxy", ComputersMetrics.colProxy) }
            if columns.shows(.age) { column("Last Used", ComputersMetrics.colAge) }
            Color.clear.frame(width: ComputersMetrics.rowActions)
        }
        .padding(.horizontal, DS.Space.s3)
        .frame(height: ComputersMetrics.tableHeader)
        .overlay(alignment: .bottom) { DS.Color.border.frame(height: ComputersMetrics.separator) }
    }

    private func column(_ title: LocalizedStringKey, _ width: CGFloat) -> some View {
        Text(title, bundle: .module).dsFont(DS.Font.label).foregroundStyle(DS.Color.textSecondary).frame(width: width, alignment: .leading)
    }
}

struct ComputersRow: View {
    let row: ComputerRow
    var columns = ComputersColumns.all

    var body: some View {
        HStack(spacing: DS.Space.s2) {
            ComputerThumbnailView(row: row, compact: true).frame(width: ComputersMetrics.rowThumbWidth)
            HStack(spacing: DS.Space.s2) {
                Text(verbatim: row.snapshot.name).dsFont(DS.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary).lineLimit(1).truncationMode(.middle)
                if row.needsYou {
                    Text("Needs You", bundle: .module).dsFont(DS.Font.label).foregroundStyle(DS.Color.agentNeedsInputText).fixedSize()
                }
            }
            .frame(minWidth: ComputersMetrics.colNameMin, maxWidth: .infinity, alignment: .leading)
            if columns.shows(.session) { cell(row.sessionTitle ?? "—", ComputersMetrics.colSession) }
            if columns.shows(.mode) { cell(row.snapshot.display.capitalized, ComputersMetrics.colMode) }
            cell(state, ComputersMetrics.colState)
            if columns.shows(.lease) {
                cell(row.snapshot.control == .human ? String(localized: "You", bundle: .module) : String(localized: "Agent", bundle: .module), ComputersMetrics.colLease)
            }
            if columns.shows(.proxy) { cell(row.snapshot.proxy, ComputersMetrics.colProxy) }
            if columns.shows(.age) { cell(row.lastActivity.formatted(.relative(presentation: .numeric)), ComputersMetrics.colAge) }
            Color.clear.frame(width: ComputersMetrics.rowActions)
        }
        .padding(.horizontal, DS.Space.s3)
        .frame(height: ComputersMetrics.rowHeight)
    }

    private var state: String {
        row.snapshot.state == .inUse ? String(localized: "In use", bundle: .module) : row.snapshot.state.rawValue.capitalized
    }

    private func cell(_ text: String, _ width: CGFloat, strong: Bool = false) -> some View {
        Text(verbatim: text).dsFont(strong ? DS.Font.bodyStrong : DS.Font.body).foregroundStyle(strong ? DS.Color.textPrimary : DS.Color.textSecondary)
            .lineLimit(1).frame(width: width, alignment: .leading)
    }
}

/// Colunas da tabela que cabem na largura da página. O nome estica; quando falta lugar saem primeiro as de menos peso (Lease, Mode,
/// Proxy, Session, Last Used) e a ponta direita fica sempre livre para os botões da linha. Antes as larguras eram fixas: com os dois
/// painéis abertos a tabela passava da coluna do meio, cortava o nome e os botões, e `Last Used` ficava por baixo de `Open Run Folder`.
struct ComputersColumns: Equatable {
    enum Column: CaseIterable { case session, mode, lease, proxy, age }

    var hidden: Set<Column> = []

    static let all = ComputersColumns()
    static let dropOrder: [Column] = [.lease, .mode, .proxy, .session, .age]

    func shows(_ column: Column) -> Bool { !hidden.contains(column) }

    static func width(_ column: Column) -> CGFloat {
        switch column {
        case .session: ComputersMetrics.colSession
        case .mode: ComputersMetrics.colMode
        case .lease: ComputersMetrics.colLease
        case .proxy: ComputersMetrics.colProxy
        case .age: ComputersMetrics.colAge
        }
    }

    /// Largura que a linha pede com estas colunas (nome no mínimo).
    var required: CGFloat {
        let fixed = [ComputersMetrics.rowThumbWidth, ComputersMetrics.colNameMin, ComputersMetrics.colState, ComputersMetrics.rowActions]
        let optional = Column.allCases.filter(shows).map(Self.width)
        let cells = fixed + optional
        return cells.reduce(0, +) + DS.Space.s2 * CGFloat(cells.count - 1) + DS.Space.s3 * 2
    }

    static func fitting(_ width: CGFloat) -> ComputersColumns {
        var columns = ComputersColumns.all
        for column in dropOrder where columns.required > width { columns.hidden.insert(column) }
        return columns
    }
}

extension EnvironmentValues {
    /// Largura reservada à direita do header de página para os botões da janela (com o painel direito fechado).
    @Entry var pageTrailingInset: CGFloat = 0
}

/// Repassa a largura dos botões da janela às páginas enquanto o painel direito está fechado (com ele aberto os botões ficam sobre ele).
struct PageInsetReader<Content: View>: View {
    let rightPanel: RightPanelController?
    let content: Content

    var body: some View {
        content.environment(\.pageTrailingInset, rightPanel.map { $0.isContentVisible ? 0 : RightPanelMetrics.stripButtons } ?? 0)
    }
}
