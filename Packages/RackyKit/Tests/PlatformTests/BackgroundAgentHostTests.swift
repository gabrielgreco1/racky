import Darwin
import Foundation
import Synchronization
import Testing

@testable import RackyPlatform

/// Serviço de LaunchAgent falso: reproduz o que o S-01 observou do `SMAppService` e do launchd, sem registrar nada de verdade.
final class FakeBackgroundAgentService: BackgroundAgentService, @unchecked Sendable {  // SAFETY: estado só sob `lock`.
    private let lock = Mutex(State(status: .notFound))
    struct State {
        var status: BackgroundAgentStatus
        var registerError: (any Error)?
        /// Status que o erro deixa para trás (o `SMAppService` lança "launch denied by user" e fica em requiresApproval).
        var statusOnRegisterError: BackgroundAgentStatus?
        /// Status depois de um `register()` bem-sucedido (`.requiresApproval` = o dono ainda não aprovou).
        var statusAfterRegister: BackgroundAgentStatus = .enabled
        var calls: [String] = []
        var openedSettings = 0
    }

    init(initial: BackgroundAgentStatus) { lock.withLock { $0 = State(status: initial) } }

    var status: BackgroundAgentStatus { lock.withLock { $0.status } }
    var calls: [String] { lock.withLock { $0.calls } }
    var openedSettings: Int { lock.withLock { $0.openedSettings } }

    func configure(_ body: (inout State) -> Void) { lock.withLock { body(&$0) } }

    func register() throws {
        try lock.withLock { state in
            state.calls.append("register")
            if let error = state.registerError {
                if let after = state.statusOnRegisterError { state.status = after }
                throw error
            }
            state.status = state.statusAfterRegister
        }
    }

    func unregister() throws {
        lock.withLock { state in
            state.calls.append("unregister")
            state.status = .notRegistered
        }
    }

    func openLoginItemsSettings() { lock.withLock { $0.openedSettings += 1 } }
}

final class FakeLaunchd: LaunchdQuerying, @unchecked Sendable {  // SAFETY: estado só sob `lock`.
    private let lock = Mutex((paths: [String?](), state: LaunchdJobState.idle, queries: 0))

    init(socketPaths: [String?], running: Bool = false) { lock.withLock { $0 = (socketPaths, running ? .running : .idle, 0) } }

    func setRunning(_ value: Bool) { lock.withLock { $0.state = value ? .running : .idle } }
    func setState(_ value: LaunchdJobState) { lock.withLock { $0.state = value } }
    var queries: Int { lock.withLock { $0.queries } }

    /// Devolve os caminhos em sequência (o último se repete): `[nil, "/x"]` = o launchd demora a publicar.
    func socketPath(forKey key: String) async -> String? {
        lock.withLock { state in
            state.queries += 1
            if state.paths.count > 1 { return state.paths.removeFirst() }
            return state.paths.first ?? nil
        }
    }

    func jobState(label: String) async -> LaunchdJobState { lock.withLock { $0.state } }
}

struct SampleError: Error, LocalizedError {
    var errorDescription: String? { "denied" }
}

/// Bundle de mentira em `/tmp` com o plist do LaunchAgent e um "daemon" cujo conteúdo define o fingerprint.
final class FakeBundle {
    let root: URL
    let daemon: URL
    let state: URL

    init(withPlist: Bool = true, identity: BackgroundAgentIdentity = .production()) throws {
        root = URL(fileURLWithPath: "/tmp/abb-\(UInt32.random(in: 0 ... 0xFFFFFF))/Racky.app", isDirectory: true)
        let macOS = root.appendingPathComponent("Contents/MacOS")
        let agents = root.appendingPathComponent("Contents/Library/LaunchAgents")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        daemon = macOS.appendingPathComponent("rackyd")
        try Data("daemon-v1".utf8).write(to: daemon)
        if withPlist { try Data("<plist/>".utf8).write(to: agents.appendingPathComponent(identity.plistName)) }
        state = root.deletingLastPathComponent().appendingPathComponent("run/ptyd-registration.json")
    }

    func replaceDaemon(with text: String) throws { try Data(text.utf8).write(to: daemon) }
    func remove() { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
}

@Suite struct BackgroundAgentHostTests {
    private func host(
        _ bundle: FakeBundle, service: FakeBackgroundAgentService, launchd: FakeLaunchd, identity: BackgroundAgentIdentity = .production()
    ) -> BackgroundAgentHost {
        BackgroundAgentHost(
            identity: identity, service: service, launchd: launchd, bundleURL: bundle.root, daemonExecutable: bundle.daemon,
            stateFile: bundle.state, pause: { _ in })
    }

    @Test func firstLaunchRegistersAndUsesTheLaunchdSocket() async throws {
        let bundle = try FakeBundle()
        defer { bundle.remove() }
        let service = FakeBackgroundAgentService(initial: .notFound)  // `notFound` antes do primeiro register (S-01)
        let launchd = FakeLaunchd(socketPaths: ["/var/run/com.apple.launchd.AAA/Listeners"])
        launchd.setState(.notLoaded)  // o launchd ainda não conhece o job
        let mode = await host(bundle, service: service, launchd: launchd).prepare()
        #expect(mode == .launchAgent(socketPath: "/var/run/com.apple.launchd.AAA/Listeners"))
        #expect(service.calls == ["register"])
    }

    /// F30: outro build (outra pasta) já registrou e o daemon está vivo: este app adota, não registra de novo (isso derrubaria o daemon).
    @Test func aDaemonRegisteredByAnotherBuildIsAdoptedWithoutRegistering() async throws {
        let bundle = try FakeBundle()
        defer { bundle.remove() }
        for state in [LaunchdJobState.running] {
            for status in [BackgroundAgentStatus.notRegistered, .notFound] {
                let service = FakeBackgroundAgentService(initial: status)
                let launchd = FakeLaunchd(socketPaths: ["/var/run/other/Listeners"])
                launchd.setState(state)
                let mode = await host(bundle, service: service, launchd: launchd).prepare()
                #expect(mode == .launchAgent(socketPath: "/var/run/other/Listeners"))
                #expect(service.calls.isEmpty, "nem register nem unregister: \(state) \(status)")
            }
        }
    }

    @Test func pointerIsPublishedForTheStableLauncher() async throws {
        let bundle = try FakeBundle()
        defer { bundle.remove() }
        let home = bundle.root.deletingLastPathComponent()
        let host = BackgroundAgentHost(
            identity: .production(), service: FakeBackgroundAgentService(initial: .enabled),
            launchd: FakeLaunchd(socketPaths: ["/var/run/x/Listeners"]), bundleURL: bundle.root, daemonExecutable: bundle.daemon,
            stateFile: bundle.state, pointer: .init(home: home, daemonBinary: bundle.daemon, build: "1.0 (12)"), pause: { _ in })
        _ = await host.prepare()
        #expect(DaemonPointer.read(home: home) == DaemonPointer(path: bundle.daemon.path, build: 12))
    }

    @Test func alreadyEnabledDoesNotRegisterAgain() async throws {
        let bundle = try FakeBundle()
        defer { bundle.remove() }
        let service = FakeBackgroundAgentService(initial: .notRegistered)
        let launchd = FakeLaunchd(socketPaths: ["/var/run/x/Listeners"])
        let host = host(bundle, service: service, launchd: launchd)
        _ = await host.prepare()
        let again = await host.prepare()
        #expect(again == .launchAgent(socketPath: "/var/run/x/Listeners"))
        #expect(service.calls == ["register"], "o segundo prepare só lê o estado")
    }

    @Test func waitsForLaunchdToPublishTheSocketPath() async throws {
        let bundle = try FakeBundle()
        defer { bundle.remove() }
        let launchd = FakeLaunchd(socketPaths: [nil, nil, "/var/run/late/Listeners"])
        let mode = await host(bundle, service: FakeBackgroundAgentService(initial: .enabled), launchd: launchd).prepare()
        #expect(mode == .launchAgent(socketPath: "/var/run/late/Listeners"))
        #expect(launchd.queries == 3)
    }

    // MARK: Fallback

    @Test func requiresApprovalFallsBackToChildDaemonWithoutOpeningSettings() async throws {
        let bundle = try FakeBundle()
        defer { bundle.remove() }
        let service = FakeBackgroundAgentService(initial: .notRegistered)
        service.configure { $0.statusAfterRegister = .requiresApproval }
        let host = host(bundle, service: service, launchd: FakeLaunchd(socketPaths: [nil]))
        let mode = await host.prepare()
        #expect(mode == .childProcess(reason: .requiresApproval))
        #expect(service.openedSettings == 0, "abrir Ajustes do Sistema é só por clique no botão")
        // Aprovado depois: o próximo prepare passa a usar o LaunchAgent sem novo register.
        service.configure { $0.status = .enabled }
        let launchd = FakeLaunchd(socketPaths: ["/var/run/ok/Listeners"])
        let approved = BackgroundAgentHost(
            identity: .production(), service: service, launchd: launchd, bundleURL: bundle.root, daemonExecutable: bundle.daemon,
            stateFile: bundle.state, pause: { _ in })
        #expect(await approved.prepare() == .launchAgent(socketPath: "/var/run/ok/Listeners"))
    }

    @Test func approvalThrownByRegisterIsTheSameFallback() async throws {
        let bundle = try FakeBundle()
        defer { bundle.remove() }
        let service = FakeBackgroundAgentService(initial: .notRegistered)
        service.configure {
            $0.registerError = SampleError()
            $0.statusOnRegisterError = .requiresApproval
        }
        let mode = await host(bundle, service: service, launchd: FakeLaunchd(socketPaths: [nil])).prepare()
        #expect(mode == .childProcess(reason: .requiresApproval))
    }

    @Test func registrationFailureFallsBackWithTheMessage() async throws {
        let bundle = try FakeBundle()
        defer { bundle.remove() }
        let service = FakeBackgroundAgentService(initial: .notRegistered)
        service.configure { $0.registerError = SampleError() }
        let mode = await host(bundle, service: service, launchd: FakeLaunchd(socketPaths: [nil])).prepare()
        #expect(mode == .childProcess(reason: .registrationFailed("denied")))
    }

    @Test func missingPlistMeansRunningOutsideTheBundle() async throws {
        let bundle = try FakeBundle(withPlist: false)
        defer { bundle.remove() }
        let service = FakeBackgroundAgentService(initial: .notFound)
        let mode = await host(bundle, service: service, launchd: FakeLaunchd(socketPaths: ["/x"])).prepare()
        #expect(mode == .childProcess(reason: .notInBundle))
        #expect(service.calls.isEmpty)
    }

    @Test func noSocketPathFallsBack() async throws {
        let bundle = try FakeBundle()
        defer { bundle.remove() }
        let mode = await host(bundle, service: FakeBackgroundAgentService(initial: .enabled), launchd: FakeLaunchd(socketPaths: [nil])).prepare()
        #expect(mode == .childProcess(reason: .socketUnavailable))
    }

    @Test func settingsButtonOpensLoginItemsOnlyWhenCalled() async throws {
        let bundle = try FakeBundle()
        defer { bundle.remove() }
        let service = FakeBackgroundAgentService(initial: .requiresApproval)
        let host = host(bundle, service: service, launchd: FakeLaunchd(socketPaths: [nil]))
        _ = await host.prepare()
        #expect(service.openedSettings == 0)
        host.openLoginItemsSettings()
        #expect(service.openedSettings == 1)
    }

    // MARK: Binário novo do daemon (S-01: o launchd prende o job ao cdhash)

    @Test func newDaemonBinaryWhileIdleReRegistersAtOnce() async throws {
        let bundle = try FakeBundle()
        defer { bundle.remove() }
        let service = FakeBackgroundAgentService(initial: .notRegistered)
        let launchd = FakeLaunchd(socketPaths: ["/var/run/old/Listeners"], running: false)
        let first = host(bundle, service: service, launchd: launchd)
        _ = await first.prepare()
        #expect(service.calls == ["register"])

        try bundle.replaceDaemon(with: "daemon-v2")  // atualização do app
        let second = host(bundle, service: service, launchd: FakeLaunchd(socketPaths: ["/var/run/new/Listeners"], running: false))
        let mode = await second.prepare()
        #expect(service.calls == ["register", "unregister", "register"])
        #expect(mode == .launchAgent(socketPath: "/var/run/new/Listeners"))
        #expect(await second.pendingReRegistration == false)
    }

    @Test func newDaemonBinaryWithLiveDaemonNeverUnregisters() async throws {
        let bundle = try FakeBundle()
        defer { bundle.remove() }
        let service = FakeBackgroundAgentService(initial: .notRegistered)
        _ = await host(bundle, service: service, launchd: FakeLaunchd(socketPaths: ["/var/run/old/Listeners"])).prepare()

        try bundle.replaceDaemon(with: "daemon-v2")
        let launchd = FakeLaunchd(socketPaths: ["/var/run/old/Listeners"], running: true)  // daemon antigo com sessões
        let second = host(bundle, service: service, launchd: launchd)
        let mode = await second.prepare()
        #expect(service.calls == ["register"], "unregister mataria as sessões vivas")
        #expect(mode == .launchAgent(socketPath: "/var/run/old/Listeners"))
        #expect(await second.pendingReRegistration)

        // Ainda rodando: recover() não mexe.
        _ = await second.recover()
        #expect(service.calls == ["register"])

        // O daemon antigo saiu (drainWhenIdle): agora sim, re-registra e devolve o socket novo.
        launchd.setRunning(false)
        let fresh = FakeLaunchd(socketPaths: ["/var/run/new/Listeners"], running: false)
        let third = BackgroundAgentHost(
            identity: .production(), service: service, launchd: fresh, bundleURL: bundle.root, daemonExecutable: bundle.daemon,
            stateFile: bundle.state, pause: { _ in })
        let recovered = await third.recover()
        #expect(service.calls == ["register", "unregister", "register"])
        #expect(recovered == .launchAgent(socketPath: "/var/run/new/Listeners"))
        #expect(await third.pendingReRegistration == false)
    }

    @Test func failedJobWithTheSameBinaryIsRepairedEvenWithoutAFingerprintChange() async throws {
        // `spawn failed` / `needs LWCR update` (S-01): o job não sobe; com o job parado re-registrar é seguro.
        let bundle = try FakeBundle()
        defer { bundle.remove() }
        let service = FakeBackgroundAgentService(initial: .notRegistered)
        _ = await host(bundle, service: service, launchd: FakeLaunchd(socketPaths: ["/var/run/old/Listeners"])).prepare()
        let broken = FakeLaunchd(socketPaths: ["/var/run/new/Listeners"])
        broken.setState(.failed)
        let mode = await host(bundle, service: service, launchd: broken).prepare()
        #expect(service.calls == ["register", "unregister", "register"])
        #expect(mode == .launchAgent(socketPath: "/var/run/new/Listeners"))
    }

    @Test func reRegisterWaitsForTheUnregisterToFinishBeforeRegistering() async throws {
        let bundle = try FakeBundle()
        defer { bundle.remove() }
        let service = FakeBackgroundAgentService(initial: .notRegistered)
        _ = await host(bundle, service: service, launchd: FakeLaunchd(socketPaths: ["/x/Listeners"])).prepare()
        try bundle.replaceDaemon(with: "daemon-v2")
        let pauses = Mutex(0)
        let waiting = BackgroundAgentHost(
            identity: .production(), service: service, launchd: FakeLaunchd(socketPaths: ["/y/Listeners"]), bundleURL: bundle.root,
            daemonExecutable: bundle.daemon, stateFile: bundle.state, pause: { _ in pauses.withLock { $0 += 1 } })
        _ = await waiting.prepare()
        #expect(service.calls == ["register", "unregister", "register"])
        // O launchd falso nunca esquece o job (`idle`): o laço de espera esgota as tentativas antes de registrar, sem travar.
        #expect(pauses.withLock { $0 } > 0)
    }

    @Test func sameBinaryNeverReRegisters() async throws {
        let bundle = try FakeBundle()
        defer { bundle.remove() }
        let service = FakeBackgroundAgentService(initial: .notRegistered)
        let launchd = FakeLaunchd(socketPaths: ["/var/run/a/Listeners"])
        _ = await host(bundle, service: service, launchd: launchd).prepare()
        _ = await host(bundle, service: service, launchd: launchd).prepare()
        _ = await host(bundle, service: service, launchd: launchd).recover()
        #expect(service.calls == ["register"])
    }

    @Test func unregisterForgetsTheRecord() async throws {
        let bundle = try FakeBundle()
        defer { bundle.remove() }
        let service = FakeBackgroundAgentService(initial: .notRegistered)
        let host = host(bundle, service: service, launchd: FakeLaunchd(socketPaths: ["/x/Listeners"]))
        _ = await host.prepare()
        #expect(FileManager.default.fileExists(atPath: bundle.state.path))
        await host.unregister()
        #expect(!FileManager.default.fileExists(atPath: bundle.state.path))
        #expect(service.status == .notRegistered)
    }
}

struct BackgroundAgentIdentityTests {
    @Test func productionNamesCarryTheMajor() {
        let id = BackgroundAgentIdentity.production()
        #expect(id.label == "app.racky.ptyd.v1")
        #expect(id.plistName == "app.racky.ptyd.v1.plist")
        #expect(id.socketKey == "RACKY_PTYD_SOCK_V1")
        #expect(!id.isTest)
        #expect(BackgroundAgentIdentity.production(major: 2).socketKey == "RACKY_PTYD_SOCK_V2")
    }

    @Test func rackyHomeSelectsATestLabelThatNeverCollidesWithProduction() {
        let id = BackgroundAgentIdentity.resolve(environment: ["RACKY_HOME": "/tmp/abx-1"])
        #expect(id.isTest)
        #expect(id.label.hasPrefix("app.racky.ptyd.test-"))
        #expect(id.socketKey != BackgroundAgentIdentity.production().socketKey)
        #expect(id == BackgroundAgentIdentity.resolve(environment: ["RACKY_HOME": "/tmp/abx-1"]))
        #expect(id != BackgroundAgentIdentity.resolve(environment: ["RACKY_HOME": "/tmp/abx-2"]))
        #expect(BackgroundAgentIdentity.resolve(environment: ["RACKY_HOME": "/tmp/abx-1", "RACKY_TEST_N": "7"]).label == "app.racky.ptyd.test-7")
        #expect(BackgroundAgentIdentity.resolve(environment: [:]) == .production())
    }
}

struct LaunchdQueryParsingTests {
    @Test func onlyTheJobLineCountsAsRunning() {
        let running = "gui/501/x = {\n\tstate = running\n\n\tsockets = {\n\t\t\"Listeners\" = {\n\t\t\tstate = active\n"
        let idle = "gui/501/x = {\n\tstate = not running\n\n\tsockets = {\n\t\tstate = running\n"
        #expect(SystemLaunchd.isRunning(printOutput: running))
        #expect(!SystemLaunchd.isRunning(printOutput: idle))
        #expect(!SystemLaunchd.isRunning(printOutput: "\tstate = spawn scheduled\n"))
    }

    @Test func printOutputMapsToJobStates() {
        let running = "gui/501/x = {\n\tstate = running\n\tjob state = running\n\tproperties = partial import | has LWCR\n}\n"
        let failed = "gui/501/x = {\n\tstate = spawn scheduled\n\tlast exit reason = OS_REASON_CODESIGNING\n\tjob state = spawn failed\n"
            + "\tproperties = partial import | needs LWCR update | has LWCR\n}\n"
        let fresh = "gui/501/x = {\n\tstate = not running\n\tjob state = uninitialized\n\tproperties = partial import | has LWCR\n}\n"
        #expect(SystemLaunchd.state(printOutput: running) == .running)
        #expect(SystemLaunchd.state(printOutput: failed) == .failed)
        #expect(SystemLaunchd.state(printOutput: fresh) == .idle)
    }

    @Test func activationOutsideLaunchdFailsWithoutDescriptors() {
        #expect(throws: LaunchdSocketActivation.Failure.self) {
            _ = try LaunchdSocketActivation.activate(name: "Listeners")
        }
    }
}
