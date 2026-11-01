import RackyCore
import RackyDesignSystem
import RackyProtocol
import SwiftUI

/// Tela Traffic de um computador (o "mini Burp"), num pane da sessão: todas as requests com filtro, hosts e busca; a escolhida
/// com request e response (cabeçalhos, corpo formatado, bruto) e `Copy as cURL`; e a aba Activity com os comandos do terminal.
struct TrafficPaneView: View {
    let traffic: TrafficController
    let name: String
    /// Fecha o pane (o Traffic é um pane da sessão como o dataset: sai pelo X).
    var close: (() -> Void)?
    @Environment(\.actionRegistry) private var registry
    @State private var query = ""

    private var state: TrafficController.ViewState { traffic.state(name) }

    var body: some View {
        // Ao lado do agente o pane tem metade da janela: estreito, os hosts viram um menu, a tabela perde Kind e Proxy e
        // request e response viram abas (lado a lado, cortava tudo).
        GeometryReader { geo in
            let wide = geo.size.width >= TrafficMetrics.wide
            VStack(spacing: 0) {
                topBar(wide)
                if state.mode == "activity" {
                    ActivityListView(entries: (traffic.activity[name] ?? []).reversed(), computer: name)
                } else {
                    toolbar(wide)
                    HStack(spacing: 0) {
                        if wide {
                            hosts
                            DS.Color.border.frame(width: ComputersMetrics.separator)
                        }
                        VStack(spacing: 0) {
                            table(wide)
                            DS.Color.border.frame(height: ComputersMetrics.separator)
                            detail(wide, height: min(TrafficMetrics.detail, max(TrafficMetrics.detailMin, geo.size.height * 0.45)))
                        }
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .background(DS.Color.canvas)
        .task(id: name) { await traffic.refresh(name) }
        .onAppear { traffic.openTraffic.insert(name) }
        .a11y(.trafficPage, kind: "page", label: name)
    }

    private func set(_ key: String, _ value: String) {
        guard let registry else { return }
        Task { _ = try? await registry.perform(.trafficSet, .select("\(name)|\(key)=\(value)")) }
    }

    // MARK: Barra de cima

    private func topBar(_ wide: Bool) -> some View {
        let s = traffic.stats[name] ?? TrafficStats()
        return HStack(spacing: DS.Space.s3) {
            Image(systemName: "network").foregroundStyle(DS.Color.textTertiary)
            Text(verbatim: name).dsFont(DS.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary).lineLimit(1).truncationMode(.middle)
            HStack(spacing: DS.Space.s0_5) {
                modeButton("traffic", String(localized: "Requests", bundle: .module))
                modeButton("activity", String(localized: "Commands", bundle: .module))
            }
            .padding(DS.Space.s0_5)
            .background(RoundedRectangle(cornerRadius: DS.Radius.md).fill(DS.Color.secondary))
            .fixedSize()
            Spacer(minLength: DS.Space.s2)
            if wide {
                Text(verbatim: String(localized: "\(s.total.formatted()) requests · \(TrafficController.size(s.bytes))", bundle: .module))
                    .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).lineLimit(1)
            }
            HStack(spacing: DS.Space.s1_5) {
                Circle().fill(s.recent > 0 ? DS.Color.locate : DS.Color.textQuaternary).frame(width: DS.Space.s1_5, height: DS.Space.s1_5)
                Text(verbatim: s.recent > 0 ? String(localized: "Live", bundle: .module) : String(localized: "Idle", bundle: .module))
                    .dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary)
            }
            if let close {
                // lint-ui: allow buttons fecha o pane (layout do workspace, sem ação de registro própria)
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(DSIconButtonStyle(.header))
                    .help(String(localized: "Close", bundle: .module))
                    .a11y(.trafficClose, kind: "button")
            }
        }
        .padding(.horizontal, DS.Space.s3)
        .frame(height: DS.Layout.paneHeaderHeight + DS.Space.s2)
        .overlay(alignment: .bottom) { DS.Color.border.frame(height: ComputersMetrics.separator) }
    }

    private func modeButton(_ mode: String, _ title: String) -> some View {
        ActionButton(.trafficSet, id: .trafficMode(mode), argument: .select("\(name)|mode=\(mode)")) {
            Text(verbatim: title).dsFont(DS.Font.small)
                .foregroundStyle(state.mode == mode ? DS.Color.textPrimary : DS.Color.textSecondary)
                .padding(.horizontal, DS.Space.s2_5)
                .frame(height: (DS.Space.s4 + DS.Space.s1))
                .background(RoundedRectangle(cornerRadius: DS.Radius.sm).fill(state.mode == mode ? DS.Color.accent : Color.clear))
        }
        .buttonStyle(.plain)
    }

    // MARK: Filtros

    private func toolbar(_ wide: Bool) -> some View {
        let s = traffic.stats[name] ?? TrafficStats()
        return HStack(spacing: DS.Space.s2) {
            HStack(spacing: DS.Space.s1_5) {
                Image(systemName: "magnifyingglass").font(.system(size: DS.Space.s3)).foregroundStyle(DS.Color.textTertiary)
                TextField(String(localized: "Search requests", bundle: .module), text: $query)
                    .help(String(localized: "Filter by URL, host, method or status", bundle: .module))
                    .textFieldStyle(.plain).dsFont(DS.Font.small)
                    .onChange(of: query) { _, text in set("query", text) }
                    .a11y(.trafficSearch, kind: "textfield", value: query)
            }
            .padding(.horizontal, DS.Space.s2)
            .frame(minWidth: TrafficMetrics.searchMin, maxWidth: TrafficMetrics.search)
            .frame(height: DS.Space.s6)
            .background(RoundedRectangle(cornerRadius: DS.Radius.md).fill(DS.Color.secondary))
            if !wide { hostMenu(s) }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Space.s1) {
                    chip("all", nil, String(localized: "All", bundle: .module), s.total)
                    ForEach(TrafficCategory.allCases.filter { (s.categories[$0] ?? 0) > 0 }, id: \.self) { category in
                        chip(category.rawValue, category, TrafficRowView.label(category), s.categories[category] ?? 0)
                    }
                    if s.errors > 0 { chip("errors", nil, String(localized: "Failed", bundle: .module), s.errors) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, DS.Space.s3)
        .frame(height: DS.Layout.paneHeaderHeight + DS.Space.s1)
        .overlay(alignment: .bottom) { DS.Color.border.frame(height: ComputersMetrics.separator) }
    }

    /// Estreito: os hosts num menu (o mesmo `traffic.set host=` da lista).
    private func hostMenu(_ s: TrafficStats) -> some View {
        let all = "\(name)|host="
        let entries: [DSMenuEntry] = [.item(DSMenuItem(all, String(localized: "All hosts", bundle: .module), detail: s.total.formatted(), detailMono: true))]
            + s.hosts.prefix(60).map { .item(DSMenuItem("\(name)|host=\($0.host)", $0.host, detail: $0.count.formatted(), detailMono: true)) }
        return DSCombobox(
            id: .trafficHost("menu"), selection: state.host.map { "\(name)|host=\($0)" } ?? all, entries: entries, action: .trafficSet,
            height: DS.Space.s6)
            .frame(maxWidth: TrafficMetrics.hostMenu)
    }

    private func chip(_ key: String, _ category: TrafficCategory?, _ title: String, _ count: Int) -> some View {
        let on = state.filter == key
        return ActionButton(.trafficSet, id: .trafficFilter(key), argument: .select("\(name)|filter=\(key)")) {
            HStack(spacing: DS.Space.s1) {
                if let category { CategoryIcon(category: category) }
                Text(verbatim: title).foregroundStyle(key == "errors" ? DS.Color.destructive : on ? DS.Color.textPrimary : DS.Color.textSecondary)
                Text(verbatim: count.formatted()).foregroundStyle(DS.Color.textTertiary).monospacedDigit()
            }
            .dsFont(DS.Font.small)
            .padding(.horizontal, DS.Space.s2)
            .frame(height: (DS.Space.s4 + DS.Space.s1 + DS.Space.s0_5))
            .background(RoundedRectangle(cornerRadius: DS.Radius.sm).fill(on ? DS.Color.sidebarSelected : Color.clear))
        }
        .buttonStyle(.plain)
    }

    // MARK: Hosts

    private var hosts: some View {
        let s = traffic.stats[name] ?? TrafficStats()
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text("Hosts", bundle: .module).dsFont(DS.Font.micro).foregroundStyle(DS.Color.textTertiary)
                    .padding(.horizontal, DS.Space.s2).padding(.vertical, DS.Space.s2)
                hostRow(nil, String(localized: "All hosts", bundle: .module), s.total)
                ForEach(s.hosts.prefix(80), id: \.host) { hostRow($0.host, $0.host, $0.count) }
            }
            .padding(DS.Space.s1)
            .background(OverlayScrollerConfigurator())
        }
        .frame(width: TrafficMetrics.hosts)
        .background(DS.Color.panel)
    }

    private func hostRow(_ host: String?, _ title: String, _ count: Int) -> some View {
        let on = state.host == host
        return ActionButton(.trafficSet, id: .trafficHost(host ?? "all"), argument: .select("\(name)|host=\(host ?? "")")) {
            HStack(spacing: DS.Space.s1) {
                Text(verbatim: title).dsFont(DS.Font.small).foregroundStyle(on ? DS.Color.textPrimary : DS.Color.textSecondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: DS.Space.s1)
                Text(verbatim: count.formatted()).dsFont(DS.Font.microNumeric).foregroundStyle(DS.Color.textTertiary)
            }
            .padding(.horizontal, DS.Space.s2)
            .frame(height: DS.Space.s6)
            .background(RoundedRectangle(cornerRadius: DS.Radius.sm).fill(on ? DS.Color.sidebarSelected : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Tabela

    private func table(_ wide: Bool) -> some View {
        let list = traffic.visibleEntries(name)
        return VStack(spacing: 0) {
            HStack(spacing: DS.Space.s2) {
                Text("Status", bundle: .module).frame(width: TrafficMetrics.pill, alignment: .leading)
                Text("Method", bundle: .module).frame(width: TrafficMetrics.method, alignment: .leading)
                Text("Host and path", bundle: .module).frame(maxWidth: .infinity, alignment: .leading)
                if wide { Text("Kind", bundle: .module).frame(width: TrafficMetrics.type, alignment: .leading) }
                Text("Size", bundle: .module).frame(width: TrafficMetrics.size, alignment: .trailing)
                Text("Time", bundle: .module).frame(width: TrafficMetrics.time, alignment: .trailing)
            }
            .dsFont(DS.Font.micro).foregroundStyle(DS.Color.textTertiary)
            .padding(.horizontal, DS.Space.s3)
            .frame(height: DS.Space.s6)
            .overlay(alignment: .bottom) { DS.Color.border.frame(height: ComputersMetrics.separator) }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(list.prefix(TrafficMetrics.maxRows)) { entry in
                        ActionButton(.trafficSet, id: .trafficRow(entry.id), argument: .select("\(name)|select=\(entry.id)")) {
                            TrafficRowView(entry: entry, compact: !wide, selected: entry.id == state.selected, tall: true)
                        }
                        .buttonStyle(.plain)
                    }
                    if list.isEmpty {
                        Text("No requests match.", bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).padding(DS.Space.s6)
                    }
                }
                .background(OverlayScrollerConfigurator())
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: Detalhe

    @ViewBuilder private func detail(_ wide: Bool, height: CGFloat) -> some View {
        if let entry = traffic.entry(name, state.selected) {
            VStack(spacing: 0) {
                HStack(spacing: DS.Space.s2) {
                    Text(verbatim: entry.method).dsFont(DS.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary).fixedSize()
                    Text(verbatim: entry.type == "tunnel" ? entry.url : entry.path).dsFont(DS.Font.monoCell).foregroundStyle(DS.Color.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                    if wide { Text(verbatim: entry.host).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).lineLimit(1) }
                    Spacer(minLength: DS.Space.s2)
                    pill(entry.blocked ? String(localized: "blocked · \(entry.blockedReason ?? "")", bundle: .module)
                         : entry.status.map(TrafficController.statusLine) ?? "—")
                    pill(TrafficController.size(entry.bytes))
                    pill(TrafficRowView.duration(entry.durationMs))
                    if wide { pill("\(TrafficRowView.label(entry.category)) · \(entry.via == "direct" ? entry.source : entry.via)") }
                    DSButton(.trafficCopyCurl, id: .trafficCopyCurl, "Copy as cURL", variant: .outline, size: .xs, argument: .select("\(name)|\(entry.id)"))
                        .fixedSize()
                }
                .padding(.horizontal, DS.Space.s3)
                .frame(height: DS.Layout.paneHeaderHeight + DS.Space.s1)
                .overlay(alignment: .bottom) { DS.Color.border.frame(height: ComputersMetrics.separator) }
                let request = MessageView(
                    title: String(localized: "Request", bundle: .module), side: "requestTab", tab: state.requestTab, computer: name,
                    headers: entry.requestHeaders, payload: traffic.body(name, entry, kind: "request"),
                    firstLine: "\(entry.method) \(entry.path)", titleSide: wide ? nil : "request", shownSide: state.detailSide)
                let response = MessageView(
                    title: String(localized: "Response", bundle: .module), side: "responseTab", tab: state.responseTab, computer: name,
                    headers: entry.responseHeaders, payload: traffic.body(name, entry, kind: "response"),
                    firstLine: entry.status.map { "HTTP \($0)" } ?? (entry.error ?? ""), titleSide: wide ? nil : "response", shownSide: state.detailSide)
                if wide {
                    HStack(spacing: 0) {
                        request
                        DS.Color.border.frame(width: ComputersMetrics.separator)
                        response
                    }
                } else if state.detailSide == "request" {
                    request
                } else {
                    response
                }
            }
            .frame(height: height)
            .a11y(.trafficDetail, kind: "group", label: entry.url)
        } else {
            Text("Pick a request to see its headers and body.", bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                .frame(maxWidth: .infinity).frame(height: TrafficMetrics.detailEmpty)
        }
    }

    private func pill(_ text: String) -> some View {
        Text(verbatim: text).dsFont(DS.Font.small).monospacedDigit().foregroundStyle(DS.Color.textSecondary).lineLimit(1)
            .padding(.horizontal, DS.Space.s2).frame(height: (DS.Space.s4 + DS.Space.s1))
            .background(RoundedRectangle(cornerRadius: DS.Radius.sm).fill(DS.Color.secondary))
    }
}

/// Request ou response: cabeçalhos, corpo (JSON formatado quando dá) ou o bruto.
private struct MessageView: View {
    let title: String
    let side: String
    let tab: String
    let computer: String
    let headers: [[String]]
    let payload: Data?
    let firstLine: String
    /// Estreito: `request`/`response` (os dois títulos viram abas que trocam o lado mostrado); largo: `nil`.
    var titleSide: String?
    var shownSide = "response"

    var body_: String {
        guard let payload, !payload.isEmpty else { return String(localized: "No body.", bundle: .module) }
        if let object = try? JSONSerialization.jsonObject(with: payload, options: [.fragmentsAllowed]),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes]) {
            return String(decoding: pretty.prefix(TrafficMetrics.maxBody), as: UTF8.self)
        }
        return String(decoding: payload.prefix(TrafficMetrics.maxBody), as: UTF8.self)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.s3) {
                if titleSide != nil {
                    sideButton("request", String(localized: "Request", bundle: .module))
                    sideButton("response", String(localized: "Response", bundle: .module))
                    DS.Color.border.frame(width: ComputersMetrics.separator, height: DS.Space.s3)
                } else {
                    Text(verbatim: title).dsFont(DS.Font.sectionLabel).foregroundStyle(DS.Color.textSecondary)
                }
                tabButton("headers", headers.isEmpty ? String(localized: "Headers", bundle: .module) : String(localized: "Headers \(headers.count)", bundle: .module))
                tabButton("body", String(localized: "Body", bundle: .module))
                tabButton("raw", String(localized: "Raw", bundle: .module))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.s3)
            .frame(height: (DS.Space.s6 + DS.Space.s1))
            ScrollView([.vertical]) {
                Group {
                    switch tab {
                    case "headers": headerList
                    case "raw": mono(([firstLine] + headers.map { "\($0[0]): \(Self.safe($0))" }).joined(separator: "\n") + "\n\n" + body_)
                    default: mono(body_)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Space.s3)
                .padding(.bottom, DS.Space.s3)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Cookies e autorização não aparecem por inteiro (o print de tela vaza fácil).
    static func safe(_ header: [String]) -> String {
        ["cookie", "set-cookie", "authorization", "proxy-authorization"].contains(header[0].lowercased()) ? "•••••• (\(header[1].count) chars)" : header[1]
    }

    private var headerList: some View {
        VStack(alignment: .leading, spacing: DS.Space.s0_5) {
            if headers.isEmpty { Text("No headers.", bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary) }
            ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
                    Text(verbatim: header[0]).foregroundStyle(DS.Color.textTertiary).frame(width: TrafficMetrics.headerKey, alignment: .leading)
                    Text(verbatim: Self.safe(header)).foregroundStyle(DS.Color.textSecondary).textSelection(.enabled)
                }
                .dsFont(DS.Font.monoCell).lineLimit(2)
            }
        }
    }

    private func mono(_ text: String) -> some View {
        Text(verbatim: text).dsFont(DS.Font.monoCell).foregroundStyle(DS.Color.textSecondary).textSelection(.enabled)
    }

    private func sideButton(_ key: String, _ label: String) -> some View {
        ActionButton(.trafficSet, id: .trafficDetailSide(key), argument: .select("\(computer)|side=\(key)")) {
            Text(verbatim: label).dsFont(DS.Font.sectionLabel).foregroundStyle(shownSide == key ? DS.Color.textPrimary : DS.Color.textTertiary)
        }
        .buttonStyle(.plain)
    }

    private func tabButton(_ key: String, _ label: String) -> some View {
        ActionButton(.trafficSet, id: side == "requestTab" ? .trafficRequestTab(key) : .trafficResponseTab(key), argument: .select("\(computer)|\(side)=\(key)")) {
            Text(verbatim: label).dsFont(DS.Font.small).foregroundStyle(tab == key ? DS.Color.textPrimary : DS.Color.textTertiary)
        }
        .buttonStyle(.plain)
    }
}

/// Activity: o que o agente rodou no terminal do computador, o mais novo em cima.
private struct ActivityListView: View {
    let entries: [ActivityEntry]
    let computer: String

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if entries.isEmpty {
                    Text("No commands yet.", bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).padding(DS.Space.s6)
                }
                ForEach(entries) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.s3) {
                        Text(verbatim: entry.at.formatted(date: .omitted, time: .standard)).dsFont(DS.Font.monoCell).foregroundStyle(DS.Color.textTertiary)
                        Text(verbatim: entry.exit.map { String(localized: "exit \($0)", bundle: .module) } ?? "…").dsFont(DS.Font.monoCell)
                            .foregroundStyle((entry.exit ?? 0) == 0 ? DS.Color.textTertiary : DS.Color.destructive)
                            .frame(width: TrafficMetrics.method, alignment: .leading)
                        Text(verbatim: entry.shell).dsFont(DS.Font.monoCell).foregroundStyle(DS.Color.textPrimary).lineLimit(3).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(verbatim: entry.durationMs.map { "\($0) ms" } ?? "").dsFont(DS.Font.monoCell).foregroundStyle(DS.Color.textTertiary)
                    }
                    .padding(.horizontal, DS.Space.s3)
                    .padding(.vertical, DS.Space.s1_5)
                    .overlay(alignment: .bottom) { DS.Color.border.opacity(0.6).frame(height: ComputersMetrics.separator) }
                    .a11y(.trafficActivityRow(entry.id), kind: "row", label: entry.shell)
                }
            }
            .background(OverlayScrollerConfigurator())
        }
    }
}

extension TrafficMetrics {
    /// Abaixo disto a tela usa o arranjo estreito.
    static let wide: CGFloat = 980
    static let searchMin: CGFloat = 120
    static let hostMenu: CGFloat = 180
    static let search: CGFloat = 280
    static let detail: CGFloat = 320
    static let detailMin: CGFloat = 170
    static let detailEmpty: CGFloat = 80
    static let maxRows = 2_000
    static let maxBody = 200_000
}
