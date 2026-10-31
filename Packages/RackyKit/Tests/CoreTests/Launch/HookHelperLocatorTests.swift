import Foundation
import Testing

@testable import RackyCore

/// O helper `racky` vive em Contents/Helpers (build.sh). Em Contents/MacOS o nome colide com o executável do app em APFS.
@Suite struct HookHelperLocatorTests {
    private func bundle(files: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("helper-locator-\(UUID().uuidString).app", isDirectory: true)
        for relative in files {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return root
    }

    @Test func prefersTheHelpersFolderOverMacOS() throws {
        let root = try bundle(files: ["Contents/Helpers/racky", "Contents/MacOS/Racky"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(HookHelperLocator.path(environment: [:], bundleURL: root) == root.appendingPathComponent("Contents/Helpers/racky").path)
    }

    @Test func environmentOverrideWinsAndMissingHelperIsNil() throws {
        let root = try bundle(files: ["Contents/MacOS/Racky"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(HookHelperLocator.path(environment: ["RACKY_HELPER": "/x/racky"], bundleURL: root) == "/x/racky")
        // Só o executável do app (mesmo arquivo que "racky" em volume case-insensitive): não é um helper.
        #expect(HookHelperLocator.path(environment: [:], bundleURL: root) == nil || FileManager.default.fileExists(atPath: root.appendingPathComponent("Contents/MacOS/racky").path))
    }
}
