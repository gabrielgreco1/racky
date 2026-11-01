import RackyCore
import RackyProtocol
import Darwin
import Foundation
import Synchronization
import Testing

@testable import RackyPlatform
@testable import RackyUI

/// LaunchAgent falso para o `TerminalRuntime`: sem `SMAppService` nem launchd reais.
private final class StubAgentService: BackgroundAgentService, @unchecked Sendable {  // SAFETY: estado sob `lock`.
    private let lock = Mutex((status: BackgroundAgentStatus.notRegistered, after: BackgroundAgentStatus.enabled, opened: 0))
    init(after: BackgroundAgentStatus) { lock.withLock { $0.after = after } }
    var status: BackgroundAgentStatus { lock.withLock { $0.status } }
    var opened: Int { lock.withLock { $0.opened } }
    func register() throws { lock.withLock { $0.status = $0.after } }
    func unregister() throws { lock.withLock { $0.status = .notRegistered } }
    func openLoginItemsSettings() { lock.withLock { $0.opened += 1 } }
}

private struct StubLaunchd: LaunchdQuerying {
    var path: String?
    func socketPath(forKey key: String) async -> String? { path }
    func jobState(label: String) async -> LaunchdJobState { .idle }
}

/// Onde o daemon roda (T1-24): LaunchAgent quando aprovado; daemon filho (modo atual) quando exige aprovação ou não responde.
@MainActor
@Suite(.serialized, .tags(.integration), .timeLimit(.minutes(1)), .offscreenAppKit) struct DaemonHostingTests {
    private func makeHost(
        home: URL, after: BackgroundAgentStatus, socket: String?
    ) throws -> (BackgroundAgentHost, StubAgentService) {
        let bundle = home.appendingPathComponent("Racky.app")
        let agents = bundle.appendingPathComponent("Contents/Library/LaunchAgents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let identity = BackgroundAgentIdentity.test(suffix: "surface")
        try Data("<plist/>".utf8).write(to: agents.appendingPathComponent(identity.plistName))
        let service = StubAgentService(after: after)
        let host = BackgroundAgentHost(
            identity: identity, service: service, launchd: StubLaunchd(path: socket), bundleURL: bundle, daemonExecutable: nil,
            stateFile: home.appendingPathComponent("run/ptyd-registration.json"), pause: { _ in })
        return (host, service)
    }

    private func makeRuntime(home: URL, host: BackgroundAgentHost?) -> TerminalRuntime {
        TerminalRuntime(
            configuration: .init(
                daemonHome: home, daemonExecutable: rackydBinary(), stopDaemonOnQuit: false, appSocketPath: "/tmp/none.sock",
                backgroundAgent: host, loginEnvironment: { ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()] }),
            registry: nil, elements: nil)
    }

    private func temporaryHome() throws -> URL {
        let home = URL(fileURLWithPath: "/tmp/abr-\(UInt32.random(in: 0 ... 0xFFFFFF))", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return home
    }

    private func alive(_ pid: Int32) -> Bool { pid > 0 && kill(pid, 0) == 0 }

    @Test func approvalPendingFallsBackToTheChildDaemonAndStillWorks() async throws {
        let home = try temporaryHome()
        defer { DaemonReaper.reap(home: home); try? FileManager.default.removeItem(at: home) }  // F34: o filho ignora SIGTERM
        let (host, service) = try makeHost(home: home, after: .requiresApproval, socket: nil)
        let runtime = makeRuntime(home: home, host: host)
        var changes: [DaemonHostMode] = []
        runtime.onHostModeChange = { changes.append($0) }

        #expect(await runtime.connect())
        #expect(runtime.hostMode == .childProcess(reason: .requiresApproval))
        #expect(runtime.needsLoginItemApproval, "Settings › General mostra \"Background agents need approval\"")
        #expect(changes == [.childProcess(reason: .requiresApproval)])
        #expect(service.opened == 0, "o app nunca abre os Itens de Início sozinho")
        let pid = runtime.daemonPID
        #expect(alive(pid), "o fallback é o daemon filho de sempre")

        // Funciona: cria um PTY no daemon filho.
        let create = makeCreate(["/bin/sh", "-c", "echo fallback-ok; sleep 60"])
        let created = try await runtime.client.create(create)
        #expect(created.session.state == .running)

        // "⌘Q" no fallback: o app some e o daemon (reparentado) mantém o PTY; a reabertura o reencontra (T1-23).
        runtime.shutdown()
        await runtime.client.stop()
        #expect(alive(pid))
        let reopened = makeRuntime(home: home, host: host)
        let sessions = try #require(await reopened.probeDaemon())
        #expect(sessions.contains { $0.sessionID == create.sessionID && $0.state == .running })
        try await reopened.client.kill(sessionID: create.sessionID, mode: .force)
        await reopened.client.stop()
        kill(pid, SIGKILL)
    }

    @Test func approvedAgentUsesTheLaunchdSocketAndSpawnsNoChild() async throws {
        let harness = try DaemonHarness()  // faz o papel do daemon que o launchd subiu
        try await harness.start()
        let home = try temporaryHome()
        defer { DaemonReaper.reap(home: home); try? FileManager.default.removeItem(at: home) }
        let (host, _) = try makeHost(home: home, after: .enabled, socket: harness.socketPath)
        let runtime = makeRuntime(home: home, host: host)
        #expect(await runtime.connect())
        #expect(runtime.hostMode == .launchAgent(socketPath: harness.socketPath))
        #expect(!runtime.needsLoginItemApproval)
        #expect(runtime.daemonPID == 0, "com o LaunchAgent o app não cria processo filho")
        let create = makeCreate(["/bin/sh", "-c", "sleep 60"])
        _ = try await runtime.client.create(create)
        let listed = try await runtime.client.list()
        #expect(listed.contains { $0.sessionID == create.sessionID })
        try await runtime.client.kill(sessionID: create.sessionID, mode: .force)
        await runtime.client.stop()
        await harness.stop()
    }

    @Test func silentLaunchdSocketFallsBackToTheChildDaemon() async throws {
        let home = try temporaryHome()
        defer { DaemonReaper.reap(home: home); try? FileManager.default.removeItem(at: home) }  // F34: o filho ignora SIGTERM
        let (host, _) = try makeHost(home: home, after: .enabled, socket: "/tmp/abr-nobody-listens-here.sock")
        let runtime = makeRuntime(home: home, host: host)
        #expect(await runtime.connect())
        #expect(runtime.hostMode == .childProcess(reason: .daemonUnreachable))
        #expect(!runtime.needsLoginItemApproval)
        let pid = runtime.daemonPID
        #expect(alive(pid))
        await runtime.client.stop()
        kill(pid, SIGKILL)
    }

    @Test func noBackgroundAgentConfiguredKeepsTheChildDaemon() async throws {
        let home = try temporaryHome()
        defer { DaemonReaper.reap(home: home); try? FileManager.default.removeItem(at: home) }  // F34: o filho ignora SIGTERM
        let runtime = makeRuntime(home: home, host: nil)
        #expect(await runtime.connect())
        #expect(runtime.hostMode == .childProcess(reason: nil))
        let pid = runtime.daemonPID
        #expect(alive(pid))
        await runtime.client.stop()
        kill(pid, SIGKILL)
    }
}
