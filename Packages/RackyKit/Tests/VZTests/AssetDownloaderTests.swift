import CryptoKit
import Foundation
import Synchronization
import Testing

@testable import RackyVZ

private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

private func sample(_ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }) }

private func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("vz-dl-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private final class Progress: Sendable {
    private let values = Mutex<[(Int64, Int64)]>([])
    func record(_ done: Int64, _ total: Int64) { values.withLock { $0.append((done, total)) } }
    var all: [(Int64, Int64)] { values.withLock { $0 } }
}

// Sobe um servidor HTTP local e corta a conexão no meio: sob a fase paralela o parcial às vezes nem chega ao disco. Fase serial.
@Suite(.tags(.integration)) struct AssetDownloaderTests {
    // MARK: file://

    @Test func copiesALocalFileVerifiesItAndReportsProgress() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = sample(300_000)
        let source = dir.appendingPathComponent("src.bin")
        try data.write(to: source)
        let spec = VZAssetSpec(url: source.absoluteString, sha256: sha(data), size: Int64(data.count))
        let destination = dir.appendingPathComponent("out/dst.bin")
        let progress = Progress()
        try await AssetDownloader().fetch(spec, to: destination) { progress.record($0, $1) }
        #expect(try Data(contentsOf: destination) == data)
        #expect(progress.all.last?.0 == Int64(data.count))
        #expect(progress.all.last?.1 == Int64(data.count))
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathExtension("part").path))
        // Segunda chamada: já válido, não baixa de novo (mesmo com a origem apagada).
        try FileManager.default.removeItem(at: source)
        try await AssetDownloader().fetch(spec, to: destination) { _, _ in }
        #expect(AssetDownloader().isValid(destination, spec: spec))
    }

    @Test func aChecksumMismatchDeletesThePartialAndFails() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = sample(10_000)
        let source = dir.appendingPathComponent("src.bin")
        try data.write(to: source)
        let wrong = VZAssetSpec(url: source.absoluteString, sha256: String(repeating: "1", count: 64), size: Int64(data.count))
        let destination = dir.appendingPathComponent("dst.bin")
        await #expect(throws: AssetDownloadError.self) { try await AssetDownloader().fetch(wrong, to: destination) { _, _ in } }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathExtension("part").path))
    }

    @Test func aWrongSizeIsReportedBeforeHashing() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = sample(10_000)
        let source = dir.appendingPathComponent("src.bin")
        try data.write(to: source)
        let spec = VZAssetSpec(url: source.absoluteString, sha256: sha(data), size: 99)
        await #expect(throws: AssetDownloadError.sizeMismatch(expected: 99, actual: 10_000)) {
            try await AssetDownloader().fetch(spec, to: dir.appendingPathComponent("dst.bin")) { _, _ in }
        }
    }

    @Test func aTamperedFileFailsValidationEvenWithTheSidecar() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = sample(5_000)
        let source = dir.appendingPathComponent("src.bin")
        try data.write(to: source)
        let spec = VZAssetSpec(url: source.absoluteString, sha256: sha(data), size: Int64(data.count))
        let destination = dir.appendingPathComponent("dst.bin")
        try await AssetDownloader().fetch(spec, to: destination) { _, _ in }
        var tampered = data
        tampered[100] ^= 0xFF
        try tampered.write(to: destination)
        #expect(!AssetDownloader().isValid(destination, spec: spec))
    }

    @Test func resumesALocalCopyFromThePartialFile() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = sample(200_000)
        let source = dir.appendingPathComponent("src.bin")
        try data.write(to: source)
        let destination = dir.appendingPathComponent("dst.bin")
        try data.prefix(120_000).write(to: destination.appendingPathExtension("part"))
        let spec = VZAssetSpec(url: source.absoluteString, sha256: sha(data), size: Int64(data.count))
        let progress = Progress()
        try await AssetDownloader().fetch(spec, to: destination) { progress.record($0, $1) }
        #expect(try Data(contentsOf: destination) == data)
        #expect(progress.all.first?.0 == 120_000)  // começou de onde parou
    }

    // MARK: http://

    @Test func downloadsOverHTTPAndVerifies() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = sample(2_000_000)
        let server = try TestHTTPServer(files: ["/kernel": data])
        let base = try await server.start()
        defer { server.stop() }
        let spec = VZAssetSpec(url: base.appendingPathComponent("kernel").absoluteString, sha256: sha(data), size: Int64(data.count))
        let progress = Progress()
        let destination = dir.appendingPathComponent("kernel.bin")
        try await AssetDownloader().fetch(spec, to: destination) { progress.record($0, $1) }
        #expect(try Data(contentsOf: destination) == data)
        #expect(progress.all.last?.0 == Int64(data.count))
        #expect(progress.all.map(\.0) == progress.all.map(\.0).sorted())  // progresso monotônico
    }

    @Test func resumesOverHTTPWithARangeRequest() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = sample(1_000_000)
        let server = try TestHTTPServer(files: ["/f": data])
        let base = try await server.start()
        defer { server.stop() }
        let destination = dir.appendingPathComponent("f.bin")
        try data.prefix(400_000).write(to: destination.appendingPathExtension("part"))
        let spec = VZAssetSpec(url: base.appendingPathComponent("f").absoluteString, sha256: sha(data), size: Int64(data.count))
        try await AssetDownloader().fetch(spec, to: destination) { _, _ in }
        #expect(try Data(contentsOf: destination) == data)
        #expect(server.seenRequests.first?.range == "bytes=400000-")
    }

    @Test func aServerThatIgnoresRangeRestartsFromZero() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = sample(300_000)
        let server = try TestHTTPServer(files: ["/f": data], behavior: .init(supportsRange: false))
        let base = try await server.start()
        defer { server.stop() }
        let destination = dir.appendingPathComponent("f.bin")
        try data.prefix(100_000).write(to: destination.appendingPathExtension("part"))
        let spec = VZAssetSpec(url: base.appendingPathComponent("f").absoluteString, sha256: sha(data), size: Int64(data.count))
        try await AssetDownloader().fetch(spec, to: destination) { _, _ in }
        #expect(try Data(contentsOf: destination) == data)
    }

    @Test func anOversizedPartialIsDiscardedAndTheFileDownloadsFresh() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = sample(50_000)
        let server = try TestHTTPServer(files: ["/f": data])
        let base = try await server.start()
        defer { server.stop() }
        let destination = dir.appendingPathComponent("f.bin")
        try (data + Data(repeating: 1, count: 10)).write(to: destination.appendingPathExtension("part"))  // maior que o arquivo
        let spec = VZAssetSpec(url: base.appendingPathComponent("f").absoluteString, sha256: sha(data), size: Int64(data.count))
        try await AssetDownloader().fetch(spec, to: destination) { _, _ in }
        #expect(try Data(contentsOf: destination) == data)
    }

    @Test func httpErrorsSurface() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = try TestHTTPServer(files: [:])
        let base = try await server.start()
        defer { server.stop() }
        let spec = VZAssetSpec(url: base.appendingPathComponent("missing").absoluteString, sha256: String(repeating: "a", count: 64), size: 10)
        await #expect(throws: AssetDownloadError.self) {
            try await AssetDownloader().fetch(spec, to: dir.appendingPathComponent("x.bin")) { _, _ in }
        }
    }

    @Test func aDroppedConnectionKeepsThePartialAndTheNextTryResumes() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = sample(500_000)
        let server = try TestHTTPServer(files: ["/f": data], behavior: .init(cutAfter: 150_000))
        let base = try await server.start()
        defer { server.stop() }
        let destination = dir.appendingPathComponent("f.bin")
        let spec = VZAssetSpec(url: base.appendingPathComponent("f").absoluteString, sha256: sha(data), size: Int64(data.count))
        await #expect(throws: (any Error).self) { try await AssetDownloader().fetch(spec, to: destination) { _, _ in } }
        let partial = (try FileManager.default.attributesOfItem(atPath: destination.appendingPathExtension("part").path)[.size] as? NSNumber)?.int64Value ?? 0
        #expect(partial > 0 && partial < Int64(data.count))
        server.setBehavior(.init())
        try await AssetDownloader().fetch(spec, to: destination) { _, _ in }
        #expect(try Data(contentsOf: destination) == data)
        #expect(server.seenRequests.last?.range == "bytes=\(partial)-")
    }
}
