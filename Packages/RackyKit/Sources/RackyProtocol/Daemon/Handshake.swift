import Foundation

/// Resultado do handshake: versão e capabilities valendo para a conexão.
public struct NegotiatedSession: Sendable, Hashable {
    /// Major do par e `min(minor local, minor remoto)`.
    public let version: ProtocolVersion
    /// Interseção das capabilities dos dois lados.
    public let capabilities: [Capability]

    public init(version: ProtocolVersion, capabilities: [Capability]) {
        self.version = version
        self.capabilities = capabilities
    }

    public func supports(_ capability: Capability) -> Bool { capabilities.contains(capability) }

    /// Falha com `notCapable` se a operação exige capability não negociada; depois valida os campos.
    public func validate(_ command: DaemonCommand) throws(DaemonError) {
        if let required = command.requiredCapability, !supports(required) {
            throw DaemonError(.notCapable, "capability '\(required.rawValue)' was not negotiated for op '\(command.op)'")
        }
        try command.validate()
    }
}

/// Lado do daemon do handshake. Primeiro frame obrigatório: `hello` (timeout de 2 s é do transporte).
public struct ServerHandshake: Sendable {
    public enum State: Sendable, Hashable {
        case awaitingHello
        case established(NegotiatedSession)
        case failed(DaemonError)
    }

    public enum Outcome: Sendable, Hashable {
        /// Responder com `reply` e seguir com a conexão.
        case established(reply: DaemonReply, session: NegotiatedSession)
        /// Responder com `reply` (se houver) e fechar a conexão.
        case rejected(reply: DaemonReply)
    }

    public let version: ProtocolVersion
    public let capabilities: [Capability]
    public let daemon: DaemonInfo
    public private(set) var state: State = .awaitingHello

    public init(
        version: ProtocolVersion = .current, capabilities: [Capability] = Capability.initialSet, daemon: DaemonInfo
    ) {
        self.version = version
        self.capabilities = capabilities
        self.daemon = daemon
    }

    /// Processa a primeira mensagem de controle. `sessions` entra no `helloAck`.
    public mutating func receive(_ message: ControlMessage, sessions: Int) -> Outcome {
        guard case .awaitingHello = state else {
            return fail(.badRequest, "hello already processed", id: nil)
        }
        guard case .request(let request) = message else {
            return fail(.badRequest, "first message must be hello", id: nil)
        }
        guard case .hello(let hello) = request.command else {
            return fail(.badRequest, "first message must be hello, got '\(request.command.op)'", id: request.id)
        }
        guard hello.protocolVersion.major == version.major else {
            return fail(
                .protocolMajorMismatch,
                "client protocol major \(hello.protocolVersion.major), daemon major \(version.major)", id: request.id)
        }
        let negotiated = NegotiatedSession(
            version: ProtocolVersion(major: version.major, minor: min(version.minor, hello.protocolVersion.minor)),
            capabilities: Capability.intersection(capabilities, hello.capabilities))
        state = .established(negotiated)
        let ack = HelloAck(protocolVersion: version, daemon: daemon, capabilities: negotiated.capabilities, sessions: sessions)
        return .established(reply: .helloAck(id: request.id, ack), session: negotiated)
    }

    /// Tempo esgotado sem `hello`: falha o handshake (o transporte fecha a conexão).
    public mutating func timedOut() -> DaemonReply {
        let error = DaemonError(.badRequest, "handshake timeout: no hello received")
        state = .failed(error)
        return .error(id: nil, error)
    }

    private mutating func fail(_ code: DaemonErrorCode, _ message: String, id: RequestID?) -> Outcome {
        let error = DaemonError(code, message)
        state = .failed(error)
        return .rejected(reply: .error(id: id, error))
    }
}

public enum HandshakeError: Error, Sendable, Hashable {
    /// O daemon respondeu `error{}` ao `hello`.
    case rejectedByDaemon(DaemonError)
    /// Major do daemon fora das majors aceitas por este cliente.
    case majorMismatch(local: [UInt16], remote: UInt16)
    /// Daemon abaixo do mínimo suportado (AR-904: "Restart background service to update").
    case daemonTooOld(minimum: ProtocolVersion, actual: ProtocolVersion)
    case unexpectedReply
    case idMismatch(expected: RequestID, got: RequestID?)
    case timedOut
    case connectionClosed
}

/// Lado do cliente (app) do handshake.
public struct ClientHandshake: Sendable {
    public struct Result: Sendable, Hashable {
        public var session: NegotiatedSession
        public var daemon: DaemonInfo
        public var sessions: Int
        /// `true` quando o major do daemon é o anterior (N-1): usar só o subconjunto de compatibilidade.
        public var isCompatibilityMode: Bool
    }

    public let version: ProtocolVersion
    public let capabilities: [Capability]
    public let client: ClientInfo
    /// Majors que este cliente sabe falar (N e N-1).
    public let acceptedMajors: [UInt16]
    public let minimumDaemonVersion: ProtocolVersion?
    public private(set) var pendingID: RequestID?

    /// `version` é o que o `hello` anuncia. Para falar com um daemon N-1 (socket antigo), o cliente de
    /// compatibilidade anuncia a major anterior.
    public init(
        version: ProtocolVersion = .current, capabilities: [Capability] = Capability.initialSet, client: ClientInfo,
        acceptedMajors: [UInt16]? = nil, minimumDaemonVersion: ProtocolVersion? = nil
    ) {
        self.version = version
        self.capabilities = capabilities
        self.client = client
        self.acceptedMajors = acceptedMajors ?? [version.major]
        self.minimumDaemonVersion = minimumDaemonVersion
    }

    public mutating func makeHello(id: RequestID) -> DaemonRequest {
        pendingID = id
        return DaemonRequest(
            id: id,
            command: .hello(HelloRequest(protocolVersion: version, client: client, capabilities: capabilities)))
    }

    public mutating func receive(_ message: ControlMessage) throws(HandshakeError) -> Result {
        guard let expected = pendingID else { throw .unexpectedReply }
        guard case .reply(let reply) = message else { throw .unexpectedReply }
        pendingID = nil
        switch reply {
        case .error(let id, let error):
            if let id, id != expected { throw .idMismatch(expected: expected, got: id) }
            throw .rejectedByDaemon(error)
        case .helloAck(let id, let ack):
            guard id == expected else { throw .idMismatch(expected: expected, got: id) }
            guard acceptedMajors.contains(ack.protocolVersion.major) else {
                throw .majorMismatch(local: acceptedMajors, remote: ack.protocolVersion.major)
            }
            if let minimum = minimumDaemonVersion, ack.protocolVersion.major == minimum.major,
                ack.protocolVersion < minimum
            {
                throw .daemonTooOld(minimum: minimum, actual: ack.protocolVersion)
            }
            let negotiated = NegotiatedSession(
                version: ProtocolVersion(
                    major: ack.protocolVersion.major, minor: min(version.minor, ack.protocolVersion.minor)),
                capabilities: Capability.intersection(capabilities, ack.capabilities))
            return Result(
                session: negotiated, daemon: ack.daemon, sessions: ack.sessions,
                isCompatibilityMode: ack.protocolVersion.major != ProtocolVersion.current.major)
        case .ok, .attachSnapshot:
            throw .unexpectedReply
        }
    }
}
