import RackyDocker
import RackyProtocol
import RackyStore
import Foundation
import Synchronization
import Testing

@testable import RackyCore

// Spec subagent-harness: `agent_spawn` reserva e chama o launcher; `agent_wait` acorda no result_submit + box_release, na saída do
// processo e na falha de lançamento, e vence no `wait_s`; `agent_stop` manda SIGINT, SIGTERM, SIGKILL em ordem; só o pai que criou o
// worker o enxerga. Provisionador e launcher falsos (nenhum CLI real).

/// Launcher falso: guarda o que o app receberia e, opcionalmente, "sai" do terminal quando recebe um certo sinal.
actor FakeWorkerLauncher: WorkerLauncher {
    private(set) var started: [WorkerLaunchRequest] = []
    private(set) var signals: [WorkerSignal] = []
    var failStart: String?
    /// Sinal que faz o terminal sair (`workerExited` no scheduler); `nil` = nunca sai sozinho.
    var exitsOn: WorkerSignal?
    var scheduler: ComputerScheduler?
    private var terminals: [UUID: String] = [:]

    func configure(failStart: String? = nil, exitsOn: WorkerSignal? = nil, scheduler: ComputerScheduler? = nil) {
        self.failStart = failStart; self.exitsOn = exitsOn; self.scheduler = scheduler
    }

    func start(_ request: WorkerLaunchRequest) async throws -> UUID {
        if let failStart { throw ToolError(.notSupported, failStart) }
        started.append(request)
        let id = UUID()
        terminals[id] = request.childID
        return id
    }

    func signal(terminal: UUID, _ signal: WorkerSignal) async {
        signals.append(signal)
        if signal == exitsOn, let child = terminals[terminal], let scheduler { await scheduler.workerExited(childID: child, exitCode: 130) }
    }
}

private func ok(_ result: (isError: Bool, json: JSON, outcome: ToolOutcome)) -> JSON {
    #expect(!result.isError, "unexpected error: \(result.json.text)")
    return result.json
}

private struct WorkerRig {
    let rig: SchedulerRig
    let launcher: FakeWorkerLauncher

    static func make(harness: SubagentHarness = .codex, store: RackyStore? = nil) async throws -> WorkerRig {
        let rig = try await SchedulerRig.make(
            workers: 2, store: store, sessionInfo: { _ in SessionRef(id: UUID(), title: "houston-listings", harness: harness) })
        let launcher = FakeWorkerLauncher()
        await launcher.configure(scheduler: rig.scheduler)
        await rig.scheduler.setWorkerLauncher(launcher, helperPath: "/usr/local/bin/racky")
        await rig.scheduler.setStopGrace(.milliseconds(60))
        return WorkerRig(rig: rig, launcher: launcher)
    }

    func spawn(_ name: String = "houston", harness: String? = nil, extra: [String: JSON] = [:]) async -> JSON {
        var args: [String: JSON] = ["brief": "TASK: study houston listings. OUTPUT: {rows:int}", "title": "Houston listings", "name": .string(name)]
        if let harness { args["harness"] = .string(harness) }
        for (k, v) in extra { args[k] = v }
        return ok(await rig.parentCall("agent_spawn", .object(args)))
    }

    /// Faz de conta de worker: reivindica, entrega o resultado e libera, pelas ferramentas MCP com a identidade do filho.
    func finishAsWorker(child: String, computer: String, submit: Bool = true) async {
        _ = await rig.wait(computer, .ready)
        _ = await rig.service.call("box_claim", arguments: ["name": .string(computer), "wait_s": 5], child: child)
        if submit {
            let r = await rig.service.call("result_submit", arguments: ["result": ["rows": 3]], child: child)
            #expect(!r.isError, "\(r.content)")
        }
        let released = await rig.service.call("box_release", arguments: [:], child: child)
        #expect(!released.isError)
    }
}

@Suite("Subagent harness: workers de app") struct AppWorkerTests {
    @Test func spawnReservesAndHandsTheLauncherAFullRequestWithoutBlocking() async throws {
        let w = try await WorkerRig.make()
        defer { w.rig.cleanup() }
        let started = ContinuousClock.now
        let reply = await w.spawn()
        #expect(started.duration(to: .now) < .seconds(2), "agent_spawn answers at once")
        #expect(reply["name"]?.string == "houston" && reply["harness"]?.string == "codex")
        let state = try #require(reply["state"]?.string)
        #expect(["starting", "queued"].contains(state))
        let child = try #require(reply["child_id"]?.string)
        #expect(child == "parent-a-a1", "app workers have their own identity, apart from the native slots")
        // O computador foi reservado para essa identidade (mesma fila e capacidade do boxes_reserve).
        let reservedFor = await w.rig.scheduler.childID(for: "houston")
        #expect(reservedFor == child)
        // O app recebe tudo que precisa para abrir o terminal.
        for _ in 0 ..< 100 where await w.launcher.started.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let request = try #require(await w.launcher.started.first)
        #expect(request.parentID == "parent-aaaaaaaa" && request.childID == child && request.computerName == "houston" && request.harness == .codex)
        #expect(request.terminalTitle == "Codex 1 · Houston listings" && request.helperPath == "/usr/local/bin/racky")
        #expect(request.prompt.contains("\"houston\"") && request.prompt.contains("TASK: study houston listings"))
        // A capability é válida no hub e o filho é um worker (não pode chamar ferramenta de pai).
        #expect(await w.rig.hub.authorize(child: child, capability: request.capability))
        #expect(await w.rig.hub.role(of: child) == .worker)
        let refused = await w.rig.service.call("agent_spawn", arguments: ["brief": "x"], child: child)
        #expect(refused.isError)
    }

    @Test func harnessDefaultsToTheSessionAndMixedFallsBackToCodex() async throws {
        for (session, expected) in [(SubagentHarness.opencode, "opencode"), (.mixed, "codex"), (.codex, "codex")] {
            let w = try await WorkerRig.make(harness: session)
            defer { w.rig.cleanup() }
            let reply = ok(await w.rig.parentCall("agent_spawn", ["brief": "go", "name": "a"]))
            #expect(reply["harness"]?.string == expected, "session \(session) -> \(expected)")
            #expect(reply["subagent_harness"]?.string == session.rawValue)
        }
        let w = try await WorkerRig.make(harness: .opencode)
        defer { w.rig.cleanup() }
        #expect(await w.spawn("explicit", harness: "claude")["harness"]?.string == "claude")
    }

    @Test func noNameFallsBackToTheTitleSlugAndStaysUnique() async throws {
        let w = try await WorkerRig.make()
        defer { w.rig.cleanup() }
        let one = ok(await w.rig.parentCall("agent_spawn", ["brief": "go", "title": "Phoenix AZ listings!"]))
        let two = ok(await w.rig.parentCall("agent_spawn", ["brief": "go", "title": "Phoenix AZ listings!"]))
        #expect(one["name"]?.string == "phoenix-az-listings" && two["name"]?.string == "phoenix-az-listings-2")
        // boxes_reserve continua usando só os slots nativos, mesmo com workers de app vivos.
        let native = ok(await w.rig.parentCall("boxes_reserve", ["names": ["native-a"]]))
        #expect(native["boxes"]?.array?.first?["child_id"]?.string == "parent-a-w1")
    }

    @Test func waitWakesOnResultSubmitPlusRelease() async throws {
        let w = try await WorkerRig.make()
        defer { w.rig.cleanup() }
        let child = try #require(await w.spawn()["child_id"]?.string)
        let waiting = Task { await w.rig.parentCall("agent_wait", ["names": ["houston"], "wait_s": 20]) }
        try await Task.sleep(for: .milliseconds(100))
        let mid = ok(await w.rig.parentCall("agent_status", ["names": ["houston"]]))
        #expect(mid["workers"]?.array?.first?["state"]?.string == "running" && mid["workers"]?.array?.first?["result_ready"]?.bool == false)
        await w.finishAsWorker(child: child, computer: "houston")
        let done = ok(await waiting.value)
        let item = try #require(done["workers"]?.array?.first)
        #expect(item["state"]?.string == "done" && item["result_ready"]?.bool == true && done["done"]?.bool == true)
        // box_collect segue valendo.
        let collected = ok(await w.rig.parentCall("box_collect", ["name": "houston"]))
        #expect(collected["result"]?["rows"]?.int == 3 || collected.text.contains("rows"))
    }

    @Test func waitAnyReturnsAtTheFirstAndAllWaitsForEveryone() async throws {
        let w = try await WorkerRig.make()
        defer { w.rig.cleanup() }
        let a = try #require(await w.spawn("a")["child_id"]?.string)
        _ = await w.spawn("b")
        let anyWait = Task { await w.rig.parentCall("agent_wait", ["names": ["a", "b"], "any": true, "wait_s": 20]) }
        try await Task.sleep(for: .milliseconds(100))
        await w.finishAsWorker(child: a, computer: "a")
        let first = ok(await anyWait.value)
        #expect(first["workers"]?.array?.map { $0["state"]?.string } == ["done", "running"] && first["done"]?.bool == true)
        let all = ok(await w.rig.parentCall("agent_wait", ["names": ["a", "b"], "wait_s": 0.3]))
        #expect(all["done"]?.bool == false, "all-mode keeps waiting for b")
    }

    @Test func waitTimesOutAtWaitSeconds() async throws {
        let w = try await WorkerRig.make()
        defer { w.rig.cleanup() }
        _ = await w.spawn()
        let started = ContinuousClock.now
        let reply = ok(await w.rig.parentCall("agent_wait", ["names": ["houston"], "wait_s": 0.4]))
        let took = started.duration(to: .now)
        #expect(took >= .milliseconds(350) && took < .seconds(10), "never blocks much past wait_s (loose bound: the suite runs in parallel)")
        #expect(reply["done"]?.bool == false && reply["workers"]?.array?.first?["state"]?.string == "running")
        #expect(errorCode(await w.rig.parentCall("agent_wait", ["names": ["nobody"], "wait_s": 0])) == "not_found")
    }

    @Test func waitWakesWhenTheProcessExitsWithoutAResult() async throws {
        let w = try await WorkerRig.make()
        defer { w.rig.cleanup() }
        let child = try #require(await w.spawn()["child_id"]?.string)
        _ = await w.rig.wait("houston", .ready)
        let waiting = Task { await w.rig.parentCall("agent_wait", ["names": ["houston"], "wait_s": 20]) }
        try await Task.sleep(for: .milliseconds(100))
        await w.rig.scheduler.workerExited(childID: child, exitCode: 1)
        let item = try #require(ok(await waiting.value)["workers"]?.array?.first)
        #expect(item["state"]?.string == "failed" && item["reason"]?.string?.contains("exited before it submitted a result") == true)
        // O computador foi devolvido.
        let phase = await w.rig.scheduler.phase(of: "houston")
        #expect(phase == nil)
    }

    @Test func processExitAfterAResultIsDoneAndReleasesTheComputer() async throws {
        let w = try await WorkerRig.make()
        defer { w.rig.cleanup() }
        let child = try #require(await w.spawn()["child_id"]?.string)
        _ = await w.rig.wait("houston", .ready)
        _ = await w.rig.service.call("box_claim", arguments: ["name": "houston", "wait_s": 5], child: child)
        _ = await w.rig.service.call("result_submit", arguments: ["result": ["rows": 1]], child: child)
        await w.rig.scheduler.workerExited(childID: child, exitCode: 0)  // saiu sem box_release
        let item = try #require(ok(await w.rig.parentCall("agent_status", ["names": ["houston"]]))["workers"]?.array?.first)
        #expect(item["state"]?.string == "done")
        let phase = await w.rig.scheduler.phase(of: "houston")
        #expect(phase == nil)
    }

    @Test func releaseWithoutAResultIsAFailure() async throws {
        let w = try await WorkerRig.make()
        defer { w.rig.cleanup() }
        let child = try #require(await w.spawn()["child_id"]?.string)
        await w.finishAsWorker(child: child, computer: "houston", submit: false)
        let item = try #require(ok(await w.rig.parentCall("agent_wait", ["names": ["houston"], "wait_s": 5]))["workers"]?.array?.first)
        #expect(item["state"]?.string == "failed" && item["result_ready"]?.bool == false)
    }

    @Test func aWorkerThatFailsToStartFailsAndFreesItsComputer() async throws {
        let w = try await WorkerRig.make()
        defer { w.rig.cleanup() }
        await w.launcher.configure(failStart: "no terminal", scheduler: w.rig.scheduler)
        _ = await w.spawn()
        let item = try #require(ok(await w.rig.parentCall("agent_wait", ["names": ["houston"], "wait_s": 10]))["workers"]?.array?.first)
        #expect(item["state"]?.string == "failed" && item["reason"]?.string?.contains("failed to start") == true)
        // O computador é liberado logo depois do "failed" (em outra tarefa): espera um instante em vez de exigir a mesma volta.
        var phase = await w.rig.scheduler.phase(of: "houston")
        for _ in 0..<50 where phase != nil {
            try await Task.sleep(for: .milliseconds(20))
            phase = await w.rig.scheduler.phase(of: "houston")
        }
        #expect(phase == nil)
    }

    @Test func stopEscalatesInterruptTerminateKillAndReleases() async throws {
        let w = try await WorkerRig.make()
        defer { w.rig.cleanup() }
        _ = await w.spawn()
        for _ in 0 ..< 100 where await w.launcher.started.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        _ = await w.rig.wait("houston", .ready)
        await w.launcher.configure(exitsOn: .kill, scheduler: w.rig.scheduler)
        let stopped = ok(await w.rig.parentCall("agent_stop", ["name": "houston"]))
        let sigs1 = await w.launcher.signals
        #expect(sigs1 == [.interrupt, .terminate, .kill])
        #expect(stopped["state"]?.string == "stopped")
        let phase = await w.rig.scheduler.phase(of: "houston")
        #expect(phase == nil)
    }

    @Test func stopStopsAtTheFirstSignalThatWorks() async throws {
        let w = try await WorkerRig.make()
        defer { w.rig.cleanup() }
        _ = await w.spawn()
        for _ in 0 ..< 100 where await w.launcher.started.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        await w.launcher.configure(exitsOn: .interrupt, scheduler: w.rig.scheduler)
        _ = ok(await w.rig.parentCall("agent_stop", ["name": "houston"]))
        let sigs2 = await w.launcher.signals
        #expect(sigs2 == [.interrupt])
        let item = try #require(ok(await w.rig.parentCall("agent_status", ["names": ["houston"]]))["workers"]?.array?.first)
        #expect(item["state"]?.string == "stopped")
    }

    @Test func onlyTheSpawningParentSeesAndStopsAWorker() async throws {
        let w = try await WorkerRig.make()
        defer { w.rig.cleanup() }
        _ = await w.spawn()
        await w.rig.hub.registerParent(id: "parent-bbbbbbbb", capability: "cap-b")
        #expect(errorCode(await w.rig.parentCall("agent_stop", ["name": "houston"], as: "parent-bbbbbbbb")) == "blocked_by_policy")
        #expect(errorCode(await w.rig.parentCall("agent_wait", ["names": ["houston"], "wait_s": 0], as: "parent-bbbbbbbb")) == "not_found")
        let other = ok(await w.rig.parentCall("agent_status", [:], as: "parent-bbbbbbbb"))
        #expect(other["workers"]?.array?.isEmpty == true)
        // Um worker nunca chama as ferramentas do pai.
        let child = try #require(await w.rig.hub.children(of: "parent-aaaaaaaa").first { OrchestrationInjectionBuilder.isAppWorker($0) })
        for tool in ["agent_stop", "agent_wait", "agent_status"] {
            let args: JSON = tool == "agent_stop" ? ["name": "houston"] : tool == "agent_wait" ? ["names": ["houston"]] : [:]
            #expect(errorCode(await w.rig.parentCall(tool, args, as: child)) == "blocked_by_policy")
        }
    }

    @Test func statusAndBoxesStatusCarryTheLiveHarnessHint() async throws {
        let live = Mutex(SubagentHarness.codex)
        let rig = try await SchedulerRig.make(sessionInfo: { _ in SessionRef(id: UUID(), title: "t", harness: live.withLock { $0 }) })
        defer { rig.cleanup() }
        #expect(ok(await rig.parentCall("agent_status"))["subagent_harness"]?.string == "codex")
        #expect(ok(await rig.parentCall("boxes_status"))["subagent_harness"]?.string == "codex")
        live.withLock { $0 = .mixed }  // trocado no menu da sessão no meio da execução
        #expect(ok(await rig.parentCall("agent_status"))["subagent_harness"]?.string == "mixed")
        #expect(ok(await rig.parentCall("boxes_status"))["subagent_harness"]?.string == "mixed")
    }

    @Test func spawnWithoutALauncherIsNotSupportedAndTheGateStillApplies() async throws {
        let rig = try await SchedulerRig.make()
        defer { rig.cleanup() }
        #expect(errorCode(await rig.parentCall("agent_spawn", ["brief": "go", "name": "x"])) == "not_supported")
        // O mesmo portão do boxes_reserve: `pending` não lança nada.
        let launcher = FakeWorkerLauncher()
        await rig.scheduler.setWorkerLauncher(launcher, helperPath: "/h")
        let gated = ComputerToolService(hub: rig.hub, orchestrator: rig.scheduler, gate: PendingGate())
        let outcome = await gated.call("agent_spawn", arguments: ["brief": "go", "name": "y"], child: rig.parent)
        #expect(outcome.content.first?["text"]?.string?.contains("pending") == true)
        let startedCount = await launcher.started.count, yPhase = await rig.scheduler.phase(of: "y")
        #expect(startedCount == 0 && yPhase == nil)
    }

    @Test func workerRowsPersistHarnessTitleTerminalAndEnd() async throws {
        let home = try ActivityHome(); defer { home.remove() }
        let store = try await home.openStore()
        let w = try await WorkerRig.make(store: store)
        defer { w.rig.cleanup() }
        let child = try #require(await w.spawn(harness: "opencode")["child_id"]?.string)
        for _ in 0 ..< 100 where await w.launcher.started.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(100))
        var row = try #require(try await store.orchestrationChild(id: child))
        #expect(row.harness == "opencode" && row.title == "Houston listings" && row.workerTerminalID != nil && row.slot > 1000)
        #expect(row.capabilityHash == ComputerHub.fingerprint(try #require(await w.launcher.started.first).capability))
        await w.finishAsWorker(child: child, computer: "houston")
        row = try #require(try await store.orchestrationChild(id: child))
        #expect(row.state == .ended)
        try await store.close()
    }

    @Test func workersAreNumberedPerCLIAndShowDoneOnceTheyDeliverEvenWithTheCLIStillOpen() async throws {
        let home = try ActivityHome(); defer { home.remove() }
        let store = try await home.openStore()
        let w = try await WorkerRig.make(store: store)
        defer { w.rig.cleanup() }
        let first = try #require(await w.spawn("books-a")["child_id"]?.string)
        _ = await w.spawn("books-b")
        for _ in 0 ..< 200 where await w.launcher.started.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(Set(await w.launcher.started.map(\.agentName)) == ["Codex 1", "Codex 2"], "two concurrent spawns don't share a number")
        var list = await w.rig.scheduler.appWorkerSummaries(parents: [w.rig.parent])
        #expect(list.count == 2 && list.allSatisfy { !$0.state.isFinal })
        #expect(Set(list.map(\.agentName)) == ["Codex 1", "Codex 2"] && Set(list.compactMap(\.computer)) == ["books-a", "books-b"])
        // O worker entregou e soltou o computador; o CLI segue aberto (nenhuma saída de processo): para a UI, terminou.
        await w.finishAsWorker(child: first, computer: "books-a")
        list = await w.rig.scheduler.appWorkerSummaries(parents: [w.rig.parent])
        #expect(list.first { $0.computer == "books-a" }?.state == .done)
        #expect(list.first { $0.computer == "books-b" }?.state.isFinal == false)
        try await store.close()
    }
}

private struct PendingGate: ReserveGating {
    func authorize(parent: String, _ request: ReserveRequest) async throws -> ReserveAuthorization { .pending(["status": "pending"]) }
}
