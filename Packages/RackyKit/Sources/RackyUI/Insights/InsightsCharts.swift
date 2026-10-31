import RackyCore
import RackyDesignSystem
import SwiftUI

// MARK: - Heatmap por hora do dia

/// 24 células (0h–23h, hora local). Intensidade = tokens novos dos últimos 14 dias naquela hora, em 4 níveis por raiz.
/// A hora atual ganha contorno. As células entram em ondas de 4 (stagger de lista, 04 §3.5).
struct HourHeatmap: View {
    let values: [Double]
    let currentHour: Int
    @State private var appeared = false

    var body: some View {
        let peak = values.max() ?? 0
        let policy = MotionPolicy.shared
        let animates: Bool = { if case .normal = policy.resolution { return true } else { return false } }()
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            HStack(spacing: DS.Space.s0_5) {
                ForEach(0..<24, id: \.self) { hour in
                    let level = InsightsFormat.heatLevel(hour < values.count ? values[hour] : 0, max: peak)
                    RoundedRectangle(cornerRadius: DS.Radius.xs)
                        .fill(fill(level))
                        .frame(maxWidth: InsightsMetrics.heatMaxCell)
                        .frame(height: InsightsMetrics.heatCell)
                        .overlay {
                            if hour == currentHour {
                                RoundedRectangle(cornerRadius: DS.Radius.xs).strokeBorder(DS.Color.textSecondary, lineWidth: DSMetrics.hairline)
                            }
                        }
                        .opacity(animates && !appeared ? 0 : 1)
                        .animation(policy.animation(MotionTokens.Easing.standard, MotionTokens.Duration.base)?
                            .delay(Double(hour / 4) * MotionTokens.Stagger.list), value: appeared)
                }
            }
            HStack {
                ForEach([0, 6, 12, 18], id: \.self) { h in
                    Text(verbatim: String(format: "%02d", h)).dsFont(DS.Font.microNumeric).foregroundStyle(DS.Color.textTertiary)
                    Spacer(minLength: .zero)
                }
                Text(verbatim: "24").dsFont(DS.Font.microNumeric).foregroundStyle(DS.Color.textTertiary)
            }
        }
        .onAppear { appeared = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Usage by hour of day. Busiest hour \(values.enumerated().max { $0.element < $1.element }?.offset ?? 0):00."))
    }

    private func fill(_ level: Int) -> Color {
        switch level {
        case 0: DS.Color.fg6
        case 1: DS.Color.textPrimary.opacity(0.16)
        case 2: DS.Color.textPrimary.opacity(0.3)
        case 3: DS.Color.textPrimary.opacity(0.48)
        default: DS.Color.textPrimary.opacity(0.7)
        }
    }
}

// MARK: - Sparkline da semana

struct PolylineShape: Shape {
    let points: [Double]  // 0…1 (já normalizado)
    var progress: Double = 1

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard points.count > 1 else { return path }
        let step = rect.width / CGFloat(points.count - 1)
        func point(_ i: Int) -> CGPoint { CGPoint(x: rect.minX + step * CGFloat(i), y: rect.maxY - CGFloat(points[i]) * rect.height) }
        path.move(to: point(0))
        let total = Double(points.count - 1)
        for i in 1..<points.count {
            let t = Double(i) / total
            if t <= progress {
                path.addLine(to: point(i))
            } else {
                let prev = point(i - 1), next = point(i)
                let local = (progress - Double(i - 1) / total) * total
                if local > 0 { path.addLine(to: CGPoint(x: prev.x + (next.x - prev.x) * CGFloat(local), y: prev.y + (next.y - prev.y) * CGFloat(local))) }
                break
            }
        }
        return path
    }
}

/// Sete dias: linha com pontos, último ponto (hoje) em destaque, letras dos dias embaixo. A linha se desenha da esquerda.
struct WeekSparkline: View {
    let days: [DailyUsage]
    var calendar: Calendar = .current

    var body: some View {
        let values = days.map { Double($0.counts.fresh) }
        let peak = max(values.max() ?? 0, 1)
        let normalized = values.map { $0 / peak }
        VStack(spacing: DS.Space.s1) {
            ZStack {
                Rectangle().fill(DS.Color.border).frame(height: DSMetrics.hairline).frame(maxHeight: .infinity, alignment: .bottom)
                AnimatedValue(value: 1) { progress in
                    PolylineShape(points: normalized, progress: progress)
                        .stroke(DS.Color.textPrimary.opacity(0.6), style: StrokeStyle(lineWidth: MotionTokens.Stroke.liveBorder, lineCap: .round, lineJoin: .round))
                }
                GeometryReader { proxy in
                    // Só o ponto de hoje: o resto é a linha.
                    if let v = normalized.last {
                        Circle()
                            .fill(DS.Color.textPrimary)
                            .frame(width: DS.Space.s1_5, height: DS.Space.s1_5)
                            .position(x: proxy.size.width - DS.Space.s0_5,
                                      y: min(max(DS.Space.s1, proxy.size.height - CGFloat(v) * proxy.size.height), proxy.size.height - DS.Space.s1))
                    }
                }
            }
            .frame(height: InsightsMetrics.sparkHeight)
            .padding(.horizontal, DS.Space.s1)
            HStack {
                ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                    Text(verbatim: weekdayLetter(d.dayStart))
                        .dsFont(DS.Font.microNumeric)
                        .foregroundStyle(i == days.count - 1 ? DS.Color.textPrimary : DS.Color.textTertiary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Last seven days of usage. Today \(InsightsFormat.tokens(days.last?.counts.fresh ?? 0)) tokens."))
    }

    private func weekdayLetter(_ date: Date) -> String {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let i = calendar.component(.weekday, from: date) - 1
        return symbols.indices.contains(i) ? symbols[i] : ""
    }
}

// MARK: - Histórico (Machine)

/// Linha de histórico das últimas amostras (CPU, memória, rede). Canvas: sem relayout de SwiftUI a cada amostra.
struct HistoryLine: View {
    let values: [Double]
    /// Teto da escala. `nil` = maior valor do histórico (rede).
    var ceiling: Double?
    var color: Color = DS.Color.textPrimary
    var fill = true

    var body: some View {
        Canvas { context, size in
            let top = max(ceiling ?? (values.max() ?? 1), ceiling == nil ? 1 : 0.0001)
            let n = InsightsHistory.capacity
            let step = size.width / CGFloat(n - 1)
            let offset = n - values.count
            var line = Path()
            for (i, v) in values.enumerated() {
                let p = CGPoint(x: step * CGFloat(i + offset), y: size.height - CGFloat(min(1, v / top)) * (size.height - DS.Space.s0_5))
                if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
            }
            if fill, values.count > 1 {
                var area = line
                area.addLine(to: CGPoint(x: step * CGFloat(n - 1), y: size.height))
                area.addLine(to: CGPoint(x: step * CGFloat(offset), y: size.height))
                area.closeSubpath()
                context.fill(area, with: .color(color.opacity(0.1)))
            }
            context.stroke(line, with: .color(color.opacity(0.9)), style: StrokeStyle(lineWidth: MotionTokens.Stroke.liveBorder, lineCap: .round, lineJoin: .round))
        }
        .frame(height: InsightsMetrics.sparkHeight)
        .overlay(alignment: .bottom) { Rectangle().fill(DS.Color.border).frame(height: DSMetrics.hairline) }
    }
}

/// Barras verticais finas por núcleo de CPU.
struct CoreBars: View {
    let loads: [Double]

    private func coreHeight(_ load: Double) -> CGFloat {
        max(DS.Space.s0_5, InsightsMetrics.coreBarHeight * CGFloat(min(1, max(0, load))))
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: DS.Space.s0_5) {
            ForEach(Array(loads.enumerated()), id: \.offset) { _, load in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: DS.Radius.xs).fill(DS.Color.fg8)
                    RoundedRectangle(cornerRadius: DS.Radius.xs)
                        .fill(InsightsTone.color(for: load))
                        .frame(height: coreHeight(load))
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: InsightsMetrics.coreBarHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(loads.count) CPU cores"))
    }
}

// MARK: - Barras

/// Barra horizontal segmentada (memória: app, wired, comprimida) sobre trilho.
struct SegmentedBar: View {
    struct Segment: Identifiable {
        let id: String
        let fraction: Double
        let color: Color
    }

    let segments: [Segment]

    private func width(_ s: Segment, in total: CGFloat, progress: Double) -> CGFloat {
        max(0, total * CGFloat(s.fraction) * CGFloat(progress) - MotionTokens.Stroke.liveBorder)
    }

    var body: some View {
        GeometryReader { proxy in
            AnimatedValue(value: 1) { progress in
                HStack(spacing: MotionTokens.Stroke.liveBorder) {
                    ForEach(segments) { s in
                        Rectangle().fill(s.color).frame(width: width(s, in: proxy.size.width, progress: progress))
                    }
                    Spacer(minLength: .zero)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Color.fg8)
        }
        .frame(height: DS.Space.s1_5)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.xs))
    }
}

/// Barra fina de proporção sob uma linha de lista.
struct ShareBar: View {
    let fraction: Double
    var color: Color = DS.Color.textPrimary

    var body: some View {
        GeometryReader { proxy in
            AnimatedValue(value: min(1, max(0, fraction))) { shown in
                ZStack(alignment: .leading) {
                    Rectangle().fill(DS.Color.fg8)
                    Rectangle().fill(color.opacity(0.85)).frame(width: proxy.size.width * CGFloat(shown))
                }
            }
        }
        .frame(height: InsightsMetrics.rowBarHeight)
    }
}
