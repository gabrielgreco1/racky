import RackyCore
import RackyDocker
import RackyVZ
import Foundation

/// Qual runtime serve os computadores neste Mac, para a checklist do onboarding e o Diagnostics. Puro e injetável: a mesma decisão
/// do `AppComputerProvisioning` (macOS 26+, Apple silicon, build com o entitlement, sem `Use Docker instead`), sem tocar no Docker.
nonisolated enum ComputerRuntimeProbe {
    static func mode(
        environment: [String: String], supportRoot: URL, forceDocker: Bool,
        entitled: Bool = VZRuntime.processHasVirtualizationEntitlement(),
        osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        appleSilicon: Bool = RuntimeSelector.isAppleSilicon,
        assetsInstalled: (VZPaths) -> Bool = { $0.isInstalled }
    ) -> ComputerRuntimeMode {
        // Testes com Docker (RACKY_TEST_RUN) e RACKY_COMPUTER_RUNTIME=docker ficam sempre no Docker, como no provisionamento.
        if environment["RACKY_TEST_RUN"] != nil || environment["RACKY_COMPUTER_RUNTIME"] == "docker" { return .dockerForced }
        if let reason = RuntimeSelector.nativeUnavailableReason(osVersion: osVersion, appleSilicon: appleSilicon) {
            return .dockerOnly(reason: reason)
        }
        if !entitled { return .dockerOnly(reason: "This build of Racky isn't signed to run virtual machines.") }
        if forceDocker { return .dockerForced }
        return .native(assetsInstalled: assetsInstalled(VZPaths(appDataRoot: supportRoot)))
    }
}
