import AppKit
import QuartzCore
import SwiftUI

/// Especificação pura do spinner (04 §2, M-401/M-811): 1 volta/s em 12 passos discretos de 30°, fase global, ≤ 12 fps.
public enum DSSpinnerSpec {
    public static var period: Double { MotionTokens.Loop.spinner.period }
    public static var steps: Int { Int(MotionTokens.Loop.spinner.numbers["steps"]?.first ?? 12) }
    public static var fps: Double { MotionTokens.Loop.spinner.fps }
    /// Arco de 270° (topo transparente).
    public static let arcFraction = 0.75

    /// Ângulos de cada passo (radianos, sentido horário na tela).
    public static var stepAngles: [Double] {
        (0..<steps).map { -Double($0) * 2 * Double.pi / Double(steps) }
    }

    /// Começo global da animação: múltiplo inteiro do período em `CACurrentMediaTime`, o mesmo para toda instância (fase sincronizada).
    public static func globalBeginTime(now: CFTimeInterval) -> CFTimeInterval {
        (now / period).rounded(.down) * period
    }
}

public enum DSSpinnerKind: Sendable {
    /// Operações do app: `textSecondary`, traço 1,5 (pequeno) ou 2.
    case neutral
    /// Só o estado `working` de agente: anel de 2 pt `agentWorking`.
    case agentWorking
}

/// View AppKit do spinner: `CAShapeLayer` com `CAKeyframeAnimation` discreta. Pausa fora de vista (janela oculta/oclusa,
/// view escondida ou sem janela) removendo a animação; Reduce Motion mostra o anel completo, parado (04 §2).
@MainActor
public final class DSSpinnerNSView: NSView {
    public let ring = CAShapeLayer()
    public static let animationKey = "ds.spinner"
    private var observers: [NSObjectProtocol] = []
    private var kind: DSSpinnerKind = .neutral
    private var lineWidth: CGFloat = 2
    public private(set) var reduceMotionOverride: Bool?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(ring)
        ring.fillColor = nil
        ring.lineCap = .butt
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public func configure(kind: DSSpinnerKind, lineWidth: CGFloat, reduceMotion: Bool? = nil) {
        self.kind = kind
        self.lineWidth = lineWidth
        reduceMotionOverride = reduceMotion
        ring.strokeColor = (kind == .agentWorking ? DS.ColorSpec.agentWorking : DS.ColorSpec.textSecondary).nsColor.cgColor
        ring.lineWidth = lineWidth
        needsLayout = true
        updateRunning()
    }

    public override func layout() {
        super.layout()
        ring.frame = bounds
        let inset = lineWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let path = CGMutablePath()
        // Topo transparente: começa às 12h e cobre 270° no sentido horário.
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: min(rect.width, rect.height) / 2,
                    startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi * DSSpinnerSpec.arcFraction, clockwise: true)
        ring.path = path
        ring.strokeEnd = 1
        updateRunning()
    }

    public var isReduceMotion: Bool { reduceMotionOverride ?? MotionPolicy.shared.reduceMotion }

    /// Visível de fato: na janela, janela visível (não oclusa) e sem ancestral escondido.
    public var isInView: Bool {
        guard let window, !isHiddenOrHasHiddenAncestor else { return false }
        return window.occlusionState.contains(.visible) && window.isVisible
    }

    public var isAnimating: Bool { ring.animation(forKey: Self.animationKey) != nil }

    public func updateRunning() {
        if isReduceMotion {
            // Anel completo parado (04 §2): sem rotação nem recorte do topo.
            ring.removeAnimation(forKey: Self.animationKey)
            ring.strokeEnd = 1
            return
        }
        if isInView {
            if !isAnimating { ring.add(Self.makeAnimation(layer: ring), forKey: Self.animationKey) }
        } else {
            ring.removeAnimation(forKey: Self.animationKey)
        }
    }

    static func makeAnimation(layer: CALayer) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        a.values = DSSpinnerSpec.stepAngles
        a.calculationMode = .discrete
        a.duration = DSSpinnerSpec.period
        a.repeatCount = .infinity
        a.isRemovedOnCompletion = false
        a.beginTime = layer.convertTime(DSSpinnerSpec.globalBeginTime(now: CACurrentMediaTime()), from: nil)
        let fps = Float(DSSpinnerSpec.fps)
        a.preferredFrameRateRange = CAFrameRateRange(minimum: fps, maximum: fps, preferred: fps)
        return a
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        if let window {
            let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateRunning() }
                })
            }
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.updateRunning() } })
        }
        updateRunning()
    }

    public override func viewDidHide() { super.viewDidHide(); updateRunning() }
    public override func viewDidUnhide() { super.viewDidUnhide(); updateRunning() }
}

struct DSSpinnerRepresentable: NSViewRepresentable {
    let kind: DSSpinnerKind
    let lineWidth: CGFloat
    let reduceMotion: Bool?

    func makeNSView(context: Context) -> DSSpinnerNSView {
        let v = DSSpinnerNSView(frame: .zero)
        v.configure(kind: kind, lineWidth: lineWidth, reduceMotion: reduceMotion)
        return v
    }
    func updateNSView(_ v: DSSpinnerNSView, context: Context) {
        v.configure(kind: kind, lineWidth: lineWidth, reduceMotion: reduceMotion)
    }
}

/// Spinner (02 §12.22): operações do app (`.neutral`) ou estado `working` do agente (`.agentWorking`).
/// Aparece só depois de `delay.spinnerShow` (0,15 s) quando `delayed` (04 princípio 9).
public struct DSSpinner: View {
    private let size: CGFloat
    private let kind: DSSpinnerKind
    private let delayed: Bool
    private let reduceMotion: Bool?
    @State private var shown: Bool

    public init(kind: DSSpinnerKind = .neutral, size: CGFloat = 16, delayed: Bool = true, reduceMotion: Bool? = nil) {
        self.kind = kind
        self.size = size
        self.delayed = delayed
        self.reduceMotion = reduceMotion
        _shown = State(initialValue: !delayed)
    }

    private var lineWidth: CGFloat { size <= 12 ? MotionTokens.Stroke.liveBorder : MotionTokens.Stroke.ring }

    public var body: some View {
        DSSpinnerRepresentable(kind: kind, lineWidth: lineWidth, reduceMotion: reduceMotion)
            .frame(width: size, height: size)
            .opacity(shown ? 1 : 0)
            .task {
                guard !shown else { return }
                try? await Task.sleep(for: .seconds(MotionTokens.Delay.spinnerShow))
                shown = true
            }
            .accessibilityHidden(true)
    }
}
