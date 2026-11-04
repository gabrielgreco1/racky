import RackyCore
import RackyDesignSystem
import RackyProtocol
import AppKit
import Observation
import SwiftUI

// Linhas dos subagentes sob o agente pai no card da sessão (hooks SubagentStart/SubagentStop, com ou sem computador) e o hover card com a
// pré-visualização do computador (07 CS-403, T3-05). Compacto e calmo: spinner amarelo enquanto roda, título em negrito, tempo à direita.

extension EnvironmentValues {
    /// Hover card do computador de um subagente; ligado pelo `AppEnvironment`.
    @Entry var subagentHoverCards: SubagentHoverCardController?
    /// F28: a sidebar lê quem tem o controle de cada computador e devolve o controle sem abrir o viewer.
    @Entry var computersController: ComputersController?
}

/// F28: `You have control` + `Hand Back` na linha do subagente e no card da sessão, sem abrir o viewer.
struct HumanControlLine: View {
    let computer: String
    let controlID: A11yID
    let handBackID: A11yID
    @Environment(\.computersController) private var computers

    static func isHuman(_ computer: String?, _ controller: ComputersController?) -> Bool {
        guard let computer, let controller else { return false }
        return controller.model.rows.first { $0.id == computer }?.snapshot.control == .human
    }

    var body: some View {
        HStack(spacing: DS.Space.s1_5) {
            Image(systemName: "hand.raised.fill").font(.system(size: SidebarMetrics.line2Icon)).foregroundStyle(DS.Color.aiAccent)
            Text("You have control", bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textPrimary.opacity(0.9)).lineLimit(1)
                .a11y(controlID, kind: "text", label: String(localized: "You have control", bundle: .module), value: computer)
            Spacer(minLength: DS.Space.s1)
            DSButton(.computerHandBack, id: handBackID, "Hand Back", variant: .outline, size: .xs, argument: .select("now:\(computer)"))
        }
        .padding(.horizontal, SidebarMetrics.agentRowPaddingH)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum SubagentCardMetrics {
    static let width: CGFloat = 320
    static let height: CGFloat = 200
    static let previewHeight: CGFloat = 138
    static let margin = DS.Space.s6
    static let gap = DS.Space.s2
    static let showDelay: TimeInterval = 0.35
    static let hideDelay: TimeInterval = 0.25
    static let radius = DS.Radius.card
}

// MARK: Linha do subagente

/// v6 (03/11): uma linha limpa por subagente (setinha, logo da AI, nome, estado e tempo). A setinha abre ali mesmo o computador dele
/// (miniatura pequena, ao vivo ou desligado) e as tabelas que ele gravou; o clique na linha abre a aba do subagente no centro.
struct SubagentRowView: View {
    let model: SidebarModel
    let sessionID: UUID
    let terminalID: UUID
    /// CLI do agente pai: um subagente comum roda no mesmo CLI; um worker de app tem o dele (`child.worker`).
    let provider: TerminalProvider
    let child: SubagentRowData
    /// Tabelas gravadas pelo computador deste subagente.
    var tables: [SessionDatasetRow] = []
    @Environment(\.actionRegistry) private var registry
    @Environment(\.subagentHoverCards) private var hoverCards
    @Environment(\.computersController) private var computers
    @State private var hovering = false

    private var expandable: Bool { child.computer != nil || !tables.isEmpty }
    private var expanded: Bool { expandable && model.expandedSubagents.contains(SidebarModel.subagentKey(terminal: terminalID, child: child.id)) }

    var body: some View {
        let sid = sessionID.uuidString, cid = child.id
        VStack(alignment: .leading, spacing: 0) {
            rowBody(sid: sid, cid: cid)
            if HumanControlLine.isHuman(child.computer, computers), let computer = child.computer {
                HumanControlLine(computer: computer, controlID: .sidebarSessionChildControl(sid, cid), handBackID: .sidebarSessionChildHandBack(sid, cid))
                    .transition(.opacity)
            }
            if expanded {
                details(sid: sid, cid: cid)
                    .transition(MotionPolicy.shared.reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -DS.Space.s1)))
            }
        }
        .animation(MotionPolicy.shared.animation(MotionTokens.Springs.snappy), value: expanded)
    }

    private var logo: DSAgentKind { QuickLaunchModel.kind(child.worker ?? provider) }

    @ViewBuilder
    private func rowBody(sid: String, cid: String) -> some View {
        TimelineView(.periodic(from: .now, by: SubagentMetrics.elapsedTick)) { context in
            let screen = child.computer.flatMap { name in computers?.model.rows.first { $0.id == name } }
            let needsYou = screen?.needsYou == true
            let line = HStack(spacing: SidebarMetrics.agentRowGap + DS.Space.s0_5) {
                DSAgentLogo(logo, size: SidebarMetrics.agentLogo, dimmed: child.phase == .done)
                Text(verbatim: child.title)
                    .dsFont(DS.Font.sidebarMeta)
                    .foregroundStyle(child.phase == .done ? DS.Color.textTertiary : DS.Color.textPrimary.opacity(0.88))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .a11y(.sidebarSessionChildTitle(sid, cid), kind: "text", label: child.title)
                if let task = child.task {
                    Text(verbatim: task)
                        .dsFont(DS.Font.sidebarMeta)
                        .foregroundStyle(DS.Color.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: DS.Space.s1)
                if let pr = child.pullRequest {
                    // O PR que o subagente abriu: um clique abre no navegador.
                    ActionButton(
                        .subagentOpenPR, id: .sidebarSessionChildPr(sid, cid), argument: .select(pr.absoluteString),
                        tooltip: String(localized: "Open the pull request on GitHub", bundle: .module)
                    ) {
                        Text(verbatim: SubagentInfo.pullRequestLabel(pr))
                            .dsFont(DS.Font.sidebarMetaNumeric)
                            .foregroundStyle(DS.Color.textSecondary)
                            .fixedSize()
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                DSAgentIndicator(needsYou ? .needsInput : child.glyph, size: .sm)
                    .a11y(.sidebarSessionChildStatus(sid, cid), kind: "image", label: needsYou ? String(localized: "Needs You", bundle: .module) : child.stateLabel)
                Text(verbatim: child.elapsedText(now: context.date))
                    .dsFont(DS.Font.sidebarMetaNumeric)
                    .foregroundStyle(DS.Color.textTertiary)
                    .fixedSize()
                    .a11y(.sidebarSessionChildElapsed(sid, cid), kind: "text", label: child.elapsedText(now: context.date))
            }
            .padding(.trailing, SidebarMetrics.agentRowPaddingH)
            .frame(height: SidebarMetrics.agentRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background { SubagentHoverTracker(child: child, sessionID: sessionID, controller: hoverCards, hovering: $hovering) }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(verbatim: "\(child.title)\(child.task.map { ", \($0)" } ?? ""), \(child.stateLabel), \(child.elapsedText(now: context.date))"))
            HStack(spacing: 0) {
                disclosure(sid: sid, cid: cid)
                Group {
                    if let workerTerminal = child.workerTerminalID, let registry, registry.isOffered(.paneShow) {
                        // Worker de app: o clique leva ao pane dele (a sessão separada ao lado do agente).
                        ActionButton(.paneShow, id: .sidebarSessionChild(sid, cid), argument: .select(workerTerminal.uuidString)) { line }
                            .buttonStyle(.plain)
                    } else if let computer = child.computer, let registry, registry.isOffered(.computerOpenViewer) {
                        // A aba do subagente: a tela do computador dele com o que ele entregou ao lado.
                        ActionButton(.computerOpenViewer, id: .sidebarSessionChild(sid, cid), argument: .select(computer)) { line }
                            .buttonStyle(.plain)
                    } else if let registry, registry.isOffered(.paneShow) {
                        ActionButton(.paneShow, id: .sidebarSessionChild(sid, cid), argument: .select(terminalID.uuidString)) { line }
                            .buttonStyle(.plain)
                    } else {
                        line.a11y(.sidebarSessionChild(sid, cid), kind: "row", label: child.title)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: SidebarMetrics.agentRowRadius).fill(hovering ? DS.Color.hoverAgentRow : Color.clear))
        }
        .animation(MotionPolicy.shared.animation(MotionTokens.Easing.ease, MotionTokens.Duration.hover), value: hovering)
        .transition(MotionPolicy.shared.reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -DS.Space.s1)))
    }

    /// Setinha que abre o computador e as tabelas na barra; sem nada para mostrar, só o espaço (as linhas ficam alinhadas).
    @ViewBuilder
    private func disclosure(sid: String, cid: String) -> some View {
        if expandable {
            ActionButton(
                .subagentToggleDetails, id: .sidebarSessionChildToggle(sid, cid), argument: .select("\(terminalID.uuidString)/\(child.id)"),
                tooltip: expanded ? String(localized: "Hide computer and data", bundle: .module) : String(localized: "Show computer and data", bundle: .module)
            ) {
                Image(systemName: "chevron.right")
                    .font(.system(size: SidebarMetrics.chevron - DS.Space.s0_5, weight: .medium))
                    .foregroundStyle(DS.Color.textTertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: SubagentMetrics.toggleBox, height: SidebarMetrics.agentRowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(Text(verbatim: expanded ? "expanded" : "collapsed"))
        } else {
            Color.clear.frame(width: SubagentMetrics.toggleBox, height: SidebarMetrics.agentRowHeight)
        }
    }

    /// O que abre embaixo da linha: o computador (miniatura pequena e se está ao vivo) e as tabelas que ele gravou.
    @ViewBuilder
    private func details(sid: String, cid: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let name = child.computer {
                let row = computers?.model.rows.first { $0.id == name }
                let line = HStack(spacing: SidebarMetrics.agentRowGap + DS.Space.s0_5) {
                    if let row, row.snapshot.display != "http", row.snapshot.state.isLive {
                        SidebarComputerThumb(data: row.thumbnail, needsYou: row.needsYou)
                    } else {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: SidebarMetrics.line2Icon + DS.Space.s0_5))
                            .foregroundStyle(DS.Color.textQuaternary)
                            .frame(width: SidebarMetrics.agentLogo)
                    }
                    Text(verbatim: name).dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: DS.Space.s1)
                    Text(verbatim: Self.computerState(row))
                        .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).lineLimit(1).fixedSize()
                }
                .padding(.horizontal, SidebarMetrics.agentRowPaddingH)
                .frame(height: row?.snapshot.state.isLive == true && row?.snapshot.display != "http" ? SubagentMetrics.thumbRowHeight : SidebarMetrics.agentRowHeight)
                .contentShape(Rectangle())
                if let registry, registry.isOffered(.computerOpenViewer) {
                    ActionButton(.computerOpenViewer, id: .sidebarSessionChildComputer(sid, cid), argument: .select(name)) { line }
                        .buttonStyle(.plain)
                } else {
                    line.a11y(.sidebarSessionChildComputer(sid, cid), kind: "row", label: name)
                }
            }
            ForEach(tables) { table in
                SessionDatasetRowView(sessionID: sessionID, row: table, id: .sidebarSessionChildDataset(sid, cid, table.id), stripPrefix: child.computer)
            }
        }
        .padding(.leading, SubagentMetrics.toggleBox + SidebarMetrics.agentLogo + SidebarMetrics.agentRowGap - SidebarMetrics.agentRowPaddingH)
        .padding(.bottom, DS.Space.s1)
    }

    /// `ao vivo`, `sem tela`, `desligado`: o que a linha do computador diz à direita.
    static func computerState(_ row: ComputerRow?) -> String {
        guard let row else { return String(localized: "Off", bundle: .module) }
        if row.snapshot.control == .human { return String(localized: "You have control", bundle: .module) }
        guard row.snapshot.state.isLive else { return String(localized: "Off", bundle: .module) }
        return row.snapshot.display == "http" ? String(localized: "No screen", bundle: .module) : String(localized: "Live", bundle: .module)
    }
}

/// Rastreia o ponteiro sobre a linha (sem interceptar cliques) e avisa o hover card, com o frame da linha em coordenadas de tela.
private struct SubagentHoverTracker: NSViewRepresentable {
    let child: SubagentRowData
    let sessionID: UUID
    let controller: SubagentHoverCardController?
    @Binding var hovering: Bool

    func makeNSView(context: Context) -> TrackerView { TrackerView() }

    func updateNSView(_ view: TrackerView, context: Context) {
        view.computer = child.computer
        view.sessionID = sessionID
        view.childID = child.id
        view.controller = controller
        view.onHover = { value in DispatchQueue.main.async { hovering = value } }
    }

    final class TrackerView: NSView {
        var computer: String?
        var sessionID = UUID()
        var childID = ""
        weak var controller: SubagentHoverCardController?
        var onHover: (Bool) -> Void = { _ in }
        private var area: NSTrackingArea?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let new = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
            addTrackingArea(new)
            area = new
        }

        override func mouseEntered(with event: NSEvent) {
            onHover(true)
            guard let computer, let window else { return }
            let frame = window.convertToScreen(convert(bounds, to: nil))
            MainActor.assumeIsolated { controller?.rowEntered(computer: computer, session: sessionID, child: childID, anchor: frame, window: window) }
        }

        override func mouseExited(with event: NSEvent) {
            onHover(false)
            MainActor.assumeIsolated { controller?.rowExited(computer: computer) }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { MainActor.assumeIsolated { controller?.rowExited(computer: computer) } }
            super.viewWillMove(toWindow: newWindow)
        }
    }
}

// MARK: Hover card

/// Painel flutuante (~320×200) ao lado da linha: pré-visualização do computador em baixa taxa (a miniatura de ≤ 1 fps do T3-05), nome,
/// URL e a última linha do diário. Abre depois de um instante, fica enquanto o ponteiro está na linha ou no card, e fecha parando o fluxo.
@MainActor
final class SubagentHoverCardController {
    private let computers: ComputersController
    private weak var registry: ActionRegistry?
    private let elements: UIElementStore
    private var panel: NSPanel?
    private var showTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private(set) var shownComputer: String?
    private var overCard = false
    private let state = SubagentHoverCardState()

    init(computers: ComputersController, registry: ActionRegistry, elements: UIElementStore) {
        self.computers = computers
        self.registry = registry
        self.elements = elements
    }

    func rowEntered(computer: String, session: UUID, child: String, anchor: NSRect, window: NSWindow) {
        hideTask?.cancel()
        if shownComputer == computer { return }
        showTask?.cancel()
        showTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(SubagentCardMetrics.showDelay))
            guard !Task.isCancelled, let self else { return }
            self.show(computer: computer, session: session, child: child, anchor: anchor, window: window)
        }
    }

    /// `computer.showPreview` (automação e teclado): abre o card ao lado da linha do subagente que tem esse computador, sem ponteiro.
    func present(computer: String, window: NSWindow?) -> Bool {
        guard let sid = computers.model.sessionIDs[computer],
              let child = computers.model.agentComputers.first(where: { $0.value == computer })?.key,
              let frame = elements.frame(of: .sidebarSessionChild(sid.uuidString, child)), let window else { return false }
        // `frame` vem do topo-esquerdo da janela; o painel usa coordenadas de tela (origem embaixo).
        let content = window.contentView?.bounds.height ?? window.frame.height
        let local = NSRect(x: frame.minX, y: content - frame.maxY, width: frame.width, height: frame.height)
        let screen = window.convertToScreen(window.contentView?.convert(local, to: nil) ?? local)
        hideTask?.cancel()
        show(computer: computer, session: sid, child: child, anchor: screen, window: window)
        return true
    }

    func rowExited(computer: String?) {
        showTask?.cancel()
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(SubagentCardMetrics.hideDelay))
            guard !Task.isCancelled, let self, !self.overCard else { return }
            self.hide()
        }
    }

    func cardHover(_ over: Bool) {
        overCard = over
        if over { hideTask?.cancel() } else { scheduleHide() }
    }

    /// Clique no card ou na pré-visualização: abre o viewer (com Take Over) e fecha o card.
    func opened() { hide() }

    private func show(computer: String, session: UUID, child: String, anchor: NSRect, window: NSWindow) {
        guard computers.model.computer(named: computer) != nil else { return }
        state.computer = computer
        state.session = session
        state.child = child
        let panel = ensurePanel()
        (panel.contentView as? NSHostingView<AnyView>)?.rootView = content()
        let size = NSSize(width: SubagentCardMetrics.width, height: SubagentCardMetrics.height)
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var x = anchor.maxX + SubagentCardMetrics.gap
        x = min(x, screen.maxX - size.width - SubagentCardMetrics.gap)
        var y = anchor.maxY - size.height
        y = min(max(y, screen.minY + SubagentCardMetrics.gap), screen.maxY - size.height - SubagentCardMetrics.gap)
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
        if panel.parent !== window { window.addChildWindow(panel, ordered: .above) }
        panel.alphaValue = 0
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = MotionTokens.Duration.fast
            panel.animator().alphaValue = 1
        }
        shownComputer = computer
        computers.setHoverPreview(open: true)  // o fluxo da pré-visualização só roda com o card aberto
    }

    func hide() {
        showTask?.cancel()
        hideTask?.cancel()
        overCard = false
        guard let panel, shownComputer != nil else { return }
        shownComputer = nil
        computers.setHoverPreview(open: false)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = MotionTokens.Duration.fast
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in
            MainActor.assumeIsolated {
                guard let panel, panel.alphaValue == 0 else { return }
                panel.parent?.removeChildWindow(panel)
                panel.orderOut(nil)
            }
        })
    }

    private func content() -> AnyView {
        guard let registry else { return AnyView(EmptyView()) }
        return AnyView(
            SubagentHoverCardView(model: computers.model, state: state, controller: self)
                .environment(\.actionRegistry, registry).environment(\.elementStore, elements).environment(\.a11yParent, .windowMain))
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = ChromeHostingView(content: EmptyView())
        self.panel = panel
        return panel
    }
}

@MainActor
@Observable
final class SubagentHoverCardState {
    var computer = ""
    var session = UUID()
    var child = ""
}

struct SubagentHoverCardView: View {
    let model: ComputersModel
    let state: SubagentHoverCardState
    let controller: SubagentHoverCardController

    private var row: ComputerRow? { model.rows.first { $0.id == state.computer } }

    var body: some View {
        let sid = state.session.uuidString, cid = state.child
        VStack(alignment: .leading, spacing: 0) {
            ActionButton(.computerOpenViewer, id: .sidebarSessionChildPreview(sid, cid), argument: .select(state.computer)) {
                preview
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded { controller.opened() })
            VStack(alignment: .leading, spacing: DS.Space.s0_5) {
                HStack(spacing: DS.Space.s1_5) {
                    Text(verbatim: state.computer)
                        .dsFont(DS.Font.bodyStrong)
                        .foregroundStyle(DS.Color.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: DS.Space.s1)
                    if let snapshot = row?.snapshot {
                        Text(verbatim: snapshot.control == .human ? String(localized: "You're in control", bundle: .module) : snapshot.state.rawValue.replacingOccurrences(of: "_", with: " "))
                            .dsFont(DS.Font.microNumeric)
                            .foregroundStyle(DS.Color.textTertiary)
                    }
                }
                Text(verbatim: row?.snapshot.url ?? String(localized: "No page yet", bundle: .module))
                    .dsFont(DS.Font.monoMicro)
                    .foregroundStyle(DS.Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let doing = row?.snapshot.lastDoing {
                    Text(verbatim: doing)
                        .dsFont(DS.Font.small)
                        .foregroundStyle(DS.Color.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, DS.Space.s3)
            .padding(.vertical, DS.Space.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: SubagentCardMetrics.width, height: SubagentCardMetrics.height, alignment: .top)
        .background(RoundedRectangle(cornerRadius: SubagentCardMetrics.radius).fill(DS.Color.menuSolid))
        .clipShape(RoundedRectangle(cornerRadius: SubagentCardMetrics.radius))
        .overlay(RoundedRectangle(cornerRadius: SubagentCardMetrics.radius).strokeBorder(DS.Color.border, lineWidth: DSMetrics.hairline))
        .dsShadow(DS.Shadow.floating)
        .onHover { controller.cardHover($0) }
        .a11y(.sidebarSessionChildHoverCard(sid, cid), kind: "container", label: state.computer)
    }

    @ViewBuilder private var preview: some View {
        ZStack {
            DS.Color.terminalBackground
            if let data = row?.thumbnail, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .transition(.opacity)
            } else {
                VStack(spacing: DS.Space.s1_5) {
                    DSSpinner(size: SidebarMetrics.pendingSpinner)
                    Text(verbatim: row?.snapshot.display == "http" ? String(localized: "HTTP computer · no screen", bundle: .module) : String(localized: "Waiting for the first frame…", bundle: .module))
                        .dsFont(DS.Font.small)
                        .foregroundStyle(DS.Color.textTertiary)
                }
            }
        }
        .frame(width: SubagentCardMetrics.width, height: SubagentCardMetrics.previewHeight)
        .clipped()
        .animation(MotionPolicy.shared.animation(MotionTokens.Easing.ease, MotionTokens.Duration.fast), value: row?.thumbnail)
    }
}

extension BoxState {
    /// O computador está ligado (a tela pode mostrar algo); `queued`/`provisioning` ainda não, `stopped`/`failed` já não.
    var isLive: Bool { self == .ready || self == .inUse }
}
