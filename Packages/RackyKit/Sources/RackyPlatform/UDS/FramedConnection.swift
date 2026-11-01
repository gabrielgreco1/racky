import RackyProtocol
import Foundation

/// `UDSConnection` + framing do protocolo do daemon. Um único consumidor de `receive()`; `send` pode ser
/// chamado de qualquer task (as escritas são enfileiradas na ordem de chamada).
public actor FramedConnection {
    private let transport: UDSConnection
    private var decoder = FrameDecoder()
    private var ready: [Frame] = []
    private var ended = false
    private var failure: FrameError?

    public init(_ transport: UDSConnection) {
        self.transport = transport
    }

    /// Próximo frame completo, ou `nil` no fim limpo do stream. Falhas de framing (`FrameError`) são
    /// permanentes: quem recebe deve responder `error{}` (`FrameError.daemonError`) e chamar `close()`.
    /// Fim do stream no meio de um frame lança `FrameError.truncatedFrame`.
    public func receive() async throws -> Frame? {
        while true {
            if !ready.isEmpty { return ready.removeFirst() }
            if let failure { throw failure }  // permanente; só depois de entregar os frames válidos anteriores
            if ended { return nil }
            guard let chunk = try await transport.receive() else {
                ended = true
                try decoder.finish()
                return nil
            }
            let result = decoder.drain(chunk)
            ready.append(contentsOf: result.frames)
            failure = result.error
        }
    }

    /// Codifica e escreve um frame; suspende enquanto o par não drena (contrapressão).
    public func send(_ frame: Frame) async throws {
        try await transport.send(FrameCodec.encode(frame))
    }

    /// Escreve bytes crus (testes de frames corrompidos).
    public func sendRaw(_ data: Data) async throws {
        try await transport.send(data)
    }

    public func close() {
        transport.close()
    }
}

// MARK: - Handshake sobre o transporte

extension FramedConnection {
    /// Lado do daemon: espera o `hello` (timeout de 2 s por padrão), responde e devolve a sessão negociada.
    /// Em rejeição, envia o `error{}` correspondente, fecha a conexão e lança `HandshakeError.rejectedByDaemon`.
    /// Em frame inválido (ex.: grande demais), responde `error{}` com o código certo, fecha e relança o `FrameError`.
    public func acceptHandshake(
        _ handshake: ServerHandshake, sessions: Int, timeout: Duration = ProtocolLimits.handshakeTimeout
    ) async throws -> NegotiatedSession {
        var handshake = handshake
        let frame: Frame?
        do {
            frame = try await receiveWithDeadline(timeout)
        } catch HandshakeError.timedOut {
            await replyAndClose(handshake.timedOut())
            throw HandshakeError.timedOut
        } catch let error as FrameError {
            await replyAndClose(.error(id: nil, error.daemonError))
            throw error
        }
        guard let frame else { throw HandshakeError.connectionClosed }
        guard case .control(let message) = frame else {
            let reply = DaemonReply.error(id: nil, DaemonError(.badRequest, "first frame must be control hello"))
            await replyAndClose(reply)
            throw HandshakeError.unexpectedReply
        }
        switch handshake.receive(message, sessions: sessions) {
        case .established(let reply, let session):
            try await send(.control(.reply(reply)))
            return session
        case .rejected(let reply):
            await replyAndClose(reply)
            if case .error(_, let error) = reply { throw HandshakeError.rejectedByDaemon(error) }
            throw HandshakeError.unexpectedReply
        }
    }

    /// Lado do app: envia `hello`, espera `helloAck` e devolve o resultado negociado.
    public func performHandshake(
        _ handshake: ClientHandshake, id: RequestID = 1, timeout: Duration = ProtocolLimits.handshakeTimeout
    ) async throws -> ClientHandshake.Result {
        var handshake = handshake
        try await send(.control(.request(handshake.makeHello(id: id))))
        guard let frame = try await receiveWithDeadline(timeout) else { throw HandshakeError.connectionClosed }
        guard case .control(let message) = frame else { throw HandshakeError.unexpectedReply }
        return try handshake.receive(message)
    }

    private func replyAndClose(_ reply: DaemonReply) async {
        try? await send(.control(.reply(reply)))
        close()
    }

    /// `receive()` com prazo. No estouro a conexão é fechada (cancelar `receive()` fecha o transporte).
    private func receiveWithDeadline(_ timeout: Duration) async throws -> Frame? {
        try await withThrowingTaskGroup(of: Frame?.self) { group in
            group.addTask { try await self.receive() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw HandshakeError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { return nil }
            return first
        }
    }
}
