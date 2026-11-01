import RackyDocker
import RackyProtocol
import Foundation
import Network
import Synchronization

/// Resultado de `Test connection` (Settings › Computers › Proxies). `summary` cabe numa linha e nunca carrega credencial.
public struct ProxyTestResult: Sendable, Equatable {
    public var ok: Bool
    public var summary: String
    public var latencyMilliseconds: Int?

    public init(ok: Bool, summary: String, latencyMilliseconds: Int? = nil) {
        self.ok = ok
        self.summary = summary
        self.latencyMilliseconds = latencyMilliseconds
    }
}

/// Teste leve de um proxy sem Docker: abre o TCP até o proxy, autentica e pede um túnel (`CONNECT`) até um host público.
/// HTTP/HTTPS usam `CONNECT host:443`; SOCKS5 usa o handshake com usuário e senha. O proxy aceitar o túnel prova host, porta
/// e credencial; o IP de saída só o egress descartável da orquestração mede.
public enum ProxyTester {
    public static let target = (host: "example.com", port: 443)

    public static func test(profile: ProxyProfile, secret: String?, timeout: Duration = .seconds(10)) async -> ProxyTestResult {
        let upstream = EgressUpstream(profile: profile, secret: secret)
        let started = ContinuousClock.now
        do {
            let message: String = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await handshake(upstream) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw ProxyTestError.timeout
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw ProxyTestError.timeout }
                return first
            }
            let ms = Int((ContinuousClock.now - started).components.seconds * 1000 + (ContinuousClock.now - started).components.attoseconds / 1_000_000_000_000_000)
            return ProxyTestResult(ok: true, summary: "\(message) · \(ms) ms", latencyMilliseconds: ms)
        } catch let error as ProxyTestError {
            return ProxyTestResult(ok: false, summary: error.message(host: profile.host, port: profile.port))
        } catch {
            return ProxyTestResult(ok: false, summary: "Couldn't reach \(profile.host):\(profile.port).")
        }
    }

    // MARK: Protocolos

    private static func handshake(_ up: EgressUpstream) async throws -> String {
        let conn = try await ProxyConnection.open(host: up.host, port: up.port, tls: up.scheme == "https")
        defer { conn.close() }
        if up.scheme == "socks5" { return try await socks5(conn, up) }
        return try await httpConnect(conn, up)
    }

    private static func httpConnect(_ conn: ProxyConnection, _ up: EgressUpstream) async throws -> String {
        var request = "CONNECT \(target.host):\(target.port) HTTP/1.1\r\nHost: \(target.host):\(target.port)\r\n"
        if up.username != nil || up.password != nil {
            let credential = "\(up.username ?? ""):\(up.password ?? "")"
            request += "Proxy-Authorization: Basic \(Data(credential.utf8).base64EncodedString())\r\n"
        }
        request += "\r\n"
        try await conn.send(Data(request.utf8))
        var buffer = Data()
        while !buffer.contains(Data("\r\n\r\n".utf8)), buffer.count < 8192 {
            buffer.append(try await conn.receive(max: 2048))
        }
        let line = String(decoding: buffer, as: UTF8.self).split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = line.split(separator: " ")
        let status = parts.count > 1 ? Int(parts[1]) : nil
        switch status {
        case 200: return "Connected through \(up.host)"
        case 407: throw ProxyTestError.rejectedCredentials
        case let code?: throw ProxyTestError.refused("The proxy answered \(code).")
        case nil: throw ProxyTestError.refused("That doesn't look like an HTTP proxy.")
        }
    }

    private static func socks5(_ conn: ProxyConnection, _ up: EgressUpstream) async throws -> String {
        let hasAuth = up.username != nil
        try await conn.send(Data(hasAuth ? [5, 2, 0, 2] : [5, 1, 0]))
        let method = try await conn.receive(exactly: 2)
        guard method[0] == 5 else { throw ProxyTestError.refused("That doesn't look like a SOCKS5 proxy.") }
        if method[1] == 2 {
            let user = Array((up.username ?? "").utf8.prefix(255)), pass = Array((up.password ?? "").utf8.prefix(255))
            try await conn.send(Data([1, UInt8(user.count)] + user + [UInt8(pass.count)] + pass))
            let reply = try await conn.receive(exactly: 2)
            guard reply[1] == 0 else { throw ProxyTestError.rejectedCredentials }
        } else if method[1] == 0xFF {
            throw ProxyTestError.rejectedCredentials
        }
        let host = Array(target.host.utf8)
        try await conn.send(Data([5, 1, 0, 3, UInt8(host.count)] + host + [UInt8(target.port >> 8), UInt8(target.port & 0xFF)]))
        let head = try await conn.receive(exactly: 4)
        guard head[1] == 0 else { throw ProxyTestError.refused("The SOCKS5 proxy refused the tunnel (code \(head[1])).") }
        return "Connected through \(up.host)"
    }
}

enum ProxyTestError: Error {
    case timeout
    case rejectedCredentials
    case refused(String)
    case unreachable

    func message(host: String, port: Int) -> String {
        switch self {
        case .timeout: "No answer from \(host):\(port) in 10 s."
        case .rejectedCredentials: "The proxy rejected the credentials."
        case .refused(let text): text
        case .unreachable: "Couldn't reach \(host):\(port)."
        }
    }
}

/// `NWConnection` com `async`: um envio e uma leitura por vez (o handshake é sequencial).
final class ProxyConnection: @unchecked Sendable {  // SAFETY: `NWConnection` é thread-safe e o handshake é sequencial (um envio ou leitura por vez).
    private let connection: NWConnection

    private init(_ connection: NWConnection) { self.connection = connection }

    static func open(host: String, port: Int, tls: Bool) async throws -> ProxyConnection {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { throw ProxyTestError.unreachable }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: tls ? .tls : .tcp)
        let wrapper = ProxyConnection(connection)
        do {
            try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let once = OnceGate()
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: if once.fire() { continuation.resume() }
                    case .failed, .waiting: if once.fire() { continuation.resume(throwing: ProxyTestError.unreachable) }
                    case .cancelled: if once.fire() { continuation.resume(throwing: CancellationError()) }
                    default: break
                    }
                }
                connection.start(queue: .global(qos: .userInitiated))
            }
            } onCancel: { connection.cancel() }
        } catch {
            // `.waiting`/`.failed` não cancelam sozinhos: sem isto a NWConnection fica viva (e re-tentando) depois do erro.
            connection.cancel()
            throw error
        }
        return wrapper
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    func receive(max: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, isComplete, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else if isComplete { continuation.resume(throwing: ProxyTestError.refused("The proxy closed the connection.")) }
                else { continuation.resume(returning: Data()) }
            }
        }
    }

    func receive(exactly count: Int) async throws -> Data {
        var buffer = Data()
        while buffer.count < count { buffer.append(try await receive(max: count - buffer.count)) }
        return buffer
    }

    func close() { connection.cancel() }
}

private final class OnceGate: Sendable {
    private let fired = Mutex(false)
    func fire() -> Bool { fired.withLock { was in
        if was { return false }
        was = true
        return true
    } }
}
