import RackyProtocol
import Foundation
import Network
import Testing

@testable import RackyCore

/// `ProxyTester` contra proxies falsos em loopback: HTTP CONNECT (200 e 407) e SOCKS5 com usuário e senha.
@Suite("Test connection do proxy", .tags(.integration), .serialized) struct ProxyTesterTests {
    /// Uma conexão do proxy falso: responde a cada leitura com o que `handler` devolve para (bytes, passo).
    final class Session: @unchecked Sendable {
        let connection: NWConnection
        let handler: @Sendable (Data, Int) -> Data?
        let record: @Sendable (Data) -> Void
        init(_ connection: NWConnection, handler: @escaping @Sendable (Data, Int) -> Data?, record: @escaping @Sendable (Data) -> Void) {
            self.connection = connection
            self.handler = handler
            self.record = record
        }

        func loop(_ step: Int) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, done, error in
                guard let data, error == nil, !done else { self.connection.cancel(); return }
                self.record(data)
                if let reply = self.handler(data, step) {
                    self.connection.send(content: reply, completion: .contentProcessed { _ in self.loop(step + 1) })
                } else {
                    self.loop(step + 1)
                }
            }
        }
    }

    /// Servidor TCP em loopback; guarda as conexões vivas e os bytes recebidos.
    final class FakeProxy: @unchecked Sendable {
        let listener: NWListener
        private(set) var port = 0
        private let lock = NSLock()
        private var _requests: [Data] = []
        private var sessions: [Session] = []
        var requests: [Data] { lock.withLock { _requests } }

        init(_ handler: @escaping @Sendable (Data, Int) -> Data?) throws {
            listener = try NWListener(using: .tcp, on: .any)
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
            let lock = self.lock
            listener.newConnectionHandler = { [unowned self] connection in
                let session = Session(connection, handler: handler, record: { data in lock.withLock { self._requests.append(data) } })
                lock.withLock { self.sessions.append(session) }
                connection.start(queue: .global())
                session.loop(0)
            }
            listener.start(queue: .global())
            _ = ready.wait(timeout: .now() + 5)
            port = Int(listener.port?.rawValue ?? 0)
        }

        deinit { listener.cancel() }
    }

    private func profile(port: Int, scheme: ProxyScheme = .http, username: String? = nil) -> ProxyProfile {
        ProxyProfile(name: "t", scheme: scheme, host: "127.0.0.1", port: port, username: username)
    }

    @Test func httpConnectAcceptedSendsBasicCredentials() async throws {
        let fake = try FakeProxy { _, _ in Data("HTTP/1.1 200 Connection established\r\n\r\n".utf8) }
        let result = await ProxyTester.test(profile: profile(port: fake.port, username: "alex"), secret: "pw")
        #expect(result.ok && result.summary.hasPrefix("Connected through 127.0.0.1"), "\(result.summary)")
        let request = String(decoding: fake.requests.first ?? Data(), as: UTF8.self)
        #expect(request.hasPrefix("CONNECT example.com:443 HTTP/1.1"))
        #expect(request.contains("Proxy-Authorization: Basic \(Data("alex:pw".utf8).base64EncodedString())"))
    }

    @Test func httpConnectWith407ReportsTheCredentials() async throws {
        let fake = try FakeProxy { _, _ in Data("HTTP/1.1 407 Proxy Authentication Required\r\n\r\n".utf8) }
        let result = await ProxyTester.test(profile: profile(port: fake.port), secret: nil)
        #expect(!result.ok && result.summary == "The proxy rejected the credentials.")
    }

    @Test func socks5HandshakeWithUserAndPassword() async throws {
        let fake = try FakeProxy { _, step in
            switch step {
            case 0: Data([5, 2])  // escolhe usuário/senha
            case 1: Data([1, 0])  // credencial aceita
            default: Data([5, 0, 0, 1, 0, 0, 0, 0, 0, 0])  // túnel aberto
            }
        }
        let result = await ProxyTester.test(profile: profile(port: fake.port, scheme: .socks5, username: "u"), secret: "p")
        #expect(result.ok, "\(result.summary)")
    }

    @Test func closedPortIsAnUnreachableLine() async {
        let result = await ProxyTester.test(profile: profile(port: 1), secret: nil, timeout: .seconds(3))
        #expect(!result.ok && result.summary.contains("127.0.0.1:1"), "\(result.summary)")
    }
}
