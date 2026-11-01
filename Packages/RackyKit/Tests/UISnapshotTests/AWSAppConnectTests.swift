import RackyCore
import RackyDocker
import RackyProtocol
import AppKit
import Foundation
import SwiftUI
import Testing

@testable import RackyUI

/// O caminho da tela, de verdade e fora da tela do usuário: app sem janela (RACKY_HOME isolado), Your cloud + Ohio pelas ações,
/// `computers.cloud.connect` pelo registro (o mesmo que o botão "Connect AWS…" dispara), um computador pela fiação do app na AWS,
/// print da página com a VM ligada no Spending, Stop pela ação e nada vivo no fim. Só com `RACKY_AWS_LIVE=1` (custa centavos).
@MainActor
@Suite(.serialized, .offscreenAppKit, .enabled(if: ProcessInfo.processInfo.environment["RACKY_AWS_LIVE"] == "1")) struct AWSAppConnectTests {
    @Test(.timeLimit(.minutes(30))) func connectAWSFromThePageAndRunAComputer() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aws-app-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let env = AppEnvironment(environment: ["RACKY_SKIP_ONBOARDING": "1", "RACKY_HOME": home.path, "RACKY_TEST_HEADLESS": "1"])
        _ = try await env.registry.perform(.computersRunOn, .select("cloud"))
        _ = try await env.registry.perform(.computersCloudProvider, .select("aws"))
        _ = try await env.registry.perform(.computersCloudRegion, .select("us-east-2"))
        _ = try await env.registry.perform(.computersCloudLimits, .select("max=1"))

        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        var config = AppComputerProvisioning.Config(
            runtimeRoot: repo.appendingPathComponent("runtime", isDirectory: true), secretsRoot: home.appendingPathComponent("secrets", isDirectory: true),
            owner: "racky-live-app")
        config.network = ComputerProvisioner.defaultNetwork
        let stack = try #require(await env.makeCloudStack(root: home, config: config))

        // O clique: Connect AWS… (sessão do `aws login` já válida, então só confirma a conta).
        let answer = try await env.registry.perform(.computersCloudConnect, nil)
        print("connect: \(answer.ok) \(answer.message ?? "")")
        guard case .connected(let account) = env.settings.cloudConnection else {
            Issue.record("not connected: \(env.settings.cloudConnection)")
            return
        }
        #expect(!account.isEmpty)
        #expect(env.settings.settings.computers.cloud.acceptedAUP != nil)

        do {
            let spec = ComputerSpec(
                name: "app-connect", parent: "live-app", display: .headless, profile: nil, proxy: "direct", proxiesAllowed: [], allowHosts: [],
                batch: nil, run: RunFolder(root: home.appendingPathComponent("run", isDirectory: true)))
            try await stack.provisioning.preflight()
            let handle = try await stack.provisioning.provision(spec)
            let outcome = try await handle.backend.execRun(BackendExec(shell: "uname -m && echo from-the-app > /work/ok.txt && cat /work/ok.txt"), timeout: .seconds(60))
            let out = String(decoding: outcome.stdout, as: UTF8.self)
            print("computer said: \(out)")
            #expect(outcome.exitCode == 0 && out.contains("aarch64") && out.contains("from-the-app"))

            // A página como o usuário a vê agora: conta conectada e a VM ligada no Spending.
            env.settings.cloudSnapshot = await stack.snapshot()
            #expect(env.settings.cloudSnapshot.hosts.count == 1)
            let view = NSHostingView(rootView: ComputersPageView(controller: env.computers, settings: env.settings)
                .environment(\.actionRegistry, env.registry).environment(\.elementStore, env.elements).preferredColorScheme(.dark))
            view.frame = NSRect(x: 0, y: 0, width: 900, height: 2000)
            let window = OffscreenAppKit.makeWindow(size: view.frame.size)
            window.contentView = view
            try await Task.sleep(for: .milliseconds(900))
            if let dir = ProcessInfo.processInfo.environment["RACKY_CAPTURE_DIR"], let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("aws-app-connected.png"))
            }
            _ = window

            // Stop pela ação da linha da VM.
            await handle.teardown()
            let hostID = try #require(env.settings.cloudSnapshot.hosts.first?.id)
            _ = try await env.registry.perform(.computersCloudStopHost, .select(hostID))
            #expect(env.settings.cloudSnapshot.hosts.isEmpty)
        } catch {
            await stack.shutdown()
            throw error
        }
        await stack.shutdown()
        let owner = CloudKeys.installOwner(in: home.appendingPathComponent("cloud", isDirectory: true), base: "racky-live-app")
        let left = try await AWSProvider(cli: stack.cli).listHosts(tags: RackyTags.filter(owner: owner), regions: ["us-east-2"]).filter { $0.state.isLive }
        #expect(left.isEmpty)
        let records = await stack.snapshot().records
        print("cost records: \(records.map { "\($0.hostID) \($0.shape ?? "") \(String(format: "%.4f", $0.costUSD(now: Date())))" })")
        #expect(records.count == 1 && records.allSatisfy { $0.endedAt != nil })
    }
}
