import RackyDesignSystem
import RackyProtocol
import AppKit
import QuartzCore
import SwiftUI

/// Cápsula de 24 pt (logo do agente + nome) que sai do botão "Create Session" e voa até a linha pendente da sidebar (M-501).
struct LaunchChipView: View {
    let provider: TerminalProvider
    let title: String

    var body: some View {
        HStack(spacing: DS.Space.s1_5) {
            DSAgentLogo(DSAgentKind(provider), size: DS.Space.s3)
            Text(verbatim: title)
                .dsFont(DS.Font.small)
                .foregroundStyle(DS.Color.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, DS.Space.s2)
        .frame(height: DS.Space.s6)
        .background(Capsule().fill(DS.Color.chrome))
        .overlay(Capsule().strokeBorder(DS.Color.borderStrong))
        .accessibilityHidden(true)
    }
}

/// Hosting view que nunca captura o mouse (o chip é só desenho por cima da janela).
private final class PassthroughHostingView: NSHostingView<LaunchChipView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Voo do chip (M-501, 0,42 s): x com `standard`, y com `expoOut`, arco de `arcLift` e escala 1 → 0,85; pouso com `clickRing`.
/// Sem animação com Reduce Motion (a linha pendente aparece em fade, sem chip). Tudo é `CAAnimation` na layer da janela.
@MainActor
enum LaunchChipFlight {
    /// `from` e `to` em coordenadas da janela com y do topo (o espaço de `UIElementStore.frame(of:)`).
    static func play(in window: NSWindow, from: CGRect, to: CGRect, provider: TerminalProvider, title: String, completion: (@MainActor () -> Void)? = nil) {
        guard !MotionPolicy.shared.reduceMotion, MotionPolicy.shared.mode != .instant, let content = window.contentView else {
            completion?()
            return
        }
        let host = PassthroughHostingView(rootView: LaunchChipView(provider: provider, title: title))
        host.safeAreaRegions = []
        let size = host.fittingSize
        host.frame = CGRect(origin: .zero, size: size)
        host.wantsLayer = true
        content.addSubview(host, positioned: .above, relativeTo: nil)

        let height = content.bounds.height
        func center(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: height - rect.midY) }
        let start = center(from)
        // Pouso sobre o logo da linha (à esquerda), não no meio dela.
        let end = CGPoint(x: to.minX + size.width / 2 + DS.Space.s2, y: height - to.midY)
        host.frame.origin = CGPoint(x: end.x - size.width / 2, y: end.y - size.height / 2)
        guard let layer = host.layer else { host.removeFromSuperview(); completion?(); return }
        layer.position = end

        let duration = MotionTokens.Duration.flight
        let x = CABasicAnimation(keyPath: "position.x")
        x.fromValue = start.x; x.toValue = end.x
        x.timingFunction = Motion.caTiming(MotionTokens.Easing.standard)
        let y = CABasicAnimation(keyPath: "position.y")
        y.fromValue = start.y; y.toValue = end.y
        y.timingFunction = Motion.caTiming(MotionTokens.Easing.expoOut)
        let arc = CAKeyframeAnimation(keyPath: "position.y")
        arc.values = [0, MotionTokens.Distance.arcLift, 0]
        arc.keyTimes = [0, 0.5, 1]
        arc.isAdditive = true
        arc.calculationMode = .cubic
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1; scale.toValue = 0.85
        scale.timingFunction = Motion.caTiming(MotionTokens.Easing.standard)
        let group = CAAnimationGroup()
        group.animations = [x, y, arc, scale]
        group.duration = duration
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                ring(in: content, at: end)
                host.removeFromSuperview()
                completion?()
            }
        }
        layer.add(group, forKey: "launchChip.flight")
        CATransaction.commit()
    }

    /// `clickRing` de 16 pt que sai do logo no pouso (0,46 s, escala 0,4 → 1,4, opacidade 0,9 → 0).
    private static func ring(in content: NSView, at point: CGPoint) {
        guard let root = content.layer else { return }
        let size = DS.Space.s4
        let layer = CAShapeLayer()
        layer.frame = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
        layer.path = CGPath(ellipseIn: layer.bounds, transform: nil)
        layer.fillColor = nil
        layer.strokeColor = DS.ColorSpec.ring.nsColor.cgColor
        layer.lineWidth = MotionTokens.Stroke.liveBorder
        layer.opacity = 0
        root.addSublayer(layer)
        let ring = MotionTokens.Keyframes.clickRing
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = ring.tracks["scale"]?.first?.first ?? 0.4
        scale.toValue = ring.tracks["scale"]?.first?.last ?? 1.4
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = ring.tracks["opacity"]?.first?.first ?? 0.9
        fade.toValue = ring.tracks["opacity"]?.first?.last ?? 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = ring.duration ?? MotionTokens.Duration.ripple
        group.timingFunction = Motion.caTiming(MotionTokens.Easing.cssEaseOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { layer.removeFromSuperlayer() }
        layer.add(group, forKey: "launchChip.ring")
        CATransaction.commit()
    }
}
