import RackyCore
import RackyDesignSystem
import RackyProtocol
import RackyViewerKit
import AppKit
import SwiftUI

/// Medidas do viewer (03 §11).
enum ViewerMetrics {
    static let header = DS.Space.s8
    static let banner = DS.Space.s10
    static let pill: CGFloat = 22
    static let frameStroke: CGFloat = 1.5
    static let frameStrokeStrong: CGFloat = 2
    static let noteWidth: CGFloat = 300
    static let noteHeight: CGFloat = 64
    static let badgeSeconds: Double = 3
    static let cardWidth: CGFloat = 360
    static let separator: CGFloat = 1
    static let strip: CGFloat = 72
    static let stripThumbWidth: CGFloat = 104
    static let addressMaxWidth: CGFloat = 420
    static let addressMinWidth: CGFloat = 160
    static let addressIcon: CGFloat = 9
    static let startWidth: CGFloat = 300
    static let monitorWidth: CGFloat = 132
    static let monitorHeight: CGFloat = 84
    static let monitorStand: CGFloat = 28
    static let progressHeight: CGFloat = 3
    static let progressWidth: CGFloat = 240
    static let sweepFraction: CGFloat = 0.6
    static let indeterminateFraction: CGFloat = 0.3
}

/// Embrulha a view AppKit do WebView (a mesma instância durante toda a vida do viewer).
struct ViewerCanvas: NSViewRepresentable {
    let web: ComputerViewerWebView
    func makeNSView(context: Context) -> ComputerViewerWebView { web }
    func updateNSView(_ nsView: ComputerViewerWebView, context: Context) {}
}

/// Viewer de computador como pane (03 §11): header 32, banner de ajuda, canvas noVNC com borda viva conforme o controle.
struct ComputerViewerView: View {
    let controller: ComputerViewerController
    let computers: ComputersController
    /// Nome da sessão de origem para o botão `Back to <sessão>`; `nil` na janela própria (sem página para voltar).
    var backTitle: String?
    /// Faixa de miniaturas dos outros computadores; desligada quando as sub-tabs da sessão já navegam.
    var showsStrip = true
    /// Sem header próprio: as sub-tabs da sessão mostram os controles (uma barra só).
    var showsHeader = true
    /// Num pane da sessão: o nome arrasta o pane (como o título de um terminal) e o X fecha só a tela (o computador segue).
    var pane: ViewerPane? = nil
    @State private var badgeVisible = false
    @State private var breathing = false

    private var model: ComputerViewerModel { controller.model }
    private var id: String { controller.name }

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader { ViewerHeader(controller: controller, backTitle: backTitle, pane: pane) }
            if showsStrip { ViewerStrip(computers: computers, current: id) }
            if let help = model.help { helpBanner(help) }
            ZStack {
                ViewerCanvas(web: controller.web)
                controlFrame
                stateOverlay
                keyboardBadge
                if model.handBackNoteVisible { handBackCard.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(DS.Space.s3) }
                if model.blockedClickAt != nil { blockedTip }
            }
            .background(DS.Color.canvas)
        }
        .background(DS.Color.canvas)
        .overlay { if computers.pendingExit?.computer == id { exitOverlay } }
        .a11y(.viewer(id), kind: "container", label: id)
        .task { await controller.start() }
        // Num pane da sessão, fora da tela (tab trocada ou pane fechado) a tela do computador para de transmitir; volta ao reaparecer.
        .onDisappear { if pane != nil { controller.stop() } }
        .onChange(of: model.keyboardCaptured) { _, captured in
            guard captured else { badgeVisible = false; return }
            badgeVisible = true
            Task {
                try? await Task.sleep(for: .seconds(ViewerMetrics.badgeSeconds))
                badgeVisible = false
            }
        }
    }

    // MARK: Borda viva (04 momento 3, básico)

    private var frameColor: Color {
        if model.help != nil, model.control != .human { return DS.Color.agentNeedsInput }
        switch model.control {
        case .agent: return DS.Color.aiAccent
        case .revoking: return DS.Color.aiAccent.opacity(0.4)
        case .human: return DS.Color.textPrimary
        }
    }

    private var controlFrame: some View {
        Rectangle()
            .strokeBorder(frameColor, lineWidth: model.control == .human ? ViewerMetrics.frameStrokeStrong : ViewerMetrics.frameStroke)
            .opacity(model.help != nil && model.control != .human ? (breathing ? 1 : 0.45) : 1)
            .allowsHitTesting(false)
            .animation(MotionPolicy.shared.reduceMotion ? nil : .easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: breathing)
            .onAppear { breathing = true }
            .a11y(.viewerControlFrame(id), kind: "frame", value: model.control.rawValue)
    }

    // MARK: Estados do canvas (03 §11.4)

    @ViewBuilder
    private var stateOverlay: some View {
        switch model.connection {
        case .connecting:
            startingCard
        case .reconnecting:
            statusPill(String(localized: "Reconnecting…", bundle: .module), reconnect: false)
        case .delayed(let since):
            statusPill(String(localized: "Slow connection · last frame \(since.formatted(date: .omitted, time: .standard))", bundle: .module), reconnect: false)
        case .disconnected, .error:
            card {
                VStack(spacing: DS.Space.s3) {
                    Text(verbatim: String(localized: "Disconnected from \(id).", bundle: .module)).dsFont(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
                    DSButton(.computerReconnect, "Reconnect", variant: .outline, size: .xs)
                }
            }
            .a11y(.viewerDisconnected(id), kind: "status", label: "Disconnected")
        case .stopped:
            card { Text("This computer is stopped.", bundle: .module).dsFont(DS.Font.label).foregroundStyle(DS.Color.textPrimary) }
                .a11y(.viewerStatus(id), kind: "status", label: "This computer is stopped.")
        case .live:
            EmptyView()
        }
    }

    /// Primeira conexão: tela inteira dizendo o que acontece (computador subindo, com o progresso, ou conectando à tela).
    private var startingCard: some View {
        ViewerStartingView(model: model, name: id)
            .a11y(.viewerConnecting(id), kind: "status", label: model.isStarting ? "Starting \(id)" : "Connecting to \(id)")
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(DS.Space.s4)
            .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Color.overlayCard))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Color.border))
    }

    private func statusPill(_ text: String, reconnect: Bool) -> some View {
        HStack(spacing: DS.Space.s2) {
            DSSpinner(kind: .neutral, size: DS.Space.s3)
            Text(verbatim: text).dsFont(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
            DSButton(.computerReconnect, "Reconnect", variant: .ghost, size: .xs)
        }
        .padding(.horizontal, DS.Space.s3)
        .frame(height: ViewerMetrics.pill)
        .background(Capsule().fill(DS.Color.chrome))
        .overlay(Capsule().strokeBorder(DS.Color.border))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, DS.Space.s3)
        .a11y(.viewerStatus(id), kind: "status", label: text)
    }

    private var keyboardBadge: some View {
        HStack(spacing: DS.Space.s1_5) {
            Image(systemName: "keyboard")
            Text("Keyboard captured · ⌃⌥ to release", bundle: .module)
        }
        .dsFont(DS.Font.label)
        .foregroundStyle(DS.Color.textPrimary)
        .padding(.horizontal, DS.Space.s2_5)
        .frame(height: ViewerMetrics.pill)
        .background(Capsule().fill(DS.Color.chrome))
        .overlay(Capsule().strokeBorder(DS.Color.border))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(DS.Space.s2)
        .opacity(model.keyboardCaptured && badgeVisible ? 1 : 0)
        .allowsHitTesting(false)
        .a11y(.viewerKeyboardBadge(id), kind: "badge", label: "Keyboard captured · ⌃⌥ to release", value: model.keyboardCaptured ? "captured" : "released")
    }

    private var blockedTip: some View {
        Text(verbatim: String(localized: "\(computers.agentName(forComputer: id)) is using this computer. Take over to interact.", bundle: .module))
            .dsFont(DS.Font.label)
            .foregroundStyle(DS.Color.textPrimary)
            .padding(.horizontal, DS.Space.s3)
            .frame(height: ViewerMetrics.pill)
            .background(Capsule().fill(DS.Color.chrome))
            .overlay(Capsule().strokeBorder(DS.Color.border))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, DS.Space.s6)
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    // MARK: Banner de ajuda (03 §11.4)

    private func helpBanner(_ help: HelpSummary) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.s2) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(DS.Color.agentNeedsInputText)
                Text(verbatim: "\(controller.name) needs you · \(help.headline)")
                    .dsFont(DS.Font.label)
                    .foregroundStyle(DS.Color.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: DS.Space.s2)
                if model.control == .agent {
                    DSButton(.computerTakeOver, "Take Over", variant: .primary, size: .xs, symbol: "cursorarrow.click", argument: .select(controller.name))
                }
                DSButton(.computerDeclineHelp, id: .viewerHelpBannerDecline(id), "Decline…", variant: .ghost, size: .xs)
            }
            .padding(.horizontal, DS.Space.s3)
            .frame(height: ViewerMetrics.banner)
            if model.declineVisible { declineForm }
        }
        .background(DS.Color.agentNeedsInput.opacity(0.1))
        .overlay(alignment: .bottom) { DS.Color.agentNeedsInput.opacity(0.25).frame(height: ViewerMetrics.separator) }
        .a11y(.viewerHelpBanner(id), kind: "banner", label: help.headline)
    }

    private var declineForm: some View {
        HStack(spacing: DS.Space.s2) {
            ZStack(alignment: .leading) {
                if model.declineReason.isEmpty {
                    Text("Reason (optional)", bundle: .module).dsFont(DS.Font.inputCompact).foregroundStyle(DS.Color.textQuaternary).allowsHitTesting(false)
                }
                TextField(text: Bindable(controller.model).declineReason) { EmptyView() }
                    .textFieldStyle(.plain)
                    .dsFont(DS.Font.inputCompact)
                    .foregroundStyle(DS.Color.textPrimary)
            }
            .dsFieldChrome()
            Text("The agent will be told you declined.", bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
            DSButton(.computerDeclineHelp, "Cancel", variant: .ghost, size: .xs, argument: .select("cancel"))
            DSButton(.computerDeclineHelp, "Decline", variant: .outline, size: .xs, argument: .select("confirm"))
        }
        .padding(.horizontal, DS.Space.s3)
        .padding(.bottom, DS.Space.s2)
    }

    // MARK: Saída com o controle na mão (F28)

    /// `Hand back to <Agent>?`: o humano tentou sair do viewer com o lease. Hand Back é o padrão (Return); Esc continua no viewer.
    private var exitOverlay: some View {
        let agent = computers.agentName(forComputer: id)
        return ZStack {
            Color.black.opacity(0.35)
            VStack(alignment: .leading, spacing: DS.Space.s3) {
                Text(verbatim: String(localized: "Hand back to \(agent)?", bundle: .module)).dsFont(DS.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary)
                Text(verbatim: String(localized: "You have control of \(id). \(agent) is waiting and can't continue until you hand it back. It returns on its own after 3 minutes without input.", bundle: .module))
                    .dsFont(DS.Font.small)
                    .foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DS.Space.s2) {
                    Spacer(minLength: 0)
                    DSButton(.computerHandBack, id: .viewerExitKeep(id), "Keep control", variant: .outline, size: .sm, argument: .select("exit-keep"))
                    DSButton(.computerHandBack, id: .viewerExitHandBack(id), "Hand Back", variant: .primary, size: .sm, argument: .select("exit-handback"))
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(DS.Space.s4)
            .frame(width: ViewerMetrics.cardWidth)
            .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Color.overlayCard))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Color.border))
            .a11y(.viewerExit(id), kind: "dialog", label: String(localized: "Hand back to \(agent)?", bundle: .module))
        }
        .onExitCommand { Task { await computers.resolveExit(handBack: nil) } }
    }

    // MARK: Hand Back (03 §11.5)

    private var handBackCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            Text("Note for Claude Code (optional)", bundle: .module).dsFont(DS.Font.label).foregroundStyle(DS.Color.textSecondary)
            ZStack(alignment: .topLeading) {
                if model.handBackNote.isEmpty {
                    Text("e.g. Logged in, continue from page 3", bundle: .module)
                        .dsFont(DS.Font.inputCompact).foregroundStyle(DS.Color.textQuaternary).allowsHitTesting(false)
                }
                TextEditor(text: Bindable(controller.model).handBackNote)
                    .scrollContentBackground(.hidden)
                    .dsFont(DS.Font.inputCompact)
                    .foregroundStyle(DS.Color.textPrimary)
            }
            .frame(height: ViewerMetrics.noteHeight)
            .dsFieldChrome(height: nil)
            .a11y(.viewerHandBackNote(id), kind: "textfield", value: model.handBackNote)
            HStack(spacing: DS.Space.s2) {
                Spacer(minLength: 0)
                DSButton(.computerHandBack, "Cancel", variant: .ghost, size: .xs, argument: .select("cancel"))
                DSButton(.computerHandBack, id: .viewerHandBackConfirm(id), "Hand Back", variant: .primary, size: .xs, keycap: "⌘↵", argument: .select("confirm"))
            }
        }
        .padding(DS.Space.s3)
        .frame(width: ViewerMetrics.noteWidth)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Color.overlayCard))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Color.border))
    }
}

/// Faixa de miniaturas (03 §11.3): os outros computadores, 72 de altura; clicar troca o viewer. Oculta com um computador só.
struct ViewerStrip: View {
    let computers: ComputersController
    let current: String

    var body: some View {
        let others = computers.model.rows.filter { $0.id != current }
        if !others.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: DS.Space.s2) {
                    ForEach(others) { row in
                        ActionButton(.computerOpenViewer, argument: .select(row.id)) {
                            ComputerThumbnailView(row: row, compact: true).frame(width: ViewerMetrics.stripThumbWidth)
                        }
                        .buttonStyle(.plain)
                        .a11y(.viewerStripThumb(current, row.id), kind: "thumbnail", label: row.id)
                    }
                }
                .padding(.horizontal, DS.Space.s3)
            }
            .frame(height: ViewerMetrics.strip)
            .background(DS.Color.canvas)
            .overlay(alignment: .bottom) { DS.Color.border.frame(height: ViewerMetrics.separator) }
            .a11y(.viewerStrip(current), kind: "container")
        }
    }
}

/// Header de 32 (03 §11.2): nome, tipo, URL, pill de controle, Take Over / Hand Back, janela própria.
/// O que o viewer precisa quando é um pane de sessão: arrastar, fechar e o nome do subagente.
struct ViewerPane {
    let id: UUID
    let drag: PaneDragController
    let title: String
    let close: () -> Void
}

struct ViewerHeader: View {
    let controller: ComputerViewerController
    var backTitle: String?
    var pane: ViewerPane? = nil
    /// Dentro das sub-tabs da sessão: sem fundo nem altura próprios e sem nome/tipo (a sub-tab já diz qual computador é).
    var embedded = false
    private var model: ComputerViewerModel { controller.model }
    private var id: String { controller.name }

    var body: some View {
        if embedded {
            HStack(spacing: DS.Space.s2) { trailing }
        } else {
            HStack(spacing: DS.Space.s2) {
                if let backTitle {
                    DSButton(.pageClose, id: .viewerBack(id), "Back to \(backTitle)", variant: .ghost, size: .xs, symbol: "arrow.left")
                }
                HStack(spacing: DS.Space.s2) {
                    Image(systemName: "display").foregroundStyle(DS.Color.textSecondary)
                    Text(verbatim: pane?.title ?? controller.name).dsFont(DS.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                        .a11y(.viewerName(id), kind: "text", label: controller.name)
                }
                .overlay {
                    if let pane { PaneDragSource(controller: pane.drag, payload: .otherPane(pane.id), title: { pane.title }) }
                }
                Text(verbatim: modeLabel).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                    .a11y(.viewerMode(id), kind: "text", label: modeLabel)
                Spacer(minLength: DS.Space.s2)
                trailing
                if let pane {
                    // lint-ui: allow buttons fecha o pane da tela (layout do workspace, sem ação de registro própria)
                    Button(action: pane.close) { Image(systemName: "xmark") }
                        .buttonStyle(DSIconButtonStyle(.header))
                        .dsTooltip(String(localized: "Close", bundle: .module), shortcut: nil)
                }
            }
            .padding(.horizontal, DS.Space.s3)
            .frame(height: ViewerMetrics.header)
            .background(DS.Color.chrome)
            .overlay(alignment: .bottom) { DS.Color.border.frame(height: ViewerMetrics.separator) }
        }
    }

    /// Barra de endereço do navegador do computador (só leitura): cadeado/globo + host e caminho, truncado no meio.
    @ViewBuilder private var addressBar: some View {
        if let url = model.snapshot?.url, !url.isEmpty {
            let secure = url.hasPrefix("https://")
            let shown = url.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
            HStack(spacing: DS.Space.s1_5) {
                Image(systemName: secure ? "lock.fill" : "globe").font(.system(size: ViewerMetrics.addressIcon)).foregroundStyle(DS.Color.textTertiary)
                Text(verbatim: shown).dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary).lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, DS.Space.s2_5)
            .frame(minWidth: ViewerMetrics.addressMinWidth, idealWidth: ViewerMetrics.addressMaxWidth, maxWidth: ViewerMetrics.addressMaxWidth,
                   minHeight: ViewerMetrics.pill, maxHeight: ViewerMetrics.pill, alignment: .leading)
            .layoutPriority(1)
            .background(Capsule().fill(DS.Color.canvas))
            .overlay(Capsule().strokeBorder(DS.Color.border))
            .help(url)
            .a11y(.viewerUrl(id), kind: "text", value: url)
        }
    }

    @ViewBuilder private var trailing: some View {
            addressBar
            Spacer(minLength: DS.Space.s2)
            ControlPill(model: model, id: id, agent: model.agentName)
            controls
            ActionButton(.computerPaste, tooltip: String(localized: "Paste to Computer", bundle: .module)) { Image(systemName: "doc.on.clipboard") }
                .buttonStyle(DSIconButtonStyle(.header))
            ActionButton(.computerCopySelection, tooltip: String(localized: "Copy Selection from Computer", bundle: .module)) { Image(systemName: "doc.on.doc") }
                .buttonStyle(DSIconButtonStyle(.header))
            ActionButton(.computerPopOut, id: .viewerPopOut(id), tooltip: String(localized: "Open in New Window", bundle: .module)) {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(DSIconButtonStyle(.header))
    }

    private var modeLabel: String {
        switch model.snapshot?.display {
        case "desktop": String(localized: "Desktop", bundle: .module)
        case "http": String(localized: "HTTP", bundle: .module)
        default: String(localized: "Headless", bundle: .module)
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch model.control {
        case .agent:
            DSButton(.computerTakeOver, id: .viewerTakeOver(id), "Take Over", variant: .primary, size: .xs, symbol: "cursorarrow.click", keycap: "⇧⌘R", argument: .select(controller.name))
        case .revoking:
            DSButton(
                .computerTakeOver, id: .viewerTakeOver(id), "Take Over", variant: .primary, size: .xs, loading: "Requesting control…", argument: .select(controller.name))
            if model.forceAvailable {
                DSButton(.computerForceTakeOver, id: .viewerForceTakeOver(id), "Force Take Over", variant: .destructive, size: .xs, argument: .select(controller.name))
            }
        case .human:
            DSButton(.computerHandBack, id: .viewerHandBack(id), "Hand Back", variant: .primary, size: .xs, symbol: "hand.raised", keycap: "⇧⌘R")
        }
    }
}

/// Pill de controle (03 §11.2): agente usando, humano no controle, pedido de ajuda, ocioso.
struct ControlPill: View {
    let model: ComputerViewerModel
    let id: String
    /// Agente pai (`Claude`, `Codex`, `OpenCode`).
    var agent = "Claude"

    var body: some View {
        HStack(spacing: DS.Space.s1_5) {
            if model.control == .agent, model.help == nil, model.connection != .stopped { DSSpinner(kind: .neutral, size: DS.Space.s3) }
            Text(verbatim: text).dsFont(DS.Font.label).foregroundStyle(foreground).lineLimit(1)
        }
        .padding(.horizontal, DS.Space.s2_5)
        .frame(height: ViewerMetrics.pill)
        .background(Capsule().fill(background))
        .a11y(.viewerControlPill(id), kind: "status", label: text, value: model.control.rawValue)
    }

    private var text: String {
        if model.control == .human { return String(localized: "You're in control", bundle: .module) }
        if model.control == .revoking { return String(localized: "Requesting control…", bundle: .module) }
        if model.help != nil { return String(localized: "Needs You", bundle: .module) }
        if model.connection == .stopped { return String(localized: "Idle", bundle: .module) }
        return String(localized: "\(agent) is using", bundle: .module)
    }

    private var foreground: Color {
        if model.control == .human { return DS.Color.textPrimary }
        if model.help != nil { return DS.Color.agentNeedsInputText }
        return DS.Color.aiAccent
    }

    private var background: Color {
        if model.control == .human { return DS.Color.fg10 }
        if model.help != nil { return DS.Color.agentNeedsInput.opacity(0.15) }
        return DS.Color.aiAccent.opacity(0.15)
    }
}

/// Computador subindo ou conectando: monitor com varredura de luz, título, passo atual com barra de progresso e a tarefa do
/// subagente. Substitui a tela preta com um card pequeno.
struct ViewerStartingView: View {
    let model: ComputerViewerModel
    let name: String
    @State private var sweep = false

    private var reduceMotion: Bool { MotionPolicy.shared.reduceMotion }

    /// `Building computer image… 5 of 17` -> 5/17.
    private var fraction: Double? {
        guard model.isStarting, let detail = model.snapshot?.detail,
              let match = detail.firstMatch(of: /(\d+) of (\d+)/), let n = Double(match.1), let total = Double(match.2), total > 0 else { return nil }
        return min(max(n / total, 0), 1)
    }

    private var title: String {
        model.isStarting ? String(localized: "Starting \(name)", bundle: .module) : String(localized: "Connecting to \(name)", bundle: .module)
    }

    private var step: String {
        if model.isStarting {
            if let q = model.snapshot?.queuePosition { return String(localized: "Waiting in line · position \(q)", bundle: .module) }
            return model.snapshot?.detail ?? String(localized: "Booting the browser…", bundle: .module)
        }
        return String(localized: "Opening the live screen…", bundle: .module)
    }

    var body: some View {
        VStack(spacing: DS.Space.s4) {
            monitor
            VStack(spacing: DS.Space.s1_5) {
                Text(verbatim: title).dsFont(DS.Font.dialogTitle).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                Text(verbatim: step).dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary).lineLimit(1)
            }
            progress
            if let doing = model.snapshot?.lastDoing, !doing.isEmpty {
                HStack(spacing: DS.Space.s1_5) {
                    DSAgentLogo(DSAgentKind.claude, size: DS.Space.s3)
                    Text(verbatim: doing).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).lineLimit(1).truncationMode(.tail)
                }
                .frame(maxWidth: ViewerMetrics.startWidth)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RadialGradient(colors: [DS.Color.aiAccent.opacity(0.08), Color.clear], center: .center, startRadius: 0, endRadius: ViewerMetrics.startWidth * 1.4)
        )
        .onAppear { sweep = true }
    }

    private var monitor: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: DS.Radius.card)
                .fill(DS.Color.chrome)
                .overlay(
                    GeometryReader { geo in
                        LinearGradient(colors: [Color.clear, DS.Color.aiAccent.opacity(0.35), Color.clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * ViewerMetrics.sweepFraction)
                            .offset(x: sweep && !reduceMotion ? geo.size.width : -geo.size.width * ViewerMetrics.sweepFraction)
                            .animation(reduceMotion ? nil : .easeInOut(duration: 1.6).repeatForever(autoreverses: false), value: sweep)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
                )
                .overlay(Image(systemName: "globe").font(.system(size: DS.Space.s6)).foregroundStyle(DS.Color.textTertiary))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Color.aiAccent.opacity(0.5)))
                .frame(width: ViewerMetrics.monitorWidth, height: ViewerMetrics.monitorHeight)
            Rectangle().fill(DS.Color.border).frame(width: DS.Space.s1, height: DS.Space.s2)
            Capsule().fill(DS.Color.border).frame(width: ViewerMetrics.monitorStand, height: DS.Space.s1)
        }
    }

    private var progress: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(DS.Color.fg10)
                if let fraction {
                    Capsule().fill(DS.Color.aiAccent).frame(width: max(geo.size.width * fraction, ViewerMetrics.progressHeight))
                        .animation(.easeOut(duration: 0.4), value: fraction)
                } else {
                    Capsule().fill(DS.Color.aiAccent)
                        .frame(width: geo.size.width * ViewerMetrics.indeterminateFraction)
                        .offset(x: sweep && !reduceMotion ? geo.size.width * (1 - ViewerMetrics.indeterminateFraction) : 0)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: sweep)
                }
            }
        }
        .frame(width: ViewerMetrics.progressWidth, height: ViewerMetrics.progressHeight)
    }
}

/// Pane de um computador que não existe mais (encerrado e limpo depois que a sessão o usou).
struct GoneComputerPane: View {
    let name: String
    let close: () -> Void
    /// Volta ao terminal do agente da sessão (quem criou o computador), quando há um.
    var showAgent: (() -> Void)? = nil
    /// Abre no Finder a pasta das execuções (screenshots e logs dos computadores).
    var showRuns: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: DS.Space.s3) {
            Image(systemName: "desktopcomputer.trianglebadge.exclamationmark").font(.system(size: DS.Space.s8)).foregroundStyle(DS.Color.textQuaternary)
            Text(verbatim: String(localized: "\(name) is no longer running", bundle: .module)).dsFont(DS.Font.composerTitle).foregroundStyle(DS.Color.textPrimary)
            Text("The subagent's computer was stopped and cleaned up. Its screenshots and logs stay in the session's run folder.", bundle: .module)
                .dsFont(DS.Font.body).foregroundStyle(DS.Color.textSecondary).multilineTextAlignment(.center).frame(maxWidth: DataMetrics.emptyTextWidth)
            HStack(spacing: DS.Space.s2) {
                if let showAgent {
                    // lint-ui: allow buttons mostra o terminal do agente da sessão (layout do workspace, sem ação de registro própria)
                    Button(action: showAgent) { Text("Go to Agent", bundle: .module) }
                        .buttonStyle(DSButtonStyle(.primary, .sm))
                }
                if let showRuns {
                    // lint-ui: allow buttons abre a pasta das execuções no Finder (sem ação de registro própria)
                    Button(action: showRuns) { Text("Show Screenshots and Logs", bundle: .module) }
                        .buttonStyle(DSButtonStyle(showAgent == nil ? .primary : .outline, .sm))
                        .help(Text("Opens the run folder in Finder", bundle: .module))
                }
                // lint-ui: allow buttons fecha o pane deste computador (layout do workspace, sem ação de registro própria)
                Button(action: close) { Text("Close Tab", bundle: .module) }
                    .buttonStyle(DSButtonStyle(.outline, .sm))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Color.canvas)
    }
}
