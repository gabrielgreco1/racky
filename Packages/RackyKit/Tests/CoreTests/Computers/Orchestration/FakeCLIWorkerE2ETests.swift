import RackyDocker
import RackyPlatform
import RackyProtocol
import Foundation
import Synchronization
import Testing

@testable import RackyCore

// Spec subagent-harness, teste de ponta a ponta com um CLI de mentira (nenhum codex/opencode/claude real, nenhum uso gasto): o plano de
// lançamento é o REAL (`LaunchPlanner` + a injeção do worker), o processo é `Fixtures/fake_worker_cli.py`, e ele fala MCP com o helper
// REAL `racky mcp` pelo `app.sock` de um hub em memória. Tudo em diretórios temporários; nada toca ~/.codex, ~/.config/opencode ou ~/.claude.

private let python = "/usr/bin/python3"
private let fakeCLI = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/fake_worker_cli.py").path

/// Launcher que sobe o CLI de mentira com o argv que o app geraria para o harness, e avisa o scheduler quando o processo sai.
actor ProcessWorkerLauncher: WorkerLauncher {
    private var processes: [UUID: Process] = [:]
    private(set) var signals: [WorkerSignal] = []
    private(set) var plans: [String: LaunchPlan] = [:]
    let socket: String
    let mode: String
    let dumpDirectory: URL
    var scheduler: ComputerScheduler?

    init(socket: String, mode: String, dumpDirectory: URL) { self.socket = socket; self.mode = mode; self.dumpDirectory = dumpDirectory }
    func attach(_ scheduler: ComputerScheduler) { self.scheduler = scheduler }
    func dump(for child: String) -> [String: JSON]? {
        (try? JSON.parse(Data(contentsOf: dumpDirectory.appendingPathComponent("\(child).json"))))?.object
    }

    func start(_ request: WorkerLaunchRequest) async throws -> UUID {
        let provider = TerminalProvider(rawValue: request.harness.rawValue) ?? .codex
        // O plano de verdade (adaptador do CLI + injeção do worker); só o executável é o de mentira.
        var input = LaunchSamples.input(
            LaunchSpec(provider: provider, model: request.model, initialPrompt: request.prompt, workerChildID: request.childID),
            capabilities: LaunchSamples.helpCapabilities(provider), slice: .slice2, injection: WorkerLaunch(request).applied(to: nil))
        input.executablePath = fakeCLI
        input.launchDirectory = dumpDirectory.appendingPathComponent("launch-\(request.childID)", isDirectory: true)
        let plan = try LaunchPlanner.plan(input)
        try LaunchFileWriter.materialize(plan)
        plans[request.childID] = plan
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-I", fakeCLI] + Array(plan.flattenedArgv.dropFirst())
        var env = ["PATH": "/usr/bin:/bin", "HOME": dumpDirectory.path, "RACKY_APP_SOCK": socket, "FAKE_CLI_MODE": mode,
                   "FAKE_CLI_DUMP": dumpDirectory.appendingPathComponent("\(request.childID).json").path]
        for (key, value) in plan.environment where key == OpenCodeOrchestration.environmentName { env[key] = value }
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let id = UUID(), child = request.childID
        process.terminationHandler = { [weak self] finished in
            Task { await self?.exited(child: child, code: Int(finished.terminationStatus)) }
        }
        try process.run()
        processes[id] = process
        return id
    }

    private func exited(child: String, code: Int) async { await scheduler?.workerExited(childID: child, exitCode: code) }

    func signal(terminal: UUID, _ signal: WorkerSignal) async {
        signals.append(signal)
        guard let process = processes[terminal], process.isRunning else { return }
        switch signal {
        case .interrupt: kill(process.processIdentifier, SIGINT)
        case .terminate: kill(process.processIdentifier, SIGTERM)
        case .kill: kill(process.processIdentifier, SIGKILL)
        }
    }

    func terminateAll() { for process in processes.values where process.isRunning { kill(process.processIdentifier, SIGKILL) } }
}

@Suite("Subagent harness: CLI de mentira de ponta a ponta", .tags(.integration), .serialized, .enabled(if: FileManager.default.isExecutableFile(atPath: python)))
struct FakeCLIWorkerE2ETests {
    struct World {
        let rig: SchedulerRig
        let launcher: ProcessWorkerLauncher
        let sockets: AppSockHub
        let home: URL

        static func make(mode: String, harness: SubagentHarness = .codex) async throws -> World {
            let rig = try await SchedulerRig.make(workers: 2, sessionInfo: { _ in SessionRef(id: UUID(), title: "e2e", harness: harness) })
            let home = URL(fileURLWithPath: "/tmp/abe-\(UInt32.random(in: 0 ... 0xFFFFFF))", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let socket = home.appendingPathComponent("app.sock").path
            let server = ComputerMCPServer(tools: rig.service)
            let sockets = AppSockHub(socketPath: socket, providers: [McpServiceProvider(server: server, hub: rig.hub)])
            try await sockets.start()
            let launcher = ProcessWorkerLauncher(socket: socket, mode: mode, dumpDirectory: home)
            await launcher.attach(rig.scheduler)
            await rig.scheduler.setWorkerLauncher(launcher, helperPath: McpHelperProcessTests.binary().path)
            await rig.scheduler.setStopGrace(.milliseconds(400))
            return World(rig: rig, launcher: launcher, sockets: sockets, home: home)
        }

        func teardown() async {
            await launcher.terminateAll()
            await sockets.stop()
            rig.cleanup()
            try? FileManager.default.removeItem(at: home)
        }

        func spawn(_ name: String = "example", harness: String? = nil) async throws -> JSON {
            var args: [String: JSON] = ["brief": "TASK: open https://example.com and submit its title", "title": "Example title", "name": .string(name)]
            if let harness { args["harness"] = .string(harness) }
            let reply = await rig.parentCall("agent_spawn", .object(args))
            try #require(!reply.isError, "\(reply.json.text)")
            return reply.json
        }
    }

    @Test(arguments: ["codex", "opencode", "claude"])
    func aWorkerRunsTheWholeFlowThroughTheRealHelper(_ harness: String) async throws {
        let w = try await World.make(mode: "done")
        defer { Task { await w.teardown() } }
        let reply = try await w.spawn(harness: harness)
        #expect(reply["harness"]?.string == harness)
        let child = try #require(reply["child_id"]?.string)
        let waited = await w.rig.parentCall("agent_wait", ["names": ["example"], "wait_s": 45])
        let item = try #require(waited.json["workers"]?.array?.first, "\(waited.json.text)")
        #expect(item["state"]?.string == "done" && item["result_ready"]?.bool == true, "\(item)")
        // O CLI viu a configuração do harness certo e o prompt completo com o nome do computador.
        let dump = try #require(await w.launcher.dump(for: child))
        #expect(dump["computer"]?.string == "example" && (dump["prompt_len"]?.int ?? 0) > 3000)
        let plan = try #require(await w.launcher.plans[child])
        switch harness {
        case "codex": #expect(plan.argv.injected.contains { $0.hasPrefix("mcp_servers.racky_worker={") } && !plan.argv.injected.contains { $0.hasPrefix("mcp_servers.racky=") })
        case "opencode": #expect(dump["has_opencode_config"]?.bool == true)
        default: #expect(plan.argv.injected.contains("--mcp-config"))
        }
        // O resultado passou pelo MCP de verdade: o pai o coleta e o computador foi devolvido.
        let collected = await w.rig.parentCall("box_collect", ["name": "example"])
        #expect(!collected.isError && collected.json.text.contains("Example Domain"), "\(collected.json.text)")
        #expect(await w.rig.scheduler.phase(of: "example") == nil)
        #expect(await w.launcher.signals.isEmpty)
    }

    @Test func aWorkerThatCrashesAfterClaimingIsFailedAndItsComputerComesBack() async throws {
        let w = try await World.make(mode: "crash")
        defer { Task { await w.teardown() } }
        _ = try await w.spawn()
        let waited = await w.rig.parentCall("agent_wait", ["names": ["example"], "wait_s": 45])
        let item = try #require(waited.json["workers"]?.array?.first)
        #expect(item["state"]?.string == "failed" && item["result_ready"]?.bool == false && item["reason"]?.string?.contains("code 3") == true, "\(item)")
        #expect(await w.rig.scheduler.phase(of: "example") == nil)
    }

    @Test func aWorkerThatSubmitsAndQuitsWithoutReleasingIsDoneAndReleased() async throws {
        let w = try await World.make(mode: "quit")
        defer { Task { await w.teardown() } }
        _ = try await w.spawn()
        let waited = await w.rig.parentCall("agent_wait", ["names": ["example"], "wait_s": 45])
        #expect(waited.json["workers"]?.array?.first?["state"]?.string == "done")
        #expect(await w.rig.scheduler.phase(of: "example") == nil)
    }

    @Test func stopEscalatesAgainstARealProcessThatIgnoresSIGINTAndSIGTERM() async throws {
        let w = try await World.make(mode: "hang")
        defer { Task { await w.teardown() } }
        _ = try await w.spawn()
        // Espera o worker reivindicar o computador (prova que o CLI está vivo e falando com o helper).
        var claimed = false
        for _ in 0 ..< 400 where !claimed {
            claimed = (await w.rig.hub.computer(named: "example")?.owner) != nil
            if !claimed { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(claimed)
        let stopped = await w.rig.parentCall("agent_stop", ["name": "example"])
        #expect(!stopped.isError && stopped.json["state"]?.string == "stopped", "\(stopped.json.text)")
        #expect(await w.launcher.signals == [.interrupt, .terminate, .kill], "the process ignored the first two, only SIGKILL ended it")
        #expect(await w.rig.scheduler.phase(of: "example") == nil)
    }
}
