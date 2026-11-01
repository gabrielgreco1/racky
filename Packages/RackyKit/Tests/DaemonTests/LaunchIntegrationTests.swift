import RackyCore
import RackyPlatform
import RackyProtocol
import Foundation
import Synchronization
import Testing

/// Coletor de eventos do coordenador (qualquer thread).
private final class Events: @unchecked Sendable {  // SAFETY: estado sob `lock`.
    private let lock = Mutex<[LaunchEvent]>([])
    func add(_ event: LaunchEvent) { lock.withLock { $0.append(event) } }
    var all: [LaunchEvent] { lock.withLock { $0 } }
    func statuses(_ key: LaunchStepKey) -> [LaunchStepStatus] {
        all.compactMap { if case .step(let p) = $0, p.step == key { p.status } else { nil } }
    }
}

/// `LaunchCoordinator` contra o `rackyd` real (T1-16): zsh de verdade, `claude -p --model haiku` de verdade (opt-in por
/// custo) e CLI ausente. Verifica os estados running -> exited no daemon e os eventos de progresso reais.
@Suite(.tags(.integration), .serialized, .timeLimit(.minutes(1))) struct LaunchIntegrationTests {
    private func coordinator(_ harness: DaemonHarness, client: PTYClient, login: @escaping @Sendable () async -> [String: String]) -> LaunchCoordinator {
        let gateway = PTYLaunchGateway(client: client, ensureConnected: { (try? await client.start()) != nil })
        return LaunchCoordinator(
            daemon: gateway,
            configuration: .init(
                launchRoot: harness.home.appendingPathComponent("run/launch", isDirectory: true), appSocketPath: harness.home.appendingPathComponent("run/app.sock").path,
                loginEnvironment: login))
    }

    private func waitFor(_ client: PTYClient, _ id: SessionID, state: SessionState, timeout: Duration = .seconds(60)) async throws -> SessionSummary {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let s = try await client.list().first(where: { $0.sessionID == id }), s.state == state { return s }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw HarnessError.timeout("session \(id) never reached \(state)")
    }

    @Test func zshRunsThenExits() async throws {
        let harness = try DaemonHarness()
        defer { harness.terminateNow() }
        try await harness.start()
        let client = harness.makeClient()
        try await client.start()
        let c = coordinator(harness, client: client) { ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "SHELL": "/bin/zsh", "LANG": "en_US.UTF-8"] }
        let events = Events()
        let job = LaunchJob(terminalID: UUID(), spec: LaunchSpec(provider: .shell), cwd: "/tmp")
        let result = try await c.launch(job, onEvent: events.add)
        #expect(events.statuses(.ptySpawn) == [.running, .done])
        #expect(events.statuses(.cliExec) == [.running])
        let id = result.summary.sessionID
        let running = try await waitFor(client, id, state: .running)
        #expect(running.argv0.hasSuffix("zsh"))
        // Nada do app foi digitado no PTY (T11).
        #expect(running.inputBytesByOrigin.total == 0)
        await c.noteFirstOutput(runID: result.runID)
        #expect(events.statuses(.cliExec) == [.running, .done])
        try await client.kill(sessionID: id, mode: .graceful)
        let exited = try await waitFor(client, id, state: .exited, timeout: .seconds(10))
        #expect(exited.exit != nil)
        await client.stop()
        await harness.stop()
    }

    @Test func missingCLIIsCouldntStart() async throws {
        let harness = try DaemonHarness()
        defer { harness.terminateNow() }
        try await harness.start()
        let client = harness.makeClient()
        try await client.start()
        let c = coordinator(harness, client: client) { ["PATH": "/definitely/not/here", "HOME": "/definitely/not/here"] }
        let events = Events()
        let job = LaunchJob(terminalID: UUID(), spec: LaunchSpec(provider: .opencode), cwd: "/tmp")
        var captured: LaunchFailure?
        do { _ = try await c.launch(job, onEvent: events.add) } catch let failure as LaunchFailure { captured = failure }
        // Em máquinas com opencode em ~/.opencode/bin o executável é achado; só o caso "ausente" interessa aqui.
        if let captured, case .cliNotFound = captured {
            #expect(events.statuses(.cliResolve).last == .failed)
            #expect(try await client.list().isEmpty)
        }
        let nonexistent = LaunchJob(terminalID: UUID(), spec: LaunchSpec(provider: .custom, customArgv: ["/definitely/not/here/tool"]), cwd: "/tmp")
        await #expect(throws: LaunchFailure.self) { _ = try await c.launch(nonexistent, onEvent: events.add) }
        #expect(events.statuses(.ptySpawn).last == .failed)
        await client.stop()
        await harness.stop()
    }

    /// Custo: uma chamada `claude -p --model haiku "reply OK"`. Só com `AB_REAL_CLI=1`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AB_REAL_CLI"] == "1"))
    func claudeHaikuRunsThenExitsZero() async throws {
        let harness = try DaemonHarness()
        defer { harness.terminateNow() }
        try await harness.start()
        let client = harness.makeClient()
        try await client.start()
        let loginProvider = LoginShellEnvProvider()
        let c = coordinator(harness, client: client) { await loginProvider.environment().variables }
        let events = Events()
        let spec = LaunchSpec(provider: .claude, model: "haiku", extraArgs: ["-p"], initialPrompt: "reply OK")
        let job = LaunchJob(terminalID: UUID(), spec: spec, cwd: NSTemporaryDirectory())
        let result = try await c.launch(job, onEvent: events.add)
        let id = result.summary.sessionID
        #expect(result.plan.flattenedArgv.suffix(5).joined(separator: " ").hasSuffix("-p reply OK") || result.plan.flattenedArgv.contains("-p"))
        #expect(result.plan.nativeConversationID != nil)
        let exited = try await waitFor(client, id, state: .exited, timeout: .seconds(90))
        #expect(exited.exit?.code == 0)
        let text = try await client.textSnapshot(sessionID: id, lines: 40)
        #expect(text.contains("OK"))
        await client.stop()
        await harness.stop()
    }

    // MARK: Sessão limpa (T1-17): o agente roda na pasta gerenciada que o app acabou de criar

    private func managedFolder() throws -> (root: URL, folder: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("abx-sessions-\(UUID().uuidString)", isDirectory: true)
        return (root, try CleanSessionFolders.createManaged(root: root))
    }

    @Test func cleanSessionFolderIsTheCwdOfTheProcess() async throws {
        let harness = try DaemonHarness()
        defer { harness.terminateNow() }
        try await harness.start()
        let client = harness.makeClient()
        try await client.start()
        let (root, folder) = try managedFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = coordinator(harness, client: client) { ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "SHELL": "/bin/zsh", "LANG": "en_US.UTF-8"] }
        let events = Events()
        let spec = LaunchSpec(provider: .custom, customArgv: ["/bin/sh", "-c", "pwd -P; touch made-by-the-agent"])
        let result = try await c.launch(LaunchJob(terminalID: UUID(), spec: spec, cwd: folder.path), onEvent: events.add)
        _ = try await waitFor(client, result.summary.sessionID, state: .exited, timeout: .seconds(10))
        let text = try await client.textSnapshot(sessionID: result.summary.sessionID, lines: 20)
        #expect(text.contains(folder.resolvingSymlinksInPath().lastPathComponent))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("made-by-the-agent").path))
        await client.stop()
        await harness.stop()
    }

    @Test func zshRunsInACleanSessionFolder() async throws {
        let harness = try DaemonHarness()
        defer { harness.terminateNow() }
        try await harness.start()
        let client = harness.makeClient()
        try await client.start()
        let (root, folder) = try managedFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = coordinator(harness, client: client) { ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "SHELL": "/bin/zsh", "LANG": "en_US.UTF-8"] }
        let result = try await c.launch(LaunchJob(terminalID: UUID(), spec: LaunchSpec(provider: .shell), cwd: folder.path), onEvent: { _ in })
        let running = try await waitFor(client, result.summary.sessionID, state: .running)
        #expect(running.argv0.hasSuffix("zsh"))
        #expect(running.inputBytesByOrigin.total == 0)
        try await client.kill(sessionID: result.summary.sessionID, mode: .graceful)
        _ = try await waitFor(client, result.summary.sessionID, state: .exited, timeout: .seconds(10))
        await client.stop()
        await harness.stop()
    }

    /// Custo: `claude -p --model haiku "reply OK"` na pasta de uma sessão limpa. Só com `AB_REAL_CLI=1`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AB_REAL_CLI"] == "1"))
    func claudeHaikuRunsInACleanSessionFolder() async throws {
        let harness = try DaemonHarness()
        defer { harness.terminateNow() }
        try await harness.start()
        let client = harness.makeClient()
        try await client.start()
        let (root, folder) = try managedFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let loginProvider = LoginShellEnvProvider()
        let c = coordinator(harness, client: client) { await loginProvider.environment().variables }
        let spec = LaunchSpec(provider: .claude, model: "haiku", extraArgs: ["-p"], initialPrompt: "reply OK")
        let result = try await c.launch(LaunchJob(terminalID: UUID(), spec: spec, cwd: folder.path), onEvent: { _ in })
        #expect(result.plan.cwd == folder.path)
        let exited = try await waitFor(client, result.summary.sessionID, state: .exited, timeout: .seconds(90))
        #expect(exited.exit?.code == 0)
        #expect(try await client.textSnapshot(sessionID: result.summary.sessionID, lines: 40).contains("OK"))
        await client.stop()
        await harness.stop()
    }
}
