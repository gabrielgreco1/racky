import RackyDesignSystem
import AppKit
import QuartzCore
import SwiftUI

/// Hospeda o painel direito e faz o motion M-108 (04 §6): o painel abre e fecha por recorte a partir da borda que encosta no
/// conteúdo (a esquerda); o conteúdo não desliza. Com Reduce Motion vira crossfade de 0,15 s. A largura do split muda uma vez
/// só, fora desta view (no primeiro quadro da abertura, no último do fechamento), então o terminal sofre um único resize.
@MainActor
final class RightPanelHostView: NSView {
    let hosting: ChromeHostingView
    private let maskLayer = CALayer()
    private static let animationKey = "rightPanel.reveal"
    /// Entre `prepareReveal` e `reveal`: o recorte fica em largura 0 mesmo que o layout rode no meio.
    private var holdingHidden = false

    init(content: some View) {
        hosting = ChromeHostingView(content: content)
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(hosting)
        maskLayer.backgroundColor = NSColor.black.cgColor
        maskLayer.anchorPoint = CGPoint(x: 0, y: 0.5)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }  // required init?(coder:) não usado

    override func layout() {
        super.layout()
        hosting.frame = bounds
        if layer?.mask != nil, !holdingHidden, maskLayer.animation(forKey: Self.animationKey) == nil { fitMask(width: bounds.width) }
    }

    private func fitMask(width: CGFloat) {
        maskLayer.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        maskLayer.position = CGPoint(x: 0, y: bounds.height / 2)
    }

    /// Esconde o painel antes de o split expandi-lo (sem piscar o conteúdo inteiro no primeiro quadro).
    func prepareReveal(reduceMotion: Bool) {
        guard let layer else { return }
        layer.removeAllAnimations()
        holdingHidden = true
        if reduceMotion {
            layer.opacity = 0
        } else {
            layer.mask = maskLayer
            fitMask(width: 0)
        }
    }

    func reveal(reduceMotion: Bool, duration: CFTimeInterval, timing: CAMediaTimingFunction, completion: @escaping @MainActor () -> Void = {}) {
        holdingHidden = false
        guard let layer else { return completion() }
        if reduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = MotionTokens.Policy.reducedCrossfade
            fade.timingFunction = Motion.caTiming(MotionTokens.Easing.ease)
            layer.opacity = 1
            layer.add(fade, forKey: Self.animationKey)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(MotionTokens.Policy.reducedCrossfade))
                completion()
            }
            return
        }
        let width = bounds.width
        layer.mask = maskLayer
        fitMask(width: width)
        let grow = CABasicAnimation(keyPath: "bounds.size.width")
        grow.fromValue = 0
        grow.toValue = width
        grow.duration = duration
        grow.timingFunction = timing
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                self?.layer?.mask = nil
                completion()
            }
        }
        maskLayer.add(grow, forKey: Self.animationKey)
        CATransaction.commit()
    }

    func conceal(reduceMotion: Bool, duration: CFTimeInterval, timing: CAMediaTimingFunction, completion: @escaping @MainActor () -> Void) {
        guard let layer else { return completion() }
        if reduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = MotionTokens.Policy.reducedCrossfade
            fade.timingFunction = Motion.caTiming(MotionTokens.Easing.ease)
            layer.opacity = 0
            layer.add(fade, forKey: Self.animationKey)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(MotionTokens.Policy.reducedCrossfade))
                completion()
                layer.opacity = 1
            }
            return
        }
        let width = bounds.width
        layer.mask = maskLayer
        fitMask(width: 0)
        let shrink = CABasicAnimation(keyPath: "bounds.size.width")
        shrink.fromValue = width
        shrink.toValue = 0
        shrink.duration = duration
        shrink.timingFunction = timing
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                completion()
                self?.layer?.mask = nil
            }
        }
        maskLayer.add(shrink, forKey: Self.animationKey)
        CATransaction.commit()
    }

    /// Sem animação: mostra tudo (estado restaurado na abertura do app, testes).
    func showInstantly() {
        holdingHidden = false
        layer?.removeAllAnimations()
        maskLayer.removeAllAnimations()
        layer?.mask = nil
        layer?.opacity = 1
    }
}
