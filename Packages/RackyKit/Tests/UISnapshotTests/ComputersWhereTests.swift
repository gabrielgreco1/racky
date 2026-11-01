import RackyCore
import RackyProtocol
import Foundation
import Testing

@testable import RackyDesignSystem
@testable import RackyUI

/// Página Computers › onde rodar (BK-12): local/nuvem, provedor, região, tetos, links e o padrão das sessões novas.
@MainActor
@Suite(.serialized, .offscreenAppKit) struct ComputersWhereTests {
    @Test func runOnProviderRegionAndLimitsGoThroughTheRegistry() async throws {
        let env = AppEnvironment(environment: ["RACKY_SKIP_ONBOARDING": "1"])
        let registry = env.registry
        #expect(env.settings.settings.computers.runOn == .local)
        _ = try await registry.perform(.computersRunOn, .select("cloud"))
        #expect(env.settings.settings.computers.runOn == .cloud)

        _ = try await registry.perform(.computersCloudRegion, .select("sa-east-1"))
        #expect(env.settings.settings.computers.cloud.region == "sa-east-1")
        await #expect(throws: (any Error).self) { _ = try await registry.perform(.computersCloudRegion, .select("mars-1")) }

        // Provedor "em breve" não é escolhido.
        await #expect(throws: (any Error).self) { _ = try await registry.perform(.computersCloudProvider, .select("hetzner")) }
        #expect(env.settings.settings.computers.cloud.provider == "aws")

        _ = try await registry.perform(.computersCloudLimits, .select("daily+"))
        #expect(env.settings.settings.computers.cloud.dailyCapUSD == 6)
        _ = try await registry.perform(.computersCloudLimits, .set("max=99"))
        #expect(env.settings.settings.computers.cloud.maxComputers == AppSettings.Cloud.maxComputersRange.upperBound)
        _ = try await registry.perform(.computersCloudLimits, .select("monthly-"))
        #expect(env.settings.settings.computers.cloud.monthlyCapUSD == 45, "passo de 5 até 50")

        // O Connect só fica desligado enquanto a sessão da AWS é conferida; entrando pelo navegador, clicar de novo cancela.
        #expect(env.settings.cloudConnection == .checking || registry.availability(of: .computersCloudConnect) == .enabled)

        var opened: [URL] = []
        env.settings.openURL = { opened.append($0) }
        _ = try await registry.perform(.computersCloudOpenLink, .select("pricing"))
        #expect(opened.first?.host == "aws.amazon.com")

        _ = try await registry.perform(.computersWhereToggle, .press)
        #expect(env.settings.computersWhereOpen)
    }

    @Test func useDockerInsteadIsDisabledWithoutTheNativeRuntimeAndToggleableWithIt() async throws {
        let env = AppEnvironment(environment: ["RACKY_SKIP_ONBOARDING": "1"])
        let registry = env.registry
        env.settings.runtimeInfo = ComputerRuntimeInfo(nativeAvailable: false, unavailableReason: "The built-in computer runtime needs macOS 26 or later. Computers use Docker.")
        #expect(registry.availability(of: .settingsComputersForceDocker) != .enabled)
        env.settings.runtimeInfo = ComputerRuntimeInfo(nativeAvailable: true, unavailableReason: nil)
        #expect(registry.availability(of: .settingsComputersForceDocker) == .enabled)
        #expect(env.settings.settings.computers.forceDocker == false)
        _ = try await registry.perform(.settingsComputersForceDocker, .set("on"))
        #expect(env.settings.settings.computers.forceDocker)
        _ = try await registry.perform(.settingsComputersForceDocker, .press)
        #expect(env.settings.settings.computers.forceDocker == false)
    }

    @Test func oldSettingsFilesDecodeWithLocalDefaultsAndClampedLimits() throws {
        let old = #"{"computers":{"defaultSubagentMode":"full"}}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(AppSettings.self, from: old)
        #expect(settings.computers.defaultSubagentMode == .full)
        #expect(settings.computers.runOn == .local)
        #expect(settings.computers.cloud == AppSettings.Cloud())
        let wild = #"{"computers":{"runOn":"cloud","cloud":{"dailyCapUSD":0,"maxComputers":1000}}}"#.data(using: .utf8)!
        let clamped = try JSONDecoder().decode(AppSettings.self, from: wild).computers
        #expect(clamped.runOn == .cloud)
        #expect(clamped.cloud.dailyCapUSD == AppSettings.Cloud.dailyCapRange.lowerBound)
        #expect(clamped.cloud.maxComputers == AppSettings.Cloud.maxComputersRange.upperBound)
    }

    @Test func everyProviderLogoShipsInTheBundle() {
        for provider in CloudProviderCatalog.all {
            #expect((DSAgentLogoImages.fileURL(provider.logo, scale: 3) != nil), "\(provider.logo) ausente em AgentLogos")
        }
        #expect((DSAgentLogoImages.fileURL("docker", scale: 3) != nil) && (DSAgentLogoImages.fileURL("github", scale: 3) != nil))
    }
}
