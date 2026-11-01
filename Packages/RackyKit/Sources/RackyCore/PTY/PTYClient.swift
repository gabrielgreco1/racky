import RackyPlatform
import RackyProtocol
import Foundation
import Synchronization

public enum PTYClientError: Error, Sendable, Equatable {
    case notConnected
    case disconnected
    case timedOut
    case daemon(DaemonError)
    case unexpectedReply
    case handshake(String)
}

/// O que um pane anexado recebe. A sequência sempre começa com `.snapshot`; um novo `.snapshot` depois (reconexão sem
/// `sinceSeq` possível, `resyncRequired`, buraco de `seq`) manda o consumidor refazer o emulador do zero.
public enum PTYUpdate: Sendable, Equatable {
    case snapshot(AttachSnapshot)
    case output(OutputFrame)
    case event(EventPayload)
    /// A conexão com o daemon caiu; o cliente está reconectando. Não chegam bytes até o próximo `.snapshot`.
    case disconnected
}

/// Bytes de saída entregues ao `updates` de um pane e ainda não consumidos (08 AR-406: backlog de 4 MiB por pane).
/// O cliente soma ao entregar; o consumidor (a view) subtrai ao alimentar o emulador.
public final class PTYBacklogGauge: Sendable {
    private let value = Mutex(0)
    public init() {}
    public var pending: Int { value.withLock { $0 } }
    func added(_ count: Int) -> Int { value.withLock { $0 += count; return $0 } }
    /// Chamado pelo consumidor depois de alimentar `count` bytes.
    public func consumed(_ count: Int) { value.withLock { $0 = max(0, $0 - count) } }
}

public struct PTYAttachment: Sendable {
    public let snapshot: AttachSnapshot
    public let updates: AsyncStream<PTYUpdate>
    public let backlog: PTYBacklogGauge
}

public enum PTYConnectionState: Sendable, Equatable {
    case connecting
    case connected(daemonBuild: String, sessions: Int)
    case disconnected
}

public struct PTYClientConfiguration: Sendable {
    public var socketPath: String
    public var build: String
    public var requestTimeout: Duration
    public var reconnectInitialDelay: Duration
    public var reconnectMaxDelay: Duration
    /// `nil`: tenta para sempre.
    public var reconnectMaxAttempts: Int?
    /// Backlog por pane acima do qual a fila é abandonada e o cliente pede `snapshot` (08 AR-406).
    public var maxBacklogBytes: Int

    public init(
        socketPath: String, build: String = "1.0 (dev)", requestTimeout: Duration = .seconds(10),
        reconnectInitialDelay: Duration = .milliseconds(50), reconnectMaxDelay: Duration = .seconds(2), reconnectMaxAttempts: Int? = nil,
        maxBacklogBytes: Int = 4 << 20
    ) {
        self.maxBacklogBytes = maxBacklogBytes
        self.socketPath = socketPath
        self.build = build
        self.requestTimeout = requestTimeout
        self.reconnectInitialDelay = reconnectInitialDelay
        self.reconnectMaxDelay = reconnectMaxDelay
        self.reconnectMaxAttempts = reconnectMaxAttempts
    }
}

/// Cliente do `rackyd` no lado do app (06 §1.1): único cliente do daemon. Actor; nenhuma leitura de PTY nem de
/// socket acontece no main thread (a leitura é do `UDSConnection`, dirigida por GCD).
public actor PTYClient {
    private struct Route {
        var continuation: AsyncStream<PTYUpdate>.Continuation
        var cols: UInt16
        var rows: UInt16
        var validator = OutputSequenceValidator()
        var awaitingSnapshot = true
        let backlog = PTYBacklogGauge()
        /// Fim do replay do último snapshot: só quadros ao vivo (`seq` >= isto) contam para o limite de backlog.
        var replayEndSeq: UInt64 = 0
    }

    private var configuration: PTYClientConfiguration
    private var framed: FramedConnection?
    private var sender: AsyncStream<Frame>.Continuation?
    private var generation = 0
    private var nextRequestID: UInt64 = 2
    private var pending: [RequestID: CheckedContinuation<DaemonReply, any Error>] = [:]
    private var routes: [SessionID: Route] = [:]
    private var readerTask: Task<Void, Never>?
    private var senderTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var stopped = false
    private var stateContinuations: [UUID: AsyncStream<PTYConnectionState>.Continuation] = [:]
    private var currentState = PTYConnectionState.disconnected
    private let eventsContinuation: AsyncStream<DaemonEvent>.Continuation
    /// Todos os eventos do daemon (também de sessões não anexadas, depois de `subscribe`).
    public nonisolated let events: AsyncStream<DaemonEvent>

    public init(configuration: PTYClientConfiguration) {
        self.configuration = configuration
        (events, eventsContinuation) = AsyncStream<DaemonEvent>.makeStream(bufferingPolicy: .unbounded)
    }

    /// Troca o caminho do socket das próximas conexões (o launchd muda o caminho a cada registro; o fallback usa outro socket).
    public func updateSocketPath(_ path: String) {
        configuration.socketPath = path
    }

    public var socketPath: String { configuration.socketPath }

    public func connectionStates() -> AsyncStream<PTYConnectionState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<PTYConnectionState>.makeStream(bufferingPolicy: .unbounded)
        continuation.yield(currentState)
        stateContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeStateContinuation(id) }
        }
        return stream
    }

    private func removeStateContinuation(_ id: UUID) { stateContinuations[id] = nil }

    private func publish(_ state: PTYConnectionState) {
        currentState = state
        for continuation in stateContinuations.values { continuation.yield(state) }
    }

    // MARK: Ciclo de vida

    /// Conecta e faz o handshake (uma vez). Depois disso, quedas são tratadas por reconexão automática.
    public func start() async throws {
        stopped = false
        try await establish()
    }

    public func stop() {
        stopped = true
        reconnectTask?.cancel()
        reconnectTask = nil
        tearDown(failWith: .disconnected)
        for route in routes.values { route.continuation.finish() }
        routes.removeAll()
        publish(.disconnected)
    }

    private func establish() async throws {
        publish(.connecting)
        let result: ClientHandshake.Result
        let framed: FramedConnection
        var opened: FramedConnection?
        do {
            let connection = try await UDSClient.connect(path: configuration.socketPath)
            let candidate = FramedConnection(connection)
            opened = candidate
            framed = candidate
            result = try await candidate.performHandshake(ClientHandshake(client: ClientInfo(kind: .app, build: configuration.build)))
        } catch {
            // Handshake falhou: fecha o socket (senão fd e DispatchSources vazam a cada retry).
            await opened?.close()
            publish(.disconnected)
            throw PTYClientError.handshake("\(error)")
        }
        generation += 1
        let current = generation
        self.framed = framed
        let (frames, continuation) = AsyncStream<Frame>.makeStream(bufferingPolicy: .unbounded)
        sender = continuation
        senderTask = Task { [weak self] in
            for await frame in frames {
                do {
                    try await framed.send(frame)
                } catch {
                    await framed.close()
                    await self?.connectionLost(generation: current)
                    return
                }
            }
        }
        readerTask = Task { [weak self] in
            while true {
                guard let frame = try? await framed.receive() else { break }
                guard let self else { return }
                await self.handle(frame)
            }
            await self?.connectionLost(generation: current)
        }
        publish(.connected(daemonBuild: result.daemon.build, sessions: result.sessions))
    }

    private func tearDown(failWith error: PTYClientError) {
        readerTask?.cancel()
        senderTask?.cancel()
        readerTask = nil
        senderTask = nil
        sender?.finish()
        sender = nil
        if let framed {
            Task { await framed.close() }
        }
        framed = nil
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values { continuation.resume(throwing: error) }
    }

    private func connectionLost(generation lost: Int) {
        guard lost == generation, framed != nil else { return }
        tearDown(failWith: .disconnected)
        for key in routes.keys {
            routes[key]?.awaitingSnapshot = true
            routes[key]?.continuation.yield(.disconnected)
        }
        publish(.disconnected)
        guard !stopped, reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in await self?.reconnectLoop() }
    }

    private func reconnectLoop() async {
        var delay = configuration.reconnectInitialDelay
        var attempts = 0
        while !Task.isCancelled, !stopped {
            attempts += 1
            do {
                try await establish()
                reconnectTask = nil
                await reattachRoutes()
                return
            } catch {
                if let max = configuration.reconnectMaxAttempts, attempts >= max { break }
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, configuration.reconnectMaxDelay)
            }
        }
        reconnectTask = nil
    }

    /// Depois de reconectar: `sinceSeq` do que já foi entregue; se o ring não alcança, o daemon cai para `snapshot`.
    private func reattachRoutes() async {
        for (id, route) in routes {
            let mode: AttachMode = route.validator.expectedSeq.map { .sinceSeq($0) } ?? .snapshot
            do {
                _ = try await request(.attach(AttachRequest(sessionID: id, cols: route.cols, rows: route.rows, mode: mode)))
            } catch let error as PTYClientError {
                if case .daemon(let daemonError) = error, daemonError.code == .unknownSession {
                    routes[id]?.continuation.yield(.event(.sessionGone))
                    routes[id]?.continuation.finish()
                    routes[id] = nil
                }
            } catch {}
        }
    }

    /// Fecha o socket do nosso lado para exercitar a reconexão (testes).
    func dropConnectionForTesting() async {
        if let framed { await framed.close() }
    }

    // MARK: Requisições

    private func request(_ command: DaemonCommand) async throws -> DaemonReply {
        guard let sender else { throw PTYClientError.notConnected }
        let id = RequestID(rawValue: nextRequestID)
        nextRequestID += 1
        let timeout = configuration.requestTimeout
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.expire(id)
        }
        let reply: DaemonReply = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            sender.yield(.control(.request(DaemonRequest(id: id, command: command))))
        }
        if case .error(_, let error) = reply { throw PTYClientError.daemon(error) }
        return reply
    }

    private func expire(_ id: RequestID) {
        pending.removeValue(forKey: id)?.resume(throwing: PTYClientError.timedOut)
    }

    private func okResult(_ command: DaemonCommand) async throws -> OkResult {
        guard case .ok(_, let result) = try await request(command) else { throw PTYClientError.unexpectedReply }
        return result
    }

    public func create(_ create: CreateRequest) async throws -> CreateResult {
        guard case .created(let result) = try await okResult(.create(create)) else { throw PTYClientError.unexpectedReply }
        return result
    }

    public func list() async throws -> [SessionSummary] {
        guard case .list(let result) = try await okResult(.list) else { throw PTYClientError.unexpectedReply }
        return result.sessions
    }

    public func ping() async throws -> PongInfo {
        guard case .pong(let result) = try await okResult(.ping) else { throw PTYClientError.unexpectedReply }
        return result
    }

    public func textSnapshot(sessionID: SessionID, lines: Int) async throws -> String {
        guard case .textSnapshot(let result) = try await okResult(.textSnapshot(TextSnapshotRequest(sessionID: sessionID, lines: lines))) else {
            throw PTYClientError.unexpectedReply
        }
        return result.text
    }

    public func resize(sessionID: SessionID, cols: UInt16, rows: UInt16) async throws {
        let interval = Perf.begin(.resize)
        defer { interval.end() }
        _ = try await okResult(.resize(ResizeRequest(sessionID: sessionID, cols: cols, rows: rows)))
        routes[sessionID]?.cols = cols
        routes[sessionID]?.rows = rows
    }

    public func signal(sessionID: SessionID, signal: Int32, target: SignalTarget = .group) async throws {
        _ = try await okResult(.signal(SignalRequest(sessionID: sessionID, signal: signal, target: target)))
    }

    public func kill(sessionID: SessionID, mode: KillMode = .graceful) async throws {
        _ = try await okResult(.kill(KillRequest(sessionID: sessionID, mode: mode)))
    }

    public func forget(sessionID: SessionID) async throws {
        _ = try await okResult(.forget(SessionTarget(sessionID: sessionID)))
        routes[sessionID]?.continuation.finish()
        routes[sessionID] = nil
    }

    public func subscribe(_ scope: SubscribeScope, events: [EventKind]) async throws {
        _ = try await okResult(.subscribe(SubscribeRequest(scope: scope, events: events)))
    }

    public func drainWhenIdle() async throws {
        _ = try await okResult(.drainWhenIdle)
    }

    /// F30: encerra o daemon e todas as sessões. Só para "Stop and Quit" e testes.
    public func shutdownDaemon() async throws {
        _ = try await okResult(.shutdown)
    }

    public func detach(sessionID: SessionID) async throws {
        routes[sessionID]?.continuation.finish()
        routes[sessionID] = nil
        _ = try await okResult(.detach(SessionTarget(sessionID: sessionID)))
    }

    /// Anexa a sessão. O `updates` devolvido começa com `.snapshot` (o mesmo valor de `snapshot`).
    public func attach(sessionID: SessionID, cols: UInt16, rows: UInt16, mode: AttachMode = .snapshot) async throws -> PTYAttachment {
        let (stream, continuation) = AsyncStream<PTYUpdate>.makeStream(bufferingPolicy: .unbounded)
        routes[sessionID]?.continuation.finish()
        routes[sessionID] = Route(continuation: continuation, cols: cols, rows: rows)
        let reply: DaemonReply
        do {
            reply = try await request(.attach(AttachRequest(sessionID: sessionID, cols: cols, rows: rows, mode: mode)))
        } catch {
            routes[sessionID] = nil
            continuation.finish()
            throw error
        }
        guard case .attachSnapshot(_, let snapshot) = reply else { throw PTYClientError.unexpectedReply }
        return PTYAttachment(snapshot: snapshot, updates: stream, backlog: routes[sessionID]?.backlog ?? PTYBacklogGauge())
    }

    /// Pede um `snapshot` novo (o consumidor recebe `.snapshot` e refaz o emulador).
    public func resync(sessionID: SessionID) async throws {
        guard let route = routes[sessionID] else { return }
        routes[sessionID]?.awaitingSnapshot = true
        _ = try await request(.attach(AttachRequest(sessionID: sessionID, cols: route.cols, rows: route.rows, mode: .snapshot)))
    }

    // MARK: Input

    public func sendInput(sessionID: SessionID, origin: InputOrigin = .key, bytes: Data) throws {
        guard let sender else { throw PTYClientError.notConnected }
        var offset = 0
        while offset < bytes.count {
            let take = min(FrameCodec.maxInputBytes, bytes.count - offset)
            sender.yield(.input(InputFrame(sessionID: sessionID, origin: origin, bytes: bytes.subdata(in: offset ..< offset + take))))
            offset += take
        }
    }

    // MARK: Demultiplexação

    private func handle(_ frame: Frame) {
        switch frame {
        case .control(.reply(let reply)):
            handleReply(reply)
        case .control(.event(let event)):
            handleEvent(event)
        case .control(.request):
            break
        case .output(let output):
            handleOutput(output)
        case .input:
            break
        }
    }

    private func handleReply(_ reply: DaemonReply) {
        guard let id = reply.id else { return }
        if case .attachSnapshot(_, let snapshot) = reply, var route = routes[snapshot.sessionID] {
            // Os frames de replay começam em `startSeq` e continuam, sem buraco, no ao vivo.
            route.validator = OutputSequenceValidator(expectedSeq: snapshot.startSeq)
            route.awaitingSnapshot = false
            route.replayEndSeq = snapshot.endSeq
            routes[snapshot.sessionID] = route
            route.continuation.yield(.snapshot(snapshot))
        }
        pending.removeValue(forKey: id)?.resume(returning: reply)
    }

    private func handleEvent(_ event: DaemonEvent) {
        eventsContinuation.yield(event)
        guard routes[event.sessionID] != nil else { return }
        switch event.payload {
        case .resyncRequired:
            routes[event.sessionID]?.awaitingSnapshot = true
            routes[event.sessionID]?.continuation.yield(.event(.resyncRequired))
            let id = event.sessionID
            Task { [weak self] in try? await self?.resync(sessionID: id) }
        case .sessionGone:
            routes[event.sessionID]?.continuation.yield(.event(.sessionGone))
            routes[event.sessionID]?.continuation.finish()
            routes[event.sessionID] = nil
        default:
            routes[event.sessionID]?.continuation.yield(.event(event.payload))
        }
    }

    private func handleOutput(_ output: OutputFrame) {
        guard var route = routes[output.sessionID], !route.awaitingSnapshot else { return }
        switch route.validator.accept(output) {
        case .continuous:
            let pending = route.backlog.added(output.bytes.count)
            if pending > configuration.maxBacklogBytes, output.seq >= route.replayEndSeq {
                // O consumidor não acompanha: abandona o que falta (ele recebe o `.snapshot` depois dos quadros já
                // enfileirados, que consome rápido por não renderizar) e refaz do snapshot.
                route.awaitingSnapshot = true
                routes[output.sessionID] = route
                route.continuation.yield(.event(.resyncRequired))
                let id = output.sessionID
                Task { [weak self] in try? await self?.resync(sessionID: id) }
                return
            }
            routes[output.sessionID] = route
            route.continuation.yield(.output(output))
        case .gap, .overlap:
            // Buraco ou sobreposição: o stream não é confiável; refaz com snapshot.
            route.awaitingSnapshot = true
            routes[output.sessionID] = route
            let id = output.sessionID
            Task { [weak self] in try? await self?.resync(sessionID: id) }
        }
    }
}
