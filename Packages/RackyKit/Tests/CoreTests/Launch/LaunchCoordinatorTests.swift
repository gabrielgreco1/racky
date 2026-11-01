import RackyPlatform
import RackyProtocol
import Foundation
import Synchronization
import Testing

@testable import RackyCore

/// Daemon de mentira: registra os `create`, pode falhar e devolve um resumo fixo.
final class FakeGateway: LaunchDaemonGateway, @unchecked Sendable {  // SAFETY: estado sob `lock`.
    struct State {
        var requests: [CreateRequest] = []
        var killed: [SessionID] = []
        var connected = true
        var createError: (any Error)?
        var delay: Duration = .zero
    }
    private let lock = Mutex(State())
    var requests: [CreateRequest] { lock.withLock { $0.requests } }
    var killed: [SessionID] { lock.withLock { $0.killed } }
    func configure(_ body: (inout State) -> Void) { lock.withLock { body(&$0) } }

    func connect() async -> Bool { lock.withLock { $0.connected } }
    func create(_ request: CreateRequest) async throws -> SessionSummary {
        let (error, delay) = lock.withLock { s in (s.createError, s.delay) }
        if delay > .zero { try? await Task.sleep(for: delay) }
        if let error { throw error }
        lock.withLock { $0.requests.append(request) }
        return SessionSummary(
            sessionID: request.sessionID, pid: 4242, pgid: 4242, argv0: request.argv.first ?? "", cwd: request.cwd, state: .running,
            startedAt: Date(), exit: nil, lastOutputAt: nil, title: nil, endSeq: 0, inputBytesByOrigin: InputByteCounts())
    }
    func kill(sessionID: SessionID) async { lock.withLock { $0.killed.append(sessionID) } }
}

final class EventLog: @unchecked Sendable {  // SAFETY: estado sob `lock`.
    private let lock = Mutex<[LaunchEvent]>([])
    func add(_ event: LaunchEvent) { lock.withLock { $0.append(event) } }
    var events: [LaunchEvent] { lock.withLock { $0 } }
    var steps: [(LaunchStepKey, LaunchStepStatus)] {
        events.compactMap { if case .step(let p) = $0 { (p.step, p.status) } else { nil } }
    }
    func status(of key: LaunchStepKey) -> [LaunchStepStatus] { steps.filter { $0.0 == key }.map(\.1) }
}

@Suite struct LaunchCoordinatorTests {
    private func makeCoordinator(
        gateway: FakeGateway, executables: [String: String] = ["claude": "/usr/local/bin/claude", "zsh": "/bin/zsh"]
    ) -> LaunchCoordinator {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lc-\(UUID().uuidString)", isDirectory: true)
        return LaunchCoordinator(
            daemon: gateway,
            configuration: .init(
                launchRoot: root, appSocketPath: "/tmp/app.sock",
                loginEnvironment: { ["PATH": "/usr/bin:/bin", "HOME": "/Users/example", "SHELL": "/bin/zsh"] },
                resolveExecutable: { name, _ in executables[name] }))
    }

    private func job(_ spec: LaunchSpec, workspace: LaunchWorkspaceStep? = nil) -> LaunchJob {
        LaunchJob(terminalID: UUID(), spec: spec, cwd: "/tmp", workspace: workspace)
    }

    @Test func emitsRealStepsInOrderAndRebuildsArgv() async throws {
        let gateway = FakeGateway()
        let coordinator = makeCoordinator(gateway: gateway)
        let log = EventLog()
        let result = try await coordinator.launch(job(LaunchSpec(provider: .claude, model: "haiku", initialPrompt: "reply OK")), onEvent: log.add)
        let order = log.steps.filter { $0.1 != .skipped }.map { "\($0.0.rawValue):\($0.1.rawValue)" }
        #expect(order == [
            "env.login:running", "env.login:done", "cli.resolve:running", "cli.resolve:done", "launch.config:running", "launch.config:done",
            "pty.spawn:running", "pty.spawn:done", "cli.exec:running",
        ])
        #expect(log.status(of: .gitFetch) == [.skipped])
        let argv = gateway.requests[0].argv
        #expect(argv.first == "/usr/local/bin/claude")
        #expect(argv.contains("--model") && argv.contains("haiku"))
        #expect(argv.last == "reply OK")
        #expect(result.plan.nativeConversationID != nil)
        #expect(log.events.contains { if case .nativeID(_, let id) = $0 { id == result.plan.nativeConversationID } else { false } })
        // Restart: novo run, argv regerado.
        let second = try await coordinator.launch(job(LaunchSpec(provider: .claude, initialPrompt: "x")), onEvent: { _ in })
        #expect(second.runID != result.runID)
        #expect(gateway.requests.count == 2)
    }

    @Test func firstOutputClosesCliExecOnce() async throws {
        let gateway = FakeGateway()
        let coordinator = makeCoordinator(gateway: gateway)
        let log = EventLog()
        let result = try await coordinator.launch(job(LaunchSpec(provider: .shell)), onEvent: log.add)
        #expect(log.status(of: .cliExec) == [.running])
        await coordinator.noteFirstOutput(runID: result.runID)
        await coordinator.noteFirstOutput(runID: result.runID)
        #expect(log.status(of: .cliExec) == [.running, .done])
        #expect(log.events.filter { $0 == .firstOutput(runID: result.runID) }.count == 1)
    }

    @Test func firstOutputDuringAttachIsReplayedAfterRunning() async throws {
        let gateway = FakeGateway()
        let coordinator = makeCoordinator(gateway: gateway)
        let log = EventLog()
        let result = try await coordinator.launch(
            job(LaunchSpec(provider: .shell)), onEvent: log.add,
            attach: { _, runID in await coordinator.noteFirstOutput(runID: runID) })
        #expect(log.status(of: .cliExec) == [.running, .done])
        #expect(await coordinator.hasSeenFirstOutput(runID: result.runID))
    }

    @Test func missingCLIFailsOnResolveStep() async {
        let coordinator = makeCoordinator(gateway: FakeGateway(), executables: [:])
        let log = EventLog()
        let request = job(LaunchSpec(provider: .claude))
        await #expect(throws: LaunchFailure.cliNotFound("Claude Code")) {
            _ = try await coordinator.launch(request, onEvent: log.add)
        }
        #expect(log.status(of: .cliResolve).last == .failed)
        #expect(log.status(of: .launchConfig).isEmpty)
    }

    @Test func spawnErrorBecomesFailureWithPath() async {
        let gateway = FakeGateway()
        gateway.configure { $0.createError = PTYClientError.daemon(DaemonError(.spawnFailed, "No such file", errnoValue: 2, path: "/nope")) }
        let coordinator = makeCoordinator(gateway: gateway)
        let log = EventLog()
        let request = job(LaunchSpec(provider: .shell))
        await #expect(throws: LaunchFailure.spawn("No such file (/nope)")) {
            _ = try await coordinator.launch(request, onEvent: log.add)
        }
        #expect(log.status(of: .ptySpawn) == [.running, .failed])
    }

    @Test func daemonUnavailableFails() async {
        let gateway = FakeGateway()
        gateway.configure { $0.connected = false }
        let coordinator = makeCoordinator(gateway: gateway)
        let request = job(LaunchSpec(provider: .shell))
        await #expect(throws: LaunchFailure.daemonUnavailable) {
            _ = try await coordinator.launch(request, onEvent: { _ in })
        }
        #expect(gateway.requests.isEmpty)
    }

    @Test func workspaceStepEmitsGitRowsAndFailureStopsBeforeSpawn() async {
        let gateway = FakeGateway()
        let coordinator = makeCoordinator(gateway: gateway)
        let log = EventLog()
        let ok = job(
            LaunchSpec(provider: .shell),
            workspace: { emit in
                emit(.gitFetch, .running, nil); emit(.gitFetch, .done, nil)
                emit(.gitWorktree, .running, nil); emit(.gitWorktree, .done, nil)
            })
        _ = try? await coordinator.launch(ok, onEvent: log.add)
        #expect(log.status(of: .gitFetch) == [.running, .done])
        #expect(log.status(of: .gitWorktree) == [.running, .done])
        let bad = job(LaunchSpec(provider: .shell), workspace: { _ in throw LaunchFailure.workspace("branch exists") })
        let log2 = EventLog()
        await #expect(throws: LaunchFailure.workspace("branch exists")) { _ = try await coordinator.launch(bad, onEvent: log2.add) }
        #expect(log2.status(of: .gitWorktree) == [.failed])
        #expect(gateway.requests.count == 1)
    }

    @Test func cancelDuringCreateKillsTheSession() async throws {
        let gateway = FakeGateway()
        gateway.configure { $0.delay = .milliseconds(150) }
        let coordinator = makeCoordinator(gateway: gateway)
        let request = job(LaunchSpec(provider: .shell))
        let running = Task { try await coordinator.launch(request, onEvent: { _ in }) }
        try await Task.sleep(for: .milliseconds(50))
        await coordinator.cancel(terminalID: request.terminalID)
        await #expect(throws: LaunchFailure.cancelled) { _ = try await running.value }
        #expect(gateway.killed.count == gateway.requests.count)
    }

    @Test func earlyExitBeforeOutputIsAStartFailure() {
        #expect(LaunchExitClassifier.classify(firstOutputSeen: false, code: 127, signal: nil, agent: "Claude Code")
            == .failedToStart("Claude Code exited with code 127 before it printed anything."))
        #expect(LaunchExitClassifier.classify(firstOutputSeen: true, code: 1, signal: nil, agent: "Claude Code") == .exited)
        #expect(LaunchExitClassifier.classify(firstOutputSeen: false, code: 0, signal: nil, agent: "Terminal") == .exited)
        if case .failedToStart = LaunchExitClassifier.classify(firstOutputSeen: false, code: nil, signal: 9, agent: "x") {} else { Issue.record("signal") }
    }
}
