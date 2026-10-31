import RackyDesignSystem
import RackyProtocol
import AppKit
import SwiftUI

extension EnvironmentValues {
    /// `true` a partir da abertura do cartão: os grupos de conteúdo animam a entrada (stagger de M-101).
    @Entry var overlayEntered: Bool = true
}

/// Grupo de conteúdo do cartão (M-101): fade + 4 pt com atraso `(índice + 1) × stagger`, até 3 grupos.
/// Reduce Motion e modo instantâneo: sem stagger (o cartão inteiro faz o crossfade).
struct OverlayGroupModifier: ViewModifier {
    let index: Int
    @Environment(\.overlayEntered) private var entered

    func body(content: Content) -> some View {
        let animated: Bool = if case .normal = MotionPolicy.shared.resolution { true } else { false }
        let visible = entered || !animated
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : MotionTokens.Distance.micro)
            .animation(Self.animation(index: index), value: visible)
    }

    static func animation(index: Int) -> Animation? {
        guard case .normal(let scale) = MotionPolicy.shared.resolution else { return nil }
        return Motion.curve(MotionTokens.Easing.standard, OverlayMotion.enterDuration * scale)
            .delay(OverlayMotion.groupDelay(index: index) * scale)
    }
}

public extension View {
    /// Marca o grupo `index` (0...2) de conteúdo do overlay para o stagger de M-101.
    func overlayGroup(_ index: Int) -> some View { modifier(OverlayGroupModifier(index: index)) }
}

/// Raiz do host (02 §12.17, 16): scrim, cartões da pilha e toasts, acima do `NSSplitViewController` da janela.
struct OverlayPanelHost: View {
    let router: OverlayRouter
    let toasts: ToastCenter
    let registry: ActionRegistry
    let elements: UIElementStore

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(Array(router.stack.enumerated()), id: \.element.id) { index, entry in
                    OverlayEntryView(entry: entry, isBase: index == 0, isTop: entry.id == router.top?.id, container: proxy.size, router: router)
                }
                ToastStack(toasts: toasts)
                PopoverLayer(router: router)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .environment(\.elementStore, elements)
        .environment(\.actionRegistry, registry)
        .environment(\.overlayRouter, router)
        .environment(\.a11yParent, .windowMain)
        .ignoresSafeArea()
    }
}

/// Um overlay: scrim (só o da base) + cartão com a animação M-101/M-102 variante A.
private struct OverlayEntryView: View {
    let entry: OverlayEntry
    let isBase: Bool
    let isTop: Bool
    let container: CGSize
    let router: OverlayRouter

    @State private var shown = false
    @State private var entered = false
    @State private var started = false
    @State private var cardSize: CGSize = .zero

    private var resolution: MotionResolution { MotionPolicy.shared.resolution }
    private var reduced: Bool { if case .crossfade = resolution { true } else { false } }

    var body: some View {
        let origin = OverlayMotion.origin(
            cardSize: cardSize, cardCenter: CGPoint(x: container.width / 2, y: container.height / 2),
            originCenter: entry.originFrame.map { CGPoint(x: $0.midX, y: $0.midY) })
        let closing = entry.isClosing
        let hiddenScale = reduced ? 1 : (closing ? MotionTokens.Scale.exitTo : MotionTokens.Scale.dialogFrom)
        let hiddenOffset = (reduced || closing) ? 0 : OverlayMotion.offset

        ZStack {
            if isBase { scrim }
            card
                .scaleEffect(shown ? 1 : hiddenScale, anchor: origin.anchor)
                .offset(x: shown ? 0 : origin.direction.dx * hiddenOffset, y: shown ? 0 : origin.direction.dy * hiddenOffset)
                .opacity(shown ? 1 : 0)
                .animation(cardAnimation, value: shown)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .allowsHitTesting(isTop && !closing)
        .accessibilityHidden(!isTop || closing)
        .onChange(of: entry.isClosing) { _, isClosing in
            if isClosing { shown = false }
        }
    }

    private var scrim: some View {
        (MotionPolicy.shared.reduceTransparency ? DS.Color.scrimReducedTransparency : DS.Color.scrim)
            .opacity(shown ? 1 : 0)
            .animation(scrimAnimation, value: shown)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .a11y(.overlayScrim, kind: "scrim")
    }

    private var card: some View {
        entry.spec.content()
            .environment(\.overlayEntered, entered)
            .frame(width: min(entry.spec.width, max(container.width - DSMetrics.overlayWindowMarginH, .zero)))
            .frame(maxHeight: max(container.height - DSMetrics.overlayWindowMarginV, .zero))
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: entry.spec.cornerRadius).fill(DS.Color.overlaySolid))
            .overlay(RoundedRectangle(cornerRadius: entry.spec.cornerRadius).strokeBorder(DS.Color.borderStrong, lineWidth: DSMetrics.hairline))
            .dsShadow(DS.Shadow.dialog)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .a11y(entry.spec.id, kind: "overlay")
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                cardSize = size
                begin()
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { router.setCardFrame(entry.id, $0) }
    }

    /// A animação só começa quando o tamanho do cartão é conhecido (a âncora depende dele).
    private func begin() {
        guard !started, cardSize.width > 0 else { return }
        started = true
        shown = true
        entered = true
    }

    private var cardAnimation: Animation? {
        switch resolution {
        case .none: nil
        case .crossfade(let d): Motion.curve(MotionTokens.Easing.ease, d)
        case .normal(let scale):
            shown
                ? Motion.curve(MotionTokens.Easing.standard, OverlayMotion.enterDuration * scale)
                : Motion.curve(MotionTokens.Easing.exit, OverlayMotion.exitDuration * scale)
        }
    }

    private var scrimAnimation: Animation? {
        switch resolution {
        case .none: nil
        case .crossfade(let d): Motion.curve(MotionTokens.Easing.ease, d)
        case .normal(let scale): Motion.curve(MotionTokens.Easing.ease, OverlayMotion.scrimDuration * scale)
        }
    }
}

/// Hosting view do overlay: cobre a janela inteira (inclusive sidebar e titlebar; os semáforos ficam acima e clicáveis).
/// Sem overlay deixa passar todos os cliques, exceto os dos toasts; com overlay engole tudo (o scrim bloqueia o fundo).
@MainActor
final class OverlayHostingView: NSHostingView<AnyView> {
    let router: OverlayRouter
    let toasts: ToastCenter

    init(router: OverlayRouter, toasts: ToastCenter, registry: ActionRegistry, elements: UIElementStore) {
        self.router = router
        self.toasts = toasts
        super.init(rootView: AnyView(OverlayPanelHost(router: router, toasts: toasts, registry: registry, elements: elements)))
        safeAreaRegions = []
        trackCursorOwnership()
    }

    // MARK: Cursor

    /// Com overlay aberto o cursor é a seta: sem isto o terminal por baixo (SwiftTerm, área de rastreamento `.activeAlways`)
    /// punha o "I" de texto sobre os botões do composer e dos diálogos.
    private func trackCursorOwnership() {
        let host = CursorHostBox(self)
        withObservationTracking {
            _ = router.capturesInput
        } onChange: {
            Task { @MainActor in
                guard let view = host.view else { return }
                view.window?.invalidateCursorRects(for: view)
                if view.router.capturesInput { NSCursor.arrow.set() }
                view.trackCursorOwnership()
            }
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if router.capturesInput { addCursorRect(bounds, cursor: .arrow) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(where: { $0.userInfo?["overlayCursor"] != nil }) {
            addTrackingArea(NSTrackingArea(
                rect: .zero, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self, userInfo: ["overlayCursor": true]))
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        if router.capturesInput { NSCursor.arrow.set() } else { super.cursorUpdate(with: event) }
    }

    /// Exigido pela superclasse; o host sempre nasce por `init(router:...)`. Aqui o roteador é vazio e nunca é usado.
    @MainActor @preconcurrency required init(rootView: AnyView) {
        router = OverlayRouter()
        toasts = ToastCenter()
        super.init(rootView: rootView)
    }

    @MainActor @preconcurrency required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }  // required init?(coder:) não usado

    override var acceptsFirstResponder: Bool { router.capturesInput }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Ponto em coordenadas globais do SwiftUI (origem no canto superior esquerdo).
    private func swiftUIPoint(_ local: NSPoint) -> CGPoint {
        CGPoint(x: local.x, y: isFlipped ? local.y : bounds.height - local.y)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if router.capturesInput { return super.hitTest(point) }
        let p = swiftUIPoint(local)
        if toasts.cardFrames.values.contains(where: { $0.contains(p) }) { return super.hitTest(point) }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        // Popover aberto: a camada SwiftUI decide (item do painel ou clique fora, que só fecha o popover).
        if router.popoverIsOpen {
            super.mouseDown(with: event)
            return
        }
        let p = swiftUIPoint(convert(event.locationInWindow, from: nil))
        let inside = router.top.flatMap { router.cardFrames[$0.id] }?.contains(p) ?? false
        if router.isPresenting, !inside, !toasts.cardFrames.values.contains(where: { $0.contains(p) }) {
            router.scrimClicked()
            return
        }
        super.mouseDown(with: event)
    }

    static let escapeKeyCode: UInt16 = 53

    override func keyDown(with event: NSEvent) {
        if router.capturesInput, event.keyCode == Self.escapeKeyCode {
            router.escapePressed()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if router.capturesInput { router.escapePressed() } else { super.cancelOperation(sender) }
    }

    /// Tab fica no overlay: o único key view candidato enquanto há overlay é este (os outros recusam first responder).
    override var nextKeyView: NSView? {
        get { router.capturesInput ? self : super.nextKeyView }
        set { super.nextKeyView = newValue }
    }

    override var previousValidKeyView: NSView? { router.capturesInput ? self : super.previousValidKeyView }
    override var nextValidKeyView: NSView? { router.capturesInput ? self : super.nextValidKeyView }
}

/// Referência fraca ao host do overlay para o `onChange` (`@Sendable`) da observação do cursor.
private final class CursorHostBox: @unchecked Sendable {  // SAFETY: `view` só é lido dentro de `Task { @MainActor }`.
    weak var view: OverlayHostingView?
    init(_ view: OverlayHostingView) { self.view = view }
}
