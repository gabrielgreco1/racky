import RackyCore
import RackyDesignSystem
import RackyProtocol
import SwiftUI

enum StatusBarMetrics {
    static let popover: CGFloat = 300
    static let computersPopover: CGFloat = 320
    static let barHeight: CGFloat = 4
    static let logo: CGFloat = 12
    static let separator: CGFloat = 1
}

/// Status bar (03 §5): 24 pt, fundo `chrome`, `border-top`, padding 0×12, gap 16, texto 12. Esquerda: uso do Claude e do Codex;
/// direita: computadores, uso do proxy e o aviso do Docker. Segmento sem dado não aparece. Clique direito: checkboxes + `Hide`.
struct StatusBarView: View {
    let controller: StatusBarController

    var body: some View {
        HStack(spacing: DS.Space.s4) {
            ForEach(StatusBarSegment.allCases.filter(\.onLeft), id: \.self) { segment($0) }
            Spacer(minLength: DS.Space.s4)
            ForEach(StatusBarSegment.allCases.filter { !$0.onLeft }, id: \.self) { segment($0) }
        }
        .padding(.horizontal, DS.Space.s3)
        .frame(maxWidth: .infinity)
        .frame(height: DS.Layout.statusBarHeight)
        .background(DS.Color.chrome)
        .overlay(alignment: .top) { Rectangle().fill(DS.Color.border).frame(height: StatusBarMetrics.separator) }
        .dsContextMenu(name: "statusBarMenu", entries: { controller.contextEntries() })
        .a11y(.statusBar, kind: "container")
    }

    @ViewBuilder private func segment(_ segment: StatusBarSegment) -> some View {
        if controller.shows(segment), segment == .agents {
            // Clique leva às sessões (o item Sessions substituiu o Inbox).
            ActionButton(.pageSessions, id: segment.a11yID) { StatusBarSegmentLabel(controller: controller, segment: segment) }
                .buttonStyle(.plain)
        } else if controller.shows(segment) {
            ActionButton(.statusBarOpenSegment, id: segment.a11yID, argument: .select(segment.rawValue)) {
                StatusBarSegmentLabel(controller: controller, segment: segment)
            }
            .buttonStyle(.plain)
        }
    }
}

/// O rótulo de um segmento: logo ou ícone + texto.
struct StatusBarSegmentLabel: View {
    let controller: StatusBarController
    let segment: StatusBarSegment

    var body: some View {
        HStack(spacing: DS.Space.s1_5) {
            switch segment {
            case .claude, .codex:
                if let usage = segment == .claude ? controller.content.claude : controller.content.codex {
                    DSAgentLogo(usage.provider.agentKind, size: StatusBarMetrics.logo)
                    usageText(usage)
                }
            case .agents:
                if let agents = controller.agents {
                    DSAgentIndicator(agents.glyph, size: .sm)
                    Text(verbatim: agents.text).dsFont(DS.Font.label).foregroundStyle(DS.Color.textSecondary)
                }
            case .computers:
                Image(systemName: "display").font(.system(size: StatusBarMetrics.logo)).foregroundStyle(DS.Color.textSecondary)
                if let computers = controller.content.computers {
                    Text(verbatim: computers.text).dsFont(DS.Font.label).foregroundStyle(DS.Color.textSecondary)
                }
            case .proxyUsage:
                if let proxy = controller.content.proxy {
                    Text(verbatim: proxy.text).dsFont(DS.Font.label).foregroundStyle(DS.Color.textSecondary)
                }
            case .docker:
                Text("Docker isn't running", bundle: .module).dsFont(DS.Font.label).foregroundStyle(DS.Color.warning)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .contentShape(Rectangle())
    }

    /// `5h 62% · 7d 31%`: o percentual leva a cor do estado (≥ 80% aviso, ≥ 95% crítico).
    private func usageText(_ usage: StatusBarUsage) -> some View {
        HStack(spacing: DS.Space.s1_5) {
            ForEach(Array(usage.windows.enumerated()), id: \.offset) { index, window in
                if index > 0 { Text(verbatim: "·").dsFont(DS.Font.label).foregroundStyle(DS.Color.textTertiary) }
                HStack(spacing: DS.Space.s1) {
                    Text(verbatim: window.label).dsFont(DS.Font.label).foregroundStyle(DS.Color.textSecondary)
                    Text(verbatim: window.percentText).dsFont(DS.Font.label).foregroundStyle(StatusBarTone.color(window.level))
                }
            }
        }
    }
}

enum StatusBarTone {
    static func color(_ level: StatusBarLevel) -> Color {
        switch level {
        case .normal: DS.Color.textPrimary
        case .warning: DS.Color.warning
        case .destructive: DS.Color.destructive
        }
    }

    static func fill(_ level: StatusBarLevel) -> Color {
        switch level {
        case .normal: DS.Color.textPrimary.opacity(0.7)
        case .warning: DS.Color.warning
        case .destructive: DS.Color.destructive
        }
    }
}

// MARK: Popovers

/// Popover de um segmento (03 §5). Lê o controlador, então os números acompanham o Insights enquanto aberto.
struct StatusBarPopoverContent: View {
    let controller: StatusBarController
    let segment: StatusBarSegment
    let dismiss: @MainActor () -> Void

    var body: some View {
        Group {
            switch segment {
            case .claude: usage(controller.content.claude)
            case .codex: usage(controller.content.codex)
            case .agents: EmptyView()
            case .computers: StatusBarComputersPopover(content: controller.content.computers, dismiss: dismiss)
            case .proxyUsage: StatusBarProxyPopover(content: controller.content.proxy, dismiss: dismiss)
            case .docker: StatusBarDockerPopover(dismiss: dismiss)
            }
        }
        .padding(DS.Space.s3)
        .frame(width: segment == .computers ? StatusBarMetrics.computersPopover : StatusBarMetrics.popover, alignment: .leading)
        .dsMenuSurface()
    }

    @ViewBuilder private func usage(_ usage: StatusBarUsage?) -> some View {
        if let usage {
            StatusBarUsagePopover(usage: usage, now: controller.now(), calendar: controller.calendar)
        }
    }
}

struct StatusBarUsagePopover: View {
    let usage: StatusBarUsage
    let now: Date
    var calendar = Calendar.current

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            ForEach(Array(usage.windows.enumerated()), id: \.offset) { _, window in
                VStack(alignment: .leading, spacing: DS.Space.s1) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: window.label == "5h" ? "5-hour window" : "7-day window").dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary)
                        Spacer(minLength: DS.Space.s1)
                        Text(verbatim: window.percentText).dsFont(DS.Font.label).foregroundStyle(StatusBarTone.color(window.level))
                    }
                    bar(window)
                    if let resets = window.resetsAt {
                        Text(verbatim: StatusBarContent.resetText(resets, now: now, calendar: calendar)).dsFont(DS.Font.microNumeric).foregroundStyle(DS.Color.textTertiary)
                    }
                }
            }
            Text(verbatim: usage.source).dsFont(DS.Font.micro).foregroundStyle(DS.Color.textTertiary)
        }
    }

    private func filled(_ window: StatusBarWindow) -> CGFloat { CGFloat(Swift.min(Swift.max(window.fraction, 0), 1)) }

    private func bar(_ window: StatusBarWindow) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(DS.Color.fg8)
                Capsule().fill(StatusBarTone.fill(window.level)).frame(width: proxy.size.width * filled(window))
            }
        }
        .frame(height: StatusBarMetrics.barHeight)
        .accessibilityHidden(true)
    }
}

/// Um botão de ação dentro do popover: fecha o popover junto com o clique.
private extension View {
    func closesPopover(_ dismiss: @escaping @MainActor () -> Void) -> some View {
        simultaneousGesture(TapGesture().onEnded { dismiss() })
    }
}

struct StatusBarComputersPopover: View {
    let content: StatusBarComputers?
    let dismiss: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            if let content {
                ForEach(content.lines) { line in row(line) }
                if content.queued > 0 {
                    Text(verbatim: content.queued == 1 ? "1 computer waiting in the queue" : "\(content.queued) computers waiting in the queue")
                        .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                }
            }
            DSButton(.pageComputers, id: .statusBarPopoverOpenComputers, "Open Computers", variant: .outline, size: .xs)
                .closesPopover(dismiss)
        }
    }

    private func row(_ line: StatusBarComputerLine) -> some View {
        HStack(alignment: .top, spacing: DS.Space.s2) {
            VStack(alignment: .leading, spacing: DS.Space.s0_5) {
                Text(verbatim: line.name).dsFont(DS.Font.label).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                Text(verbatim: details(line)).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).lineLimit(2)
            }
            Spacer(minLength: DS.Space.s1)
            DSButton(.computerStop, id: .statusBarPopoverComputersStop(line.name), "Stop", variant: .ghost, size: .xs, argument: .select(line.name))
                .closesPopover(dismiss)
        }
    }

    /// `Austin listings · In use · headless · zyte-us · 312 MB · 4% CPU · Proxy $0.12 today`.
    private func details(_ line: StatusBarComputerLine) -> String {
        var parts: [String] = []
        if let session = line.session { parts.append(session) }
        parts.append(line.state)
        parts.append(line.mode)
        parts.append(line.proxy)
        if let memory = line.memoryBytes { parts.append(InsightsFormat.bytes(UInt64(max(0, memory)))) }
        if let cpu = line.cpuPercent { parts.append("\(Int(cpu.rounded()))% CPU") }
        if let usage = line.proxyUsage { parts.append("\(usage) proxy today") }
        if line.proxyUsageUnavailable { parts.append("Usage unavailable") }
        return parts.joined(separator: " · ")
    }
}

struct StatusBarProxyPopover: View {
    let content: StatusBarProxy?
    let dismiss: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            if let content {
                ForEach(content.lines) { line in
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: line.name).dsFont(DS.Font.label).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                        Spacer(minLength: DS.Space.s1)
                        if let micros = line.todayMicros {
                            Text(verbatim: "\(StatusBarProxy.money(micros)) · \(line.requests) requests").dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary)
                        } else {
                            Text("Usage unavailable", bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                        }
                    }
                }
            }
            DSButton(.settingsOpenSection, id: .statusBarPopoverProxySettings, "Proxy Settings", variant: .outline, size: .xs, argument: .select("computers"))
                .closesPopover(dismiss)
        }
    }
}

struct StatusBarDockerPopover: View {
    let dismiss: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            Text("Subagent computers need Docker. Start it and they come back.", bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary)
            DSButton(.dockerStart, id: .statusBarPopoverStartDocker, "Start Docker", variant: .outline, size: .xs).closesPopover(dismiss)
        }
    }
}
