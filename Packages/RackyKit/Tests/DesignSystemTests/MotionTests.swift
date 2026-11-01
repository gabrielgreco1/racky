import Foundation
import QuartzCore
import SwiftUI
import Testing
@testable import RackyDesignSystem

@Suite(.offscreenAppKit) struct MotionTests {
    /// 04 §3.3: progresso a 60 fps para conferir protótipo e app quadro a quadro.
    @Test func bezierProgressMatchesSpecTables() {
        func check(_ b: Bezier, durationFrames n: Double, _ samples: [(Double, Double)], _ name: String) {
            for (frame, want) in samples {
                let got = b.value(at: frame / n)
                #expect(abs(got - want) < 0.01, "\(name) f\(Int(frame)): \(got) != \(want)")
            }
        }
        check(MotionTokens.Easing.standard, durationFrames: 12, [(2, 0.61), (4, 0.86), (6, 0.95), (8, 0.98), (12, 1.0)], "standard")
        check(MotionTokens.Easing.expoOut, durationFrames: 18, [(2, 0.53), (4, 0.79), (6, 0.90), (8, 0.96), (12, 0.99)], "expoOut")
        check(MotionTokens.Easing.exit, durationFrames: 9, [(2, 0.08), (4, 0.26), (6, 0.51), (8, 0.82), (9, 1.0)], "exit")
        check(MotionTokens.Easing.drawer, durationFrames: 13.2, [(2, 0.47), (4, 0.85), (6, 0.94), (8, 0.98), (13, 1.0)], "drawer")
    }

    @Test func bezierBoundariesAndLinear() {
        for (name, b) in MotionTokens.Easing.all {
            #expect(b.value(at: 0) == 0, "\(name)(0)")
            #expect(b.value(at: 1) == 1, "\(name)(1)")
        }
        let lin = MotionTokens.Easing.linear
        for i in 0...10 { #expect(abs(lin.value(at: Double(i) / 10) - Double(i) / 10) < 1e-5) }
    }

    /// 04 §3.4: progresso a 60 fps e constantes para Core Animation.
    @Test func springsMatchSpecTables() {
        let snappy = MotionTokens.Springs.snappy
        for (frame, want) in [(3.0, 0.33), (6, 0.72), (9, 0.92), (12, 0.99), (15, 1.004)] {
            #expect(abs(snappy.value(at: frame / 60) - want) < 0.01, "snappy f\(Int(frame))")
        }
        let lively = MotionTokens.Springs.lively
        for (frame, want) in [(6.0, 0.55), (12, 0.97), (18, 1.038), (30, 1.00)] {
            #expect(abs(lively.value(at: frame / 60) - want) < 0.01, "lively f\(Int(frame))")
        }
        #expect(abs(snappy.stiffness - 503.6) < 0.1)
        #expect(abs(snappy.damping - 38.6) < 0.1)
        #expect(abs(lively.stiffness - 246.7) < 0.1)
        #expect(abs(lively.damping - 22.6) < 0.1)
        #expect(abs(MotionTokens.Springs.drag.stiffness - 815.7) < 0.1)
        for (name, s) in MotionTokens.Springs.all {
            #expect(s.value(at: 0) == 0, "\(name)(0)")
            #expect(abs(s.value(at: 3) - 1) < 1e-6, "\(name) assenta em 1")
        }
    }

    @MainActor @Test func motionBuildersUseTokenValues() {
        let t = Motion.caTiming(MotionTokens.Easing.standard)
        var c1: [Float] = [0, 0]
        var c2: [Float] = [0, 0]
        t.getControlPoint(at: 1, values: &c1)
        t.getControlPoint(at: 2, values: &c2)
        #expect(c1 == [0.2, 0.8])
        #expect(c2 == [0.2, 1.0])
        let spring = Motion.caSpring(MotionTokens.Springs.snappy)
        #expect(spring.duration > 0)
    }

    // MARK: Reduce Motion (04 §5)

    @Test func reduceMotionIsOROfSystemAndPreference() {
        typealias R = MotionPolicyRules
        #expect(R.reduceMotion(system: false, preference: .followSystem) == false)
        #expect(R.reduceMotion(system: true, preference: .followSystem) == true)
        #expect(R.reduceMotion(system: false, preference: .on) == true)
        #expect(R.reduceMotion(system: true, preference: .on) == true)
    }

    @Test func resolutionFollowsReduceMotionAndMode() {
        typealias R = MotionPolicyRules
        #expect(R.resolve(reduceMotion: false, mode: .normal) == .normal(durationScale: 1))
        #expect(R.resolve(reduceMotion: true, mode: .normal) == .crossfade(duration: 0.15))
        #expect(R.resolve(reduceMotion: false, mode: .instant) == .none)
        #expect(R.resolve(reduceMotion: true, mode: .instant) == .none)
        #expect(R.resolve(reduceMotion: false, mode: .slow(factor: 4)) == .normal(durationScale: 4))
        #expect(R.resolve(reduceMotion: true, mode: .slow(factor: 4)) == .crossfade(duration: 0.15))
    }

    @Test func loopFpsIsCappedAndDropsInLowPower() {
        typealias R = MotionPolicyRules
        #expect(R.loopFpsCeiling(lowPower: false) == 30)
        #expect(R.loopFpsCeiling(lowPower: true) == 15)
        #expect(R.loopFps(MotionTokens.Loop.spinner, lowPower: true) == 12, "spinner continua a 12 em Low Power")
        #expect(R.loopFps(MotionTokens.Loop.liveBorder, lowPower: false) == 30)
        #expect(R.loopFps(MotionTokens.Loop.liveBorder, lowPower: true) == 15)
        for (name, l) in MotionTokens.Loop.all { #expect(l.fps <= 30, "\(name) <= 30 fps (R6)") }
    }

    @MainActor @Test func policyAppliesPreferenceAndMode() {
        let p = MotionPolicy()
        p.preference = .on
        #expect(p.reduceMotion)
        #expect(p.resolution == .crossfade(duration: 0.15))
        #expect(p.animation(MotionTokens.Easing.standard, 0.2) != nil)
        #expect(p.animation(MotionTokens.Springs.lively) != nil)
        p.mode = .instant
        #expect(p.resolution == .none)
        #expect(p.animation(MotionTokens.Easing.standard, 0.2) == nil)
        #expect(p.animation(MotionTokens.Springs.lively) == nil)
        p.mode = .normal
        p.preference = .followSystem
        p.refresh()
        #expect(p.reduceMotion == p.systemReduceMotion)
        p.startObserving()
        p.startObserving()
    }

    @Test func reducedCrossfadeTokensAreDefined() {
        #expect(MotionTokens.Policy.reducedCrossfade == 0.15)
        #expect(MotionTokens.Policy.maxUiDirect == 0.5)
        #expect(MotionTokens.Duration.fast == MotionTokens.Policy.reducedCrossfade)
    }
}
