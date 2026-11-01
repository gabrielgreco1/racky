import RackyCore
import RackyProtocol
import Darwin
import Foundation
import Testing

@testable import RackyPlatform

/// F30: trocar de build ou de pasta nunca derruba o daemon nem as sessões. Daemon real de teste (`RACKY_HOME` isolado).
@Suite(.serialized, .tags(.integration), .timeLimit(.minutes(1))) struct DaemonSurvivalTests {
    private func alive(_ pid: Int32) -> Bool { pid > 0 && Darwin.kill(pid, 0) == 0 }

    private func waitGone(_ pid: Int32) async -> Bool {
        for _ in 0 ..< 100 {
            if !alive(pid) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// Dois "apps" (builds e caminhos de bundle diferentes) conectam ao mesmo daemon: o segundo vê a sessão do primeiro viva.
    @Test func twoAppsFromDifferentBuildsShareOneDaemonAndTheSessionSurvives() async throws {
        let harness = try DaemonHarness()
        defer { harness.terminateNow() }
        try await harness.start()
        let appA = harness.makeClient(build: "1.0 (10) /Applications/Racky.app")
        try await appA.start()
        let create = makeCreate(["/bin/sh", "-c", "echo ALIVE-$$; exec cat"])
        _ = try await appA.create(create)
        let daemon = try #require(harness.pid)

        let appB = harness.makeClient(build: "1.0 (99) /private/tmp/otter/build/Racky.app")
        try await appB.start()
        let seenByB = try await appB.list()
        #expect(seenByB.contains { $0.sessionID == create.sessionID && $0.state == .running }, "o app de outra pasta se conecta, não substitui")
        // O app novo é mais novo: pede drain, que nunca derruba a sessão viva.
        try await appB.drainWhenIdle()
        await appA.stop()
        await appB.stop()
        try await Task.sleep(for: .seconds(1))
        #expect(alive(daemon))

        let appC = harness.makeClient(build: "1.0 (99) other")
        try await appC.start()
        #expect(try await appC.list().contains { $0.sessionID == create.sessionID && $0.state == .running }, "drain preserva a sessão viva")
        // Só quando a última sessão termina o daemon antigo sai.
        try await appC.kill(sessionID: create.sessionID, mode: .force)
        #expect(await waitGone(daemon))
        await appC.stop()
    }

    /// SIGTERM, SIGHUP e SIGINT no daemon (um `kill` por engano, o launchd de outro registro) não matam o daemon nem o PTY.
    @Test func daemonIgnoresTerminationSignalsAndOnlyShutdownEndsIt() async throws {
        let harness = try DaemonHarness()
        defer { harness.terminateNow() }
        try await harness.start()
        let client = harness.makeClient()
        try await client.start()
        let create = makeCreate(["/bin/sh", "-c", "exec cat"])
        _ = try await client.create(create)
        let daemon = try #require(harness.pid)
        for number in [SIGTERM, SIGHUP, SIGINT] { Darwin.kill(daemon, number) }
        try await Task.sleep(for: .seconds(1))
        #expect(alive(daemon), "SIGTERM do app ou de fora não encerra o daemon")
        let sessions = try await client.list()
        #expect(sessions.contains { $0.sessionID == create.sessionID && $0.state == .running }, "o PTY continua vivo")
        let pty = try #require(sessions.first { $0.sessionID == create.sessionID }?.pid)
        #expect(alive(pty))

        try await client.shutdownDaemon()
        #expect(await waitGone(daemon), "o comando shutdown do protocolo encerra o daemon")
        await client.stop()
    }

    /// Os filhos PTY não herdam a ignorância de SIGTERM do daemon: continuam encerráveis (Stop and Quit, kill graceful).
    @Test func ptyChildrenKeepTheDefaultSIGTERMDisposition() async throws {
        let harness = try DaemonHarness()
        defer { harness.terminateNow() }
        try await harness.start()
        let client = harness.makeClient()
        try await client.start()
        let create = makeCreate(["/bin/sh", "-c", "exec sleep 600"])
        _ = try await client.create(create)
        let pty = try #require(try await client.list().first { $0.sessionID == create.sessionID }?.pid)
        try await client.kill(sessionID: create.sessionID, mode: .graceful)
        #expect(await waitGone(pty), "o filho morre com SIGTERM normalmente")
        await client.stop()
    }

    /// O launcher real (C) executa o alvo do ponteiro `bin/rackyd-current` em vez do `rackyd` ao lado.
    @Test func theRealLauncherExecsTheTargetOfThePointer() throws {
        let home = URL(fileURLWithPath: "/tmp/abp-\(UInt32.random(in: 0 ... 0xFFFFFF))", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let target = home.appendingPathComponent("fake-rackyd")
        try "#!/bin/sh\necho \"ran:$0 $@\"\n".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        DaemonPointer.update(home: home, executable: target, build: "1.0 (7)")
        let binary = rackydBinary().deletingLastPathComponent().appendingPathComponent("rackyd-launch")
        try #require(FileManager.default.isExecutableFile(atPath: binary.path), "rackyd-launch precisa estar construído ao lado")
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--launchd", "Listeners"]
        process.environment = ["RACKY_HOME": home.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(output.contains("ran:\(target.path) --launchd Listeners"), "executou: \(output)")
    }
}
