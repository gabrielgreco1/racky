import Foundation
import Testing

@testable import RackyDocker

private func makeContext(_ files: [String: (String, Bool)]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("abx-ctx-\(UUID().uuidString)", isDirectory: true)
    for (path, (content, executable)) in files {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
    }
    return root
}

private func run(_ executable: String, _ arguments: [String], stdin: Data? = nil) throws -> (status: Int32, out: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let out = Pipe(), input = Pipe()
    process.standardOutput = out
    process.standardError = out
    process.standardInput = input
    try process.run()
    if let stdin { input.fileHandleForWriting.write(stdin) }
    try input.fileHandleForWriting.close()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

private let repoRoot: URL = {
    var url = URL(fileURLWithPath: #filePath)
    while url.path != "/", !FileManager.default.fileExists(atPath: url.appendingPathComponent("scripts/build-runtime-image.sh").path) {
        url.deleteLastPathComponent()
    }
    return url
}()

@Suite(.tags(.integration)) struct BuildContextTests {
    private let sample: [String: (String, Bool)] = [
        "Dockerfile": ("FROM scratch\n", false), "entrypoint.sh": ("#!/bin/sh\n", true), "pkg/data/a.txt": ("a", false),
    ]

    @Test func hashIsStableOrderIndependentAndContentSensitive() throws {
        let dir = try makeContext(sample)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try BuildContext.contentHash(of: dir)
        let again = try BuildContext.contentHash(of: dir)
        #expect(first.count == 64 && first == again)
        #expect(BuildContext.tag(repository: "racky-computer", hash: first) == "racky-computer:ctx-\(first.prefix(12))")

        // Mudar o conteúdo, o bit de execução ou o nome muda o hash; `.DS_Store` não.
        try Data("b".utf8).write(to: dir.appendingPathComponent("pkg/data/a.txt"))
        let changed = try BuildContext.contentHash(of: dir)
        #expect(changed != first)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent("pkg/data/a.txt").path)
        let mode = try BuildContext.contentHash(of: dir)
        #expect(mode != changed)
        try Data("x".utf8).write(to: dir.appendingPathComponent(".DS_Store"))
        #expect(try BuildContext.contentHash(of: dir) == mode)
    }

    @Test func hashMatchesTheShellScriptUsedForLocalBuilds() throws {
        let dir = try makeContext(sample.merging(["z/ü-ñ.txt": ("utf8", false), "B.txt": ("upper", false)]) { a, _ in a })
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = repoRoot.appendingPathComponent("scripts/build-runtime-image.sh").path
        let result = try run(script, ["--context", dir.path, "--print-hash"])
        #expect(result.status == 0)
        #expect(result.out.trimmingCharacters(in: .whitespacesAndNewlines) == (try BuildContext.contentHash(of: dir)))
        let tag = try run(script, ["--context", dir.path, "--print-tag"])
        #expect(tag.out.trimmingCharacters(in: .whitespacesAndNewlines) == BuildContext.tag(repository: "racky-computer", hash: try BuildContext.contentHash(of: dir)))
    }

    @Test func realRuntimeContextHashMatchesScript() throws {
        let context = repoRoot.appendingPathComponent("runtime/computer")
        let swift = try BuildContext.contentHash(of: context)
        let script = try run(repoRoot.appendingPathComponent("scripts/build-runtime-image.sh").path, ["--print-hash"])
        #expect(script.out.trimmingCharacters(in: .whitespacesAndNewlines) == swift)
    }

    @Test func tarIsReadableByBsdtarWithModesAndNestedDirs() throws {
        let dir = try makeContext(sample)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tar = try BuildContext.tar(of: dir)
        #expect(tar.count % 512 == 0)
        let listing = try run("/usr/bin/tar", ["-tvf", "-"], stdin: tar)
        #expect(listing.status == 0, Comment(rawValue: listing.out))
        #expect(listing.out.contains("-rwxr-xr-x") && listing.out.contains("entrypoint.sh"))
        #expect(listing.out.contains("pkg/data/a.txt") && listing.out.contains("drwxr-xr-x"))
        // Conteúdo íntegro.
        let extractDir = FileManager.default.temporaryDirectory.appendingPathComponent("abx-x-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: extractDir) }
        #expect(try run("/usr/bin/tar", ["-xf", "-", "-C", extractDir.path], stdin: tar).status == 0)
        #expect(try String(contentsOf: extractDir.appendingPathComponent("pkg/data/a.txt"), encoding: .utf8) == "a")
    }

    @Test func tarIsDeterministic() throws {
        let dir = try makeContext(sample)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try BuildContext.tar(of: dir) == (try BuildContext.tar(of: dir)))
    }

    @Test func longPathsUseUstarPrefixAndTooLongFail() throws {
        let long = (0 ..< 6).map { _ in String(repeating: "d", count: 20) }.joined(separator: "/") + "/file.txt"  // 6*20+5+9 = 134
        let dir = try makeContext([long: ("hi", false)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let tar = try BuildContext.tar(of: dir)
        let listing = try run("/usr/bin/tar", ["-tf", "-"], stdin: tar)
        #expect(listing.status == 0 && listing.out.contains("file.txt"))
        let tooLong = try makeContext([String(repeating: "x", count: 150) + "/" + String(repeating: "y", count: 120): ("hi", false)])
        defer { try? FileManager.default.removeItem(at: tooLong) }
        #expect(throws: DockerError.self) { try BuildContext.tar(of: tooLong) }
    }

    @Test func symlinkAndMissingDirectoryAreRejected() throws {
        let dir = try makeContext(sample)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("link").path, withDestinationPath: "/etc/hosts")
        #expect(throws: DockerError.self) { try BuildContext.contentHash(of: dir) }
        #expect(throws: DockerError.self) { try BuildContext.contentHash(of: URL(fileURLWithPath: "/nonexistent/abx")) }
    }
}
