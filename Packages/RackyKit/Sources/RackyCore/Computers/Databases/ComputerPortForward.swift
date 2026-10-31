import Foundation
import Network
import Synchronization

/// Porta do Mac (`127.0.0.1:<efêmera>`) que leva a um serviço dentro do computador: cada conexão abre a admin API, pede o upgrade
/// `GET /v1/tcp?port=<n>` (com o token) e, depois do 101, copia os bytes nos dois sentidos. É assim que o Data lê o Postgres que o
/// agente subiu no computador sem a VM ter IP alcançável e sem o agente receber nada.
public final class ComputerPortForward: Sendable {
    public typealias Target = @Sendable () async throws -> AdminTunnelTarget

    private let target: Target
    private let queue = DispatchQueue(label: "app.racky.computer.forward")
    private let listener: NWListener

    public init(target: @escaping Target) throws {
        self.target = target
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    /// Começa a escutar e devolve a porta do Mac.
    public func start() async throws -> Int {
        let target = target
        let queue = queue
        listener.newConnectionHandler = { connection in
            Task { await Self.serve(connection, target: target, queue: queue) }
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, any Error>) in
            let resumed = OnceFlag()
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    resumed.run {
                        if let port = listener.port?.rawValue { continuation.resume(returning: Int(port)) } else {
                            continuation.resume(throwing: ToolError(.notSupported, "the local forward has no port"))
                        }
                    }
                case .failed(let error): resumed.run { continuation.resume(throwing: error) }
                case .cancelled: resumed.run { continuation.resume(throwing: ToolError(.notSupported, "the local forward was cancelled")) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() { listener.cancel() }

    // MARK: Uma conexão

    private static func serve(_ client: NWConnection, target: Target, queue: DispatchQueue) async {
        client.start(queue: queue)
        guard let tunnel = try? await target(), let port = NWEndpoint.Port(rawValue: UInt16(clamping: tunnel.adminPort)) else {
            client.cancel()
            return
        }
        let admin = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        admin.start(queue: queue)
        await send(tunnel.request, on: admin)
        // Cabeçalho da resposta: só segue com 101; o que vier depois do cabeçalho já é do serviço.
        var head = Data()
        let separator = Data("\r\n\r\n".utf8)
        while head.range(of: separator) == nil {
            guard let chunk = await receive(on: admin), head.count < 16 * 1024 else {
                admin.cancel()
                client.cancel()
                return
            }
            head.append(chunk)
        }
        let end = head.range(of: separator)!.upperBound
        let status = String(decoding: head[..<end], as: UTF8.self)
        guard status.hasPrefix("HTTP/1.1 101") else {
            admin.cancel()
            client.cancel()
            return
        }
        let leftover = head[end...]
        if !leftover.isEmpty { await send(Data(leftover), on: client) }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                while let data = await receive(on: admin) { await send(data, on: client) }
                client.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
            }
            group.addTask {
                while let data = await receive(on: client) { await send(data, on: admin) }
                admin.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
            }
        }
        admin.cancel()
        client.cancel()
    }

    private static func send(_ data: Data, on connection: NWConnection) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in continuation.resume() })
        }
    }

    /// Próximo pedaço; `nil` no EOF ou erro.
    private static func receive(on connection: NWConnection) async -> Data? {
        while true {
            let result: (data: Data?, finished: Bool) = await withCheckedContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    continuation.resume(returning: (data, isComplete || error != nil))
                }
            }
            if let data = result.data, !data.isEmpty { return data }
            if result.finished { return nil }
        }
    }
}

/// Roda o bloco só na primeira vez (o callback de estado do listener repete).
final class OnceFlag: Sendable {
    private let done = Mutex(false)
    func run(_ body: () -> Void) {
        let first = done.withLock { value in
            defer { value = true }
            return !value
        }
        if first { body() }
    }
}
