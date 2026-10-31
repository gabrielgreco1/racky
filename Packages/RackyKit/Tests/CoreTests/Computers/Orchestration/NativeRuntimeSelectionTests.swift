import RackyDocker
import RackyProtocol
import Foundation
import Synchronization
import Testing

@testable import RackyCore

// `AppComputerProvisioning` com o runtime nativo (sem Docker): escolha entre nativo e Docker, progresso do download na linha do
// computador, e a adoção que devolve lista vazia (e não `nil`) para o scheduler baixar as linhas de uma sessão anterior.

/// Runtime nativo falso: registra as chamadas; o `ProvisionedHandle` é o do backend falso dos testes de orquestração.
private final class FakeNative: NativeComputerRuntime {
    private let calls = Mutex<[String]>([])
    let reason: String?
    let readyError: (any Error)?
    let steps: [ComputerSetupState]

    init(reason: String? = nil, readyError: (any Error)? = nil, steps: [ComputerSetupState] = []) {
        self.reason = reason; self.readyError = readyError; self.steps = steps
    }

    var unavailableReason: String? { reason }
    var log: [String] { calls.withLock { $0 } }

    func ensureReady(progress: @escaping @Sendable (ComputerSetupState) -> Void) async throws {
        calls.withLock { $0.append("ensureReady") }
        for step in steps { progress(step) }
        if let readyError { throw readyError }
    }

    func vmCapacity() async -> VMCapacity { VMCapacity(memTotalBytes: 12 << 30, cpuCount: 8) }

    func provision(_ spec: ComputerSpec) async throws -> ProvisionedHandle {
        calls.withLock { $0.append("provision:\(spec.name)") }
        return ProvisionedHandle(backend: FakeBackend()) { self.calls.withLock { $0.append("teardown") } }
    }

    func shutdown() async { calls.withLock { $0.append("shutdown") } }
}

private struct NotPublished: LocalizedError {
    var errorDescription: String? { "the computer runtime download isn't published yet" }
}

private func makeProvisioning(native: FakeNative?, forceDocker: Bool = false) -> AppComputerProvisioning {
    var config = AppComputerProvisioning.Config(
        runtimeRoot: nil, secretsRoot: FileManager.default.temporaryDirectory.appendingPathComponent("native-sel-\(UUID().uuidString)"), owner: "native-test")
    // Docker inalcançável de propósito: o teste não pode depender (nem tocar) no Docker da máquina.
    config.client = DockerClient(socketPath: "/nonexistent/racky-test-docker.sock", defaultTimeout: .milliseconds(200))
    config.native = native
    config.forceDocker = { forceDocker }
    return AppComputerProvisioning(config: config)
}

private func spec() -> ComputerSpec {
    ComputerSpec(
        name: "scout", parent: "p", display: .headless, profile: nil, proxy: "direct", proxiesAllowed: [], allowHosts: [], batch: nil,
        run: RunFolder(root: FileManager.default.temporaryDirectory.appendingPathComponent("native-run-\(UUID().uuidString)")))
}

@Suite("Runtime nativo no AppComputerProvisioning", .serialized) struct NativeRuntimeSelectionTests {
    @Test func theNativeRuntimeIsUsedWhenAvailableAndNotForcedOff() async throws {
        let native = FakeNative()
        let provisioning = makeProvisioning(native: native)
        // Escolha é do sistema: o teste roda em macOS 26+/Apple silicon; em outro Mac o Docker é o esperado.
        let expected: ComputerRuntimeChoice = RuntimeSelector.choose(forceDocker: false) == .native ? .native : .docker
        #expect(await provisioning.activeRuntime() == expected)
        guard expected == .native else { return }
        try await provisioning.preflight()  // não toca no Docker (que está inalcançável aqui)
        let capacity = await provisioning.vmCapacity()
        #expect(capacity.memTotalBytes == 12 << 30)
        _ = try await provisioning.provision(spec())
        #expect(native.log == ["ensureReady", "provision:scout"])
        #expect(await provisioning.state == .ready)
    }

    @Test func forceDockerBypassesTheNativeRuntime() async {
        let native = FakeNative()
        let provisioning = makeProvisioning(native: native, forceDocker: true)
        #expect(await provisioning.activeRuntime() == .docker)
        // Caminho Docker: sem socket, o preflight falha como sempre ("Docker isn't running"); o nativo nem foi consultado.
        await #expect(throws: ComputerSetupError.dockerNotRunning) { try await provisioning.preflight() }
        #expect(native.log.isEmpty)
    }

    @Test func anUnavailableNativeRuntimeFallsBackToDocker() async {
        let native = FakeNative(reason: "This build of Racky isn't signed to run virtual machines.")
        let provisioning = makeProvisioning(native: native)
        #expect(await provisioning.activeRuntime() == .docker)
        #expect(native.log.isEmpty)
    }

    @Test func withoutANativeRuntimeNothingChanges() async {
        let provisioning = makeProvisioning(native: nil)
        #expect(await provisioning.activeRuntime() == .docker)
        await #expect(throws: ComputerSetupError.dockerNotRunning) { try await provisioning.preflight() }
    }

    @Test func downloadProgressReachesTheObserverAsTheRowLabel() async throws {
        guard RuntimeSelector.choose(forceDocker: false) == .native else { return }
        let native = FakeNative(steps: [.downloading(done: 0, total: 453 << 20), .downloading(done: 200 << 20, total: 453 << 20), .preparing])
        let provisioning = makeProvisioning(native: native)
        let labels = Mutex<[String]>([])
        await provisioning.setObserver(state: { state in if let label = state.label { labels.withLock { $0.append(label) } } }, problem: nil)
        _ = try await provisioning.provision(spec())
        try await Task.sleep(for: .milliseconds(100))  // o observador é chamado por Tasks soltas
        let seen = labels.withLock { $0 }
        #expect(seen.contains("Downloading the computer runtime (200 of 453 MB)…"))
        #expect(seen.contains("Preparing the computer runtime…"))
    }

    @Test func aRuntimeThatCannotBePreparedFailsWithACleanErrorAndNoDockerBanner() async throws {
        guard RuntimeSelector.choose(forceDocker: false) == .native else { return }
        let native = FakeNative(readyError: NotPublished())
        let provisioning = makeProvisioning(native: native)
        let problems = Mutex<[ComputerSetupError]>([])
        await provisioning.setObserver(state: nil, problem: { problem in problems.withLock { $0.append(problem) } })
        await #expect(throws: ComputerSetupError.self) { _ = try await provisioning.provision(spec()) }
        let seen = problems.withLock { $0 }
        #expect(seen.count == 1)
        if case .nativeRuntime(let detail)? = seen.first { #expect(detail.contains("isn't published yet")) } else { Issue.record("expected .nativeRuntime, got \(seen)") }
        #expect(!seen.contains(.dockerNotRunning))
        if case .failed = await provisioning.state {} else { Issue.record("state should be .failed") }
    }

    @Test func liveComputersIsEmptyNotNilSoStaleRowsAreDropped() async {
        guard RuntimeSelector.choose(forceDocker: false) == .native else { return }
        let provisioning = makeProvisioning(native: FakeNative())
        #expect(await provisioning.liveComputers() == [])  // com Docker inalcançável, o nativo ainda responde "nada vivo"
    }

    @Test func shutdownStopsTheNativeVMs() async {
        let native = FakeNative()
        let provisioning = makeProvisioning(native: native)
        await provisioning.shutdownNative()
        #expect(native.log == ["shutdown"])
    }

    @Test func setupLabelsRead() {
        #expect(ComputerSetupState.downloading(done: 10 << 20, total: 453 << 20).label == "Downloading the computer runtime (10 of 453 MB)…")
        #expect(ComputerSetupState.downloading(done: 10 << 20, total: 0).label == "Downloading the computer runtime (10 MB)…")
        #expect(ComputerSetupState.preparing.label == "Preparing the computer runtime…")
        #expect(ComputerSetupState.ready.label == nil)
    }

    @Test func forceDockerSettingDefaultsOffAndSurvivesOldDatabases() throws {
        #expect(AppSettings().computers.forceDocker == false)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"computers":{"defaultSubagentMode":"off","runOn":"local"}}"#.utf8))
        #expect(old.computers.forceDocker == false)
        var settings = AppSettings()
        settings.computers.forceDocker = true
        let roundTrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(roundTrip.computers.forceDocker)
    }
}
