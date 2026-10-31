import RackyCore
import RackyDesignSystem
import RackyProtocol
import SwiftUI

/// Medidas do chrome do pane (03 §4, DS §12.23).
enum PaneMetrics {
    static let headerHeight = DS.Layout.paneHeaderHeight
    static let headerPaddingH = DS.Space.s2
    static let buttonGap: CGFloat = 0
    static let banner = DS.Space.s8
    static let cardWidth: CGFloat = 360
    static let dividerHit = PaneLayout.dividerThickness + 2 * DS.Layout.paneDividerHitSlop
    static let separator: CGFloat = 1
    static let logo = DS.Space.s3
    static let ignitionLogo = DS.Space.s8
    static let ignitionHalo = DS.Space.s10 + DS.Space.s6
    static let phaseGlyph = DS.Space.s3
    static let phaseListWidth: CGFloat = 200
}

/// Dados que o container do pane entrega às views SwiftUI do chrome (cabeçalho, botões, banners).
@MainActor
@Observable
final class PaneChromeModel {
    var terminalID = UUID()
    var title = ""
    var provider: TerminalProvider = .shell
    var glyph: DSIndicatorGlyph = .none
    var focused = false
    var expanded = false
    var hovering = false
    var state: PaneRunState = .running
    var errorDetail = ""
    var timeline: LaunchTimeline?
    /// Interrupted (T1-23): por que o processo sumiu e se o Resume usa o ID nativo (senão vira "Continue Last").
    var interruption: InterruptionReason = .unexpected
    var exactResume = true
    /// "Subagent computers" da sessão do pane (F12): só Claude. `nil` = sem controle.
    var subagentSession: UUID?
    var subagentMode: SubagentComputersMode = .off
    var subagentRestart = false
    @ObservationIgnored var onFloatingResize: ((CGSize) -> Void)?
    /// Arrasto do cabeçalho (F11): vira tab ou muda de lugar sobre outro pane.
    var drag: PaneDragController?

    var id: String { terminalID.uuidString }
    var agentName: String { provider.isAgent ? ProviderAdapters.name(provider) : String(localized: "Terminal", bundle: .module) }
}

/// Cabeçalho do pane (03 §4.2): 24 de altura, sobreposto ao topo, separador inferior `white/6`.
struct PaneHeaderView: View {
    let model: PaneChromeModel

    var body: some View {
        HStack(spacing: DS.Space.s1_5) {
            if model.glyph != .none { DSAgentIndicator(model.glyph, size: .sm).a11y(.paneStatus(model.id), kind: "status") }
            DSAgentLogo(model.provider, size: PaneMetrics.logo)
            Text(verbatim: model.title)
                .dsFont(DS.Font.monoPane)
                .foregroundStyle(model.focused ? DS.Color.paneTitleInput : DS.Color.paneTitle)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: DS.Space.s2)
            PaneComputersToggle(model: model)
            PaneButtons(model: model)
        }
        .padding(.horizontal, PaneMetrics.headerPaddingH)
        .frame(height: PaneMetrics.headerHeight)
        .background {
            ZStack {
                DS.Color.terminalBackground
                PaneDragSource(controller: model.drag, payload: .pane(model.terminalID), title: { model.title })
            }
        }
        .overlay(alignment: .bottom) { DS.Color.paneTitleSeparator.frame(height: PaneMetrics.separator) }
        .a11y(.paneHeader(model.id), kind: "container", label: model.title)
    }
}

/// Botões de ação do pane (split à direita e abaixo, expandir, fechar). Split: no pane ativo ou no hover; fechar: só no hover (fade 120 ms).
struct PaneButtons: View {
    let model: PaneChromeModel

    var body: some View {
        let arg = ActionArgument.select(model.id)
        let showSplit = model.focused || model.hovering
        HStack(spacing: PaneMetrics.buttonGap) {
            ActionButton(.paneSplitRight, id: .paneSplitRight(model.id), argument: arg, tooltip: String(localized: "Split Right", bundle: .module)) {
                Image(systemName: "square.split.2x1")
            }
            .buttonStyle(DSIconButtonStyle(.pane))
            .opacity(showSplit ? 1 : 0)
            ActionButton(.paneSplitDown, id: .paneSplitDown(model.id), argument: arg, tooltip: String(localized: "Split Down", bundle: .module)) {
                Image(systemName: "square.split.1x2")
            }
            .buttonStyle(DSIconButtonStyle(.pane))
            .opacity(showSplit ? 1 : 0)
            ActionButton(
                .paneToggleExpand, id: .paneExpand(model.id), argument: arg,
                tooltip: model.expanded ? String(localized: "Collapse Pane", bundle: .module) : String(localized: "Expand Pane", bundle: .module)
            ) {
                Image(systemName: model.expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(DSIconButtonStyle(.pane))
            .opacity(showSplit ? 1 : 0)
            ActionButton(.paneClose, id: .paneClose(model.id), argument: arg, tooltip: String(localized: "Close Pane", bundle: .module)) {
                Image(systemName: "xmark")
            }
            .buttonStyle(DSIconButtonStyle(.pane))
            .opacity(model.hovering ? 1 : 0)
        }
        .animation(MotionPolicy.shared.animation(MotionTokens.Easing.ease, MotionTokens.Duration.hover), value: showSplit)
        .animation(MotionPolicy.shared.animation(MotionTokens.Easing.ease, MotionTokens.Duration.hover), value: model.hovering)
    }
}

/// Ícone "Subagent computers" do pane (F12): sempre visível com o modo ligado (ou com "Restart to apply" pendente); desligado só aparece
/// no hover ou com o pane em foco.
struct PaneComputersToggle: View {
    let model: PaneChromeModel

    var body: some View {
        if let session = model.subagentSession {
            let visible = model.subagentMode.isOn || model.subagentRestart || model.hovering || model.focused
            HStack(spacing: DS.Space.s1) {
                if model.subagentRestart {
                    RestartToApplyPill(sessionID: session, id: nil)
                }
                SubagentToggleButton(sessionID: session, mode: model.subagentMode, id: .paneComputers(model.id), restartPending: model.subagentRestart, style: .pane)
                    .opacity(visible ? 1 : 0)
            }
            .animation(MotionPolicy.shared.animation(MotionTokens.Easing.ease, MotionTokens.Duration.hover), value: visible)
            .animation(MotionPolicy.shared.animation(MotionTokens.Springs.snappy), value: model.subagentRestart)
        }
    }
}

/// Variante chromeless (1 pane): só os botões no canto superior direito, visíveis no hover.
struct PaneFloatingButtons: View {
    let model: PaneChromeModel

    var body: some View {
        HStack(spacing: PaneMetrics.buttonGap) {
            PaneComputersToggle(model: model)
            PaneButtons(model: model)
                .opacity(model.hovering ? 1 : 0)
        }
        .fixedSize()
        // O quadro da hosting view é do pai (AppKit): avisa quando o conteúdo muda de tamanho ("Restart to apply" entrando, F38).
        .onGeometryChange(for: CGSize.self, of: \.size) { model.onFloatingResize?($0) }
        .animation(MotionPolicy.shared.animation(MotionTokens.Easing.ease, MotionTokens.Duration.hover), value: model.hovering)
    }
}

/// Banner no topo do pane (processo saiu, interrompido, "The process didn't exit.").
struct PaneBannerView: View {
    let model: PaneChromeModel

    var body: some View {
        let arg = ActionArgument.select(model.id)
        HStack(spacing: DS.Space.s2) {
            // Pane estreito: a frase inteira não cabe ao lado dos botões, então vira uma palavra (a frase fica no tooltip).
            ViewThatFits(in: .horizontal) {
                Text(verbatim: text).lineLimit(1).fixedSize()
                Text(verbatim: shortText).lineLimit(1).fixedSize()
            }
            .dsFont(DS.Font.small)
            .foregroundStyle(isWarning ? DS.Color.warning : DS.Color.textSecondary)
            .help(text)
            Spacer(minLength: DS.Space.s2)
            switch model.state {
            case .closing:
                DSButton(.terminalForceQuit, id: .paneClosingForceQuit(model.id), "Force Quit", variant: .outline, size: .xs, argument: arg)
                DSButton(.terminalCancelClose, "Cancel", variant: .outline, size: .xs, argument: arg)
            case .interrupted where model.provider.isAgent:
                if model.exactResume {
                    DSButton(.terminalResume, id: .paneInterruptedResume(model.id), "Resume", variant: .primary, size: .xs, argument: arg)
                } else {
                    DSButton(.terminalResume, id: .paneInterruptedResume(model.id), "Continue Last", variant: .primary, size: .xs, argument: arg)
                }
                DSButton(.terminalStartFresh, "Start Fresh", variant: .outline, size: .xs, argument: arg)
                DSButton(.paneClose, "Close", variant: .outline, size: .xs, argument: arg)
            default:
                DSButton(.terminalRestart, "Restart", variant: .outline, size: .xs, argument: arg)
                DSButton(.paneClose, "Close", variant: .outline, size: .xs, argument: arg)
            }
        }
        .padding(.horizontal, DS.Space.s3)
        .frame(height: PaneMetrics.banner)
        .background(DS.Color.chrome)
        .overlay(alignment: .bottom) { DS.Color.border.frame(height: PaneMetrics.separator) }
        .a11y(bannerID, kind: "banner", label: text)
    }

    private var isWarning: Bool { if case .closing = model.state { true } else { false } }

    private var shortText: String {
        switch model.state {
        case .closing: String(localized: "Not exiting", bundle: .module)
        case .interrupted: String(localized: "Stopped", bundle: .module)
        default: String(localized: "Exited", bundle: .module)
        }
    }

    private var bannerID: A11yID {
        switch model.state {
        case .interrupted: .paneInterrupted(model.id)
        default: .paneExitBanner(model.id)
        }
    }

    private var text: String {
        switch model.state {
        case .closing: String(localized: "The process didn't exit.", bundle: .module)
        case .interrupted:
            switch model.interruption {
            case .macRestarted: String(localized: "This terminal stopped when your Mac restarted.", bundle: .module)
            case .appClosed: String(localized: "This terminal stopped while Racky was closed.", bundle: .module)
            case .unexpected: String(localized: "This terminal stopped unexpectedly.", bundle: .module)
            }
        default:
            model.provider.isAgent
                ? String(localized: "\(model.agentName) exited.", bundle: .module) : String(localized: "pane.exited.shell", bundle: .module)
        }
    }
}

/// Cartão central do pane: saída com erro (`Terminal exited`) e "Couldn't start" (03 §4.6).
struct PaneCardView: View {
    let model: PaneChromeModel

    var body: some View {
        let arg = ActionArgument.select(model.id)
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            switch model.state {
            case .failed(let detail):
                HStack(spacing: DS.Space.s2) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(DS.Color.destructive)
                    Text(String(localized: "Couldn't start \(model.agentName)", bundle: .module))
                        .dsFont(DS.Font.dialogTitle)
                        .foregroundStyle(DS.Color.textPrimary)
                }
                Text(verbatim: detail)
                    .dsFont(DS.Font.monoPane)
                    .foregroundStyle(DS.Color.textSecondary)
                    .lineLimit(6)
                HStack(spacing: DS.Space.s2) {
                    Spacer(minLength: 0)
                    if model.provider.isAgent {
                        DSButton(.agentOpenSettings, "Open Agent Settings", variant: .outline, size: .sm, argument: .select(model.provider.rawValue))
                    }
                    DSButton(.terminalCopyStartError, "Copy Details", variant: .outline, size: .sm, argument: arg)
                    DSButton(.terminalRetryStart, "Try Again", variant: .primary, size: .sm, argument: arg)
                }
            case .exited(let code, let signal):
                Text("Terminal exited", bundle: .module)
                    .dsFont(DS.Font.dialogTitle)
                    .foregroundStyle(DS.Color.textPrimary)
                Text(verbatim: exitText(code: code, signal: signal))
                    .dsFont(DS.Font.dialogBody)
                    .foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DS.Space.s2) {
                    Spacer(minLength: 0)
                    if model.provider.isAgent, model.exactResume {
                        // F30: o botão que o dono quer é continuar a conversa; "Restart" confundia.
                        // Três botões no cartão: "Resume Conversation" cortava ("Resume Conver…"); "Close" sem contorno parecia texto.
                        DSButton(.paneClose, id: .paneExitOverlayClose(model.id), "Close", variant: .outline, size: .sm, argument: arg)
                        DSButton(.terminalStartFresh, "Start Fresh", variant: .outline, size: .sm, argument: arg)
                        DSButton(.terminalResume, id: .paneExitOverlayResume(model.id), "Resume", variant: .primary, size: .sm, argument: arg)
                    } else {
                        DSButton(.paneClose, id: .paneExitOverlayClose(model.id), "Close", variant: .outline, size: .sm, argument: arg)
                        DSButton(.terminalRestart, id: .paneExitOverlayRestart(model.id), "Restart", variant: .primary, size: .sm, argument: arg)
                    }
                }
            default:
                EmptyView()
            }
        }
        .padding(DS.Space.s4)
        .frame(width: PaneMetrics.cardWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Color.chrome))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Color.border))
        .a11y(cardID, kind: "overlay")
    }

    private var cardID: A11yID {
        if case .failed = model.state { .paneStartError(model.id) } else { .paneExitOverlay(model.id) }
    }

    private func exitText(code: Int?, signal: Int?) -> String {
        if let signal { return String(localized: "The process was killed (signal \(signal)). Its output is preserved.", bundle: .module) }
        return String(localized: "The process ended with exit code \(code ?? 0). Its output is preserved.", bundle: .module)
    }
}

extension ProviderAdapters {
    /// Nome do agente na UI ("Claude Code").
    static func name(_ provider: TerminalProvider) -> String { adapter(for: provider).displayName }
}

/// P25: faixa no topo da sessão quando a retomada automática está desligada e há agentes que pararam com o app fechado.
struct StoppedAgentsBanner: View {
    let model: WorkspaceModel

    var body: some View {
        if model.showsDaemonLossBanner { row.a11y(.windowDaemonBanner, kind: "container") } else { row }
    }

    @ViewBuilder private var row: some View {
        let count = model.stoppedAgentsInCurrentSession.count
        let lost = model.showsDaemonLossBanner
        HStack(spacing: DS.Space.s2) {
            Text(verbatim: lost
                ? String(localized: "Background agents stopped unexpectedly.", bundle: .module)
                : count == 1
                ? String(localized: "1 agent stopped while Racky was closed", bundle: .module)
                : String(localized: "\(count) agents stopped while Racky was closed", bundle: .module))
                .dsFont(DS.Font.small)
                .foregroundStyle(DS.Color.textSecondary)
                .lineLimit(1)
            Spacer(minLength: DS.Space.s2)
            if lost {
                // Só com agente que dá para retomar pelo ID; sem ele o botão ficava cinza e parecia quebrado (cada painel tem Continue Last).
                if model.hasInterruptedAgents(in: nil) {
                    DSButton(.sessionResumeAgents, "Resume Agents…", variant: .primary, size: .xs)   // abre o overlay §16.7
                }
            } else {
                DSButton(.sessionResumeStopped, "Resume All", variant: .primary, size: .xs)
            }
        }
        .padding(.horizontal, DS.Space.s3)
        .frame(height: PaneMetrics.banner)
        .background(DS.Color.chrome)
        .overlay(alignment: .bottom) { DS.Color.border.frame(height: PaneMetrics.separator) }
    }
}
