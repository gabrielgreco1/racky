import RackyDocker
import RackyPlatform
import RackyProtocol
import RackyStore
import Foundation

// F12/F13: a fiação que a T3-04 deixou fora do app. Um orquestrador por app: hub, scheduler, ferramentas MCP, porta de consentimento
// (Off/Ask/Full) e o preparo das imagens. A cada lançamento de um Claude com "Subagent computers" ligado o app chama `prepareParent`,
// que gera `--mcp-config` + `--plugin-dir` + `--agents` + deny de `Skill(racky)` (OrchestrationInjectionBuilder) e registra as identidades.

public final class ComputerOrchestrator: Sendable {
    public let hub: ComputerHub
    public let scheduler: ComputerScheduler
    public let approvals: ComputerApprovalCenter
    public let parents: ParentDirectory
    public let tools: ComputerToolService
    public let provisioning: AppComputerProvisioning
    public let helperPath: String
    public let server: ComputerMCPServer
    /// Bancos que os agentes sobem nos computadores: aparecem no Data e viram datasets da sessão.
    public let databases: ComputerDatabaseWatcher
    private let store: RackyStore?
    public let runsRoot: URL

    /// `waitSeconds`: quanto uma chamada de `boxes_reserve` espera a decisão do Ask antes de devolver `pending` (45 s no app).
    public init(
        helperPath: String, store: RackyStore?, provisioning: AppComputerProvisioning, runsRoot: URL, waitSeconds: TimeInterval = 45,
        fixedEstimates: Bool? = nil, maxParallelCreations: Int = ComputerScheduler.defaultMaxParallelCreations,
        proxies: (any ProxyDirectory)? = nil
    ) {
        self.helperPath = helperPath
        self.store = store
        self.runsRoot = runsRoot
        self.provisioning = provisioning
        let hub = ComputerHub()
        self.hub = hub
        let parents = ParentDirectory()
        self.parents = parents
        scheduler = ComputerScheduler(
            hub: hub, provisioning: provisioning, capacity: { await provisioning.vmCapacity() },
            // `runs/<session-slug>/<computador>` (07 §2.8); sem sessão conhecida, os 8 primeiros caracteres do pai.
            runDirectory: { parent, name in
                let slug = RunArchive.slug(await parents.info(parent)?.sessionTitle, fallback: String(parent.prefix(8)))
                return runsRoot.appendingPathComponent("\(slug)/\(name)", isDirectory: true)
            },
            store: store, maxParallelCreations: maxParallelCreations, fixedEstimates: fixedEstimates, proxies: proxies,
            sessionProxy: { parent in await parents.info(parent)?.proxy },
            sessionInfo: { parent in
                guard let info = await parents.info(parent) else { return nil }
                // Harness vivo: mudar no menu da sessão vale para o próximo spawn, sem reiniciar o pai.
                var harness = info.harness
                if let id = info.sessionID, let live = try? await store?.session(id: id) { harness = live.subagentHarness }
                return SessionRef(id: info.sessionID, title: info.sessionTitle, harness: harness)
            })
        let approvals = ComputerApprovalCenter()
        self.approvals = approvals
        let scheduler = scheduler
        // Datasets: a sessão de quem chama é a do pai (o filho e o pai compartilham a tabela).
        let datasets = store.map { store in
            DatasetBackend(service: DatasetService(store: store)) { [hub, parents] identity in
                let parent = await hub.parent(of: identity) ?? identity
                return await parents.info(parent)?.sessionID
            }
        }
        tools = ComputerToolService(
            hub: hub, orchestrator: scheduler,
            gate: SubagentComputersGate(
                parents: parents, approvals: approvals, waitSeconds: waitSeconds,
                effectiveProxy: { parent, requested in await scheduler.effectiveProxy(parent: parent, requested: requested) },
                effectiveLeftovers: { parent in await scheduler.leftovers(parent: parent) }),
            datasets: datasets)
        server = ComputerMCPServer(tools: tools)
        var append: ComputerDatabaseWatcher.Append?
        if let store {
            let service = DatasetService(store: store)
            append = { session, dataset, rows, computer in
                _ = try await service.append(session: session, name: dataset, rows: rows, provenance: DatasetProvenance(computer: computer, runID: "database"))
            }
        }
        databases = ComputerDatabaseWatcher(
            computers: { [hub] in await hub.allComputers },
            sessionOf: { [scheduler, parents] name in
                guard let parent = await scheduler.parent(of: name) else { return nil }
                return await parents.info(parent)?.sessionID
            },
            append: append)
        if let store {
            Task { await parents.observeProxyChanges { id, proxy in Task { try? await store.updateOrchestrationParentProxy(id: id, proxy: proxy) } } }
            Task { await hub.setBindObserver { thread, child in Task { try? await store.bindOrchestrationThread(childID: child, thread: thread) } } }
        }
    }

    /// O app liga o launcher dos workers de app (RackyUI): `agent_spawn` abre o terminal por ele. `helperPath` é o do orquestrador.
    public func setWorkerLauncher(_ launcher: (any WorkerLauncher)?) async {
        await scheduler.setWorkerLauncher(launcher, helperPath: helperPath)
    }

    /// Serviço `mcp` do `app.sock` (o helper `racky mcp` do Claude fala com ele).
    public var mcpProvider: McpServiceProvider { McpServiceProvider(server: server, hub: hub) }

    /// Liga o scheduler ao hub e o progresso das imagens às linhas dos computadores. `onProblem` recebe "Docker isn't running".
    public func start(onProblem: (@Sendable (ComputerSetupError) -> Void)? = nil) async {
        await scheduler.attach()
        let hub = hub
        await provisioning.setObserver(
            state: { state in
                Task {
                    for computer in await hub.allComputers where await computer.state == .provisioning { await computer.setDetail(state.label) }
                }
            },
            problem: onProblem)
    }

    /// Por lançamento do Claude pai (Ask ou Full): peças de injeção já registradas. Chamar de novo (Resume) gera identidades novas.
    public func prepareParent(_ info: ParentInfo, options: OrchestrationInjectionBuilder.Options = .init()) async throws -> OrchestrationBundle {
        precondition(info.mode.isOn, "prepareParent só vale com Subagent computers ligado")
        var info = info
        if info.proxy == nil, let session = info.sessionID { info.proxy = await parents.proxy(forSession: session) }
        var options = options
        options.harness = info.harness
        if info.provider == .opencode { options.readableDirectories.append(runsRoot.standardizedFileURL.path) }
        var bundle = try OrchestrationInjectionBuilder.make(parentID: info.parentID, helperPath: helperPath, options: options, provider: info.provider)
        bundle.spawnGuardMode = info.mode
        await parents.register(info)
        await observeBindings()
        // A identidade (só o hash da capability) e o que o pai sabe da sessão sobrevivem a um reinício do app (adoção).
        try? await store?.saveOrchestrationParent(OrchestrationParentRecord(
            id: info.parentID, parentRunID: UUID(uuidString: info.parentID), sessionID: info.sessionID, sessionTitle: info.sessionTitle,
            mode: info.mode.rawValue, proxy: info.proxy, capabilityHash: ComputerHub.fingerprint(bundle.parentCapability), provider: info.provider.rawValue,
            poolID: bundle.poolID, poolCapabilityHash: bundle.poolCapability.map(ComputerHub.fingerprint)))
        await OrchestrationInjectionBuilder.register(bundle, hub: hub, scheduler: scheduler, parentRunID: UUID(uuidString: info.parentID))
        return bundle
    }

    /// O terminal pai terminou (saiu, foi fechado ou relançado): solta o que ele reservou e os pedidos que esperavam o usuário.
    public func endParent(_ parentID: String) async {
        await approvals.cancel(parent: parentID)
        let names = await scheduler.computerNames(of: parentID)
        if !names.isEmpty { _ = await scheduler.release(parent: parentID, names: names, keep24h: false) }
        await parents.remove(parentID)
        try? await store?.deleteOrchestrationParent(id: parentID)
        await hub.unregisterPools(of: parentID)
        await hub.unregisterChild(id: parentID)
        for child in await hub.children(of: parentID) { await hub.unregisterChild(id: child) }
    }

    /// Pais com identidade persistida mais velhos que isto não voltam (o terminal deles já terminou há muito).
    static let parentRetention: TimeInterval = 14 * 24 * 3600

    /// App reiniciado: o Claude pai e os subagentes seguiram vivos (o daemon os manteve) com as capabilities do lançamento antigo nos
    /// argumentos. Devolve ao hub e ao diretório de pais o que foi persistido, para o `racky mcp` deles voltar a ser aceito. Só lê o
    /// Store (rápido); chamar antes de aceitar conexões MCP.
    public func restoreIdentities() async {
        await Self.restoreIdentities(store: store, hub: hub, parents: parents)
        await observeBindings()
    }

    /// Persiste a ligação thread -> slot dos workers do Codex (síncrono com o chamador, sem corrida com o primeiro `bind`).
    private func observeBindings() async {
        guard let store else { return }
        await hub.setBindObserver { thread, child in Task { try? await store.bindOrchestrationThread(childID: child, thread: thread) } }
    }

    static func restoreIdentities(store: RackyStore?, hub: ComputerHub, parents: ParentDirectory) async {
        guard let store else { return }
        try? await store.pruneOrchestrationParents(olderThan: Date().addingTimeInterval(-parentRetention))
        for record in (try? await store.orchestrationParents()) ?? [] {
            guard await hub.role(of: record.id) == nil else { continue }  // já registrado neste processo
            await hub.registerParent(id: record.id, capabilityHash: record.capabilityHash)
            await parents.register(ParentInfo(
                parentID: record.id, sessionID: record.sessionID, sessionTitle: record.sessionTitle, mode: SubagentComputersMode(rawValue: record.mode) ?? .ask,
                proxy: record.proxy, provider: TerminalProvider(rawValue: record.provider) ?? .claude))
            // Codex: os workers falam pelo servidor `racky_worker`; sem o pool de volta eles seriam recusados.
            if let pool = record.poolID, let hash = record.poolCapabilityHash, await hub.role(of: pool) == nil {
                await hub.registerPool(id: pool, capabilityHash: hash, parent: record.id)
            }
            if record.proxy != nil { await parents.setProxy(record.proxy, for: record.id) }
            for child in (try? await store.orchestrationChildren(parentID: record.id)) ?? [] {
                guard let hash = child.capabilityHash, await hub.role(of: child.id) == nil else { continue }
                await hub.registerChild(id: child.id, capabilityHash: hash, parent: record.id)
                if let pool = record.poolID, let thread = child.boundThread { await hub.restoreBinding(thread: thread, pool: pool, to: child.id) }
            }
        }
    }

    /// Identidades + computadores: depois de `restoreIdentities`, adota os containers que seguiram vivos (precisa do Docker de pé; sem ele
    /// não faz nada). Devolve os nomes adotados.
    @discardableResult
    public func adoptRunning() async -> [String] {
        await restoreIdentities()
        return await scheduler.adoptRunning()
    }

    /// Agente pai do computador (`Claude`, `Codex`, `OpenCode`), para "<Agent> is using" e "Hand back to <Agent>?".
    public func agentName(ofComputer name: String) async -> String {
        guard let parent = await scheduler.parent(of: name) else { return TerminalProvider.claude.computerAgentName }
        return (await parents.info(parent)?.provider ?? .claude).computerAgentName
    }

    /// Workers de app dos pais abertos (sidebar e abas da sessão).
    public func appWorkers() async -> [AppWorkerSummary] {
        await scheduler.appWorkerSummaries(parents: await parents.all.map(\.parentID))
    }

    /// Todos os lotes das sessões abertas (painel "Batch"): rótulo, filhos e estado. Pais da mesma sessão (retomada) viram um só lote.
    public func batches() async -> [BatchSummary] {
        var out: [BatchSummary] = []
        var seen = Set<String>()
        for info in await parents.all {
            for name in await scheduler.batchNames(parent: info.parentID) {
                guard let summary = await scheduler.batchSummary(parent: info.parentID, batch: name) else { continue }
                let key = "\(summary.sessionID?.uuidString ?? info.parentID)|\(name)"
                if seen.insert(key).inserted { out.append(summary) }
            }
        }
        return out.sorted { ($0.createdAt ?? .distantPast, $0.name) > ($1.createdAt ?? .distantPast, $1.name) }
    }

    /// O consolidado de um lote com os resultados (exportação CSV/JSON e `Collect All`).
    public func consolidated(batch: BatchSummary) async -> BatchSummary? {
        guard let parent = batch.parent else { return nil }
        return await scheduler.consolidatedBatch(parent: parent, batch: batch.name)
    }

    /// `Collect All` do painel: o mesmo `batch_collect` do pai; devolve o caminho do `results.jsonl`.
    public func collectAll(batch: BatchSummary) async -> URL? {
        guard let parent = batch.parent, let reply = try? await scheduler.collectBatch(parent: parent, batch: batch.name),
              let path = reply["results_jsonl_path"]?.string else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// `Archive Batch`: remove os computadores do lote; runs e resultados ficam.
    @discardableResult
    public func archive(batch: BatchSummary) async -> [String] {
        guard let parent = batch.parent else { return [] }
        return await scheduler.archiveBatch(parent: parent, batch: batch.name)
    }

    /// `Archive Computers` de uma sessão (AC-423): os computadores dela saem; runs e perfis ficam.
    @discardableResult
    public func archiveComputers(sessionID: UUID) async -> [String] {
        var names: [String] = []
        for info in await parents.all where info.sessionID == sessionID { names += await scheduler.computerNames(of: info.parentID) }
        return await scheduler.archiveComputers(names: names)
    }

    /// Qual sessão do app é dona do computador (linha filha, título do Inbox).
    public func sessionID(ofComputer name: String) async -> UUID? {
        guard let parent = await scheduler.parent(of: name) else { return nil }
        return await parents.info(parent)?.sessionID
    }
}
