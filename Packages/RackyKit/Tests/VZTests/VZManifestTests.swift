import Foundation
import Testing

@testable import RackyVZ

private let zeros = String(repeating: "0", count: 64)
private let abcd = String(repeating: "ab", count: 32)

private func manifestJSON(kernelSHA: String = abcd, url: String = "https://example.test/vmlinux", schema: Int = 1) -> Data {
    Data("""
    {"schema": \(schema), "version": "v1",
     "kernel": {"url": "\(url)", "sha256": "\(kernelSHA)", "size": 100, "license": "GPL-2.0-only"},
     "vminit": {"url": "vminit.oci.tar", "sha256": "\(abcd)", "size": 200, "reference": "vminit:1"},
     "computer": {"url": "https://example.test/computer.oci.tar", "sha256": "\(abcd)", "size": 300}}
    """.utf8)
}

@Suite struct VZManifestTests {
    @Test func decodesAndSumsSizes() throws {
        let manifest = try VZManifest.decode(manifestJSON())
        #expect(manifest.version == "v1")
        #expect(manifest.kernel.license == "GPL-2.0-only")
        #expect(manifest.vminit.reference == "vminit:1")
        #expect(manifest.totalSize == 600)
        #expect(manifest.assets.map(\.name) == ["kernel", "vminit", "computer"])
        try manifest.requirePublished()
    }

    @Test func rejectsUnsupportedSchemaAndBadChecksums() {
        #expect(throws: VZManifestError.unsupportedSchema(2)) { try VZManifest.decode(manifestJSON(schema: 2)) }
        #expect(throws: VZManifestError.self) { try VZManifest.decode(manifestJSON(kernelSHA: "xyz")) }
        #expect(throws: VZManifestError.self) { try VZManifest.decode(Data("nope".utf8)) }
    }

    @Test func placeholdersAreRefusedWithAClearError() throws {
        let zeroed = try VZManifest.decode(manifestJSON(kernelSHA: zeros))
        #expect(zeroed.kernel.isPlaceholder)
        #expect(throws: VZManifestError.notPublished("kernel")) { try zeroed.requirePublished() }
        let hosted = try VZManifest.decode(manifestJSON(url: "https://PLACEHOLDER.invalid/x"))
        #expect(throws: VZManifestError.notPublished("kernel")) { try hosted.requirePublished() }
    }

    @Test func theBundledManifestPointsAtReleaseURLsWithRealHashes() throws {
        var root = URL(fileURLWithPath: #filePath)
        while root.path != "/", !FileManager.default.fileExists(atPath: root.appendingPathComponent("runtime/vz-manifest.json").path) { root.deleteLastPathComponent() }
        let manifest = try VZManifest.decode(Data(contentsOf: root.appendingPathComponent("runtime/vz-manifest.json")))
        #expect(manifest.kernel.license == "GPL-2.0-only")
        #expect(manifest.kernel.sourceURL?.contains("kata-containers") == true)
        // scripts/vz/stage-release.sh: URLs de release do GitHub e sha256 reais (nada de placeholder, nada de zeros).
        try manifest.requirePublished()
        for spec in [manifest.kernel, manifest.vminit, manifest.computer] {
            #expect(spec.url.hasPrefix("https://github.com/") && spec.url.contains("/racky/releases/download/runtime-\(manifest.version)/"))
            #expect(spec.sha256.count == 64 && (spec.size ?? 0) > 0)
        }
    }

    @Test func relativeURLsResolveAgainstTheManifestLocation() throws {
        let manifest = try VZManifest.decode(manifestJSON(url: "vmlinux")).resolved(against: URL(fileURLWithPath: "/tmp/assets/vz-manifest.json"))
        #expect(manifest.kernel.url == "file:///tmp/assets/vmlinux")
        #expect(manifest.vminit.url == "file:///tmp/assets/vminit.oci.tar")
        #expect(manifest.computer.url == "https://example.test/computer.oci.tar")  // absoluta fica
    }

    @Test func locationPrefersTheEnvironmentOverride() throws {
        let environment = [VZManifest.environmentKey: "file:///tmp/m.json"]
        #expect(VZManifest.location(environment: environment, runtimeRoot: nil)?.absoluteString == "file:///tmp/m.json")
        #expect(VZManifest.location(environment: [VZManifest.environmentKey: "/tmp/other.json"], runtimeRoot: nil)?.path == "/tmp/other.json")
        #expect(VZManifest.location(environment: [:], runtimeRoot: nil) == nil)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vz-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(VZManifest.location(environment: [:], runtimeRoot: root) == nil)
        try manifestJSON().write(to: root.appendingPathComponent("vz-manifest.json"))
        #expect(VZManifest.location(environment: [:], runtimeRoot: root)?.lastPathComponent == "vz-manifest.json")
        #expect(VZManifest.location(environment: environment, runtimeRoot: root)?.absoluteString == "file:///tmp/m.json")
    }

    @Test func loadsALocalManifestOverFileURL() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vz-load-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("vz-manifest.json")
        try manifestJSON(url: "vmlinux").write(to: file)
        let manifest = try await VZManifest.load(from: file)
        #expect(manifest.kernel.url == root.appendingPathComponent("vmlinux").standardizedFileURL.absoluteString)
    }
}
