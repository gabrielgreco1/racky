import Foundation
import RackyDocker
import Testing

@testable import RackyCore

/// Ponta a ponta na AWS de verdade (custa centavos): sobe um host t4g.medium na conta do perfil, abre o túnel, constrói a imagem no host,
/// sobe um computador, roda um comando nele, desmonta e encerra o host. Só com `RACKY_AWS_LIVE=1` (perfil em `RACKY_AWS_PROFILE`,
/// padrão `racky`; região em `RACKY_AWS_REGION`, padrão `us-east-2`).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["RACKY_AWS_LIVE"] == "1")) struct AWSLiveTests {
    @Test(.timeLimit(.minutes(30))) func hostComputerCommandAndCleanup() async throws {
        let env = ProcessInfo.processInfo.environment
        let region = env["RACKY_AWS_REGION"] ?? "us-east-2"
        let cli = AWSCLI(profile: env["RACKY_AWS_PROFILE"] ?? "racky")
        let identity = try await cli.identity()
        #expect(!identity.account.isEmpty)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aws-live-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let runtime = repo.appendingPathComponent("runtime", isDirectory: true)
        let owner = "racky-live-test"
        let keys = try await CloudKeys.load(in: root.appendingPathComponent("keys", isDirectory: true))
        let secrets = BoxSecretFiles(root: root.appendingPathComponent("secrets", isDirectory: true))
        let stack = CloudStack(
            cli: cli, owner: owner, root: root, keys: keys, runtimeRoot: runtime, caps: SpendCaps(dailyUSD: 3, monthlyUSD: 10), idleGrace: .seconds(5),
            settings: { (region, 1) }, regions: { [region] }, acceptedAUP: { _, _ in true },
            progress: { id, step in print("host \(id): \(step)") },
            make: { access in
                DockerComputerProvisioning(
                    client: access.client, image: (access as? ImagedHostAccess)?.imageTag ?? "", secrets: secrets, owner: owner, host: access)
            })

        do {
            try await stack.provisioning.preflight()
            let run = RunFolder(root: root.appendingPathComponent("run", isDirectory: true))
            let spec = ComputerSpec(
                name: "aws-live", parent: "live-test", display: .headless, profile: nil, proxy: "direct", proxiesAllowed: [], allowHosts: [],
                batch: nil, run: run)
            let handle = try await stack.provisioning.provision(spec)
            let outcome = try await handle.backend.execRun(BackendExec(shell: "uname -m && echo cloud-ok > /work/hi.txt && cat /work/hi.txt"), timeout: .seconds(60))
            let out = String(decoding: outcome.stdout, as: UTF8.self)
            print("computer said: \(out) | stderr: \(String(decoding: outcome.stderr, as: UTF8.self)) | exit \(outcome.exitCode ?? -1)")
            let probe = try await handle.backend.execRun(BackendExec(shell: "id; ls -ld /work; df -h /work | tail -1"), timeout: .seconds(30))
            print("probe: \(String(decoding: probe.stdout + probe.stderr, as: UTF8.self))")
            #expect(outcome.exitCode == 0)
            #expect(out.contains("aarch64"))
            #expect(out.contains("cloud-ok"))
            await handle.teardown()
        } catch {
            await stack.shutdown()
            throw error
        }
        await stack.shutdown()

        // Nada do dono continua vivo na conta, e o gasto ficou registrado e fechado.
        let left = try await AWSProvider(cli: cli).listHosts(tags: RackyTags.filter(owner: owner), regions: [region]).filter { $0.state.isLive }
        #expect(left.isEmpty)
        let snapshot = await stack.snapshot()
        #expect(snapshot.records.count >= 1)
        #expect(snapshot.records.allSatisfy { $0.endedAt != nil })
        print("cost records: \(snapshot.records.map { "\($0.hostID) \($0.shape ?? "") \(String(format: "%.4f", $0.costUSD(now: Date())))" })")
    }
}
