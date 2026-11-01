import RackyPlatform
import Foundation
import Testing

@testable import RackyDocker

/// BK-12 com o Docker REAL (`RACKY_TEST_DOCKER=1`): o `DockerClient` por um socket encaminhado (proxy local até o socket real, sem
/// sshd e sem nuvem), exec com hijack, eventos, a API de arquivo, volumes semeados e a volta de `/work` ao Mac.
/// Só toca em recursos com `racky.test=1` + `test_run` (a limpeza é por esses labels).
@Suite("BK-12 - host remoto simulado sobre o Docker real", .serialized, .enabled(if: Live.enabled), .tags(.integration), .timeLimit(.minutes(5)))
struct LiveRemoteHostTests {
    private func tunnel(for env: LiveEnv) async throws -> (SSHTunnel, TunnelFixture, ForwardingTunnelRunner) {
        let fixture = try TunnelFixture()
        let runner = ForwardingTunnelRunner(targetSocket: env.runtime.runtime.socketPath)
        let tunnel = try SSHTunnel(endpoint: fixture.endpoint, directory: fixture.tunnelDirectory, runner: runner)
        try await tunnel.start()
        return (tunnel, fixture, runner)
    }

    @Test func engineApiExecEventsAndArchiveWorkThroughTheForwardedSocket() async throws {
        try await Live.with { env in
            let (tunnel, fixture, _) = try await tunnel(for: env)
            defer { fixture.cleanup() }
            let remote = tunnel.client
            try await remote.ping()
            #expect(try await remote.version().version == env.runtime.version.version)

            // eventos pelo túnel enquanto criamos o container
            let events = Task { () -> [String] in
                var seen: [String] = []
                for try await event in try await remote.events(filters: ["label": env.labelFilter]) {
                    seen.append(event.baseAction)
                    if event.baseAction == "start" { break }
                }
                return seen
            }
            try await Task.sleep(for: .milliseconds(300))
            // rootfs é somente leitura e /tmp é tmpfs (a API de arquivo não alcança): usa um volume.
            let volume = env.name("data")
            _ = try await remote.createVolume(name: volume, labels: env.baseLabels)
            var spec = env.spec("tunnel")
            spec.named = ["\(volume):/data"]
            let id = try await remote.createContainer(spec)
            try await remote.startContainer(id)
            let seen = try await events.value
            #expect(seen.contains("create") || seen.contains("start"))

            // exec com hijack: stdin com half-close, stdout/stderr separados, código de saída
            let result = try await remote.run(in: id, command: ["sh", "-c", "cat; echo err >&2; exit 4"], stdin: Data("hello".utf8), killableGroup: false)
            #expect(result.stdoutString == "hello" && result.stderrString == "err\n" && result.exitCode == 4)

            // arquivo: PUT e GET pelo mesmo caminho
            try await remote.putArchive(id, path: "/data", tar: TarArchive.create(entries: [TarEntry(path: "note.txt", data: Data("from-mac".utf8), mode: 0o644)]))
            let dest = fixture.directory.appendingPathComponent("pulled", isDirectory: true)
            let report = try await RunFileSync(client: remote).pull(container: id, remotePath: "/data", into: dest)
            #expect(report.files >= 1)
            #expect(try String(contentsOf: dest.appendingPathComponent("note.txt"), encoding: .utf8) == "from-mac")
            await tunnel.stop()
        }
    }

    @Test func seededVolumesGiveTheAgentWritableWorkAndReadOnlySecretsAndWorkComesBackToTheRunFolder() async throws {
        try await Live.with { env in
            let (tunnel, fixture, _) = try await tunnel(for: env)
            defer { fixture.cleanup() }
            let remote = tunnel.client
            let computerID = "c-\(env.runID)"
            let volumes = RemoteStorageSeeder.Volumes(computerID: computerID)
            for name in [volumes.work, volumes.logs, volumes.secrets] { _ = try await remote.createVolume(name: name, labels: env.baseLabels) }
            let labels = ComputerLabels(owner: "test-\(env.runID)", computerID: computerID, computerName: "t", isTest: true)
            try await RemoteStorageSeeder(client: remote).seed(
                volumes: volumes, labels: labels, image: Live.alpine, secretFiles: ["API_KEY": Data("s3cret".utf8)], agentUID: 10001, egressUID: 10003,
                extraLabels: ["racky.test_run": env.runID])

            var spec = env.spec("agent")
            spec.user = "10001"
            spec.named = ["\(volumes.work):/work", "\(volumes.secrets):/run/abx-secrets:ro", "\(volumes.logs):/run/racky/logs"]
            let id = try await remote.createContainer(spec)
            try await remote.startContainer(id)

            let stat = try await remote.run(in: id, command: ["stat", "-c", "%u:%g:%a", "/work", "/run/abx-secrets", "/run/abx-secrets/API_KEY", "/run/racky/logs"])
            #expect(stat.stdoutString.split(separator: "\n").map(String.init) == ["10001:10001:755", "10001:10001:500", "10001:10001:400", "10003:10003:755"])
            let read = try await remote.run(in: id, command: ["cat", "/run/abx-secrets/API_KEY"])
            #expect(read.stdoutString == "s3cret")
            let writeSecret = try await remote.run(in: id, command: ["sh", "-c", "echo x > /run/abx-secrets/other"])
            #expect(writeSecret.exitCode != 0, "segredos são somente leitura para o agente")
            let write = try await remote.run(in: id, command: ["sh", "-c", "mkdir -p /work/out && echo 'a,b' > /work/out/result.csv"])
            #expect(write.exitCode == 0)

            // volta para a pasta do run do Mac (a mesma do local)
            let run = fixture.directory.appendingPathComponent("run", isDirectory: true)
            let synced = try await RunFileSync(client: remote).pullRun(
                container: id, workDirectory: run.appendingPathComponent("work"), logsDirectory: run.appendingPathComponent("logs"))
            #expect(synced.work.files == 1)
            #expect(try String(contentsOf: run.appendingPathComponent("work/out/result.csv"), encoding: .utf8) == "a,b\n")
            await tunnel.stop()
        }
    }
}
