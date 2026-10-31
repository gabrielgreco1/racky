import RackyPlatform
import RackyProtocol
import Darwin
import Foundation

/// De onde vem o socket de escuta (06 §1.2).
enum DaemonListenSource: Sendable, Equatable {
    /// Modo degradado e testes: o próprio daemon faz `bind` em `paths.socketPath`.
    case bind
    /// LaunchAgent: `launch_activate_socket(name)`; o daemon nunca faz `unlink`/`bind`.
    case launchd(name: String)
    /// Descritor já em escuta herdado (simula `launch_activate_socket` nos testes de integração).
    case inheritedFD(Int32)
}

struct DaemonConfiguration: Sendable {
    var paths: DaemonPaths
    var listen: DaemonListenSource = .bind
    var build: String
    /// Sai depois de tanto tempo sem sessões vivas e sem clientes (06 §1.2). `nil` desliga.
    var idleExit: Duration?
    /// Autenticação do peer na aceitação da conexão (06 §1.4, T1-07).
    var peerAuthenticator: PeerAuthenticator
}

/// Servidor do daemon: registro de sessões, atendimento das operações de 06 §1.3 e ciclo de vida.
actor DaemonServer {
    private let configuration: DaemonConfiguration
    private let hub = EventHub()
    private let log = LogFacade(.ptyd, category: "server")
    private let authLog = LogFacade(.ptyd, category: "auth")
    private let startedAt = Date()
    private let startedInstant = ContinuousClock.now
    private var sessions: [SessionID: PTYSession] = [:]
    private var clientCount = 0
    private var drainWhenIdle = false
    private var emptySince: ContinuousClock.Instant?

    init(configuration: DaemonConfiguration) {
        self.configuration = configuration
    }

    var daemonInfo: DaemonInfo {
        DaemonInfo(build: configuration.build, pid: getpid(), startedAt: startedAt, binary: CommandLine.arguments.first ?? "rackyd")
    }

    // MARK: Execução

    func run() async throws {
        try configuration.paths.prepare(includeSocketDirectory: configuration.listen == .bind)
        let sessionsDirectory = configuration.paths.sessionsDirectory
        _ = await BlockingIOBridge.run { ColdLog.sweep(sessionsDirectory: sessionsDirectory, keeping: []) }
        let listener: UDSListener
        switch configuration.listen {
        case .bind:
            listener = try await UDSListener.listen(path: configuration.paths.socketPath)
            log.publicInfo("rackyd listening")
        case .launchd(let name):
            let descriptors = try LaunchdSocketActivation.activate(name: name)
            for extra in descriptors.dropFirst() { Darwin.close(extra) }
            listener = try UDSListener.adopt(fileDescriptor: descriptors[0])
            log.publicInfo("rackyd listening on launchd socket")
        case .inheritedFD(let descriptor):
            listener = try UDSListener.adopt(fileDescriptor: descriptor)
            log.publicInfo("rackyd listening on inherited socket")
        }
        switch configuration.peerAuthenticator.policy {
        case .signed: authLog.publicInfo("peer auth: signed (uid + code requirement)")
        case .adhocDevelopment: authLog.publicInfo("peer auth: ad-hoc development mode (uid only)")
        case .denyAll(let reason):
            authLog.publicError("peer auth: DENY ALL, every connection will be refused")
            authLog.error(reason)
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.idleMonitor(listener: listener) }
            for await connection in listener.connections {
                group.addTask { await self.serve(connection) }
            }
            group.cancelAll()
        }
    }

    private func idleMonitor(listener: UDSListener) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            var live = 0
            for session in sessions.values where await session.isRunning { live += 1 }
            let now = ContinuousClock.now
            if drainWhenIdle, live == 0 {
                listener.close()
                Darwin.exit(0)
            }
            if live == 0, clientCount == 0 {
                if emptySince == nil { emptySince = now }
                if let idleExit = configuration.idleExit, let since = emptySince, now - since >= idleExit {
                    listener.close()
                    Darwin.exit(0)
                }
            } else {
                emptySince = nil
            }
        }
    }

    // MARK: Conexões

    private func serve(_ connection: UDSConnection) async {
        let framed = FramedConnection(connection)
        guard await authorize(connection, framed) else { return }
        let handshake = ServerHandshake(daemon: daemonInfo)
        let negotiated: NegotiatedSession
        do {
            negotiated = try await framed.acceptHandshake(handshake, sessions: sessions.count)
        } catch {
            // Cliente caiu antes do hello (ou handshake inválido): fecha o fd.
            await framed.close()
            return
        }
        let outbox = ClientOutbox()
        hub.register(outbox)
        clientCount += 1
        let writer = Task { await Self.runWriter(outbox: outbox, framed: framed) }
        defer {
            clientCount -= 1
            hub.unregister(outbox)
            outbox.close()
            writer.cancel()
            for session in sessions.values { session.detach(outbox) }
            Task { await framed.close() }
        }
        while true {
            let frame: Frame?
            do {
                frame = try await framed.receive()
            } catch let error as FrameError {
                outbox.enqueueControl(.reply(.error(id: nil, error.daemonError)))
                try? await Task.sleep(for: .milliseconds(100))
                return
            } catch {
                return
            }
            guard let frame else { return }
            switch frame {
            case .control(.request(let request)):
                if let reply = await handle(request, outbox: outbox, negotiated: negotiated) { outbox.enqueueControl(.reply(reply)) }
            case .control:
                outbox.enqueueControl(.reply(.error(id: nil, DaemonError(.badRequest, "unexpected control message"))))
            case .input(let input):
                sessions[input.sessionID]?.writeInput([UInt8](input.bytes), origin: input.origin)
            case .output:
                outbox.enqueueControl(.reply(.error(id: nil, DaemonError(.badRequest, "output frames are daemon-to-client only"))))
            }
        }
    }

    /// Autentica o peer antes de ler o `hello`. Recusa: `error{peerRejected}` tipado, log em `auth` e fecha.
    private func authorize(_ connection: UDSConnection, _ framed: FramedConnection) async -> Bool {
        let authenticator = configuration.peerAuthenticator
        let credentials = connection.peer
        let decision = await BlockingIOBridge.run { authenticator.authenticate(credentials) }
        switch decision {
        case .accepted:
            return true
        case .rejected(let rejection):
            authLog.publicError("peer rejected")
            authLog.error("\(rejection.kind.rawValue): \(rejection.detail) (pid \(credentials?.pid ?? -1))")
            let error = DaemonError(.peerRejected, "peer not authorized: \(rejection.kind.rawValue)")
            try? await framed.send(.control(.reply(.error(id: nil, error))))
            try? await Task.sleep(for: .milliseconds(50))
            await framed.close()
            return false
        }
    }

    /// Único escritor do socket de um cliente: replays com prioridade, depois a fila FIFO.
    private static func runWriter(outbox: ClientOutbox, framed: FramedConnection) async {
        for await _ in outbox.wakeStream {
            while let work = outbox.next() {
                do {
                    switch work {
                    case .frame(let frame):
                        try await framed.send(frame)
                    case .replay(let job):
                        try await framed.send(.control(.reply(job.reply)))
                        var offset = 0
                        while offset < job.bytes.count {
                            if outbox.isClosed { return }
                            let take = min(PTYSession.frameBytes, job.bytes.count - offset)
                            let frame = OutputFrame(sessionID: job.sessionID, seq: job.startSeq + UInt64(offset), bytes: Data(job.bytes[offset ..< offset + take]))
                            try await framed.send(.output(frame))
                            offset += take
                        }
                    }
                } catch {
                    await framed.close()
                    return
                }
            }
        }
    }

    // MARK: Operações

    private func handle(_ request: DaemonRequest, outbox: ClientOutbox, negotiated: NegotiatedSession) async -> DaemonReply? {
        do {
            try negotiated.validate(request.command)
            return try await perform(request, outbox: outbox)
        } catch {
            return .error(id: request.id, error)
        }
    }

    private func session(_ id: SessionID) throws(DaemonError) -> PTYSession {
        guard let session = sessions[id] else { throw DaemonError(.unknownSession, "unknown session \(id)") }
        return session
    }

    private func perform(_ request: DaemonRequest, outbox: ClientOutbox) async throws(DaemonError) -> DaemonReply? {
        let id = request.id
        switch request.command {
        case .hello:
            throw DaemonError(.badRequest, "hello already processed")
        case .create(let create):
            if let existing = sessions[create.sessionID] {
                return .ok(id: id, .created(CreateResult(session: await existing.summary(), spawned: false)))
            }
            let created = try await spawn(create)
            return .ok(id: id, .created(CreateResult(session: await created.summary(), spawned: true)))
        case .list:
            var summaries: [SessionSummary] = []
            for session in sessions.values { summaries.append(await session.summary()) }
            summaries.sort { ($0.startedAt, $0.sessionID.description) < ($1.startedAt, $1.sessionID.description) }
            return .ok(id: id, .list(ListResult(sessions: summaries)))
        case .attach(let attach):
            let target = try session(attach.sessionID)
            if case .failure(let error) = await target.attach(outbox, request: attach, requestID: id) { throw error }
            // A resposta `attachSnapshot` vai no `ReplayJob`; não há `ok` separado.
            return nil
        case .detach(let target):
            let found = try session(target.sessionID)
            found.detach(outbox)
            return .ok(id: id, .empty)
        case .resize(let resize):
            let target = try session(resize.sessionID)
            if case .failure(let error) = await target.resize(cols: resize.cols, rows: resize.rows) { throw error }
            return .ok(id: id, .empty)
        case .signal(let signal):
            let target = try session(signal.sessionID)
            if case .failure(let error) = await target.signal(signal.signal, target: signal.target) { throw error }
            return .ok(id: id, .empty)
        case .kill(let kill):
            let target = try session(kill.sessionID)
            if case .failure(let error) = await target.kill(mode: kill.mode) { throw error }
            return .ok(id: id, .empty)
        case .subscribe(let subscribe):
            hub.subscribe(outbox, request: subscribe)
            return .ok(id: id, .empty)
        case .textSnapshot(let snapshot):
            let target = try session(snapshot.sessionID)
            let text = await target.textSnapshot(lines: snapshot.lines)
            return .ok(id: id, .textSnapshot(TextSnapshotResult(text: text, lines: text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count)))
        case .forget(let target):
            try await forget(target.sessionID)
            return .ok(id: id, .empty)
        case .drainWhenIdle:
            drainWhenIdle = true
            return .ok(id: id, .empty)
        case .shutdown:
            log.publicInfo("shutdown requested by the protocol")
            Task.detached {  // DETACHED: sai do processo depois de responder; não pertence a nenhuma conexão
                try? await Task.sleep(for: .milliseconds(150))
                Darwin.exit(0)
            }
            return .ok(id: id, .empty)
        case .ping:
            var active = 0
            for session in sessions.values where await session.isRunning { active += 1 }
            let uptime = ContinuousClock.now - startedInstant
            let millis = UInt64(max(0, uptime.components.seconds)) * 1000 + UInt64(max(0, uptime.components.attoseconds / 1_000_000_000_000_000))
            return .ok(id: id, .pong(PongInfo(at: Date(), activeSessions: active, uptimeMillis: millis)))
        }
    }

    private func spawn(_ create: CreateRequest) async throws(DaemonError) -> PTYSession {
        var environment = create.env
        environment["TERM"] = create.term
        let argv = create.argv, cwd = create.cwd, cols = create.cols, rows = create.rows
        let env = environment
        let spawned: Result<SpawnedPTY, DaemonError> = await BlockingIOBridge.run {
            do throws(DaemonError) {
                return .success(try PTYSpawner.spawn(argv: argv, cwd: cwd, env: env, cols: cols, rows: rows))
            } catch {
                return .failure(error)
            }
        }
        let pty = try spawned.get()
        var coldLog: ColdLog?
        if create.coldLog {
            let meta = ColdLogMeta(
                sessionID: create.sessionID.description, terminalID: create.owner.terminalID, runID: create.owner.runID, argv: create.argv,
                cwd: create.cwd, envKeys: create.env.keys.sorted(), pid: pty.pid, startedAt: Date(), exit: nil)
            coldLog = try? ColdLog(directory: configuration.paths.sessionsDirectory.appendingPathComponent(create.sessionID.description, isDirectory: true), meta: meta)
        }
        let session = PTYSession(request: create, spawned: pty, coldLog: coldLog, hub: hub)
        sessions[create.sessionID] = session
        session.start()
        return session
    }

    private func forget(_ id: SessionID) async throws(DaemonError) {
        guard let session = sessions[id] else {
            // Sessão de um daemon anterior: só o cold log em disco.
            let directory = configuration.paths.sessionsDirectory.appendingPathComponent(id.description, isDirectory: true)
            guard FileManager.default.fileExists(atPath: directory.path) else { throw DaemonError(.unknownSession, "unknown session \(id)") }
            try? FileManager.default.removeItem(at: directory)
            return
        }
        guard await !session.isRunning else { throw DaemonError(.badRequest, "forget: session is still running") }
        sessions[id] = nil
        await session.announceGone()
        _ = await session.forget()
    }
}
