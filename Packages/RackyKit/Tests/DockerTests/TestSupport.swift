import RackyPlatform
import Darwin
import Foundation

@testable import RackyDocker

enum Fixtures {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: "Fixtures/" + name, withExtension: nil) else {
            throw FixtureError.missing(name)
        }
        return try Data(contentsOf: url)
    }

    static func text(_ name: String) throws -> String { String(decoding: try data(name), as: UTF8.self) }

    static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(type, from: data(name))
    }

    enum FixtureError: Error { case missing(String) }
}

/// Diretório privado (0700) com caminho curto o bastante para `sun_path`.
final class TempSocketDir: Sendable {
    let url: URL
    var socketPath: String { url.appendingPathComponent("d.sock").path }

    init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        url = base.appendingPathComponent("abd-\(UInt32.random(in: 0 ... 0xFFFFFF))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        chmod(url.path, 0o700)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

struct FakeRequest: Sendable {
    var method: String
    var target: String
    var headers: [String: String]
    var body: Data

    var path: String { String(target.split(separator: "?", maxSplits: 1)[0]) }
    var query: String { target.contains("?") ? String(target.split(separator: "?", maxSplits: 1)[1]) : "" }
    var jsonBody: [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }
}

actor RequestLog {
    private(set) var items: [FakeRequest] = []
    func add(_ request: FakeRequest) { items.append(request) }
    func matching(_ method: String, prefix: String) -> [FakeRequest] { items.filter { $0.method == method && $0.path.contains(prefix) } }
}

/// Daemon Docker de brincadeira: serve um socket Unix e delega cada requisição ao `handler`, que escreve a resposta.
final class FakeDockerDaemon: Sendable {
    typealias Handler = @Sendable (FakeRequest, UDSConnection) async -> Void

    let dir: TempSocketDir
    let log = RequestLog()
    private let listener: UDSListener
    private let serving: Task<Void, Never>

    var socketPath: String { dir.socketPath }
    var client: DockerClient { DockerClient(socketPath: socketPath, defaultTimeout: .seconds(5)) }

    init(handler: @escaping Handler) async throws {
        let dir = try TempSocketDir()
        self.dir = dir
        let listener = try await UDSListener.listen(path: dir.socketPath)
        self.listener = listener
        let log = self.log
        serving = Task {
            await withTaskGroup(of: Void.self) { group in
                for await connection in listener.connections {
                    group.addTask {
                        guard let request = try? await Self.readRequest(connection) else {
                            connection.close()
                            return
                        }
                        await log.add(request)
                        await handler(request, connection)
                        connection.close()
                    }
                }
            }
        }
    }

    func stop() {
        listener.close()
        serving.cancel()
    }

    static func readRequest(_ connection: UDSConnection) async throws -> FakeRequest {
        var buffer = Data()
        let terminator = Data("\r\n\r\n".utf8)
        while buffer.range(of: terminator) == nil {
            guard let chunk = try await connection.receive() else { throw DockerError.transport("EOF") }
            buffer.append(chunk)
        }
        let range = buffer.range(of: terminator)!
        let head = String(decoding: buffer[buffer.startIndex ..< range.lowerBound], as: UTF8.self)
        var body = Data(buffer[range.upperBound...])
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let length = headers["content-length"].flatMap { Int($0) } ?? 0
        while body.count < length {
            guard let chunk = try await connection.receive() else { break }
            body.append(chunk)
        }
        return FakeRequest(method: String(first[0]), target: String(first[1]), headers: headers, body: body)
    }
}

enum Reply {
    static func json(_ connection: UDSConnection, status: Int = 200, body: Data, contentType: String = "application/json") async {
        await raw(connection, status: status, headers: ["Content-Type": contentType, "Content-Length": String(body.count)], body: body)
    }

    static func text(_ connection: UDSConnection, status: Int = 200, _ text: String) async {
        await json(connection, status: status, body: Data(text.utf8), contentType: "text/plain")
    }

    static func raw(_ connection: UDSConnection, status: Int, headers: [String: String], body: Data) async {
        var head = "HTTP/1.1 \(status) \(reason(status))\r\n"
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) { head += "\(key): \(value)\r\n" }
        head += "Connection: close\r\n\r\n"
        try? await connection.send(Data(head.utf8) + body)
    }

    static func chunked(_ connection: UDSConnection, status: Int = 200, contentType: String = "application/json", chunks: [Data], delay: Duration? = nil) async {
        let head = "HTTP/1.1 \(status) \(reason(status))\r\nContent-Type: \(contentType)\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
        try? await connection.send(Data(head.utf8))
        for chunk in chunks {
            try? await connection.send(Data(String(chunk.count, radix: 16).utf8) + Data("\r\n".utf8) + chunk + Data("\r\n".utf8))
            if let delay { try? await Task.sleep(for: delay) }
        }
        try? await connection.send(Data("0\r\n\r\n".utf8))
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 101: "UPGRADED"
        case 204: "No Content"
        case 304: "Not Modified"
        case 404: "Not Found"
        case 409: "Conflict"
        default: "Status"
        }
    }

    /// Frame multiplexado do Docker (`kind`, 3 zeros, tamanho big endian).
    static func mux(_ kind: UInt8, _ text: String) -> Data {
        let payload = Data(text.utf8)
        var header = Data([kind, 0, 0, 0])
        let n = UInt32(payload.count)
        header.append(contentsOf: [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
        return header + payload
    }
}
