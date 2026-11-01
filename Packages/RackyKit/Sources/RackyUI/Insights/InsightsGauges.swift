import RackyDesignSystem
import SwiftUI

/// Componentes do módulo Insights. Linguagem contida (estilo da tela `/usage` do Claude): barras finas com rótulo e
/// percentual à direita, números secundários pequenos, cor de estado só acima de 80% (aviso) e 95% (crítico). Nenhum loop
/// infinito (04 R5); as animações são one-shots com tokens de 04.

nonisolated enum InsightsMetrics {
    /// Espessura da barra de limite (token de espaçamento s1 = 4).
    static let barHeight: CGFloat = 4
    static let heatCell: CGFloat = 8
    static let heatMaxCell: CGFloat = 14
    static let sparkHeight: CGFloat = 24
    static let coreBarHeight: CGFloat = 16
    static let rowBarHeight: CGFloat = 2
    /// Breakpoints de largura do módulo: ≥ `wideMinWidth` duas colunas; ≥ `mediumMinWidth` uma coluna; abaixo, compacto.
    static let wideMinWidth: CGFloat = 520
    static let mediumMinWidth: CGFloat = 300
    /// Abaixo disso as abas viram só ícone.
    static let iconTabsBelowWidth: CGFloat = 300
    static let gridLabelWidth: CGFloat = 40
}

enum InsightsTone {
    /// Estado de uma fração de uso: neutro até 80%, aviso a partir de 80%, crítico a partir de 95%.
    static let warnAt = 0.8
    static let criticalAt = 0.95

    static func color(for fraction: Double) -> Color {
        if fraction >= criticalAt { return DS.Color.destructive }
        if fraction >= warnAt { return DS.Color.warning }
        return DS.Color.textPrimary
    }

    /// Cor do preenchimento da barra: neutro discreto até 80%.
    static func fill(for fraction: Double) -> Color {
        if fraction >= criticalAt { return DS.Color.destructive }
        if fraction >= warnAt { return DS.Color.warning }
        return DS.Color.textPrimary.opacity(0.7)
    }
}

// MARK: - Valor animado

/// Entrega ao conteúdo o valor "mostrado": começa em 0 e vai ao alvo com `twEaseOut` (contadores e barras de 04).
/// Reduce Motion / modo instantâneo mostram o alvo direto, sem estado intermediário.
struct AnimatedValue<Content: View>: View {
    let value: Double
    var duration: Double = MotionTokens.Duration.ripple
    @ViewBuilder let content: (Double) -> Content
    @State private var shown: Double = 0

    var body: some View {
        let policy = MotionPolicy.shared
        let animates: Bool = { if case .normal = policy.resolution { return true } else { return false } }()
        content(animates ? shown : value)
            .animation(policy.animation(MotionTokens.Easing.twEaseOut, duration), value: shown)
            .onAppear { shown = value }
            .onChange(of: value) { _, new in shown = new }
    }
}

/// Texto numérico cujo valor é interpolado pelo SwiftUI durante a animação (contagem).
struct CountingText: View, Animatable {
    var value: Double
    let format: @Sendable (Double) -> String

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(verbatim: format(value)).monospacedDigit()
    }
}

/// Número com contagem animada: `AnimatedNumber(value: 0.31) { InsightsFormat.percent($0) }`.
struct AnimatedNumber: View {
    let value: Double
    let format: @Sendable (Double) -> String

    var body: some View {
        AnimatedValue(value: value) { CountingText(value: $0, format: format) }
    }
}

// MARK: - Barra fina

/// Barra fina de uma fração (limites, disco). Neutra até 80%; `toned: false` mantém sempre neutra.
struct ThinBar: View {
    let fraction: Double?
    var toned = true

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(DS.Color.fg8)
                if let fraction {
                    let clamped = min(1, max(0, fraction))
                    AnimatedValue(value: clamped) { shown in
                        Capsule()
                            .fill(toned ? InsightsTone.fill(for: fraction) : DS.Color.textPrimary.opacity(0.7))
                            .frame(width: proxy.size.width * CGFloat(shown))
                    }
                }
            }
        }
        .frame(height: InsightsMetrics.barHeight)
        .accessibilityHidden(true)
    }
}

/// Uma janela de limite: rótulo à esquerda, percentual à direita, barra fina e "Resets in …". `compact` junta o reset ao rótulo.
struct LimitRow: View {
    let label: LocalizedStringKey
    let fraction: Double?
    let resetsAt: Date?
    let now: Date
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s1_5) {
                Text(label, bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary).lineLimit(1)
                if compact, let text = resetText {
                    Text(verbatim: text).dsFont(DS.Font.microNumeric).foregroundStyle(DS.Color.textTertiary).lineLimit(1)
                }
                Spacer(minLength: DS.Space.s1)
                percent
            }
            ThinBar(fraction: fraction)
            if !compact {
                // Reserva a linha mesmo sem horário de reset: a altura do bloco não pula quando o dado exato chega.
                Text(verbatim: resetText ?? " ").dsFont(DS.Font.microNumeric).foregroundStyle(DS.Color.textTertiary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var percent: some View {
        if let fraction {
            AnimatedNumber(value: fraction * 100) { "\(Int($0.rounded()))%" }
                .dsFont(DS.Font.label).foregroundStyle(InsightsTone.color(for: fraction))
        } else {
            Text(verbatim: "—").dsFont(DS.Font.label).foregroundStyle(DS.Color.textTertiary)
        }
    }

    private var resetText: String? {
        guard let resetsAt, resetsAt > now else { return nil }
        return compactReset(resetsAt)
    }

    private func compactReset(_ date: Date) -> String {
        let text = InsightsFormat.duration(date.timeIntervalSince(now))
        return compact ? text : String(localized: "Resets in \(text)", bundle: .module)
    }
}

// MARK: - Grade de números secundários

/// Linha da grade: rótulo curto e até três valores (custo, tokens, mensagens), em fonte pequena e dígitos tabulares.
struct InsightsStatRow: Identifiable {
    let id: String
    let label: LocalizedStringKey
    let values: [String]
}

struct InsightsStatGrid: View {
    let headers: [LocalizedStringKey]
    let rows: [InsightsStatRow]

    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: DS.Space.s2, verticalSpacing: DS.Space.s1) {
            GridRow {
                Color.clear.frame(width: InsightsMetrics.gridLabelWidth, height: DSMetrics.hairline).gridColumnAlignment(.leading)
                ForEach(Array(headers.enumerated()), id: \.offset) { _, h in
                    Text(h, bundle: .module).dsFont(DS.Font.micro).foregroundStyle(DS.Color.textTertiary).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            ForEach(rows) { row in
                GridRow {
                    Text(row.label, bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary).lineLimit(1)
                        .frame(width: InsightsMetrics.gridLabelWidth, alignment: .leading)
                    ForEach(Array(row.values.enumerated()), id: \.offset) { _, v in
                        Text(verbatim: v).dsFont(DS.Font.microNumeric).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
        }
    }
}
