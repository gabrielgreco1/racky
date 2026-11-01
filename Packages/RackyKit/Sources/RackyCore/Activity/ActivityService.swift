import RackyPlatform
import RackyProtocol
import RackyStore
import Foundation

/// Ingestão de eventos de hook no app (06 §3.2): recebe do serviço `hook` de `app.sock` e do spool, grava em
/// `agent_event` (idempotente por id), refaz o estado com o redutor (ordem de ocorrência, não de chegada) e projeta
/// em `agent_run` e no terminal (`last_message`, ID nativo).
public actor ActivityService {
    public enum IngestOutcome: Sendable, Equatable { case applied, duplicate }

    public enum IngestError: Error, Equatable {
        /// `RACKY_RUN_ID` que não é UUID: nunca vira linha; no spool é pulado como linha inválida.
        case invalidRunID(String)
    }

    public struct Update: Sendable, Equatable {
        public var runID: UUID
        public var terminalID: UUID?
        public var activity: AgentActivity
        public var lastMessage: String?
        public var statusReason: String?
        public var subtitle: String?
        public var liveChildren: Int
        public var children: [SubagentInfo] = []

        public init(
            runID: UUID, terminalID: UUID?, activity: AgentActivity, lastMessage: String? = nil, statusReason: String? = nil,
            subtitle: String? = nil, liveChildren: Int = 0, children: [SubagentInfo] = []
        ) {
            self.children = children
            self.runID = runID; self.terminalID = terminalID; self.activity = activity; self.lastMessage = lastMessage
            self.statusReason = statusReason; self.subtitle = subtitle; self.liveChildren = liveChildren
        }
    }

    public struct DrainReport: Sendable, Equatable {
        public var files = 0
        public var applied = 0
        public var duplicates = 0
        public var invalid = 0
        public var truncatedMarkers = 0
        /// Linhas que falharam por erro do banco: o arquivo fica para a próxima drenagem (idempotente).
        public var deferred = 0
    }

    public nonisolated let updates: AsyncStream<Update>
    private nonisolated let updateContinuation: AsyncStream<Update>.Continuation

    private let store: RackyStore
    private let spoolDirectory: URL
    private let log = LogFacade(.app, category: "hooks")

    private struct Cached {
        var state: ActivityState
        var lastAtNs: Int64
        var provider: HookProvider
        var terminalID: UUID?
        var touched: Int
    }
    private var cache: [UUID: Cached] = [:]
    private var touches = 0
    private static let cacheLimit = 64

    /// T3-04: hooks de filhos nativos (`agent_id` + `mcp_server.name`, S-08) para a árvore da orquestração. Chamado depois de gravar.
    public struct ChildHook: Sendable, Equatable {
        public var parentRunID: UUID
        public var event: String
        public var agentID: String
        public var mcpServer: String?
    }
    private var childObserver: (@Sendable (ChildHook) async -> Void)?
    public func setChildObserver(_ observer: (@Sendable (ChildHook) async -> Void)?) { childObserver = observer }

    /// `cwd` informado por um hook de um terminal (a árvore de arquivos do painel direito acompanha o agente, 10-right-panel §2).
    private var cwdObserver: (@Sendable (UUID, String) async -> Void)?
    public func setCwdObserver(_ observer: (@Sendable (UUID, String) async -> Void)?) { cwdObserver = observer }

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var watchTask: Task<Void, Never>?

    public init(store: RackyStore, spoolDirectory: URL) {
        self.store = store
        self.spoolDirectory = spoolDirectory
        (updates, updateContinuation) = AsyncStream.makeStream(of: Update.self, bufferingPolicy: .bufferingNewest(256))
    }

    // MARK: - Ciclo de vida

    /// Cria o diretório do spool, drena o que ficou com o app fechado, reconcilia projeções atrasadas, aplica a retenção
    /// e passa a observar o diretório (kqueue, nunca polling; 08 AR-109).
    public func start() async throws {
        guard watchTask == nil else { return }
        try HookSpool.ensureDirectory(spoolDirectory)
        let changes = try DirectoryWatcher.changes(of: spoolDirectory)
        await drainSpool()
        await reconcile()
        _ = try? await store.pruneAgentEvents()
        watchTask = Task { [weak self] in
            for await _ in changes {
                guard !Task.isCancelled else { return }
                await self?.drainSpool()
            }
        }
    }

    public func stop() {
        watchTask?.cancel()
        watchTask = nil
        updateContinuation.finish()
    }

    // MARK: - Ingestão

    @discardableResult
    public func ingest(_ envelope: HookEnvelope) async throws -> IngestOutcome {
        guard let runID = UUID(uuidString: envelope.runID) else { throw IngestError.invalidRunID(envelope.runID) }
        let pane = envelope.paneID.flatMap(UUID.init(uuidString:))
        return try await ingest(
            runID: runID, terminalID: pane, provider: envelope.provider, eventID: envelope.id, name: envelope.event,
            payload: envelope.payload, atNs: envelope.atNs)
    }

    /// Evento `exit` do daemon (06 §3.3): `code != 0` -> `failed("exited with N")`. Execução desconhecida: sem efeito.
    @discardableResult
    public func recordProcessExit(runID: UUID, code: Int, atNs: Int64 = HookTransport.realtimeNs()) async throws -> IngestOutcome? {
        guard let run = try await store.agentRun(id: runID) else { return nil }
        let provider: HookProvider = run.harness == .codex ? .codex : .claude
        return try await ingest(
            runID: runID, terminalID: run.terminalID, provider: provider, eventID: "process-exit-\(code)",
            name: ActivitySyntheticEvent.processExit, payload: ReducedHookPayload(reason: String(code)), atNs: atNs)
    }

    /// O PTY se perdeu (reboot, crash do daemon): `interrupted`.
    @discardableResult
    public func recordPtyLost(runID: UUID, atNs: Int64 = HookTransport.realtimeNs()) async throws -> IngestOutcome? {
        guard let run = try await store.agentRun(id: runID) else { return nil }
        let provider: HookProvider = run.harness == .codex ? .codex : .claude
        return try await ingest(
            runID: runID, terminalID: run.terminalID, provider: provider, eventID: "pty-lost",
            name: ActivitySyntheticEvent.ptyLost, payload: ReducedHookPayload(), atNs: atNs)
    }

    private func ingest(
        runID: UUID, terminalID: UUID?, provider: HookProvider, eventID: String, name: String,
        payload: ReducedHookPayload, atNs: Int64
    ) async throws -> IngestOutcome {
        await acquire()
        defer { release() }
        do {
            let json = String(decoding: try HookCodec.encoder().encode(payload), as: UTF8.self)
            let harness: TerminalProvider = provider == .claude ? .claude : .codex
            let mainKind = await runKind(terminalID: terminalID)
            let seed = AgentRun(
                id: runID, terminalID: terminalID, rootRunID: runID, kind: mainKind, harness: harness, activity: .starting,
                startedAt: Date(timeIntervalSince1970: Double(atNs) / 1_000_000_000))
            let inserted = try await store.recordAgentEvent(
                NewAgentEvent(runID: runID, eventID: eventID, type: name, payloadJSON: json, atNs: atNs), ensuringRun: seed)
            if !inserted, cache[runID] != nil { return .duplicate }

            let state: ActivityState
            if inserted, var c = cache[runID], atNs >= c.lastAtNs {
                c.state = ActivityReducer.reduce(c.state, ActivityEvent(name: name, payload: payload, atNs: atNs))
                c.lastAtNs = atNs
                c.terminalID = terminalID ?? c.terminalID
                state = c.state
                remember(runID, c)
            } else {
                // Primeiro contato com a execução, evento fora de sequência ou duplicado sem cache (reprojeta e cura):
                // refaz o estado com todos os eventos gravados, em ordem de ocorrência.
                let stored = try await store.agentEvents(runID: runID)
                state = Self.replay(stored)
                remember(runID, Cached(
                    state: state, lastAtNs: stored.last?.atNs ?? atNs, provider: provider, terminalID: terminalID, touched: 0))
            }
            let effectiveTerminal = terminalID ?? cache[runID]?.terminalID
            let projection = ActivityProjector.projection(runID: runID, terminalID: effectiveTerminal, provider: provider, state: state, mainKind: mainKind)
            try await store.saveActivity(projection)
            publish(runID: runID, terminalID: effectiveTerminal, state: state)
            if inserted, let observer = cwdObserver, let cwd = payload.cwd, !cwd.isEmpty, let terminal = effectiveTerminal {
                await observer(terminal, cwd)
            }
            if inserted, let observer = childObserver, let agent = payload.agentID, !agent.isEmpty {
                await observer(ChildHook(parentRunID: runID, event: name, agentID: agent, mcpServer: payload.mcpServer))
            }
            return inserted ? .applied : .duplicate
        } catch {
            cache[runID] = nil  // o próximo evento refaz o estado a partir do banco
            throw error
        }
    }

    /// `app_worker_light` para o terminal de um worker de app (o `launch_spec` gravado antes do lançamento diz); `main` nos demais.
    private var workerTerminals: [UUID: Bool] = [:]
    private func runKind(terminalID: UUID?) async -> AgentRunKind {
        guard let terminalID else { return .main }
        if let known = workerTerminals[terminalID] { return known ? .appWorkerLight : .main }
        let isWorker = (try? await store.isWorkerTerminal(terminalID)) ?? false
        workerTerminals[terminalID] = isWorker
        return isWorker ? .appWorkerLight : .main
    }

    static func replay(_ stored: [StoredAgentEvent]) -> ActivityState {
        let decoder = JSONDecoder()
        let events = stored.map { e in
            ActivityEvent(
                name: e.type, payload: (try? decoder.decode(ReducedHookPayload.self, from: Data(e.payloadJSON.utf8))) ?? ReducedHookPayload(),
                atNs: e.atNs)
        }
        return ActivityReducer.fold(events)  // `agentEvents` já vem ordenado por (at_ns, seq)
    }

    /// Refaz a projeção das execuções cujos eventos estão à frente de `agent_run` (queda entre gravar e projetar).
    public func reconcile() async {
        guard let ids = try? await store.runsNeedingReconcile() else { return }
        for id in ids {
            await acquire()
            defer { release() }
            do {
                guard let run = try await store.agentRun(id: id) else { continue }
                let stored = try await store.agentEvents(runID: id)
                let state = Self.replay(stored)
                let provider: HookProvider = run.harness == .codex ? .codex : .claude
                try await store.saveActivity(ActivityProjector.projection(runID: id, terminalID: run.terminalID, provider: provider, state: state, mainKind: run.kind))
                publish(runID: id, terminalID: run.terminalID, state: state)
            } catch {
                log.error("reconcile failed: \(error)")
            }
        }
    }

    // MARK: - Spool

    /// Consome o spool: cada arquivo é renomeado (sob lock) e lido; linha inválida é registrada e pulada, e o cursor
    /// avança de qualquer forma (corrige `audit/02` #11). Erro de banco mantém o arquivo para a próxima drenagem.
    @discardableResult
    public func drainSpool() async -> DrainReport {
        var report = DrainReport()
        let files: [URL]
        do { files = try HookSpool.takeAll(directory: spoolDirectory) } catch {
            log.error("spool listing failed: \(error)")
            return report
        }
        for file in files {
            report.files += 1
            let lines: [Data]
            do { lines = try HookSpool.readLines(file) } catch {
                log.error("spool file unreadable: \(error)")
                report.deferred += 1
                continue
            }
            var deferred = false
            for line in lines {
                switch HookSpoolLine.parse(line) {
                case .marker(let marker):
                    report.truncatedMarkers += 1
                    log.info("spool truncated, \(marker.dropped) older events were dropped")
                case .invalid(let reason):
                    report.invalid += 1
                    log.error("invalid spool line skipped: \(reason)")
                case .event(let envelope):
                    do {
                        switch try await ingest(envelope) {
                        case .applied: report.applied += 1
                        case .duplicate: report.duplicates += 1
                        }
                    } catch IngestError.invalidRunID(let id) {
                        report.invalid += 1
                        log.error("spool line with invalid run id skipped: \(id)")
                    } catch {
                        report.deferred += 1
                        deferred = true
                        log.error("spool line deferred: \(error)")
                    }
                }
            }
            if !deferred { HookSpool.discard(file) }
        }
        return report
    }

    // MARK: - Interno

    private func remember(_ id: UUID, _ value: Cached) {
        var v = value
        touches += 1
        v.touched = touches
        cache[id] = v
        if cache.count > Self.cacheLimit, let oldest = cache.min(by: { $0.value.touched < $1.value.touched })?.key { cache[oldest] = nil }
    }

    private func publish(runID: UUID, terminalID: UUID?, state: ActivityState) {
        updateContinuation.yield(Update(
            runID: runID, terminalID: terminalID, activity: state.activity, lastMessage: state.lastMessage,
            statusReason: state.statusReason, subtitle: state.subtitle, liveChildren: state.liveChildCount, children: state.subagentInfos))
    }

    /// Exclusão mútua assíncrona: uma ingestão por vez, para que a projeção gravada seja sempre a do estado mais novo.
    private func acquire() async {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

/// Serviço `hook` de `app.sock`: um frame com o `HookEnvelope`, uma resposta `HookAck`, e a conexão fecha.
public struct HookServiceProvider: AppSockServiceProvider {
    public let service = AppSockService.hook
    private let activity: ActivityService

    public init(activity: ActivityService) { self.activity = activity }

    public func admit() -> CtlError? { nil }

    public func makeHandler() -> AppSockServer.Handler {
        let activity = activity
        return { frame in
            func reply(_ ack: HookAck) -> AppSockReply {
                AppSockReply(frames: [(try? HookCodec.encoder().encode(ack)) ?? Data()], close: true)
            }
            guard frame.count <= HookLimits.maxFrameBytes else { return reply(HookAck(ok: false, error: "frame too large")) }
            guard let envelope = try? JSONDecoder().decode(HookEnvelope.self, from: frame) else {
                return reply(HookAck(ok: false, error: "not a hook envelope"))
            }
            do {
                let outcome = try await activity.ingest(envelope)
                return reply(HookAck(ok: true, duplicate: outcome == .duplicate))
            } catch {
                return reply(HookAck(ok: false, error: "\(error)"))
            }
        }
    }
}
