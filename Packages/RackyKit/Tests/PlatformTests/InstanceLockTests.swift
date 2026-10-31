import Foundation
import Testing

@testable import RackyPlatform

struct InstanceLockTests {
    @Test func secondInstanceOfTheSameDataFolderGetsTheOwnersPidAndAnotherFolderIsFree() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("abx-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let mine = base.appendingPathComponent("a/run"), other = base.appendingPathComponent("b/run")
        #expect(InstanceLock.acquire(runDirectory: mine) == nil, "primeira: o lock é nosso")
        #expect(InstanceLock.acquire(runDirectory: mine) == ProcessInfo.processInfo.processIdentifier, "segunda na mesma pasta: recebe o pid da dona")
        #expect(InstanceLock.acquire(runDirectory: other) == nil, "outra pasta de dados (cópia de teste) não é bloqueada")
    }
}
