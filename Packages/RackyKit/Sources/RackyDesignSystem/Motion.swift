import AppKit
import QuartzCore
import SwiftUI

/// Motion (04 §3.8). Consome `MotionTokens` (gerado) e a política de Reduce Motion.
/// Nenhuma duração, curva ou spring é escrita à mão fora daqui e de `MotionTokens.generated.swift` (04 §3.1).
public enum Motion {
    public static func curve(_ e: Bezier, _ duration: Double) -> Animation {
        .timingCurve(e.x1, e.y1, e.x2, e.y2, duration: duration)
    }

    public static func spring(_ s: SpringSpec) -> Animation {
        .spring(response: s.response, dampingFraction: s.dampingFraction)
    }

    public static func caTiming(_ e: Bezier) -> CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: Float(e.x1), Float(e.y1), Float(e.x2), Float(e.y2))
    }

    public static func caSpring(_ s: SpringSpec) -> CASpringAnimation {
        let a = CASpringAnimation(perceptualDuration: s.response, bounce: s.bounce)
        return a
    }

    // Atalhos semânticos (um por papel, nunca por tela).
    public static var dialogIn: Animation { curve(MotionTokens.Easing.standard, MotionTokens.Duration.base) }
    public static var dialogOut: Animation { curve(MotionTokens.Easing.exit, MotionTokens.Duration.fast) }
    public static var menuIn: Animation { curve(MotionTokens.Easing.standard, MotionTokens.Duration.fast) }
    public static var hover: Animation { curve(MotionTokens.Easing.ease, MotionTokens.Duration.hover) }
    public static var press: Animation { curve(MotionTokens.Easing.ease, MotionTokens.Duration.press) }
    public static var disclosure: Animation { curve(MotionTokens.Easing.expoOut, MotionTokens.Duration.disclosure) }
    public static var selection: Animation { spring(MotionTokens.Springs.snappy) }
    /// Crossfade de Reduce Motion (04 §5).
    public static var reducedCrossfade: Animation {
        curve(MotionTokens.Easing.ease, MotionTokens.Policy.reducedCrossfade)
    }
}

/// Decisão pura (testável) de como uma animação se comporta sob a política (04 §5, `MotionPolicy.mode`).
nonisolated public enum MotionResolution: Sendable, Equatable {
    /// Sem animação (modo `.instant`).
    case none
    /// Mesma curva/spring, com a duração escalada (`.slow`, modo de teste e Motion Lab).
    case normal(durationScale: Double)
    /// Reduce Motion: translação, escala e recorte viram crossfade de `policy.reducedCrossfade`.
    case crossfade(duration: Double)
}

nonisolated public enum MotionMode: Sendable, Equatable {
    case normal
    case instant
    case slow(factor: Double)
}

nonisolated public enum ReduceMotionPreference: Sendable, Equatable {
    /// Settings › Appearance › Reduce motion = Follow System (padrão).
    case followSystem
    case on
}

nonisolated public enum MotionPolicyRules {
    /// OR do sistema com a preferência do app (04 §5).
    public static func reduceMotion(system: Bool, preference: ReduceMotionPreference) -> Bool {
        system || preference == .on
    }

    public static func resolve(reduceMotion: Bool, mode: MotionMode) -> MotionResolution {
        if case .instant = mode { return .none }
        if reduceMotion { return .crossfade(duration: MotionTokens.Policy.reducedCrossfade) }
        if case .slow(let factor) = mode { return .normal(durationScale: factor) }
        return .normal(durationScale: 1)
    }

    /// Teto de fps de loops: 30 normal, 15 em Low Power Mode (04 R6).
    public static func loopFpsCeiling(lowPower: Bool) -> Double {
        lowPower ? MotionTokens.Policy.loopMaxFpsLowPower : MotionTokens.Policy.loopMaxFps
    }

    /// fps efetivo de um loop (token limitado pelo teto).
    public static func loopFps(_ loop: MotionLoop, lowPower: Bool) -> Double {
        min(loop.fps, loopFpsCeiling(lowPower: lowPower))
    }
}

/// Estado de acessibilidade e energia que governa o motion (04 §3.8). Lê o sistema; Settings pode forçar `On`.
@MainActor @Observable
public final class MotionPolicy {
    public static let shared = MotionPolicy()

    public var preference: ReduceMotionPreference = .followSystem
    public var mode: MotionMode = .normal
    public private(set) var systemReduceMotion: Bool
    public private(set) var reduceTransparency: Bool
    public private(set) var lowPower: Bool

    public init() {
        systemReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    public var reduceMotion: Bool {
        MotionPolicyRules.reduceMotion(system: systemReduceMotion, preference: preference)
    }

    /// Relê o sistema. Chamado pelas notificações abaixo e pelos testes.
    public func refresh() {
        systemReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// Passa a observar mudanças de acessibilidade e de Low Power Mode. Idempotente por instância.
    public func startObserving() {
        guard observers.isEmpty else { return }
        let refresh: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main, using: refresh))
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main, using: refresh))
    }

    private var observers: [NSObjectProtocol] = []

    public var resolution: MotionResolution {
        MotionPolicyRules.resolve(reduceMotion: reduceMotion, mode: mode)
    }

    /// Animação de curva já filtrada pela política; `nil` = aplicar sem animar.
    public func animation(_ easing: Bezier, _ duration: Double) -> Animation? {
        switch resolution {
        case .none: return nil
        case .crossfade(let d): return Motion.curve(MotionTokens.Easing.ease, d)
        case .normal(let scale): return Motion.curve(easing, duration * scale)
        }
    }

    /// Animação de spring filtrada pela política; `nil` = aplicar sem animar.
    public func animation(_ spring: SpringSpec) -> Animation? {
        switch resolution {
        case .none: return nil
        case .crossfade(let d): return Motion.curve(MotionTokens.Easing.ease, d)
        case .normal(let scale):
            return Motion.spring(SpringSpec(response: spring.response * scale, dampingFraction: spring.dampingFraction))
        }
    }
}
