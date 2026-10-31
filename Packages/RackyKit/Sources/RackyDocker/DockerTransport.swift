import RackyPlatform
import Foundation

/// Executa `body` com prazo. Estourar o prazo cancela a operação (o que fecha o socket) e lança `.timeout`.
func withDeadline<T: Sendable>(
    _ timeout: Duration?, operation: String, _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    guard let timeout else { return try await body() }
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw DockerError.timeout(operation: operation)
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw DockerError.cancelled }
        return first
    }
}

/// Lê uma resposta HTTP/1.1 de uma conexão: cabeça, depois corpo decodificado sob demanda.
/// Um único consumidor por vez (a contrapressão vem de `UDSConnection.receive`, que só lê quando pedido).
actor ResponseReader {
    nonisolated let head: HTTPResponseHead
    private let connection: UDSConnection
    private var pending: Data
    private var chunked: ChunkedDecoder?
    private var remaining: Int?
    private var finished = false

    private init(connection: UDSConnection, head: HTTPResponseHead, leftover: Data, hasBody: Bool) {
        self.connection = connection
        self.head = head
        pending = leftover
        if !hasBody {
            finished = true
        } else if head.isChunked {
            chunked = ChunkedDecoder()
        } else if let length = head.contentLength {
            remaining = length
            finished = length == 0
        }
    }

    /// Lê a cabeça. `hasBody` é falso em 1xx/204/304.
    static func open(_ connection: UDSConnection) async throws -> ResponseReader {
        var parser = HTTPHeadParser()
        while true {
            guard let data = try await connection.receive() else {
                if Task.isCancelled { throw DockerError.cancelled }
                throw DockerError.transport("conexão fechada antes da resposta")
            }
            if let (head, rest) = try parser.feed(data) {
                let noBody = head.status == 204 || head.status == 304 || (100 ..< 200).contains(head.status)
                return ResponseReader(connection: connection, head: head, leftover: rest, hasBody: !noBody)
            }
        }
    }

    /// Bytes restantes depois da cabeça de um upgrade (101) ou de um stream sem enquadramento.
    func takeLeftover() -> Data {
        defer { pending = Data() }
        return pending
    }

    func nextBody() async throws -> Data? {
        while true {
            if finished && pending.isEmpty { return nil }
            if !pending.isEmpty {
                let input = pending
                pending = Data()
                if chunked != nil {
                    let out = try chunked!.feed(input)
                    if chunked!.isFinished { finished = true }
                    if !out.isEmpty { return out }
                    continue
                } else if let left = remaining {
                    let take = min(left, input.count)
                    remaining = left - take
                    if remaining == 0 { finished = true }
                    return Data(input.prefix(take))
                } else {
                    return input
                }
            }
            guard let data = try await connection.receive() else {
                if Task.isCancelled { throw DockerError.cancelled }
                finished = true
                if let chunked, !chunked.isFinished { throw DockerError.transport("corpo chunked truncado") }
                if let remaining, remaining > 0 { throw DockerError.transport("corpo truncado (\(remaining) bytes faltando)") }
                return nil
            }
            pending = data
        }
    }

    func readAll(limit: Int = 64 << 20) async throws -> Data {
        var body = Data()
        while let chunk = try await nextBody() {
            body.append(chunk)
            if body.count > limit { throw DockerError.malformedResponse("corpo acima de \(limit) bytes") }
        }
        return body
    }

    nonisolated func close() { connection.close() }
}

struct DockerResponse: Sendable {
    var status: Int
    var headers: [String: String]
    var body: Data
}

/// Conexão sequestrada (`Upgrade: tcp`) de um exec/attach: bytes crus nos dois sentidos.
public final class HijackedConnection: Sendable {
    private let connection: UDSConnection
    private let leftover: LeftoverBox

    // Guarda os bytes que vieram junto da cabeça HTTP; entregues no primeiro `receive`.
    actor LeftoverBox {
        private var data: Data?
        init(_ data: Data) { self.data = data.isEmpty ? nil : data }
        func take() -> Data? {
            defer { data = nil }
            return data
        }
    }

    init(connection: UDSConnection, leftover: Data) {
        self.connection = connection
        self.leftover = LeftoverBox(leftover)
    }

    public func receive() async throws -> Data? {
        if let first = await leftover.take() { return first }
        return try await connection.receive()
    }

    public func send(_ data: Data) async throws { try await connection.send(data) }
    /// Half-close da escrita: o processo vê EOF no stdin.
    public func finishWriting() { connection.finishWriting() }
    public func close() { connection.close() }
}

/// Transporte HTTP/1.1 sobre o socket Unix do Docker. Uma conexão por requisição (`Connection: close`),
/// toda espera é async (DispatchSource), nada bloqueia o pool cooperativo (08 AR-404).
struct DockerTransport: Sendable {
    let socketPath: String
    let apiVersion: String

    func connect() async throws -> UDSConnection {
        do {
            return try await UDSClient.connect(path: socketPath)
        } catch let error as UDSError {
            throw DockerError.runtimeUnavailable("não foi possível conectar em \(socketPath): \(error)")
        }
    }

    private func versioned(_ request: HTTPRequest) -> HTTPRequest {
        var copy = request
        if !copy.path.hasPrefix("/_ping") { copy.path = "/\(apiVersion)\(copy.path)" }
        return copy
    }

    private func write(_ request: HTTPRequest, on connection: UDSConnection, upgrade: Bool) async throws {
        let body = request.body
        do {
            try await connection.send(request.head(bodyLength: body.map(\.count) ?? (request.method == "POST" || request.method == "PUT" ? 0 : nil), upgrade: upgrade))
            if let body, !body.isEmpty { try await connection.send(body) }
        } catch let error as UDSError {
            throw DockerError.transport("escrita falhou: \(error)")
        }
    }

    /// Requisição completa com corpo em memória. `acceptable` lista status de sucesso adicionais além de 2xx.
    func send(_ request: HTTPRequest, timeout: Duration?, operation: String, accept: Set<Int> = []) async throws -> DockerResponse {
        let request = versioned(request)
        return try await withDeadline(timeout, operation: operation) {
            let connection = try await connect()
            defer { connection.close() }
            try await write(request, on: connection, upgrade: false)
            let reader = try await ResponseReader.open(connection)
            let body = try await reader.readAll()
            let head = reader.head
            guard (200 ..< 300).contains(head.status) || accept.contains(head.status) else {
                throw DockerError.from(status: head.status, body: body, context: operation)
            }
            return DockerResponse(status: head.status, headers: head.headers, body: body)
        }
    }

    /// Resposta em streaming (eventos, logs, progresso). O corpo decodificado chega em `AsyncThrowingStream<Data>`;
    /// terminar ou cancelar o consumo fecha o socket. O prazo vale só até a cabeça da resposta.
    func stream(_ request: HTTPRequest, headTimeout: Duration?, operation: String) async throws -> (head: HTTPResponseHead, body: AsyncThrowingStream<Data, any Error>) {
        let request = versioned(request)
        let (reader, connection) = try await withDeadline(headTimeout, operation: operation) { () -> (ResponseReader, UDSConnection) in
            let connection = try await connect()
            do {
                try await write(request, on: connection, upgrade: false)
                let reader = try await ResponseReader.open(connection)
                return (reader, connection)
            } catch {
                connection.close()
                throw error
            }
        }
        let head = reader.head
        guard (200 ..< 300).contains(head.status) else {
            defer { connection.close() }
            let body = (try? await reader.readAll(limit: 1 << 20)) ?? Data()
            throw DockerError.from(status: head.status, body: body, context: operation)
        }
        let body = AsyncThrowingStream<Data, any Error> { continuation in
            let task = Task {
                do {
                    while let chunk = try await reader.nextBody() { continuation.yield(chunk) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                connection.close()
            }
            continuation.onTermination = { _ in
                task.cancel()
                connection.close()
            }
        }
        return (head, body)
    }

    /// `POST` com `Upgrade: tcp` (exec/attach). Aceita `101` e `200` (alguns runtimes respondem 200 com
    /// `application/vnd.docker.raw-stream`/`multiplexed-stream` e mantêm a conexão aberta).
    func hijack(_ request: HTTPRequest, timeout: Duration?, operation: String) async throws -> (head: HTTPResponseHead, connection: HijackedConnection) {
        let request = versioned(request)
        return try await withDeadline(timeout, operation: operation) {
            let connection = try await connect()
            do {
                try await write(request, on: connection, upgrade: true)
                let reader = try await ResponseReader.open(connection)
                let head = reader.head
                guard head.status == 101 || head.status == 200 else {
                    let body = (try? await reader.readAll(limit: 1 << 20)) ?? Data()
                    connection.close()
                    throw DockerError.from(status: head.status, body: body, context: operation)
                }
                let leftover = await reader.takeLeftover()
                return (head, HijackedConnection(connection: connection, leftover: leftover))
            } catch {
                connection.close()
                throw error
            }
        }
    }
}
