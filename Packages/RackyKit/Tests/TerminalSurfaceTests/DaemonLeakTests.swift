import RackyCore
import RackyProtocol
import Darwin
import Foundation
import Testing

@testable import RackyUI

/// F34: daemon de teste com sessão viva (`exec cat`) não pode sobreviver à limpeza do teste. O `rackyd` ignora SIGTERM e
/// não sai ocioso com sessões, então só `shutdown` (protocolo) ou SIGKILL o encerram.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)), .tags(.integration)) struct DaemonLeakTests {
    private func gone(_ pid: Int32, within seconds: Int = 5) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if kill(pid, 0) != 0 { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return kill(pid, 0) != 0
    }

    @Test func harnessStopEndsTheDaemonEvenWithALiveSession() async throws {
        let harness = try DaemonHarness()
        try await harness.start()
        let pid = try #require(harness.pid)
        let client = harness.makeClient()
        try await client.start()
        _ = try await client.create(makeCreate(["/bin/sh", "-c", "exec cat"]))
        #expect(kill(pid, 0) == 0)
        await client.stop()
        await harness.stop()
        #expect(await gone(pid), "daemon \(pid) sobreviveu ao stop do harness")
        #expect(!FileManager.default.fileExists(atPath: harness.home.path), "o home temporário é removido")
    }

    @Test func childDaemonOfARuntimeIsEndedByTheSharedCleanup() async throws {
        let home = URL(fileURLWithPath: "/tmp/abt-\(UInt32.random(in: 0 ... 0xFFFFFF))", isDirectory: true)
        defer { DaemonReaper.reap(home: home); try? FileManager.default.removeItem(at: home) }
        let runtime = TerminalRuntime(
            configuration: .init(
                daemonHome: home, daemonExecutable: rackydBinary(), stopDaemonOnQuit: false, appSocketPath: "/tmp/none.sock",
                loginEnvironment: { ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()] }),
            registry: nil, elements: nil)
        #expect(await runtime.connect())
        let pid = runtime.daemonPID
        #expect(pid > 0)
        _ = try await runtime.client.create(makeCreate(["/bin/sh", "-c", "exec cat"]))
        #expect(DaemonReaper.children(home: home).map(\.pid) == [pid], "o reaper enxerga o filho do runtime pelo --home")
        await runtime.client.stop()
        await DaemonReaper.shutdown(home: home)
        #expect(await gone(pid), "daemon filho \(pid) sobreviveu à limpeza")
    }

    @Test func reapKillsOnlyChildrenOfThisHome() async throws {
        let a = try DaemonHarness(), b = try DaemonHarness()
        try await a.start()
        try await b.start()
        defer { a.terminateNow(); b.terminateNow() }
        let pidA = try #require(a.pid), pidB = try #require(b.pid)
        DaemonReaper.reap(home: a.home)
        #expect(await gone(pidA))
        #expect(kill(pidB, 0) == 0, "o daemon de outro home não é tocado")
    }
}
