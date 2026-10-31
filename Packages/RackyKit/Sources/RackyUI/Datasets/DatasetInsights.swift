import RackyCore
import RackyDesignSystem
import RackyProtocol
import RackyStore
import SwiftUI

// Topo da página de um dataset: estado da coleta, números que respondem "está chegando? está bom? de onde vem?", o gráfico de volume
// com hover, a barra de filtro com os filtros ativos em chips e as facetas da esquerda. Tudo lê o `DatasetPageSnapshot`; os cliques
// passam pelas ações do registro.

enum InsightMetrics {
    static let metricsHeight: CGFloat = 70
    static let metricMinWidth: CGFloat = 148
    static let sparkHeight = DS.Space.s4
    static let sparkWidth: CGFloat = 64
    static let chartHeight: CGFloat = 112
    /// A aba Overview só tem o gráfico abaixo dos números: ele ganha a altura que sobraria vazia.
    static let overviewChartHeight: CGFloat = 280
    static let tallChartMinRows = 10
    static let chartBarGap: CGFloat = 2
    static let chartTooltipWidth: CGFloat = 188
    static let barRadius: CGFloat = 1.5
    static let dot: CGFloat = 8
    static let statusDot: CGFloat = 6
    static let queryHeight = DS.Space.s8
    static let chipHeight = DS.Space.s6
    static let facetHeader: CGFloat = 28
    static let check: CGFloat = 14
}

// MARK: Estado da coleta

/// "● Collecting · 2 computers" enquanto algum computador da sessão roda; senão "Idle · last row 4h ago".
struct CollectionStatus: View {
    let collecting: Bool
    let computers: Int
    let lastRow: String?
    @State private var pulse = false

    var body: some View {
        HStack(spacing: DS.Space.s1_5) {
            ZStack {
                if collecting {
                    Circle().fill(DS.Color.dataValid.opacity(0.35))
                        .frame(width: InsightMetrics.statusDot, height: InsightMetrics.statusDot)
                        .scaleEffect(pulse ? 2.2 : 1)
                        .opacity(pulse ? 0 : 1)
                }
                Circle().fill(collecting ? DS.Color.dataValid : DS.Color.textQuaternary)
                    .frame(width: InsightMetrics.statusDot, height: InsightMetrics.statusDot)
            }
            Text(verbatim: text).dsFont(DS.Font.label).foregroundStyle(collecting ? DS.Color.dataValid : DS.Color.textTertiary)
        }
        .padding(.horizontal, DS.Space.s2)
        .frame(height: InsightMetrics.chipHeight)
        .background(Capsule().fill(collecting ? DS.Color.dataValid.opacity(0.1) : DS.Color.secondary))
        .fixedSize()
        .onAppear {
            guard collecting, let animation = MotionPolicy.shared.animation(MotionTokens.Easing.standard, MotionTokens.Duration.attention) else { return }
            withAnimation(animation.repeatForever(autoreverses: false)) { pulse = true }
        }
        .a11y(.datasetStatus, kind: "text", label: text)
    }

    private var text: String {
        if collecting {
            if computers == 0 { return String(localized: "Collecting", bundle: .module) }
            return computers == 1
                ? String(localized: "Collecting · 1 computer", bundle: .module)
                : String(localized: "Collecting · \(computers) computers", bundle: .module)
        }
        guard let lastRow else { return String(localized: "Waiting for rows", bundle: .module) }
        return String(localized: "Idle · last row \(lastRow)", bundle: .module)
    }
}

// MARK: Gráfico

/// Linhas que chegaram ao longo do período, como área (no jeito do Vercel/Datadog): por minuto, ou o total acumulado. Verde são as
/// válidas, âmbar as inválidas. O hover mostra a linha do cursor com o ponto e os números daquele trecho; arrastar escolhe um
/// período (a tabela passa a mostrar só ele). A área se desenha da esquerda para a direita ao aparecer.
struct ActivityChart: View {
    enum Mode: String, CaseIterable { case rate, total }

    let snapshot: DatasetPageSnapshot
    let controller: DatasetsController
    let rangeMenu: AnyView
    var height = InsightMetrics.chartHeight
    @State private var mode: Mode = .rate
    @State private var hover: Int?
    /// Arrasto no gráfico: faixas de início e fim.
    @State private var brush: (start: Int, end: Int)?
    @Environment(\.actionRegistry) private var registry
    /// Sem movimento (preferência do sistema, testes) a área já nasce inteira.
    @State private var reveal: CGFloat = MotionPolicy.shared.animation(MotionTokens.Easing.expoOut, MotionTokens.Duration.ripple) == nil ? 1 : 0

    private var buckets: [DatasetActivityBucket] { snapshot.activity }
    private var total: Int { buckets.reduce(0) { $0 + $1.valid + $1.invalid } }
    private var filtered: Bool { snapshot.matching < snapshot.stats.rows }
    private var perMinute: Double { 60 / max(snapshot.bucketSeconds, 1) }

    /// As duas séries no modo atual: válidas (ou todas, no total) e inválidas.
    private var series: (main: [Double], invalid: [Double]) {
        switch mode {
        case .rate:
            // Faixas menores que 1 min: soma o último minuto (janela móvel) em vez de multiplicar, senão 30 linhas em 2 s viram 900/min.
            let window = Int((60 / max(snapshot.bucketSeconds, 1)).rounded())
            guard window > 1 else {
                return (buckets.map { Double($0.valid) * perMinute }, buckets.map { Double($0.invalid) * perMinute })
            }
            let rolling = { (pick: (DatasetActivityBucket) -> Int) in
                buckets.indices.map { i in Double(buckets[max(0, i - window + 1)...i].reduce(0) { $0 + pick($1) }) }
            }
            return (rolling(\.valid), rolling(\.invalid))
        case .total:
            var all = 0.0, bad = 0.0
            return (buckets.map { all += Double($0.valid + $0.invalid); return all }, buckets.map { bad += Double($0.invalid); return bad })
        }
    }

    private var hasInvalid: Bool { buckets.contains { $0.invalid > 0 } }

    /// Topo do eixo: o número redondo logo acima do pico (1, 2, 2.5, 3, 4, 5, 6, 8, 10 × 10ⁿ).
    private var axisTop: Double {
        let peak = max(series.main.max() ?? 0, series.invalid.max() ?? 0, 1)
        var unit = 1.0
        while unit * 10 <= peak { unit *= 10 }
        while unit > peak { unit /= 10 }
        let top = [1, 2, 2.5, 3, 4, 5, 6, 8, 10].map { unit * $0 }.first { $0 >= peak } ?? peak
        // Contagem é inteira: o meio do eixo também ("1 / 0.5 / 0" não faz sentido para linhas).
        return top < 10 ? (top / 2).rounded(.up) * 2 : top
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2_5) {
            header
            HStack(alignment: .top, spacing: DS.Space.s2) {
                yAxis
                VStack(spacing: DS.Space.s1_5) {
                    plot
                    xAxis
                }
            }
        }
        .padding(.horizontal, DS.Space.s4)
        .padding(.top, DS.Space.s3)
        .padding(.bottom, DS.Space.s2_5)
        .overlay(alignment: .bottom) { DS.Color.border.frame(height: ComputersMetrics.separator) }
        .onAppear {
            guard reveal < 1 else { return }
            guard let animation = MotionPolicy.shared.animation(MotionTokens.Easing.expoOut, MotionTokens.Duration.flight * 2) else { reveal = 1; return }
            withAnimation(animation) { reveal = 1 }
        }
        .a11y(.datasetChart, kind: "chart", value: "\(total)")
    }

    // MARK: Cabeçalho

    private var header: some View {
        HStack(spacing: DS.Space.s2) {
            Text("Rows over time", bundle: .module).dsFont(DS.Font.sectionLabel).foregroundStyle(DS.Color.textPrimary)
            Text(verbatim: filtered
                ? String(localized: "\(total.formatted()) matching", bundle: .module)
                : total == 1 ? String(localized: "1 row", bundle: .module) : String(localized: "\(total.formatted()) rows", bundle: .module))
                .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
            if let window = snapshot.window { windowPill(window) }
            Spacer(minLength: DS.Space.s2)
            if hasInvalid {
                legend(DS.Color.dataValid, mode == .total ? String(localized: "All rows", bundle: .module) : String(localized: "Valid", bundle: .module))
                legend(DS.Color.warning, String(localized: "Invalid", bundle: .module))
            }
            modePicker
            rangeMenu
        }
    }

    private var modePicker: some View {
        HStack(spacing: 0) {
            ForEach(Mode.allCases, id: \.self) { item in
                // lint-ui: allow buttons troca a leitura do gráfico (estado local da vista)
                Button {
                    withAnimation(MotionPolicy.shared.animation(MotionTokens.Easing.standard, MotionTokens.Duration.base)) { mode = item }
                } label: {
                    Text(verbatim: item == .rate ? String(localized: "Per minute", bundle: .module) : String(localized: "Total", bundle: .module))
                        .dsFont(DS.Font.small)
                        .foregroundStyle(mode == item ? DS.Color.textPrimary : DS.Color.textTertiary)
                        .padding(.horizontal, DS.Space.s2)
                        .frame(height: DS.Space.s6 - DS.Space.s1)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.sm - DS.Space.s0_5).fill(mode == item ? DS.Color.secondary : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(DS.Space.s0_5)
        .background(RoundedRectangle(cornerRadius: DS.Radius.sm).fill(DS.Color.chrome))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.sm).strokeBorder(DS.Color.border))
        .fixedSize()
    }

    // MARK: Eixos

    private var yAxis: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(verbatim: Self.short(axisTop)).dsFont(DS.Font.monoMicro).foregroundStyle(DS.Color.textTertiary)
            Spacer(minLength: 0)
            Text(verbatim: Self.short(axisTop / 2)).dsFont(DS.Font.monoMicro).foregroundStyle(DS.Color.textTertiary)
            Spacer(minLength: 0)
            Text(verbatim: "0").dsFont(DS.Font.monoMicro).foregroundStyle(DS.Color.textTertiary)
        }
        .frame(height: height + DS.Space.s1)
        .frame(minWidth: DS.Space.s6, alignment: .trailing)
        .offset(y: -DS.Space.s1_5)
    }

    /// A interface é em inglês: o separador decimal segue ela, não a região do Mac ("0,5" ao lado de "1.2k").
    static func short(_ value: Double) -> String {
        let style = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1)).locale(Locale(identifier: "en_US"))
        if value >= 1000 { return (value / 1000).formatted(style) + "k" }
        return value.formatted(style)
    }

    /// 5 marcas; estreito, 3; mais estreito, só as pontas.
    private var xAxis: some View {
        ViewThatFits(in: .horizontal) {
            marks([0, 1, 2, 3, 4])
            marks([0, 2, 4])
            marks([0, 4])
        }
    }

    private func marks(_ indexes: [Int]) -> some View {
        HStack(spacing: DS.Space.s3) {
            ForEach(Array(indexes.enumerated()), id: \.offset) { position, index in
                Text(verbatim: label(index)).dsFont(DS.Font.monoMicro).foregroundStyle(DS.Color.textTertiary).fixedSize()
                if position < indexes.count - 1 { Spacer(minLength: 0) }
            }
        }
    }

    private func label(_ index: Int) -> String {
        guard let start = snapshot.activityStart, let end = snapshot.activityEnd else { return "" }
        if index == 4, controller.now().timeIntervalSince(end) < 1 { return String(localized: "now", bundle: .module) }
        // Período curto: com segundos, senão as marcas se repetem ("16:47 16:47").
        let span = end.timeIntervalSince(start)
        return controller.clock(start.addingTimeInterval(span * Double(index) / 4), seconds: span <= 600)
    }

    // MARK: Área

    private var plot: some View {
        GeometryReader { geo in
            let size = geo.size
            let (main, invalid) = series
            let top = axisTop
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    // Grade: três linhas finas (topo, meio, base).
                    for fraction in [0.0, 0.5, 1.0] {
                        let y = (size.height - 1) * fraction + 0.5
                        context.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                                       with: .color(fraction == 1 ? DS.Color.borderStrong : DS.Color.border), lineWidth: 1)
                    }
                }
                Group {
                    AreaSeries(values: main, top: top, color: DS.Color.dataValid)
                    if hasInvalid { AreaSeries(values: invalid, top: top, color: DS.Color.warning) }
                }
                .mask(alignment: .leading) { Rectangle().frame(width: size.width * reveal) }
                // Ponto no valor mais recente: com poucas linhas a curva é só um degrau na borda e passava despercebida.
                if hover == nil, reveal == 1, let last = main.last, last > 0 {
                    dot(DS.Color.dataValid)
                        .offset(x: x(main.count - 1, width: size.width) - InsightMetrics.dot / 2,
                                y: size.height - 1 - (size.height - 2) * CGFloat(last / top) - InsightMetrics.dot / 2)
                        .allowsHitTesting(false)
                }
                if let range = shadedRange { shade(range, width: size.width) }
                if let hover, hover < buckets.count, brush == nil {
                    cursor(hover, main: main, invalid: invalid, top: top, size: size)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: DS.Space.s1)
                    .onChanged { drag in brush = (index(at: drag.startLocation.x, width: size.width), index(at: drag.location.x, width: size.width)) }
                    .onEnded { _ in commitBrush() }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    let index = index(at: point.x, width: size.width)
                    if hover != index { hover = index }
                case .ended: hover = nil
                }
            }
        }
        .frame(height: height)
    }

    private func x(_ index: Int, width: CGFloat) -> CGFloat {
        guard buckets.count > 1 else { return width / 2 }
        return width * CGFloat(index) / CGFloat(buckets.count - 1)
    }

    private func index(at x: CGFloat, width: CGFloat) -> Int {
        guard buckets.count > 1, width > 0 else { return 0 }
        return min(max(Int((x / width * CGFloat(buckets.count - 1)).rounded()), 0), buckets.count - 1)
    }

    private func cursor(_ index: Int, main: [Double], invalid: [Double], top: Double, size: CGSize) -> some View {
        let px = x(index, width: size.width)
        let y = { (value: Double) in size.height - 1 - (size.height - 2) * CGFloat(value / top) }
        return ZStack(alignment: .topLeading) {
            DS.Color.textTertiary.frame(width: ComputersMetrics.separator, height: size.height).offset(x: px)
            dot(DS.Color.dataValid).offset(x: px - InsightMetrics.dot / 2, y: y(main[index]) - InsightMetrics.dot / 2)
            if hasInvalid, invalid[index] > 0 {
                dot(DS.Color.warning).offset(x: px - InsightMetrics.dot / 2, y: y(invalid[index]) - InsightMetrics.dot / 2)
            }
            tooltip(index)
                .offset(x: px + DS.Space.s2 + InsightMetrics.chartTooltipWidth <= size.width ? px + DS.Space.s2 : max(px - DS.Space.s2 - InsightMetrics.chartTooltipWidth, 0))
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color)
            .overlay(Circle().strokeBorder(DS.Color.canvas, lineWidth: DS.Space.s0_5))
            .frame(width: InsightMetrics.dot, height: InsightMetrics.dot)
    }

    private func tooltip(_ index: Int) -> some View {
        let bucket = buckets[index]
        let end = bucket.start.addingTimeInterval(snapshot.bucketSeconds)
        let seconds = snapshot.bucketSeconds < 60
        let soFar = buckets[...index].reduce(0) { $0 + $1.valid + $1.invalid }
        return VStack(alignment: .leading, spacing: DS.Space.s1) {
            Text(verbatim: "\(controller.clock(bucket.start, seconds: seconds)) – \(controller.clock(end, seconds: seconds))")
                .dsFont(DS.Font.monoMicro).foregroundStyle(DS.Color.textTertiary)
            tooltipLine(DS.Color.dataValid, String(localized: "Valid", bundle: .module), bucket.valid)
            tooltipLine(DS.Color.warning, String(localized: "Invalid", bundle: .module), bucket.invalid)
            DS.Color.border.frame(height: ComputersMetrics.separator)
            HStack {
                Text("Total so far", bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                Spacer(minLength: DS.Space.s2)
                Text(verbatim: soFar.formatted()).dsFont(DS.Font.monoCell).foregroundStyle(DS.Color.textSecondary)
            }
        }
        .padding(DS.Space.s2)
        .frame(width: InsightMetrics.chartTooltipWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.md).fill(DS.Color.panel))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).strokeBorder(DS.Color.borderStrong))
        .shadow(color: .black.opacity(0.35), radius: DS.Space.s2, y: DS.Space.s1)
    }

    private func tooltipLine(_ color: Color, _ title: String, _ value: Int) -> some View {
        HStack(spacing: DS.Space.s1_5) {
            RoundedRectangle(cornerRadius: DS.Radius.xs).fill(color).frame(width: DS.Space.s2, height: DS.Space.s2)
            Text(verbatim: title).dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary)
            Spacer(minLength: DS.Space.s2)
            Text(verbatim: value.formatted()).dsFont(DS.Font.monoCell).foregroundStyle(value == 0 ? DS.Color.textTertiary : DS.Color.textPrimary)
        }
    }

    private func legend(_ color: Color, _ title: String) -> some View {
        HStack(spacing: DS.Space.s1) {
            RoundedRectangle(cornerRadius: DS.Radius.xs).fill(color).frame(width: DS.Space.s2, height: DS.Space.s2)
            Text(verbatim: title).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
        }
    }

    // MARK: Período

    /// O que fica destacado: o arrasto em curso, senão o período escolhido.
    private var shadedRange: ClosedRange<Int>? {
        if let brush { return min(brush.start, brush.end)...max(brush.start, brush.end) }
        guard let window = snapshot.window, let start = snapshot.activityStart, snapshot.bucketSeconds > 0, !buckets.isEmpty else { return nil }
        let first = Int((window.lowerBound.timeIntervalSince(start) / snapshot.bucketSeconds).rounded(.down))
        let last = Int((window.upperBound.timeIntervalSince(start) / snapshot.bucketSeconds).rounded(.up)) - 1
        let low = max(first, 0), high = min(last, buckets.count - 1)
        return low <= high ? low...high : nil
    }

    private func shade(_ range: ClosedRange<Int>, width: CGFloat) -> some View {
        let from = x(range.lowerBound, width: width), to = x(range.upperBound, width: width)
        return RoundedRectangle(cornerRadius: InsightMetrics.barRadius)
            .fill(DS.Color.dataKey.opacity(0.1))
            .overlay(RoundedRectangle(cornerRadius: InsightMetrics.barRadius).strokeBorder(DS.Color.dataKey.opacity(0.45)))
            .frame(width: max(to - from, InsightMetrics.dot))
            .offset(x: range.lowerBound == range.upperBound ? from - InsightMetrics.dot / 2 : from)
            .allowsHitTesting(false)
            .a11y(.datasetChartWindow, kind: "region")
    }

    private func commitBrush() {
        guard let brush, let registry, !buckets.isEmpty else { self.brush = nil; return }
        let low = min(brush.start, brush.end), high = max(brush.start, brush.end)
        let start = buckets[low].start
        let end = buckets[high].start.addingTimeInterval(snapshot.bucketSeconds)
        let argument = "\(Int64(start.timeIntervalSince1970 * 1000))-\(Int64(end.timeIntervalSince1970 * 1000))"
        Task {
            _ = try? await registry.perform(.datasetTimeWindow, .select(argument))
            self.brush = nil
        }
    }

    private func windowPill(_ window: ClosedRange<Date>) -> some View {
        let seconds = snapshot.bucketSeconds < 60
        return HStack(spacing: DS.Space.s1) {
            Image(systemName: "clock").font(.system(size: DS.Space.s2_5)).foregroundStyle(DS.Color.dataKey)
            Text(verbatim: "\(controller.clock(window.lowerBound, seconds: seconds)) – \(controller.clock(window.upperBound, seconds: seconds))")
                .dsFont(DS.Font.small).foregroundStyle(DS.Color.textPrimary)
            ActionButton(.datasetTimeWindow, id: .datasetChartWindowClear, argument: .select("clear"), tooltip: String(localized: "Show the whole period", bundle: .module)) {
                Image(systemName: "xmark").font(.system(size: DS.Space.s2, weight: .semibold)).foregroundStyle(DS.Color.textTertiary)
                    .frame(width: DS.Space.s4, height: DS.Space.s4).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, DS.Space.s2)
        .padding(.trailing, DS.Space.s0_5)
        .frame(height: FilterBarMetrics.pillHeight)
        .background(RoundedRectangle(cornerRadius: DS.Radius.sm).fill(DS.Color.dataKey.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.sm).strokeBorder(DS.Color.dataKey.opacity(0.3)))
    }
}

/// Uma série como área: curva suave que não passa do zero nem inventa picos (cúbica monotônica), linha de 1,5 pt e o preenchimento
/// de leve embaixo.
struct AreaSeries: View {
    let values: [Double]
    let top: Double
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard values.count > 1, top > 0 else { return }
            let points = values.enumerated().map { index, value in
                CGPoint(x: size.width * CGFloat(index) / CGFloat(values.count - 1),
                        y: size.height - 1 - (size.height - 2) * CGFloat(min(value, top) / top))
            }
            let line = Self.monotone(points)
            var area = line
            area.addLine(to: CGPoint(x: points[points.count - 1].x, y: size.height))
            area.addLine(to: CGPoint(x: points[0].x, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .color(color.opacity(0.14)))
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }

    /// Fritsch–Carlson: tangentes que não deixam a curva ultrapassar os pontos vizinhos.
    static func monotone(_ p: [CGPoint]) -> Path {
        var path = Path()
        guard let first = p.first else { return path }
        path.move(to: first)
        guard p.count > 2 else { p.dropFirst().forEach { path.addLine(to: $0) }; return path }
        let n = p.count
        var slopes = (0..<(n - 1)).map { (p[$0 + 1].y - p[$0].y) / max(p[$0 + 1].x - p[$0].x, .ulpOfOne) }
        var tangents = [CGFloat](repeating: 0, count: n)
        tangents[0] = slopes[0]
        tangents[n - 1] = slopes[n - 2]
        for i in 1..<(n - 1) {
            tangents[i] = slopes[i - 1] * slopes[i] <= 0 ? 0 : (slopes[i - 1] + slopes[i]) / 2
        }
        for i in 0..<(n - 1) where slopes[i] == 0 {
            tangents[i] = 0
            tangents[i + 1] = 0
        }
        for i in 0..<(n - 1) where slopes[i] != 0 {
            let a = tangents[i] / slopes[i], b = tangents[i + 1] / slopes[i]
            let h = a * a + b * b
            if h > 9 {
                let t = 3 / h.squareRoot()
                tangents[i] = t * a * slopes[i]
                tangents[i + 1] = t * b * slopes[i]
            }
        }
        slopes.removeAll()
        for i in 0..<(n - 1) {
            let dx = (p[i + 1].x - p[i].x) / 3
            path.addCurve(
                to: p[i + 1],
                control1: CGPoint(x: p[i].x + dx, y: p[i].y + tangents[i] * dx),
                control2: CGPoint(x: p[i + 1].x - dx, y: p[i + 1].y - tangents[i + 1] * dx))
        }
        return path
    }
}

/// Linha horizontal de ponta a ponta (grade do gráfico).
struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

// MARK: Facetas

/// Caixa de seleção: vazia = fora; marcada = verde com o visto.
struct CheckSquare: View {
    let on: Bool
    var tint: Color = DS.Color.dataValid

    var body: some View {
        RoundedRectangle(cornerRadius: DS.Radius.xs + 1)
            .fill(on ? tint : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.xs + 1).strokeBorder(on ? tint : DS.Color.borderStrong, lineWidth: ComputersMetrics.separator))
            .overlay {
                if on {
                    Image(systemName: "checkmark").font(.system(size: DS.Space.s2, weight: .bold)).foregroundStyle(DS.Color.canvas)
                }
            }
            .frame(width: InsightMetrics.check, height: InsightMetrics.check)
    }
}

/// Coluna da esquerda, no jeito do Datadog: cada grupo recolhe; cada valor tem a caixa, a barra da proporção atrás e a contagem; no
/// hover a contagem vira "only" (só esse valor). Erro funciona ao contrário: marcar filtra.
struct FacetsPanel: View {
    let snapshot: DatasetPageSnapshot
    let controller: DatasetsController
    let model: DatasetViewModel
    @State private var collapsed: Set<DatasetFacet> = []
    @State private var hovered: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.s1) {
                ForEach(DatasetFacet.allCases, id: \.self) { facet in
                    let values = snapshot.facets[facet] ?? []
                    if !values.isEmpty { group(facet, values) }
                }
                ColumnFacets(snapshot: snapshot, model: model)
            }
            .padding(.horizontal, DS.Space.s2)
            .padding(.vertical, DS.Space.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: DatasetMetrics.facetWidth)
        .background(DS.Color.chrome)
        .overlay(alignment: .trailing) { DS.Color.border.frame(width: ComputersMetrics.separator) }
    }

    private func group(_ facet: DatasetFacet, _ values: [DatasetFacetCount]) -> some View {
        let open = !collapsed.contains(facet)
        let filtered = facet == .error ? !model.errorKinds.isEmpty : !(model.excluded[facet]?.isEmpty ?? true)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.s1_5) {
                // lint-ui: allow buttons recolhe o grupo (estado local da coluna, sem ação de registro)
                Button {
                    withAnimation(MotionPolicy.shared.animation(MotionTokens.Easing.standard, MotionTokens.Duration.disclosure)) {
                        if open { collapsed.insert(facet) } else { collapsed.remove(facet) }
                    }
                } label: {
                    HStack(spacing: DS.Space.s1_5) {
                        Image(systemName: "chevron.right").font(.system(size: DS.Space.s2, weight: .semibold))
                            .rotationEffect(.degrees(open ? 90 : 0)).foregroundStyle(DS.Color.textTertiary)
                        Text(verbatim: Self.title(facet)).dsFont(DS.Font.sectionLabel).foregroundStyle(DS.Color.textSecondary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if filtered {
                    ActionButton(.datasetFacet, id: .datasetFacetReset(facet.rawValue), argument: .select("\(facet.rawValue):*")) {
                        Text("Reset", bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.dataKey)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, DS.Space.s2)
            .frame(height: InsightMetrics.facetHeader)
            if open {
                ForEach(values) { value in row(facet, value) }
                    .transition(.opacity)
            }
        }
    }

    private func row(_ facet: DatasetFacet, _ value: DatasetFacetCount) -> some View {
        let on = model.isChecked(facet, value.value)
        let key = "\(facet.rawValue):\(value.value)"
        let isHovered = hovered == key
        return HStack(spacing: 0) {
            ActionButton(.datasetFacet, id: .datasetFacet(facet.rawValue, value.value), argument: .select(key)) {
                HStack(spacing: DS.Space.s2) {
                    CheckSquare(on: on)
                    if facet == .status {
                        Circle().fill(value.value == "valid" ? DS.Color.dataValid : DS.Color.warning)
                            .frame(width: DatasetMetrics.facetDot, height: DatasetMetrics.facetDot)
                    }
                    Text(verbatim: Self.label(facet, value.value, controller: controller)).dsFont(DS.Font.cell)
                        .foregroundStyle(on || facet == .error ? DS.Color.textPrimary : DS.Color.textTertiary)
                        .lineLimit(1).truncationMode(.middle)
                        .help(facet == .computer ? value.value : "")
                    Spacer(minLength: DS.Space.s1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isHovered, facet != .error, (snapshot.facets[facet]?.count ?? 0) > 1 {
                ActionButton(.datasetFacet, id: .datasetFacetOnly(facet.rawValue, value.value), argument: .select("\(facet.rawValue):=\(value.value)")) {
                    Text("only", bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.dataKey)
                }
                .buttonStyle(.plain)
            } else {
                Text(verbatim: value.count.formatted()).dsFont(DS.Font.monoMicro).foregroundStyle(DS.Color.textTertiary)
            }
        }
        .padding(.horizontal, DS.Space.s2)
        .frame(height: DatasetMetrics.facetRow)
        .background(RoundedRectangle(cornerRadius: DS.Radius.sm).fill(isHovered ? DS.Color.hoverAgentRow : Color.clear))
        .onHover { hovered = $0 ? key : (hovered == key ? nil : hovered) }
    }

    static func title(_ facet: DatasetFacet) -> String {
        switch facet {
        case .status: String(localized: "Status", bundle: .module)
        case .computer: String(localized: "Computer", bundle: .module)
        case .source: String(localized: "Source", bundle: .module)
        case .evidence: String(localized: "Evidence", bundle: .module)
        case .error: String(localized: "Error", bundle: .module)
        }
    }

    /// O computador de um worker leva o nome do agente ("Codex 1 · books-p13-14").
    static func label(_ facet: DatasetFacet, _ value: String, controller: DatasetsController) -> String {
        switch (facet, value) {
        case (.status, "valid"): String(localized: "Valid", bundle: .module)
        case (.status, "invalid"): String(localized: "Invalid", bundle: .module)
        case (.evidence, "observed"): String(localized: "Seen in network", bundle: .module)
        case (.evidence, "reported"): String(localized: "Agent-reported", bundle: .module)
        case (.evidence, "none"): String(localized: "No source", bundle: .module)
        case (.computer, _): controller.computerLabel(value) ?? value
        case (_, ""): String(localized: "None", bundle: .module)
        default: value
        }
    }
}
