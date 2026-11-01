import Foundation

// MARK: - Handshake

/// Quem conecta. Só `app` é aceito (o `ctl` nunca fala com o daemon, 08 AR-503): outro valor falha na decodificação.
public enum ClientKind: String, Sendable, Codable, Hashable {
    case app
}

public struct ClientInfo: Sendable, Codable, Hashable {
    public var kind: ClientKind
    public var build: String
    public init(kind: ClientKind = .app, build: String) {
        self.kind = kind
        self.build = build
    }
}

public struct HelloRequest: Sendable, Codable, Hashable {
    public var protocolVersion: ProtocolVersion
    public var client: ClientInfo
    public var capabilities: [Capability]

    public init(protocolVersion: ProtocolVersion = .current, client: ClientInfo, capabilities: [Capability]) {
        self.protocolVersion = protocolVersion
        self.client = client
        self.capabilities = capabilities
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case client, capabilities
    }
}

// MARK: - Operações

/// Dono lógico da sessão no app (correlação; opaco para o daemon).
public struct SessionOwner: Sendable, Codable, Hashable {
    public var terminalID: String
    public var runID: String
    public init(terminalID: String, runID: String) {
        self.terminalID = terminalID
        self.runID = runID
    }
}

public struct CreateRequest: Sendable, Codable, Hashable {
    /// Faixa aceita para `ringBytes` (a UI limita a 1–32 MiB; o piso menor facilita testes).
    public static let ringBytesRange: ClosedRange<Int> = 4096 ... (32 << 20)

    public var sessionID: SessionID
    public var argv: [String]
    public var cwd: String
    public var env: [String: String]
    public var cols: UInt16
    public var rows: UInt16
    public var term: String
    public var ringBytes: Int
    public var coldLog: Bool
    public var label: String?
    public var owner: SessionOwner

    public init(
        sessionID: SessionID, argv: [String], cwd: String, env: [String: String], cols: UInt16, rows: UInt16,
        term: String = "xterm-256color", ringBytes: Int = 4 << 20, coldLog: Bool = true, label: String? = nil,
        owner: SessionOwner
    ) {
        self.sessionID = sessionID
        self.argv = argv
        self.cwd = cwd
        self.env = env
        self.cols = cols
        self.rows = rows
        self.term = term
        self.ringBytes = ringBytes
        self.coldLog = coldLog
        self.label = label
        self.owner = owner
    }
}

public enum AttachMode: Sendable, Hashable {
    case snapshot
    case sinceSeq(UInt64)
}

public struct AttachRequest: Sendable, Codable, Hashable {
    public var sessionID: SessionID
    public var cols: UInt16
    public var rows: UInt16
    public var mode: AttachMode

    public init(sessionID: SessionID, cols: UInt16, rows: UInt16, mode: AttachMode) {
        self.sessionID = sessionID
        self.cols = cols
        self.rows = rows
        self.mode = mode
    }

    private enum CodingKeys: String, CodingKey { case sessionID, cols, rows, mode, sinceSeq }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try c.decode(SessionID.self, forKey: .sessionID)
        cols = try c.decode(UInt16.self, forKey: .cols)
        rows = try c.decode(UInt16.self, forKey: .rows)
        switch try c.decode(String.self, forKey: .mode) {
        case "snapshot":
            mode = .snapshot
        case "sinceSeq":
            guard let since = try c.decodeIfPresent(UInt64.self, forKey: .sinceSeq) else {
                throw DecodingError.keyNotFound(
                    CodingKeys.sinceSeq, .init(codingPath: decoder.codingPath, debugDescription: "mode sinceSeq requires sinceSeq"))
            }
            mode = .sinceSeq(since)
        default:
            throw DecodingError.dataCorruptedError(forKey: .mode, in: c, debugDescription: "unknown attach mode")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionID, forKey: .sessionID)
        try c.encode(cols, forKey: .cols)
        try c.encode(rows, forKey: .rows)
        switch mode {
        case .snapshot:
            try c.encode("snapshot", forKey: .mode)
        case .sinceSeq(let since):
            try c.encode("sinceSeq", forKey: .mode)
            try c.encode(since, forKey: .sinceSeq)
        }
    }
}

/// Corpo de `detach` e `forget`.
public struct SessionTarget: Sendable, Codable, Hashable {
    public var sessionID: SessionID
    public init(sessionID: SessionID) { self.sessionID = sessionID }
}

public struct ResizeRequest: Sendable, Codable, Hashable {
    public var sessionID: SessionID
    public var cols: UInt16
    public var rows: UInt16
    public init(sessionID: SessionID, cols: UInt16, rows: UInt16) {
        self.sessionID = sessionID
        self.cols = cols
        self.rows = rows
    }
}

public enum SignalTarget: String, Sendable, Codable, Hashable {
    case group
    case foreground
}

public struct SignalRequest: Sendable, Codable, Hashable {
    public var sessionID: SessionID
    /// Número do sinal POSIX (1...31).
    public var signal: Int32
    public var target: SignalTarget
    public init(sessionID: SessionID, signal: Int32, target: SignalTarget) {
        self.sessionID = sessionID
        self.signal = signal
        self.target = target
    }
}

public enum KillMode: String, Sendable, Codable, Hashable {
    /// SIGHUP + SIGTERM ao grupo; evento `stillAlive` após 5 s.
    case graceful
    /// SIGKILL, só por ação explícita do usuário.
    case force
}

public struct KillRequest: Sendable, Codable, Hashable {
    public var sessionID: SessionID
    public var mode: KillMode
    public init(sessionID: SessionID, mode: KillMode) {
        self.sessionID = sessionID
        self.mode = mode
    }
}

/// Eventos que podem ser assinados. `stillAlive`, `resyncRequired` e `sessionGone` chegam sempre.
public enum EventKind: String, Sendable, Codable, Hashable, CaseIterable {
    case exit, title, cwd, bell, prompt, altScreen, modes, idle
}

public enum SubscribeScope: Sendable, Hashable {
    case sessions([SessionID])
    case all
}

public struct SubscribeRequest: Sendable, Codable, Hashable {
    public var scope: SubscribeScope
    public var events: [EventKind]
    public init(scope: SubscribeScope, events: [EventKind]) {
        self.scope = scope
        self.events = events
    }

    private enum CodingKeys: String, CodingKey { case sessionIDs, all, events }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        events = try c.decode([EventKind].self, forKey: .events)
        let all = try c.decodeIfPresent(Bool.self, forKey: .all) ?? false
        let ids = try c.decodeIfPresent([SessionID].self, forKey: .sessionIDs)
        switch (all, ids) {
        case (true, nil): scope = .all
        case (false, let ids?): scope = .sessions(ids)
        default:
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "subscribe needs exactly one of sessionIDs or all"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(events, forKey: .events)
        switch scope {
        case .all: try c.encode(true, forKey: .all)
        case .sessions(let ids): try c.encode(ids, forKey: .sessionIDs)
        }
    }
}

public struct TextSnapshotRequest: Sendable, Codable, Hashable {
    public static let maxLines = 10_000
    public var sessionID: SessionID
    public var lines: Int
    public init(sessionID: SessionID, lines: Int) {
        self.sessionID = sessionID
        self.lines = lines
    }
}

// MARK: - Comando

/// Corpo de uma requisição de controle (`op` + campos). O input não é requisição: vai em frames `0x03`.
public enum DaemonCommand: Sendable, Hashable {
    case hello(HelloRequest)
    case create(CreateRequest)
    case list
    case attach(AttachRequest)
    case detach(SessionTarget)
    case resize(ResizeRequest)
    case signal(SignalRequest)
    case kill(KillRequest)
    case subscribe(SubscribeRequest)
    case textSnapshot(TextSnapshotRequest)
    case forget(SessionTarget)
    case drainWhenIdle
    /// F30: encerra o daemon (e as sessões) por comando explícito ("Stop and Quit"); SIGTERM nunca encerra.
    case shutdown
    case ping

    /// Todos os `op` de requisição, na ordem de 06 §1.3.
    public static let allOps: [String] = [
        "hello", "create", "list", "attach", "detach", "resize", "signal", "kill", "subscribe", "textSnapshot", "forget",
        "drainWhenIdle", "shutdown", "ping",
    ]

    public var op: String {
        switch self {
        case .hello: "hello"
        case .create: "create"
        case .list: "list"
        case .attach: "attach"
        case .detach: "detach"
        case .resize: "resize"
        case .signal: "signal"
        case .kill: "kill"
        case .subscribe: "subscribe"
        case .textSnapshot: "textSnapshot"
        case .forget: "forget"
        case .drainWhenIdle: "drainWhenIdle"
        case .shutdown: "shutdown"
        case .ping: "ping"
        }
    }

    /// Capability exigida para a operação, se houver (`notCapable` quando não negociada).
    public var requiredCapability: Capability? {
        switch self {
        case .textSnapshot: .textSnapshot
        case .drainWhenIdle: .drainWhenIdle
        case .create(let request): request.coldLog ? .coldLog : nil
        default: nil
        }
    }

    /// Validação estrutural (campos fora de faixa viram `badRequest`).
    public func validate() throws(DaemonError) {
        switch self {
        case .create(let r):
            guard let first = r.argv.first, !first.isEmpty else { throw bad("create: argv must not be empty") }
            guard !r.cwd.isEmpty else { throw bad("create: cwd must not be empty") }
            guard !r.term.isEmpty else { throw bad("create: term must not be empty") }
            try Self.validateSize(cols: r.cols, rows: r.rows, op: "create")
            guard CreateRequest.ringBytesRange.contains(r.ringBytes) else { throw bad("create: ringBytes out of range") }
            for key in r.env.keys where key.isEmpty || key.contains("=") || key.contains("\0") {
                throw bad("create: invalid env key")
            }
        case .attach(let r): try Self.validateSize(cols: r.cols, rows: r.rows, op: "attach")
        case .resize(let r): try Self.validateSize(cols: r.cols, rows: r.rows, op: "resize")
        case .signal(let r):
            guard (1 ... 31).contains(r.signal) else { throw bad("signal: number out of range 1...31") }
        case .subscribe(let r):
            guard !r.events.isEmpty else { throw bad("subscribe: events must not be empty") }
        case .textSnapshot(let r):
            guard (1 ... TextSnapshotRequest.maxLines).contains(r.lines) else { throw bad("textSnapshot: lines out of range") }
        case .hello, .list, .detach, .kill, .forget, .drainWhenIdle, .shutdown, .ping:
            break
        }
    }

    private static func validateSize(cols: UInt16, rows: UInt16, op: String) throws(DaemonError) {
        guard cols > 0, rows > 0 else { throw DaemonError(.badRequest, "\(op): cols and rows must be > 0") }
    }

    private func bad(_ message: String) -> DaemonError { DaemonError(.badRequest, message) }
}

/// Requisição de controle: `{"op":…,"id":…, …campos}`.
public struct DaemonRequest: Sendable, Hashable {
    public var id: RequestID
    public var command: DaemonCommand
    public init(id: RequestID, command: DaemonCommand) {
        self.id = id
        self.command = command
    }
}

extension DaemonRequest: Codable {
    private enum CodingKeys: String, CodingKey { case op, id }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(RequestID.self, forKey: .id)
        let op = try c.decode(String.self, forKey: .op)
        switch op {
        case "hello": command = .hello(try HelloRequest(from: decoder))
        case "create": command = .create(try CreateRequest(from: decoder))
        case "list": command = .list
        case "attach": command = .attach(try AttachRequest(from: decoder))
        case "detach": command = .detach(try SessionTarget(from: decoder))
        case "resize": command = .resize(try ResizeRequest(from: decoder))
        case "signal": command = .signal(try SignalRequest(from: decoder))
        case "kill": command = .kill(try KillRequest(from: decoder))
        case "subscribe": command = .subscribe(try SubscribeRequest(from: decoder))
        case "textSnapshot": command = .textSnapshot(try TextSnapshotRequest(from: decoder))
        case "forget": command = .forget(try SessionTarget(from: decoder))
        case "drainWhenIdle": command = .drainWhenIdle
        case "shutdown": command = .shutdown
        case "ping": command = .ping
        default:
            throw DecodingError.dataCorruptedError(forKey: .op, in: c, debugDescription: "unknown op '\(op)'")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(command.op, forKey: .op)
        try c.encode(id, forKey: .id)
        switch command {
        case .hello(let v): try v.encode(to: encoder)
        case .create(let v): try v.encode(to: encoder)
        case .attach(let v): try v.encode(to: encoder)
        case .detach(let v): try v.encode(to: encoder)
        case .resize(let v): try v.encode(to: encoder)
        case .signal(let v): try v.encode(to: encoder)
        case .kill(let v): try v.encode(to: encoder)
        case .subscribe(let v): try v.encode(to: encoder)
        case .textSnapshot(let v): try v.encode(to: encoder)
        case .forget(let v): try v.encode(to: encoder)
        case .list, .drainWhenIdle, .shutdown, .ping: break
        }
    }
}
