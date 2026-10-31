import Foundation
import Testing

/// Integração com uma VM REAL (`RACKY_TEST_VZ=1`): sobe o runtime sem Docker com os arquivos gerados localmente
/// (`scripts/vz/fetch-kernel.sh` + `scripts/vz/build-image.sh` -> `build/vz-assets`, ou `RACKY_VZ_OUT`) e confere exec, virtiofs,
/// copyIn/copyOut, segredos por stdin, a ponte até a admin API (:8790), um computador headless completo e a desmontagem.
///
/// O Virtualization.framework exige o entitlement `com.apple.security.virtualization` no processo, e o `swiftpm-testing-helper` não o
/// tem. Por isso o teste roda `scripts/vz/selftest.sh`, que compila o `racky-vz-selftest`, assina ad-hoc com o entitlement e o executa
/// com um `RACKY_HOME` temporário (nunca o do app do dono). Nenhum contêiner do Docker é tocado e nenhuma VM fica de pé.
@Suite("Runtime sem Docker (VM real)", .serialized, .enabled(if: ProcessInfo.processInfo.environment["RACKY_TEST_VZ"] == "1"), .tags(.integration), .timeLimit(.minutes(10)))
struct LiveVZTests {
    static var repoRoot: URL {
        var root = URL(fileURLWithPath: #filePath)
        while root.path != "/", !FileManager.default.fileExists(atPath: root.appendingPathComponent("scripts/vz/selftest.sh").path) { root.deleteLastPathComponent() }
        return root
    }

    @Test func bootsExecsCopiesReachesTheAdminAPIAndStops() async throws {
        let script = Self.repoRoot.appendingPathComponent("scripts/vz/selftest.sh")
        #expect(FileManager.default.isExecutableFile(atPath: script.path))
        let process = Process()
        process.executableURL = script
        process.currentDirectoryURL = Self.repoRoot
        // O `swift test` segura o lock do .build: o script usa o autoteste que este alvo de teste já compilou (dependência do VZTests).
        process.environment = ProcessInfo.processInfo.environment.merging(["RACKY_VZ_SELFTEST_NO_BUILD": "1"]) { $1 }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = await Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() }.value
        process.waitUntilExit()
        let text = String(decoding: output, as: UTF8.self)
        if let directory = ProcessInfo.processInfo.environment["RACKY_EVIDENCE_DIR"] {
            try? text.write(toFile: directory + "/vz-selftest.log", atomically: true, encoding: .utf8)
        }
        for step in [
            "ok   boot VM", "ok   exec as agent", "ok   virtiofs /work host<->guest", "ok   copyIn / copyOut", "ok   secrets by exec+stdin",
            "ok   bridge -> admin API :8790", "ok   stop VM", "ok   provision headless computer", "ok   teardown leaves nothing behind", "RESULT pass",
        ] {
            #expect(text.contains(step), "missing step '\(step)' in the self-test output:\n\(text.suffix(2000))")
        }
        #expect(process.terminationStatus == 0, "self-test failed:\n\(text.suffix(2000))")
    }
}
