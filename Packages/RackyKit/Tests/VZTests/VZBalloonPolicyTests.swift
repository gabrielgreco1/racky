import Testing

@testable import RackyVZ

/// Balão ajustado (backlog 20): segue o uso real da VM, esvazia na hora e enche aos poucos.
@Suite struct VZBalloonPolicyTests {
    let mib: UInt64 = 1 << 20
    var configured: UInt64 { 3200 * mib }

    func info(totalMiB: UInt64 = 3056, availableMiB: UInt64) -> VZBalloonPolicy.MemInfo {
        .init(total: totalMiB * mib, available: availableMiB * mib)
    }

    @Test func meminfoIsParsed() {
        let parsed = VZBalloonPolicy.parse("MemTotal:        3129728 kB\nMemFree:          100 kB\nMemAvailable:    3012128 kB\n")
        let expected = VZBalloonPolicy.MemInfo(total: 3_129_728 * 1024, available: 3_012_128 * 1024)
        #expect(parsed == expected)
        #expect(VZBalloonPolicy.parse("garbage") == nil)
    }

    @Test func anIdleVMInflatesStepByStepDownToTheFloor() {
        var current = configured
        var steps = 0
        while true {
            let next = VZBalloonPolicy.next(current: current, configured: configured, info: info(availableMiB: 2900 - (configured - current) / mib))
            if next == current { break }
            #expect(current - next <= VZBalloonPolicy.maxInflateStep)
            current = next
            steps += 1
        }
        #expect(current == VZBalloonPolicy.floor)
        #expect(steps >= 4)
    }

    @Test func aSpikeDeflatesAtOnce() {
        let current: UInt64 = 1024 * mib
        // Balão com 2176 MiB; a VM ficou com só 100 MiB livres: o uso real subiu para ~780 MiB.
        let next = VZBalloonPolicy.next(current: current, configured: configured, info: info(availableMiB: 100))
        #expect(next > current)
        #expect(next == (3056 - 100 - 2176 + 512) * mib)
    }

    @Test func swappingCountsAsUseSoTheBalloonGivesMemoryBack() {
        let current: UInt64 = 800 * mib
        // Uso real 288 MiB + folga 512 = exatamente o tamanho atual: nada a mexer.
        var swapping = info(availableMiB: 3056 - 288 - (3200 - 800))
        #expect(VZBalloonPolicy.next(current: current, configured: configured, info: swapping) == current)
        swapping.swapUsed = 1500 * mib
        #expect(VZBalloonPolicy.next(current: current, configured: configured, info: swapping) == (288 + 1500 + 512) * mib)
        #expect(VZBalloonPolicy.parse("MemTotal: 10 kB\nMemAvailable: 5 kB\nSwapTotal: 100 kB\nSwapFree: 40 kB\n")?.swapUsed == 60 * 1024)
    }

    @Test func neverAboveWhatTheVMWasGivenAndIgnoresNoise() {
        #expect(VZBalloonPolicy.next(current: configured, configured: configured, info: info(availableMiB: 0)) == configured)
        let current: UInt64 = 1500 * mib
        let steady = info(availableMiB: 3056 - (1500 - 512 - 50) - (3200 - 1500))
        #expect(VZBalloonPolicy.next(current: current, configured: configured, info: steady) == current)
    }
}
