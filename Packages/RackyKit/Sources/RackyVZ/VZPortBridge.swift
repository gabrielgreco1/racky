import Foundation
import Network
import Synchronization

/// Ponte TCP do Mac para uma porta vsock da VM: escuta em `127.0.0.1:<porta efêmera>` e, a cada conexão, abre uma conexão vsock na VM
/// (`dial`) e copia os bytes nos dois sentidos. É como a admin API (e o viewer VNC, que passa por ela) chega ao Mac sem IP da VM:
/// o IP da vmnet exigiria a permissão "Local Network" do macOS e expõe a porta na rede compartilhada; o loopback não faz nenhum dos dois.
public final class VZPortBridge: Sendable {
    public typealias Dial = @Sendable () async throws -> FileHandle

    private let dial: Dial
    private let queue = DispatchQueue(label: "app.racky.vz.bridge")
    private let listener: NWListener

    public init(dial: @escaping Dial) throws {
        self.dial = dial
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    /// Começa a escutar e devolve a porta do Mac.
    public func start() async throws -> Int {
        let dial = dial
        let queue = queue
        listener.newConnectionHandler = { connection in
            Task { await Self.serve(connection, dial: dial, queue: queue) }
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, any Error>) in
            let resumed = AtomicFlag()
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    if resumed.setOnce() {
                        if let port = listener.port?.rawValue { continuation.resume(returning: Int(port)) } else {
                            continuation.resume(throwing: VZError.unavailable("the local bridge has no port"))
                        }
                    }
                case .failed(let error):
                    if resumed.setOnce() { continuation.resume(throwing: error) }
                case .cancelled:
                    if resumed.setOnce() { continuation.resume(throwing: VZError.unavailable("the local bridge was cancelled")) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() { listener.cancel() }

    // MARK: Uma conexão

    private static func serve(_ connection: NWConnection, dial: Dial, queue: DispatchQueue) async {
        connection.start(queue: queue)
        let handle: FileHandle
        do { handle = try await dial() } catch {
            connection.cancel()
            return
        }
        let fd = handle.fileDescriptor
        let io = DispatchIO(type: .stream, fileDescriptor: fd, queue: queue) { _ in try? handle.close() }
        io.setLimit(lowWater: 1)
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                // VM -> cliente
                for await chunk in Self.chunks(of: io, queue: queue) { await Self.send(chunk, on: connection) }
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
            }
            group.addTask {
                // cliente -> VM; no EOF do cliente, meio-fechamento do socket (a resposta ainda volta)
                while let data = await Self.receive(on: connection) {
                    if await !Self.write(data, to: io, queue: queue) { break }
                }
                shutdown(fd, SHUT_WR)
            }
        }
        io.close(flags: .stop)
        connection.cancel()
    }

    private static func chunks(of io: DispatchIO, queue: DispatchQueue) -> AsyncStream<Data> {
        AsyncStream { continuation in
            io.read(offset: 0, length: Int.max, queue: queue) { done, data, error in
                if let data, !data.isEmpty { continuation.yield(Data(data)) }
                if done || error != 0 { continuation.finish() }
            }
        }
    }

    private static func write(_ data: Data, to io: DispatchIO, queue: DispatchQueue) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let dispatchData = data.withUnsafeBytes { DispatchData(bytes: $0) }
            io.write(offset: 0, data: dispatchData, queue: queue) { done, _, error in
                if done { continuation.resume(returning: error == 0) }
            }
        }
    }

    private static func send(_ data: Data, on connection: NWConnection) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in continuation.resume() })
        }
    }

    /// Próximo pedaço do cliente; `nil` no EOF ou erro.
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

/// Marca de "já resolvi a continuation" para os callbacks de estado (que podem repetir).
final class AtomicFlag: Sendable {
    private let value = Mutex(false)
    var isSet: Bool { value.withLock { $0 } }
    func setOnce() -> Bool { value.withLock { current in
        if current { return false }
        current = true
        return true
    } }
}
