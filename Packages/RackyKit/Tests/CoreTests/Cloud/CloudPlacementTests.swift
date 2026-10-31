import RackyDocker
import Foundation
import Testing

@testable import RackyCore

// BK12-T10/T11 com o provedor falso: nenhum teste toca rede, AWS, Docker ou túnel real.

actor RecordingSender: HeartbeatSending {
    private(set) var beats: [String] = []
    var failing: Set<String> = []
    func setFailing(_ ids: Set<String>) { failing = ids }
    func sendHeartbeat(hostID: String) async throws {
        beats.append(hostID)
        if failing.contains(hostID) { throw HeartbeatError.remoteFailed(255, "sem rota") }
    }
}

/// Espera que deixa passar `allowed` vezes POR intervalo e depois falha (encerra cada laço de forma determinística).
actor LimitedSleeper {
    private let allowed: Int
    private var used: [Duration: Int] = [:]
    private(set) var calls: [Duration] = []
    init(allowed: Int) { self.allowed = allowed }
    func sleep(_ duration: Duration) throws {
        calls.append(duration)
        guard used[duration, default: 0] < allowed else { throw CancellationError() }
        used[duration, default: 0] += 1
    }
}

struct StubAccess: ComputerHostAccess {
    var host: ComputerHost { .local }
    var client: DockerClient { DockerClient(socketPath: "/nonexistent/docker.sock") }
    var storage: ComputerStorage { .volumes }
    func reach(publishedPort: Int, computerID: String) async throws -> Int { publishedPort }
    func releaseForwards(computerID: String) async {}
}

actor RecordingConnector: HostConnecting {
    private(set) var connected: [String] = []
    private(set) var disconnected: [String] = []
    func connect(_ host: PlacedHost) async throws -> any ComputerHostAccess { connected.append(host.id); return StubAccess() }
    func disconnect(hostID: String) async { disconnected.append(hostID) }
}

private let hang: @Sendable (Duration) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3600)) }

@Suite("BK12-T10 - pool de hosts e provisionamento na nuvem (provedor falso)")
struct CloudPlacementTests {
    private func pool(
        _ provider: FakeCloudProvider, _ clock: CloudTestClock, shape: HostShape = CloudFixture.large, max: Int = 10, grace: Duration = .seconds(900),
        caps: SpendCaps = SpendCaps(), sleep: @escaping @Sendable (Duration) async throws -> Void = hang,
        onClosed: @escaping @Sendable (String) async -> Void = { _ in }
    ) -> ComputerHostPool {
        ComputerHostPool(
            manager: CloudFixture.manager(provider: provider, clock: clock, caps: caps), region: "us-east-1", shape: shape, access: CloudFixture.access,
            maxComputers: max, idleGrace: grace, clock: clock.reader, sleep: sleep, onHostClosed: onClosed)
    }

    @Test func capacityComesFromTheShape() {
        #expect(ComputerHostPool.capacity(of: CloudFixture.small) == 1)
        #expect(ComputerHostPool.capacity(of: CloudFixture.large) == 8)
        #expect(ComputerHostPool.capacity(of: HostShape(id: "tiny", vcpus: 1, memoryGiB: 1)) == 1)
    }

    @Test func reusesARunningHostWithFreeCapacity() async throws {
        let provider = FakeCloudProvider(clock: { CloudFixture.noon })
        let pool = pool(provider, CloudTestClock(CloudFixture.noon))
        let a = try await pool.acquire(computerID: "a")
        let b = try await pool.acquire(computerID: "b")
        #expect(a.id == b.id)
        #expect(try await pool.acquire(computerID: "a").id == a.id)  // idempotente
        #expect(await provider.provisionCalls == 1)
        #expect(await pool.computers(on: a.id) == ["a", "b"])
    }

    @Test func concurrentAcquisitionsBootOnlyOneHost() async throws {
        let provider = FakeCloudProvider(clock: { CloudFixture.noon })
        let pool = pool(provider, CloudTestClock(CloudFixture.noon))
        let ids = try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0 ..< 5 { group.addTask { try await pool.acquire(computerID: "c\(index)").id } }
            var out: Set<String> = []
            for try await id in group { out.insert(id) }
            return out
        }
        #expect(ids.count == 1)
        #expect(await provider.provisionCalls == 1)
    }

    @Test func fullHostMakesANewOneAndAdmissionFollowsShapeCapacity() async throws {
        let provider = FakeCloudProvider(clock: { CloudFixture.noon })
        let pool = pool(provider, CloudTestClock(CloudFixture.noon), shape: CloudFixture.small)  // cabe 1 por host
        let a = try await pool.acquire(computerID: "a")
        let b = try await pool.acquire(computerID: "b")
        #expect(a.id != b.id)
        #expect(await provider.provisionCalls == 2)
        #expect(await pool.hostIDs.count == 2)
    }

    @Test func maxComputersIsAnExtraCapAcrossHosts() async throws {
        let provider = FakeCloudProvider(clock: { CloudFixture.noon })
        let pool = pool(provider, CloudTestClock(CloudFixture.noon), max: 2)
        _ = try await pool.acquire(computerID: "a")
        _ = try await pool.acquire(computerID: "b")
        await #expect(throws: PlacementError.maxComputersReached(2)) { try await pool.acquire(computerID: "c") }
        #expect(await provider.provisionCalls == 1)
        await pool.release(computerID: "a")
        _ = try await pool.acquire(computerID: "c")  // vaga devolvida
        await pool.update(maxComputers: 5)
        #expect(await pool.maxComputers == 5)
    }

    @Test func spendCapDeniesBeforeAnyProviderCreateCall() async throws {
        let provider = FakeCloudProvider(clock: { CloudFixture.noon })
        let pool = pool(provider, CloudTestClock(CloudFixture.noon), caps: SpendCaps(dailyUSD: 0.01))
        await #expect {
            try await pool.acquire(computerID: "a")
        } throws: { error in
            guard case CloudError.spendCapExceeded(let denial) = error else { return false }
            return denial.window == .daily
        }
        #expect(await provider.provisionCalls == 0)
        #expect(await pool.computerCount == 0)
        #expect(await pool.hostIDs.isEmpty)
    }

    @Test func emptyHostIsShutDownOnlyAfterTheIdleGrace() async throws {
        let provider = FakeCloudProvider(clock: { CloudFixture.noon })
        let clock = CloudTestClock(CloudFixture.noon)
        let closed = ClosedLog()
        let pool = pool(provider, clock, onClosed: { await closed.add($0) })
        let host = try await pool.acquire(computerID: "a")
        _ = try await pool.acquire(computerID: "b")
        await pool.release(computerID: "a")
        clock.advance(3600)
        #expect(await pool.sweepIdle().isEmpty)  // ainda tem o "b"
        await pool.release(computerID: "b")
        clock.advance(14 * 60)
        #expect(await pool.sweepIdle().isEmpty)
        #expect(await !provider.liveHostIDs.isEmpty)
        clock.advance(61)
        #expect(await pool.sweepIdle() == [host.id])
        #expect(await provider.liveHostIDs.isEmpty)
        #expect(await closed.ids == [host.id])
        #expect(await pool.hostIDs.isEmpty)
    }

    @Test func aComputerArrivingDuringTheGraceReusesTheHost() async throws {
        let provider = FakeCloudProvider(clock: { CloudFixture.noon })
        let clock = CloudTestClock(CloudFixture.noon)
        let pool = pool(provider, clock)
        let first = try await pool.acquire(computerID: "a")
        await pool.release(computerID: "a")
        clock.advance(600)
        let second = try await pool.acquire(computerID: "b")
        #expect(second.id == first.id)
        #expect(await provider.provisionCalls == 1)
        clock.advance(3600)
        #expect(await pool.sweepIdle().isEmpty)  // voltou a ter computador: o relógio de ociosidade zerou
    }

    @Test func idleTimerShutsTheHostDownByItself() async throws {
        let provider = FakeCloudProvider(clock: { CloudFixture.noon })
        let pool = pool(provider, CloudTestClock(CloudFixture.noon), grace: .zero, sleep: { _ in })
        _ = try await pool.acquire(computerID: "a")
        await pool.release(computerID: "a")
        for _ in 0 ..< 200 where !(await provider.liveHostIDs.isEmpty) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await provider.liveHostIDs.isEmpty)
    }

    @Test func defaultIdleGraceIsTheDeadManIdleShutdown() async {
        let provider = FakeCloudProvider(clock: { CloudFixture.noon })
        let pool = ComputerHostPool(
            manager: CloudFixture.manager(provider: provider, clock: CloudTestClock(CloudFixture.noon)), region: "us-east-1", shape: CloudFixture.large,
            access: CloudFixture.access, maxComputers: 3)
        #expect(await pool.idleGrace == .seconds(900))
    }

    // MARK: CloudComputerProvisioning

    private func spec(_ name: String) -> ComputerSpec {
        ComputerSpec(
            name: name, parent: "p", display: .headless, profile: nil, proxy: "direct", proxiesAllowed: [], allowHosts: [], batch: nil,
            run: RunFolder(root: FileManager.default.temporaryDirectory.appendingPathComponent("cloud-\(UUID().uuidString)")))
    }

    @Test func cloudProvisioningPlacesConnectsOncePerHostAndReleasesOnTeardown() async throws {
        let provider = FakeCloudProvider(clock: { CloudFixture.noon })
        let pool = pool(provider, CloudTestClock(CloudFixture.noon))
        let connector = RecordingConnector()
        let inner = FakeProvisioning()
        let cloud = CloudComputerProvisioning(placement: pool, connector: connector, make: { _ in inner })
        let a = try await cloud.provision(spec("a"))
        let b = try await cloud.provision(spec("b"))
        #expect(await connector.connected.count == 1)
        #expect(await provider.provisionCalls == 1)
        #expect(await pool.computerCount == 2)
        await a.teardown()
        #expect(await pool.computerCount == 1)
        await b.teardown()
        #expect(await pool.computerCount == 0)
        #expect(await inner.tornDown.sorted() == ["a", "b"])
    }

    @Test func failedProvisionGivesTheSlotBack() async throws {
        let provider = FakeCloudProvider(clock: { CloudFixture.noon })
        let pool = pool(provider, CloudTestClock(CloudFixture.noon), max: 1)
        let inner = FakeProvisioning()
        await inner.setFailing(["bad"])
        let cloud = CloudComputerProvisioning(placement: pool, connector: RecordingConnector(), make: { _ in inner })
        await #expect(throws: (any Error).self) { try await cloud.provision(spec("bad")) }
        #expect(await pool.computerCount == 0)
        _ = try await cloud.provision(spec("good"))  // maxComputers = 1 e a vaga voltou
    }

    // MARK: Nuvem pedida sem provedor implementado

    @Test func cloudModeWithoutAnImplementedProviderFailsInsteadOfGoingLocal() async throws {
        #expect(CloudProviderAvailability.implemented("aws") && !CloudProviderAvailability.implemented("hetzner"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("abx-cloud-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppComputerProvisioning(config: .init(runtimeRoot: nil, secretsRoot: root, owner: "test-cloud"))
        await app.setCloudRoute(CloudComputerRoute(place: { .cloud }, provisioning: nil))
        let problems = ClosedLog()
        await app.setObserver(state: nil, problem: { problem in Task { await problems.add("\(problem)") } })
        let scheduler = ComputerScheduler(
            hub: ComputerHub(), provisioning: app, capacity: { await app.vmCapacity() }, runDirectory: { _, name in root.appendingPathComponent(name) })
        let reply = await scheduler.reserve(parent: "p", ReserveRequest(names: ["a"]))
        let box = try #require(reply["boxes"]?.array?.first)
        #expect(box["state"] == "unavailable" && box["reason"] == "cloud_unavailable")
        #expect(box["message"]?.string == "Cloud computers aren't available yet. Switch to This Mac in Computers.")
        #expect(await app.vmCapacity().cpuCount == 1024)  // não sondou o Docker
        await #expect(throws: ComputerSetupError.cloudUnavailable) { try await app.provision(spec("a")) }
        #expect(await app.liveComputers() == nil)
    }

    @Test func tunnelHeartbeatSenderFailsClearlyWithoutATunnel() async {
        let sender = TunnelHeartbeatSender(tunnel: { _ in nil })
        await #expect(throws: HeartbeatError.noTunnel("h1")) { try await sender.sendHeartbeat(hostID: "h1") }
    }
}

actor ClosedLog {
    private(set) var ids: [String] = []
    func add(_ id: String) { ids.append(id) }
}

@Suite("BK12-T11 - heartbeat, reaper agendado e livro-caixa persistido (provedor falso)")
struct CloudSupervisorTests {
    private func supervisor(
        _ manager: CloudHostManager, _ sender: RecordingSender, allowed: Int = 0, heartbeat: Duration = .seconds(60), reaper: Duration = .seconds(600),
        sleep: (@Sendable (Duration) async throws -> Void)? = nil
    ) -> (CloudHostSupervisor, LimitedSleeper) {
        let sleeper = LimitedSleeper(allowed: allowed)
        let supervisor = CloudHostSupervisor(
            manager: manager, sender: sender, regions: ["us-east-1"], heartbeatInterval: heartbeat, reaperInterval: reaper,
            sleep: sleep ?? { try await sleeper.sleep($0) })
        return (supervisor, sleeper)
    }

    @Test func heartbeatTickReachesEveryLiveHostAndOneFailureDoesNotStopTheOthers() async throws {
        let provider = FakeCloudProvider(clock: { CloudFixture.noon })
        let manager = CloudFixture.manager(provider: provider, clock: CloudTestClock(CloudFixture.noon))
        let a = try await manager.acquireHost(region: "us-east-1", shape: CloudFixture.small, access: CloudFixture.access)
        let b = try await manager.acquireHost(region: "us-east-1", shape: CloudFixture.small, access: CloudFixture.access)
        let sender = RecordingSender()
        await sender.setFailing([a.id])
        let (supervisor, _) = supervisor(manager, sender)
        await supervisor.heartbeatTick()
        #expect(await sender.beats.sorted() == [a.id, b.id].sorted())
        #expect(await supervisor.heartbeatFailures.keys.sorted() == [a.id])
        await sender.setFailing([])
        await supervisor.heartbeatTick()
        #expect(await supervisor.heartbeatFailures.isEmpty)
        #expect(await supervisor.heartbeatTicks == 2)
    }

    @Test func heartbeatLoopTicksOnTheIntervalAndStopsWhenTheSleeperEnds() async throws {
        let provider = FakeCloudProvider(clock: { CloudFixture.noon })
        let manager = CloudFixture.manager(provider: provider, clock: CloudTestClock(CloudFixture.noon))
        _ = try await manager.acquireHost(region: "us-east-1", shape: CloudFixture.small, access: CloudFixture.access)
        let sender = RecordingSender()
        let (supervisor, sleeper) = supervisor(manager, sender, allowed: 3, heartbeat: .seconds(60), reaper: .seconds(600))
        await supervisor.start()
        for _ in 0 ..< 300 where await sleeper.calls.count < 8 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await supervisor.heartbeatTicks == 4)  // 1 no início + 1 por espera permitida
        #expect(await supervisor.reaperRuns == 4)
        #expect(Set(await sleeper.calls) == [.seconds(60), .seconds(600)])
        await supervisor.stop()
    }

    @Test func stopHaltsBothLoopsAndStartIsIdempotent() async throws {
        let provider = FakeCloudProvider(clock: { CloudFixture.noon })
        let manager = CloudFixture.manager(provider: provider, clock: CloudTestClock(CloudFixture.noon))
        let sender = RecordingSender()
        let (supervisor, _) = supervisor(manager, sender, sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        await supervisor.start()
        await supervisor.start()
        for _ in 0 ..< 300 {
            if await supervisor.heartbeatTicks >= 1, await supervisor.reaperRuns >= 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await supervisor.isRunning)
        #expect(await supervisor.heartbeatTicks == 1)
        #expect(await supervisor.reaperRuns == 1)
        await supervisor.stop()
        #expect(await !supervisor.isRunning)
        let ticks = await supervisor.heartbeatTicks
        try await Task.sleep(for: .milliseconds(50))
        #expect(await supervisor.heartbeatTicks == ticks)
    }

    @Test func reaperRunsAtStartAndOnTheConfiguredSchedule() async throws {
        let provider = FakeCloudProvider(clock: { CloudFixture.noon })
        let now = CloudFixture.noon
        let tags = RackyTags(owner: "install-1", host: "old", created: now.addingTimeInterval(-7200), expires: now.addingTimeInterval(-60), provider: .fake)
        await provider.inject(CloudHost(
            id: "old", provider: .fake, region: "us-east-1", shape: CloudFixture.small, state: .running, launchedAt: now.addingTimeInterval(-7200),
            tags: tags.dictionary, hourlyUSD: 0.08))
        let manager = CloudFixture.manager(provider: provider, clock: CloudTestClock(now))
        let (supervisor, sleeper) = supervisor(manager, RecordingSender(), allowed: 2, heartbeat: .seconds(30), reaper: .seconds(600))
        await supervisor.start()
        for _ in 0 ..< 300 where await sleeper.calls.count < 6 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await supervisor.reaperRuns == 3)
        #expect(await provider.host("old")?.state == .terminated)
        #expect(await sleeper.calls.contains(.seconds(600)))
        #expect(CloudHostSupervisor.defaultReaperInterval == .seconds(600))
        await supervisor.stop()
    }

    @Test func reopeningAdoptsLiveHostsByTagAndBeatsThem() async throws {
        let provider = FakeCloudProvider(clock: { CloudFixture.noon })
        let clock = CloudTestClock(CloudFixture.noon)
        let before = CloudFixture.manager(provider: provider, clock: clock)
        let host = try await before.acquireHost(region: "us-east-1", shape: CloudFixture.small, access: CloudFixture.access)
        // "Quit": nasce um gerente novo (mesmo dono) que ainda não conhece o host.
        let after = CloudFixture.manager(provider: provider, clock: clock)
        #expect(await after.activeHosts.isEmpty)
        let sender = RecordingSender()
        let (supervisor, _) = supervisor(after, sender, sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        await supervisor.start()
        for _ in 0 ..< 300 where await sender.beats.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await after.activeHosts.map(\.id) == [host.id])
        #expect(await sender.beats == [host.id])
        await supervisor.stop()
    }

    // MARK: Livro-caixa

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("abx-ledger-\(UUID().uuidString)", isDirectory: true).appendingPathComponent("spend.json")
    }

    @Test func ledgerRoundTripsThroughTheFileStore() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileSpendLedgerStore(url: url)
        #expect(try store.load() == SpendLedger())  // sem arquivo: vazio
        var ledger = SpendLedger()
        ledger.open(SpendRecord(hostID: "h1", startedAt: CloudFixture.noon, expiresAt: CloudFixture.noon.addingTimeInterval(28_800), hourlyUSD: 0.08))
        ledger.open(SpendRecord(hostID: "h2", startedAt: CloudFixture.noon, expiresAt: CloudFixture.noon.addingTimeInterval(28_800), hourlyUSD: 0.58))
        ledger.close(hostID: "h2", at: CloudFixture.noon.addingTimeInterval(1800))
        try store.save(ledger)
        #expect(try store.load() == ledger)
    }

    @Test func spendSurvivesARestartAndStillEnforcesTheCap() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let provider = FakeCloudProvider(clock: { CloudFixture.noon })
        let clock = CloudTestClock(CloudFixture.noon)
        func make() -> CloudHostManager {
            CloudHostManager(
                provider: provider, settings: .init(owner: "install-1", caps: SpendCaps(dailyUSD: 1.2), calendar: CloudFixture.utc), clock: clock.reader,
                ledgerStore: FileSpendLedgerStore(url: url), acceptedAUP: { _, _ in true })
        }
        let first = make()
        let host = try await first.acquireHost(region: "us-east-1", shape: CloudFixture.small, access: CloudFixture.access)
        try await first.releaseHost(id: host.id)
        #expect(try FileSpendLedgerStore(url: url).load().records.count == 1)
        let second = make()  // reinício
        #expect(await second.ledger.records.map(\.hostID) == [host.id])
        // Projeção de 8 h de um host pequeno (~US$ 0,64) + o que já foi gasto não passa de 1,20, mas um grande passa.
        await #expect(throws: (any Error).self) { try await second.acquireHost(region: "us-east-1", shape: CloudFixture.large, access: CloudFixture.access) }
        #expect(await provider.provisionCalls == 1)
    }

    @Test func pruneDropsOnlyOldEndedRecords() {
        var ledger = SpendLedger()
        let old = CloudFixture.noon.addingTimeInterval(-90 * 86_400)
        ledger.open(SpendRecord(hostID: "old", startedAt: old, expiresAt: old.addingTimeInterval(3600), hourlyUSD: 1))
        ledger.close(hostID: "old", at: old.addingTimeInterval(60))
        ledger.open(SpendRecord(hostID: "open", startedAt: old, expiresAt: old.addingTimeInterval(3600), hourlyUSD: 1))
        ledger.prune(endedBefore: CloudFixture.noon.addingTimeInterval(-62 * 86_400))
        #expect(ledger.records.map(\.hostID) == ["open"])
    }
}
