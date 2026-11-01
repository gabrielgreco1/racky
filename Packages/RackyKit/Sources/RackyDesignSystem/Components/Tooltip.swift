import AppKit
import Observation
import SwiftUI

// Tooltip invertido (02 §12.14, M-106). `.help()` fica só nos controles de formulário do Settings.

/// Atrasos de abertura (02 §12.14, DS1; tokens `delay.tooltip*`).
public enum TooltipDelay: Sendable {
    case standard, tab, tabClose, stateDot

    public var seconds: TimeInterval {
        switch self {
        case .standard: MotionTokens.Delay.tooltip
        case .tab: MotionTokens.Delay.tooltipTab
        case .tabClose: MotionTokens.Delay.tooltipTabClose
        case .stateDot: MotionTokens.Delay.tooltipStateDot
        }
    }
}

public enum TooltipSide: Sendable { case top, bottom }

public struct TooltipContent: Equatable, Sendable {
    public var text: String
    /// Atalho em `textQuaternary` invertido, separado por 8 pt (`Split Right   ⌘D`).
    public var shortcut: String?
    /// Miniatura acima do texto (hover de um computador na sidebar, 07 CS-403). JPEG ou PNG.
    public var thumbnail: Data?

    public init(_ text: String, shortcut: String? = nil, thumbnail: Data? = nil) {
        self.text = text
        self.shortcut = shortcut?.isEmpty == true ? nil : shortcut
        self.thumbnail = thumbnail
    }
}

/// Estado exibido pelo painel (lido pela view SwiftUI do tooltip).
@MainActor @Observable
final class TooltipModel {
    var content = TooltipContent("")
    var side: TooltipSide = .bottom
    /// Deslocamento horizontal da seta em relação ao centro do balão.
    var arrowOffset: CGFloat = 0
    var visible = false
    var animated = true
}

/// Controlador único (um por janela; o app tem uma janela principal): atrasos, posição e dispensa (02 §12.14).
@MainActor
public final class TooltipController {
    public static let shared = TooltipController()

    /// Outro tooltip visível agora ou há menos de 300 ms abre sem atraso e sem animação (02 §12.14).
    nonisolated public static let chainWindow: TimeInterval = 0.3
    /// Margem transparente do painel: sombra e deslocamento de 8 pt da animação.
    static let panelMargin: CGFloat = 24

    /// Regra pura do atraso, testada sem janela.
    nonisolated public static func effectiveDelay(base: TimeInterval, tooltipVisible: Bool, hiddenAgo: TimeInterval?) -> TimeInterval {
        if tooltipVisible { return 0 }
        if let hiddenAgo, hiddenAgo < chainWindow { return 0 }
        return base
    }

    /// Verdadeiro enquanto um overlay ou menu cobre a janela: tooltips do fundo ficam quietos.
    public var isSuppressed: () -> Bool = { false }
    /// Só a janela key de um app ativo mostra tooltip (perdeu o foco para um NSOpenPanel: nada novo abre). Testes injetam `true`.
    var isWindowActive: (NSWindow) -> Bool = { $0.isKeyWindow && NSApp.isActive }
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Espera dos atrasos de abrir e fechar; testes injetam `ManualScheduler`.
    var sleep: DSSleep = dsSystemSleep
    var motion: MotionPolicy = .shared

    public private(set) var visibleKey: UUID?
    public private(set) var pendingKey: UUID?
    public private(set) var shownCount = 0
    private var hiddenAt: TimeInterval?
    private var pendingTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var monitor: Any?
    private let model = TooltipModel()
    private var panel: NSPanel?
    private weak var parent: NSWindow?

    /// Testes desligam: o painel nunca é ordenado na tela (o estado do tooltip continua igual, só não aparece janela).
    // SAFETY: gravado uma vez no bootstrap dos testes (main actor), antes de qualquer tooltip; produção nunca escreve.
    nonisolated(unsafe) public static var orderingEnabled = true
    private var observers: [any NSObjectProtocol] = []
    private weak var hoverWindow: NSWindow?

    public init() {}

    /// Janela perde o key (NSOpenPanel, sheet, outro app) ou sheet abre: o `mouseExited` nunca chega, então some aqui.
    private func installWindowObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didResignKeyNotification, NSWindow.willBeginSheetNotification, NSApplication.didResignActiveNotification,
            NSWindow.willMiniaturizeNotification, NSWindow.willCloseNotification,
        ]
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let source = note.object as? NSWindow
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // O próprio painel do tooltip nunca vira key; ignora-o.
                    if let source, source === self.panel { return }
                    // Só importa a janela do tooltip (ou o app inteiro perdendo foco); outras janelas não o afetam.
                    if let source, source !== self.hoverWindow { return }
                    self.dismiss(animated: false)
                }
            }
        }
    }

    public var isVisible: Bool { visibleKey != nil }
    public var currentContent: TooltipContent? { visibleKey == nil ? nil : model.content }

    // MARK: Hover

    /// O ponteiro entrou na área. `anchor` devolve o frame do controle em coordenadas de tela (calculado ao mostrar).
    public func hoverBegan(
        key: UUID, content: TooltipContent, delay: TimeInterval, side: TooltipSide, window: NSWindow?,
        anchor: @escaping () -> NSRect?
    ) {
        guard !content.text.isEmpty, !isSuppressed() else { return }
        installWindowObservers()
        hoverWindow = window
        if let window, !isWindowActive(window) { return }
        cancelPending()
        let hiddenAgo = hiddenAt.map { clock() - $0 }
        let wait = Self.effectiveDelay(base: delay, tooltipVisible: visibleKey != nil, hiddenAgo: hiddenAgo)
        let instant = wait == 0
        installMonitor()
        pendingKey = key
        let delay = self.sleep
        pendingTask = Task { [weak self] in
            if wait > 0 { await delay(wait) }
            guard !Task.isCancelled, let self, self.pendingKey == key else { return }
            if let window, !self.isWindowActive(window) { self.cancelPending(); return }
            self.show(key: key, content: content, side: side, window: window, anchor: anchor, animated: !instant)
        }
    }

    public func hoverEnded(key: UUID) {
        if pendingKey == key { cancelPending() }
        if visibleKey == key { hide(animated: true) }
        if visibleKey == nil, pendingKey == nil { removeMonitor() }
    }

    /// Clique, rolagem ou digitação: some na hora (02 §12.14).
    public func dismiss() { dismiss(animated: true) }

    /// `animated == false`: some na hora (perda de foco, sheet, overlay), sem esperar a animação de saída.
    public func dismiss(animated: Bool) {
        cancelPending()
        if visibleKey != nil { hide(animated: animated) }
        if !animated { hideTask?.cancel(); panel?.orderOut(nil) }
        removeMonitor()
    }

    private func cancelPending() {
        pendingTask?.cancel()
        pendingTask = nil
        pendingKey = nil
    }

    // MARK: Painel

    private func show(key: UUID, content: TooltipContent, side: TooltipSide, window: NSWindow?, anchor: () -> NSRect?, animated: Bool) {
        pendingKey = nil
        pendingTask = nil
        guard !isSuppressed(), let anchorRect = anchor() else { return }
        hideTask?.cancel()
        let panel = ensurePanel()
        model.content = content
        model.side = side
        model.animated = animated && motion.resolution != .none
        let host = panel.contentView as? NSHostingView<TooltipBubbleHost>
        host?.layoutSubtreeIfNeeded()
        let size = host?.fittingSize ?? NSSize(width: 120, height: 40)
        let margin = Self.panelMargin
        let screen = window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let bubbleWidth = size.width - margin * 2
        var x = anchorRect.midX - size.width / 2
        x = min(max(x, screen.minX - margin + 4), screen.maxX - size.width + margin - 4)
        let gap = DSMetrics.tooltipGap + DSMetrics.tooltipArrow / 2
        var resolvedSide = side
        var y = side == .bottom ? anchorRect.minY - gap - size.height + margin : anchorRect.maxY + gap - margin
        if side == .bottom, y + margin < screen.minY { resolvedSide = .top }
        if side == .top, y + size.height - margin > screen.maxY { resolvedSide = .bottom }
        if resolvedSide != side {
            y = resolvedSide == .bottom ? anchorRect.minY - gap - size.height + margin : anchorRect.maxY + gap - margin
            model.side = resolvedSide
        }
        let bubbleMidX = x + size.width / 2
        let limit = max(bubbleWidth / 2 - DS.Radius.control - DSMetrics.tooltipArrow, 0)
        model.arrowOffset = min(max(anchorRect.midX - bubbleMidX, -limit), limit)
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: false)
        guard Self.orderingEnabled else {
            visibleKey = key
            shownCount += 1
            model.visible = true
            return
        }
        if let window, panel.parent !== window {
            parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
            parent = window
        }
        panel.orderFrontRegardless()
        visibleKey = key
        shownCount += 1
        model.visible = false
        // Um ciclo depois: a entrada anima de `visible = false` para `true`.
        DispatchQueue.main.async { [model] in model.visible = true }
        if !model.animated { model.visible = true }
    }

    private func hide(animated: Bool) {
        guard visibleKey != nil else { return }
        visibleKey = nil
        hiddenAt = clock()
        model.visible = false
        let wait = (animated && model.animated) ? MotionTokens.Duration.fast : 0
        hideTask?.cancel()
        let delay = self.sleep
        hideTask = Task { [weak self] in
            if wait > 0 { await delay(wait * 2 / 3) }
            guard !Task.isCancelled, let self else { return }
            self.panel?.orderOut(nil)
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: TooltipBubbleHost(model: model))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        self.panel = panel
        return panel
    }

    // MARK: Dispensa por evento

    private func installMonitor() {
        guard monitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.dismiss() }
            return event
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: Visual

struct TooltipBubbleHost: View {
    let model: TooltipModel

    var body: some View {
        TooltipBubble(content: model.content, side: model.side, arrowOffset: model.arrowOffset)
            .padding(TooltipController.panelMargin)
            .scaleEffect(model.visible ? 1 : MotionTokens.Scale.dialogFrom, anchor: model.side == .bottom ? .top : .bottom)
            .offset(y: model.visible ? 0 : (model.side == .bottom ? -MotionTokens.Distance.small : MotionTokens.Distance.small))
            .opacity(model.visible ? 1 : 0)
            .animation(animation, value: model.visible)
    }

    private var animation: Animation? {
        guard model.animated, case .normal(let scale) = MotionPolicy.shared.resolution else { return nil }
        return model.visible
            ? Motion.curve(MotionTokens.Easing.standard, MotionTokens.Duration.fast * scale)
            : Motion.curve(MotionTokens.Easing.exit, MotionTokens.Duration.fast * 2 / 3 * scale)
    }
}

/// Balão: fundo `textPrimary`, texto `canvas` 12/400, padding 6×12 (4×8 de uma palavra), raio 8, máx. 280, seta 10 (02 §12.14).
public struct TooltipBubble: View {
    private let content: TooltipContent
    private let side: TooltipSide
    private let arrowOffset: CGFloat

    public init(content: TooltipContent, side: TooltipSide = .bottom, arrowOffset: CGFloat = 0) {
        self.content = content
        self.side = side
        self.arrowOffset = arrowOffset
    }

    private static let thumbnailRatio: CGFloat = 0.6
    private var compact: Bool { content.shortcut == nil && content.thumbnail == nil && !content.text.contains(" ") }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s1_5) {
            if let data = content.thumbnail, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: DS.Layout.tooltipMaxWidth, maxHeight: DS.Layout.tooltipMaxWidth * Self.thumbnailRatio)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm))
            }
            HStack(spacing: DS.Space.s2) {
                Text(verbatim: content.text)
                    .dsFont(DS.Font.tab)
                    .foregroundStyle(DS.Color.canvas)
                    .fixedSize(horizontal: false, vertical: true)
                if let shortcut = content.shortcut {
                    Text(verbatim: shortcut)
                        .dsFont(DS.Font.tab)
                        .foregroundStyle(DS.ColorSpec.canvas.scaled(0.55).color)
                        .fixedSize()
                }
            }
        }
        .padding(.horizontal, compact ? DS.Space.s2 : DSMetrics.tooltipPaddingH)
        .padding(.vertical, compact ? DS.Space.s1 : DSMetrics.tooltipPaddingV)
        .frame(maxWidth: DS.Layout.tooltipMaxWidth)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.Color.textPrimary)
                RoundedRectangle(cornerRadius: DS.Space.s0_5)
                    .fill(DS.Color.textPrimary)
                    .frame(width: DSMetrics.tooltipArrow, height: DSMetrics.tooltipArrow)
                    .rotationEffect(.degrees(45))
                    .offset(x: arrowOffset)
                    .frame(maxHeight: .infinity, alignment: side == .bottom ? .top : .bottom)
                    .offset(y: side == .bottom ? -DSMetrics.tooltipArrow / 2 : DSMetrics.tooltipArrow / 2)
            }
        }
        .dsShadow(DS.Shadow.floating)
        .environment(\.colorScheme, .dark)
        .accessibilityHidden(true)
    }
}

// MARK: Modificador

/// Área de rastreio sem interceptar cliques: `hitTest` devolve `nil`.
final class TooltipTrackerView: NSView {
    var content = TooltipContent("")
    var delay: TimeInterval = TooltipDelay.standard.seconds
    var side: TooltipSide = .bottom
    private let key = UUID()
    private var area: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let new = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(new)
        area = new
    }

    /// Há algo por cima (overlay, menu de outra view hospedeira)? Então o tooltip do fundo fica quieto.
    private var isObscured: Bool {
        guard let content = window?.contentView, let container = content.superview, let parent = superview else { return false }
        guard let hit = content.hitTest(container.convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)) else { return false }
        return !(hit === parent || hit.isDescendant(of: parent) || parent.isDescendant(of: hit))
    }

    override func mouseEntered(with event: NSEvent) {
        guard !isObscured else { return }
        TooltipController.shared.hoverBegan(key: key, content: content, delay: delay, side: side, window: window) { [weak self] in
            guard let self, let window = self.window else { return nil }
            return window.convertToScreen(self.convert(self.bounds, to: nil))
        }
    }

    override func mouseExited(with event: NSEvent) { TooltipController.shared.hoverEnded(key: key) }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { TooltipController.shared.hoverEnded(key: key) }
        super.viewWillMove(toWindow: newWindow)
    }
}

private struct TooltipTracker: NSViewRepresentable {
    let content: TooltipContent
    let delay: TimeInterval
    let side: TooltipSide

    func makeNSView(context: Context) -> TooltipTrackerView {
        let view = TooltipTrackerView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: TooltipTrackerView, context: Context) { apply(to: view) }

    private func apply(to view: TooltipTrackerView) {
        view.content = content
        view.delay = delay
        view.side = side
    }
}

public extension View {
    /// Tooltip do DS (02 §12.14): nome da ação + atalho, 400 ms, some ao clicar. Texto vazio ou `enabled == false`: nada.
    func dsTooltip(
        _ text: String, shortcut: String? = nil, delay: TooltipDelay = .standard, side: TooltipSide = .bottom, enabled: Bool = true,
        thumbnail: Data? = nil
    ) -> some View {
        background {
            if enabled, !text.isEmpty {
                TooltipTracker(content: TooltipContent(text, shortcut: shortcut, thumbnail: thumbnail), delay: delay.seconds, side: side)
            }
        }
    }
}
