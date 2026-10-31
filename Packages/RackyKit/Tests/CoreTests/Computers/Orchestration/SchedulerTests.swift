import RackyDocker
import RackyProtocol
import RackyStore
import Foundation
import Testing

@testable import RackyCore

// T3-04: ComputerScheduler (admissão pela memória da VM, fila FIFO com posição visível, criação em paralelo limitada a 4,
// idempotência por nome, identidade do pai e dos slots) com um provisionador falso. O Docker real fica no teste vivo.

/// Provisionador falso: cada `provision` pode esperar um portão, falhar ou demorar, e registra o pico de criações simultâneas.
actor FakeProvisioning: ComputerProvisioning {
    private(set) var provisioned: [String] = []
    private(set) var specs: [String: ComputerSpec] = [:]
    private(set) var tornDown: [String] = []
    private(set) var inFlight = 0
    private(set) var peak = 0
    var delay: Duration = .zero
    var failing: Set<String> = []
    var preflightError: String?
    private var gates: [String: [CheckedContinuation<Void, Never>]] = [:]
    var holding = false
    let backend = FakeBackend()

    func setDelay(_ d: Duration) { delay = d }
    func setFailing(_ names: Set<String>) { failing = names }
    func setPreflightError(_ e: String?) { preflightError = e }
    func setHolding(_ h: Bool) { holding = h }

    func preflight() async throws {
        if let preflightError { throw ToolError(.dockerUnavailable, preflightError) }
    }

    func provision(_ spec: ComputerSpec) async throws -> ProvisionedHandle {
        inFlight += 1
        peak = max(peak, inFlight)
        defer { inFlight -= 1 }
        if holding { await withCheckedContinuation { gates[spec.name, default: []].append($0) } }
        if delay > .zero { try? await Task.sleep(for: delay) }
        if failing.contains(spec.name) { throw ToolError(.boxRestarted, "boom") }
        provisioned.append(spec.name)
        specs[spec.name] = spec
        let name = spec.name
        return ProvisionedHandle(backend: backend) { await self.recordTeardown(name) }
    }

    func recordTeardown(_ name: String) { tornDown.append(name) }

    func openGates() {
        holding = false
        for (_, waiters) in gates { for w in waiters { w.resume() } }
        gates = [:]
    }
}

struct SchedulerRig {
    let hub: ComputerHub
    let scheduler: ComputerScheduler
    let provisioning: FakeProvisioning
    let service: ComputerToolService
    let root: URL
    let parent: String

    /// VM de 8 GB (`MemTotal` ≈ 7,7 GiB): cabem 4 headless (07 §2.4).
    static let eightGB = VMCapacity(memTotalBytes: Int64(7.7 * Double(1 << 30)), cpuCount: 14)
    static let twentyEightGB = VMCapacity(memTotalBytes: Int64(27.7 * Double(1 << 30)), cpuCount: 14)

    static func make(vm: VMCapacity = eightGB, workers: Int = 8, maxParallel: Int = 4, parent: String = "parent-aaaaaaaa", store: RackyStore? = nil,
                     proxies: (any ProxyDirectory)? = nil, sessionProxy: @escaping @Sendable (String) async -> String? = { _ in nil },
                     sessionInfo: @escaping @Sendable (String) async -> SessionRef? = { _ in nil },
                     now: @escaping @Sendable () -> Date = { Date() }) async throws -> SchedulerRig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("abx-sched-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let hub = ComputerHub()
        let provisioning = FakeProvisioning()
        let scheduler = ComputerScheduler(
            hub: hub, provisioning: provisioning, capacity: { vm }, runDirectory: { p, n in root.appendingPathComponent("\(p)/\(n)", isDirectory: true) },
            store: store, maxParallelCreations: maxParallel, fixedEstimates: true, proxies: proxies, sessionProxy: sessionProxy, sessionInfo: sessionInfo, now: now)
        await scheduler.attach()
        let service = ComputerToolService(hub: hub, orchestrator: scheduler)
        let bundle = try OrchestrationInjectionBuilder.make(
            parentID: parent, helperPath: "/usr/local/bin/racky", options: { var o = OrchestrationInjectionBuilder.Options(); o.workerSlots = workers; return o }(),
            parentCapability: "cap-parent", workerCapability: { "cap-w\($0)" })
        await OrchestrationInjectionBuilder.register(bundle, hub: hub, scheduler: scheduler)
        return SchedulerRig(hub: hub, scheduler: scheduler, provisioning: provisioning, service: service, root: root, parent: parent)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func parentCall(_ tool: String, _ args: JSON = [:], as id: String? = nil) async -> (isError: Bool, json: JSON, outcome: ToolOutcome) {
        let outcome = await service.call(tool, arguments: args, child: id ?? parent)
        let text = outcome.content.first?["text"]?.string ?? "null"
        return (outcome.isError, (try? JSON.parse(text)) ?? .null, outcome)
    }

    func states(_ result: JSON) -> [String] { (result["boxes"]?.array ?? []).compactMap { $0["state"]?.string } }

    /// Espera o estado de um computador (o provisionamento falso roda em tarefa própria).
    func wait(_ name: String, _ state: BoxState, timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let c = await hub.computer(named: name) {
                let current = await c.state
                if current == state || (state == .ready && current == .inUse) { return true }
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

@Suite("T3-04 ComputerScheduler", .tags(.integration), .serialized) struct SchedulerTests {
    @Test func eightGBVMRunsFourHeadlessAndQueuesTheFifthWithVisiblePosition() async throws {
        let rig = try await SchedulerRig.make(vm: SchedulerRig.eightGB, workers: 8)
        defer { rig.cleanup() }
        let names = ["a", "b", "c", "d", "e", "f"]
        await rig.provisioning.setHolding(true)  // os containers ainda estão subindo quando o pai recebe a resposta
        let reply = await rig.parentCall("boxes_reserve", ["names": .array(names.map { .string($0) }), "display": "headless", "batch": "listings-oct"])
        #expect(!reply.isError)
        #expect(rig.states(reply.json) == ["provisioning", "provisioning", "provisioning", "provisioning", "queued", "queued"])
        let boxes = try #require(reply.json["boxes"]?.array)
        #expect(boxes[4]["position"] == 1 && boxes[5]["position"] == 2 && boxes[4]["reason"] == "memory")
        #expect(reply.json["batch_id"] == "listings-oct")
        // O pai recebe slot de worker e `subagent_type` para cada computador, distintos entre si.
        let workers = Set(boxes.compactMap { $0["worker"]?.string })
        #expect(workers.count == 6 && workers.allSatisfy { $0.hasPrefix("racky-worker-") })
        #expect(await rig.scheduler.activeCount == 4)
        #expect(await rig.scheduler.queueLabel == "Waiting for memory · 2 of 6 queued")

        let during = await rig.parentCall("boxes_status", [:])
        #expect((during.json["boxes"]?.array ?? []).map { $0["state"]?.string ?? "" } == ["provisioning", "provisioning", "provisioning", "provisioning", "queued", "queued"])
        await rig.provisioning.openGates()
        for n in ["a", "b", "c", "d"] { #expect(await rig.wait(n, .ready)) }
        let status = await rig.parentCall("boxes_status", [:])
        let listed = try #require(status.json["boxes"]?.array)
        #expect(listed.count == 6 && status.json["queue"]?["length"] == 2)
        #expect(listed.filter { $0["state"] == "queued" }.map { $0["position"]?.string ?? "\($0["position"] ?? .null)" }.count == 2)

        // Liberar um abre vaga: o primeiro da fila entra e o seguinte sobe para a posição 1.
        let released = await rig.parentCall("boxes_release", ["names": ["a"]])
        #expect(released.json["released"] == ["a"])
        #expect(await rig.wait("e", .ready))
        let queued = await rig.scheduler.queueSnapshot
        #expect(queued.map(\.name) == ["f"] && queued.map(\.position) == [1])
        #expect(await rig.provisioning.tornDown == ["a"])
        #expect(await rig.scheduler.activeCount == 4)
    }

    @Test func memoryRuleIsSumOfEstimatesAndDesktopCountsMore() async throws {
        let rig = try await SchedulerRig.make(vm: SchedulerRig.eightGB, workers: 8)
        defer { rig.cleanup() }
        // Budget 5,7 GiB: 2 desktop (2 x 2,2) + 1 headless (1,2) = 5,6 cabem; o próximo headless (6,8) não.
        let r1 = await rig.parentCall("boxes_reserve", ["names": ["d1", "d2"], "display": "desktop"])
        let r2 = await rig.parentCall("boxes_reserve", ["names": ["h1", "h2"], "display": "headless"])
        #expect(rig.states(r1.json) == ["provisioning", "provisioning"])
        #expect(rig.states(r2.json) == ["provisioning", "queued"])
    }

    @Test func queueIsStrictFIFOEvenWhenALaterRequestWouldFit() async throws {
        let rig = try await SchedulerRig.make(vm: SchedulerRig.eightGB, workers: 8)
        defer { rig.cleanup() }
        _ = await rig.parentCall("boxes_reserve", ["names": ["d1", "d2"], "display": "desktop"])  // 4,4 GiB
        let big = await rig.parentCall("boxes_reserve", ["names": ["d3"], "display": "desktop"])  // 6,6 > 5,7: fila
        let small = await rig.parentCall("boxes_reserve", ["names": ["h1"], "display": "headless"])  // 5,6 caberia, mas d3 está na frente
        #expect(rig.states(big.json) == ["queued"] && rig.states(small.json) == ["queued"])
        #expect(small.json["boxes"]?.array?.first?["position"] == 2)
    }

    @Test func creationsRunInParallelButNeverMoreThanFour() async throws {
        let rig = try await SchedulerRig.make(vm: SchedulerRig.twentyEightGB, workers: 12, maxParallel: 4)
        defer { rig.cleanup() }
        await rig.provisioning.setDelay(.milliseconds(120))
        let names = (1...10).map { "box\($0)" }
        let started = ContinuousClock.now
        let reply = await rig.parentCall("boxes_reserve", ["names": .array(names.map { .string($0) })])
        let took = started.duration(to: .now)
        #expect(took < .seconds(1), "boxes_reserve must not wait for the containers")
        // Sob carga a resposta pode sair depois de uma caixa já ter subido (o atraso falso é 120 ms): nenhuma fica na fila e o
        // limite de tempo acima garante que a resposta não esperou as criações.
        #expect(rig.states(reply.json).allSatisfy { $0 == "provisioning" || $0 == "ready" })
        #expect(rig.states(reply.json).contains("provisioning"))
        for n in names { #expect(await rig.wait(n, .ready, timeout: .seconds(10))) }
        let peak = await rig.provisioning.peak
        #expect(peak > 1 && peak <= 4, "peak simultaneous creations: \(peak)")
    }

    @Test func reserveIsIdempotentByNameAndOwnedByTheParent() async throws {
        let rig = try await SchedulerRig.make(workers: 4)
        defer { rig.cleanup() }
        let first = await rig.parentCall("boxes_reserve", ["names": ["phoenix-az"]])
        let again = await rig.parentCall("boxes_reserve", ["names": ["phoenix-az"]])
        #expect(first.json["boxes"]?.array?.first?["child_id"] == again.json["boxes"]?.array?.first?["child_id"])
        #expect(await rig.scheduler.activeCount == 1)

        // Outro orquestrador não pega o mesmo nome.
        await rig.hub.registerParent(id: "parent-bbbbbbbb", capability: "cap-b")
        let other = await rig.parentCall("boxes_reserve", ["names": ["phoenix-az"]], as: "parent-bbbbbbbb")
        #expect(other.json["boxes"]?.array?.first?["reason"] == "name_in_use")
    }

    @Test func unavailableReasons() async throws {
        let rig = try await SchedulerRig.make(workers: 2)
        defer { rig.cleanup() }
        let bad = await rig.parentCall("boxes_reserve", ["names": ["../etc", "-x", "ok"]])
        let boxes = try #require(bad.json["boxes"]?.array)
        #expect(boxes[0]["state"] == "unavailable" && boxes[0]["reason"] == "invalid_name" && boxes[1]["reason"] == "invalid_name")
        #expect(boxes[2]["state"] == "provisioning")

        let slots = await rig.parentCall("boxes_reserve", ["names": ["s1", "s2"]])  // ok ocupa o slot 1; só sobra 1
        #expect(slots.json["boxes"]?.array?.last?["reason"] == "no_free_worker")

        await rig.provisioning.setPreflightError("Docker is not running")
        let down = await rig.parentCall("boxes_reserve", ["names": ["late"]])
        #expect(down.json["boxes"]?.array?.first?["reason"] == "docker_unavailable")
    }

    @Test func profileBusyWhenAnotherComputerHoldsTheNamedProfile() async throws {
        let rig = try await SchedulerRig.make(workers: 4)
        defer { rig.cleanup() }
        let one = await rig.parentCall("boxes_reserve", ["names": ["g1"], "profile": "gov-login"])
        let two = await rig.parentCall("boxes_reserve", ["names": ["g2"], "profile": "gov-login"])
        #expect(rig.states(one.json) == ["provisioning"])
        #expect(two.json["boxes"]?.array?.first?["reason"] == "profile_busy")
    }

    @Test func failedProvisioningFreesTheSlotAndTheMemoryForTheQueue() async throws {
        let rig = try await SchedulerRig.make(vm: SchedulerRig.eightGB, workers: 8)
        defer { rig.cleanup() }
        await rig.provisioning.setFailing(["b"])
        _ = await rig.parentCall("boxes_reserve", ["names": ["a", "b", "c", "d", "e"]])
        #expect(await rig.wait("b", .failed))
        #expect(await rig.wait("e", .ready), "the queued computer takes the memory the failed one gave back")
        let status = await rig.parentCall("boxes_status", ["names": ["b"]])
        #expect(status.json["boxes"]?.array?.first?["state"] == "failed")
        // Reservar de novo o nome que falhou tenta outra vez.
        await rig.provisioning.setFailing([])
        let retry = await rig.parentCall("boxes_reserve", ["names": ["b"]])
        #expect(rig.states(retry.json).first != "failed")
    }

    @Test func cancelQueuedRemovesTheRequest() async throws {
        let rig = try await SchedulerRig.make(vm: SchedulerRig.eightGB, workers: 8)
        defer { rig.cleanup() }
        _ = await rig.parentCall("boxes_reserve", ["names": ["a", "b", "c", "d", "e", "f"]])
        #expect(await rig.scheduler.cancelQueued(name: "e"))
        #expect(await rig.scheduler.queueSnapshot.map(\.name) == ["f"])
        #expect(await rig.scheduler.cancelQueued(name: "a") == false, "already running")
    }

    @Test func childClaimsByNameWaitsForQueuedComputerAndKeepsOwnership() async throws {
        let rig = try await SchedulerRig.make(vm: SchedulerRig.eightGB, workers: 8)
        defer { rig.cleanup() }
        let reply = await rig.parentCall("boxes_reserve", ["names": ["a", "b", "c", "d", "e"]])
        let boxes = try #require(reply.json["boxes"]?.array)
        let fifth = try #require(boxes[4]["child_id"]?.string)
        let claim = await rig.parentCall("box_claim", ["name": "e", "wait_s": 0], as: fifth)
        #expect(!claim.isError && claim.json["state"] == "queued" && claim.json["position"] == 1)
        // Enquanto está na fila, as ferramentas de trabalho devolvem `queued` e o filho repete.
        let early = await rig.parentCall("exec", ["shell": "true"], as: fifth)
        #expect(errorCode(early) == "queued")
        _ = await rig.parentCall("boxes_release", ["names": ["a"]])
        #expect(await rig.wait("e", .ready))
        let status = await rig.parentCall("box_status", [:], as: fifth)
        #expect(status.json["state"] == "in_use" && status.json["box"] == "e")
        // O pai vê quem é o dono.
        let seen = await rig.parentCall("boxes_status", ["names": ["e"]])
        #expect(seen.json["boxes"]?.array?.first?["owner"]?.string == fifth)
        // O filho libera: o computador sai e o worker recebe `box_released`.
        let done = await rig.parentCall("box_release", [:], as: fifth)
        #expect(!done.isError)
        #expect(errorCode(await rig.parentCall("browser_read", ["what": "text"], as: fifth)) == "box_released")
        #expect(await rig.provisioning.tornDown.contains("e"))
    }

    @Test func rolesAreSeparated() async throws {
        let rig = try await SchedulerRig.make(workers: 2)
        defer { rig.cleanup() }
        let bundleChild = OrchestrationInjectionBuilder.childID(parent: rig.parent, slot: 1)
        // Worker chamando ferramenta do pai.
        #expect(errorCode(await rig.parentCall("boxes_reserve", ["names": ["x"]], as: bundleChild)) == "blocked_by_policy")
        // Pai chamando ferramenta de computador.
        #expect(errorCode(await rig.parentCall("box_claim", ["name": "x"])) == "blocked_by_policy")
        // tools/list por papel.
        let server = ComputerMCPServer(tools: rig.service)
        func names(_ child: String) async throws -> [String] {
            let reply = try #require(await server.handle(Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8), child: child))
            return try JSON.parse(reply)["result"]?["tools"]?.array?.compactMap { $0["name"]?.string } ?? []
        }
        #expect(try await names(rig.parent) == ["boxes_reserve", "boxes_status", "boxes_release", "box_collect", "batch_status", "batch_collect", "dataset_list", "dataset_read", "agent_message", "agent_spawn", "agent_wait", "agent_status", "agent_stop"])
        #expect(try await names(bundleChild) == ToolCatalog.all.map(\.name))
        let initialize = try #require(await server.handle(Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#.utf8), child: rig.parent))
        let instructions = try JSON.parse(initialize)["result"]?["instructions"]?.string ?? ""
        #expect(instructions.contains("boxes_reserve") && instructions.count <= 1500)
    }

    @Test func unclaimedComputersWarnAtTenMinutesAndReleaseAtThirty() async throws {
        let clock = LockedDate(Date(timeIntervalSince1970: 1_000_000))
        let rig = try await SchedulerRig.make(workers: 4, now: { clock.get() })
        defer { rig.cleanup() }
        _ = await rig.parentCall("boxes_reserve", ["names": ["idle-one", "claimed-one"]])
        #expect(await rig.wait("idle-one", .ready))
        let child = try #require(await rig.scheduler.childID(for: "claimed-one"))
        _ = await rig.parentCall("box_claim", ["name": "claimed-one", "wait_s": 1], as: child)
        let computer = try #require(await rig.hub.computer(named: "idle-one"))
        let events = ComputerEventLog()
        await computer.setObserver { events.add($0) }

        clock.set(Date(timeIntervalSince1970: 1_000_000 + 9 * 60))
        var swept = await rig.scheduler.sweep()
        #expect(swept.warned.isEmpty && swept.released.isEmpty)
        clock.set(Date(timeIntervalSince1970: 1_000_000 + 10 * 60 + 1))
        swept = await rig.scheduler.sweep()
        #expect(swept.warned == ["idle-one"] && swept.released.isEmpty)
        #expect(events.all.contains(.unclaimed(computer: "idle-one")))
        swept = await rig.scheduler.sweep()
        #expect(swept.warned.isEmpty, "the warning comes once")
        clock.set(Date(timeIntervalSince1970: 1_000_000 + 30 * 60 + 1))
        swept = await rig.scheduler.sweep()
        #expect(swept.released == ["idle-one"], "the claimed computer is never swept")
        let idlePhase = await rig.scheduler.phase(of: "idle-one")
        let claimedPhase = await rig.scheduler.phase(of: "claimed-one")
        #expect(idlePhase == nil && claimedPhase == .active)
    }

    /// O pai supervisiona de 5 em 5 minutos: cada caixa reivindicada mostra `idle_s` desde a última chamada que fez trabalho e
    /// `stalled` depois de 5 minutos sem progresso (o dono viu um subagente esperar 20 minutos por duas requisições).
    @Test func claimedComputersShowIdleTimeAndStallAfterFiveMinutes() async throws {
        let clock = LockedDate(Date(timeIntervalSince1970: 3_000_000))
        let rig = try await SchedulerRig.make(workers: 2, now: { clock.get() })
        defer { rig.cleanup() }
        _ = await rig.parentCall("boxes_reserve", ["names": ["slow-one"]])
        #expect(await rig.wait("slow-one", .ready))
        let child = try #require(await rig.scheduler.childID(for: "slow-one"))
        _ = await rig.parentCall("box_claim", ["name": "slow-one", "wait_s": 1], as: child)
        let computer = try #require(await rig.hub.computer(named: "slow-one"))
        await computer.noteActivity(at: clock.get())
        clock.set(Date(timeIntervalSince1970: 3_000_000 + 4 * 60))
        var box = try #require(await rig.parentCall("boxes_status", [:]).json["boxes"]?.array?.first)
        #expect(box["idle_s"] == 240 && box["stalled"] == nil)
        clock.set(Date(timeIntervalSince1970: 3_000_000 + 6 * 60))
        box = try #require(await rig.parentCall("boxes_status", [:]).json["boxes"]?.array?.first)
        #expect(box["idle_s"] == 360 && box["stalled"] == true)
        #expect(ComputerToolService.waitingTools.isSuperset(of: ["exec_poll", "help_wait", "box_status"]), "esperar não conta como progresso")
    }

    /// Git de dentro do computador: o acesso vem da sessão do pai (o app liga com Settings, repositório do projeto e token do `gh`).
    @Test func reservedComputersCarryTheSessionsGitHubAccess() async throws {
        let session = UUID()
        let rig = try await SchedulerRig.make(workers: 2, sessionInfo: { _ in SessionRef(id: session, title: "listings") })
        defer { rig.cleanup() }
        let asked = LockedBox<UUID?>(nil)
        await rig.scheduler.setGitHubAccess { id in
            asked.set(id)
            return EgressGitHub(token: "ghp_x", repos: ["acme/acme-platform"])
        }
        _ = await rig.parentCall("boxes_reserve", ["names": ["chicago-il"]])
        #expect(await rig.wait("chicago-il", .ready))
        let spec = try #require(await rig.provisioning.specs["chicago-il"])
        #expect(spec.github == EgressGitHub(token: "ghp_x", repos: ["acme/acme-platform"]))
        #expect(asked.get() == session)
    }

    @Test func keepFor24HoursSurvivesReleaseUntilExpiry() async throws {
        let clock = LockedDate(Date(timeIntervalSince1970: 2_000_000))
        let rig = try await SchedulerRig.make(workers: 2, now: { clock.get() })
        defer { rig.cleanup() }
        _ = await rig.parentCall("boxes_reserve", ["names": ["keeper"]])
        #expect(await rig.wait("keeper", .ready))
        _ = await rig.parentCall("boxes_release", ["names": ["keeper"], "keep": "24h"])
        #expect(await rig.provisioning.tornDown.isEmpty)
        clock.set(Date(timeIntervalSince1970: 2_000_000 + 23 * 3600))
        #expect(await rig.scheduler.sweep().released.isEmpty)
        clock.set(Date(timeIntervalSince1970: 2_000_000 + 24 * 3600 + 1))
        #expect(await rig.scheduler.sweep().released == ["keeper"])
        #expect(await rig.provisioning.tornDown == ["keeper"])
    }

    @Test func keepAskedOnAnExistingReservationSurvivesTheWorkersEnd() async throws {
        // Regressão: reservar de novo com keep 24h devolvia a reserva existente e esquecia o keep; o fim do worker desmontava tudo.
        let rig = try await SchedulerRig.make(workers: 2)
        defer { rig.cleanup() }
        _ = await rig.parentCall("boxes_reserve", ["names": ["resume-me"]])
        #expect(await rig.wait("resume-me", .ready))
        _ = await rig.parentCall("boxes_reserve", ["names": ["resume-me"], "keep": "24h"])
        _ = await rig.parentCall("boxes_release", ["names": ["resume-me"]])
        #expect(await rig.provisioning.tornDown.isEmpty, "the computer stays for the resumed worker")
    }

    @Test func concurrentReserveCallsFromManyParentsStayConsistent() async throws {
        let rig = try await SchedulerRig.make(vm: SchedulerRig.twentyEightGB, workers: 10)
        defer { rig.cleanup() }
        await withTaskGroup(of: Void.self) { group in
            for i in 1...10 { group.addTask { _ = await rig.parentCall("boxes_reserve", ["names": [.string("c\(i)")]]) } }
        }
        let status = await rig.parentCall("boxes_status", [:])
        #expect(status.json["boxes"]?.array?.count == 10)
        let children = Set((status.json["boxes"]?.array ?? []).compactMap { $0["child_id"]?.string })
        #expect(children.count == 10, "every computer got its own worker slot")
    }
}

final class LockedDate: @unchecked Sendable {  // SAFETY: NSLock protege o valor.
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    func get() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ new: Date) { lock.lock(); value = new; lock.unlock() }
}

final class ComputerEventLog: @unchecked Sendable {  // SAFETY: NSLock protege a lista.
    private let lock = NSLock()
    private var list: [ComputerEvent] = []
    func add(_ e: ComputerEvent) { lock.lock(); list.append(e); lock.unlock() }
    var all: [ComputerEvent] { lock.lock(); defer { lock.unlock() }; return list }
}

/// Caixa com trava para capturar um valor dentro de closures `@Sendable`.
final class LockedBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}
