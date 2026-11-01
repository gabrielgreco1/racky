import Foundation
import Testing

@testable import RackyCore

@Suite("Transcript e logs da execução só do dono")
struct RunFolderPermissionsTests {
    private func mode(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber)?.intValue ?? -1
    }

    @Test func transcriptAndLogFilesAreOwnerOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("run-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let run = RunFolder(root: root)
        try run.ensureLayout()
        #expect(mode(run.transcript) == 0o700)
        let log = ChainedLog(file: run.requestsFile)
        _ = try await log.append(["kind": .string("x")])
        #expect(mode(run.requestsFile) == 0o600)
    }
}
