import Foundation
import RackyCore
import RackyDocker
import Testing

@testable import RackyVZ

private func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("vz-prov-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let image = VZBootImage(reference: "racky-computer:vz", digest: "sha256:abc", templateRootfs: URL(fileURLWithPath: "/nonexistent/rootfs.ext4"))

private func makeSpec(in root: URL, display: ComputerDisplay = .http) -> ComputerSpec {
    ComputerSpec(
        name: "scout", parent: "claude", display: display, profile: nil, proxy: "direct", proxiesAllowed: [], allowHosts: ["example.com"], batch: nil,
        run: RunFolder(root: root.appendingPathComponent("runs/scout", isDirectory: true)))
}

@Suite struct VZProvisioningTests {
    private func provisioning(_ root: URL, backend: any VZBackend, registry: VZRegistry) -> VZComputerProvisioning {
        VZComputerProvisioning(
            registry: registry, secrets: BoxSecretFiles(root: root.appendingPathComponent("secrets", isDirectory: true)), owner: "racky-test",
            runtimeReadyTimeout: .seconds(5)) { (backend: backend, image: image) }
    }

    @Test func provisionBootsDeliversSecretsByStdinAndReachesTheAdminAPIThroughTheBridge() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = FakeBackend()
        let registry = VZRegistry(url: root.appendingPathComponent("registry.json"))
        let handle = try await provisioning(root, backend: backend, registry: registry).provision(makeSpec(in: root))

        let vm = try #require(backend.vms.first)
        let plan = try #require(backend.plans.first)
        #expect(plan.vmID.hasPrefix("ab-"))
        #expect(plan.shares.contains { $0.guestPath == "/work" && $0.hostPath.hasSuffix("runs/scout/work") })
        #expect(plan.shares.contains { $0.guestPath == "/run/racky/logs" && $0.hostPath.hasSuffix("runs/scout/logs") })
        #expect(plan.environment.contains("RACKY_DISPLAY=http"))

        // Registro próprio no lugar dos labels.
        let entries = await registry.entries
        #expect(entries.count == 1)
        #expect(entries.first?.name == "scout")
        #expect(entries.first?.owner == "racky-test")
        #expect(entries.first?.hostPID == getpid())

        // Segredos: exec + stdin como `egress`, com o token, a sub-rede da vmnet e a política de hosts; nada em argv/env.
        let provision = try #require(vm.processes.first { $0.request.command == ["abx-provision"] })
        #expect(provision.request.user == "egress")
        #expect(provision.request.environment.isEmpty)
        let payload = try #require(JSONSerialization.jsonObject(with: provision.session.receivedInput) as? [String: [String: String]])
        let files = try #require(payload["files"])
        #expect(files["token"]?.count == 64)
        let egressText = try #require(files["egress.json"])
        let egressObject = try JSONSerialization.jsonObject(with: Data(egressText.utf8))
        let egress = try #require(egressObject as? [String: Any])
        #expect(egress["internal_subnet"] as? String == "192.168.64.0/24")
        #expect(egress["allow_hosts"] as? [String] == ["example.com"])
        for process in vm.processes { #expect(!process.request.command.joined(separator: " ").contains(files["token"] ?? "-")) }

        // A admin API responde pela ponte TCP -> vsock (o backend das ferramentas fala com ela por 127.0.0.1).
        #expect(try await handle.backend.proxyInfo().object != nil)

        // Exec das ferramentas: como `agent`, em /work, com o wrapper do grupo de processos (a mesma forma do Docker).
        let outcome = try await handle.backend.execRun(BackendExec(argv: ["echo", "hi"], cwd: "/work"), timeout: .seconds(5))
        #expect(outcome.exitCode == 0)
        #expect(String(decoding: outcome.stdout, as: UTF8.self) == "hi\n")
        let exec = try #require(vm.processes.last)
        #expect(exec.request.user == "agent")
        #expect(exec.request.workingDirectory == "/work")
        #expect(exec.request.command.prefix(2) == ["/bin/sh", "-c"])
        #expect(exec.request.command.suffix(2) == ["echo", "hi"])

        await handle.teardown()
        #expect(vm.stops == 1)
        #expect(await registry.entries.isEmpty)
    }

    @Test func aBootFailureCleansTheRegistryAndTheSecrets() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = VZRegistry(url: root.appendingPathComponent("registry.json"))
        let backend = FakeBackend(failure: VZError.bootFailed("no kernel"))
        await #expect(throws: VZError.bootFailed("no kernel")) {
            _ = try await provisioning(root, backend: backend, registry: registry).provision(makeSpec(in: root))
        }
        #expect(await registry.entries.isEmpty)
        let secrets = root.appendingPathComponent("secrets/boxes")
        #expect((try? FileManager.default.contentsOfDirectory(atPath: secrets.path))?.isEmpty ?? true)
    }

    @Test func aBrowserComputerWaitsForTheRuntimeToBeReady() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = VZRegistry(url: root.appendingPathComponent("registry.json"))
        let backend = FakeBackend(runtimeReady: false)
        let started = ContinuousClock.now
        await #expect(throws: ComputerProvisionerError.self) {
            _ = try await provisioning(root, backend: backend, registry: registry).provision(makeSpec(in: root, display: .headless))
        }
        #expect(ContinuousClock.now - started >= .seconds(4))
        // Falhou: a VM foi parada e nada ficou registrado.
        #expect(backend.vms.first?.stops == 1)
        #expect(await registry.entries.isEmpty)
    }

    @Test func liveComputersIsAlwaysEmptySoTheSchedulerDropsStaleRows() async {
        let registry = VZRegistry(url: URL(fileURLWithPath: "/tmp/unused-registry.json"))
        let provisioning = VZComputerProvisioning(registry: registry, secrets: BoxSecretFiles(root: URL(fileURLWithPath: "/tmp")), owner: "x") {
            (backend: FakeBackend(), image: image)
        }
        #expect(await provisioning.liveComputers() == [])
    }

    @Test func theGroupedSessionSignalsTheProcessGroupThroughASecondExec() async throws {
        let vm = FakeVM(vmID: "ab-x")
        let transport = VZExecTransport(vm: vm)
        var spec = ExecSpec(command: ["sleep", "30"], killableGroup: true, user: "agent")
        spec.workingDirectory = "/work"
        let session = try await transport.startExec(spec)
        let first = try #require(vm.processes.first)
        let script = first.request.command[2]
        #expect(script == "echo $$ > \"$0\"; exec \"$@\"")
        let pidFile = first.request.command[3]
        #expect(pidFile.hasPrefix("/tmp/.abx-exec-"))
        _ = try await session.finalExitCode()  // o processo "terminou"
        try await session.terminateGroup(grace: .milliseconds(100))
        // O desligamento manda TERM ao grupo por um exec separado, lendo o mesmo arquivo de pid.
        let signals = vm.processes.dropFirst().filter { $0.request.command.dropFirst(3).first == pidFile }
        #expect(signals.first?.request.command.last == "TERM")
    }

    @Test func runHelperTimesOutAndTerminates() async throws {
        let vm = SlowVM()
        await #expect(throws: VZError.timedOut("command sleep")) {
            _ = try await vm.run(VZExecRequest(command: ["sleep", "30"]), timeout: .milliseconds(200))
        }
        #expect(vm.session.wasTerminated)
    }
}

/// VM cujo processo nunca termina (para o timeout de `run`).
private final class SlowVM: RunningVM {
    let vmID = "slow"
    let ipAddress: String? = nil
    let session = NeverEndingSession()
    func startProcess(_ request: VZExecRequest) async throws -> any ComputerExecSession { session }
    func dialVsock(port: UInt32) async throws -> FileHandle { throw VZError.unavailable("none") }
    func copyIn(from source: URL, to guestPath: String) async throws {}
    func copyOut(from guestPath: String, to destination: URL) async throws {}
    func stop() async {}
}

private final class NeverEndingSession: ComputerExecSession {
    let frames = AsyncThrowingStream<DockerStreamFrame, any Error> { _ in }
    private let flag = AtomicFlag()
    var wasTerminated: Bool { flag.isSet }
    func writeInput(_ data: Data) async throws {}
    func closeInput() async {}
    func finalExitCode() async throws -> Int {
        try await Task.sleep(for: .seconds(60))
        return 0
    }
    func terminateGroup(grace: Duration) async throws { _ = flag.setOnce() }
}
