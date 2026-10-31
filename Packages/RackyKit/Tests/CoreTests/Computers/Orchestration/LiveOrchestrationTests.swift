import RackyDocker
import RackyPlatform
import RackyProtocol
import RackyStore
import Foundation
import Testing

@testable import RackyCore

// T3-04 com o Docker real (`RACKY_TEST_DOCKER=1`) e, opcionalmente, o Claude Code real (`RACKY_TEST_CLAUDE=1`, haiku, teto de
// US$ 0,15). Um único "mundo": imagens reais, página de teste numa bridge de teste, scheduler com `DockerComputerProvisioning`, o
// `racky mcp` REAL como processo (identidades do pai e dos workers) falando com um `app.sock` de verdade. Só toca recursos
// `racky.test=1` + `racky.test_run=<id>` e remove tudo ao final.

private func orcRPC(_ method: String, id: Int? = 1, params: JSON? = nil) -> String {
    var object: [String: JSON] = ["jsonrpc": "2.0", "method": .string(method)]
    if let id { object["id"] = .int(id) }
    if let params { object["params"] = params }
    return String(decoding: JSON.object(object).data(), as: UTF8.self)
}

/// Um agente "scriptado": cada chamada sobe o helper real com a identidade dada, como o Claude Code faria.
struct ScriptedAgent {
    let socket: String
    let child: String
    let capability: String

    @discardableResult
    func call(_ tool: String, _ args: JSON = [:]) async throws -> (isError: Bool, json: JSON) {
        let run = await McpHelperProcessTests.run(socket: socket, child: child, capability: capability, lines: [
            orcRPC("tools/call", id: 1, params: ["name": .string(tool), "arguments": args]),
        ], timeout: 120)
        let line = try #require(run.lines.first, "no reply from the helper for \(tool)")
        let reply = try JSON.parse(line)
        if let error = reply["error"] { return (true, error) }
        let text = reply["result"]?["content"]?.array?.first?["text"]?.string ?? "null"
        return (reply["result"]?["isError"]?.bool ?? false, (try? JSON.parse(text)) ?? .null)
    }

    func list() async throws -> [String] {
        let run = await McpHelperProcessTests.run(socket: socket, child: child, capability: capability, lines: [orcRPC("tools/list")])
        let reply = try JSON.parse(try #require(run.lines.first))
        return reply["result"]?["tools"]?.array?.compactMap { $0["name"]?.string } ?? []
    }
}

@Suite("T3-04 - orquestração real", .serialized, .enabled(if: LiveC.enabled), .tags(.integration), .timeLimit(.minutes(10)))
struct LiveOrchestrationTests {
    static let evidenceFile = "slice3/T3-04/live-orchestration.json"
    static let claudeEnabled = ProcessInfo.processInfo.environment["RACKY_TEST_CLAUDE"] == "1"

    @Test func scriptedParentAndWorkerOverRealDockerAndRealHelper() async throws {
        let runID = LiveComputerTests.shortID()
        let detected = try await RuntimeDetector().detect()
        let client = DockerClient(runtime: detected.runtime, defaultTimeout: .seconds(60))
        let testLabels = [RackyLabel.test: "1", "racky.test_run": runID]
        let labelFilter = ["\(RackyLabel.test)=1", "racky.test_run=\(runID)"]
        let e = LiveEvidenceC.shared
        let home = URL(fileURLWithPath: "/tmp/abx-orc-\(runID)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        func cleanup() async {
            let gc = GarbageCollector(client: client)
            if let items = try? await gc.inventory(labels: labelFilter) { _ = await gc.remove(items) }
            if let images = try? await client.listImages(filters: ["label": labelFilter]) { for image in images { try? await client.removeImage(image.id, force: true) } }
            try? FileManager.default.removeItem(at: home)
        }
        do {
            try await scenario(runID: runID, detected: detected, client: client, testLabels: testLabels, home: home, e: e)
        } catch {
            await cleanup()
            await e.flush(to: Self.evidenceFile)
            throw error
        }
        await cleanup()
        let leftovers = (try? await GarbageCollector(client: client).inventory(labels: labelFilter)) ?? []
        #expect(leftovers.isEmpty, "the cleanup left resources behind: \(leftovers.map(\.name))")
        let images = (try? await client.listImages(filters: ["label": labelFilter])) ?? []
        #expect(images.isEmpty, "the cleanup left images behind")
        await e.record("cleanup", ["leftover_resources": .int(leftovers.count), "leftover_images": .int(images.count)])
        await e.flush(to: Self.evidenceFile)
    }

    func scenario(runID: String, detected: DetectedRuntime, client: DockerClient, testLabels: [String: String], home: URL, e: LiveEvidenceC) async throws {
        await e.record("runtime", .string("\(detected.runtime.kind.rawValue): Engine \(detected.version.version), MemTotal \(detected.info.memTotal) (\(String(format: "%.2f", detected.capacity.memGiB)) GiB)"))
        let realPlanner = CapacityPlanner(vm: detected.capacity)
        await e.record("vm", ["mem_gib": .double((detected.capacity.memGiB * 100).rounded() / 100), "max_headless_by_rule": .int(realPlanner.maxConcurrent(.headless)),
                              "vm_warning": realPlanner.vmSizeWarning().map { JSON.string($0) } ?? .null])

        // ---- imagens e cena (como no teste da T3-03)
        let images = ImageManager(client: client)
        let t0 = ContinuousClock.now
        let computerImage = try await images.ensure(ImageSource(repository: "racky-computer-test-\(runID)", contextDirectory: LiveC.repoRoot.appendingPathComponent("runtime/computer"), extraLabels: testLabels))
        await e.record("image_build_seconds", .int(Int(t0.duration(to: .now).components.seconds)))
        let bridge = "abx-t-\(runID)-bridge"
        let bridgeID = try await client.createNetwork(name: bridge, isInternal: false, labels: testLabels)
        let subnet = try #require(try await client.inspectNetwork(bridgeID).subnets.first)
        var origin = ContainerSpec(name: "abx-t-\(runID)-origin", image: computerImage.tag)
        origin.entrypoint = ["python"]
        origin.command = ["-c", liveOriginScript]
        origin.labels = testLabels.merging([RackyLabel.owner: "test-\(runID)", RackyLabel.computer: "c-origin-\(runID)", RackyLabel.ephemeral: "true"]) { $1 }
        origin.user = "65534"
        origin.tmpfs = ["/tmp": "rw,nosuid,size=16m"]
        origin.resources = ContainerResources(memoryBytes: 128 << 20, cpus: 0.5, pidsLimit: 128)
        origin.network = ContainerNetworkAttachment(network: bridge, aliases: ["origin"])
        let originID = try await client.createContainer(origin)
        try await client.startContainer(originID)

        // ---- app: store real, scheduler com Docker real, MCP em `app.sock` real
        let store = try await RackyStore.open(paths: StorePaths(root: home.appendingPathComponent("store", isDirectory: true)))
        let capacityBox = LockedValue(detected.capacity)
        let provisioning = DockerComputerProvisioning(
            client: client, image: computerImage.tag, secrets: BoxSecretFiles(root: home), owner: "test-\(runID)", network: bridge,
            allowCIDRs: [subnet], extraLabels: ["racky.test_run": runID], isTest: true)
        let hub = ComputerHub()
        let scheduler = ComputerScheduler(
            hub: hub, provisioning: provisioning, capacity: { capacityBox.get() },
            runDirectory: { parent, name in home.appendingPathComponent("runs/\(parent.prefix(8))/\(name)", isDirectory: true) }, store: store, fixedEstimates: true)
        await scheduler.attach()
        let service = ComputerToolService(hub: hub, orchestrator: scheduler)
        let socketHome = try McpSocketTests.Home()
        defer { try? FileManager.default.removeItem(at: socketHome.root) }
        let appSock = AppSockHub(socketPath: socketHome.socket, providers: [McpServiceProvider(server: ComputerMCPServer(tools: service), hub: hub)])
        try await appSock.start()
        defer { Task { await appSock.stop() } }

        let parentID = UUID().uuidString.lowercased()
        let helperPath = McpHelperProcessTests.binary().path
        var options = OrchestrationInjectionBuilder.Options()
        options.workerSlots = 4
        let bundle = try OrchestrationInjectionBuilder.make(parentID: parentID, helperPath: helperPath, options: options)
        await OrchestrationInjectionBuilder.register(bundle, hub: hub, scheduler: scheduler)
        let parent = ScriptedAgent(socket: socketHome.socket, child: parentID, capability: bundle.parentCapability)
        func worker(_ slot: Int) -> ScriptedAgent {
            let w = bundle.workers[slot - 1]
            return ScriptedAgent(socket: socketHome.socket, child: w.childID, capability: w.capability)
        }
        #expect(try await parent.list() == ["boxes_reserve", "boxes_status", "boxes_release", "box_collect", "batch_status", "batch_collect", "agent_message"])
        #expect(try await worker(1).list().count == ToolCatalog.all.count)

        // =========================================================== fila com capacidade pela memória (display http: containers leves)
        // VM de teste de 2,9 GiB: orçamento 0,9 GiB, cabem 2 computadores `http` (0,4 GiB cada); o 3º entra na fila com posição visível.
        capacityBox.set(VMCapacity(memTotalBytes: Int64(2.9 * Double(1 << 30)), cpuCount: 14))
        let t1 = ContinuousClock.now
        let reserved = try await parent.call("boxes_reserve", ["names": ["q-one", "q-two", "q-three"], "display": "http", "batch": "queue-demo"])
        let reserveMs = Int(t1.duration(to: .now).components.seconds * 1000 + t1.duration(to: .now).components.attoseconds / 1_000_000_000_000_000)
        #expect(!reserved.isError)
        let reservedBoxes = try #require(reserved.json["boxes"]?.array)
        #expect(reservedBoxes.map { $0["state"]?.string } == ["provisioning", "provisioning", "queued"])
        #expect(reservedBoxes[2]["position"] == 1 && reservedBoxes[2]["reason"] == "memory")
        await e.record("queue_reserve", ["reply": reserved.json, "reserve_call_ms": .int(reserveMs)])
        // O filho do 3º computador (na fila) reivindica por nome: recebe `queued` + posição, e as ferramentas de trabalho devolvem `queued`.
        let thirdChild = try #require(reservedBoxes[2]["child_id"]?.string)
        let thirdSlot = try #require(bundle.workers.first { $0.childID == thirdChild }?.slot)
        let queuedClaim = try await worker(thirdSlot).call("box_claim", ["name": "q-three", "wait_s": 0])
        #expect(queuedClaim.json["state"] == "queued" && queuedClaim.json["position"] == 1)
        let early = try await worker(thirdSlot).call("exec", ["shell": "true"])
        #expect(early.isError && early.json["error"] == "queued")
        // Espera os dois primeiros ficarem prontos e libera um: o da fila entra.
        try await waitFor("q-one and q-two ready", timeout: .seconds(120)) {
            let s = try await parent.call("boxes_status", [:])
            return (s.json["boxes"]?.array ?? []).filter { $0["name"]?.string?.hasPrefix("q-") == true && ($0["state"] == "ready" || $0["state"] == "in_use") }.count >= 2
        }
        let statusQueued = try await parent.call("boxes_status", ["batch": "queue-demo"])
        #expect(statusQueued.json["queue"]?["length"] == 1)
        await e.record("queue_status", statusQueued.json)
        let freed = try await parent.call("boxes_release", ["names": ["q-one"]])
        #expect(freed.json["released"] == ["q-one"])
        try await waitFor("q-three admitted and ready", timeout: .seconds(120)) {
            let s = try await parent.call("boxes_status", ["names": ["q-three"]])
            let state = s.json["boxes"]?.array?.first?["state"]?.string
            return state == "ready" || state == "in_use"
        }
        let claimed = try await worker(thirdSlot).call("box_claim", ["name": "q-three", "wait_s": 20])
        #expect(!claimed.isError && claimed.json["state"] == "in_use")
        let http = try await worker(thirdSlot).call("exec", ["shell": "echo hello-from-q-three"])
        #expect(http.json["stdout_tail"]?.string?.contains("hello-from-q-three") == true)
        let releasedThird = try await worker(thirdSlot).call("box_release")
        #expect(!releasedThird.isError)
        _ = try await parent.call("boxes_release", ["names": ["q-two"]])
        await e.record("queue_admission", "q-three admitted after q-one was released; worker ran exec on it")

        // =========================================================== J4 mínimo: 1 computador headless (Chromium real) e um filho
        capacityBox.set(detected.capacity)  // a VM real
        let reserve1 = try await parent.call("boxes_reserve", ["names": ["phoenix-az"], "display": "headless", "batch": "listings-oct"])
        let box1 = try #require(reserve1.json["boxes"]?.array?.first)
        #expect(box1["state"] == "provisioning" && box1["worker"]?.string?.hasPrefix("racky-worker-") == true)
        let child1 = try #require(box1["child_id"]?.string)
        let slot1 = try #require(bundle.workers.first { $0.childID == child1 }?.slot)
        let w1 = worker(slot1)
        let claim = try await w1.call("box_claim", ["name": "phoenix-az", "wait_s": 45])
        let claim2 = claim.json["state"] == "in_use" ? claim : try await w1.call("box_claim", ["name": "phoenix-az", "wait_s": 45])
        #expect(!claim2.isError && claim2.json["state"] == "in_use", "claim: \(claim2.json.text)")
        let open = try await w1.call("browser_open", ["url": "http://origin:8080/", "wait_s": 0])
        #expect(!open.isError && open.json["title"] == "Origin Page", "open: \(open.json.text)")
        let requestID = try #require(open.json["request_id"]?.string)

        // Mensagem do pai (P12): chega no próximo box_status do filho e fica na timeline.
        let sent = try await parent.call("agent_message", ["child_id": "phoenix-az", "text": "Also report the page heading, then submit."])
        #expect(sent.json["delivered"] == "inbox")
        let status = try await w1.call("box_status")
        #expect(status.json["parent_messages"]?.array?.first?["text"] == "Also report the page heading, then submit.")
        // Um filho de OUTRO pai não recebe nada do nosso e nós não mandamos para ele.
        #expect(try await parent.call("agent_message", ["child_id": "nobody", "text": "x"]).json["error"] == "blocked_by_policy")

        _ = try await w1.call("journal", ["kind": "FOUND", "text": "Heading is Hello Origin", "evidence": [.string(requestID)]])
        let submitted = try await w1.call("result_submit", ["result": ["title": "Origin Page", "heading": "Hello Origin"], "evidence": ["/title": [.string(requestID)]]])
        #expect(!submitted.isError)
        // O pai vê estado, dono e último DOING antes do release.
        let during = try await parent.call("boxes_status", ["names": ["phoenix-az"]])
        let seen = try #require(during.json["boxes"]?.array?.first)
        #expect(seen["owner"]?.string == child1 && seen["child_id"]?.string == child1 && seen["batch"] == "listings-oct")
        await e.record("parent_boxes_status", seen)

        // Árvore persistida: o slot está `claimed` com o computador.
        let treeBefore = try #require(try await store.orchestrationChild(id: child1))
        #expect(treeBefore.computerName == "phoenix-az" && treeBefore.batchID == "listings-oct" && treeBefore.state == .reserved || treeBefore.state == .claimed)

        let runDir = home.appendingPathComponent("runs/\(parentID.prefix(8))/phoenix-az", isDirectory: true)
        let releasedFirst = try await w1.call("box_release")
        #expect(!releasedFirst.isError)
        // Release: timeline gerada, containers removidos, vaga devolvida, slot liberado.
        #expect(FileManager.default.fileExists(atPath: runDir.appendingPathComponent("logs/timeline.md").path))
        #expect(FileManager.default.fileExists(atPath: runDir.appendingPathComponent("work/result.json").path))
        let timeline = (try? String(contentsOf: runDir.appendingPathComponent("logs/timeline.md"), encoding: .utf8)) ?? ""
        #expect(timeline.contains("Also report the page heading"), "agent_message is on the timeline")
        let gone = try await waitForGone(client: client, name: "phoenix-az", runID: runID)
        #expect(gone, "containers of phoenix-az are removed after box_release")
        let after = try await parent.call("boxes_status", [:])
        let remaining = after.json["boxes"]?.array ?? []
        #expect(remaining.isEmpty)
        let treeAfter = try #require(try await store.orchestrationChild(id: child1))
        #expect(treeAfter.state == .released)
        let messages = try await store.agentMessages(childID: child1)
        #expect(messages.count == 1 && messages[0].deliveredAt != nil)
        await e.record("scripted_flow", [
            "claim_state": claim2.json["state"] ?? .null, "title": open.json["title"] ?? .null, "tree_state_after": .string(treeAfter.state.rawValue),
            "timeline_has_message": .bool(timeline.contains("Also report the page heading")), "containers_removed": .bool(gone),
        ])

        // =========================================================== Claude real (haiku), opcional
        if Self.claudeEnabled {
            try await realClaude(
                runID: runID, home: home, socket: socketHome.socket, bundle: bundle, helperPath: helperPath, hub: hub, scheduler: scheduler, store: store,
                parentID: parentID, e: e, client: client)
        }
        try await store.close()
    }

    // MARK: Claude real

    func realClaude(
        runID: String, home: URL, socket: String, bundle: OrchestrationBundle, helperPath: String, hub: ComputerHub, scheduler: ComputerScheduler,
        store: RackyStore, parentID: String, e: LiveEvidenceC, client: DockerClient
    ) async throws {
        let claudePath = try #require(CLIExecutableResolver.resolve(name: "claude", searchPath: ProcessInfo.processInfo.environment["PATH"], override: nil))
        let launchDirectory = home.appendingPathComponent("launch/\(parentID)", isDirectory: true)
        let prompt = """
            spawn 2 subagents for Phoenix and Austin. Both are test targets served by the same local test site, http://origin:8080/ : each \
            subagent only needs to open that URL in its computer and report the page title, nothing else. Run them in the background and wait for both.
            """
        let injection = bundle.apply(to: LaunchInjection(helperPath: helperPath))
        var input = LaunchPlanInput(
            spec: LaunchSpec(provider: .claude, initialPrompt: prompt), terminalID: UUID(), runID: UUID(uuidString: parentID)!, cwd: home.path,
            executablePath: claudePath, capabilities: nil, loginEnvironment: ProcessInfo.processInfo.environment, launchDirectory: launchDirectory,
            slice: .slice2, appVersion: "0.0.0", appSocketPath: socket, injection: injection)
        input.capabilities = LaunchSamples.helpCapabilities(.claude)
        let plan = try LaunchPlanner.plan(input)
        try LaunchFileWriter.materialize(plan)
        // `-p` + saída estruturada + teto de custo; o resto é exatamente o argv injetado do app (--settings/--mcp-config/--plugin-dir/--agents).
        var argv = ["-p", "--model", "haiku", "--dangerously-skip-permissions", "--output-format", "stream-json", "--verbose", "--max-budget-usd", "0.20"]
        argv += plan.argv.injected
        argv += ["--", prompt]
        var env = plan.environment
        env["RACKY_MCP_NO_LAUNCH"] = "1"
        env["RACKY_APP_SOCK"] = socket
        let result = await runProcess(claudePath, argv, environment: env, cwd: home, timeout: 420)
        let lines = result.stdout.split(separator: "\n").compactMap { try? JSON.parse(String($0)) }
        var summary = ClaudeRunSummary()
        for line in lines { summary.absorb(line) }
        await e.record("claude_run", summary.json(exit: result.status))
        try? result.stdout.write(to: home.appendingPathComponent("claude-stream.jsonl"), atomically: true, encoding: .utf8)
        if let root = LiveC.evidenceRoot {
            let url = root.appendingPathComponent("slice3/T3-04/claude-run-summary.json")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? summary.json(exit: result.status).data(pretty: true).write(to: url)
        }
        #expect(summary.initMcpServers.contains("racky"), "the parent got the app MCP: \(summary.initMcpServers)")
        #expect(summary.initSkills.contains { $0.contains("racky-boxes") }, "the app skill is loaded by --plugin-dir: \(summary.initSkills)")
        #expect(summary.toolUses.contains("mcp__racky__boxes_reserve"), "parent reserved a computer: \(summary.toolUses)")
        #expect(summary.agentSubagentTypes.contains { $0.hasPrefix("racky-worker-") }, "parent spawned a native worker: \(summary.agentSubagentTypes)")
        // A skill global continua na listagem (S4); se o modelo tentar chamá-la, o `deny` por lançamento a bloqueia e ela nunca carrega.
        #expect(!summary.loadedSkills.contains { $0 == "racky" }, "the global racky skill never loaded: \(summary.loadedSkills)")
        if summary.skillInvocations.contains("racky") { #expect(summary.errors.contains { $0.contains("blocked by permission rules") }, "the attempt was blocked: \(summary.errors)") }
        #expect(summary.workerToolUses.contains { $0.hasSuffix("__box_claim") } && summary.workerToolUses.contains { $0.hasSuffix("__browser_open") }, "the worker claimed and browsed: \(summary.workerToolUses)")
        #expect(!summary.bashCommands.contains { $0.contains("bin/racky") || $0.contains("racky ") }, "no old CLI execution: \(summary.bashCommands)")
        #expect(!summary.finalText.isEmpty && summary.finalText.contains("Origin Page"), "final answer carries the title: \(summary.finalText)")
        #expect(summary.costUSD < 0.20)
    }

    func waitFor(_ what: String, timeout: Duration, _ condition: @escaping () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(400))
        }
        Issue.record("timeout waiting for \(what)")
    }

    func waitForGone(client: DockerClient, name: String, runID: String) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            let items = try await GarbageCollector(client: client).inventory(labels: ["\(RackyLabel.test)=1", "racky.test_run=\(runID)", "\(RackyLabel.computerName)=\(name)"])
            if items.isEmpty { return true }
            try await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    func runProcess(_ path: String, _ arguments: [String], environment: [String: String], cwd: URL, timeout: Double) async -> (status: Int32, stdout: String) {
        await offPool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.environment = environment
            process.currentDirectoryURL = cwd
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return (-1, "") }
            let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            killer.cancel()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }
    }
}

final class LockedValue<T: Sendable>: @unchecked Sendable {  // SAFETY: NSLock protege o valor.
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ new: T) { lock.lock(); value = new; lock.unlock() }
}

/// Resumo do `stream-json` do Claude real: o que o pai e o filho chamaram, o custo e a resposta final.
struct ClaudeRunSummary {
    var initMcpServers: [String] = []
    var initSkills: [String] = []
    var toolUses: [String] = []  // do pai
    var workerToolUses: [String] = []  // de dentro do subagente (têm `parent_tool_use_id`)
    var agentSubagentTypes: [String] = []
    var skillInvocations: [String] = []
    var bashCommands: [String] = []
    var loadedSkills: [String] = []
    var finalText = ""
    var costUSD = 0.0
    var turns = 0
    var errors: [String] = []

    mutating func absorb(_ line: JSON) {
        let type = line["type"]?.string
        if type == "system", line["subtype"] == "init" {
            initMcpServers = line["mcp_servers"]?.array?.compactMap { $0["name"]?.string } ?? []
            initSkills = line["skills"]?.array?.compactMap { $0.string } ?? []
        }
        if type == "assistant" {
            let isWorker = (line["parent_tool_use_id"]?.string?.isEmpty == false)
            for block in line["message"]?["content"]?.array ?? [] where block["type"] == "tool_use" {
                guard let name = block["name"]?.string else { continue }
                if isWorker { workerToolUses.append(name) } else { toolUses.append(name) }
                if name == "Agent" || name == "Task", let t = block["input"]?["subagent_type"]?.string { agentSubagentTypes.append(t) }
                if name == "Skill", let s = block["input"]?["skill"]?.string { skillInvocations.append(s) }
                if name == "Bash", let c = block["input"]?["command"]?.string { bashCommands.append(c) }
            }
        }
        if type == "user" {
            for block in line["message"]?["content"]?.array ?? [] where block["type"] == "tool_result" {
                let text = block["content"]?.string ?? block["content"]?.array?.compactMap { $0["text"]?.string }.joined() ?? ""
                if block["is_error"] == true { errors.append(String(text.prefix(160))) }
                if text.hasPrefix("Launching skill: ") { loadedSkills.append(String(text.dropFirst("Launching skill: ".count))) }
            }
        }
        if type == "result" {
            finalText = line["result"]?.string ?? ""
            costUSD = line["total_cost_usd"]?.double ?? 0
            turns = line["num_turns"]?.int ?? 0
        }
    }

    func json(exit: Int32) -> JSON {
        [
            "exit": .int(Int(exit)), "racky_mcp_server_present": .bool(initMcpServers.contains("racky")), "other_mcp_servers_count": .int(initMcpServers.filter { $0 != "racky" }.count), "app_skills_loaded": .array(initSkills.filter { $0.contains("racky") }.map { .string($0) }),
            "parent_tool_uses": .array(toolUses.map { .string($0) }), "worker_tool_uses": .array(workerToolUses.map { .string($0) }),
            "agent_subagent_types": .array(agentSubagentTypes.map { .string($0) }), "skill_invocations": .array(skillInvocations.map { .string($0) }), "bash_commands": .array(bashCommands.map { .string($0) }),
            "tool_errors": .array(errors.map { .string($0) }), "skills_loaded_by_the_model": .array(loadedSkills.map { .string($0) }), "final_text": .string(String(finalText.prefix(600))), "cost_usd": .double(costUSD), "turns": .int(turns),
        ]
    }
}
