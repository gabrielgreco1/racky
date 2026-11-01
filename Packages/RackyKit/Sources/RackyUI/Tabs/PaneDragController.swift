import RackyDesignSystem
import RackyProtocol
import AppKit
import Foundation
import SwiftUI

/// Arrasto de tab ou de pane (F11, 03 §3.4 e §4.3, M-303 e M-306). Rastreio de mouse próprio: a view de origem recebe
/// `mouseDown`/`mouseDragged`/`mouseUp` e entrega os pontos (coordenadas da janela, y para cima) a este controlador, que
/// decide o alvo (reordenar, zona de drop sobre um pane, tab row) e aplica no `WorkspaceModel` ao soltar.
///
/// Nunca deixa estado preso: Esc, perda de foco da janela ou do app e a saída da view de origem da janela cancelam; todo
/// caminho de saída (soltar, cancelar) passa por `finish()` e devolve o teclado ao terminal.
@MainActor
@Observable
final class PaneDragController {
    enum Target: Equatable {
        /// Zona sobre um pane; `frame` no espaço da área de panes (y para baixo).
        case pane(paneID: UUID, zone: PaneDropZone, outcome: DropOutcome, frame: CGRect)
        /// Pane arrastado sobre a tab row: vira tab na posição `index`.
        case tabRow(index: Int)
        /// Tab ativa arrastada sobre o próprio conteúdo: vira split com a tab parceira; `frame` é a área de panes inteira.
        case selfTab(zone: PaneDropZone, outcome: DropOutcome, frame: CGRect)
    }

    struct Session: Equatable {
        var payload: PaneDragPayload
        var title: String
        var start: CGPoint
        var point: CGPoint
        /// Posição da tab arrastada na tab row quando o arrasto começou.
        var originIndex: Int?
        var overTabRow: Bool
        var target: Target?
    }

    private(set) var session: Session?

    @ObservationIgnored weak var model: WorkspaceModel?
    @ObservationIgnored weak var paneArea: PaneAreaView?
    /// Retângulo da tab row em coordenadas da janela (y para cima).
    @ObservationIgnored var tabRowRect: () -> CGRect? = { nil }
    /// Frames das tabs em coordenadas globais do SwiftUI (só o eixo x importa aqui).
    @ObservationIgnored var tabFrames: [UUID: CGRect] = [:]
    @ObservationIgnored private var listeners: [() -> Void] = []
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private weak var owner: AnyObject?
    @ObservationIgnored private weak var hostWindow: NSWindow?
    @ObservationIgnored private var ghost: DragGhostView?
    @ObservationIgnored private var cursorPushed = false
    /// Quantos arrastos terminaram em drop aplicado ou cancelado (testes e diagnóstico).
    @ObservationIgnored private(set) var finishedCount = 0

    /// Largura padrão de uma tab quando o SwiftUI ainda não mediu.
    static let fallbackTabWidth = DS.Layout.tabWidth

    var isActive: Bool { session != nil }

    func addListener(_ listener: @escaping () -> Void) { listeners.append(listener) }
    private func notify() { for l in listeners { l() } }

    // MARK: Ciclo de vida

    func begin(_ payload: PaneDragPayload, title: String, from start: CGPoint, at point: CGPoint, window: NSWindow?, owner: AnyObject?) {
        if session != nil { cancel() }
        guard let model else { return }
        var originIndex: Int?
        if case .tab(let id) = payload { originIndex = model.tabs.firstIndex { $0.id == id } }
        session = Session(payload: payload, title: title, start: start, point: point, originIndex: originIndex, overTabRow: false, target: nil)
        self.owner = owner
        hostWindow = window
        installGuards(window: window)
        if let content = window?.contentView {
            let g = DragGhostView(title: title)
            content.addSubview(g)
            ghost = g
        }
        NSCursor.closedHand.push()
        cursorPushed = true
        refresh()
    }

    func update(at point: CGPoint) {
        guard session != nil else { return }
        session?.point = point
        refresh()
    }

    /// Solta: aplica o alvo atual. `nil` quando não havia arrasto ou o drop caiu fora (cancela).
    @discardableResult
    func end(at point: CGPoint) -> DropOutcome? {
        guard session != nil else { return nil }
        session?.point = point
        refresh()
        guard let s = session else { return nil }
        finish()
        guard let model else { return nil }
        switch (s.payload, s.target) {
        case (.tab(let id), nil) where s.overTabRow:
            let target = reorderTarget(for: s)
            if target != s.originIndex { model.moveTab(id, to: target) }
            model.returnFocusToTerminal()
            return .applied
        case (let payload, .pane(let paneID, let zone, _, _)?):
            return model.performDrop(payload, onPane: paneID, zone: zone)
        case (.tab(let id), .selfTab(let zone, _, _)?):
            return model.performSelfDrop(id, zone: zone)
        case (.pane(let terminalID), .tabRow(let index)?):
            return model.detachPane(terminalID, toIndex: index)
        case (.otherPane(let paneID), .tabRow(let index)?):
            return model.detachPane(paneID: paneID, toIndex: index)
        default:
            model.returnFocusToTerminal()
            return nil
        }
    }

    /// Esc, perda de foco ou saída da view de origem: nada muda no modelo e o foco volta ao terminal.
    func cancel() {
        guard session != nil else { return }
        finish()
        model?.returnFocusToTerminal()
    }

    /// A view de origem saiu da janela no meio do arrasto: só cancela se o arrasto era dela.
    func cancel(ifOwnedBy view: AnyObject) {
        if owner === view { cancel() }
    }

    private func finish() {
        session = nil
        owner = nil
        finishedCount += 1
        removeGuards()
        ghost?.removeFromSuperview()
        ghost = nil
        if cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
        notify()
    }

    private func installGuards(window: NSWindow?) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.session != nil else { return event }
            if event.keyCode == 53 {  // Esc
                self.cancel()
                return nil
            }
            return event
        }
        let center = NotificationCenter.default
        if let window {
            observers.append(
                center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.cancel() }
                })
        }
        observers.append(
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            })
    }

    private func removeGuards() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
    }

    // MARK: Alvo

    private func refresh() {
        guard var s = session, let model else { return }
        s.overTabRow = tabRowRect().map { $0.contains(s.point) } ?? false
        s.target = nil
        if s.overTabRow {
            switch s.payload {
            case .pane, .otherPane: s.target = .tabRow(index: insertionIndex(atX: s.point.x, in: model))
            case .tab: break
            }
        } else if case .tab(let id) = s.payload, id == model.activeTabID {
            // Tab ativa sobre o próprio conteúdo: zonas sobre a área inteira, parceira = outra tab da sessão.
            if let hit = paneArea?.selfDropHit(atWindowPoint: s.point) {
                let outcome = model.evaluateSelfDrop(id, zone: hit.zone)
                if outcome != .invalid { s.target = .selfTab(zone: hit.zone, outcome: outcome, frame: hit.frame) }
            }
        } else if let hit = paneArea?.dropHit(atWindowPoint: s.point) {
            let outcome = model.evaluateDrop(s.payload, onPane: hit.paneID, zone: hit.zone)
            if outcome != .invalid { s.target = .pane(paneID: hit.paneID, zone: hit.zone, outcome: outcome, frame: hit.frame) }
        }
        let showGhost = !(s.overTabRow && s.originIndex != nil)
        session = s
        ghost?.place(at: s.point, visible: showGhost)
        notify()
    }

    /// Índice onde um pane solto na tab row entra: depois de todas as tabs cujo meio está à esquerda do cursor.
    private func insertionIndex(atX x: CGFloat, in model: WorkspaceModel) -> Int {
        model.tabs.filter { (tabFrames[$0.id]?.midX ?? -.infinity) < x }.count
    }

    /// Para onde a tab arrastada iria ao soltar agora (deslocamento horizontal em larguras de tab).
    func reorderTarget(for s: Session) -> Int {
        guard let origin = s.originIndex, case .tab(let id) = s.payload, let model else { return 0 }
        let width = tabFrames[id]?.width ?? Self.fallbackTabWidth
        let moved = Int(((s.point.x - s.start.x) / max(width, 1)).rounded())
        return min(max(origin + moved, 0), max(model.tabs.count - 1, 0))
    }
}

/// Etiqueta que acompanha o cursor enquanto o item está fora da tab row: título numa pílula `chrome` com borda (não recebe clique).
@MainActor
final class DragGhostView: NSView {
    private let label: NSTextField
    static let height = DS.Layout.paneHeaderHeight + DS.Space.s1
    static let maxWidth = DS.Layout.tabWidth

    init(title: String) {
        label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = DS.ColorSpec.chrome.nsColor.cgColor
        layer?.borderColor = DS.ColorSpec.borderStrong.nsColor.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = DS.Space.s1_5
        label.font = DS.Font.tab.nsFont
        label.textColor = DS.ColorSpec.textPrimary.nsColor
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        alphaValue = 0
        let width = min(label.intrinsicContentSize.width + 2 * DS.Space.s2, Self.maxWidth)
        setFrameSize(NSSize(width: width, height: Self.height))
        label.frame = NSRect(
            x: DS.Space.s2, y: (Self.height - label.intrinsicContentSize.height) / 2, width: width - 2 * DS.Space.s2, height: label.intrinsicContentSize.height)
        setAccessibilityIdentifier(A11yID.paneDragGhost.rawValue)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// `point` em coordenadas da janela: a pílula fica logo abaixo e à direita do cursor.
    func place(at point: CGPoint, visible: Bool) {
        guard let superview else { return }
        let local = superview.convert(point, from: nil)
        let below = superview.isFlipped ? DS.Space.s3 : -(DS.Space.s3 + frame.height)
        setFrameOrigin(NSPoint(x: local.x + DS.Space.s3, y: local.y + below))
        alphaValue = visible ? 0.94 : 0
    }
}

/// Origem de um arrasto: view transparente que recebe o mouse da tab (ou do cabeçalho do pane). Clique sem arrastar chama
/// `onClick` (1 ou 2 cliques); depois de 12 pt de movimento vira arrasto e o clique não dispara.
@MainActor
final class DragSourceView: NSView {
    var controller: PaneDragController?
    var payload: PaneDragPayload = .pane(UUID())
    var title: () -> String = { "" }
    var onClick: (Int) -> Void = { _ in }
    /// Só o botão esquerdo é nosso: o resto (menu de contexto, clique do meio, hover) atravessa para o SwiftUI.
    var claimsOnlyLeftMouse = true
    private var down: NSPoint?
    private(set) var dragging = false
    private var clickCount = 1

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if claimsOnlyLeftMouse {
            guard let type = NSApp.currentEvent?.type, type == .leftMouseDown || type == .leftMouseDragged || type == .leftMouseUp else { return nil }
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        down = event.locationInWindow
        dragging = false
        clickCount = event.clickCount
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = down, let controller else { return }
        let p = event.locationInWindow
        if !dragging {
            guard hypot(p.x - start.x, p.y - start.y) >= TabMetrics.dragActivation else { return }
            dragging = true
            controller.begin(payload, title: title(), from: start, at: p, window: window, owner: self)
        }
        controller.update(at: p)
    }

    override func mouseUp(with event: NSEvent) {
        let wasDragging = dragging
        let count = clickCount
        down = nil
        dragging = false
        if wasDragging {
            controller?.end(at: event.locationInWindow)
        } else {
            onClick(count)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            controller?.cancel(ifOwnedBy: self)
            down = nil
            dragging = false
        }
    }
}

/// Ponte SwiftUI da `DragSourceView`.
struct PaneDragSource: NSViewRepresentable {
    let controller: PaneDragController?
    let payload: PaneDragPayload
    let title: () -> String
    var onClick: (Int) -> Void = { _ in }

    func makeNSView(context: Context) -> DragSourceView { DragSourceView() }

    func updateNSView(_ view: DragSourceView, context: Context) {
        view.controller = controller
        view.payload = payload
        view.title = title
        view.onClick = onClick
    }
}
