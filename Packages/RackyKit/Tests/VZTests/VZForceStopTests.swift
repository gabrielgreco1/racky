import Foundation
import Testing

@testable import RackyVZ

/// Desligamento de VM travada (02/11): prazo para o stop educado e SIGKILL só no processo do Virtualization.framework.
@Suite struct VZForceStopTests {
    @Test func lsofOutputBecomesPids() {
        #expect(VZForceStop.pids(fromLsof: "22067\n22069\n\n") == [22067, 22069])
        #expect(VZForceStop.pids(fromLsof: "").isEmpty)
    }

    @Test func aHungStopIsAbandonedAfterTheDeadline() async {
        let start = ContinuousClock.now
        let finished = await VZForceStop.finishes(within: .milliseconds(200)) { try? await Task.sleep(for: .seconds(30)) }
        #expect(!finished)
        #expect(ContinuousClock.now - start < .seconds(20), "não espera os 30 s do stop travado (folga para máquina carregada)")
        #expect(await VZForceStop.finishes(within: .seconds(5)) {})
    }

    @Test func neverKillsAProcessThatIsNotAVirtualMachine() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("vz-force-\(UUID().uuidString).ext4")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        holder.arguments = ["-f", file.path]
        try holder.run()
        defer { holder.terminate() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await VZForceStop.killVM(holding: file).isEmpty)
        #expect(holder.isRunning)
    }
}
