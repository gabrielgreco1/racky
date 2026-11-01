import Foundation
import Network
import Synchronization

/// Servidor HTTP mínimo em loopback para os testes do downloader: serve arquivos em memória, com `Range` (206) ou sem (200).
final class TestHTTPServer: Sendable {
    struct Behavior: Sendable {
        var supportsRange = true
        /// Responde `status` fixo (ex.: 404) em vez do arquivo.
        var forcedStatus: Int?
        /// Fecha a conexão depois de enviar só esta quantidade de bytes do corpo (simula queda no meio do download).
        var cutAfter: Int?
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.http")
    private let files: Mutex<[String: Data]>
    private let behavior: Mutex<Behavior>
    private let requests = Mutex<[(path: String, range: String?)]>([])

    init(files: [String: Data], behavior: Behavior = Behavior()) throws {
        self.files = Mutex(files)
        self.behavior = Mutex(behavior)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func setBehavior(_ new: Behavior) { behavior.withLock { $0 = new } }
    var seenRequests: [(path: String, range: String?)] { requests.withLock { $0 } }

    /// Começa a escutar e devolve a URL base (`http://127.0.0.1:<porta>`).
    func start() async throws -> URL {
        listener.newConnectionHandler = { [self] connection in handle(connection) }
        let port: Int = try await withCheckedThrowingContinuation { continuation in
            let once = Mutex(false)
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    if once.withLock({ let first = !$0; $0 = true; return first }), let port = listener.port?.rawValue { continuation.resume(returning: Int(port)) }
                case .failed(let error):
                    if once.withLock({ let first = !$0; $0 = true; return first }) { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        return URL(string: "http://127.0.0.1:\(port)")!
    }

    func stop() { listener.cancel() }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [self] data, _, _, _ in
            guard let data, let text = String(data: data, encoding: .utf8) else { connection.cancel(); return }
            let lines = text.components(separatedBy: "\r\n")
            let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let range = lines.first { $0.lowercased().hasPrefix("range:") }?.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) }
            requests.withLock { $0.append((path, range)) }
            respond(connection, path: path, range: range)
        }
    }

    private func respond(_ connection: NWConnection, path: String, range: String?) {
        let behavior = behavior.withLock { $0 }
        func send(_ head: String, _ body: Data, cut: Int? = nil) {
            var payload = Data(head.utf8)
            let announced = body.count
            payload.append(cut.map { body.prefix($0) } ?? body)
            _ = announced
            connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
        }
        if let status = behavior.forcedStatus {
            send("HTTP/1.1 \(status) X\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", Data())
            return
        }
        guard let file = files.withLock({ $0[path] }) else {
            send("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", Data())
            return
        }
        if behavior.supportsRange, let range, range.hasPrefix("bytes="), let start = Int(range.dropFirst(6).split(separator: "-").first ?? "") {
            if start >= file.count {
                send("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", Data())
                return
            }
            let body = file.suffix(from: start)
            send("HTTP/1.1 206 Partial Content\r\nContent-Length: \(body.count)\r\nContent-Range: bytes \(start)-\(file.count - 1)/\(file.count)\r\nConnection: close\r\n\r\n",
                 Data(body), cut: behavior.cutAfter)
        } else {
            send("HTTP/1.1 200 OK\r\nContent-Length: \(file.count)\r\nConnection: close\r\n\r\n", file, cut: behavior.cutAfter)
        }
    }
}
