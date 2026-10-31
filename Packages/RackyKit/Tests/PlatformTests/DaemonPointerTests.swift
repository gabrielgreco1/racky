import Darwin
import Foundation
import Testing

@testable import RackyPlatform

/// F30: o launcher estável aponta para o `rackyd` da versão instalada mais nova; abrir um app mais antigo de outra pasta
/// não troca o daemon que o launchd sobe.
@Suite struct DaemonPointerTests {
    private func home() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/abp-\(UInt32.random(in: 0 ... 0xFFFFFF))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func executable(_ directory: URL, _ name: String, script: String = "#!/bin/sh\necho \"$0 $@\"\n") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test func buildNumbersParse() {
        #expect(DaemonPointer.buildNumber("1.0 (41)") == 41)
        #expect(DaemonPointer.buildNumber("57") == 57)
        #expect(DaemonPointer.buildNumber("1.0 (dev)") == 0)
    }

    @Test func newestBuildWinsAndAnOlderAppFromAnotherFolderDoesNotTakeOver() throws {
        let h = try home()
        defer { try? FileManager.default.removeItem(at: h) }
        let installed = try executable(h, "installed-rackyd")
        let scratch = try executable(h, "scratch-rackyd")
        #expect(DaemonPointer.update(home: h, executable: installed, build: "1.0 (50)"))
        #expect(DaemonPointer.read(home: h) == DaemonPointer(path: installed.path, build: 50))
        #expect(!DaemonPointer.update(home: h, executable: scratch, build: "1.0 (49)"), "build menor de outra pasta não troca")
        #expect(DaemonPointer.read(home: h)?.path == installed.path)
        #expect(DaemonPointer.update(home: h, executable: scratch, build: "1.0 (51)"), "build maior assume")
        try FileManager.default.removeItem(at: scratch)
        #expect(DaemonPointer.update(home: h, executable: installed, build: "1.0 (10)"), "ponteiro para binário apagado é refeito")
    }
}
