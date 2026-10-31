import RackyCore
import RackyDesignSystem
import RackyProtocol
import RackyStore
import SwiftUI

// Visão geral de um dataset: cartões que respondem, cada um, uma pergunta de quem coleta dados — quanto já veio, em que ritmo, se está
// bom, se as colunas estão cheias, como foram as requisições e de onde veio. Cada cartão tem nome claro, o número, um desenho pequeno
// que mostra a forma do dado e uma linha de contexto.

enum OverviewMetrics {
    static let tileHeight: CGFloat = 112
    static let tileMinWidth: CGFloat = 176
    static let tileSpacing = DS.Space.s3
    static let visualHeight: CGFloat = 22
    static let barHeight: CGFloat = 6
    static let barGap: CGFloat = 2
    static let iconSize: CGFloat = 11
}

/// A grade de cartões; quebra em mais linhas quando a área estreita.
struct DatasetOverviewTiles: View {
    let snapshot: DatasetPageSnapshot
    let controller: DatasetsController
    /// Numa página que rola (Overview): sem espaço para os 6 lado a lado, quebra em 3 + 3 ou 2 + 2 + 2 em vez de rolar de lado.
    var wrap = false

    @State private var width: CGFloat = 0

    private var s: DatasetStats { snapshot.stats }

    /// Os 6 cabem lado a lado?
    private var fits: Bool {
        width - DS.Space.s4 * 2 >= CGFloat(tileCount) * OverviewMetrics.tileMinWidth + CGFloat(tileCount - 1) * OverviewMetrics.tileSpacing
    }

    var body: some View {
        // Uma linha só: cabendo, os cartões dividem a largura; senão, rolam de lado (a tabela não desce).
        Group {
            if fits {
                HStack(spacing: OverviewMetrics.tileSpacing) { tiles }
                    .padding(.horizontal, DS.Space.s4)
            } else if wrap {
                let count = tileCount == 4 ? 2 : (width - DS.Space.s4 * 2 >= 3 * OverviewMetrics.tileMinWidth + 2 * OverviewMetrics.tileSpacing ? 3 : 2)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: OverviewMetrics.tileSpacing), count: count), spacing: OverviewMetrics.tileSpacing) { tiles }
                    .padding(.horizontal, DS.Space.s4)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: OverviewMetrics.tileSpacing) { tiles.frame(width: OverviewMetrics.tileMinWidth + DS.Space.s4) }
                        .padding(.horizontal, DS.Space.s4)
                }
                // A borda some aos poucos: dá para ver que tem mais cartões de lado.
                .mask {
                    HStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: DS.Space.s8)
                    }
                }
            }
        }
        .padding(.vertical, DS.Space.s3)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .a11y(.datasetStats, kind: "group", value: "\(s.rows)")
    }

    /// Requests e Sources só aparecem quando há o que mostrar (coleta sem rede registrada não ganha cartões vazios).
    private var hasNetwork: Bool { s.requests > 0 || !(snapshot.facets[.source] ?? []).filter { !$0.value.isEmpty }.isEmpty }
    private var tileCount: Int { hasNetwork ? 6 : 4 }

    @ViewBuilder private var tiles: some View {
        rowsTile
        throughputTile
        qualityTile
        completenessTile
        if hasNetwork {
            requestsTile
            sourcesTile
        }
    }

    // MARK: Cartões

    private var rowsTile: some View {
        OverviewTile(
            icon: "square.stack.3d.up", title: String(localized: "Rows collected", bundle: .module),
            help: String(localized: "Unique rows in this dataset. Rows that arrive again with the same key are merged.", bundle: .module),
            value: s.rows.formatted(), unit: nil,
            badge: s.recent > 0 ? String(localized: "+\(s.recent.formatted()) in 5 min", bundle: .module) : nil,
            footer: rowsFooter
        ) {
            CumulativeLine(values: snapshot.activity.map { $0.valid + $0.invalid })
        }
    }

    private var rowsFooter: String {
        guard let last = s.lastSeen else { return String(localized: "Waiting for the first row", bundle: .module) }
        return String(localized: "Last row \(controller.relative(last))", bundle: .module)
    }

    private var throughputTile: some View {
        OverviewTile(
            icon: "speedometer", title: String(localized: "Throughput", bundle: .module),
            help: String(localized: "New rows per minute over the last 5 minutes.", bundle: .module),
            value: ActivityChart.short(snapshot.perMinute), unit: String(localized: "rows/min", bundle: .module), badge: nil,
            footer: peakFooter
        ) {
            MiniBars(values: snapshot.activity.suffix(24).map { $0.valid + $0.invalid })
        }
    }

    private var peakFooter: String {
        let counts = snapshot.activity.map { $0.valid + $0.invalid }
        guard (counts.max() ?? 0) > 0 else { return String(localized: "Nothing arrived in this period", bundle: .module) }
        // Faixas menores que 1 min: soma uma janela de 1 min (senão 30 linhas num segundo viram "1.800/min").
        let window = max(Int((60 / snapshot.bucketSeconds).rounded(.up)), 1)
        let peak = window > 1
            ? counts.indices.map { counts[$0..<min($0 + window, counts.count)].reduce(0, +) }.max() ?? 0
            : Int((Double(counts.max() ?? 0) / (snapshot.bucketSeconds / 60)).rounded())
        return peak == 1 ? String(localized: "Peak 1 row/min", bundle: .module) : String(localized: "Peak \(peak.formatted()) rows/min", bundle: .module)
    }

    private var qualityTile: some View {
        let valid = s.rows == 0 ? 0 : Double(s.rows - s.invalid) / Double(s.rows)
        return OverviewTile(
            icon: "checkmark.seal", title: String(localized: "Valid rows", bundle: .module),
            help: String(localized: "Rows whose values match the column types and required fields.", bundle: .module),
            value: Self.percent(valid), unit: nil,
            badge: nil, footer: qualityFooter, footerTone: s.invalid > 0 ? DS.Color.warning : DS.Color.textTertiary
        ) {
            SegmentBar(segments: [(Double(s.rows - s.invalid), DS.Color.dataValid), (Double(s.invalid), DS.Color.warning)])
        }
    }

    private var qualityFooter: String {
        guard s.invalid > 0 else {
            return s.duplicatesMerged > 0
                ? String(localized: "No invalid rows · \(s.duplicatesMerged.formatted()) duplicates merged", bundle: .module)
                : String(localized: "No invalid rows", bundle: .module)
        }
        let top = (snapshot.facets[.error] ?? []).first.map { " · \($0.value)" } ?? ""
        return String(localized: "\(s.invalid.formatted()) invalid", bundle: .module) + top
    }

    private var completenessTile: some View {
        let columns = snapshot.summary.dataset.columns.map(\.name)
        let fills = columns.map { s.columnFill[$0] ?? 0 }
        return OverviewTile(
            icon: "square.grid.3x3.topleft.filled", title: String(localized: "Fields filled", bundle: .module),
            help: String(localized: "Share of cells with a value. Each bar is a column; short bars are columns the scraper often misses.", bundle: .module),
            value: Self.percent(s.filled), unit: nil, badge: nil,
            footer: s.weakestColumn.map { String(localized: "Lowest: \($0.name) \(Self.percent($0.fill))", bundle: .module) }
                ?? String(localized: "Every column filled in every row", bundle: .module),
            footerTone: (s.weakestColumn?.fill ?? 1) < 0.9 ? DS.Color.warning : DS.Color.textTertiary
        ) {
            ColumnFillBars(names: columns, fills: fills)
        }
    }

    private var requestsTile: some View {
        let failed = s.failedRequests
        return OverviewTile(
            icon: "arrow.left.arrow.right", title: String(localized: "Requests", bundle: .module),
            help: String(localized: "Network requests that produced rows, from each computer's request log.", bundle: .module),
            value: s.requests == 0 ? "–" : s.requests.formatted(), unit: nil,
            badge: nil, footer: requestsFooter, footerTone: failed > 0 ? DS.Color.warning : DS.Color.textTertiary
        ) {
            SegmentBar(segments: [(Double(s.requests - failed), DS.Color.dataValid), (Double(failed), DS.Color.warning)])
        }
    }

    private var requestsFooter: String {
        guard s.requests > 0 else { return String(localized: "No network evidence yet", bundle: .module) }
        var parts: [String] = []
        if let ms = s.averageRequestMs { parts.append(String(localized: "avg \(ms.formatted()) ms", bundle: .module)) }
        parts.append(s.failedRequests == 0 ? String(localized: "none failed", bundle: .module) : String(localized: "\(s.failedRequests) failed", bundle: .module))
        if s.rows >= s.requests * 2 {
            parts.append(String(localized: "\((Double(s.rows) / Double(s.requests)).formatted(.number.precision(.fractionLength(0)))) rows each", bundle: .module))
        }
        return parts.joined(separator: " · ")
    }

    private var sourcesTile: some View {
        let hosts = (snapshot.facets[.source] ?? []).filter { !$0.value.isEmpty }
        let agents = (snapshot.facets[.computer] ?? []).map { controller.computerLabel($0.value) ?? $0.value }
        let tones: [Color] = [DS.Color.dataKey, DS.Color.dataKey.opacity(0.6), DS.Color.dataKey.opacity(0.35), DS.Color.textQuaternary]
        return OverviewTile(
            icon: "globe", title: String(localized: "Sources", bundle: .module),
            help: String(localized: "Sites the rows came from, and the computers that collected them.", bundle: .module),
            value: hosts.count.formatted(), unit: hosts.count == 1 ? String(localized: "site", bundle: .module) : String(localized: "sites", bundle: .module),
            badge: nil,
            footer: [hosts.first?.value, agents.isEmpty ? nil : agents.joined(separator: ", ")].compactMap { $0 }.joined(separator: " · ")
        ) {
            SegmentBar(segments: hosts.prefix(4).enumerated().map { (Double($0.element.count), tones[$0.offset]) })
        }
    }

    static func percent(_ value: Double) -> String {
        value >= 1 ? "100%" : value.formatted(.percent.precision(.fractionLength(value >= 0.995 ? 1 : 0)))
    }
}

/// Um cartão: ícone e nome (com explicação no hover), número grande, desenho da forma do dado e uma linha de contexto.
struct OverviewTile<Visual: View>: View {
    let icon: String
    let title: String
    let help: String
    let value: String
    let unit: String?
    let badge: String?
    let footer: String
    var footerTone: Color = DS.Color.textTertiary
    @ViewBuilder var visual: () -> Visual
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.s1_5) {
                Image(systemName: icon).font(.system(size: OverviewMetrics.iconSize)).foregroundStyle(DS.Color.textTertiary)
                Text(verbatim: title).dsFont(DS.Font.label).foregroundStyle(DS.Color.textSecondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s1) {
                Text(verbatim: value).dsFont(DS.Font.metric).foregroundStyle(DS.Color.textPrimary)
                    .contentTransition(.numericText())
                if let unit { Text(verbatim: unit).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary) }
                if let badge {
                    Text(verbatim: badge).dsFont(DS.Font.small).foregroundStyle(DS.Color.dataValid).padding(.leading, DS.Space.s1)
                }
            }
            .lineLimit(1)
            .padding(.top, DS.Space.s1_5)
            Spacer(minLength: DS.Space.s1)
            visual().frame(height: OverviewMetrics.visualHeight, alignment: .bottom)
            Text(verbatim: footer).dsFont(DS.Font.small).foregroundStyle(footerTone).lineLimit(1).truncationMode(.tail)
                .padding(.top, DS.Space.s1_5)
        }
        .padding(DS.Space.s3)
        .frame(maxWidth: .infinity, minHeight: OverviewMetrics.tileHeight, maxHeight: OverviewMetrics.tileHeight, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.md).fill(DS.Color.panel))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).strokeBorder(hovering ? DS.Color.borderStrong : DS.Color.border))
        .onHover { hovering = $0 }
        .animation(MotionPolicy.shared.animation(MotionTokens.Easing.ease, MotionTokens.Duration.hover), value: hovering)
        .help(help)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Desenhos

/// Total acumulado ao longo do período: linha com a área de leve embaixo.
struct CumulativeLine: View {
    let values: [Int]

    var body: some View {
        Canvas { context, size in
            var running = 0
            let points = values.map { value -> Int in running += value; return running }
            guard let last = points.last, last > 0, points.count > 1 else {
                context.fill(Path(CGRect(x: 0, y: size.height - 1, width: size.width, height: 1)), with: .color(DS.Color.borderStrong))
                return
            }
            let step = size.width / CGFloat(points.count - 1)
            var line = Path()
            for (index, value) in points.enumerated() {
                let point = CGPoint(x: CGFloat(index) * step, y: size.height - 1 - (size.height - 2) * CGFloat(value) / CGFloat(last))
                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .color(DS.Color.dataValid.opacity(0.12)))
            context.stroke(line, with: .color(DS.Color.dataValid), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

/// Barras por faixa de tempo (ritmo).
struct MiniBars: View {
    let values: [Int]

    var body: some View {
        Canvas { context, size in
            guard !values.isEmpty else { return }
            let peak = CGFloat(max(values.max() ?? 0, 1))
            let gap = OverviewMetrics.barGap
            let width = max((size.width - gap * CGFloat(values.count - 1)) / CGFloat(values.count), 1)
            for (index, value) in values.enumerated() {
                let height = value == 0 ? 2 : max(size.height * CGFloat(value) / peak, 3)
                let rect = CGRect(x: CGFloat(index) * (width + gap), y: size.height - height, width: width, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(value == 0 ? DS.Color.border : DS.Color.dataValid.opacity(0.85)))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Barra horizontal dividida em partes proporcionais (válidas/inválidas, requisições ok/falhas, sites).
struct SegmentBar: View {
    let segments: [(Double, Color)]

    var body: some View {
        GeometryReader { geo in
            let total = segments.reduce(0) { $0 + $1.0 }
            let usable = geo.size.width - OverviewMetrics.barGap * CGFloat(segments.count - 1)
            HStack(spacing: OverviewMetrics.barGap) {
                if total <= 0 {
                    Capsule().fill(DS.Color.border)
                } else {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        if segment.0 > 0 {
                            Capsule().fill(segment.1)
                                .frame(width: max(usable * segment.0 / total, OverviewMetrics.barHeight))
                        }
                    }
                }
            }
            .frame(height: OverviewMetrics.barHeight)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }
}

/// Uma barra por coluna, a altura é o preenchimento; colunas com buraco ficam em âmbar. O hover mostra o nome e o número.
struct ColumnFillBars: View {
    let names: [String]
    let fills: [Double]

    var body: some View {
        GeometryReader { geo in
            let count = max(fills.count, 1)
            // The width uses the same spacing the stack lays out with, so many columns shrink to fit instead of spilling past the tile.
            let gap: CGFloat = count > 40 ? 1 : OverviewMetrics.barGap * 2
            let width = min(max((geo.size.width - gap * CGFloat(count - 1)) / CGFloat(count), 1), DS.Space.s2)
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(Array(fills.enumerated()), id: \.offset) { index, fill in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 1).fill(DS.Color.border)
                        // An empty column shows only its track: a stub at its base reads as a stray underscore.
                        if fill > 0 {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(fill >= 0.9 ? DS.Color.dataValid.opacity(0.85) : DS.Color.warning)
                                .frame(height: max(geo.size.height * fill, OverviewMetrics.barGap))
                        }
                    }
                    .frame(width: width, height: geo.size.height)
                    .help(index < names.count ? "\(names[index]) \(DatasetOverviewTiles.percent(fill))" : "")
                }
            }
        }
        .clipped()
    }
}
