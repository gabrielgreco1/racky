import AppKit
import SwiftUI
import Testing

@testable import RackyDesignSystem

/// M-101/M-102 variante A (04 §7.1.1): amostras puras contra a tabela de quadros e a geometria do protótipo.
@MainActor
@Suite(.offscreenAppKit) struct OverlayMotionTests {
    private func near(_ a: Double, _ b: Double, _ tol: Double = 0.02) -> Bool { abs(a - b) <= tol }

    @Test func enterFramesMatchTheSpecTable() {
        // (t ms, scrim, opacidade do cartão, escala, offset em pt)
        let rows: [(Double, Double, Double, Double, Double)] = [
            (33, 0.19, 0.61, 0.981, 4.7), (67, 0.41, 0.86, 0.993, 1.7), (100, 0.51, 0.95, 0.998, 0.6), (150, 0.55, 0.99, 1.0, 0.1),
        ]
        for (ms, scrim, opacity, scale, offset) in rows {
            let s = OverlayMotion.enter(at: ms / 1000, reduceMotion: false)
            #expect(near(s.scrim, scrim, 0.03), "scrim @\(ms)")
            #expect(near(s.cardOpacity, opacity, 0.03), "opacity @\(ms)")
            #expect(near(s.cardScale, scale, 0.004), "scale @\(ms)")
            #expect(near(s.offsetFraction * OverlayMotion.offset, offset, 0.4), "offset @\(ms)")
        }
        let end = OverlayMotion.enter(at: 0.2, reduceMotion: false)
        #expect(end.cardOpacity == 1 && end.cardScale == 1 && end.offsetFraction == 0)
    }

    @Test func exitFramesMatchTheSpecTable() {
        // O scrim segue o protótipo aprovado (`0,55 × (1 − ease(t / 0,15))`), não a coluna de scrim da tabela de 04 §7.1.1,
        // que não bate com o texto da própria seção ("scrim 0,55 → 0 `ease` em 0,15").
        let rows: [(Double, Double, Double, Double)] = [(50, 0.23, 0.84, 0.997), (100, 0.04, 0.49, 0.990), (150, 0, 0, 0.980)]
        for (ms, scrim, opacity, scale) in rows {
            let s = OverlayMotion.exit(at: ms / 1000, reduceMotion: false)
            #expect(near(s.scrim, scrim, 0.02), "scrim @\(ms)")
            #expect(near(s.cardOpacity, opacity, 0.05), "opacity @\(ms)")
            #expect(near(s.cardScale, scale, 0.004), "scale @\(ms)")
        }
    }

    @Test func reduceMotionIsACrossfadeWithoutScaleOrOffset() {
        for t in stride(from: 0.0, through: 0.15, by: 0.03) {
            let s = OverlayMotion.enter(at: t, reduceMotion: true)
            #expect(s.cardScale == 1 && s.offsetFraction == 0)
            #expect(near(s.cardOpacity, MotionTokens.Easing.ease.value(at: t / MotionTokens.Policy.reducedCrossfade), 1e-9))
        }
        #expect(OverlayMotion.enter(at: MotionTokens.Policy.reducedCrossfade, reduceMotion: true).scrim == MotionTokens.Opacity.scrim)
    }

    @Test func tokensAreTheSameAsThePrototype() {
        #expect(OverlayMotion.scrimMax == 0.55)
        #expect(OverlayMotion.enterDuration == 0.2 && OverlayMotion.exitDuration == 0.15 && OverlayMotion.scrimDuration == 0.15)
        #expect(OverlayMotion.offset == 12 && OverlayMotion.stagger == 0.035)
        #expect(MotionTokens.Scale.dialogFrom == 0.95 && MotionTokens.Scale.exitTo == 0.98)
        #expect(OverlayMotion.groupDelay(index: 0) == 0.035 && near(OverlayMotion.groupDelay(index: 2), 0.105, 1e-9))
    }

    @Test func originAnchorIsTheVectorIntersectionWithTheCardEdge() {
        // Cartão 560×400 centrado em (720, 450); botão no canto superior esquerdo da janela.
        let o = OverlayMotion.origin(cardSize: CGSize(width: 560, height: 400), cardCenter: CGPoint(x: 720, y: 450), originCenter: CGPoint(x: 100, y: 18))
        #expect(o.direction.dx < 0 && o.direction.dy < 0)
        let len = (o.direction.dx * o.direction.dx + o.direction.dy * o.direction.dy).squareRoot()
        #expect(near(len, 1, 1e-9))
        // A âncora está na borda do cartão (x = 0 ou y = 0 em unidades) e dentro do retângulo.
        #expect(o.anchor.x == 0 || o.anchor.y == 0)
        #expect(o.anchor.x >= 0 && o.anchor.y >= 0 && o.anchor.x <= 1 && o.anchor.y <= 1)
        let none = OverlayMotion.origin(cardSize: CGSize(width: 560, height: 400), cardCenter: .zero, originCenter: nil)
        #expect(none.anchor == .center && none.direction == .zero)
    }
}

@MainActor
@Suite(.offscreenAppKit) struct ComponentSpecTests {
    @Test func spinnerIsTwelveDiscreteStepsOneTurnPerSecondAtMostTwelveFps() {
        #expect(DSSpinnerSpec.steps == 12 && DSSpinnerSpec.period == 1 && DSSpinnerSpec.fps <= 12)
        #expect(DSSpinnerSpec.stepAngles.count == 12)
        // Fase global: dois instantes no mesmo segundo dão o mesmo começo.
        #expect(DSSpinnerSpec.globalBeginTime(now: 105.2) == DSSpinnerSpec.globalBeginTime(now: 105.9))
    }

    @Test func spinnerAnimationIsDiscreteAndPausesOutOfView() {
        let view = DSSpinnerNSView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        view.configure(kind: .neutral, lineWidth: 2, reduceMotion: false)
        // Sem janela = fora de vista: sem animação (nenhum custo de CA).
        #expect(!view.isAnimating)
        let a = DSSpinnerNSView.makeAnimation(layer: view.ring)
        #expect(a.calculationMode == .discrete && a.duration == 1 && a.repeatCount == .infinity)
        #expect((a.values?.count ?? 0) == 12)
        #expect((a.preferredFrameRateRange.maximum) <= 12)
        view.configure(kind: .agentWorking, lineWidth: 2, reduceMotion: true)
        #expect(!view.isAnimating, "Reduce Motion: anel completo parado")
    }

    @Test func buttonColorsFollowTheVariantTable() {
        typealias C = DS.ColorSpec
        #expect(DSButtonColors.resolve(.primary, state: .rest).background == C.primary)
        #expect(DSButtonColors.resolve(.primary, state: .hover).background.alpha == 0.9)
        #expect(DSButtonColors.resolve(.primary, state: .pressed).background.alpha == 0.84)
        #expect(DSButtonColors.resolve(.primary, state: .rest).foreground == C.textOnPrimary)
        #expect(DSButtonColors.resolve(.outline, state: .rest).border == C.input)
        #expect(DSButtonColors.resolve(.destructive, state: .hover).foreground.hex == 0xffffff)
        #expect(DSButtonSize.xs.height == 24 && DSButtonSize.sm.height == 32 && DSButtonSize.regular.height == 36 && DSButtonSize.lg.height == 40)
    }
}
