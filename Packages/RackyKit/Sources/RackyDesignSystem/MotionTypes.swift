import Foundation

/// Curva cubic-bezier (04 §3.3). Mesmo solver do `UnitBezier` do WebKit (Newton-Raphson com fallback de bissecção, ε = 1e-6),
/// a mesma família de `CAMediaTimingFunction` e `timingCurve` (04 §9.4).
nonisolated public struct Bezier: Sendable, Equatable {
    public let x1: Double
    public let y1: Double
    public let x2: Double
    public let y2: Double

    public init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
    }

    private var cx: Double { 3 * x1 }
    private var bx: Double { 3 * (x2 - x1) - cx }
    private var ax: Double { 1 - cx - bx }
    private var cy: Double { 3 * y1 }
    private var by: Double { 3 * (y2 - y1) - cy }
    private var ay: Double { 1 - cy - by }

    private func sampleX(_ t: Double) -> Double { ((ax * t + bx) * t + cx) * t }
    private func sampleY(_ t: Double) -> Double { ((ay * t + by) * t + cy) * t }
    private func sampleDX(_ t: Double) -> Double { (3 * ax * t + 2 * bx) * t + cx }

    private func solveT(forX x: Double, epsilon: Double = 1e-6) -> Double {
        var t = x
        for _ in 0..<8 {
            let err = sampleX(t) - x
            if abs(err) < epsilon { return t }
            let d = sampleDX(t)
            if abs(d) < 1e-6 { break }
            t -= err / d
        }
        var lo = 0.0
        var hi = 1.0
        t = x
        if t < lo { return lo }
        if t > hi { return hi }
        while lo < hi {
            let v = sampleX(t)
            if abs(v - x) < epsilon { return t }
            if x > v { lo = t } else { hi = t }
            t = (hi - lo) / 2 + lo
            if hi - lo < 1e-12 { break }
        }
        return t
    }

    /// Progresso (0...1) no instante normalizado `t` (0...1).
    public func value(at t: Double) -> Double {
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        return sampleY(solveT(forX: t))
    }
}

/// Spring no vocabulário do SwiftUI: `response` e `dampingFraction` (04 §3.4).
nonisolated public struct SpringSpec: Sendable, Equatable {
    public let response: Double
    public let dampingFraction: Double

    public init(response: Double, dampingFraction: Double) {
        self.response = response
        self.dampingFraction = dampingFraction
    }

    /// Rigidez para `CASpringAnimation` (massa 1): `(2π/response)²`.
    public var stiffness: Double { pow(2 * .pi / response, 2) }
    /// Amortecimento para `CASpringAnimation`: `2·ζ·(2π/response)`.
    public var damping: Double { 2 * dampingFraction * (2 * .pi / response) }
    /// Bounce de `CASpringAnimation(perceptualDuration:bounce:)`: `1 − dampingFraction`.
    public var bounce: Double { 1 - dampingFraction }

    /// Oscilador amortecido (velocidade inicial 0), `t` em segundos. `x(0) = 0`, `x(∞) = 1`.
    public func value(at t: Double) -> Double {
        if t <= 0 { return 0 }
        let w0 = 2 * .pi / response
        let z = dampingFraction
        if z >= 1 {
            return 1 - exp(-w0 * t) * (1 + w0 * t)
        }
        let wd = w0 * (1 - z * z).squareRoot()
        return 1 - exp(-z * w0 * t) * (cos(wd * t) + (z * w0 / wd) * sin(wd * t))
    }
}

/// Loop de `design/motion/tokens.json` (04 §3.6).
nonisolated public struct MotionLoop: Sendable, Equatable {
    public let period: Double
    public let fps: Double
    /// `global` (fase sincronizada) ou `instance`.
    public let phase: String
    /// Demais valores numéricos do token (`steps`, `periodRevoking`, `from`, `to`, `dash`, `scale`, `opacity`, `offset`).
    public let numbers: [String: [Double]]
    /// Valores textuais (`easing`).
    public let strings: [String: String]
}

/// Keyframes de `design/motion/tokens.json`. Cada trilha é uma lista de linhas: pares `[tempo, valor]`
/// (keyframes com tempo) ou uma linha `[de, para]`.
nonisolated public struct MotionKeyframe: Sendable, Equatable {
    public let duration: Double?
    public let easing: String?
    public let spring: String?
    public let tracks: [String: [[Double]]]
    public let scalars: [String: Double]
}
