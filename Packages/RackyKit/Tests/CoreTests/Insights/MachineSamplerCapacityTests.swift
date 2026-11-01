import Foundation
import Synchronization
import Testing
@testable import RackyCore

/// T2-11: a capacidade do volume custa uma ida e volta XPC síncrona (CacheDelete); o amostrador a relê só a cada 30 s.
@Suite struct MachineSamplerCapacityTests {
    final class Calls: Sendable {
        private let n = Mutex(0)
        func bump() { n.withLock { $0 += 1 } }
        var count: Int { n.withLock { $0 } }
    }

    @Test func readsTheVolumeOncePerThirtySecondsNotPerTick() async {
        let calls = Calls()
        let sampler = MachineSampler(capacityReader: { calls.bump(); return (1_000_000, 400_000) })
        let t0 = Date()
        for i in 0 ..< 20 { _ = await sampler.sample(now: t0.addingTimeInterval(Double(i) * 1.5), includeProcesses: false) }  // 30 s de ticks de 1,5 s
        #expect(calls.count == 1, "20 ticks em 28,5 s: uma leitura só")
        let later = await sampler.sample(now: t0.addingTimeInterval(61), includeProcesses: false)
        #expect(calls.count == 2 && later.disk?.freeBytes == 400_000 && later.disk?.totalBytes == 1_000_000)
    }

    @Test func processListIsEnumeratedEveryThreeSecondsNotEveryTick() async {
        let sampler = MachineSampler(capacityReader: { (1, 1) })
        let t0 = Date()
        for i in 0 ..< 5 { _ = await sampler.sample(now: t0.addingTimeInterval(Double(i) * 1.5), includeProcesses: true) }  // 0, 1.5, 3, 4.5, 6 s
        #expect(await sampler.processReads == 3, "leituras em 0, 3 e 6 s")
    }
}
