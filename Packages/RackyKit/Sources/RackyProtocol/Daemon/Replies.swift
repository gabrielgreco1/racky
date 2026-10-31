import Foundation

/// Origem de quem escreveu no PTY (byte `origin` do frame de input; 06 §1.3).
public enum InputOrigin: UInt8, Sendable, Hashable, CaseIterable, Codable {
    case key = 0x00
    case userPaste = 0x01
    case appPaste = 0x02
    case ctl = 0x03
    case parentToChild = 0x04
    case terminalReply = 0x05

    /// Nome estável usado em `inputBytesByOrigin`.
    public var wireName: String {
        switch self {
        case .key: "key"
        case .userPaste: "userPaste"
        case .appPaste: "appPaste"
        case .ctl: "ctl"
        case .parentToChild: "parentToChild"
        case .terminalReply: "terminalReply"
        }
    }

    public init?(wireName: String) {
        guard let match = Self.allCases.first(where: { $0.wireName == wireName }) else { return nil }
        self = match
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        let name = try c.decode(String.self)
        guard let value = InputOrigin(wireName: name) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown input origin '\(name)'")
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wireName)
    }
}

/// Bytes escritos no PTY por origem (`inputBytesByOrigin` de `list`). Serializa como objeto `{nome: contagem}`.
public struct InputByteCounts: Sendable, Hashable, Codable {
    public var counts: [InputOrigin: UInt64]
    public init(_ counts: [InputOrigin: UInt64] = [:]) { self.counts = counts }

    public subscript(origin: InputOrigin) -> UInt64 { counts[origin] ?? 0 }
    public var total: UInt64 { counts.values.reduce(0, +) }

    public mutating func add(_ byteCount: Int, origin: InputOrigin) {
        counts[origin, default: 0] += UInt64(byteCount)
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: UInt64].self)
        var result: [InputOrigin: UInt64] = [:]
        for (name, value) in raw {
            guard let origin = InputOrigin(wireName: name) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "unknown input origin '\(name)'"))
            }
            result[origin] = value
        }
        counts = result
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(Dictionary(uniqueKeysWithValues: counts.map { ($0.key.wireName, $0.value) }))
    }
}

public enum SessionState: String, Sendable, Codable, Hashable {
    case running
    case exited
}

/// Desfecho do processo (`exit{code, signal, at}`): `code` ou `signal`, nunca os dois.
public struct ExitInfo: Sendable, Codable, Hashable {
    public var code: Int32?
    public var signal: Int32?
    public var at: Date
    public init(code: Int32? = nil, signal: Int32? = nil, at: Date) {
        self.code = code
        self.signal = signal
        self.at = at
    }
}

/// Entrada de `list` (e resultado de `create`).
public struct SessionSummary: Sendable, Codable, Hashable {
    public var sessionID: SessionID
    public var pid: Int32?
    public var pgid: Int32?
    public var argv0: String
    public var cwd: String
    public var state: SessionState
    public var startedAt: Date
    public var exit: ExitInfo?
    public var lastOutputAt: Date?
    public var title: String?
    public var endSeq: UInt64
    public var inputBytesByOrigin: InputByteCounts

    public init(
        sessionID: SessionID, pid: Int32? = nil, pgid: Int32? = nil, argv0: String, cwd: String, state: SessionState,
        startedAt: Date, exit: ExitInfo? = nil, lastOutputAt: Date? = nil, title: String? = nil, endSeq: UInt64,
        inputBytesByOrigin: InputByteCounts = InputByteCounts()
    ) {
        self.sessionID = sessionID
        self.pid = pid
        self.pgid = pgid
        self.argv0 = argv0
        self.cwd = cwd
        self.state = state
        self.startedAt = startedAt
        self.exit = exit
        self.lastOutputAt = lastOutputAt
        self.title = title
        self.endSeq = endSeq
        self.inputBytesByOrigin = inputBytesByOrigin
    }
}

public struct DaemonInfo: Sendable, Codable, Hashable {
    public var build: String
    public var pid: Int32
    public var startedAt: Date
    public var binary: String
    public init(build: String, pid: Int32, startedAt: Date, binary: String) {
        self.build = build
        self.pid = pid
        self.startedAt = startedAt
        self.binary = binary
    }
}

public struct HelloAck: Sendable, Codable, Hashable {
    public var protocolVersion: ProtocolVersion
    public var daemon: DaemonInfo
    public var capabilities: [Capability]
    public var sessions: Int

    public init(protocolVersion: ProtocolVersion, daemon: DaemonInfo, capabilities: [Capability], sessions: Int) {
        self.protocolVersion = protocolVersion
        self.daemon = daemon
        self.capabilities = capabilities
        self.sessions = sessions
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case daemon, capabilities, sessions
    }
}

/// Resposta a `attach`: precede os frames `output` de `startSeq` a `endSeq` (replay) e depois o stream ao vivo.
public struct AttachSnapshot: Sendable, Codable, Hashable {
    public var sessionID: SessionID
    public var startSeq: UInt64
    public var endSeq: UInt64
    /// Escapes VT que restabelecem modos que o replay pode ter cortado (base64 no JSON).
    public var modesPreamble: Data
    /// `true` quando um `sinceSeq` ainda estava no ring e foi atendido sem cair para snapshot.
    public var resumed: Bool

    public init(sessionID: SessionID, startSeq: UInt64, endSeq: UInt64, modesPreamble: Data, resumed: Bool = false) {
        self.sessionID = sessionID
        self.startSeq = startSeq
        self.endSeq = endSeq
        self.modesPreamble = modesPreamble
        self.resumed = resumed
    }

    private enum CodingKeys: String, CodingKey { case sessionID, startSeq, endSeq, modesPreamble, resumed }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try c.decode(SessionID.self, forKey: .sessionID)
        startSeq = try c.decode(UInt64.self, forKey: .startSeq)
        endSeq = try c.decode(UInt64.self, forKey: .endSeq)
        modesPreamble = try c.decode(Data.self, forKey: .modesPreamble)
        resumed = try c.decodeIfPresent(Bool.self, forKey: .resumed) ?? false
    }
}

public struct CreateResult: Sendable, Codable, Hashable {
    public var session: SessionSummary
    /// `false` quando o `sessionID` já existia (idempotência: nenhum novo spawn).
    public var spawned: Bool
    public init(session: SessionSummary, spawned: Bool) {
        self.session = session
        self.spawned = spawned
    }
}

public struct ListResult: Sendable, Codable, Hashable {
    public var sessions: [SessionSummary]
    public init(sessions: [SessionSummary]) { self.sessions = sessions }
}

public struct PongInfo: Sendable, Codable, Hashable {
    public var at: Date
    public var activeSessions: Int
    public var uptimeMillis: UInt64
    public init(at: Date, activeSessions: Int, uptimeMillis: UInt64) {
        self.at = at
        self.activeSessions = activeSessions
        self.uptimeMillis = uptimeMillis
    }
}

public struct TextSnapshotResult: Sendable, Codable, Hashable {
    public var text: String
    public var lines: Int
    public init(text: String, lines: Int) {
        self.text = text
        self.lines = lines
    }
}

/// Carga de `{"op":"ok", …}`. O campo `result` (extensão sobre 06 §1.3) discrimina a forma; ausente = vazio.
public enum OkResult: Sendable, Hashable {
    case empty
    case created(CreateResult)
    case list(ListResult)
    case pong(PongInfo)
    case textSnapshot(TextSnapshotResult)

    public var resultName: String? {
        switch self {
        case .empty: nil
        case .created: "created"
        case .list: "list"
        case .pong: "pong"
        case .textSnapshot: "textSnapshot"
        }
    }
}

/// Resposta do daemon a uma requisição.
public enum DaemonReply: Sendable, Hashable {
    case helloAck(id: RequestID, HelloAck)
    case ok(id: RequestID, OkResult)
    case attachSnapshot(id: RequestID, AttachSnapshot)
    /// `id == nil` para erros de conexão (ex.: `frameTooLarge`, `protocolMajorMismatch` sem `hello` legível).
    case error(id: RequestID?, DaemonError)

    public static let allOps: [String] = ["helloAck", "ok", "attachSnapshot", "error"]

    public var op: String {
        switch self {
        case .helloAck: "helloAck"
        case .ok: "ok"
        case .attachSnapshot: "attachSnapshot"
        case .error: "error"
        }
    }

    public var id: RequestID? {
        switch self {
        case .helloAck(let id, _), .ok(let id, _), .attachSnapshot(let id, _): id
        case .error(let id, _): id
        }
    }
}

extension DaemonReply: Codable {
    private enum CodingKeys: String, CodingKey { case op, id, result }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let op = try c.decode(String.self, forKey: .op)
        switch op {
        case "helloAck":
            self = .helloAck(id: try c.decode(RequestID.self, forKey: .id), try HelloAck(from: decoder))
        case "attachSnapshot":
            self = .attachSnapshot(id: try c.decode(RequestID.self, forKey: .id), try AttachSnapshot(from: decoder))
        case "error":
            self = .error(id: try c.decodeIfPresent(RequestID.self, forKey: .id), try DaemonError(from: decoder))
        case "ok":
            let id = try c.decode(RequestID.self, forKey: .id)
            switch try c.decodeIfPresent(String.self, forKey: .result) {
            case nil: self = .ok(id: id, .empty)
            case "created": self = .ok(id: id, .created(try CreateResult(from: decoder)))
            case "list": self = .ok(id: id, .list(try ListResult(from: decoder)))
            case "pong": self = .ok(id: id, .pong(try PongInfo(from: decoder)))
            case "textSnapshot": self = .ok(id: id, .textSnapshot(try TextSnapshotResult(from: decoder)))
            case let other?:
                throw DecodingError.dataCorruptedError(forKey: .result, in: c, debugDescription: "unknown ok result '\(other)'")
            }
        default:
            throw DecodingError.dataCorruptedError(forKey: .op, in: c, debugDescription: "unknown reply op '\(op)'")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(op, forKey: .op)
        switch self {
        case .helloAck(let id, let ack):
            try c.encode(id, forKey: .id)
            try ack.encode(to: encoder)
        case .attachSnapshot(let id, let snapshot):
            try c.encode(id, forKey: .id)
            try snapshot.encode(to: encoder)
        case .error(let id, let error):
            try c.encodeIfPresent(id, forKey: .id)
            try error.encode(to: encoder)
        case .ok(let id, let result):
            try c.encode(id, forKey: .id)
            try c.encodeIfPresent(result.resultName, forKey: .result)
            switch result {
            case .empty: break
            case .created(let v): try v.encode(to: encoder)
            case .list(let v): try v.encode(to: encoder)
            case .pong(let v): try v.encode(to: encoder)
            case .textSnapshot(let v): try v.encode(to: encoder)
            }
        }
    }
}
