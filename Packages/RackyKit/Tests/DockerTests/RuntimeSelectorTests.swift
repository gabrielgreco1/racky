import Foundation
import Testing

@testable import RackyDocker

/// Ordem de seleção do runtime dos computadores: macOS 26+ em Apple silicon usa o nativo; o resto, ou "Use Docker instead", usa o Docker.
@Suite struct RuntimeSelectorTests {
    private func version(_ major: Int) -> OperatingSystemVersion { OperatingSystemVersion(majorVersion: major, minorVersion: 0, patchVersion: 0) }

    @Test func macOS26OnAppleSiliconUsesTheNativeRuntime() {
        #expect(RuntimeSelector.choose(osVersion: version(26), appleSilicon: true, forceDocker: false) == .native)
        #expect(RuntimeSelector.choose(osVersion: version(27), appleSilicon: true, forceDocker: false) == .native)
    }

    @Test func olderMacOSOrIntelFallsBackToDocker() {
        #expect(RuntimeSelector.choose(osVersion: version(15), appleSilicon: true, forceDocker: false) == .docker)
        #expect(RuntimeSelector.choose(osVersion: version(25), appleSilicon: true, forceDocker: false) == .docker)
        #expect(RuntimeSelector.choose(osVersion: version(26), appleSilicon: false, forceDocker: false) == .docker)
    }

    @Test func theUserCanForceDockerAnywhere() {
        #expect(RuntimeSelector.choose(osVersion: version(26), appleSilicon: true, forceDocker: true) == .docker)
        #expect(RuntimeSelector.choose(osVersion: version(15), appleSilicon: true, forceDocker: true) == .docker)
    }

    @Test func aBuildWithoutTheNativeRuntimeUsesDocker() {
        #expect(RuntimeSelector.choose(osVersion: version(26), appleSilicon: true, forceDocker: false, nativeLinked: false) == .docker)
    }

    @Test func unavailableReasonsNameTheCause() {
        #expect(RuntimeSelector.nativeUnavailableReason(osVersion: version(26), appleSilicon: true) == nil)
        #expect(RuntimeSelector.nativeUnavailableReason(osVersion: version(15), appleSilicon: true)?.contains("macOS 26") == true)
        #expect(RuntimeSelector.nativeUnavailableReason(osVersion: version(26), appleSilicon: false)?.contains("Apple silicon") == true)
    }
}
