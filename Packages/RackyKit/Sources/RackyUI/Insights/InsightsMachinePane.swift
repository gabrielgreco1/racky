import RackyCore
import RackyDesignSystem
import SwiftUI

/// Aba Machine: CPU, memória, disco, rede, apps no topo, computadores Docker e agentes por sessão.
struct InsightsMachinePane: View {
    let snapshot: InsightsSnapshot
    let history: InsightsHistory
    @Binding var sortByMemory: Bool
    let width: CGFloat

    var body: some View {
        if let machine = snapshot.machine {
            InsightsAdaptive(width: width) {
                wideBody(machine)
            } medium: {
                mediumBody(machine)
            } condensed: {
                condensedBody(machine)
            } compact: {
                compactBody(machine)
            }
        } else {
            DSEmptyState(String(localized: "Reading this Mac…", bundle: .module))
        }
    }

    // MARK: Largo (duas colunas) e médio (uma coluna)

    private func wideBody(_ m: MachineSnapshot) -> some View {
        HStack(alignment: .top, spacing: DS.Space.s4) {
            VStack(alignment: .leading, spacing: .zero) {
                InsightsSection(title: "CPU", trailing: m.cpu.map { "load " + String(format: "%.2f", $0.load1) }, rule: false) { cpuBlock(m) }
                InsightsSection(title: "Memory", trailing: m.memory.map { InsightsFormat.bytes($0.totalBytes) }) { memoryBlock(m) }
                InsightsSection(title: "Disk", trailing: nil) { diskBlock(m) }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            VStack(alignment: .leading, spacing: .zero) {
                InsightsSection(title: "Network", trailing: nil, rule: false) { networkBlock(m) }
                InsightsSection(title: "Top apps", trailing: nil) { appsBlock(m) }
                InsightsSection(title: "Computers", trailing: nil) { computersBlock }
                if !snapshot.agents.isEmpty {
                    InsightsSection(title: "Agents by session", trailing: nil) { agentsBlock }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .layoutProbe("pane.wide")
    }

    private func condensedBody(_ m: MachineSnapshot) -> some View {
        VStack(alignment: .leading, spacing: .zero) {
            InsightsSection(title: "CPU", trailing: m.cpu.map { "load " + String(format: "%.2f", $0.load1) }, rule: false) { cpuBlock(m) }
            InsightsSection(title: "Memory", trailing: m.memory.map { InsightsFormat.bytes($0.totalBytes) }) { memoryBlock(m) }
            InsightsSection(title: "Disk", trailing: nil) { diskBlock(m) }
        }
        .layoutProbe("pane.condensed")
    }

    private func mediumBody(_ m: MachineSnapshot) -> some View {
        VStack(alignment: .leading, spacing: .zero) {
            InsightsSection(title: "CPU", trailing: m.cpu.map { "load " + String(format: "%.2f", $0.load1) }, rule: false) { cpuBlock(m) }
            InsightsSection(title: "Memory", trailing: m.memory.map { InsightsFormat.bytes($0.totalBytes) }) { memoryBlock(m) }
            InsightsSection(title: "Disk", trailing: nil) { diskBlock(m) }
            InsightsSection(title: "Network", trailing: nil) { networkBlock(m) }
            InsightsSection(title: "Top apps", trailing: nil) { appsBlock(m) }
            InsightsSection(title: "Computers", trailing: nil) { computersBlock }
            if !snapshot.agents.isEmpty {
                InsightsSection(title: "Agents by session", trailing: nil) { agentsBlock }
            }
        }
        .layoutProbe("pane.medium")
    }

    private func cpuBlock(_ m: MachineSnapshot) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            HStack(alignment: .firstTextBaseline) {
                AnimatedNumber(value: (m.cpu?.total ?? 0) * 100) { "\(Int($0.rounded()))%" }
                    .dsFont(DS.Font.control).foregroundStyle(InsightsTone.color(for: m.cpu?.total ?? 0))
                Spacer(minLength: DS.Space.s1)
                if let c = m.cpu {
                    Text(verbatim: "user \(InsightsFormat.percent(c.user)) · system \(InsightsFormat.percent(c.system))").dsFont(DS.Font.microNumeric).foregroundStyle(DS.Color.textTertiary)
                }
            }
            HistoryLine(values: history.cpu, ceiling: 1, color: InsightsTone.color(for: m.cpu?.total ?? 0))
            if let cores = m.cpu?.perCore, !cores.isEmpty { CoreBars(loads: cores) }
        }
    }

    private func memoryBlock(_ m: MachineSnapshot) -> some View {
        let mem = m.memory
        let total = Double(max(1, mem?.totalBytes ?? 1))
        return VStack(alignment: .leading, spacing: DS.Space.s2) {
            HStack(alignment: .firstTextBaseline) {
                AnimatedNumber(value: (mem?.usedFraction ?? 0) * 100) { "\(Int($0.rounded()))%" }
                    .dsFont(DS.Font.control).foregroundStyle(DS.Color.textPrimary)
                Text(verbatim: InsightsFormat.bytes(mem?.usedBytes ?? 0)).dsFont(DS.Font.control).foregroundStyle(DS.Color.textSecondary)
                Spacer(minLength: DS.Space.s1)
                if let p = mem?.pressure { pressureBadge(p) }
            }
            SegmentedBar(segments: [
                .init(id: "app", fraction: Double(mem?.appBytes ?? 0) / total, color: DS.Color.textPrimary),
                .init(id: "wired", fraction: Double(mem?.wiredBytes ?? 0) / total, color: DS.Color.textSecondary),
                .init(id: "compressed", fraction: Double(mem?.compressedBytes ?? 0) / total, color: DS.Color.textTertiary),
            ])
            HStack(spacing: DS.Space.s3) {
                legend(DS.Color.textPrimary, "App", mem?.appBytes)
                legend(DS.Color.textSecondary, "Wired", mem?.wiredBytes)
                legend(DS.Color.textTertiary, "Compressed", mem?.compressedBytes)
            }
            if let swap = mem?.swapUsedBytes, swap > 0 { InsightsStat(label: "Swap used", value: InsightsFormat.bytes(swap)) }
        }
    }

    private func legend(_ color: Color, _ label: LocalizedStringKey, _ bytes: UInt64?) -> some View {
        HStack(spacing: DS.Space.s1) {
            Circle().fill(color).frame(width: DS.Space.s1_5, height: DS.Space.s1_5)
            Text(label, bundle: .module).dsFont(DS.Font.micro).foregroundStyle(DS.Color.textSecondary)
            Text(verbatim: InsightsFormat.bytes(bytes ?? 0)).dsFont(DS.Font.microNumeric).foregroundStyle(DS.Color.textTertiary)
        }
    }

    private func pressureBadge(_ p: MemoryPressureLevel) -> some View {
        switch p {
        case .normal: DSBadge(String(localized: "Pressure normal", bundle: .module))
        case .warning: DSBadge(String(localized: "Pressure high", bundle: .module), variant: .warning)
        case .critical: DSBadge(String(localized: "Pressure critical", bundle: .module), variant: .error)
        }
    }

    private func diskBlock(_ m: MachineSnapshot) -> some View {
        let d = m.disk
        return VStack(alignment: .leading, spacing: DS.Space.s2) {
            HStack(alignment: .firstTextBaseline) {
                AnimatedNumber(value: (d?.usedFraction ?? 0) * 100) { "\(Int($0.rounded()))%" }
                    .dsFont(DS.Font.control).foregroundStyle(InsightsTone.color(for: d?.usedFraction ?? 0))
                Text(verbatim: "used").dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                Spacer(minLength: DS.Space.s1)
                Text(verbatim: InsightsFormat.bytes(d?.freeBytes ?? 0) + " free").dsFont(DS.Font.microNumeric).foregroundStyle(DS.Color.textSecondary)
            }
            ThinBar(fraction: d?.usedFraction)
            HStack(spacing: DS.Space.s4) {
                rateLabel("arrow.down.doc", d?.readBytesPerSec ?? 0, "Read")
                rateLabel("arrow.up.doc", d?.writeBytesPerSec ?? 0, "Write")
            }
        }
    }

    private func rateLabel(_ symbol: String, _ value: Double, _ label: LocalizedStringKey) -> some View {
        HStack(spacing: DS.Space.s1) {
            Image(systemName: symbol).font(.system(size: DS.Space.s3)).foregroundStyle(DS.Color.textTertiary)
            Text(label, bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary)
            Text(verbatim: InsightsFormat.rate(value)).dsFont(DS.Font.microNumeric).foregroundStyle(DS.Color.textPrimary)
        }
    }

    private func networkBlock(_ m: MachineSnapshot) -> some View {
        let n = m.network
        return VStack(alignment: .leading, spacing: DS.Space.s2) {
            HStack(spacing: DS.Space.s4) {
                rateLabel("arrow.down", n?.downBytesPerSec ?? 0, "Down")
                rateLabel("arrow.up", n?.upBytesPerSec ?? 0, "Up")
            }
            ZStack {
                HistoryLine(values: history.down, ceiling: nil, color: DS.Color.textPrimary, fill: true)
                HistoryLine(values: history.up, ceiling: max(history.down.max() ?? 1, history.up.max() ?? 1), color: DS.Color.textSecondary, fill: false)
            }
            HStack {
                Text(verbatim: "since boot ↓ " + InsightsFormat.bytes(n?.totalDownBytes ?? 0) + " ↑ " + InsightsFormat.bytes(n?.totalUpBytes ?? 0))
                    .dsFont(DS.Font.microNumeric).foregroundStyle(DS.Color.textTertiary)
            }
        }
    }

    private func appsBlock(_ m: MachineSnapshot) -> some View {
        let apps = sortByMemory ? m.topByMemory : m.topByCPU
        let peak = max(sortByMemory ? Double(apps.first?.memoryBytes ?? 1) : (apps.first?.cpuPercent ?? 1), 0.0001)
        return VStack(spacing: DS.Space.s2) {
            sortSwitch
            ForEach(apps) { app in
                VStack(spacing: DS.Space.s1) {
                    HStack(spacing: DS.Space.s2) {
                        Text(verbatim: app.name).dsFont(DS.Font.small).foregroundStyle(DS.Color.textPrimary).lineLimit(1).truncationMode(.tail)
                        if app.processCount > 1 { Text(verbatim: "×\(app.processCount)").dsFont(DS.Font.microNumeric).foregroundStyle(DS.Color.textTertiary) }
                        Spacer(minLength: DS.Space.s1)
                        Text(verbatim: sortByMemory ? InsightsFormat.bytes(app.memoryBytes) : String(format: "%.0f%%", app.cpuPercent))
                            .dsFont(DS.Font.microNumeric).foregroundStyle(DS.Color.textPrimary)
                    }
                    ShareBar(fraction: (sortByMemory ? Double(app.memoryBytes) : app.cpuPercent) / peak)
                }
            }
        }
    }

    private var sortSwitch: some View {
        HStack(spacing: .zero) {
            ForEach([false, true], id: \.self) { byMemory in
                let active = byMemory == sortByMemory
                // lint-ui: allow buttons seletor local de ordenação do módulo; não é uma ação do app
                Button { sortByMemory = byMemory } label: { Text(byMemory ? "Memory" : "CPU", bundle: .module) }
                    .buttonStyle(DSSegmentStyle(active: active))
                    .background { if active { RoundedRectangle(cornerRadius: DS.Radius.sm).fill(DS.Color.accent) } }
                    .accessibilityAddTraits(active ? .isSelected : [])
            }
            Spacer(minLength: .zero)
        }
        .padding(DSMetrics.segmentedPadding)
        .frame(height: DSMetrics.segmentedHeight)
        .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.Color.secondary))
        .fixedSize(horizontal: true, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var computersBlock: some View {
        if !snapshot.dockerAvailable {
            Text("No computers to show right now.").dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
        } else if snapshot.computers.isEmpty {
            Text("No computers running.").dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
        } else {
            VStack(spacing: DS.Space.s2) {
                ForEach(snapshot.computers) { c in
                    VStack(spacing: DS.Space.s1) {
                        HStack(spacing: DS.Space.s1_5) {
                            DSAgentIndicator(.dot(c.state == "running" ? DS.ColorSpec.agentDone : DS.ColorSpec.processExited), size: .sm)
                            Text(verbatim: c.name).dsFont(DS.Font.small).foregroundStyle(DS.Color.textPrimary).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: DS.Space.s1)
                            Text(verbatim: String(format: "%.0f%%", c.cpuPercent)).dsFont(DS.Font.microNumeric).foregroundStyle(DS.Color.textPrimary)
                            Text(verbatim: InsightsFormat.bytes(UInt64(max(0, c.memoryBytes)))).dsFont(DS.Font.microNumeric).foregroundStyle(DS.Color.textSecondary)
                        }
                        ShareBar(fraction: c.memoryFraction, color: InsightsTone.color(for: c.memoryFraction))
                    }
                }
            }
        }
    }

    private var agentsBlock: some View {
        VStack(spacing: DS.Space.s2) {
            ForEach(snapshot.agents.prefix(8)) { a in
                HStack(spacing: DS.Space.s1_5) {
                    DSAgentLogo(a.provider.agentKind, size: DS.Space.s3)
                    Text(verbatim: a.title).dsFont(DS.Font.small).foregroundStyle(DS.Color.textPrimary).lineLimit(1).truncationMode(.tail)
                    if a.running { DSAgentIndicator(.dot(DS.ColorSpec.agentDone), size: .sm) }
                    if a.subagentMessages > 0 { DSBadge("+\(a.subagentMessages) sub", variant: .mono) }
                    Spacer(minLength: DS.Space.s1)
                    Text(verbatim: InsightsFormat.tokens(a.counts.fresh)).dsFont(DS.Font.microNumeric).foregroundStyle(DS.Color.textSecondary)
                    Text(verbatim: InsightsFormat.cost(a.costUSD)).dsFont(DS.Font.microNumeric).foregroundStyle(DS.Color.textPrimary)
                        .frame(minWidth: DS.Space.s10, alignment: .trailing)
                }
            }
        }
    }

    // MARK: Compacto

    private func compactBody(_ m: MachineSnapshot) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            compactRow("CPU", m.cpu?.total, text: m.cpu.map { InsightsFormat.percent($0.total) })
            compactRow("MEM", m.memory?.usedFraction, text: m.memory.map { InsightsFormat.percent($0.usedFraction) })
            compactRow("DISK", m.disk?.usedFraction, text: m.disk.map { InsightsFormat.percent($0.usedFraction) })
            HStack {
                Image(systemName: "arrow.down").font(.system(size: DS.Space.s3)).foregroundStyle(DS.Color.textTertiary)
                Text(verbatim: InsightsFormat.rate(m.network?.downBytesPerSec ?? 0)).dsFont(DS.Font.microNumeric).foregroundStyle(DS.Color.textPrimary)
                Spacer(minLength: DS.Space.s1)
                Image(systemName: "arrow.up").font(.system(size: DS.Space.s3)).foregroundStyle(DS.Color.textTertiary)
                Text(verbatim: InsightsFormat.rate(m.network?.upBytesPerSec ?? 0)).dsFont(DS.Font.microNumeric).foregroundStyle(DS.Color.textPrimary)
            }
            if snapshot.dockerAvailable {
                InsightsStat(label: "Computers", value: "\(snapshot.computers.count)")
            }
        }
        .layoutProbe("pane.compact")
    }

    private func compactRow(_ label: String, _ fraction: Double?, text: String?) -> some View {
        VStack(spacing: DS.Space.s1) {
            HStack {
                Text(verbatim: label).dsFont(DS.Font.micro).foregroundStyle(DS.Color.textSecondary)
                Spacer(minLength: DS.Space.s1)
                Text(verbatim: text ?? "–").dsFont(DS.Font.label).monospacedDigit().foregroundStyle(InsightsTone.color(for: fraction ?? 0))
            }
            ThinBar(fraction: fraction)
        }
    }
}

/// Aba Proxy: uso por proxy cadastrado (requisições, dados, custo) e barras dos últimos dias.
struct InsightsProxyPane: View {
    let proxies: [ProxyUsageSummary]
    let width: CGFloat

    var body: some View {
        if proxies.isEmpty {
            DSEmptyState(String(localized: "No proxies yet. Add one in Settings to see its usage here.", bundle: .module))
        } else {
            InsightsAdaptive(width: width) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: DS.Space.s4, alignment: .top), GridItem(.flexible(), alignment: .top)],
                          alignment: .leading, spacing: .zero) {
                    ForEach(proxies) { p in section(p, compact: false, rule: false) }
                }
                .layoutProbe("pane.wide")
            } medium: {
                VStack(alignment: .leading, spacing: .zero) {
                    ForEach(Array(proxies.enumerated()), id: \.element.id) { i, p in section(p, compact: false, rule: i > 0) }
                }
                .layoutProbe("pane.medium")
            } condensed: {
                VStack(alignment: .leading, spacing: .zero) {
                    ForEach(Array(proxies.enumerated()), id: \.element.id) { i, p in section(p, compact: true, rule: i > 0) }
                }
                .layoutProbe("pane.condensed")
            } compact: {
                VStack(alignment: .leading, spacing: .zero) {
                    ForEach(Array(proxies.enumerated()), id: \.element.id) { i, p in section(p, compact: true, rule: i > 0) }
                }
                .layoutProbe("pane.compact")
            }
        }
    }

    private func section(_ p: ProxyUsageSummary, compact: Bool, rule: Bool) -> some View {
        InsightsSection(title: LocalizedStringKey(p.name), trailing: p.isDefault ? "default" : nil, rule: rule) {
            if compact { compactBody(p) } else { fullBody(p) }
        }
    }

    private func fullBody(_ p: ProxyUsageSummary) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            HStack(alignment: .firstTextBaseline) {
                AnimatedNumber(value: Double(p.requests)) { InsightsFormat.tokens(Int($0)) }
                    .dsFont(DS.Font.control).foregroundStyle(DS.Color.textPrimary)
                Text(verbatim: "requests").dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                Spacer(minLength: DS.Space.s1)
                Text(verbatim: InsightsFormat.micros(p.costMicros)).dsFont(DS.Font.control).foregroundStyle(DS.Color.textSecondary)
            }
            InsightsStat(label: "Data", value: InsightsFormat.bytes(UInt64(max(0, p.bytes))))
            DayBars(values: p.daily.map { Double($0.requests) })
            Text("Last 30 days").dsFont(DS.Font.micro).foregroundStyle(DS.Color.textTertiary)
        }
    }

    private func compactBody(_ p: ProxyUsageSummary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
            Text(verbatim: InsightsFormat.tokens(p.requests)).dsFont(DS.Font.label).monospacedDigit().foregroundStyle(DS.Color.textPrimary)
            Text(verbatim: "requests").dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
            Spacer(minLength: DS.Space.s1)
            Text(verbatim: InsightsFormat.bytes(UInt64(max(0, p.bytes))) + " · " + InsightsFormat.micros(p.costMicros))
                .dsFont(DS.Font.microNumeric).foregroundStyle(DS.Color.textSecondary).lineLimit(1)
        }
    }
}

/// Barras diárias (proxy): altura proporcional ao maior dia, último dia em destaque.
struct DayBars: View {
    let values: [Double]

    var body: some View {
        let peak = max(values.max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: DS.Space.s0_5) {
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                RoundedRectangle(cornerRadius: DS.Radius.xs)
                    .fill(DS.Color.textPrimary.opacity(i == values.count - 1 ? 0.95 : 0.4))
                    .frame(height: max(DS.Space.s0_5, InsightsMetrics.sparkHeight * CGFloat(v / peak)))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: InsightsMetrics.sparkHeight, alignment: .bottom)
        .overlay(alignment: .bottom) { Rectangle().fill(DS.Color.border).frame(height: DSMetrics.hairline) }
    }
}
