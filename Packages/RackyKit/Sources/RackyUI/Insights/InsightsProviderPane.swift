import RackyCore
import RackyDesignSystem
import SwiftUI

/// Bloco com título (micro, caixa alta), hairline acima e conteúdo. Sem card: o painel já é a superfície.
struct InsightsSection<Content: View>: View {
    let title: LocalizedStringKey
    var trailing: String?
    var rule = true
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            HStack(spacing: DS.Space.s2) {
                Text(title, bundle: .module).dsFont(DS.Font.micro).textCase(.uppercase).foregroundStyle(DS.Color.textTertiary).lineLimit(1)
                Spacer(minLength: DS.Space.s2)
                if let trailing { Text(verbatim: trailing).dsFont(DS.Font.microNumeric).foregroundStyle(DS.Color.textTertiary).lineLimit(1) }
            }
            content
        }
        .padding(.vertical, DS.Space.s2_5)
        .overlay(alignment: .top) { if rule { Rectangle().fill(DS.Color.border).frame(height: DSMetrics.hairline) } }
    }
}

/// Rótulo + valor numérico alinhados (valor em dígitos tabulares).
struct InsightsStat: View {
    let label: LocalizedStringKey
    let value: String
    var emphasis = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
            Text(label, bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary).lineLimit(1)
            Spacer(minLength: DS.Space.s1)
            Text(verbatim: value).dsFont(emphasis ? DS.Font.label : DS.Font.small).monospacedDigit()
                .foregroundStyle(DS.Color.textPrimary).lineLimit(1)
        }
    }
}

/// Aba de um provedor (Claude ou Codex): limites de 5 h e semanal, números secundários, tendência e listas.
/// Três layouts (largo, médio, compacto) escolhidos por `InsightsAdaptive` conforme o espaço.
struct InsightsProviderPane: View {
    let summary: ProviderSummary
    let now: Date
    let width: CGFloat
    var limitsStatus: ClaudeLimitsStatus = .notEnabled
    var scanning = false

    var body: some View {
        if !summary.hasData {
            DSEmptyState(summary.provider == .claude
                ? String(localized: "No Claude usage found yet.", bundle: .module)
                : String(localized: "No Codex usage found yet.", bundle: .module))
        } else {
            InsightsAdaptive(width: width) {
                wideBody
            } medium: {
                mediumBody
            } condensed: {
                condensedBody
            } compact: {
                compactBody
            }
        }
    }

    // MARK: Largo (duas colunas)

    private var wideBody: some View {
        HStack(alignment: .top, spacing: DS.Space.s4) {
            VStack(alignment: .leading, spacing: DS.Space.s3) {
                header.layoutProbe("header")
                limits.layoutProbe("limits")
                exactNote(compact: false).layoutProbe("exact")
                statsGrid.layoutProbe("grid")
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            VStack(alignment: .leading, spacing: .zero) {
                trendSection(rule: false)
                heatSection
                modelsSection
                sessionsSection
                unpricedNote
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .layoutProbe("pane.wide")
    }

    // MARK: Médio (uma coluna)

    private var mediumBody: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            header.layoutProbe("header")
            limits.layoutProbe("limits")
            exactNote(compact: false).layoutProbe("exact")
            statsGrid.layoutProbe("grid")
            VStack(alignment: .leading, spacing: .zero) {
                trendSection(rule: true)
                heatSection
                modelsSection
                sessionsSection
                unpricedNote
            }
        }
        .layoutProbe("pane.medium")
    }

    // MARK: Condensado (uma coluna sem tendência nem listas)

    private var condensedBody: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            header.layoutProbe("header")
            limits.layoutProbe("limits")
            exactNote(compact: false).layoutProbe("exact")
            statsGrid.layoutProbe("grid")
        }
        .layoutProbe("pane.condensed")
    }

    // MARK: Compacto (só barras e números principais)

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            LimitRow(label: "5 h", fraction: summary.fiveHour?.usedFraction, resetsAt: summary.fiveHour?.resetsAt, now: now, compact: true)
                .layoutProbe("limits.5h")
            LimitRow(label: "Week", fraction: summary.sevenDay?.usedFraction, resetsAt: summary.sevenDay?.resetsAt, now: now, compact: true)
                .layoutProbe("limits.7d")
            HStack(spacing: DS.Space.s2) {
                Text("Today", bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary)
                Spacer(minLength: DS.Space.s1)
                Text(verbatim: InsightsFormat.cost(summary.todayCostUSD) + " · " + InsightsFormat.tokens(summary.today.fresh))
                    .dsFont(DS.Font.microNumeric).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
            }
            .layoutProbe("today")
            exactNote(compact: true).layoutProbe("exact")
        }
        .layoutProbe("pane.compact")
    }

    // MARK: Peças

    private var header: some View {
        HStack(spacing: DS.Space.s2) {
            DSAgentLogo(summary.provider.agentKind, size: DS.Space.s4)
            Text(verbatim: summary.provider == .claude ? "Claude" : "Codex").dsFont(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
            if let plan = InsightsFormat.plan(summary.plan?.plan) { DSBadge(plan) }
            Spacer(minLength: .zero)
            if scanning { DSSpinner(size: DS.Space.s3, delayed: true) }
            if let p = summary.plan, !p.loggedIn { DSBadge(String(localized: "Signed out", bundle: .module), variant: .warning) }
        }
    }

    private var limits: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            LimitRow(label: "Session (5 h)", fraction: summary.fiveHour?.usedFraction, resetsAt: summary.fiveHour?.resetsAt, now: now)
            LimitRow(label: "Weekly (7 d)", fraction: summary.sevenDay?.usedFraction, resetsAt: summary.sevenDay?.resetsAt, now: now)
        }
    }

    /// Só o Claude tem a fonte exata sob demanda. Aparece enquanto a decisão não foi tomada ou o dado não chegou.
    @ViewBuilder private func exactNote(compact: Bool) -> some View {
        if summary.provider == .claude {
            let missing = summary.fiveHour?.usedFraction == nil || summary.sevenDay?.usedFraction == nil
            switch limitsStatus {
            case .notEnabled:
                if missing || !compact { showButton(compact: compact) }
            case .loading:
                note(String(localized: "Reading exact limits…", bundle: .module))
            case .needsClaudeRefresh:
                note(String(localized: "Open Claude Code to refresh", bundle: .module), tone: DS.Color.warning)
            case .unavailable:
                if missing { note(String(localized: "Exact limits unavailable right now", bundle: .module)) }
            case .live:
                EmptyView()
            }
        }
    }

    private func note(_ text: String, tone: Color = DS.Color.textTertiary) -> some View {
        Text(verbatim: text).dsFont(DS.Font.small).foregroundStyle(tone).lineLimit(2).fixedSize(horizontal: false, vertical: true)
    }

    private func showButton(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s1_5) {
            if !compact {
                Text("Exact limits come from your Claude Code sign-in. Racky reads it only after you click.", bundle: .module)
                    .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
            ActionButton(.insightsShowExactLimits, id: .rightPanelInsightsShowExactLimits) {
                Text("Show exact limits", bundle: .module)
            }
            .buttonStyle(DSButtonStyle(.secondary, .xs))
        }
    }

    private var statsGrid: some View {
        let s = summary
        return InsightsStatGrid(
            headers: ["Cost", "Tokens", "Messages"],
            rows: [
                InsightsStatRow(id: "5h", label: "5 h", values: [InsightsFormat.cost(s.fiveHour?.costUSD ?? 0),
                                                                InsightsFormat.tokens(s.fiveHour?.counts.fresh ?? 0), "\(s.fiveHour?.messages ?? 0)"]),
                InsightsStatRow(id: "today", label: "Today", values: [InsightsFormat.cost(s.todayCostUSD), InsightsFormat.tokens(s.today.fresh), "\(s.todayMessages)"]),
                InsightsStatRow(id: "7d", label: "7 d", values: [InsightsFormat.cost(s.sevenDay?.costUSD ?? s.weekCostUSD),
                                                               InsightsFormat.tokens(s.sevenDay?.counts.fresh ?? s.week.fresh), "\(s.sevenDay?.messages ?? 0)"]),
            ])
    }

    private func trendSection(rule: Bool) -> some View {
        InsightsSection(title: "Last 7 days", trailing: InsightsFormat.tokens(summary.week.fresh) + " · " + InsightsFormat.cost(summary.weekCostUSD), rule: rule) {
            WeekSparkline(days: summary.dailyWeek)
        }
        .layoutProbe("trend")
    }

    private var heatSection: some View {
        InsightsSection(title: "By hour of day") {
            HourHeatmap(values: summary.hourOfDay, currentHour: Calendar.current.component(.hour, from: now))
        }
        .layoutProbe("heat")
    }

    @ViewBuilder private var modelsSection: some View {
        if !summary.topModels.isEmpty {
            InsightsSection(title: "Models") { modelRows }.layoutProbe("models")
        }
    }

    @ViewBuilder private var sessionsSection: some View {
        if !summary.topSessions.isEmpty {
            InsightsSection(title: "Sessions") { sessionRows }.layoutProbe("sessions")
        }
    }

    @ViewBuilder private var unpricedNote: some View {
        if !summary.unpricedModels.isEmpty {
            Text(verbatim: "Cost estimate leaves out \(summary.unpricedModels.count) model\(summary.unpricedModels.count == 1 ? "" : "s") without a price.")
                .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).fixedSize(horizontal: false, vertical: true)
                .padding(.top, DS.Space.s1)
        }
    }

    private var modelRows: some View {
        VStack(spacing: DS.Space.s1_5) {
            ForEach(summary.topModels.prefix(4)) { m in
                VStack(spacing: DS.Space.s1) {
                    HStack(spacing: DS.Space.s2) {
                        Text(verbatim: InsightsFormat.modelName(m.model)).dsFont(DS.Font.monoMicro).foregroundStyle(DS.Color.textPrimary).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: DS.Space.s1)
                        Text(verbatim: InsightsFormat.percent(m.share)).dsFont(DS.Font.microNumeric).foregroundStyle(DS.Color.textTertiary)
                        Text(verbatim: InsightsFormat.cost(m.costUSD)).dsFont(DS.Font.microNumeric).foregroundStyle(DS.Color.textPrimary)
                            .frame(minWidth: DS.Space.s8, alignment: .trailing)
                    }
                    ShareBar(fraction: m.share)
                }
            }
        }
    }

    private var sessionRows: some View {
        let top = max(summary.topSessions.first?.costUSD ?? 0, 0.0001)
        return VStack(spacing: DS.Space.s1_5) {
            ForEach(summary.topSessions.prefix(4)) { s in
                VStack(spacing: DS.Space.s1) {
                    HStack(spacing: DS.Space.s1_5) {
                        Text(verbatim: s.label ?? "Session " + String(s.session.prefix(6))).dsFont(DS.Font.small).foregroundStyle(DS.Color.textPrimary).lineLimit(1).truncationMode(.middle)
                        if s.sidechainMessages > 0 { DSBadge("+\(s.sidechainMessages) sub", variant: .mono) }
                        Spacer(minLength: DS.Space.s1)
                        Text(verbatim: InsightsFormat.cost(s.costUSD)).dsFont(DS.Font.microNumeric).foregroundStyle(DS.Color.textPrimary)
                            .frame(minWidth: DS.Space.s8, alignment: .trailing)
                        Text(verbatim: InsightsFormat.ago(s.lastActive, now: now)).dsFont(DS.Font.microNumeric).foregroundStyle(DS.Color.textTertiary)
                            .frame(minWidth: DS.Space.s6, alignment: .trailing)
                    }
                    ShareBar(fraction: s.costUSD / top)
                }
            }
        }
    }
}
