import Foundation
import Testing
@testable import RackyPlatform

@Suite(.tags(.integration)) struct ProcessRunnerTests {
    private func request(_ exe: String, _ args: [String], timeout: Duration = .seconds(10),
                         max: Int = 1_000_000, env: [String: String] = [:]) -> ProcessRequest {
        ProcessRequest(executable: URL(fileURLWithPath: exe), arguments: args, environment: env,
                       timeout: timeout, maxOutputBytes: max)
    }

    @Test func capturesStdoutStderrAndExitCode() async throws {
        let out = try await ProcessRunner.run(request("/bin/sh", ["-c", "echo hi; echo err >&2; exit 3"]))
        #expect(out.exitCode == 3)
        #expect(out.stdoutString == "hi\n")
        #expect(out.stderrString == "err\n")
        #expect(!out.truncated)
    }

    @Test func passesEnvironmentOverlay() async throws {
        let out = try await ProcessRunner.run(request("/usr/bin/env", [], env: ["AB_TEST_VAR": "42"]))
        #expect(out.stdoutString.contains("AB_TEST_VAR=42"))
    }

    @Test func missingExecutableIsLaunchFailure() async {
        await #expect(throws: ProcessRunnerError.self) {
            _ = try await ProcessRunner.run(request("/nonexistent/binary", []))
        }
    }

    @Test func missingWorkingDirectoryFailsWithoutSpawning() async {
        var req = request("/bin/echo", ["hi"])
        req.currentDirectory = URL(fileURLWithPath: "/nonexistent/racky-folder", isDirectory: true)
        await #expect(throws: ProcessRunnerError.self) { _ = try await ProcessRunner.run(req) }
    }

    /// O crash da demo (30/10): cada execução que não chegava a rodar deixava os pipes abertos, e o app passou de 4 mil descritores.
    @Test func runsDoNotLeakFileDescriptors() async throws {
        func openDescriptors() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0 }
        _ = try await ProcessRunner.run(request("/bin/echo", ["warm"]))
        let before = openDescriptors()
        for _ in 0..<60 {
            _ = try? await ProcessRunner.run(request("/nonexistent/binary", []))
            _ = try await ProcessRunner.run(request("/bin/echo", ["hi"], timeout: .seconds(120)))
        }
        try await Task.sleep(for: .milliseconds(300))
        // Antes: 4 por falha + 2 por execução que esperava o prazo (360 aqui). A folga cobre os outros testes rodando ao lado.
        #expect(openDescriptors() - before < 60)
    }

    @Test func timeoutKillsProcess() async throws {
        let start = ContinuousClock.now
        do {
            _ = try await ProcessRunner.run(request("/bin/sleep", ["30"], timeout: .milliseconds(300)))
            Issue.record("deveria ter estourado o tempo")
        } catch let error as ProcessRunnerError {
            #expect(error == .timedOut)
        }
        // Folga para a máquina carregada (a suíte inteira em paralelo): o que importa é não esperar os 30 s.
        #expect(ContinuousClock.now - start < .seconds(15))
    }

    @Test func cancellationKillsProcess() async throws {
        let task = Task { try await ProcessRunner.run(request("/bin/sleep", ["30"])) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("deveria ter sido cancelado")
        } catch let error as ProcessRunnerError {
            #expect(error == .cancelled)
        }
    }

    @Test func outputIsBounded() async throws {
        let out = try await ProcessRunner.run(request("/bin/sh", ["-c", "yes x | head -c 500000"], max: 1000))
        #expect(out.stdout.count == 1000)
        #expect(out.truncated)
    }

    @Test func largeOutputDoesNotDeadlock() async throws {
        let out = try await ProcessRunner.run(request("/bin/sh", ["-c", "yes x | head -c 3000000"], max: 10_000_000))
        #expect(out.stdout.count == 3_000_000)
    }

    @Test func backgroundGrandchildHoldingPipeDoesNotHangResult() async throws {
        let start = ContinuousClock.now
        let out = try await ProcessRunner.run(request("/bin/sh", ["-c", "sleep 30 & echo done"]))
        #expect(out.stdoutString == "done\n")
        // Bem abaixo dos 30 s do neto, com folga para a suíte carregada.
        #expect(ContinuousClock.now - start < .seconds(15))
    }

    /// AR-404: esperar processos não pode ocupar o pool cooperativo.
    @Test func manyConcurrentProcessesDoNotStarveTheCooperativePool() async throws {
        let count = max(16, ProcessInfo.processInfo.activeProcessorCount * 3)
        async let batch: [Int32] = withThrowingTaskGroup(of: Int32.self) { group in
            for _ in 0..<count {
                group.addTask { try await ProcessRunner.run(request("/bin/sleep", ["1"])).exitCode }
            }
            var codes: [Int32] = []
            for try await code in group { codes.append(code) }
            return codes
        }
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        try await Task.sleep(for: .milliseconds(50))
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .milliseconds(400), "pool cooperativo parece bloqueado: \(elapsed)")
        let codes = try await batch
        #expect(codes.count == count)
        #expect(codes.allSatisfy { $0 == 0 })
    }
}
