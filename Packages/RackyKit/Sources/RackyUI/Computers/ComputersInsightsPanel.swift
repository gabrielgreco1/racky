import RackyCore
import RackyDesignSystem
import RackyProtocol
import SwiftUI

/// Aba Computers do painel direito: um computador da sessão por vez. A tela dele, as requests ao longo do run (dados, assets e
/// ruído empilhados), o que deu errado, com quem ele falou, o proxy com o logo do provedor e o custo, e a lista ao vivo. Um clique
/// numa request abre o essencial ali mesmo; a tela Traffic inteira fica no botão do cabeçalho.
struct ComputersInsightsPanel: View {
    let computers: ComputersController
    let traffic: TrafficController
    let insights: InsightsModel?

    var body: some View {
        if let name = traffic.shownComputer {
            let s = traffic.stats[name] ?? TrafficStats()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    header(name)
                    screen(name)
                    numbers(s)
                    noiseNote(s)
                    talkedTo(s)
                    proxies(name, s)
                    machine(name)
                    Section { live(name) } header: { liveHeader(name) }
                }
                .background(OverlayScrollerConfigurator())
            }
            .background(DS.Color.panel)
        } else {
            Text("No computers in this session. Agents create them when they need a browser.", bundle: .module)
                .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).multilineTextAlignment(.center)
                .padding(DS.Space.s4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DS.Color.panel)
                .a11y(.rightPanelComputersEmpty, kind: "text")
        }
    }

    private func row(_ name: String) -> ComputerRow? { computers.model.rows.first { $0.id == name } }

    // MARK: Cabeçalho

    private func header(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            HStack(spacing: DS.Space.s2) {
                let list = traffic.sessionComputers
                if list.count > 1 {
                    DSCombobox(
                        id: .rightPanelComputersPick, selection: name,
                        entries: list.map { .item(DSMenuItem($0, $0, detail: (traffic.stats[$0]?.total ?? 0).formatted(), detailMono: true)) },
                        action: .rightPanelComputersPick, height: DSMetrics.fieldHeightComposer - DS.Space.s1)
                        .fixedSize()
                } else {
                    Text(verbatim: name).dsFont(DS.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                }
                Spacer(minLength: DS.Space.s1)
                DSButton(
                    .computerOpenTraffic, id: .rightPanelComputersOpenTraffic, "Traffic", variant: .outline, size: .xs, symbol: "arrow.up.right",
                    argument: .select(name))
            }
            HStack(spacing: DS.Space.s2) {
                StatusChip(working: row(name)?.snapshot.state == .inUse, text: statusText(name))
                Text(verbatim: whereText(name)).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.horizontal, DS.Space.s3)
        .padding(.top, DS.Space.s2_5)
        .padding(.bottom, DS.Space.s2_5)
    }

    /// `Working · 12 min` / `Finished · 4 min`.
    private func statusText(_ name: String) -> String {
        let s = traffic.stats[name]
        let minutes = s.flatMap { stats in stats.first.map { Int(((stats.last ?? Date()).timeIntervalSince($0) / 60).rounded()) } } ?? 0
        let state = row(name)?.snapshot.state == .inUse ? String(localized: "Working", bundle: .module) : String(localized: "Finished", bundle: .module)
        return minutes > 0 ? String(localized: "\(state) · \(minutes) min", bundle: .module) : state
    }

    /// `booking.com · via Zyte`.
    private func whereText(_ name: String) -> String {
        var parts: [String] = []
        if let url = row(name)?.snapshot.url, let host = URL(string: url)?.host() { parts.append(host) }
        // O proxy que o computador usa agora (a escolha do usuário vale na hora); terminado, o último que apareceu no log.
        let current = row(name)?.snapshot.proxy ?? traffic.entries[name]?.last(where: { !$0.blocked })?.via
        if let current, current != "direct" { parts.append(String(localized: "via \(brandTitle(current))", bundle: .module)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func screen(_ name: String) -> some View {
        if let row = row(name) {
            ActionButton(.computerOpenViewer, argument: .select(name), tooltip: String(localized: "Open the screen", bundle: .module)) {
                ComputerThumbnailView(row: row)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, DS.Space.s3)
            .padding(.bottom, DS.Space.s3)
        }
    }

    // MARK: Números

    /// Quatro cartões no formato do painel de Data: quantas requests (linha acumulada), quantas responderam bem (verde, bloqueadas
    /// em cinza, falhas em vermelho), as chamadas de API onde os dados costumam estar (verde) e quanto veio.
    private func numbers(_ s: TrafficStats) -> some View {
        let ok = max(s.total - s.errors - s.blocked, 0)
        let okShare = s.total == 0 ? 0 : Double(ok) / Double(s.total)
        let api = (s.categories[.api] ?? 0) + (s.categories[.page] ?? 0)
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: DS.Space.s2), GridItem(.flexible())], spacing: DS.Space.s2) {
            CompactTile(
                title: String(localized: "Requests", bundle: .module), value: s.total.formatted(), unit: nil,
                detail: s.recent > 0 ? String(localized: "+\(s.recent.formatted()) in 5 min", bundle: .module) : nil, detailTone: DS.Color.dataValid
            ) { CumulativeLine(values: s.timeline.map { $0.reduce(0, +) }) }
            CompactTile(
                title: String(localized: "Responses", bundle: .module), value: DatasetOverviewTiles.percent(okShare), unit: String(localized: "OK", bundle: .module),
                detail: s.errors > 0 ? String(localized: "\(s.errors.formatted()) errors", bundle: .module)
                    : s.blocked > 0 ? String(localized: "\(s.blocked.formatted()) blocked", bundle: .module) : nil,
                detailTone: s.errors > 0 ? DS.Color.destructive : DS.Color.textTertiary
            ) {
                SegmentBar(segments: [(Double(ok), DS.Color.dataValid), (Double(s.blocked), DS.Color.textQuaternary), (Double(s.errors), DS.Color.destructive)])
            }
            CompactTile(
                title: String(localized: "API calls", bundle: .module), value: api.formatted(), unit: nil,
                detail: String(localized: "where the data is", bundle: .module), detailTone: DS.Color.textTertiary
            ) { MiniBars(values: s.timeline.map { $0.first ?? 0 }) }
            CompactTile(
                title: String(localized: "Data in", bundle: .module), value: TrafficController.size(s.bytes), unit: nil,
                detail: String(localized: "\(s.hosts.count) hosts", bundle: .module), detailTone: DS.Color.textTertiary
            ) { SegmentBar(segments: s.hosts.prefix(6).map { (Double($0.count), PanelMetrics.color(s.hostCategory[$0.host] ?? .other).opacity(0.85)) }) }
        }
        .padding(.horizontal, DS.Space.s3)
        .padding(.bottom, DS.Space.s3)
        .a11y(.rightPanelComputersStats, kind: "group", value: "\(s.total)")
    }

    @ViewBuilder private func noiseNote(_ s: TrafficStats) -> some View {
        let noise = (s.categories[.analytics] ?? 0) + (s.categories[.antibot] ?? 0)
        if s.total > 20, noise * 5 >= s.total {
            HStack(spacing: DS.Space.s1_5) {
                CategoryIcon(category: .analytics)
                Text(verbatim: String(localized: "\(Int((Double(noise) / Double(s.total) * 100).rounded()))% of the traffic is analytics and anti-bot", bundle: .module))
                    .dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary)
            }
            .padding(.horizontal, DS.Space.s3)
            .padding(.bottom, DS.Space.s3)
        }
    }

    // MARK: Com quem falou

    /// Com quem o computador falou de verdade: o ruído bloqueado do próprio Chrome fica numa linha no fim. Cada host com o domínio
    /// em destaque (o subdomínio apagado), a barra dividida pelos tipos e quanto veio dele.
    @ViewBuilder private func talkedTo(_ s: TrafficStats) -> some View {
        if !s.hosts.isEmpty {
            let top = Array(s.activeHosts.prefix(6))
            let peak = max(top.first?.count ?? 1, 1)
            VStack(alignment: .leading, spacing: 0) {
                sectionTitle(String(localized: "Talked to", bundle: .module), trailing: String(localized: "\(s.activeHosts.count) hosts", bundle: .module))
                ForEach(top, id: \.host) { item in hostRow(item.host, item.count, peak: peak, s) }
                if s.blocked > 0 {
                    HStack(spacing: DS.Space.s2) {
                        Image(systemName: "nosign").font(.system(size: TrafficMetrics.icon)).foregroundStyle(DS.Color.textQuaternary)
                        Text(verbatim: String(localized: "\(s.blocked.formatted()) requests blocked as noise", bundle: .module))
                            .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                        Spacer(minLength: 0)
                    }
                    .frame(height: PanelMetrics.hostRow)
                    .help(String(localized: "The browser's own traffic (updates, autofill, sign-in) that Racky drops before it leaves the computer.", bundle: .module))
                }
            }
            .padding(.horizontal, DS.Space.s3)
            .padding(.bottom, DS.Space.s3)
        }
    }

    private func hostRow(_ host: String, _ count: Int, peak: Int, _ s: TrafficStats) -> some View {
        let kinds = (s.hostKinds[host] ?? [:]).filter { $0.key != .blocked }
        let parts = host.split(separator: ".")
        let domain = parts.count > 2 ? parts.suffix(2).joined(separator: ".") : host
        let sub = parts.count > 2 ? parts.dropLast(2).joined(separator: ".") + "." : ""
        let order: [TrafficCategory] = [.api, .page, .antibot, .analytics, .asset, .tunnel, .other]
        let shown = order.filter { (kinds[$0] ?? 0) > 0 }
        return VStack(alignment: .leading, spacing: DS.Space.s1) {
            HStack(spacing: DS.Space.s2) {
                (Text(verbatim: sub).foregroundStyle(DS.Color.textTertiary) + Text(verbatim: domain).foregroundStyle(DS.Color.textPrimary))
                    .dsFont(DS.Font.cell).lineLimit(1).truncationMode(.head)
                Spacer(minLength: DS.Space.s2)
                Text(verbatim: TrafficController.size(s.hostBytes[host])).dsFont(DS.Font.monoCell).foregroundStyle(DS.Color.textTertiary)
                Text(verbatim: count.formatted()).dsFont(DS.Font.monoCell).foregroundStyle(DS.Color.textSecondary)
                    .frame(width: PanelMetrics.count, alignment: .trailing)
            }
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(shown, id: \.self) { kind in
                        let width = max(geo.size.width * CGFloat(kinds[kind, default: .zero]) / CGFloat(peak) - DSMetrics.hairline, DS.Space.s0_5)
                        RoundedRectangle(cornerRadius: DS.Space.s0_5).fill(PanelMetrics.color(kind).opacity(0.85)).frame(width: width)
                    }
                }
            }
            .frame(height: DS.Space.s1)
            .help(shown.map { "\(TrafficRowView.label($0)) \(kinds[$0] ?? 0)" }.joined(separator: " · "))
        }
        .padding(.vertical, DS.Space.s1)
    }

    private func sectionTitle(_ title: String, trailing: String? = nil) -> some View {
        HStack {
            Text(verbatim: title).dsFont(DS.Font.sectionLabel).foregroundStyle(DS.Color.textTertiary)
            Spacer(minLength: DS.Space.s1)
            if let trailing { Text(verbatim: trailing).dsFont(DS.Font.small).foregroundStyle(DS.Color.textQuaternary) }
        }
        .padding(.bottom, DS.Space.s1)
    }

    // MARK: Proxy

    private func brand(_ via: String) -> DSProxyBrand? { DSProxyBrand.detect(via, traffic.proxies[via]?.host ?? "") }
    private func brandTitle(_ via: String) -> String { brand(via)?.title ?? via }

    /// Por onde o computador sai: uma linha por saída usada (direto ou cada proxy, com o logo do provedor), a fatia que respondeu OK,
    /// quantas requests e o custo. Com o computador vivo, `Change` troca a saída na hora.
    private func proxies(_ name: String, _ s: TrafficStats) -> some View {
        let current = row(name)?.snapshot.proxy
        let vias = s.vias.sorted { ($0.name == current ? 0 : 1, -$0.requests) < ($1.name == current ? 0 : 1, -$1.requests) }
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Exit", bundle: .module).dsFont(DS.Font.sectionLabel).foregroundStyle(DS.Color.textTertiary)
                Spacer(minLength: DS.Space.s1)
                if row(name) != nil {
                    ActionButton(
                        .computerSetProxy, id: .rightPanelComputersChangeExit, argument: .select(name),
                        tooltip: String(localized: "Send this computer's traffic through another proxy", bundle: .module)
                    ) {
                        HStack(spacing: DS.Space.s1) {
                            Text("Change…", bundle: .module)
                            Image(systemName: "chevron.down").font(.system(size: TrafficMetrics.icon - 2, weight: .semibold))
                        }
                        .dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, DS.Space.s1_5)
            VStack(spacing: 0) {
                if vias.isEmpty {
                    Text("No traffic yet.", bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).padding(DS.Space.s2_5)
                }
                ForEach(Array(vias.enumerated()), id: \.element.id) { index, via in
                    exitRow(via, ok: s.viaOK[via.name] ?? 0, current: via.name == current)
                    if index < vias.count - 1 { DS.Color.border.frame(height: ComputersMetrics.separator) }
                }
            }
            .background(RoundedRectangle(cornerRadius: DS.Radius.md).fill(DS.Color.chrome))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).strokeBorder(DS.Color.border))
            if vias.contains(where: { $0.name != "direct" && traffic.cost($0) == nil }) {
                Text("Set a price per request in Settings › Computers › Proxies to see the cost.", bundle: .module)
                    .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).padding(.top, DS.Space.s1_5)
            }
        }
        .padding(.horizontal, DS.Space.s3)
        .padding(.bottom, DS.Space.s3)
        .a11y(.rightPanelComputersProxies, kind: "group", value: "\(s.vias.count)")
    }

    private func exitRow(_ via: TrafficVia, ok: Int, current: Bool) -> some View {
        let direct = via.name == "direct"
        let mark = brand(via.name)
        let share = via.requests == 0 ? 0 : Double(ok) / Double(via.requests)
        return HStack(spacing: DS.Space.s2_5) {
            Group {
                if let mark {
                    DSProxyLogo(mark, size: PanelMetrics.exitLogo)
                } else {
                    Image(systemName: direct ? "point.topleft.down.to.point.bottomright.curvepath" : "network")
                        .font(.system(size: PanelMetrics.exitLogo * 0.55))
                        .foregroundStyle(DS.Color.textSecondary)
                        .frame(width: PanelMetrics.exitLogo, height: PanelMetrics.exitLogo)
                        .background(RoundedRectangle(cornerRadius: PanelMetrics.exitLogo * 0.24).fill(DS.Color.secondary))
                }
            }
            VStack(alignment: .leading, spacing: DS.Space.s0_5) {
                HStack(spacing: DS.Space.s1_5) {
                    Text(verbatim: direct ? String(localized: "Direct", bundle: .module) : mark?.title ?? via.name)
                        .dsFont(DS.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                    if current { Text("In use", bundle: .module).dsFont(DS.Font.micro).foregroundStyle(DS.Color.locate) }
                }
                Text(verbatim: String(localized: "\(via.requests.formatted()) req · \(TrafficController.size(via.bytes))", bundle: .module))
                    .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).lineLimit(1)
            }
            Spacer(minLength: DS.Space.s2)
            VStack(alignment: .trailing, spacing: DS.Space.s1) {
                Text(verbatim: String(localized: "\(Int((share * 100).rounded()))% OK", bundle: .module)).dsFont(DS.Font.monoCell)
                    .foregroundStyle(share >= 0.9 ? DS.Color.dataValid : share >= 0.6 ? DS.Color.warning : DS.Color.destructive)
                SegmentBar(segments: [(share, DS.Color.dataValid), (max(1 - share, 0), DS.Color.destructive.opacity(0.7))])
                    .frame(width: PanelMetrics.exitBar, height: DS.Space.s1)
            }
            Text(verbatim: direct ? String(localized: "Free", bundle: .module) : traffic.cost(via).map { "≈ \(TrafficController.money($0))" } ?? "—")
                .dsFont(DS.Font.bodyStrong).monospacedDigit().foregroundStyle(DS.Color.textPrimary)
                .frame(minWidth: PanelMetrics.exitCost, alignment: .trailing)
        }
        .padding(.horizontal, DS.Space.s2_5)
        .padding(.vertical, DS.Space.s2)
    }

    // MARK: Máquina

    @ViewBuilder private func machine(_ name: String) -> some View {
        if let usage = insights?.snapshot.computers.first(where: { $0.name == name || $0.name.hasSuffix(name) }) {
            HStack(spacing: DS.Space.s4) {
                meter(String(localized: "CPU", bundle: .module), "\(Int(usage.cpuPercent.rounded()))%", min(usage.cpuPercent / 100, 1))
                meter(
                    String(localized: "Memory", bundle: .module),
                    "\(TrafficController.size(usage.memoryBytes)) / \(TrafficController.size(usage.memoryLimitBytes))", usage.memoryFraction)
            }
            .padding(.horizontal, DS.Space.s3)
            .padding(.bottom, DS.Space.s3)
        }
    }

    private func meter(_ title: String, _ value: String, _ fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            HStack {
                Text(verbatim: title).dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary)
                Spacer(minLength: DS.Space.s1)
                Text(verbatim: value).dsFont(DS.Font.monoCell).foregroundStyle(DS.Color.textPrimary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.Color.secondary)
                    Capsule().fill(DS.Color.textSecondary).frame(width: geo.size.width * CGFloat(fraction))
                }
            }
            .frame(height: DS.Space.s1)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Ao vivo

    private func liveHeader(_ name: String) -> some View {
        HStack(spacing: DS.Space.s1_5) {
            Circle().fill(row(name)?.snapshot.state == .inUse ? DS.Color.locate : DS.Color.textQuaternary).frame(width: DS.Space.s1_5, height: DS.Space.s1_5)
            Text("Live", bundle: .module).dsFont(DS.Font.sectionLabel).foregroundStyle(DS.Color.textSecondary)
            Spacer(minLength: DS.Space.s1)
            ForEach(["all", "api", "errors"], id: \.self) { filter in
                ActionButton(.rightPanelComputersPick, id: .rightPanelComputersFilter(filter), argument: .select("\(name)|\(filter)")) {
                    Text(verbatim: filter == "all" ? String(localized: "All", bundle: .module) : filter == "api" ? String(localized: "API", bundle: .module)
                         : String(localized: "Failed", bundle: .module))
                        .dsFont(DS.Font.small)
                        .foregroundStyle(traffic.panelFilter == filter ? DS.Color.textPrimary : DS.Color.textTertiary)
                        .padding(.horizontal, DS.Space.s2)
                        .frame(height: PanelMetrics.segment)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.sm).fill(traffic.panelFilter == filter ? DS.Color.sidebarSelected : Color.clear))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, DS.Space.s3)
        .frame(height: DatasetPanelMetrics.headerRow + DS.Space.s2)
        .background(DS.Color.chrome)
        .overlay(alignment: .top) { DS.Color.border.frame(height: ComputersMetrics.separator) }
        .overlay(alignment: .bottom) { DS.Color.border.frame(height: ComputersMetrics.separator) }
    }

    @ViewBuilder private func live(_ name: String) -> some View {
        let list = traffic.panelEntries(name)
        if list.isEmpty {
            Text("No requests yet.", bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                .frame(maxWidth: .infinity).padding(.vertical, DS.Space.s6)
        } else {
            // Clique abre o detalhe ali mesmo (a tela Traffic inteira fica no botão do cabeçalho).
            let selected = traffic.state(name).selected
            ForEach(list) { entry in
                ActionButton(.trafficSet, id: .rightPanelComputersRequest(entry.id), argument: .select("\(name)|select=\(entry.id)")) {
                    TrafficRowView(entry: entry, compact: true, selected: entry.id == selected)
                }
                .buttonStyle(.plain)
                if entry.id == selected { inlineDetail(name, entry) }
            }
        }
    }
}

extension ComputersInsightsPanel {
    /// O essencial de uma request debaixo da linha: URL inteira, números e os primeiros cabeçalhos; o resto no Traffic.
    func inlineDetail(_ name: String, _ entry: TrafficEntry) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s1_5) {
            Text(verbatim: entry.url).dsFont(DS.Font.monoCell).foregroundStyle(DS.Color.textPrimary).lineLimit(3).textSelection(.enabled)
            Text(verbatim: [entry.status.map { "HTTP \($0)" } ?? entry.error ?? "", TrafficController.size(entry.bytes), TrafficRowView.duration(entry.durationMs),
                            TrafficRowView.label(entry.category), entry.via == "direct" ? entry.source : "\(entry.source) · \(entry.via)"]
                .filter { !$0.isEmpty }.joined(separator: " · "))
                .dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary)
            ForEach(Array(entry.responseHeaders.prefix(4).enumerated()), id: \.offset) { _, header in
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
                    Text(verbatim: header[0]).foregroundStyle(DS.Color.textTertiary)
                    Text(verbatim: header[1]).foregroundStyle(DS.Color.textSecondary).lineLimit(1)
                }
                .dsFont(DS.Font.monoCell)
            }
            DSButton(.computerOpenTraffic, id: nil, "Open in Traffic", variant: .outline, size: .xs, symbol: "arrow.up.right", argument: .select("\(name)|\(entry.id)"))
        }
        .padding(DS.Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.sidebarSelected.opacity(0.5))
    }
}

/// `● Working · 12 min`: verde enquanto o computador trabalha (como `Collecting` no Data), neutro quando terminou.
private struct StatusChip: View {
    let working: Bool
    let text: String

    var body: some View {
        HStack(spacing: DS.Space.s1_5) {
            Circle().fill(working ? DS.Color.dataValid : DS.Color.textQuaternary).frame(width: DS.Space.s1_5, height: DS.Space.s1_5)
            Text(verbatim: text).dsFont(DS.Font.label).foregroundStyle(working ? DS.Color.dataValid : DS.Color.textSecondary).lineLimit(1)
        }
        .padding(.horizontal, DS.Space.s2)
        .frame(height: PanelMetrics.segment + DS.Space.s0_5)
        .background(Capsule().fill(working ? DS.Color.dataValid.opacity(0.1) : DS.Color.secondary))
        .fixedSize()
    }
}

enum PanelMetrics {
    static let chart: CGFloat = 72
    static let logo: CGFloat = 32
    static let hostRow: CGFloat = 26
    static let hostBar: CGFloat = 80
    static let count: CGFloat = 40
    static let segment: CGFloat = 22
    static let exitLogo: CGFloat = 26
    static let exitBar: CGFloat = 64
    static let exitCost: CGFloat = 56

    /// A cor de cada tipo: verde onde estão os dados (API, páginas, como as linhas válidas do Data), âmbar no anti-bot (atenção),
    /// cinza no resto e mais apagado no que foi bloqueado.
    static func color(_ category: TrafficCategory) -> Color {
        switch category {
        case .api, .page: DS.Color.dataValid
        case .antibot: DS.Color.warning
        case .blocked: DS.Color.textQuaternary
        default: DS.Color.textTertiary
        }
    }
}

/// O ícone da categoria de uma request, na cor do tipo (verde = dados, âmbar = anti-bot, cinza = o resto).
struct CategoryIcon: View {
    let category: TrafficCategory

    var body: some View {
        Image(systemName: TrafficRowView.symbol(category))
            .font(.system(size: TrafficMetrics.icon, weight: .medium))
            .foregroundStyle(PanelMetrics.color(category))
            .frame(width: TrafficMetrics.iconBox)
            .help(TrafficRowView.label(category))
    }
}

/// O status numa pílula: verde 2xx, âmbar 3xx e 4xx, vermelho 5xx e erro de rede, cinza bloqueada e túnel TLS.
struct StatusPill: View {
    let entry: TrafficEntry

    var body: some View {
        Text(verbatim: text).dsFont(DS.Font.monoCell).fontWeight(.semibold).foregroundStyle(color)
            .frame(width: TrafficMetrics.pill, height: TrafficMetrics.pillHeight)
            .background(RoundedRectangle(cornerRadius: DS.Radius.sm).fill(color.opacity(entry.blocked || entry.type == "tunnel" ? 0.08 : 0.12)))
    }

    private var text: String {
        if entry.blocked { return TrafficRowView.label(.blocked) }
        if entry.type == "tunnel" { return "TLS" }
        return entry.status.map(String.init) ?? "ERR"
    }

    private var color: Color {
        if entry.blocked || entry.type == "tunnel" { return DS.Color.textTertiary }
        guard let status = entry.status else { return DS.Color.destructive }
        if status < 300 { return DS.Color.dataValid }
        if status < 500 { return DS.Color.warning }
        return DS.Color.destructive
    }
}

/// Uma request. Na aba Computers (`compact`) em duas linhas: o caminho em destaque e, embaixo, o tipo, o host e o método. No
/// Traffic numa linha só, com as colunas.
struct TrafficRowView: View {
    let entry: TrafficEntry
    var compact = false
    var selected = false
    /// No Traffic estreito: uma linha, sem a coluna Kind.
    var tall = false
    @State private var hovering = false

    var body: some View {
        Group {
            if compact && !tall { twoLines } else { oneLine }
        }
        .padding(.horizontal, DS.Space.s3)
        .background(selected ? DS.Color.sidebarSelected : hovering ? DS.Color.hoverAgentRow : Color.clear)
        .overlay(alignment: .bottom) { DS.Color.border.opacity(0.6).frame(height: ComputersMetrics.separator) }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .opacity(entry.blocked ? 0.6 : 1)
        .accessibilityElement(children: .combine)
    }

    private var mainText: String { entry.type == "tunnel" ? entry.host : entry.path }

    private var twoLines: some View {
        HStack(spacing: DS.Space.s2_5) {
            StatusPill(entry: entry)
            VStack(alignment: .leading, spacing: DS.Space.s0_5) {
                Text(verbatim: mainText).dsFont(DS.Font.cell).foregroundStyle(DS.Color.textPrimary).lineLimit(1).truncationMode(.middle)
                HStack(spacing: DS.Space.s1) {
                    Circle().fill(PanelMetrics.color(entry.category)).frame(width: DS.Space.s1_5, height: DS.Space.s1_5)
                    Text(verbatim: [Self.label(entry.category), entry.host, entry.type == "tunnel" ? nil : entry.method].compactMap { $0 }.joined(separator: " · "))
                        .lineLimit(1).truncationMode(.middle)
                }
                .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: DS.Space.s0_5) {
                Text(verbatim: Self.duration(entry.durationMs)).foregroundStyle(DS.Color.textSecondary)
                Text(verbatim: TrafficController.size(entry.bytes)).foregroundStyle(DS.Color.textTertiary)
            }
            .dsFont(DS.Font.monoCell)
        }
        .padding(.vertical, DS.Space.s1_5)
    }

    private var oneLine: some View {
        HStack(spacing: DS.Space.s2) {
            StatusPill(entry: entry)
            Text(verbatim: entry.type == "tunnel" ? "" : entry.method).dsFont(DS.Font.monoCell).foregroundStyle(DS.Color.textTertiary)
                .frame(width: TrafficMetrics.method, alignment: .leading)
            (Text(verbatim: entry.host).foregroundStyle(DS.Color.textTertiary) + Text(verbatim: entry.type == "tunnel" ? "" : entry.path).foregroundStyle(
                entry.blocked ? DS.Color.textTertiary : DS.Color.textPrimary))
                .dsFont(DS.Font.cell).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !compact {
                HStack(spacing: DS.Space.s1) {
                    Circle().fill(PanelMetrics.color(entry.category)).frame(width: DS.Space.s1_5, height: DS.Space.s1_5)
                    Text(verbatim: Self.label(entry.category)).dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary)
                }
                .frame(width: TrafficMetrics.type, alignment: .leading)
            }
            Text(verbatim: TrafficController.size(entry.bytes)).dsFont(DS.Font.monoCell).foregroundStyle(DS.Color.textTertiary)
                .frame(width: TrafficMetrics.size, alignment: .trailing)
            Text(verbatim: Self.duration(entry.durationMs)).dsFont(DS.Font.monoCell).foregroundStyle(DS.Color.textSecondary)
                .frame(width: TrafficMetrics.time, alignment: .trailing)
        }
        .frame(height: TrafficMetrics.row)
    }

    /// `340 ms`, `12 s`, `5 min` (um túnel TLS dura o tempo da conexão inteira).
    static func duration(_ ms: Int?) -> String {
        guard let ms else { return "—" }
        if ms < 10_000 { return "\(ms) ms" }
        if ms < 120_000 { return "\(ms / 1000) s" }
        return "\(ms / 60_000) min"
    }

    static func symbol(_ category: TrafficCategory) -> String {
        switch category {
        case .page: "doc.text"
        case .api: "curlybraces"
        case .asset: "shippingbox"
        case .analytics: "chart.bar"
        case .antibot: "shield"
        case .tunnel: "lock"
        case .blocked: "nosign"
        case .other: "circle.dotted"
        }
    }

    static func label(_ category: TrafficCategory) -> String {
        switch category {
        case .page: String(localized: "Page", bundle: .module)
        case .api: String(localized: "API", bundle: .module)
        case .asset: String(localized: "Asset", bundle: .module)
        case .analytics: String(localized: "Analytics", bundle: .module)
        case .antibot: String(localized: "Anti-bot", bundle: .module)
        case .tunnel: String(localized: "TLS", bundle: .module)
        case .blocked: String(localized: "Blocked", bundle: .module)
        case .other: String(localized: "Other", bundle: .module)
        }
    }
}

enum TrafficMetrics {
    static let status: CGFloat = 30
    static let method: CGFloat = 50
    static let type: CGFloat = 70
    static let size: CGFloat = 58
    static let time: CGFloat = 54
    static let row: CGFloat = 28
    static let hosts: CGFloat = 210
    static let headerKey: CGFloat = 170
    static let icon: CGFloat = 11
    static let iconBox: CGFloat = 16
    static let pill: CGFloat = 52
    static let pillHeight: CGFloat = 20
}
