import RackyCore
import RackyDesignSystem
import RackyProtocol
import RackyStore
import SwiftUI

// A página Data (spec data-hub): explorer à esquerda (Racky e Connections), tabs dos objetos abertos e, em cima de cada objeto, a
// barra de localização (onde estou, o que é) e a linha de fluxo (quem grava aqui, para onde isto vai).

enum DataMetrics {
    /// Traço do colchete que liga a seta do fluxo a cada destino.
    static let branchLine: CGFloat = 1
    /// Painel de Overview/Structure/Who writes here aberto em cima da grade (a grade continua visível embaixo).
    static let panelHeight: CGFloat = 360
    static let panelMinHeight: CGFloat = 160
    static let explorerMin: CGFloat = 200
    /// Abaixo disso a lista se recolhe sozinha (com o painel direito aberto numa janela de 1440 ainda sobram ~510).
    static let contentMin: CGFloat = 480
    static let explorerTitleMin: CGFloat = 100
    static let collapsedStripFallback: CGFloat = 220
    static let explorerMax: CGFloat = 520
    static let resizeHandle: CGFloat = 2
    static let rowHeight = DS.Space.s6 + DS.Space.s0_5
    static let indent = DS.Space.s3 + DS.Space.s0_5
    static let tabHeight = DS.Space.s8 + DS.Space.s1
    static let tabMaxWidth: CGFloat = 220
    static let locationHeight: CGFloat = 52
    static let flowHeight = DS.Space.s8 + DS.Space.s1
    static let icon: CGFloat = 12
    static let chipHeight = DS.Space.s6
    static let liveDot: CGFloat = 6
    static let markSize: CGFloat = 18
    static let pathHeight: CGFloat = 34
    static let tabsMenuWidth: CGFloat = 64
    /// Nome de uma tab inativa quando a faixa não cabe (encurta com "…" antes de rolar).
    static let tabTitleShort: CGFloat = 76
    static let tabTitleTiny: CGFloat = 60
    static let tabsBeforeMenu = 3
    static let renameInset: CGFloat = 64
    static let logoTile: CGFloat = 20
    static let badgePadding: CGFloat = 1
    static let underline: CGFloat = 2
    static let emptyTextWidth: CGFloat = 440
    static let previewWidth: CGFloat = 460
    static let connectWidth: CGFloat = 760
    static let connectHeight: CGFloat = 820
    static let connectMargin: CGFloat = 80
    static let connectCard: CGFloat = 56
    static let connectCardCompact: CGFloat = 40
    static let connectLogo: CGFloat = 32
    static let editorHeight: CGFloat = 160
}

/// Ícones por tipo de lugar e de objeto (mesmos no explorer, nas tabs e na barra de localização).
enum DataSymbols {
    static func connection(_ kind: DataConnectionKind) -> String {
        switch kind.family {
        case .database: "cylinder.split.1x2"
        case .warehouse: "square.stack.3d.up"
        case .storage: "archivebox"
        case .spreadsheet: "tablecells.badge.ellipsis"
        case .outgoing: "paperplane"
        case .orchestrator: "flowchart"
        }
    }

    static func node(_ kind: DataNode.Kind) -> String {
        switch kind {
        case .schema: "folder"
        case .table: "tablecells"
        case .view: "eye"
        case .bucket: "archivebox"
        case .folder: "folder"
        case .file: "doc"
        case .spreadsheet: "doc.richtext"
        case .sheet: "tablecells"
        case .runs: "flowchart"
        }
    }

    static func object(_ object: DataObject) -> String {
        switch object {
        case .dataset: "tablecells"
        case .table: "tablecells"
        case .query: "terminal"
        case .folder: "folder"
        case .webhook: "paperplane"
        case .tab: "tablecells"
        case .runs: "flowchart"
        case .notebook: "book.pages"
        }
    }
}

struct DataPageView: View {
    let hub: DataHubController
    var shell: ShellModel?

    /// Com a sidebar recolhida, a faixa da janela (semáforos, nome) flutua no canto: o topo começa depois dela.
    private var topLeading: CGFloat {
        guard let shell, shell.sidebarCollapsed else { return 0 }
        // Sem a medida ainda (primeiro layout), reserva o tamanho típico da faixa: nunca deixar o conteúdo por baixo dos semáforos.
        return max(shell.titlebarStripWidth, DataMetrics.collapsedStripFallback)
    }

    @State private var width: CGFloat = .infinity

    /// Pouco espaço para o conteúdo: o explorer se recolhe sozinho (volta quando a janela abre).
    private var activeIsDemoProtected: Bool {
        guard let active = hub.active, let connection = hub.connection(active.connectionID) else { return false }
        return connection.protected && !hub.saved.contains { $0.id == connection.id }
    }

    private var explorerShown: Bool { !hub.explorerHidden && (hub.explorerForced || width - hub.explorerWidth >= DataMetrics.contentMin) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                DataExplorerHeader(hub: hub, leading: topLeading, shown: explorerShown)
                DataTabStrip(hub: hub)
            }
            .frame(height: DataMetrics.tabHeight)
            .background(DS.Color.chrome)
            .overlay(alignment: .bottom) { DS.Color.border.frame(height: ComputersMetrics.separator) }
            // Na tabela de exemplo protegida a faixa âmbar já diz "Example · Protected": as duas faixas não se empilham.
            if hub.isDemo, !activeIsDemoProtected { DataDemoBanner(hasOwn: !hub.saved.isEmpty) }
            HStack(spacing: 0) {
                if explorerShown {
                    DataExplorer(hub: hub)
                        .frame(width: max(hub.explorerWidth, topLeading + DataMetrics.explorerTitleMin))
                        .overlay(alignment: .trailing) { DataExplorerResizeHandle(hub: hub) }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                VStack(spacing: 0) {
                    if let active = hub.active {
                        if hub.connection(active.connectionID)?.protected == true { DataProductionBanner(hub: hub, object: active) }
                        DataLocationBar(hub: hub, object: active)
                        switch active {
                        case .dataset: EmptyView()  // a página do dataset desenha o caminho e as abas
                        case .runs: EmptyView()  // orquestrador: só leitura do que roda, não há caminho de dado
                        case .notebook: EmptyView()  // notebook: a lista de datasets à esquerda já diz de onde vem
                        case .table:
                            // Tabela que o Racky não alimenta não tem caminho: a frase ao lado das abas já diz isso.
                            if hub.copySource(of: active) != nil { DataLineageStrip(hub: hub, object: active, compact: true) }
                        default: DataLineageStrip(hub: hub, object: active)
                        }
                        DataObjectView(hub: hub, object: active)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .a11y(.dataObject, kind: "container", label: active.key)
                    } else {
                        DataEmptyState(hub: hub)
                    }
                }
                .frame(minWidth: .zero, maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            }
        }
        .animation(MotionPolicy.shared.animation(MotionTokens.Easing.standard, MotionTokens.Duration.base), value: explorerShown)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(DS.Color.canvas)
        .overlay {
            if hub.showingConnect { DataConnectSheet(hub: hub) }
        }
        // Saiu da área Data: a próxima vez que abrir pela barra lateral não mostra "‹ Session".
        .onDisappear { hub.cameFromSession = false }
        .a11y(.dataPage, kind: "page")
        .task { await hub.datasets.reloadList() }
        // Na área Data a prévia "Data" do painel direito seria a mesma coisa duas vezes: ela se recolhe.
        .onAppear { hub.datasets.hideDataPanel() }
    }
}

/// Topo do explorer, na mesma faixa das tabs: o título "Data" e o botão de recolher. Recolhido, sobra só o botão.
struct DataExplorerHeader: View {
    let hub: DataHubController
    let leading: CGFloat
    var shown = true

    var body: some View {
        HStack(spacing: DS.Space.s2) {
            // Chegou aqui de dentro de uma sessão (a trilha da tabela): o caminho de volta fica à vista.
            if hub.cameFromSession {
                ActionButton(.pageClose, id: .dataBackToSession, tooltip: String(localized: "Back to the session", bundle: .module)) {
                    HStack(spacing: DS.Space.s1) {
                        Image(systemName: "chevron.left").font(.system(size: DS.Space.s2_5, weight: .semibold))
                        Text("Session", bundle: .module).dsFont(DS.Font.label)
                    }
                    .foregroundStyle(DS.Color.textSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
            if shown {
                Text("Data", bundle: .module).dsFont(DS.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary)
                Spacer(minLength: 0)
            }
            ActionButton(
                .dataToggleExplorer, id: .dataExplorerToggle, argument: .select(shown ? "hide" : "show"),
                tooltip: !shown ? String(localized: "Show explorer", bundle: .module) : String(localized: "Hide explorer", bundle: .module)
            ) {
                if shown {
                    Image(systemName: "list.bullet.rectangle")
                } else {
                    // Recolhido: o botão diz o que volta ("Data", a lista de datasets e conexões).
                    HStack(spacing: DS.Space.s1) {
                        Image(systemName: "list.bullet.rectangle").font(.system(size: DS.Space.s3))
                        Text("Show Data list", bundle: .module).dsFont(DS.Font.label)
                    }
                    // Cara de botão (contorno, altura de controle), não de tab.
                    .foregroundStyle(DS.Color.textPrimary)
                    .padding(.horizontal, DS.Space.s2)
                    .frame(height: DataMetrics.chipHeight)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.Color.chrome))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(DS.Color.borderStrong))
                    .contentShape(Rectangle())
                }
            }
                .buttonStyle(ExplorerToggleStyle(shown: shown))
                .fixedSize()
        }
        .padding(.leading, max(leading, DS.Space.s3))
        .padding(.trailing, DS.Space.s1_5)
        .frame(width: shown ? max(hub.explorerWidth, leading + DataMetrics.explorerTitleMin) : nil, alignment: .leading)
        .frame(maxHeight: .infinity)
        // Recolhido, sobra só o botão de reabrir: ele nunca pode ser espremido pelas tabs.
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(2)
        .overlay(alignment: .trailing) { DS.Color.border.frame(width: ComputersMetrics.separator) }
    }
}

/// Aberto, o botão é um ícone como os outros do cabeçalho; recolhido, é um botão com rótulo (o estilo de ícone cortaria o texto).
private struct ExplorerToggleStyle: ButtonStyle {
    let shown: Bool

    func makeBody(configuration: Configuration) -> some View {
        if shown {
            DSIconButtonStyle(.header).makeBody(configuration: configuration)
        } else {
            configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
        }
    }
}

/// Borda do explorer: arrastar muda a largura (200 a 520 pt).
struct DataExplorerResizeHandle: View {
    let hub: DataHubController
    @State private var start: CGFloat?
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(hovering || start != nil ? DS.Color.borderStrong : Color.clear)
            .frame(width: DataMetrics.resizeHandle)
            .contentShape(Rectangle().inset(by: -DataMetrics.resizeHandle))
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let base = start ?? hub.explorerWidth
                        if start == nil { start = base }
                        hub.explorerWidth = min(max(base + drag.translation.width, DataMetrics.explorerMin), DataMetrics.explorerMax)
                    }
                    .onEnded { _ in start = nil }
            )
            .a11y(.dataExplorerResize, kind: "splitter", value: "\(Int(hub.explorerWidth))")
    }
}

// MARK: Explorer

struct DataExplorer: View {
    let hub: DataHubController
    @Environment(\.actionRegistry) private var registry

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.s1) {
                    section(String(localized: "On this Mac", bundle: .module), caption: String(localized: "Saved by Racky as your agents collect", bundle: .module), id: "racky")
                    racky
                    section(String(localized: "Connections", bundle: .module), caption: String(localized: "Your databases and services", bundle: .module), id: "connections")
                        .padding(.top, DS.Space.s3)
                    connections
                }
                .padding(.horizontal, DS.Space.s2)
                .padding(.vertical, DS.Space.s3)
            }
            ActionButton(.dataAddConnection, id: .dataAddConnection, argument: .press) {
                HStack(spacing: DS.Space.s1_5) {
                    Image(systemName: "plus").font(.system(size: DS.Space.s2_5, weight: .semibold))
                    Text("Add connection", bundle: .module).dsFont(DS.Font.label)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(DS.Color.textSecondary)
                .padding(.horizontal, DS.Space.s3)
                .frame(height: DataMetrics.tabHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .top) { DS.Color.border.frame(height: ComputersMetrics.separator) }
        }
        .background(DS.Color.chrome)
        .overlay(alignment: .trailing) { DS.Color.border.frame(width: ComputersMetrics.separator) }
        .a11y(.dataExplorer, kind: "tree")
    }

    private func section(_ title: String, caption: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: .zero) {
            Text(verbatim: title.uppercased()).dsFont(DS.Font.micro).tracking(0.6).foregroundStyle(DS.Color.textTertiary)
            Text(verbatim: caption).dsFont(DS.Font.small).foregroundStyle(DS.Color.textQuaternary).lineLimit(1)
        }
        .padding(.horizontal, DS.Space.s2)
        .padding(.bottom, DS.Space.s1)
        .a11y(.dataExplorerSection(id), kind: "header", label: title)
    }

    // MARK: Racky

    @ViewBuilder private var racky: some View {
        let groups = hub.rackyGroups
        if groups.isEmpty {
            Text("No datasets yet. Agents create them when they collect data.", bundle: .module)
                .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                .padding(.horizontal, DS.Space.s2)
        }
        ForEach(groups, id: \.session) { group in
            let node = "racky/\(group.session)"
            let open = !hub.expanded.contains(node)  // sessões abertas por padrão
            row(id: node, depth: 0, mark: .agent(QuickLaunchModel.kind(group.datasets.first.flatMap { hub.datasets.sessionAgent($0.dataset.sessionID) } ?? .claude)), title: group.session, detail: nil, chevron: open, toggle: node, live: false, selected: false, open: nil)
            if open {
                ForEach(group.datasets, id: \.dataset.id) { summary in
                    let object = DataObject.dataset(summary.dataset.id)
                    if hub.renaming == summary.dataset.id, hub.renamingIn == "explorer" {
                        DatasetRenameField(hub: hub, id: summary.dataset.id, initial: hub.datasets.displayName(summary))
                            .padding(.leading, DataMetrics.renameInset)
                            .frame(height: DataMetrics.rowHeight)
                    } else {
                        row(id: object.key, depth: 1, mark: .symbol("tablecells", DS.Color.dataValid), title: hub.datasets.displayName(summary), detail: summary.rowCount.formatted(),
                            chevron: nil, toggle: nil, live: hub.datasets.isCollecting(summary), selected: hub.active == object, open: object)
                            .simultaneousGesture(TapGesture(count: 2).onEnded { _ = registry.map { r in Task { _ = try? await r.perform(.dataRenameDataset, .select("@explorer:\(summary.dataset.id)")) } } })
                            // Arrastar para um notebook põe o dataset na lista dele (o "Load into notebook" carrega).
                            .draggable(NotebookDrop.payload(summary.dataset.id)) {
                                Label(hub.datasets.displayName(summary), systemImage: "tablecells").dsFont(DS.Font.label)
                                    .padding(.horizontal, DS.Space.s2).padding(.vertical, DS.Space.s1)
                                    .background(DS.Color.panel, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
                            }
                            .help(summary.dataset.name == hub.datasets.displayName(summary) ? "" : String(localized: "Agents write to it as \(summary.dataset.name)", bundle: .module))
                    }
                }
            }
        }
    }

    // MARK: Conexões

    @ViewBuilder private var connections: some View {
        if hub.connections.isEmpty {
            Text("Connect a database, a bucket or a spreadsheet to browse it here and let agents write to it.", bundle: .module)
                .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                .padding(.horizontal, DS.Space.s2)
        }
        ForEach(hub.connections) { connection in
            let open = hub.expanded.contains(connection.id)
            let target: DataObject? = connection.kind == .webhook ? .webhook(connection: connection.id) : nil
            HStack(spacing: 0) {
                row(id: connection.id, depth: 0, mark: .brand(connection.kind.brand), title: connection.name, detail: nil,
                    chevron: connection.kind.canBrowse ? open : nil, toggle: connection.kind.canBrowse ? connection.id : nil,
                    live: target.map(hub.isLive) ?? false, selected: target != nil && hub.active == target, open: target,
                    badge: connection, subtitle: connection.kind.title == connection.name ? nil : connection.kind.title)
            }
            if open {
                ForEach(connection.children) { child in nodeRows(child, connection: connection, depth: 1, path: []) }
                if let status = catalogStatus(connection) {
                    Text(verbatim: status.text).dsFont(DS.Font.small).foregroundStyle(status.error ? DS.Color.warning : DS.Color.textTertiary)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, DS.Space.s1 + (DataMetrics.indent + DataMetrics.indent)).padding(.trailing, DS.Space.s2).padding(.vertical, DS.Space.s1)
                        .a11y(.dataExplorerNode("\(connection.id)/status"), kind: "text", label: status.text)
                }
                if connection.kind.speaksSQL {
                    ActionButton(.dataNewQuery, id: .dataExplorerNode("\(connection.id)/query"), argument: .select(connection.id)) {
                        rowLabel(depth: 1, mark: .symbol("plus.rectangle", nil), title: String(localized: "New SQL query", bundle: .module), detail: nil, chevron: nil,
                                 live: false, selected: false, badge: nil, subtitle: nil, muted: true)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// O que dizer sob uma conexão Postgres aberta: lendo, erro ou vazia.
    private func catalogStatus(_ connection: DataConnection) -> (text: String, error: Bool)? {
        guard hub.isLivePostgres(connection.id) else { return nil }
        let state = hub.catalogs[connection.id]
        if let error = state?.error { return (error, true) }
        if state?.schemas == nil { return (String(localized: "Reading schemas…", bundle: .module), false) }
        if connection.children.allSatisfy({ $0.children.isEmpty }) { return (String(localized: "No tables in this database.", bundle: .module), false) }
        return nil
    }

    private func nodeRows(_ node: DataNode, connection: DataConnection, depth: Int, path: [String]) -> AnyView {
        let open = hub.expanded.contains(node.id)
        let object = Self.object(for: node, connection: connection, path: path)
        let expandable = node.lazy || !node.children.isEmpty
        let liveS3 = hub.isLiveS3(connection.id)
        return AnyView(VStack(alignment: .leading, spacing: 0) {
            row(id: node.id, depth: depth, mark: .symbol(DataSymbols.node(node.kind), nil), title: node.name, detail: node.size.map { $0.formatted() },
                chevron: expandable ? open : nil, toggle: expandable && (object == nil || liveS3) ? node.id : nil,
                live: object.map(hub.isLive) ?? false, selected: object != nil && hub.active == object, open: object)
            if open {
                ForEach(node.children) { child in nodeRows(child, connection: connection, depth: depth + 1, path: path + [node.name]) }
            }
        })
    }

    /// O que abre ao clicar no nó (schema e planilha só expandem).
    static func object(for node: DataNode, connection: DataConnection, path: [String]) -> DataObject? {
        switch node.kind {
        case .table, .view: .table(connection: connection.id, schema: path.last ?? "", name: node.name)
        case .folder, .bucket: .folder(connection: connection.id, path: path + [node.name])
        case .sheet: .tab(connection: connection.id, spreadsheet: path.last ?? "", name: node.name)
        case .runs: .runs(connection: connection.id)
        case .schema, .spreadsheet, .file: nil
        }
    }

    @ViewBuilder
    private func row(
        id: String, depth: Int, mark: DataMark, title: String, detail: String?, chevron: Bool?, toggle: String?, live: Bool, selected: Bool,
        open: DataObject?, badge: DataConnection? = nil, subtitle: String? = nil
    ) -> some View {
        let label = rowLabel(depth: depth, mark: mark, title: title, detail: detail, chevron: chevron, live: live, selected: selected, badge: badge, subtitle: subtitle)
        HStack(spacing: 0) {
            if let open {
                ActionButton(.dataOpen, id: .dataExplorerNode(id), argument: .select(open.key)) { label }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded { if let toggle, !hub.expanded.contains(toggle) { hub.toggle(toggle) } })
            } else if let toggle {
                ActionButton(.dataToggleNode, id: .dataExplorerNode(id), argument: .select(toggle)) { label }
                    .buttonStyle(.plain)
            } else {
                label.a11y(.dataExplorerNode(id), kind: "row", label: title)
            }
        }
    }

    private func rowLabel(
        depth: Int, mark: DataMark, title: String, detail: String?, chevron: Bool?, live: Bool, selected: Bool, badge: DataConnection?,
        subtitle: String?, muted: Bool = false
    ) -> some View {
        HStack(spacing: DS.Space.s1_5) {
            Group {
                if let chevron {
                    Image(systemName: "chevron.right").font(.system(size: DS.Space.s2, weight: .semibold))
                        .rotationEffect(.degrees(chevron ? 90 : 0))
                } else {
                    Color.clear
                }
            }
            .foregroundStyle(DS.Color.textTertiary)
            .frame(width: DS.Space.s2_5)
            DataMarkView(mark: mark, muted: muted)
            // O nome vem primeiro e corta no fim; o tipo da conexão some antes de cortar o nome.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.Space.s1_5) {
                    Text(verbatim: title).dsFont(DS.Font.cell).foregroundStyle(muted ? DS.Color.textTertiary : DS.Color.textPrimary).lineLimit(1).fixedSize()
                    if let subtitle { Text(verbatim: subtitle).dsFont(DS.Font.small).foregroundStyle(DS.Color.textQuaternary).lineLimit(1).fixedSize() }
                }
                Text(verbatim: title).dsFont(DS.Font.cell).foregroundStyle(muted ? DS.Color.textTertiary : DS.Color.textPrimary).lineLimit(1).truncationMode(.tail)
            }
            if let badge { ConnectionBadges(badge) }
            Spacer(minLength: DS.Space.s1)
            if live { LiveDot() }
            if let detail { Text(verbatim: detail).dsFont(DS.Font.monoMicro).foregroundStyle(DS.Color.textTertiary) }
        }
        .padding(.leading, DS.Space.s1 + CGFloat(depth) * DataMetrics.indent)
        .padding(.trailing, DS.Space.s2)
        .frame(height: DataMetrics.rowHeight)
        .background(RoundedRectangle(cornerRadius: DS.Radius.sm).fill(selected ? DS.Color.sidebarSelected : Color.clear))
        .contentShape(Rectangle())
    }
}

/// O papel do objeto no caminho do dado, grande o bastante para ser lido de relance: o original, uma cópia de mão única ou uma tabela
/// onde os agentes gravam direto.
struct DataRoleBadge: View {
    enum Role {
        case original, copy, direct

        @MainActor init?(hub: DataHubController, object: DataObject) {
            switch object {
            case .dataset: self = .original
            case .query, .tab: return nil
            default:
                if hub.copySource(of: object) != nil { self = .copy } else if !hub.writers(of: object).isEmpty { self = .direct } else { return nil }
            }
        }
    }

    let role: Role
    /// Sem espaço: só o ícone (o nome fica no tooltip).
    var iconOnly = false

    var title: String { look.title }

    private var look: (title: String, symbol: String, tint: Color) {
        switch role {
        case .original: (String(localized: "Original", bundle: .module), "checkmark.seal", DS.Color.dataValid)
        case .copy: (String(localized: "One-way copy", bundle: .module), "arrow.right.doc.on.clipboard", DS.Color.dataKey)
        case .direct: (String(localized: "Written by agents", bundle: .module), "person.2", DS.Color.textSecondary)
        }
    }

    var body: some View {
        let (title, symbol, tint) = look
        HStack(spacing: DS.Space.s1) {
            Image(systemName: symbol).font(.system(size: DS.Space.s2_5, weight: .semibold)).foregroundStyle(tint)
            // Um rótulo de estado, não um link nem um botão: texto neutro, a cor fica só no ícone.
            if !iconOnly {
                Text(verbatim: title).dsFont(DS.Font.label).foregroundStyle(DS.Color.textSecondary)
            }
        }
        .fixedSize()
    }
}

/// Conexões de exemplo ligadas: diz com todas as letras que nada está conectado.
struct DataDemoBanner: View {
    /// Já há conexão de verdade (Prefect): a faixa não pode dizer que nada está conectado.
    var hasOwn = false

    var body: some View {
        HStack(spacing: DS.Space.s2) {
            Image(systemName: "eye").font(.system(size: DS.Space.s3))
            Text("Example data", bundle: .module).dsFont(DS.Font.label)
            Text(hasOwn
                 ? "Besides the ones you added, these connections are samples: they are not connected."
                 : "These connections are samples, not yours: nothing is connected.", bundle: .module)
                .dsFont(DS.Font.small).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(DS.Color.dataKey)
        .padding(.horizontal, DS.Space.s4)
        .padding(.vertical, DS.Space.s1_5)
        .frame(minHeight: DS.Space.s8)
        .background(DS.Color.dataKey.opacity(0.1))
        .overlay(alignment: .bottom) { DS.Color.dataKey.opacity(0.3).frame(height: ComputersMetrics.separator) }
        .a11y(.dataDemo, kind: "banner")
    }
}

/// Nome do dataset que vira campo com dois cliques.
struct DatasetNameLabel: View {
    let hub: DataHubController
    let id: String
    let text: String
    let font: DSTextStyle
    @Environment(\.actionRegistry) private var registry

    var body: some View {
        if hub.renaming == id, hub.renamingIn == "title" {
            DatasetRenameField(hub: hub, id: id, initial: text)
        } else {
            HStack(spacing: DS.Space.s1) {
                Text(verbatim: text).dsFont(font).foregroundStyle(DS.Color.textPrimary).lineLimit(1).truncationMode(.tail)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { _ = registry.map { r in Task { _ = try? await r.perform(.dataRenameDataset, .select(id)) } } }
                    .help(String(localized: "Double-click to rename", bundle: .module))
                    .a11y(.dataLocationCrumb("name"), kind: "text", label: text)
                // O lápis mostra que dá para renomear (os dois cliques no nome fazem o mesmo).
                ActionButton(.dataRenameDataset, id: .dataRenameButton, argument: .select(id), tooltip: String(localized: "Rename (or double-click the name)", bundle: .module)) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(DSIconButtonStyle(.row))
            }
        }
    }
}

/// Campo de renomear: Enter grava (vazio volta ao nome original), Esc cancela.
struct DatasetRenameField: View {
    let hub: DataHubController
    let id: String
    let initial: String
    @State private var text = ""
    @FocusState private var focused: Bool
    @Environment(\.actionRegistry) private var registry

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .dsFont(DS.Font.bodyStrong)
            .foregroundStyle(DS.Color.textPrimary)
            .padding(.horizontal, DS.Space.s1_5)
            .frame(minWidth: DataMetrics.explorerTitleMin, maxWidth: DataMetrics.explorerMin)
            .frame(height: DataMetrics.chipHeight)
            .background(RoundedRectangle(cornerRadius: DS.Radius.sm).fill(DS.Color.chrome))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.sm).strokeBorder(DS.Color.textTertiary))
            .focused($focused)
            .onAppear {
                text = initial
                focused = true
            }
            .onSubmit(commit)
            .onExitCommand { hub.beginRename(nil) }
            .onChange(of: focused) { _, now in if !now, hub.renaming == id { commit() } }
            .a11y(.dataRenameField, kind: "textfield", value: text, action: .dataRenameDataset)
    }

    private func commit() {
        guard let registry, hub.renaming == id else { return }
        let value = text
        Task { _ = try? await registry.perform(.dataRenameDataset, .select("\(id)|\(value)")) }
    }
}

/// O ícone de uma linha do explorer: o logo do agente (sessões), o logo da marca (conexões) ou um símbolo.
enum DataMark {
    case symbol(String, Color?)
    case agent(DSAgentKind)
    case brand(DSDataBrand)
}

struct DataMarkView: View {
    let mark: DataMark
    var muted = false

    var body: some View {
        Group {
            switch mark {
            case .symbol(let name, let tint):
                Image(systemName: name).font(.system(size: DataMetrics.icon)).foregroundStyle(muted ? DS.Color.textTertiary : (tint ?? DS.Color.textSecondary))
            case .agent(let kind): DSAgentLogo(kind, size: DataMetrics.markSize - DS.Space.s0_5)
            case .brand(let brand): DSDataLogo(brand, size: DataMetrics.markSize - DS.Space.s0_5)
            }
        }
        .frame(width: DataMetrics.logoTile, height: DataMetrics.logoTile)
    }
}

/// O cadeado de uma conexão protegida (cor só no ícone) e as etiquetas que o usuário criou, em chips neutros.
struct ConnectionBadges: View {
    let tags: [String]
    let protected: Bool

    init(_ connection: DataConnection) {
        tags = connection.tags
        protected = connection.protected
    }

    init(tags: [String] = [], protected: Bool) {
        self.tags = tags
        self.protected = protected
    }

    var body: some View {
        HStack(spacing: DS.Space.s1) {
            if protected {
                Image(systemName: "lock.fill").font(.system(size: DS.Space.s2_5)).foregroundStyle(DS.Color.warning)
                    .help(String(localized: "Protected: Racky asks before anything that changes data", bundle: .module))
            }
            ForEach(tags, id: \.self) { tag in
                Text(verbatim: tag)
                    .dsFont(DS.Font.keycap)
                    .foregroundStyle(DS.Color.textTertiary)
                    .padding(.horizontal, DS.Space.s1)
                    .padding(.vertical, DataMetrics.badgePadding)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.xs).fill(DS.Color.secondary))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.xs).strokeBorder(DS.Color.border))
            }
        }
        .fixedSize()
    }
}

struct LiveDot: View {
    var body: some View {
        Circle().fill(DS.Color.dataValid).frame(width: DataMetrics.liveDot, height: DataMetrics.liveDot)
            .help(String(localized: "Something is writing here right now", bundle: .module))
    }
}

// MARK: Tabs

struct DataTabStrip: View {
    let hub: DataHubController
    private var showsMenu: Bool { hub.tabs.count > DataMetrics.tabsBeforeMenu }
    @Environment(\.pageTrailingInset) private var trailingInset

    var body: some View {
        // Nomes inteiros, nunca cortados. Sem espaço: os nomes das tabs inativas encurtam com "…"; só então a faixa rola.
        ViewThatFits(in: .horizontal) {
            row(compact: false)
            // Ainda sem espaço: os nomes encurtam com "…" (como no Chrome) antes de a faixa rolar.
            row(compact: true, short: true)
            // Muitas tabs: as inativas ficam só com o logo e o começo do nome, sem o X (como o Chrome), antes de a faixa rolar.
            row(compact: true, short: true, tiny: true)
            scrolling
        }
        .padding(.trailing, showsMenu ? DataMetrics.tabsMenuWidth : .zero)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) {
            // Mais tabs do que cabem: um menu com todas (as que rolaram para fora da faixa também).
            if showsMenu {
                MenuButton(id: .dataTabsMenu, action: .dataOpen, entries: hub.tabs.map { object in
                    .item(DSMenuItem(object.key, DataLabels.title(object, hub: hub), detail: hub.connection(object.connectionID)?.name ?? String(localized: "This Mac", bundle: .module),
                                     checked: hub.active == object, action: .dataOpen, argument: .select(object.key)))
                }) {
                    Image(systemName: "chevron.down").font(.system(size: DS.Space.s2_5, weight: .semibold))
                    Text(verbatim: "\(hub.tabs.count)").dsFont(DS.Font.small)
                }
                .padding(.trailing, DS.Space.s1)
                .background(DS.Color.chrome)
                .help(String(localized: "All open tabs", bundle: .module))
            }
        }
        // Os botões do painel direito ficam por cima do canto: as tabs param antes deles.
        .padding(.trailing, trailingInset)
        .frame(height: DataMetrics.tabHeight)
        .background(DS.Color.chrome)
        .overlay(alignment: .bottom) { DS.Color.border.frame(height: ComputersMetrics.separator) }
    }

    private func row(compact: Bool, short: Bool = false, tiny: Bool = false) -> some View {
        HStack(spacing: 0) {
            ForEach(hub.tabs, id: \.self) { object in tab(object, compact: compact, short: short, tiny: tiny) }
        }
    }

    private var scrolling: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(hub.tabs, id: \.self) { object in tab(object, compact: true, short: true, tiny: true).id(object) }
                }
            }
            // As bordas esmaecem: uma tab cortada pela rolagem some aos poucos em vez de virar meia palavra.
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: DS.Space.s6)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: DS.Space.s6)
                }
            }
            .onChange(of: hub.active) { _, active in if let active { reader.scrollTo(active) } }
            .onAppear { if let active = hub.active { reader.scrollTo(active) } }
        }
    }

    private func tab(_ object: DataObject, compact: Bool, short: Bool = false, tiny: Bool = false) -> some View {
        let active = hub.active == object
        let place = hub.connection(object.connectionID)
        return HStack(spacing: DS.Space.s1_5) {
            // O lugar fica no logo (e no tooltip): o nome da tab é só o objeto, para caberem mais tabs inteiras.
            ActionButton(
                .dataOpen, id: .dataTab(object.key), argument: .select(object.key),
                tooltip: "\(DataLabels.title(object, hub: hub)) · \(place?.name ?? String(localized: "This Mac", bundle: .module))"
            ) {
                HStack(spacing: DS.Space.s1_5) {
                    // O ícone diz o que a tab é (notebook, dataset do Mac, tabela de uma conexão), não só onde mora.
                    if case .notebook = object {
                        JupyterMark(size: DataMetrics.icon + DS.Space.s0_5)
                    } else if let place {
                        DSDataLogo(place.kind.brand, size: DataMetrics.icon + DS.Space.s0_5)
                    } else {
                        Image(systemName: "tablecells").font(.system(size: DataMetrics.icon)).foregroundStyle(DS.Color.textSecondary)
                    }
                    // Encurtada, a tabela mostra só o nome (sem "public."): duas tabs do mesmo schema não viram dois "publi…".
                    Text(verbatim: short && !active ? DataLabels.shortTitle(object, hub: hub) : DataLabels.title(object, hub: hub))
                        .dsFont(active ? DS.Font.tabActive : DS.Font.tab)
                        .foregroundStyle(active ? DS.Color.textPrimary : DS.Color.textSecondary).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: short && !active ? (tiny ? DataMetrics.tabTitleTiny : DataMetrics.tabTitleShort) : nil, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if active || !tiny {
                ActionButton(.dataClose, id: .dataTabClose(object.key), argument: .select(object.key), tooltip: String(localized: "Close", bundle: .module)) {
                    Image(systemName: "xmark").font(.system(size: DS.Space.s2, weight: .semibold))
                }
                .buttonStyle(DSIconButtonStyle(.tabClose))
                .opacity(active ? 1 : 0.6)
            }
        }
        .padding(.leading, tiny ? DS.Space.s2 : DS.Space.s3)
        .padding(.trailing, tiny && !active ? DS.Space.s2 : DS.Space.s1_5)
        .frame(maxHeight: .infinity)
        .fixedSize(horizontal: true, vertical: false)
        .background(active ? DS.Color.canvas : Color.clear)
        .overlay(alignment: .bottom) { if active { DS.Color.textPrimary.frame(height: DataMetrics.underline) } }
        .overlay(alignment: .trailing) { DS.Color.border.frame(width: ComputersMetrics.separator) }
    }
}

enum DataLabels {
    @MainActor static func title(_ object: DataObject, hub: DataHubController) -> String {
        switch object {
        case .dataset(let id): hub.summary(ofDataset: id).map { hub.datasets.displayName($0) } ?? String(localized: "Dataset", bundle: .module)
        case .table(_, let schema, let name): "\(schema).\(name)"
        case .query(_, let n): String(localized: "Query \(n)", bundle: .module)
        case .folder(_, let path): path.joined(separator: "/")
        case .webhook(let c): hub.connection(c)?.name ?? String(localized: "Webhook", bundle: .module)
        case .tab(_, _, let name): name
        case .runs: String(localized: "Flow runs", bundle: .module)
        case .notebook(let name): String(localized: "Notebook · \(name)", bundle: .module)
        }
    }

    /// Título de tab encurtada: o último pedaço do nome (tabela sem schema, pasta só com a última parte).
    @MainActor static func shortTitle(_ object: DataObject, hub: DataHubController) -> String {
        switch object {
        case .table(_, _, let name): name
        case .folder(_, let path): path.last ?? title(object, hub: hub)
        case .notebook(let name): name
        default: title(object, hub: hub)
        }
    }

    /// O tipo do objeto em palavras (lado direito da barra de localização).
    @MainActor static func kind(_ object: DataObject, hub: DataHubController) -> String {
        switch object {
        case .dataset: String(localized: "Dataset on this Mac", bundle: .module)
        case .table(let c, _, _): hub.connection(c)?.kind.family == .warehouse ? String(localized: "Warehouse table", bundle: .module) : String(localized: "Database table", bundle: .module)
        case .query: String(localized: "SQL query", bundle: .module)
        case .folder: String(localized: "Storage folder", bundle: .module)
        case .webhook: String(localized: "Webhook · receives only, nothing to browse", bundle: .module)
        case .tab: String(localized: "Spreadsheet tab", bundle: .module)
        case .runs: String(localized: "Orchestrator · read only", bundle: .module)
        case .notebook: String(localized: "Python notebook", bundle: .module)
        }
    }
}

// MARK: Barra de localização

/// "Em que lugar estou e o que estou vendo": o chip do lugar (Racky ou a conexão, com o ambiente), a trilha até o objeto e, à direita,
/// o tipo e o tamanho, mais as ações do objeto.
struct DataLocationBar: View {
    let hub: DataHubController
    let object: DataObject
    /// Num pane do workspace: o X fecha o pane e o lugar/nome arrasta o pane (como o título de um terminal).
    var close: (() -> Void)? = nil
    var drag: (paneID: UUID, controller: PaneDragController)? = nil
    /// Num pane da sessão: `true` sozinho numa tab, `false` ao lado do agente, `nil` fora da sessão.
    var besideAgent: Bool? = nil

    var body: some View {
        // Numa linha só enquanto cabe com os botões nomeados: primeiro some a trilha (fica o nome), depois os nomes ficam curtos e o
        // papel fica só com o ícone. Sem espaço nem assim, as ações descem para uma segunda linha (sempre com nome, nunca só ícones).
        ViewThatFits(in: .horizontal) {
            row(compact: false, items: trail, trailing: trailing(compact: false))
            row(compact: false, items: Array(trail.suffix(1)), trailing: trailing(compact: false))
            row(compact: false, items: Array(trail.suffix(1)), trailing: trailing(compact: false, short: true))
            row(compact: true, items: Array(trail.suffix(1)), trailing: trailing(compact: false, short: true, iconBadge: true))
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                HStack(spacing: DS.Space.s2) {
                    place(compact: true, items: Array(trail.suffix(1)))
                    Spacer(minLength: DS.Space.s3)
                    closeButton
                }
                trailing(compact: false, short: true)
            }
            .padding(.vertical, DS.Space.s2_5)
        }
        .padding(.horizontal, DS.Space.s4)
        .frame(minHeight: DataMetrics.locationHeight)
        .overlay(alignment: .bottom) { DS.Color.border.frame(height: ComputersMetrics.separator) }
        .a11y(.dataLocation, kind: "group", label: ([placeName] + trail).joined(separator: " › "))
    }

    private func row(compact: Bool, items: [String], trailing: some View) -> some View {
        HStack(spacing: DS.Space.s2) {
            place(compact: compact, items: items)
            Spacer(minLength: DS.Space.s3)
            trailing
            closeButton
        }
    }

    @ViewBuilder private var closeButton: some View {
        if let close {
            // lint-ui: allow buttons fecha o pane do dataset (layout do workspace, sem ação de registro própria)
            Button(action: close) { Image(systemName: "xmark") }
                .buttonStyle(DSIconButtonStyle(.header))
                .dsTooltip(String(localized: "Close", bundle: .module), shortcut: nil)
        }
    }

    private func place(compact: Bool, items: [String]) -> some View {
        HStack(spacing: DS.Space.s2) {
            // O chip do lugar é a alça que arrasta o pane; o nome e o lápis ficam livres para os cliques (renomear).
            placeChip(compact: compact)
                .overlay {
                    if let drag {
                        PaneDragSource(controller: drag.controller, payload: .otherPane(drag.paneID), title: { trail.last ?? "" })
                    }
                }
            crumbs(items)
        }
    }

    private func crumbs(_ items: [String]) -> some View {
        HStack(spacing: DS.Space.s2) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, crumb in
                Image(systemName: "chevron.right").font(.system(size: DS.Space.s2, weight: .semibold)).foregroundStyle(DS.Color.textQuaternary)
                if index == items.count - 1, case .dataset(let id) = object {
                    // O nome do dataset: dois cliques renomeiam (como no VS Code).
                    DatasetNameLabel(hub: hub, id: id, text: crumb, font: DS.Font.composerTitle)
                } else {
                    Text(verbatim: crumb).dsFont(index == items.count - 1 ? DS.Font.composerTitle : DS.Font.body)
                        .foregroundStyle(index == items.count - 1 ? DS.Color.textPrimary : DS.Color.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .a11y(.dataLocationCrumb("\(index)"), kind: "text", label: crumb)
                }
            }
        }
    }

    private func trailing(compact: Bool, short: Bool = false, iconBadge: Bool = false) -> some View {
        HStack(spacing: DS.Space.s2) {
            // Num dataset do Mac o papel não diz nada (todo dataset aqui é o original): só nas tabelas e cópias das conexões.
            if let role = DataRoleBadge.Role(hub: hub, object: object), role != .original {
                let badge = DataRoleBadge(role: role, iconOnly: iconBadge)
                badge.help((iconBadge ? badge.title + " · " : "") + DataLabels.kind(object, hub: hub) + (size.map { " · \($0)" } ?? ""))
            }
            DataObjectActions(hub: hub, object: object, compact: compact, short: short, besideAgent: besideAgent)
        }
        .fixedSize()
    }

    private var connection: DataConnection? { hub.connection(object.connectionID) }
    private var placeName: String { connection?.name ?? String(localized: "This Mac", bundle: .module) }

    private func placeChip(compact: Bool) -> some View {
        HStack(spacing: DS.Space.s1_5) {
            if let connection {
                DSDataLogo(connection.kind.brand, size: DataMetrics.markSize)
                Text(verbatim: connection.name).dsFont(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
                if !compact, connection.kind.title != connection.name {
                    Text(verbatim: connection.kind.title).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                }
                ConnectionBadges(connection)
            } else {
                Image(systemName: "laptopcomputer").font(.system(size: DataMetrics.icon)).foregroundStyle(DS.Color.textSecondary)
                Text("This Mac", bundle: .module).dsFont(DS.Font.label).foregroundStyle(DS.Color.textPrimary)

            }
        }
        .padding(.horizontal, DS.Space.s2)
        .frame(height: DataMetrics.chipHeight + DS.Space.s1)
        .lineLimit(1)
        .background(RoundedRectangle(cornerRadius: DS.Radius.sm).fill(DS.Color.secondary))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.sm).strokeBorder(DS.Color.border))
        .fixedSize()
        .help(connection?.address ?? String(localized: "Stored on this Mac by Racky", bundle: .module))
    }

    private var trail: [String] {
        switch object {
        case .dataset(let id):
            guard let summary = hub.summary(ofDataset: id) else { return [] }
            return [hub.datasets.title(of: summary), hub.datasets.displayName(summary)]
        case .table(_, let schema, let name): return [schema, name]
        case .query(_, let n): return [String(localized: "Query \(n)", bundle: .module)]
        case .folder(_, let path): return path
        case .webhook: return [connection?.address ?? ""]
        case .tab(_, let spreadsheet, let name): return [spreadsheet, name]
        case .runs: return [String(localized: "Flow runs", bundle: .module)]
        case .notebook(let name): return [String(localized: "Notebooks", bundle: .module), name]
        }
    }

    private var size: String? {
        switch object {
        case .dataset(let id):
            return hub.summary(ofDataset: id).map { $0.rowCount == 1 ? String(localized: "1 row", bundle: .module) : String(localized: "\($0.rowCount.formatted()) rows", bundle: .module) }
        case .table where hub.isLivePostgres(object.connectionID):
            let rows = hub.rowTotal(object)
            return rows.approximate ? String(localized: "about \(rows.total.formatted()) rows", bundle: .module) : String(localized: "\(rows.total.formatted()) rows", bundle: .module)
        case .table, .tab:
            let total = DataHubFixtures.grid(for: object).total
            return String(localized: "\(total.formatted()) rows", bundle: .module)
        case .folder(_, let path):
            if hub.isLiveS3(object.connectionID) {
                guard let state = hub.s3Folders[object], state.loaded else { return nil }
                return String(localized: "\(state.entries.count) items", bundle: .module) + (state.hasNext ? "+" : "")
            }
            let count = DataHubFixtures.files(in: path).count
            return String(localized: "\(count) items", bundle: .module)
        case .query, .webhook, .runs, .notebook:
            return nil
        }
    }
}

// MARK: Linhagem

/// O caminho do dado, da esquerda para a direita, com os logos: o agente da sessão (Claude Code, na sessão de origem) → os
/// subagentes que coletaram (Codex 1, Codex 2) → o original (no Mac ou direto numa conexão) → as cópias. O objeto aberto fica
/// marcado "You are here"; cada nó leva ao lugar dele (a sessão, o pane do subagente, a tabela).
struct DataLineageStrip: View {
    let hub: DataHubController
    let object: DataObject
    /// Uma linha só, em cima dos dados: logo e nome de cada passo (o detalhe fica no hover). A versão inteira fica em Overview.
    var compact = false

    struct Node: Identifiable {
        enum Mark { case agent(DSAgentKind), brand(DSDataBrand), mac, query, people }
        var id: String
        var mark: Mark
        var title: String
        var detail: String
        var action: (ActionID, ActionArgument)?
        var badge: DataConnection?
        var live = false
        var current = false
    }

    private struct Column { var edge: String; var nodes: [Node] }

    var body: some View {
        if compact { compactBody } else { fullBody }
    }

    private var compactBody: some View {
        let columns = lineage
        // Cabe inteiro: uma linha. Não cabe: cada grupo mostra o primeiro e "+N" (o resto fica no Overview); só então quebra em linhas.
        return ViewThatFits(in: .horizontal) {
            compactChips(columns, limit: nil)
            compactChips(columns, limit: 1)
            compactChips(columns, limit: 1, terse: true)
            // Nem assim cabe (pane estreito ao lado do agente): os chips quebram em linhas, nada fica cortado na borda.
            ChipFlow(spacing: DS.Space.s1_5) { chipItems(columns, limit: 1, terse: false) }  // com quebra cabe "+1 more"
                .padding(.horizontal, DS.Space.s4)
                .padding(.vertical, DS.Space.s1_5)
        }
        .frame(maxWidth: .infinity, minHeight: DataMetrics.pathHeight, alignment: .leading)
        .overlay(alignment: .bottom) { DS.Color.border.frame(height: ComputersMetrics.separator) }
        .a11y(.dataPath, kind: "group", label: columns.flatMap(\.nodes).map(\.title).joined(separator: " → "))
    }

    private func compactChips(_ columns: [Column], limit: Int?, terse: Bool = false) -> some View {
        HStack(spacing: DS.Space.s1_5) { chipItems(columns, limit: limit, terse: terse) }
            .padding(.horizontal, DS.Space.s4)
            .fixedSize()
    }

    @ViewBuilder private func chipItems(_ columns: [Column], limit: Int?, terse: Bool) -> some View {
            if columns.isEmpty {
                Text("Racky doesn't write here.", bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
            }
            ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                if index > 0 {
                    Image(systemName: "arrow.right").font(.system(size: DS.Space.s2_5, weight: .semibold)).foregroundStyle(DS.Color.textQuaternary)
                        .help(column.edge)
                }
                let shown = limit.map { column.nodes.prefix(max($0, column.nodes.firstIndex(where: \.current).map { $0 + 1 } ?? $0)) } ?? column.nodes[...]
                ForEach(Array(shown)) { node in smallChip(node) }
                if shown.count < column.nodes.count {
                    Text(verbatim: terse ? "+\(column.nodes.count - shown.count)" : String(localized: "+\(column.nodes.count - shown.count) more", bundle: .module)).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                        .help(column.nodes.dropFirst(shown.count).map(\.title).joined(separator: ", "))
                }
            }
    }

    private func smallChip(_ node: Node) -> some View {
        let content = HStack(spacing: DS.Space.s1) {
            markView(node.mark, size: DataMetrics.icon + DS.Space.s0_5)
            Text(verbatim: node.title).dsFont(node.current ? DS.Font.label : DS.Font.small)
                .foregroundStyle(node.current ? DS.Color.textPrimary : DS.Color.textSecondary).lineLimit(1)
            if let badge = node.badge { ConnectionBadges(badge) }
            if node.live { LiveDot() }
        }
        .padding(.horizontal, DS.Space.s1_5)
        .frame(height: DataMetrics.chipHeight - DS.Space.s0_5)
        .background(RoundedRectangle(cornerRadius: DS.Radius.sm).fill(node.current ? DS.Color.secondary : Color.clear))
        .contentShape(Rectangle())
        .fixedSize()
        .help(node.detail)
        return Group {
            if let action = node.action, !node.current {
                ActionButton(action.0, id: .dataFlowItem(node.id), argument: action.1) { content }.buttonStyle(.plain)
            } else {
                content
            }
        }
    }

    @ViewBuilder private func markView(_ mark: Node.Mark, size: CGFloat) -> some View {
        switch mark {
        case .agent(let kind): DSAgentLogo(kind, size: size)
        case .brand(let brand): DSDataLogo(brand, size: size)
        case .mac: Image(systemName: "laptopcomputer").font(.system(size: size * 0.8)).foregroundStyle(DS.Color.textSecondary)
        case .query: Image(systemName: "terminal").font(.system(size: size * 0.8)).foregroundStyle(DS.Color.textSecondary)
        case .people: Image(systemName: "person.2").font(.system(size: size * 0.75)).foregroundStyle(DS.Color.textSecondary)
        }
    }

    private var fullBody: some View {
        let columns = lineage
        return VStack(alignment: .leading, spacing: DS.Space.s2) {
            // Cabe de lado: a cadeia numa linha. Não cabe: de cima para baixo (cada passo numa linha, com a seta ↓ e o nome do passo),
            // em vez de cortar os últimos chips na borda.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: DS.Space.s2) {
                    if columns.isEmpty {
                        Text(verbatim: emptyText).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).lineLimit(1)
                    }
                    ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                        if index > 0 { edge(column.edge) }
                        VStack(alignment: .leading, spacing: .zero) {
                            ForEach(Array(column.nodes.enumerated()), id: \.element.id) { row, node in
                                branch(row, of: column.nodes.count) { chip(node) }
                            }
                        }
                    }
                }
                .fixedSize()
                VStack(alignment: .leading, spacing: DS.Space.s1) {
                    if columns.isEmpty {
                        Text(verbatim: emptyText).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                    }
                    ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                        if index > 0 {
                            HStack(spacing: DS.Space.s1) {
                                Image(systemName: "arrow.down").font(.system(size: DS.Space.s2_5, weight: .semibold))
                                Text(verbatim: column.edge).dsFont(DS.Font.micro)
                            }
                            .foregroundStyle(DS.Color.textTertiary)
                            .padding(.leading, DS.Space.s3)
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: DS.Space.s1) { ForEach(column.nodes) { node in chip(node) } }.fixedSize()
                            VStack(alignment: .leading, spacing: DS.Space.s1) { ForEach(column.nodes) { node in chip(node) } }
                        }
                    }
                }
            }
            if let sentence = explanation {
                Text(verbatim: sentence).dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary)
            }
            // A seta nos cards sozinha não bastava: testers não sabiam o que o clique abre.
            if columns.flatMap(\.nodes).contains(where: { $0.action != nil && !$0.current }) {
                Text("Click a card with › to open it: the agent opens its terminal, a table opens its rows.", bundle: .module)
                    .dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary)
            }
        }
        .padding(.horizontal, DS.Space.s4)
        .padding(.vertical, DS.Space.s2_5)
        .frame(maxWidth: .infinity, minHeight: DataMetrics.flowHeight, alignment: .leading)
        .background(DS.Color.chrome.opacity(0.5))
        .overlay(alignment: .bottom) { DS.Color.border.frame(height: ComputersMetrics.separator) }
        .a11y(.dataFlow, kind: "group", label: columns.flatMap(\.nodes).map(\.title).joined(separator: " → "))
    }

    private var emptyText: String {
        String(localized: "Nothing writes here yet. To have agents write here, pick it under Save data to when you start a session.", bundle: .module)
    }

    /// Uma frase que diz qual é o original e para que lado o dado anda.
    var explanation: String? {
        switch object {
        case .query(let connection, _):
            return String(localized: "This query only reads \(hub.connection(connection)?.name ?? ""). SQL that changes data asks you to confirm first.", bundle: .module)
        case .dataset(let id):
            guard let name = hub.summary(ofDataset: id).map({ hub.datasets.displayName($0) }) else { return nil }
            return hub.destinations(of: object).isEmpty
                ? String(localized: "\(name) on this Mac is the original. Nothing is copied out yet.", bundle: .module)
                : String(localized: "\(name) on this Mac is the original: change the data here. The copies only receive from it, and edits made in a copy don't come back.", bundle: .module)
        case .webhook:
            guard let source = hub.copySource(of: object).map(hub.displayName(ofDatasetNamed:)) else { return nil }
            return String(localized: "Racky posts each new row of \(source) (this Mac) to this address. Nothing comes back.", bundle: .module)
        default:
            if let source = hub.copySource(of: object).map(hub.displayName(ofDatasetNamed:)) {
                return String(localized: "This is a one-way copy of \(source) (this Mac). Change the data in \(source): edits made here don't go back.", bundle: .module)
            }
            if !hub.writers(of: object).isEmpty {
                return String(localized: "Agents write into this table directly. Nothing is kept on this Mac.", bundle: .module)
            }
            return nil
        }
    }

    // MARK: Montagem

    private var lineage: [Column] {
        switch object {
        case .query(let connection, _):
            let place = hub.connection(connection)
            return [
                Column(edge: "", nodes: [Node(id: "query", mark: .query, title: String(localized: "This query", bundle: .module), detail: String(localized: "written by you", bundle: .module), current: true)]),
                Column(edge: String(localized: "reads", bundle: .module), nodes: place.map { [placeNode($0, title: $0.name, detail: $0.kind.title, target: nil)] } ?? []),
            ]
        case .dataset(let id):
            return chain(sourceID: id)
        default:
            if let source = hub.copySource(of: object), let id = hub.datasetID(named: source) { return chain(sourceID: id) }
            let writers = hub.writers(of: object)
            guard !writers.isEmpty, let place = hub.connection(object.connectionID) else { return [] }
            var columns = agentColumns(writers: writers, session: nil)
            columns.append(Column(
                edge: String(localized: "write directly", bundle: .module),
                nodes: [placeNode(place, title: DataLabels.title(object, hub: hub), detail: String(localized: "written directly · not kept on this Mac", bundle: .module), target: object)]))
            return columns
        }
    }

    /// Agente da sessão → subagentes → dataset no Mac (original) → cópias.
    private func chain(sourceID: String) -> [Column] {
        let sourceObject = DataObject.dataset(sourceID)
        guard let summary = hub.summary(ofDataset: sourceID) else { return [] }
        var columns = agentColumns(writers: hub.writers(of: sourceObject), session: summary.dataset.sessionID)
        columns.append(Column(
            edge: columns.isEmpty ? "" : String(localized: "collect", bundle: .module),
            nodes: [Node(
                id: "source", mark: .mac, title: String(localized: "This Mac › \(hub.datasets.displayName(summary))", bundle: .module),
                detail: summary.rowCount == 1 ? String(localized: "original · 1 row", bundle: .module)
                    : String(localized: "original · \(summary.rowCount.formatted()) rows", bundle: .module),
                action: (.dataOpen, .select(sourceObject.key)), live: hub.datasets.isCollecting(summary), current: object == sourceObject)]))
        let copies = hub.destinations(of: sourceObject).compactMap { destination -> Node? in
            guard let place = hub.connection(destination.target.connectionID) else { return nil }
            var node = placeNode(place, title: DataLabels.title(destination.target, hub: hub), detail: copyStatus(destination, rows: summary.rowCount), target: destination.target)
            node.current = destination.target == object
            return node
        }
        if !copies.isEmpty { columns.append(Column(edge: String(localized: "copied one way", bundle: .module), nodes: copies)) }
        return columns
    }

    /// O agente principal da sessão (com o logo e a sessão) e, se houver, os subagentes que coletaram.
    private func agentColumns(writers: [DataWriter], session: UUID?) -> [Column] {
        let agents = writers.filter { if case .agent = $0.kind { true } else { false } }
        guard !agents.isEmpty else { return [] }
        let sessionTitle: String = if case .agent(let s)? = agents.first?.kind { s } else { "" }
        let mainProvider = session.flatMap { hub.datasets.sessionAgent($0) }
        // Nos exemplos, o agente principal vem pelo nome ("Claude Code"); no app, pela sessão.
        let mainIndex = agents.firstIndex { Self.provider(named: $0.name) == .claude && mainProvider == nil }
        let main = mainIndex.map { agents[$0] }
        let subagents = agents.enumerated().filter { $0.offset != mainIndex }.map(\.element)
        let provider = mainProvider ?? main.flatMap { Self.provider(named: $0.name) } ?? .claude
        var columns: [Column] = []
        let sessionAction: (ActionID, ActionArgument)? = session.map { (.sessionSelect, .select("\($0.uuidString)|agent")) }
        columns.append(Column(edge: "", nodes: [Node(
            id: "session", mark: .agent(QuickLaunchModel.kind(provider)), title: Self.agentTitle(provider),
            detail: String(localized: "session \(sessionTitle)", bundle: .module), action: sessionAction, live: main?.live ?? false)]))
        let subs = subagents.filter { $0.name != String(localized: "Agents", bundle: .module) }
        if !subs.isEmpty {
            columns.append(Column(edge: String(localized: "subagents", bundle: .module), nodes: subs.map { writer in
                // Subagente sem CLI próprio no nome: é um subagente do agente principal (o mesmo logo).
                let kind = (Self.provider(named: writer.name) ?? provider).map(QuickLaunchModel.kind) as DSAgentKind?
                let terminal = hub.datasets.workerTerminal(computerName(of: writer) ?? "")
                return Node(
                    id: "sub-\(writer.id)", mark: kind.map { .agent($0) } ?? .people, title: writer.name,
                    detail: computerName(of: writer).map { String(localized: "subagent · computer \($0)", bundle: .module) } ?? String(localized: "subagent", bundle: .module),
                    action: terminal.map { (.paneShow, .select($0.uuidString)) }, live: writer.live)
            }))
        }
        return columns
    }

    private func computerName(of writer: DataWriter) -> String? {
        writer.id == writer.name ? nil : writer.id
    }

    static func provider(named name: String) -> TerminalProvider? {
        let lower = name.lowercased()
        if lower.hasPrefix("codex") { return .codex }
        if lower.hasPrefix("opencode") { return .opencode }
        if lower.hasPrefix("claude") { return .claude }
        return nil
    }

    static func agentTitle(_ provider: TerminalProvider) -> String {
        switch provider {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        default: String(localized: "Agent", bundle: .module)
        }
    }

    private func placeNode(_ place: DataConnection, title: String, detail: String, target: DataObject?) -> Node {
        Node(
            id: "place-\(place.id)-\(title)", mark: .brand(place.kind.brand), title: place.name == title ? title : "\(place.name) › \(title)", detail: detail,
            action: target.map { (.dataOpen, .select($0.key)) }, badge: place, current: target == object)
    }

    private func copyStatus(_ destination: DataDestination, rows: Int) -> String {
        switch destination.detail {
        case "live copy": rows == 1 ? String(localized: "copy, updated live · in sync, 1 row", bundle: .module)
            : String(localized: "copy, updated live · in sync, \(rows.formatted()) of \(rows.formatted()) rows", bundle: .module)
        case "daily copy": String(localized: "copy, updated daily at 06:00 · last today", bundle: .module)
        case "sends new rows": String(localized: "each new row is posted here", bundle: .module)
        default: destination.detail
        }
    }

    // MARK: Desenho

    private func edge(_ label: String) -> some View {
        VStack(spacing: .zero) {
            Text(verbatim: label).dsFont(DS.Font.micro).foregroundStyle(DS.Color.textSecondary)
            Image(systemName: "arrow.right").font(.system(size: DS.Space.s3, weight: .semibold)).foregroundStyle(DS.Color.textSecondary)
        }
        .fixedSize()
    }

    /// Coluna com vários nós: um colchete fino liga a seta (no meio da coluna) a cada card, senão ela aponta para o vão entre eles.
    @ViewBuilder private func branch(_ row: Int, of count: Int, @ViewBuilder _ content: () -> some View) -> some View {
        if count < 2 {
            content()
        } else {
            HStack(spacing: .zero) {
                Rectangle().fill(DS.Color.textQuaternary).frame(width: DS.Space.s2, height: DataMetrics.branchLine)
                content()
            }
            .padding(.vertical, DS.Space.s0_5)
            .overlay(alignment: .leading) {
                VStack(spacing: .zero) {
                    Rectangle().fill(row == 0 ? Color.clear : DS.Color.textQuaternary).frame(width: DataMetrics.branchLine)
                    Rectangle().fill(row == count - 1 ? Color.clear : DS.Color.textQuaternary).frame(width: DataMetrics.branchLine)
                }
            }
        }
    }

    private func chip(_ node: Node) -> some View {
        let content = HStack(spacing: DS.Space.s2) {
            Group {
                switch node.mark {
                case .agent(let kind): DSAgentLogo(kind, size: DataMetrics.markSize)
                case .brand(let brand): DSDataLogo(brand, size: DataMetrics.markSize)
                case .mac: Image(systemName: "laptopcomputer").font(.system(size: DataMetrics.markSize * 0.8)).foregroundStyle(DS.Color.textSecondary)
                case .query: Image(systemName: "terminal").font(.system(size: DataMetrics.markSize * 0.8)).foregroundStyle(DS.Color.textSecondary)
                case .people: Image(systemName: "person.2").font(.system(size: DataMetrics.markSize * 0.75)).foregroundStyle(DS.Color.textSecondary)
                }
            }
            .frame(width: DataMetrics.markSize, height: DataMetrics.markSize)
            VStack(alignment: .leading, spacing: .zero) {
                HStack(spacing: DS.Space.s1) {
                    Text(verbatim: node.title).dsFont(DS.Font.label).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                    if let badge = node.badge { ConnectionBadges(badge) }
                    if node.live { LiveDot() }
                    if node.current { Text("You are here", bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.dataKey) }
                }
                Text(verbatim: node.detail).dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary).lineLimit(1)
            }
            // Card que leva a algum lugar: a seta diz que é clicável (sem ela parecia só um diagrama).
            if node.action != nil, !node.current {
                Image(systemName: "chevron.right").font(.system(size: DS.Space.s3, weight: .semibold)).foregroundStyle(DS.Color.textSecondary)
            }
        }
        .padding(.horizontal, DS.Space.s2_5)
        .padding(.vertical, DS.Space.s1_5)
        .background(RoundedRectangle(cornerRadius: DS.Radius.md).fill(node.current ? DS.Color.dataKey.opacity(0.1) : DS.Color.secondary))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).strokeBorder(node.current ? DS.Color.dataKey.opacity(0.55) : DS.Color.border))
        .fixedSize()
        return Group {
            if let action = node.action, !node.current {
                ActionButton(action.0, id: .dataFlowItem(node.id), argument: action.1) { content }.buttonStyle(.plain)
            } else {
                content.a11y(.dataFlowItem(node.id), kind: "text", label: node.title)
            }
        }
    }
}

// MARK: Produção

/// Faixa em âmbar em todo objeto de uma conexão de produção: o que é, o que o usuário pode fazer e quem está gravando agora (com
/// "Pause").
struct DataProductionBanner: View {
    let hub: DataHubController
    let object: DataObject

    var body: some View {
        let connection = hub.connection(object.connectionID)
        let live = hub.writers(of: object).filter(\.live)
        HStack(spacing: DS.Space.s2) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: DS.Space.s3))
            // Conexão de exemplo: a faixa diz que é exemplo (não contradiz a faixa azul "nada está conectado").
            Text(verbatim: hub.isDemo && !hub.saved.contains(where: { $0.id == connection?.id })
                ? String(localized: "Example · Protected · \(connection?.name ?? "")", bundle: .module)
                : String(localized: "Protected · \(connection?.name ?? "")", bundle: .module)).dsFont(DS.Font.label)
            Text(verbatim: message(object, live: live.count)).dsFont(DS.Font.small).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DS.Space.s2)
            if !live.isEmpty {
                DSButton(.dataPauseWriter, id: .dataProductionPause, live.count == 1 ? "Pause the agent" : "Pause agents", variant: .outline, size: .xs, symbol: "pause.fill", argument: .select("all"))
            }
        }
        .foregroundStyle(DS.Color.warning)
        .padding(.horizontal, DS.Space.s4)
        .padding(.vertical, DS.Space.s1_5)
        .frame(minHeight: DS.Space.s8)
        .background(DS.Color.warning.opacity(0.08))
        .overlay(alignment: .bottom) { DS.Color.warning.opacity(0.3).frame(height: ComputersMetrics.separator) }
        .a11y(.dataProduction, kind: "banner", label: connection?.name ?? "")
    }

    private func message(_ object: DataObject, live: Int) -> String {
        // Uma frase com as regras: quem pode gravar aqui e o que você pode fazer.
        let source = hub.copySource(of: object).map { hub.displayName(ofDatasetNamed: $0) }
        let writers = live == 0
            ? (source.map { String(localized: "Copied from \($0) on this Mac.", bundle: .module) }
                ?? String(localized: "No agent is writing here now.", bundle: .module))
            : (live == 1 ? String(localized: "1 agent is writing here now (Pause stops new writes; rows already written stay).", bundle: .module)
                : String(localized: "\(live) agents are writing here now (Pause stops new writes; rows already written stay).", bundle: .module))
        return writers + " " + String(localized: "Changes ask you to confirm.", bundle: .module)
    }
}

// MARK: Vazio

struct DataEmptyState: View {
    let hub: DataHubController

    var body: some View {
        VStack(spacing: DS.Space.s3) {
            Image(systemName: "cylinder.split.1x2").font(.system(size: DS.Space.s8)).foregroundStyle(DS.Color.textQuaternary)
            Text("Pick a dataset or a table on the left", bundle: .module).dsFont(DS.Font.composerTitle).foregroundStyle(DS.Color.textPrimary)
            Text("Racky holds what your agents collected on this Mac. Connections are your own databases, storage and destinations: browse them here and let agents write to them.", bundle: .module)
                .dsFont(DS.Font.body).foregroundStyle(DS.Color.textTertiary).multilineTextAlignment(.center)
                .frame(maxWidth: DataMetrics.emptyTextWidth)
            // Um só "Add connection": o do pé da lista (aqui só aponta para ele).
            Text("To add one, use Add connection at the bottom of the list.", bundle: .module)
                .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
        }
        .padding(DS.Space.s8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .a11y(.dataEmpty, kind: "text")
    }
}
