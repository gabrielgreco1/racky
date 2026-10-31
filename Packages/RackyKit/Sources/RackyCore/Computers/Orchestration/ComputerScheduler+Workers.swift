import RackyProtocol
import RackyStore
import Foundation

// Spec subagent-harness: `agent_spawn`, `agent_wait`, `agent_status`, `agent_stop` e o fim de vida dos workers de app (CLI separado
// num terminal próprio). A reserva do computador é a mesma de `boxes_reserve`; o que muda é quem opera o computador.

/// Um worker de app que este processo conhece.
struct AppWorker {
    var name: String
    var childID: String
    var parent: String
    var harness: WorkerHarness
    var title: String
    var state: AppWorkerState
    var terminalID: UUID?
    var reason: String?
    var stopRequested = false
    var startedAt: Date
    var endedAt: Date?
}

extension ComputerScheduler {
    // MARK: Ligação com o app

    /// O app liga o launcher (RackyUI) e o caminho do helper `racky` que o terminal do worker usa como servidor MCP.
    public func setWorkerLauncher(_ launcher: (any WorkerLauncher)?, helperPath: String) {
        workerLauncher = launcher
        workerHelperPath = helperPath
    }

    /// Só para testes: intervalo entre SIGINT, SIGTERM e SIGKILL de `agent_stop`.
    public func setStopGrace(_ grace: Duration) { stopGrace = grace }

    // MARK: Consulta

    public func sessionHarness(parent: String) async -> SubagentHarness? { await sessionInfo(parent)?.harness }

    /// `base`, ou `base-2`, `base-3`... se já existe computador ou worker com o nome neste pai.
    public func freeWorkerName(parent: String, base: String) async -> String {
        let root = Self.slug(base)
        func taken(_ name: String) -> Bool {
            entries[name] != nil || appWorkers.values.contains { $0.parent == parent && $0.name == name && !$0.state.isFinal }
        }
        guard taken(root) else { return root }
        var index = 2
        while taken("\(root)-\(index)") { index += 1 }
        return "\(root)-\(index)"
    }

    /// Nome de computador válido a partir de um título livre.
    nonisolated static func slug(_ text: String) -> String {
        var out = ""
        var lastDash = false
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII { out.unicodeScalars.append(scalar); lastDash = false }
            else if !lastDash, !out.isEmpty { out += "-"; lastDash = true }
        }
        out = String(out.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return out.isEmpty ? "worker" : out
    }

    /// O worker (de qualquer pai) dono do computador `name`; a sidebar liga o computador ao terminal por aqui.
    public func workerTerminal(ofComputer name: String) -> UUID? {
        appWorkers.values.first { $0.name == name && !$0.state.isFinal }?.terminalID
    }

    // MARK: agent_spawn

    public func agentSpawn(parent: String, request: AgentSpawnRequest, reserve template: ReserveRequest) async throws -> JSON {
        guard let launcher = workerLauncher else { throw ToolError(.notSupported, "this app build can't open subagent worker terminals") }
        guard let name = template.names.first, Self.validName(name) else {
            throw ToolError.invalid("computer names use letters, digits, '.', '_' and '-' (max 100)")
        }
        if let live = appWorkers.values.first(where: { $0.parent == parent && $0.name == name && !$0.state.isFinal }) {
            throw ToolError.invalid("a worker named \(name) is already running (child_id \(live.childID)); pick another name or agent_stop it")
        }
        let session = await sessionInfo(parent)
        let harness = request.harness ?? (session?.harness ?? .claude).defaultWorker
        let title = Self.workerTitle(request.title, fallback: name)

        // Identidade própria do worker: capability nova, só o hash fica no hub e no Store.
        var index = 1
        let existing = Set(await hub.children(of: parent))
        while existing.contains(OrchestrationInjectionBuilder.appWorkerID(parent: parent, index: index)) { index += 1 }
        let childID = OrchestrationInjectionBuilder.appWorkerID(parent: parent, index: index)
        let capability = OrchestrationInjectionBuilder.randomToken()
        await hub.registerChild(id: childID, capability: capability, parent: parent)
        try? await store?.registerOrchestrationChild(OrchestrationChild(
            id: childID, parentID: parent, parentRunID: UUID(uuidString: parent), slot: OrchestrationInjectionBuilder.appWorkerSlotBase + index,
            agentType: "app-worker", capabilityHash: ComputerHub.fingerprint(capability), harness: harness.rawValue, title: title))

        var reservation = template
        reservation.childID = childID
        let reply = await reserve(parent: parent, reservation)
        guard let box = reply["boxes"]?.array?.first, box["state"]?.string != "unavailable" else {
            await hub.unregisterChild(id: childID)
            try? await store?.updateOrchestrationChild(id: childID, state: .ended, at: now())
            let box = reply["boxes"]?.array?.first
            throw ToolError(
                .notSupported, box?["message"]?.string ?? "the computer for this worker could not be reserved",
                details: box.map { (b: JSON) -> JSON in JSON.object(["reason": b["reason"] ?? JSON.null, "name": JSON.string(name)]) })
        }
        appWorkers[childID] = AppWorker(
            name: name, childID: childID, parent: parent, harness: harness, title: title, state: .starting, startedAt: now())
        let ordinal = await workerOrdinals(parent: parent)[childID] ?? 1
        var launch = WorkerLaunchRequest(
            parentID: parent, sessionID: session?.id, harness: harness, childID: childID, capability: capability, computerName: name, title: title,
            prompt: OrchestrationText.workerPrompt(harness: harness, computer: name, brief: request.brief, title: title), model: request.model,
            helperPath: workerHelperPath)
        launch.ordinal = ordinal
        // O lançamento do terminal não bloqueia o pai: `agent_spawn` responde já e o resto acontece aqui.
        Task { await self.launchWorker(launch, with: launcher) }
        notifyChange()
        var out: [String: JSON] = [
            "name": .string(name), "child_id": .string(childID), "harness": .string(harness.rawValue),
            "state": .string(box["state"]?.string == "queued" ? "queued" : "starting"),
        ]
        if let position = box["position"] { out["position"] = position }
        if let hint = session?.harness { out["subagent_harness"] = .string(hint.rawValue) }
        return .object(out)
    }

    /// Número de cada worker entre os do mesmo CLI do pai ("Codex 1", "Codex 2"), estável depois de reabrir o app: conta os que já abriram
    /// terminal (Store) e os vivos nesta execução, na ordem do slot.
    func workerOrdinals(parent: String) async -> [String: Int] {
        let stored = (try? await store?.orchestrationChildren(parentID: parent)) ?? []
        var harnessOf: [String: (slot: Int, harness: String)] = [:]
        for child in stored where child.agentType == "app-worker" && child.workerTerminalID != nil {
            harnessOf[child.id] = (child.slot, child.harness ?? "")
        }
        for worker in appWorkers.values where worker.parent == parent {
            let slot = stored.first { $0.id == worker.childID }?.slot ?? Int.max
            harnessOf[worker.childID] = (slot, worker.harness.rawValue)
        }
        var out: [String: Int] = [:]
        for group in Dictionary(grouping: harnessOf, by: { $0.value.harness }).values {
            for (i, entry) in group.sorted(by: { ($0.value.slot, $0.key) < ($1.value.slot, $1.key) }).enumerated() { out[entry.key] = i + 1 }
        }
        return out
    }

    /// Workers de app com terminal, para a sidebar e as abas: computador, nome do agente e se já terminaram (o CLI pode seguir aberto
    /// esperando input depois do `result_submit` + `box_release`; para a UI ele terminou).
    public func appWorkerSummaries(parents: [String]) async -> [AppWorkerSummary] {
        var out: [AppWorkerSummary] = []
        for parent in parents {
            let ordinals = await workerOrdinals(parent: parent)
            let stored = (try? await store?.orchestrationChildren(parentID: parent)) ?? []
            for child in stored where child.agentType == "app-worker" {
                guard let terminal = child.workerTerminalID ?? appWorkers[child.id]?.terminalID else { continue }
                let live = appWorkers[child.id]
                let harness = live?.harness ?? child.harness.flatMap(WorkerHarness.init(rawValue:)) ?? .codex
                let state: AppWorkerState = live?.state ?? (child.state == .ended || child.state == .released ? .done : .running)
                out.append(AppWorkerSummary(
                    terminalID: terminal, computer: child.computerName ?? live?.name,
                    agentName: "\(harness.title) \(ordinals[child.id] ?? 1)", state: state))
            }
        }
        return out
    }

    static func workerTitle(_ title: String?, fallback: String) -> String {
        let trimmed = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        return String((trimmed.isEmpty ? fallback : trimmed).prefix(80))
    }

    private func launchWorker(_ request: WorkerLaunchRequest, with launcher: any WorkerLauncher) async {
        do {
            let terminal = try await launcher.start(request)
            guard var worker = appWorkers[request.childID] else { return }
            worker.terminalID = terminal
            if worker.state == .starting { worker.state = .running }
            let stop = worker.stopRequested
            appWorkers[request.childID] = worker
            try? await store?.setOrchestrationWorkerTerminal(id: request.childID, terminalID: terminal)
            notifyChange()
            if stop { await launcher.signal(terminal: terminal, .kill) }  // o pai pediu a parada enquanto o terminal subia
        } catch {
            log.error("worker \(request.childID) failed to start: \(error)")
            await closeWorker(request.childID, .failed, reason: "the worker terminal failed to start: \(String(describing: (error as? LocalizedError)?.errorDescription ?? "\(error)").prefix(200))")
        }
    }

    // MARK: Ciclo de vida

    /// `box_release` do worker (`finish`): com resultado, `done`; sem, `failed` (o prompt manda enviar o resultado até na falha).
    func workerReleased(childID: String, run: RunFolder) async {
        guard let worker = appWorkers[childID], !worker.state.isFinal else { return }
        if FileManager.default.fileExists(atPath: run.work.appendingPathComponent("result.json").path) {
            await endWorker(childID, .done, reason: nil)
        } else if worker.stopRequested {
            await endWorker(childID, .stopped, reason: "stopped by the parent")
        } else {
            await endWorker(childID, .failed, reason: "it released its computer without submitting a result")
        }
    }

    /// O computador saiu (liberado pelo pai ou pelo tempo, ou não subiu) antes de o worker terminar.
    func workerComputerGone(childID: String, reason: String) async {
        guard let worker = appWorkers[childID], !worker.state.isFinal else { return }
        await endWorker(childID, worker.stopRequested ? .stopped : .failed, reason: worker.stopRequested ? "stopped by the parent" : reason)
    }

    /// O app avisa que o terminal do worker saiu (o processo terminou ou o pane foi fechado). Sem resultado, o computador é liberado.
    public func workerExited(childID: String, exitCode: Int? = nil) async {
        guard let worker = appWorkers[childID], !worker.state.isFinal else { return }
        let hasResult = await resultReady(childID: childID)
        if worker.stopRequested { await closeWorker(childID, .stopped, reason: "stopped by the parent") }
        else if hasResult { await closeWorker(childID, .done, reason: nil) }
        else { await closeWorker(childID, .failed, reason: "the worker process exited before it submitted a result" + (exitCode.map { " (code \($0))" } ?? "")) }
    }

    /// Fecha o worker e devolve o computador ANTES de acordar `agent_wait` (o pai nunca vê o fim com o computador ainda preso).
    private func closeWorker(_ childID: String, _ state: AppWorkerState, reason: String?) async {
        await endWorker(childID, state, reason: reason, notify: false)
        await releaseComputer(of: childID)
        notifyChange()
    }

    private func endWorker(_ childID: String, _ state: AppWorkerState, reason: String?, notify: Bool = true) async {
        guard var worker = appWorkers[childID], !worker.state.isFinal else { return }
        worker.state = state
        worker.reason = reason
        worker.endedAt = now()
        appWorkers[childID] = worker
        try? await store?.updateOrchestrationChild(id: childID, state: .ended, at: now())
        if notify { notifyChange() }
    }

    /// O computador do worker segue seguro do pai: solta o que ficou (idempotente; já liberado não faz nada).
    private func releaseComputer(of childID: String) async {
        guard let entry = entries.values.first(where: { $0.childID == childID }) else { return }
        if entry.phase == .active {
            await entry.computer.release()
            await entry.computer.emit(.released(computer: entry.spec.name))
            await finish(entry.computer, keep24h: false)
        } else {
            await discard(entry.spec.name, childState: .ended)
            await drain()
        }
        await checkBatches()
    }

    private func resultReady(childID: String) async -> Bool {
        if let entry = entries.values.first(where: { $0.childID == childID }) {
            return FileManager.default.fileExists(atPath: entry.spec.run.work.appendingPathComponent("result.json").path)
        }
        guard let worker = appWorkers[childID], let run = await locateRun(parent: worker.parent, name: worker.name) else { return false }
        return FileManager.default.fileExists(atPath: run.work.appendingPathComponent("result.json").path)
    }

    // MARK: agent_status / agent_wait

    private func workerJSON(_ worker: AppWorker) async -> JSON {
        var out: [String: JSON] = [
            "name": .string(worker.name), "child_id": .string(worker.childID), "harness": .string(worker.harness.rawValue),
            "title": .string(worker.title), "state": .string(worker.state.parentFacing),
            "result_ready": .bool(await resultReady(childID: worker.childID)),
        ]
        if let reason = worker.reason { out["reason"] = .string(reason) }
        if let entry = entries[worker.name], entry.childID == worker.childID {
            out["computer_state"] = .string(entry.phase == .active ? await entry.computer.state.rawValue : entry.phase.rawValue)
            if entry.phase == .active, !worker.state.isFinal {
                let idle = await entry.computer.idleSeconds(now: now())
                out["idle_s"] = .int(idle)
                if idle >= ComputerToolService.stalledAfterSeconds { out["stalled"] = true }
                if let doing = await entry.computer.lastDoing { out["last_doing"] = .string(doing) }
            }
            if let position = queue.firstIndex(of: worker.name) { out["position"] = .int(position + 1) }
        }
        return .object(out)
    }

    private func workers(of parent: String, named names: [String]?) -> [AppWorker] {
        let mine = appWorkers.values.filter { $0.parent == parent }.sorted { $0.startedAt == $1.startedAt ? $0.name < $1.name : $0.startedAt < $1.startedAt }
        guard let names, !names.isEmpty else { return mine }
        // Mais de um worker pode ter tido o mesmo nome (um já terminou): vale o mais recente.
        return names.compactMap { name in mine.last { $0.name == name || $0.childID == name } }
    }

    public func agentStatus(parent: String, names: [String]?) async -> JSON {
        var items: [JSON] = []
        for worker in workers(of: parent, named: names) { items.append(await workerJSON(worker)) }
        var out: [String: JSON] = ["workers": .array(items)]
        if let names { for name in names where !workers(of: parent, named: [name]).contains(where: { _ in true }) {
            out["not_found"] = .array(((out["not_found"]?.array) ?? []) + [.string(name)])
        } }
        if let harness = await sessionInfo(parent)?.harness { out["subagent_harness"] = .string(harness.rawValue) }
        return .object(out)
    }

    public func agentWait(parent: String, names: [String], any: Bool, waitSeconds: Double) async throws -> JSON {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(min(max(waitSeconds, 0), 45) * 1000)))
        func finished() -> Bool {
            let selected = workers(of: parent, named: names)
            guard !selected.isEmpty else { return true }
            return any ? selected.contains { $0.state.isFinal } : selected.allSatisfy { $0.state.isFinal }
        }
        if workers(of: parent, named: names).isEmpty && !names.isEmpty {
            throw ToolError(.notFound, "no worker named \(names.joined(separator: ", ")) for this session; use the names agent_spawn returned")
        }
        while !finished() {
            let remaining = ContinuousClock.now.duration(to: deadline)
            if remaining <= .zero { break }
            await waitForChange(timeout: remaining)
        }
        var out = await agentStatus(parent: parent, names: names).object ?? [:]
        out["done"] = .bool(finished())
        return .object(out)
    }

    /// Dorme até o próximo evento de worker ou o `timeout`.
    private func waitForChange(timeout: Duration) async {
        let id = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let timer = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.wakeWaiter(id)
            }
            changeWaiters[id] = (continuation, timer)
        }
    }

    private func wakeWaiter(_ id: UUID) {
        guard let waiter = changeWaiters.removeValue(forKey: id) else { return }
        waiter.timer.cancel()
        waiter.continuation.resume()
    }

    func notifyChange() {
        let waiters = changeWaiters
        changeWaiters = [:]
        for (_, waiter) in waiters { waiter.timer.cancel(); waiter.continuation.resume() }
    }

    // MARK: agent_stop

    public func agentStop(parent: String, name: String) async throws -> JSON {
        guard let worker = workers(of: parent, named: [name]).first else {
            if appWorkers.values.contains(where: { $0.name == name || $0.childID == name }) {
                throw ToolError(.blockedByPolicy, "you can only stop workers you spawned")
            }
            throw ToolError(.notFound, "no worker named \(name) for this session")
        }
        if worker.state.isFinal { return await workerJSON(worker) }
        let childID = worker.childID
        appWorkers[childID]?.stopRequested = true
        if let terminal = worker.terminalID, let launcher = workerLauncher {
            // SIGINT -> 5 s -> SIGTERM -> 5 s -> SIGKILL, parando quando o terminal sair (`workerExited`).
            for signal in [WorkerSignal.interrupt, .terminate, .kill] {
                await launcher.signal(terminal: terminal, signal)
                let deadline = ContinuousClock.now.advanced(by: signal == .kill ? .seconds(1) : stopGrace)
                while appWorkers[childID]?.state.isFinal == false {
                    let remaining = ContinuousClock.now.duration(to: deadline)
                    if remaining <= .zero { break }
                    await waitForChange(timeout: remaining)
                }
                if appWorkers[childID]?.state.isFinal != false { break }
            }
        }
        // O terminal não avisou a saída (ou ainda nem existia): a parada vale mesmo assim e o computador volta.
        await closeWorker(childID, .stopped, reason: "stopped by the parent")
        if let current = appWorkers[childID] { return await workerJSON(current) }
        return ["name": .string(name), "state": "stopped"]
    }
}
