import RackyPlatform
import Foundation
import Testing

@testable import RackyDocker

/// BK-12: o `DockerClient` por um socket encaminhado (túnel SSH) sem sshd. O mestre é um proxy local de socket.
@Suite("BK-12 - transporte Docker por túnel SSH (sem sshd)")
struct RemoteTunnelTests {
    private func fakeEngine() async throws -> FakeDockerDaemon {
        try await FakeDockerDaemon { request, connection in
            switch request.path {
            case "/_ping": await Reply.text(connection, "OK")
            case "/v1.43/version": await Reply.json(connection, body: Data(#"{"Version":"27.0.0","ApiVersion":"1.43","MinAPIVersion":"1.24","Os":"linux","Arch":"arm64","KernelVersion":"6.1"}"#.utf8))
            case "/v1.43/containers/c1/exec": await Reply.json(connection, status: 201, body: Data(#"{"Id":"exec1"}"#.utf8))
            case "/v1.43/exec/exec1/start":
                try? await connection.send(Data("HTTP/1.1 101 UPGRADED\r\nContent-Type: application/vnd.docker.multiplexed-stream\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n".utf8))
                var input = Data()
                while let chunk = try? await connection.receive() { input.append(chunk) }
                try? await connection.send(Reply.mux(1, String(decoding: input, as: UTF8.self).uppercased()) + Reply.mux(2, "ok\n"))
            case "/v1.43/exec/exec1/json": await Reply.json(connection, body: Data(#"{"Running":false,"ExitCode":0,"Pid":1}"#.utf8))
            case "/v1.43/events":
                let event = #"{"Type":"container","Action":"start","Actor":{"ID":"c1","Attributes":{"racky.test":"1"}},"time":1}"# + "\n"
                await Reply.chunked(connection, chunks: [Data(event.utf8.prefix(40)), Data(event.utf8.dropFirst(40))])
            default: await Reply.json(connection, status: 404, body: Data(#"{"message":"?"}"#.utf8))
            }
        }
    }

    @Test func dockerClientWorksOverForwardedSocketIncludingExecHijackAndEvents() async throws {
        let engine = try await fakeEngine()
        defer { engine.stop() }
        let fixture = try TunnelFixture()
        defer { fixture.cleanup() }
        let runner = ForwardingTunnelRunner(targetSocket: engine.socketPath)
        let tunnel = try SSHTunnel(endpoint: fixture.endpoint, directory: fixture.tunnelDirectory, runner: runner)
        try await tunnel.start()

        try await tunnel.client.ping()
        #expect(try await tunnel.client.version().version == "27.0.0")
        // exec com hijack (stdin com half-close, stdout/stderr demultiplexados) pelo socket encaminhado
        let result = try await tunnel.client.run(in: "c1", command: ["cat"], stdin: Data("via tunnel".utf8), killableGroup: false)
        #expect(result.stdoutString == "VIA TUNNEL" && result.stderrString == "ok\n" && result.exitCode == 0)
        // eventos em streaming
        var actions: [String] = []
        for try await event in try await tunnel.client.events() { actions.append(event.baseAction) }
        #expect(actions == ["start"])
        await tunnel.stop()
        #expect(!FileManager.default.fileExists(atPath: tunnel.localSocketPath))
    }

    @Test func masterArgumentsForwardTheDockerSocketAndLockDownSSH() async throws {
        let engine = try await fakeEngine()
        defer { engine.stop() }
        let fixture = try TunnelFixture()
        defer { fixture.cleanup() }
        let runner = ForwardingTunnelRunner(targetSocket: engine.socketPath)
        let tunnel = try SSHTunnel(endpoint: fixture.endpoint, directory: fixture.tunnelDirectory, runner: runner)
        try await tunnel.start()
        let argv = try #require(await runner.launched.first)
        #expect(argv.contains("-N") && argv.contains("-M"))
        #expect(argv.contains("\(tunnel.localSocketPath):/var/run/docker.sock"))
        #expect(argv.last == "racky@203.0.113.7")
        await tunnel.stop()
    }

    @Test func masterCrashReconnectsAndReappliesForwardsOnTheSameLocalPorts() async throws {
        let engine = try await fakeEngine()
        defer { engine.stop() }
        let fixture = try TunnelFixture()
        defer { fixture.cleanup() }
        let runner = ForwardingTunnelRunner(targetSocket: engine.socketPath)
        let tunnel = try SSHTunnel(
            endpoint: fixture.endpoint, directory: fixture.tunnelDirectory, runner: runner,
            backoff: TunnelBackoff(initial: .milliseconds(10), max: .milliseconds(40)), sleep: { try await Task.sleep(for: min($0, .milliseconds(20))) })
        try await tunnel.start()
        let admin = try await tunnel.forward(remotePort: 49153, key: "comp-1")
        let sameAgain = try await tunnel.forward(remotePort: 49153, key: "comp-1")
        #expect(admin == sameAgain && (1024 ... 65535).contains(admin))
        #expect(await runner.forwardCommands("forward").count == 1, "idempotente: não pede o mesmo -L duas vezes")

        await runner.crashMaster()
        // O supervisor percebe a queda e religa: espera a religação ser contada e o estado voltar a connected.
        let deadline = ContinuousClock.now + .seconds(5)
        while await tunnel.reconnectCount < 1, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try await tunnel.waitConnected(timeout: .seconds(5))
        try await tunnel.client.ping()
        #expect(await runner.launched.count == 2)
        #expect(await tunnel.reconnectCount == 1)
        let reapplied = await runner.forwardCommands("forward")
        #expect(reapplied.count == 2 && reapplied.last?.contains("127.0.0.1:\(admin):127.0.0.1:49153") == true)

        await tunnel.cancelForwards(key: "comp-1")
        #expect(await runner.forwardCommands("cancel").count == 1)
        #expect(await tunnel.activeForwardCount() == 0)
        await tunnel.stop()
    }

    @Test func launchFailuresBackOffAndGiveUpAfterTheLimit() async throws {
        let fixture = try TunnelFixture()
        defer { fixture.cleanup() }
        let runner = ForwardingTunnelRunner(targetSocket: "/nonexistent")
        await runner.setFailLaunch(100)
        let tunnel = try SSHTunnel(
            endpoint: fixture.endpoint, directory: fixture.tunnelDirectory, runner: runner,
            backoff: TunnelBackoff(initial: .milliseconds(1), max: .milliseconds(4), maxAttempts: 3), sleep: { _ in })
        await #expect(throws: SSHTunnelError.self) { try await tunnel.start() }
        #expect(await runner.launched.count == 4, "1 tentativa + 3 religações")
        if case .failed = await tunnel.state {} else { Issue.record("deveria estar .failed") }
        await tunnel.stop()
    }

    @Test func backoffGrowsExponentiallyUpToTheCeiling() {
        let backoff = TunnelBackoff(initial: .seconds(1), max: .seconds(30))
        #expect([1, 2, 3, 4, 5, 6, 7].map { backoff.delay(forAttempt: $0) } == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30), .seconds(30)])
    }

    @Test func forwardFailsClearlyWhenNotConnectedOrWhenSSHRefuses() async throws {
        let engine = try await fakeEngine()
        defer { engine.stop() }
        let fixture = try TunnelFixture()
        defer { fixture.cleanup() }
        let runner = ForwardingTunnelRunner(targetSocket: engine.socketPath)
        let tunnel = try SSHTunnel(endpoint: fixture.endpoint, directory: fixture.tunnelDirectory, runner: runner)
        await #expect(throws: SSHTunnelError.notConnected) { _ = try await tunnel.forward(remotePort: 1, key: "k") }
        try await tunnel.start()
        await runner.setForwardStatus(255)
        await #expect(throws: SSHTunnelError.self) { _ = try await tunnel.forward(remotePort: 49153, key: "k") }
        await tunnel.stop()
    }

    @Test func heartbeatRunsTheFixedCommandThroughTheMaster() async throws {
        let engine = try await fakeEngine()
        defer { engine.stop() }
        let fixture = try TunnelFixture()
        defer { fixture.cleanup() }
        let runner = ForwardingTunnelRunner(targetSocket: engine.socketPath)
        let tunnel = try SSHTunnel(endpoint: fixture.endpoint, directory: fixture.tunnelDirectory, runner: runner)
        try await tunnel.start()
        let result = try await tunnel.runRemote("date +%s > /var/lib/racky/heartbeat")
        #expect(result.status == 0)
        let argv = try #require(await runner.commands.last)
        #expect(argv.suffix(2) == ["--", "date +%s > /var/lib/racky/heartbeat"] && argv.contains("-S"))
        await tunnel.stop()
    }

    @Test func remoteHostAccessForwardsPublishedPortsPerComputer() async throws {
        let engine = try await fakeEngine()
        defer { engine.stop() }
        let fixture = try TunnelFixture()
        defer { fixture.cleanup() }
        let runner = ForwardingTunnelRunner(targetSocket: engine.socketPath)
        let tunnel = try SSHTunnel(endpoint: fixture.endpoint, directory: fixture.tunnelDirectory, runner: runner)
        try await tunnel.start()
        let access = RemoteHostAccess(remote: RemoteHost(id: "i-1", provider: "fake", region: "us-east-1", address: "203.0.113.7"), tunnel: tunnel)
        #expect(access.host.isRemote && access.storage == .volumes)
        let local = try await access.reach(publishedPort: 49200, computerID: "c-1")
        #expect((1024 ... 65535).contains(local))
        #expect(await tunnel.activeForwardCount() == 1)
        await access.releaseForwards(computerID: "c-1")
        #expect(await tunnel.activeForwardCount() == 0)
        let localAccess = LocalHostAccess(client: engine.client)
        #expect(try await localAccess.reach(publishedPort: 49200, computerID: "c") == 49200 && localAccess.storage == .hostBinds)
        await tunnel.stop()
    }
}

@Suite("BK-12 - argv do ssh, known_hosts e chaves")
struct SSHCommandTests {
    private func endpoint(user: String = "racky", host: String = "203.0.113.7", port: Int = 22) -> SSHEndpoint {
        SSHEndpoint(user: user, host: host, port: port, identityFile: URL(fileURLWithPath: "/k/id"), knownHostsFile: URL(fileURLWithPath: "/k/known_hosts"))
    }

    @Test func masterArgvIsStrictAndNonInteractive() {
        let argv = SSHCommand.master(endpoint(port: 2222), localSocket: "/t/docker.sock", control: "/t/ctl")
        func value(after flag: String, matching: String) -> Bool {
            zip(argv, argv.dropFirst()).contains { $0.0 == flag && $0.1 == matching }
        }
        for option in ["StrictHostKeyChecking=yes", "UserKnownHostsFile=/k/known_hosts", "GlobalKnownHostsFile=/dev/null", "BatchMode=yes", "IdentitiesOnly=yes",
                       "IdentityAgent=none", "PasswordAuthentication=no", "ForwardAgent=no", "ExitOnForwardFailure=yes", "ServerAliveInterval=15",
                       "StreamLocalBindMask=0177"] {
            #expect(value(after: "-o", matching: option), "falta -o \(option)")
        }
        #expect(value(after: "-i", matching: "/k/id") && value(after: "-p", matching: "2222") && value(after: "-S", matching: "/t/ctl"))
        #expect(value(after: "-L", matching: "/t/docker.sock:/var/run/docker.sock"))
        #expect(argv.contains("-N") && argv.contains("-M") && argv.last == "racky@203.0.113.7")
        #expect(!argv.contains("-A") && !argv.contains("-X") && !argv.contains("-Y"))
    }

    @Test func forwardsBindOnlyLoopbackAndUseTheControlSocket() {
        let add = SSHCommand.forward(endpoint(), localPort: 51000, remotePort: 49153, control: "/t/ctl")
        #expect(add.starts(with: ["-O", "forward", "-L", "127.0.0.1:51000:127.0.0.1:49153"]) && add.contains("/t/ctl"))
        let cancel = SSHCommand.forward(endpoint(), localPort: 51000, remotePort: 49153, control: "/t/ctl", cancel: true)
        #expect(cancel.starts(with: ["-O", "cancel"]))
        let remote = SSHCommand.remote(endpoint(), control: "/t/ctl", command: "touch x")
        #expect(remote.suffix(3) == ["racky@203.0.113.7", "--", "touch x"])
    }

    @Test func endpointRejectsOptionInjectionAndBadPorts() throws {
        try endpoint().validate()
        for bad in ["-oProxyCommand=evil", "a b", "", "x;y", "h\nost"] {
            #expect(throws: SSHConfigError.self) { try endpoint(host: bad).validate() }
            #expect(throws: SSHConfigError.self) { try endpoint(user: bad).validate() }
        }
        #expect(throws: SSHConfigError.self) { try endpoint(port: 0).validate() }
        #expect(throws: SSHConfigError.self) { try endpoint(port: 70000).validate() }
    }

    @Test func identityFileMustBeOwnerOnly() throws {
        let fixture = try TunnelFixture()
        defer { fixture.cleanup() }
        try fixture.endpoint.validateFiles()
        chmod(fixture.endpoint.identityFile.path, 0o640)
        #expect(throws: SSHConfigError.self) { try fixture.endpoint.validateFiles() }
        try FileManager.default.removeItem(at: fixture.endpoint.knownHostsFile)
        chmod(fixture.endpoint.identityFile.path, 0o600)
        #expect(throws: SSHConfigError.missingFile(fixture.endpoint.knownHostsFile.path)) { try fixture.endpoint.validateFiles() }
    }

    @Test func knownHostsLineIsPinnedAndRejectsWildcards() throws {
        let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGJhZGJhZGJhZGJhZGJhZGJhZGJhZGJhZGJhZGJhZGJh comment-is-dropped"
        #expect(try KnownHosts.line(host: "203.0.113.7", publicKey: key) == "203.0.113.7 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGJhZGJhZGJhZGJhZGJhZGJhZGJhZGJhZGJhZGJhZGJh\n")
        #expect(try KnownHosts.line(host: "h.example", port: 2222, publicKey: key).hasPrefix("[h.example]:2222 ssh-ed25519 "))
        for host in ["*", "a,b", "!x", "a b", ""] { #expect(throws: SSHConfigError.self) { try KnownHosts.line(host: host, publicKey: key) } }
        #expect(throws: SSHConfigError.self) { try KnownHosts.line(host: "h", publicKey: "not a key") }
        #expect(throws: SSHConfigError.self) { try KnownHosts.line(host: "h", publicKey: "ssh-ed25519 !!!notbase64") }
    }

    @Test func generatedKeyPairIsPrivateAndUsable() async throws {
        let fixture = try TunnelFixture()
        defer { fixture.cleanup() }
        let pair = try await SSHKeyPair.generate(in: fixture.directory.appendingPathComponent("keys"))
        let mode = (try FileManager.default.attributesOfItem(atPath: pair.privateKey.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(mode & 0o077 == 0)
        #expect(pair.publicKey.hasPrefix("ssh-ed25519 "))
        let line = try KnownHosts.line(host: "203.0.113.9", publicKey: pair.publicKey)
        #expect(line.contains(pair.publicKey))
    }
}

@Suite("BK-12 - executor real de processos do túnel (com /bin/sh no lugar do ssh)")
struct ProcessTunnelRunnerTests {
    @Test func runReportsStatusAndStderrAndTimesOut() async throws {
        let runner = ProcessTunnelRunner(executable: "/bin/sh")
        let failed = try await runner.run(["-c", "echo denied >&2; exit 3"], timeout: .seconds(5))
        #expect(failed.status == 3 && failed.stderr.contains("denied"))
        let slow = try await runner.run(["-c", "sleep 30"], timeout: .milliseconds(200))
        #expect(slow.status == 255 && slow.stderr.contains("tempo esgotado"))
    }

    @Test func launchedMasterCanBeTerminatedAndTheWaitIsCancellable() async throws {
        let runner = ProcessTunnelRunner(executable: "/bin/sh")
        let process = try await runner.launch(["-c", "sleep 30"])
        let waiter = Task { await process.waitUntilExit() }
        try await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        #expect(await waiter.value == Int32.min, "espera cancelada não prende o chamador")
        process.terminate()
        #expect(await process.waitUntilExit() == 15)
    }

    @Test func launchedProcessKeepsTheStderrTailForDiagnostics() async throws {
        let process = try ManagedProcess.launch(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo 'Permission denied (publickey)' >&2; exit 255"], environment: [:])
        #expect(await process.waitUntilExit() == 255)
        try await Task.sleep(for: .milliseconds(100))
        #expect(process.stderrTail.contains("Permission denied"))
    }
}
