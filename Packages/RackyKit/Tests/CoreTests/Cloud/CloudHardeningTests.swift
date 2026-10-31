import RackyDocker
import Foundation
import Testing

@testable import RackyCore

// Auditoria: conexão única por host, reserva do teto, host morto fora do pool e regiões que falham sem travar as outras.

actor SlowConnector: HostConnecting {
    private(set) var connected: [String] = []
    func connect(_ host: PlacedHost) async throws -> any ComputerHostAccess {
        connected.append(host.id)
        try await Task.sleep(for: .milliseconds(150))
        return StubAccess()
    }
    func disconnect(hostID: String) async {}
}

@Suite("Auditoria - nuvem: reentrância, hosts mortos e regiões")
struct CloudHardeningTests {
    private func expiredHost(_ id: String, region: String, now: Date) -> CloudHost {
        let tags = RackyTags(owner: "install-1", host: id, created: now.addingTimeInterval(-7200), expires: now.addingTimeInterval(-60), provider: .fake)
        return CloudHost(
            id: id, provider: .fake, region: region, shape: CloudFixture.small, state: .running, launchedAt: now.addingTimeInterval(-7200),
            tags: tags.dictionary, hourlyUSD: 0.08)
    }

    @Test func concurrentComputersOnOneHostConnectOnlyOnce() async throws {
        let provider = FakeCloudProvider(clock: { CloudFixture.noon })
        let clock = CloudTestClock(CloudFixture.noon)
        let pool = ComputerHostPool(
            manager: CloudFixture.manager(provider: provider, clock: clock), region: "us-east-1", shape: CloudFixture.large, access: CloudFixture.access,
            maxComputers: 10, clock: clock.reader)
        let connector = SlowConnector()
        let cloud = CloudComputerProvisioning(placement: pool, connector: connector, make: { _ in FakeProvisioning() })
        func spec(_ name: String) -> ComputerSpec {
            ComputerSpec(
                name: name, parent: "p", display: .headless, profile: nil, proxy: "direct", proxiesAllowed: [], allowHosts: [], batch: nil,
                run: RunFolder(root: FileManager.default.temporaryDirectory.appendingPathComponent("cloud-\(UUID().uuidString)")))
        }
        async let a = cloud.provision(spec("a"))
        async let b = cloud.provision(spec("b"))
        _ = try await (a, b)
        #expect(await connector.connected.count == 1)
    }

    @Test func concurrentAcquisitionsCannotBothPassTheSpendCap() async throws {
        let provider = FakeCloudProvider(clock: { CloudFixture.noon })
        let probe = try await provider.estimate(shape: CloudFixture.small, region: "us-east-1")
        let hours = Double(DeadManPolicy().maxLifetime.components.seconds) / 3600
        let cap = probe.hourlyUSD * hours * 1.5  // cabe um host, não dois
        let manager = CloudFixture.manager(provider: provider, clock: CloudTestClock(CloudFixture.noon), caps: SpendCaps(dailyUSD: cap, monthlyUSD: nil))
        async let first: Result<CloudHost, any Error> = Task { try await manager.acquireHost(region: "us-east-1", shape: CloudFixture.small, access: CloudFixture.access) }.result
        async let second: Result<CloudHost, any Error> = Task { try await manager.acquireHost(region: "us-east-1", shape: CloudFixture.small, access: CloudFixture.access) }.result
        let results = await [first, second]
        #expect(results.filter { if case .success = $0 { true } else { false } }.count == 1)
        #expect(await provider.provisionCalls == 1)
        #expect(await manager.ledger.records.count == 1)
    }

    @Test func failedCreationReleasesTheReservation() async throws {
        let provider = FakeCloudProvider(clock: { CloudFixture.noon })
        await provider.setFailProvision(.provider("sem capacidade"))
        let manager = CloudFixture.manager(provider: provider, clock: CloudTestClock(CloudFixture.noon))
        await #expect(throws: (any Error).self) { try await manager.acquireHost(region: "us-east-1", shape: CloudFixture.small, access: CloudFixture.access) }
        #expect(await manager.ledger.records.isEmpty)
    }

    @Test func deadHostLeavesTheManagerAndThePoolStopsReusingIt() async throws {
        let provider = FakeCloudProvider(clock: { CloudFixture.noon })
        let clock = CloudTestClock(CloudFixture.noon)
        let manager = CloudFixture.manager(provider: provider, clock: clock)
        let pool = ComputerHostPool(
            manager: manager, region: "us-east-1", shape: CloudFixture.large, access: CloudFixture.access, maxComputers: 10, clock: clock.reader)
        let first = try await pool.acquire(computerID: "a")
        try await provider.terminateHost(id: first.id, region: "us-east-1")  // a VM se apagou sozinha
        clock.advance(300)
        _ = try await manager.reap(regions: ["us-east-1"])
        #expect(await manager.activeHosts.isEmpty)
        #expect(await manager.ledger.records.allSatisfy { $0.endedAt != nil })
        let second = try await pool.acquire(computerID: "b")
        #expect(second.id != first.id)
        #expect(await provider.provisionCalls == 2)
    }

    @Test func reaperKeepsSweepingWhenOneRegionFails() async throws {
        let provider = FakeCloudProvider(clock: { CloudFixture.noon })
        await provider.inject(expiredHost("old", region: "us-east-1", now: CloudFixture.noon))
        await provider.setFailListRegions(["sa-east-1"])
        let report = try await HostReaper(provider: provider, owner: "install-1").sweep(
            knownHostIDs: [], regions: ["sa-east-1", "us-east-1"], now: CloudFixture.noon)
        #expect(report.terminated == ["old"])
        #expect(report.regionErrors.keys.sorted() == ["sa-east-1"])
        // Todas as regiões falhando continua sendo erro.
        await #expect(throws: (any Error).self) {
            try await HostReaper(provider: provider, owner: "install-1").sweep(knownHostIDs: [], regions: ["sa-east-1"], now: CloudFixture.noon)
        }
    }

    @Test func adoptionContinuesAcrossRegionsWhenOneFails() async throws {
        let provider = FakeCloudProvider(clock: { CloudFixture.noon })
        let now = CloudFixture.noon
        let tags = RackyTags(owner: "install-1", host: "live", created: now, expires: now.addingTimeInterval(3600), provider: .fake)
        await provider.inject(CloudHost(
            id: "live", provider: .fake, region: "us-east-1", shape: CloudFixture.small, state: .running, launchedAt: now, tags: tags.dictionary, hourlyUSD: 0.08))
        await provider.setFailListRegions(["sa-east-1"])
        let manager = CloudFixture.manager(provider: provider, clock: CloudTestClock(now))
        let adopted = try await manager.adoptExisting(regions: ["sa-east-1", "us-east-1"])
        #expect(adopted.map(\.id) == ["live"])
    }
}
