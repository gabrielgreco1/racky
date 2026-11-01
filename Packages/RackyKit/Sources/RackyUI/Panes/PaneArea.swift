import RackyCore
import RackyDesignSystem
import RackyProtocol
import AppKit
import SwiftUI

/// Liga uma view AppKit à árvore de automação (`ctl ui tree`): o `UIElementStore` só vê o que passa por `.a11y(...)` do SwiftUI.
@MainActor
final class ElementRegistration {
    private let token = UUID()
    private weak var store: UIElementStore?

    init(store: UIElementStore?, id: A11yID, kind: String, label: String?, parent: A11yID?) {
        self.store = store
        store?.register(token, id: id, kind: kind, label: label, value: nil, action: nil, parent: parent)
    }

    /// `view` em coordenadas da janela, com o y do topo (o mesmo espaço dos frames do SwiftUI).
    func updateFrame(of view: NSView) {
        guard let window = view.window, let content = window.contentView else { return }
        let rect = view.convert(view.bounds, to: nil)
        let top = content.bounds.height - rect.maxY
        store?.updateFrame(token, CGRect(x: rect.minX, y: top, width: rect.width, height: rect.height))
    }

    /// Retângulo `rect` (espaço de `view`) em coordenadas da janela com o y do topo.
    func updateFrame(of rect: CGRect, in view: NSView) {
        guard let window = view.window, let content = window.contentView else { return }
        let r = view.convert(rect, to: nil)
        store?.updateFrame(token, CGRect(x: r.minX, y: content.bounds.height - r.maxY, width: r.width, height: r.height))
    }

    func remove() { store?.unregister(token) }
}

/// Pane: a `TerminalHostView` com o chrome SwiftUI por cima (cabeçalho de 24, botões, banners). A view do terminal nunca
/// anima o próprio frame; só a opacidade (pane inativo a 0,8, M-308).
@MainActor
final class PaneContainerView: NSView {
    let terminalID: UUID
    let entry: TerminalEntry
    let chrome = PaneChromeModel()
    private enum Chrome: CaseIterable { case header, floating, banner, card, ignition }
    /// Views SwiftUI do chrome: só existem enquanto aparecem (uma hosting view criada já registra seus controles).
    private var hosts: [Chrome: NSHostingView<AnyView>] = [:]
    private let registry: ActionRegistry?
    private let elementStore: UIElementStore?
    private let dim = NSView()
    /// `PaneCover` (M-504/M-506): cor do canvas do terminal sobre a view até o primeiro byte, para o terminal nunca piscar vazio.
    private let cover = NSView()
    private var coverFading = false
    private var tracking: NSTrackingArea?
    private var registrations: [ElementRegistration] = []
    private let elements: UIElementStore?
    private(set) var showsHeader = false
    /// Bordas de atenção e de localizar (M-310, M-309): camadas sobre o terminal que não recebem clique.
    private let rim = PaneRimView()
    private var rimRegistration: ElementRegistration?
    /// Último `rimFlash.nonce` já exibido neste pane.
    var lastFlashNonce = 0

    override var isFlipped: Bool { true }

    init(entry: TerminalEntry, registry: ActionRegistry?, elements: UIElementStore?, drag: PaneDragController? = nil) {
        terminalID = entry.terminalID
        self.entry = entry
        self.elements = elements
        self.registry = registry
        elementStore = elements
        super.init(frame: .zero)
        chrome.onFloatingResize = { [weak self] _ in self?.needsLayout = true }
        chrome.terminalID = entry.terminalID
        chrome.drag = drag
        wantsLayer = true
        layer?.masksToBounds = true
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(MotionTokens.Opacity.exitedDim).cgColor
        cover.wantsLayer = true
        cover.layer?.backgroundColor = DS.ColorSpec.terminalBackground.nsColor.cgColor
        addSubview(entry.host)
        addSubview(rim)
        updateTracking()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }  // required init?(coder:) não usado

    /// Só o pane visível aparece em `ctl ui tree`: os das outras tabs e sessões saem da árvore.
    func setTreeVisible(_ visible: Bool) {
        if !visible {
            teardown()
            // O chrome SwiftUI (cabeçalho, botões, banner, cartão) sai da hierarquia enquanto o pane está escondido: escondido ele
            // continuava observando o modelo e refazendo layout a cada mudança, para os panes de todas as sessões abertas.
            for h in hosts.values where h.superview != nil { h.removeFromSuperview() }
            return
        }
        if hosts.values.contains(where: { $0.superview == nil }) {
            raiseChrome()
            needsLayout = true
        }
        if registrations.isEmpty {
            let id = terminalID.uuidString
            registrations = [
                ElementRegistration(store: elements, id: .pane(id), kind: "pane", label: nil, parent: .windowMain),
                ElementRegistration(store: elements, id: .paneTerminal(id), kind: "terminal", label: nil, parent: .pane(id)),
            ]
            rimRegistration = ElementRegistration(store: elements, id: .paneRimFlash(id), kind: "rim", label: nil, parent: .pane(id))
            needsLayout = true
        }
    }

    func teardown() {
        registrations.forEach { $0.remove() }
        registrations = []
        rimRegistration?.remove()
        rimRegistration = nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Hover

    private func updateTracking() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateTracking()
    }

    override func mouseEntered(with event: NSEvent) { chrome.hovering = true }
    override func mouseExited(with event: NSEvent) { chrome.hovering = false }

    // MARK: Estado

    /// `multiPane`: a tab tem 2+ panes, então o cabeçalho de 24 aparece; com 1 pane só os botões flutuantes.
    func apply(
        title: String, provider: TerminalProvider, glyph: DSIndicatorGlyph, focused: Bool, multiPane: Bool, expanded: Bool, state: PaneRunState,
        timeline: LaunchTimeline? = nil, ignition: Bool = false, interruption: InterruptionReason = .unexpected, exactResume: Bool = true,
        needsAttention: Bool = false, subagent: (session: UUID, mode: SubagentComputersMode, restart: Bool)? = nil
    ) {
        chrome.subagentSession = subagent?.session
        chrome.subagentMode = subagent?.mode ?? .off
        chrome.subagentRestart = subagent?.restart ?? false
        // M-310: agente do pane em `needs input` e pane fora de foco: borda laranja estática até o foco.
        rim.setAttention(needsAttention && !focused)
        chrome.interruption = interruption
        chrome.exactResume = exactResume
        chrome.title = title
        chrome.provider = provider
        chrome.glyph = glyph
        chrome.focused = focused
        chrome.expanded = expanded
        chrome.state = state
        chrome.timeline = timeline
        if case .failed(let detail) = state { chrome.errorDetail = detail }
        if showsHeader != multiPane { needsLayout = true }  // o terminal muda de altura com o header
        showsHeader = multiPane
        present(.header, multiPane)
        present(.floating, !multiPane)
        let banner: Bool
        let card: Bool
        switch state {
        case .interrupted, .closing(stuck: true): (banner, card) = (true, false)
        case .exited(let code, let signal): (banner, card) = code == 0 && signal == nil ? (true, false) : (false, true)
        case .failed: (banner, card) = (false, true)
        default: (banner, card) = (false, false)
        }
        present(.banner, banner)
        present(.card, card)
        var starting = false
        var failed = false
        if case .starting = state { starting = true }
        if case .failed = state { failed = true }
        presentCover(starting || failed)
        present(.ignition, starting && ignition)
        raiseChrome()
        var dimmed = false
        if card, case .exited = state { dimmed = true }
        presentDim(dimmed)
        var interrupted = false
        if case .interrupted = state { interrupted = true }
        // Interrupted: o último scrollback fica a 50% (03 §4.6, M-002); senão o pane inativo a 0,8.
        setHostAlpha(interrupted ? MotionTokens.Opacity.interruptedContent : (focused || multiPane == false ? 1 : MotionTokens.Opacity.inactivePane))
        needsLayout = true
    }

    private func makeHost(_ kind: Chrome) -> NSHostingView<AnyView> {
        let content: AnyView
        switch kind {
        case .header: content = AnyView(PaneHeaderView(model: chrome))
        case .floating: content = AnyView(PaneFloatingButtons(model: chrome))
        case .banner: content = AnyView(PaneBannerView(model: chrome))
        case .card: content = AnyView(PaneCardView(model: chrome))
        case .ignition: content = AnyView(PaneIgnitionView(model: chrome))
        }
        let h = ChromeSizingHostingView(
            rootView: AnyView(content.environment(\.actionRegistry, registry).environment(\.elementStore, elementStore).environment(\.a11yParent, nil)))
        h.safeAreaRegions = []
        return h
    }

    /// Chrome SwiftUI que não aparece sai da hierarquia e é destruído: controles ocultos não ficam em `ctl ui tree`.
    private func present(_ kind: Chrome, _ on: Bool) {
        if on {
            if hosts[kind] == nil {
                let h = makeHost(kind)
                hosts[kind] = h
                addSubview(h)
                needsLayout = true
            }
        } else if let h = hosts.removeValue(forKey: kind) {
            if kind == .ignition { fadeOut(h, duration: MotionTokens.Duration.hover) } else { h.removeFromSuperview() }
        }
    }

    /// M-504: ignição e cobertura somem em fade (checklist 0,12 s, cobertura 0,16 s; Reduce Motion: crossfade). Sem janela, na hora.
    private func fadeOut(_ view: NSView, duration: Double, completion: (@MainActor () -> Void)? = nil) {
        guard window != nil, MotionPolicy.shared.mode != .instant else {
            view.removeFromSuperview()
            completion?()
            return
        }
        let seconds = MotionPolicy.shared.reduceMotion ? MotionTokens.Policy.reducedCrossfade : duration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = seconds
            context.timingFunction = Motion.caTiming(MotionTokens.Easing.exit)
            view.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                view.removeFromSuperview()
                view.alphaValue = 1
                completion?()
            }
        }
    }

    private func presentCover(_ on: Bool) {
        if on {
            coverFading = false
            cover.layer?.removeAllAnimations()
            cover.alphaValue = 1
            if cover.superview == nil { addSubview(cover, positioned: .above, relativeTo: entry.host) }
        } else if cover.superview != nil, !coverFading {
            coverFading = true
            fadeOut(cover, duration: MotionTokens.Duration.paneOpacity + 0.02) { [weak self] in self?.coverFading = false }
        }
    }

    /// Rim flash (M-309) em `blue-400`; o erro de lançamento usa vermelho (M-313).
    func flashRim(color: DSRGBA = DS.ColorSpec.locate) { rim.flash(color: color.nsColor) }

    /// O cabeçalho, os botões, o banner e o cartão ficam acima da cobertura e da ignição.
    private func raiseChrome() {
        addSubview(rim, positioned: .above, relativeTo: entry.host)
        for kind in [Chrome.ignition, .header, .floating, .banner, .card] {
            if let h = hosts[kind] { addSubview(h, positioned: .above, relativeTo: nil) }
        }
    }

    private func presentDim(_ on: Bool) {
        if on {
            if dim.superview == nil { addSubview(dim, positioned: .above, relativeTo: entry.host) }
        } else if dim.superview != nil {
            dim.removeFromSuperview()
        }
    }

    private func setHostAlpha(_ alpha: CGFloat) {
        let host = entry.host
        guard host.alphaValue != alpha else { return }
        if MotionPolicy.shared.reduceMotion || window == nil {
            host.alphaValue = alpha
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = MotionTokens.Duration.paneOpacity
                context.timingFunction = Motion.caTiming(MotionTokens.Easing.ease)
                host.animator().alphaValue = alpha
            }
        }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let w = bounds.width
        // Com header (pane dividido), o terminal começa abaixo dele: antes ocupava o pane inteiro e a 1ª linha e a busca (⌘F)
        // ficavam por baixo do header.
        let headerTop = showsHeader ? PaneMetrics.headerHeight : 0
        entry.host.frame = NSRect(x: 0, y: headerTop, width: w, height: max(0, bounds.height - headerTop))
        hosts[.header]?.frame = NSRect(x: 0, y: 0, width: w, height: PaneMetrics.headerHeight)
        if let floating = hosts[.floating] {
            let size = floating.fittingSize
            floating.frame = NSRect(x: max(0, w - size.width - DS.Space.s1), y: DS.Space.s1, width: min(size.width, w), height: size.height)
        }
        let top = showsHeader ? PaneMetrics.headerHeight : 0
        hosts[.banner]?.frame = NSRect(x: 0, y: top, width: w, height: PaneMetrics.banner)
        dim.frame = bounds
        cover.frame = bounds
        rim.frame = bounds
        hosts[.ignition]?.frame = NSRect(x: 0, y: top, width: w, height: max(0, bounds.height - top))
        if let card = hosts[.card] {
            let cardSize = card.fittingSize
            card.frame = NSRect(
                x: ((w - cardSize.width) / 2).rounded(), y: ((bounds.height - cardSize.height) / 2).rounded(), width: cardSize.width, height: cardSize.height)
        }
        if registrations.count == 2 {
            registrations[0].updateFrame(of: self)
            registrations[1].updateFrame(of: entry.host.surface)
            rimRegistration?.updateFrame(of: rim)
        }
    }
}

/// Camadas de atenção do pane (M-309 rim flash, M-310 atenção persistente). Não recebem clique.
/// Rim flash: borda 1,5 pt a 68%, anel 2 pt a 34% e glow de 18 pt a 36%; opacidade 1 → 0,42 (24%) → 0 (46%) em 1,5 s.
/// Reduce Motion: borda estática por 0,6 s.
@MainActor
final class PaneRimView: NSView {
    private let border = CALayer()
    private let ring = CALayer()
    private let attention = CALayer()
    private let attentionHalo = CALayer()
    static let animationKey = "ds.rimFlash"
    private(set) var flashCount = 0
    private(set) var attentionOn = false

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        for l in [border, ring] {
            l.opacity = 0
            l.backgroundColor = nil
            layer?.addSublayer(l)
        }
        border.borderWidth = 1.5
        ring.borderWidth = 2
        border.shadowRadius = 18
        border.shadowOffset = .zero
        let orange = DS.ColorSpec.agentNeedsInput.nsColor
        attention.borderWidth = 1.5
        attention.borderColor = orange.withAlphaComponent(0.64).cgColor
        attentionHalo.borderWidth = 3
        attentionHalo.borderColor = orange.withAlphaComponent(0.18).cgColor
        for l in [attentionHalo, attention] {
            l.opacity = 0
            layer?.addSublayer(l)
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        for l in [border, attention] { l.frame = bounds }
        ring.frame = bounds.insetBy(dx: 1.5, dy: 1.5)
        attentionHalo.frame = bounds.insetBy(dx: 1.5, dy: 1.5)
    }

    func setAttention(_ on: Bool) {
        guard on != attentionOn else { return }
        attentionOn = on
        let value: Float = on ? 1 : 0
        for l in [attention, attentionHalo] {
            if window != nil, !MotionPolicy.shared.reduceMotion {
                let a = CABasicAnimation(keyPath: "opacity")
                a.fromValue = l.presentation()?.opacity ?? l.opacity
                a.toValue = value
                a.duration = MotionTokens.Duration.fast
                a.timingFunction = Motion.caTiming(MotionTokens.Easing.ease)
                l.add(a, forKey: "ds.attention")
            }
            l.opacity = value
        }
    }

    func flash(color: NSColor) {
        flashCount += 1
        border.borderColor = color.withAlphaComponent(0.68).cgColor
        ring.borderColor = color.withAlphaComponent(0.34).cgColor
        border.shadowColor = color.cgColor
        border.shadowOpacity = 0.36
        let reduced = MotionPolicy.shared.reduceMotion
        for l in [border, ring] {
            l.removeAnimation(forKey: Self.animationKey)
            let a = CAKeyframeAnimation(keyPath: "opacity")
            if reduced {
                a.values = [1, 1, 0]
                a.keyTimes = [0, 0.95, 1]
                a.duration = 0.6
            } else {
                let keys = MotionTokens.Keyframes.rimFlash.tracks["opacity"] ?? []
                a.values = keys.map { Float($0[1]) }
                a.keyTimes = keys.map { NSNumber(value: $0[0]) }
                a.duration = MotionTokens.Keyframes.rimFlash.duration ?? MotionTokens.Duration.flash
            }
            a.calculationMode = .linear
            a.isRemovedOnCompletion = true
            l.opacity = 0
            l.add(a, forKey: Self.animationKey)
        }
    }

    /// `true` enquanto o flash ainda corre (testes e `ctl`).
    var isFlashing: Bool { border.animation(forKey: Self.animationKey) != nil }
}

/// Divisor entre dois panes: 3 pt visíveis (`paneDivider`), 9 de hit, cursor de resize por `addCursorRect`, arrasto imediato,
/// duplo clique iguala os dois lados (DS §12.23). Não grava a cada quadro: o modelo faz debounce de 300 ms e grava ao soltar.
@MainActor
final class PaneDividerView: NSView {
    private(set) var geometry: DividerGeometry
    private let model: WorkspaceModel
    private let line = NSView()
    private var registration: ElementRegistration?
    private var lastRatio: Double

    override var isFlipped: Bool { true }

    init(geometry: DividerGeometry, model: WorkspaceModel, elements: UIElementStore?) {
        self.geometry = geometry
        self.model = model
        lastRatio = geometry.ratio
        self.elements = elements
        super.init(frame: .zero)
        line.wantsLayer = true
        line.layer?.backgroundColor = DS.ColorSpec.paneDivider.nsColor.cgColor
        addSubview(line)
        setAccessibilityIdentifier(A11yID.paneDivider(geometry.secondLeadingPaneID.uuidString).rawValue)
    }

    private let elements: UIElementStore?

    func setTreeVisible(_ visible: Bool) {
        if !visible {
            registration?.remove()
            registration = nil
        } else if registration == nil {
            registration = ElementRegistration(
                store: elements, id: .paneDivider(geometry.secondLeadingPaneID.uuidString), kind: "divider", label: nil, parent: .windowMain)
            needsLayout = true
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }  // required init?(coder:) não usado

    func teardown() {
        registration?.remove()
        registration = nil
    }

    func update(_ geometry: DividerGeometry) {
        self.geometry = geometry
        needsLayout = true
        window?.invalidateCursorRects(for: self)
    }

    override func layout() {
        super.layout()
        switch geometry.axis {
        case .horizontal:
            line.frame = NSRect(x: (bounds.width - PaneLayout.dividerThickness) / 2, y: 0, width: PaneLayout.dividerThickness, height: bounds.height)
        case .vertical:
            line.frame = NSRect(x: 0, y: (bounds.height - PaneLayout.dividerThickness) / 2, width: bounds.width, height: PaneLayout.dividerThickness)
        }
        registration?.updateFrame(of: self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: geometry.axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Arrasto de divisor (F31): os PTYs seguram o resize até soltar; `mouseUp` fecha a transição e cada pane recebe um só.
        model.runtime.setLayoutTransition(true)
        if event.clickCount == 2 { model.equalizeDivider(at: geometry.path) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let area = superview else { return }
        let point = area.convert(event.locationInWindow, from: nil)
        let c = geometry.container
        let t = PaneLayout.dividerThickness
        let ratio: Double
        switch geometry.axis {
        case .horizontal: ratio = Double((point.x - c.minX - t / 2) / max(1, c.width - t))
        case .vertical: ratio = Double((point.y - c.minY - t / 2) / max(1, c.height - t))
        }
        lastRatio = ratio
        model.setRatio(at: geometry.path, ratio: ratio, final: false)
    }

    override func mouseUp(with event: NSEvent) {
        defer { model.runtime.setLayoutTransition(false) }
        guard event.clickCount < 2 else { return }
        model.setRatio(at: geometry.path, ratio: lastRatio, final: true)
    }
}

/// Área dos panes (abaixo da tab row): mantém uma `PaneContainerView` por terminal da sessão, posiciona a da tab ativa pelo
/// layout em árvore e esconde as outras. Terminais nunca são recriados por trocar de tab ou sessão (04 MA6).
@MainActor
final class PaneAreaView: NSView {
    private let model: WorkspaceModel
    private let registry: ActionRegistry?
    private let elements: UIElementStore?
    private let router: TerminalActionRouter?
    private var containers: [UUID: PaneContainerView] = [:]
    /// Panes sem terminal (datasets), pelo id do pane.
    private var otherHosts: [UUID: NSView] = [:]
    private var dividers: [UUID: PaneDividerView] = [:]
    private var emptyHost: NSHostingView<AnyView>?
    private var readyNotified: Set<UUID> = []
    private weak var lastFocusedHost: TerminalHostView?
    /// Zonas de drop e prévia (F11): só existe enquanto há um arrasto sobre um pane.
    private let dropOverlay: PaneDropOverlayView

    override var isFlipped: Bool { true }

    init(model: WorkspaceModel, registry: ActionRegistry?, elements: UIElementStore?, router: TerminalActionRouter?) {
        self.model = model
        self.registry = registry
        self.elements = elements
        self.router = router
        dropOverlay = PaneDropOverlayView(elements: elements)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = DS.ColorSpec.canvas.nsColor.cgColor
        model.addListener { [weak self] in self?.modelChanged() }
        model.dragController.paneArea = self
        model.dragController.addListener { [weak self] in self?.dragChanged() }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }  // required init?(coder:) não usado

    private func modelChanged() {
        reconcile()
        needsLayout = true
    }

    /// O pane (e a zona) sob o cursor durante um arrasto, em coordenadas desta view.
    func dropHit(atWindowPoint point: NSPoint) -> (paneID: UUID, zone: PaneDropZone, frame: CGRect)? {
        guard model.isLoaded, let tab = model.activeTab else { return nil }
        let local = convert(point, from: nil)
        guard bounds.contains(local) else { return nil }
        let expanded = model.expandedPane(in: tab)
        let arrangement = tab.layout.arrangement(in: bounds)
        for pane in tab.layout.panes {
            if let expanded, expanded != pane.id { continue }
            let frame = expanded == nil ? (arrangement.panes[pane.id] ?? .zero) : bounds
            if frame.contains(local) { return (pane.id, PaneDropZone.zone(at: local, in: frame), frame) }
        }
        return nil
    }

    /// Zona sob o cursor sobre a área de panes inteira (tab ativa arrastada sobre o próprio conteúdo).
    func selfDropHit(atWindowPoint point: NSPoint) -> (zone: PaneDropZone, frame: CGRect)? {
        guard model.isLoaded else { return nil }
        let local = convert(point, from: nil)
        guard bounds.contains(local) else { return nil }
        return (PaneDropZone.zone(at: local, in: bounds), bounds)
    }

    private func dragChanged() {
        let drag = model.dragController
        var hover: (zone: PaneDropZone, outcome: DropOutcome, frame: CGRect)?
        switch drag.session?.target {
        case .pane(_, let zone, let outcome, let frame)?: hover = (zone, outcome, frame)
        case .selfTab(let zone, let outcome, let frame)?: hover = (zone, outcome, frame)
        default: break
        }
        if let hover {
            if dropOverlay.superview == nil { addSubview(dropOverlay) }
            dropOverlay.frame = bounds
            dropOverlay.show(zone: hover.zone, outcome: hover.outcome, paneFrame: hover.frame)
        } else if dropOverlay.superview != nil {
            dropOverlay.hide()
        }
    }

    /// Cria e remove containers conforme os terminais carregados.
    private func reconcile() {
        let wanted = model.loadedTerminalIDs
        for id in containers.keys where !wanted.contains(id) {
            containers[id]?.teardown()
            containers[id]?.removeFromSuperview()
            containers[id] = nil
            readyNotified.remove(id)
        }
        for id in wanted where containers[id] == nil {
            let container = PaneContainerView(entry: model.runtime.entry(for: id), registry: registry, elements: elements, drag: model.dragController)
            addSubview(container, positioned: .below, relativeTo: nil)
            containers[id] = container
        }
    }

    override func layout() {
        super.layout()
        model.contentSize = bounds.size
        emptyHost?.frame = bounds
        position()
        if dropOverlay.superview != nil {
            dropOverlay.frame = bounds
            addSubview(dropOverlay, positioned: .above, relativeTo: nil)
        }
    }

    private func position() {
        let sessionLoaded = model.isLoaded
        let tab = model.activeTab
        let noTabs = sessionLoaded && model.tabs.isEmpty
        if noTabs, emptyHost == nil {
            let h = NSHostingView(
                rootView: AnyView(
                    PaneEmptyView(model: model).environment(\.actionRegistry, registry).environment(\.elementStore, elements)
                        .environment(\.a11yParent, nil)))
            h.safeAreaRegions = []
            h.frame = bounds
            addSubview(h)
            emptyHost = h
        } else if !noTabs, let h = emptyHost {
            h.removeFromSuperview()
            emptyHost = nil
        }
        // Esconde só quem sai de cena: esconder e reexibir o pane focado a cada layout tira o teclado do terminal.
        var shown: Set<UUID> = []
        var visibleDividers: Set<UUID> = []
        defer {
            // Pane fora de cena sai da janela (fica guardado em `containers`): o SwiftTerm só para de desenhar quando a view sai da
            // janela, e escondido ele seguia renderizando cada saída dos agentes de todas as sessões abertas. A saída continua
            // sendo processada; ao voltar para a mesma janela o terminal retoma sem recriar nada.
            for (id, c) in containers where !shown.contains(id) {
                c.setTreeVisible(false)
                if c.superview != nil { c.removeFromSuperview() }
            }
            for (id, d) in dividers where !visibleDividers.contains(id) {
                d.isHidden = true
                d.setTreeVisible(false)
            }
        }
        var shownOther: Set<UUID> = []
        defer {
            // Panes que saíram de todas as tabs carregadas somem; os de outras tabs só se escondem.
            let alive = model.allPaneIDs
            for (id, host) in otherHosts where !shownOther.contains(id) {
                if alive.contains(id) {
                    // Fora da janela enquanto escondido (como os terminais): escondido ele seguia atualizando o SwiftUI.
                    if host.superview != nil { host.removeFromSuperview() }
                } else {
                    host.removeFromSuperview()
                    otherHosts[id] = nil
                }
            }
        }
        guard sessionLoaded, let tab else { return }

        let expandedPane = model.expandedPane(in: tab)
        let multi = tab.layout.leafCount > 1
        let arrangement = tab.layout.arrangement(in: bounds)
        var order: [UUID] = []
        for pane in tab.layout.panes {
            guard case .terminal(let terminalID) = pane.content, let container = containers[terminalID], let terminal = model.terminal(terminalID) else { continue }
            if let expandedPane, expandedPane != pane.id { continue }
            let frame = expandedPane == nil ? (arrangement.panes[pane.id] ?? .zero) : bounds
            guard frame.width > 0, frame.height > 0 else { continue }
            shown.insert(terminalID)
            if container.superview == nil { addSubview(container, positioned: .below, relativeTo: nil) }
            container.isHidden = false
            container.setTreeVisible(true)
            if container.frame != frame { container.frame = frame }
            let status = model.status(of: terminal)
            container.apply(
                title: model.displayTitleOfPane(terminalID), provider: terminal.provider,
                glyph: status.glyph, focused: model.focusedTerminalID == terminalID,
                multiPane: multi, expanded: expandedPane != nil, state: model.paneState(terminalID),
                timeline: model.launchTimelines[terminalID], ignition: model.ignitionVisible.contains(terminalID),
                interruption: model.interruptionReasons[terminalID] ?? .unexpected, exactResume: RestorePlanner.hasExactResume(terminal),
                needsAttention: status.glyph == .needsInput, subagent: model.subagentHeader(for: terminal))
            if let flash = model.rimFlash, flash.terminalID == terminalID, container.lastFlashNonce != flash.nonce {
                container.lastFlashNonce = flash.nonce
                container.flashRim()
            }
            order.append(terminalID)
        }
        for pane in tab.layout.panes where pane.content.terminalID == nil {
            if let expandedPane, expandedPane != pane.id { continue }
            let frame = expandedPane == nil ? (arrangement.panes[pane.id] ?? .zero) : bounds
            guard frame.width > 0, frame.height > 0 else { continue }
            let host: NSView
            if let existing = otherHosts[pane.id] {
                host = existing
            } else {
                guard let view = model.makePaneView?(pane) else { continue }
                host = view
                addSubview(host, positioned: .below, relativeTo: nil)
                otherHosts[pane.id] = host
            }
            shownOther.insert(pane.id)
            if host.superview == nil { addSubview(host, positioned: .below, relativeTo: nil) }
            host.isHidden = false
            if host.frame != frame { host.frame = frame }
        }
        if expandedPane == nil {
            for geometry in arrangement.dividers {
                let key = geometry.secondLeadingPaneID
                let view: PaneDividerView
                if let existing = dividers[key] { view = existing; view.update(geometry) } else {
                    view = PaneDividerView(geometry: geometry, model: model, elements: elements)
                    dividers[key] = view
                    addSubview(view)
                }
                visibleDividers.insert(key)
                view.isHidden = false
                view.setTreeVisible(true)
                let hit = PaneMetrics.dividerHit
                let rect = geometry.rect
                let frame = geometry.axis == .horizontal
                    ? NSRect(x: rect.midX - hit / 2, y: rect.minY, width: hit, height: rect.height)
                    : NSRect(x: rect.minX, y: rect.midY - hit / 2, width: rect.width, height: hit)
                if view.frame != frame { view.frame = frame }
            }
        }
        // Foco: o roteador de ações de terminal e o first responder acompanham o pane focado.
        if let focusedID = model.focusedTerminalID, let container = containers[focusedID], !container.isHidden {
            let host = container.entry.host
            router?.focus(host)
            if lastFocusedHost !== host {
                lastFocusedHost = host
                let editing = window?.firstResponder is NSText
                if !editing { DispatchQueue.main.async { [weak model] in model?.autoFocus(host) } }
            }
        }
        // Primeiro layout com tamanho: lança o terminal novo ou religa o que o daemon manteve vivo.
        for id in order where !readyNotified.contains(id) {
            guard let container = containers[id] else { continue }
            container.layoutSubtreeIfNeeded()
            readyNotified.insert(id)
            model.paneReady(id)
        }
    }
}

/// Chrome do pane que muda de tamanho sozinho (o "Restart to apply" que aparece, os botões do hover): o pai refaz o layout, senão o
/// quadro calculado antes corta o conteúdo novo (F38).
final class ChromeSizingHostingView: NSHostingView<AnyView> {
    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        sizingOptions = [.intrinsicContentSize]
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }  // required init?(coder:) não usado

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        superview?.needsLayout = true
    }
}
