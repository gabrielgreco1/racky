import RackyCore
import RackyDesignSystem
import RackyProtocol
import SwiftUI

/// Estado `Ignition` do pane (03 §4.6, M-503): logo do agente (32) com halo e a PhaseList com as etapas reais do
/// lançamento. Só aparece se o start passa de `ignitionSkip` (0,3 s). Reduce Motion: logo estático, linhas com fade, check sem desenho.
struct PaneIgnitionView: View {
    let model: PaneChromeModel

    private var reduce: Bool { MotionPolicy.shared.reduceMotion }

    var body: some View {
        let arg = ActionArgument.select(model.id)
        let visible = model.timeline?.visible ?? (rows: [], collapsedDone: 0)
        VStack(spacing: DS.Space.s6) {
            IgnitionLogo(provider: model.provider)
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                if visible.collapsedDone > 0 {
                    Text(verbatim: "\(visible.collapsedDone) steps done")
                        .dsFont(DS.Font.small)
                        .foregroundStyle(DS.Color.textTertiary)
                        .transition(.opacity)
                }
                ForEach(visible.rows) { row in
                    PhaseRowView(row: row, paneID: model.id)
                        .transition(reduce ? .opacity : .opacity.combined(with: .offset(y: DS.Space.s1)))
                }
            }
            .frame(minWidth: PaneMetrics.phaseListWidth, alignment: .leading)
            .animation(MotionPolicy.shared.animation(MotionTokens.Easing.standard, MotionTokens.Duration.base), value: visible.rows)
            DSButton(.sessionCancelLaunch, id: .paneIgnitionCancel(model.id), "Cancel", variant: .ghost, size: .sm, argument: arg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Color.terminalBackground)
        .a11y(.paneIgnition(model.id), kind: "container")
    }
}

/// Logo de 32 com halo em loop (escala 1 ↔ 1,04, opacidade 0,5 ↔ 0,8; `MotionTokens.Loop.halo`). Estático em Reduce Motion.
struct IgnitionLogo: View {
    let provider: TerminalProvider

    var body: some View {
        let loop = MotionTokens.Loop.halo
        let scale = loop.numbers["scale"] ?? [1, 1.04]
        let opacity = loop.numbers["opacity"] ?? [0.5, 0.8]
        let still = MotionPolicy.shared.reduceMotion
        TimelineView(.animation(minimumInterval: 1 / MotionPolicyRules.loopFps(loop, lowPower: MotionPolicy.shared.lowPower), paused: still)) { context in
            let phase = still ? 0.5 : (context.date.timeIntervalSinceReferenceDate / loop.period).truncatingRemainder(dividingBy: 1)
            let t = (1 - cos(phase * 2 * .pi)) / 2  // 0 → 1 → 0 suave
            let s = scale[0] + (scale[1] - scale[0]) * t
            let o = opacity[0] + (opacity[1] - opacity[0]) * t
            ZStack {
                Circle()
                    .fill(DS.Color.fg8)
                    .frame(width: PaneMetrics.ignitionHalo, height: PaneMetrics.ignitionHalo)
                    .scaleEffect(s)
                    .opacity(o)
                DSAgentLogo(DSAgentKind(provider), size: PaneMetrics.ignitionLogo)
            }
            .frame(width: PaneMetrics.ignitionHalo, height: PaneMetrics.ignitionHalo)
        }
    }
}

/// Uma linha da checklist: spinner (ativa), check desenhado (concluída, texto muted) ou X (falhou).
private struct PhaseRowView: View {
    let row: LaunchTimeline.Row
    let paneID: String

    var body: some View {
        HStack(spacing: DS.Space.s2) {
            ZStack {
                switch row.status {
                case .running: DSSpinner(size: PaneMetrics.phaseGlyph, delayed: false)
                case .done: DrawnGlyph(kind: .check, color: DS.Color.agentDone)
                case .failed: DrawnGlyph(kind: .cross, color: DS.Color.destructive)
                case .skipped: EmptyView()
                }
            }
            .frame(width: PaneMetrics.phaseGlyph, height: PaneMetrics.phaseGlyph)
            Text(verbatim: row.title)
                .dsFont(DS.Font.body)
                .foregroundStyle(row.status == .running ? DS.Color.textPrimary : DS.Color.textSecondary)
                .lineLimit(1)
        }
        .a11y(.paneIgnitionStep(paneID, row.key.rawValue), kind: "row", label: row.title, value: row.status.rawValue)
    }
}

/// Check ou X desenhado com `trim` (0,24 `expoOut`; X: 0,18). Reduce Motion: aparece pronto.
struct DrawnGlyph: View {
    enum Kind { case check, cross }
    let kind: Kind
    let color: Color
    @State private var progress: CGFloat = 0

    var body: some View {
        GlyphShape(kind: kind)
            .trim(from: 0, to: progress)
            .stroke(color, style: StrokeStyle(lineWidth: MotionTokens.Stroke.liveBorder, lineCap: .round, lineJoin: .round))
            .onAppear {
                if MotionPolicy.shared.reduceMotion { progress = 1; return }
                let duration = kind == .check ? MotionTokens.Duration.medium : MotionTokens.Duration.disclosure
                withAnimation(Motion.curve(MotionTokens.Easing.expoOut, duration)) { progress = 1 }
            }
    }
}

private struct GlyphShape: Shape {
    let kind: DrawnGlyph.Kind

    func path(in rect: CGRect) -> Path {
        var p = Path()
        switch kind {
        case .check:
            p.move(to: CGPoint(x: rect.minX + rect.width * 0.12, y: rect.midY + rect.height * 0.05))
            p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.40, y: rect.maxY - rect.height * 0.18))
            p.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.10, y: rect.minY + rect.height * 0.22))
        case .cross:
            p.move(to: CGPoint(x: rect.minX + rect.width * 0.2, y: rect.minY + rect.height * 0.2))
            p.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.2, y: rect.maxY - rect.height * 0.2))
            p.move(to: CGPoint(x: rect.maxX - rect.width * 0.2, y: rect.minY + rect.height * 0.2))
            p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.2, y: rect.maxY - rect.height * 0.2))
        }
        return p
    }
}
