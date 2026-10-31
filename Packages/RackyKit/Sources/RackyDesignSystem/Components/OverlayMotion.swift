import SwiftUI

/// M-101 / M-102 (04 §6.3, §7.1.1), variante A aprovada: o cartão nasce do botão que abriu o overlay.
/// Tudo vem de `MotionTokens`; esta enumeração concentra a geometria (âncora, offset) e a amostragem pura que os testes
/// comparam com a tabela de quadros de 04 §7.1.1 e com o protótipo (`design/motion/prototypes/M-101-dialog`).
public enum OverlayMotion {
    /// Âncora da escala e direção do offset.
    public struct Origin: Equatable, Sendable {
        /// Interseção do vetor (centro do cartão → centro do botão) com a borda do cartão, em `UnitPoint`.
        public var anchor: UnitPoint
        /// Vetor unitário na direção do botão (zero quando não há origem).
        public var direction: CGVector
    }

    /// `v` = do centro do cartão até o centro do botão; âncora = interseção de `v` com a borda; direção = `v` normalizado.
    /// Sem botão de origem (ex.: aberto por teclado sem botão visível): centro e sem offset (04 §7.1.1).
    public static func origin(cardSize: CGSize, cardCenter: CGPoint, originCenter: CGPoint?) -> Origin {
        guard let originCenter, cardSize.width > 0, cardSize.height > 0 else {
            return Origin(anchor: .center, direction: .zero)
        }
        let vx = originCenter.x - cardCenter.x
        let vy = originCenter.y - cardCenter.y
        let length = (vx * vx + vy * vy).squareRoot()
        guard length > 0 else { return Origin(anchor: .center, direction: .zero) }
        let k = min((cardSize.width / 2) / abs(vx), (cardSize.height / 2) / abs(vy))
        let ax = cardSize.width / 2 + vx * k
        let ay = cardSize.height / 2 + vy * k
        return Origin(anchor: UnitPoint(x: ax / cardSize.width, y: ay / cardSize.height), direction: CGVector(dx: vx / length, dy: vy / length))
    }

    /// Amostra do cartão e do scrim.
    public struct Sample: Equatable, Sendable {
        public var scrim: Double
        public var cardOpacity: Double
        public var cardScale: Double
        /// Fração do offset inicial restante (1 → 0); multiplicar por `Distance.medium` e pela direção.
        public var offsetFraction: Double
    }

    public static var scrimMax: Double { MotionTokens.Opacity.scrim }
    public static var enterDuration: Double { MotionTokens.Duration.base }
    public static var exitDuration: Double { MotionTokens.Duration.fast }
    public static var scrimDuration: Double { MotionTokens.Duration.fast }
    public static var offset: Double { MotionTokens.Distance.medium }
    /// M-105 (menus e popovers): entrada 0,15 `standard`, saída 0,12 só com fade.
    public static var popoverEnterDuration: Double { MotionTokens.Duration.fast }
    public static var popoverExitDuration: Double { MotionTokens.Duration.hover }
    public static var stagger: Double { MotionTokens.Stagger.list }
    public static let groupCount = 3
    /// `M-101 end` (04 §7.1.1, f16 = 267 ms): todos os grupos assentados.
    public static let endTime = 0.267

    /// Entrada em `t` segundos desde o quadro 0 (M-101). Reduce Motion: crossfade `reducedCrossfade` sem escala nem offset.
    public static func enter(at t: Double, reduceMotion: Bool) -> Sample {
        if reduceMotion {
            let f = MotionTokens.Easing.ease.value(at: t / MotionTokens.Policy.reducedCrossfade)
            return Sample(scrim: scrimMax * f, cardOpacity: f, cardScale: 1, offsetFraction: 0)
        }
        let scrim = scrimMax * MotionTokens.Easing.ease.value(at: t / scrimDuration)
        let c = MotionTokens.Easing.standard.value(at: t / enterDuration)
        return Sample(scrim: scrim, cardOpacity: c, cardScale: lerp(MotionTokens.Scale.dialogFrom, 1, c), offsetFraction: 1 - c)
    }

    /// Saída em `t` segundos (M-102): cartão 1 → 0 com `exit` e escala 1 → 0,98; scrim 0,55 → 0 com `ease`.
    public static func exit(at t: Double, reduceMotion: Bool) -> Sample {
        if reduceMotion {
            let f = MotionTokens.Easing.ease.value(at: t / MotionTokens.Policy.reducedCrossfade)
            return Sample(scrim: scrimMax * (1 - f), cardOpacity: 1 - f, cardScale: 1, offsetFraction: 0)
        }
        let e = MotionTokens.Easing.exit.value(at: t / exitDuration)
        let scrim = scrimMax * (1 - MotionTokens.Easing.ease.value(at: t / scrimDuration))
        return Sample(scrim: scrim, cardOpacity: 1 - e, cardScale: lerp(1, MotionTokens.Scale.exitTo, e), offsetFraction: 0)
    }

    /// Progresso (0...1) do grupo `index` (0...2) de conteúdo em `t`: `standard` 0,20 com atraso `(index + 1) × stagger`.
    public static func groupProgress(index: Int, at t: Double) -> Double {
        MotionTokens.Easing.standard.value(at: (t - Double(index + 1) * stagger) / enterDuration)
    }

    /// Deslocamento vertical do grupo (4 pt → 0).
    public static func groupOffset(progress: Double) -> Double { (1 - progress) * MotionTokens.Distance.micro }

    /// Atraso do grupo `index` (0...2) na entrada.
    public static func groupDelay(index: Int) -> Double { Double(min(index, groupCount - 1) + 1) * stagger }

    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
}
