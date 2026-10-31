import RackyCore
import RackyProtocol
import Darwin
import Foundation
import Testing

@testable import RackyPlatform

/// Socket entregue por descritor (T1-24, S-01): o teste faz o papel do launchd. Cria e escuta o socket, passa o fd 3 ao
/// `rackyd` (como o launchd faz) e o daemon o adota sem `unlink` nem `bind`.
@Suite(.serialized, .tags(.integration), .timeLimit(.minutes(1))) struct LaunchdSocketTests {
    /// O que o launchd faria: socket em diretório privado, `0600`, `listen` feito por quem o criou.
    private final class FakeLaunchdSocket {
        let directory: URL
        let path: String
        private(set) var fd: Int32

        init() throws {
            directory = URL(fileURLWithPath: "/tmp/abl-\(UInt32.random(in: 0 ... 0xFFFFFF))", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            path = directory.appendingPathComponent("Listeners").path
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw HarnessError.daemonDidNotStart }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            _ = withUnsafeMutablePointer(to: &address.sun_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: 104) { strncpy($0, path, 103) }
            }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 128) == 0 else { throw HarnessError.daemonDidNotStart }
        }

        func closeDescriptor() {
            if fd >= 0 { Darwin.close(fd) }
            fd = -1
        }

        func remove() {
            closeDescriptor()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// `posix_spawn` com o fd de escuta duplicado para o descritor 3 (a convenção do launchd).
    private func spawnDaemon(listenFD: Int32, home: URL, idleExit: Int, extra: [String] = []) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, listenFD, 3)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        let binary = rackydBinary().path
        let arguments = [binary, "--idle-exit", "\(idleExit == 0 ? 5 : idleExit)", "--home", home.path, "--socket-fd", "3"] + extra
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { for pointer in argv { free(pointer) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, binary, &actions, nil, &argv, environ)
        guard status == 0 else { throw HarnessError.daemonDidNotStart }
        return pid
    }

    private func isAlive(_ pid: pid_t) -> Bool {
        var status: Int32 = 0
        return waitpid(pid, &status, WNOHANG) == 0
    }

    private func waitForExit(_ pid: pid_t, timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if !isAlive(pid) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private func withRig(idleExit: Int = 0, _ body: (FakeLaunchdSocket, URL, pid_t) async throws -> Void) async throws {
        let launchd = try FakeLaunchdSocket()
        let home = URL(fileURLWithPath: "/tmp/abh-\(UInt32.random(in: 0 ... 0xFFFFFF))", isDirectory: true)
        let pid = try spawnDaemon(listenFD: launchd.fd, home: home, idleExit: idleExit)
        launchd.closeDescriptor()  // o launchd segura o socket; aqui só o daemon o mantém aberto
        defer {
            kill(pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            launchd.remove()
            try? FileManager.default.removeItem(at: home)
        }
        try await body(launchd, home, pid)
    }

    @Test func daemonAdoptsTheInheritedDescriptorAndServesSessions() async throws {
        try await withRig { launchd, home, _ in
            let client = PTYClient(configuration: PTYClientConfiguration(socketPath: launchd.path, build: "test"))
            try await client.start()
            let create = makeCreate(["/bin/sh", "-c", "echo launchd-fd-ok; sleep 30"])
            let created = try await client.create(create)
            #expect(created.spawned)
            let attachment = try await client.attach(sessionID: create.sessionID, cols: 80, rows: 24)
            let collector = Collector()
            await collector.run(attachment)
            try await eventually("output over the launchd socket") { await collector.text.contains("launchd-fd-ok") }
            // O daemon nunca fez bind: nenhum ptyd-v1.sock no home dele.
            #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("run/ptyd-v1.sock").path))
            try await client.kill(sessionID: create.sessionID, mode: .force)
            await client.stop()
        }
    }

    @Test func connectionsQueuedBeforeTheDaemonExistsAreServedOnceItStarts() async throws {
        // Ativação sob demanda: o cliente conecta com o daemon ainda parado (o launchd segura a conexão no backlog).
        let launchd = try FakeLaunchdSocket()
        let home = URL(fileURLWithPath: "/tmp/abh-\(UInt32.random(in: 0 ... 0xFFFFFF))", isDirectory: true)
        defer {
            launchd.remove()
            try? FileManager.default.removeItem(at: home)
        }
        let client = PTYClient(configuration: PTYClientConfiguration(socketPath: launchd.path, build: "test"))
        let connecting = Task { try await client.start() }
        try await Task.sleep(for: .milliseconds(300))  // ninguém atende ainda
        let pid = try spawnDaemon(listenFD: launchd.fd, home: home, idleExit: 0)
        defer {
            kill(pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
        // O primeiro handshake pode estourar (2 s) enquanto o daemon sobe; o app tenta de novo, como no `establish()`.
        _ = try? await connecting.value
        var connected = false
        for _ in 0 ..< 5 where !connected {
            connected = (try? await client.start()) != nil
        }
        #expect(connected)
        let pong = try await client.ping()
        #expect(pong.activeSessions == 0)
        await client.stop()
    }

    @Test func idleDaemonExitsAndLeavesTheLaunchdSocketInPlace() async throws {
        try await withRig(idleExit: 1) { launchd, _, pid in
            let client = PTYClient(configuration: PTYClientConfiguration(socketPath: launchd.path, build: "test", reconnectMaxAttempts: 0))
            try await client.start()
            await client.stop()
            #expect(await waitForExit(pid), "sem sessões nem clientes, o daemon sai sozinho (06 §1.2)")
            // O arquivo do socket é do launchd: o daemon não faz unlink (senão o launchd não relançaria na próxima conexão).
            #expect(FileManager.default.fileExists(atPath: launchd.path))
        }
    }

    @Test func liveSessionsKeepTheDaemonAliveAfterTheClientLeaves() async throws {
        try await withRig(idleExit: 1) { launchd, _, pid in
            let client = PTYClient(configuration: PTYClientConfiguration(socketPath: launchd.path, build: "test"))
            try await client.start()
            let create = makeCreate(["/bin/sleep", "600"])
            _ = try await client.create(create)
            await client.stop()  // o app fechou
            try await Task.sleep(for: .seconds(3))
            #expect(isAlive(pid), "com sessão viva o daemon fica, mesmo sem cliente (P4)")
            let again = PTYClient(configuration: PTYClientConfiguration(socketPath: launchd.path, build: "test"))
            try await again.start()
            let listed = try await again.list()
            #expect(listed.contains { $0.sessionID == create.sessionID && $0.state == .running })
            try await again.kill(sessionID: create.sessionID, mode: .force)
            await again.stop()
        }
    }

    @Test func drainWhenIdleExitsOnceTheLastSessionEnds() async throws {
        try await withRig { launchd, _, pid in
            let client = PTYClient(configuration: PTYClientConfiguration(socketPath: launchd.path, build: "old"))
            try await client.start()
            let create = makeCreate(["/bin/sleep", "600"])
            _ = try await client.create(create)
            try await client.drainWhenIdle()
            try await Task.sleep(for: .seconds(1))
            #expect(isAlive(pid), "drain não derruba sessões vivas")
            try await client.kill(sessionID: create.sessionID, mode: .force)
            #expect(await waitForExit(pid), "ao terminar a última sessão o daemon sai e o launchd sobe o binário novo na próxima conexão")
            await client.stop()
        }
    }

    @Test func invalidDescriptorFailsFast() async throws {
        let home = URL(fileURLWithPath: "/tmp/abh-\(UInt32.random(in: 0 ... 0xFFFFFF))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let process = Process()
        process.executableURL = rackydBinary()
        process.arguments = ["--home", home.path, "--socket-fd", "not-a-number"]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 64)
    }
}
