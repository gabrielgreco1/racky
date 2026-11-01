import Foundation
import Testing

@testable import RackyVZ

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("racky-vz-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct VZRegistryTests {
    @Test func entriesPersistAcrossReloads() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("registry.json")
        let registry = VZRegistry(url: url)
        try await registry.add(VZRegistryEntry(vmID: "ab-1", computerID: "c1", name: "scout", owner: "racky", hostPID: 4242))
        try await registry.add(VZRegistryEntry(vmID: "ab-2", computerID: "c2", name: "other", owner: "racky", hostPID: 4242))
        let reloaded = VZRegistry(url: url)
        #expect(await reloaded.entries.map(\.vmID) == ["ab-1", "ab-2"])
        try await reloaded.remove(vmID: "ab-1")
        #expect(await VZRegistry(url: url).entries.map(\.vmID) == ["ab-2"])
        #expect(await reloaded.entry(vmID: "ab-2")?.name == "other")
    }

    @Test func addingTheSameVMReplacesIt() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = VZRegistry(url: root.appendingPathComponent("registry.json"))
        try await registry.add(VZRegistryEntry(vmID: "ab-1", computerID: "c1", name: "a", owner: "racky", hostPID: 1))
        try await registry.add(VZRegistryEntry(vmID: "ab-1", computerID: "c1", name: "b", owner: "racky", hostPID: 1))
        #expect(await registry.entries.count == 1)
        #expect(await registry.entries.first?.name == "b")
    }

    @Test func aCorruptFileStartsEmpty() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("registry.json")
        try Data("{not json".utf8).write(to: url)
        #expect(await VZRegistry(url: url).entries.isEmpty)
    }

    /// Sweep: processo morto some com a pasta; processo vivo de outra instância fica; o próprio processo vira "parar"; pasta sem registro cai.
    @Test func sweepRemovesDeadHostsAndOrphansButNeverALiveOne() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let containers = root.appendingPathComponent("containers", isDirectory: true)
        let fm = FileManager.default
        for name in ["ab-dead", "ab-live", "ab-own", "ab-orphan"] {
            try fm.createDirectory(at: containers.appendingPathComponent(name), withIntermediateDirectories: true)
            try Data("rootfs".utf8).write(to: containers.appendingPathComponent(name).appendingPathComponent("rootfs.ext4"))
        }
        let registry = VZRegistry(url: root.appendingPathComponent("registry.json"))
        try await registry.add(VZRegistryEntry(vmID: "ab-dead", computerID: "c1", name: "dead", owner: "racky", hostPID: 111))
        try await registry.add(VZRegistryEntry(vmID: "ab-live", computerID: "c2", name: "live", owner: "racky", hostPID: 222))
        try await registry.add(VZRegistryEntry(vmID: "ab-own", computerID: "c3", name: "own", owner: "racky", hostPID: 333))
        let stopped = StoppedIDs()

        let report = await registry.sweep(
            containersDirectory: containers, currentPID: 333, isAlive: { $0 == 222 || $0 == 333 }, stopOwn: { await stopped.add($0.vmID) })

        #expect(Set(report.removedEntries) == ["ab-dead", "ab-own"])
        #expect(report.keptForLiveHosts == ["ab-live"])
        #expect(report.removedOrphanDirectories == ["ab-orphan"])
        #expect(await stopped.ids == ["ab-own"])
        #expect(await registry.entries.map(\.vmID) == ["ab-live"])
        let left = Set(try fm.contentsOfDirectory(atPath: containers.path))
        #expect(left == ["ab-live"])
        // O registro em disco reflete o sweep.
        #expect(await VZRegistry(url: root.appendingPathComponent("registry.json")).entries.map(\.vmID) == ["ab-live"])
    }

    @Test func processLivenessCheck() {
        #expect(VZRegistry.processIsAlive(getpid()))
        #expect(!VZRegistry.processIsAlive(0))
        #expect(!VZRegistry.processIsAlive(-5))
    }

    @Test func pathsLayout() {
        let paths = VZPaths(appDataRoot: URL(fileURLWithPath: "/data/Racky"))
        #expect(paths.root.path == "/data/Racky/vz")
        #expect(paths.registryFile.path == "/data/Racky/vz/registry.json")
        #expect(paths.containerDirectory("ab-1").path == "/data/Racky/vz/store/containers/ab-1")
        #expect(paths.templateDirectory(digest: "sha256:abc/../x").lastPathComponent == "sha256-abcx")
    }
}

private actor StoppedIDs {
    var ids: [String] = []
    func add(_ id: String) { ids.append(id) }
}
