import RackyDesignSystem
import RackyProtocol
import AppKit

/// Zonas de drop sobre o pane sob o cursor (F11, M-306): moldura do pane, prévia translúcida da área que o item arrastado vai
/// ocupar (metade do pane nas bordas, o pane inteiro no centro, com o glifo de troca) e, sem espaço para o split, a mesma
/// prévia em vermelho. Só desenha: não recebe clique e nunca toca a view do terminal.
@MainActor
final class PaneDropOverlayView: NSView {
    private let guide = NSView()
    private let preview = NSView()
    private let swapGlyph = NSImageView()
    private let elements: UIElementStore?
    private var registrations: [ElementRegistration] = []
    private var fadeToken = 0
    private(set) var zone: PaneDropZone?
    private(set) var outcome: DropOutcome = .applied
    /// Retângulo final da prévia (espaço desta view, y para baixo); a view anima até ele.
    private(set) var previewTarget: CGRect = .zero
    private(set) var paneFrame: CGRect = .zero

    static let inset = DS.Space.s0_5
    static let radius = DS.Space.s1

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init(elements: UIElementStore?) {
        self.elements = elements
        super.init(frame: .zero)
        wantsLayer = true
        guide.wantsLayer = true
        guide.layer?.borderWidth = 1
        guide.layer?.cornerRadius = Self.radius
        preview.wantsLayer = true
        preview.layer?.borderWidth = 1.5
        preview.layer?.cornerRadius = Self.radius
        swapGlyph.image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: nil)
        swapGlyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: DS.Space.s6, weight: .regular)
        swapGlyph.contentTintColor = DS.ColorSpec.locate.nsColor
        swapGlyph.isHidden = true
        addSubview(guide)
        addSubview(preview)
        preview.addSubview(swapGlyph)
        alphaValue = 0
        setAccessibilityIdentifier(A11yID.paneDropOverlay.rawValue)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var animates: Bool { window != nil && MotionPolicy.shared.mode != .instant && !MotionPolicy.shared.reduceMotion }

    func show(zone: PaneDropZone, outcome: DropOutcome, paneFrame: CGRect) {
        fadeToken += 1
        self.zone = zone
        self.outcome = outcome
        let samePane = self.paneFrame == paneFrame
        self.paneFrame = paneFrame
        let tint = (outcome == .noRoom ? DS.ColorSpec.destructive : DS.ColorSpec.locate).nsColor
        guide.layer?.borderColor = tint.withAlphaComponent(0.34).cgColor
        preview.layer?.backgroundColor = tint.withAlphaComponent(0.14).cgColor
        preview.layer?.borderColor = tint.withAlphaComponent(0.6).cgColor
        let guideFrame = paneFrame.insetBy(dx: Self.inset, dy: Self.inset)
        let target = zone.previewRect(in: paneFrame).insetBy(dx: Self.inset, dy: Self.inset)
        previewTarget = target
        swapGlyph.isHidden = zone != .center || outcome == .noRoom
        swapGlyph.contentTintColor = tint
        let size = swapGlyph.intrinsicContentSize
        swapGlyph.frame = NSRect(x: (target.width - size.width) / 2, y: (target.height - size.height) / 2, width: size.width, height: size.height)

        let duration = MotionTokens.Duration.base
        if animates, samePane, alphaValue > 0 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = Motion.caTiming(MotionTokens.Easing.standard)
                preview.animator().frame = target
            }
        } else {
            preview.frame = target
        }
        guide.frame = guideFrame
        if alphaValue < 1 { fade(to: 1, duration: animates ? MotionTokens.Duration.fast : (MotionPolicy.shared.reduceMotion ? MotionTokens.Policy.reducedCrossfade : 0)) }
        register()
    }

    /// Some com fade e sai da hierarquia (a menos que um novo `show` chegue antes).
    func hide() {
        fadeToken += 1
        let token = fadeToken
        unregister()
        zone = nil
        let seconds = animates ? MotionTokens.Duration.fast : (MotionPolicy.shared.reduceMotion && window != nil ? MotionTokens.Policy.reducedCrossfade : 0)
        fade(to: 0, duration: seconds) { [weak self] in
            guard let self, self.fadeToken == token else { return }
            self.removeFromSuperview()
        }
    }

    private func fade(to value: CGFloat, duration: Double, completion: (@MainActor () -> Void)? = nil) {
        guard duration > 0, window != nil else {
            alphaValue = value
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = Motion.caTiming(MotionTokens.Easing.ease)
            animator().alphaValue = value
        } completionHandler: {
            MainActor.assumeIsolated { completion?() }
        }
    }

    // MARK: Automação (`ctl ui tree`)

    private func register() {
        guard let zone else { return }
        if registrations.isEmpty {
            registrations = [
                ElementRegistration(store: elements, id: .paneDropOverlay, kind: "container", label: nil, parent: .windowMain),
                ElementRegistration(store: elements, id: .paneDropZone(zone.rawValue), kind: "dropzone", label: nil, parent: .paneDropOverlay),
            ]
        } else {
            registrations[1].remove()
            registrations[1] = ElementRegistration(store: elements, id: .paneDropZone(zone.rawValue), kind: "dropzone", label: nil, parent: .paneDropOverlay)
        }
        registrations[0].updateFrame(of: paneFrame, in: self)
        registrations[1].updateFrame(of: previewTarget, in: self)
    }

    private func unregister() {
        registrations.forEach { $0.remove() }
        registrations = []
    }
}
