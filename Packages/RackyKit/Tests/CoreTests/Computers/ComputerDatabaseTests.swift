import Foundation
import Network
import Testing

@testable import RackyCore

/// Bancos dos agentes no Racky: o cluster que o smoke sobe no computador é achado pelo `postmaster.pid` no `/work` (que está no disco do
/// Mac) e lido por uma porta do Mac que passa pela admin API do computador.
struct ComputerDatabaseTests {
    @Test func findsALiveClusterByItsPostmasterPidAndSkipsNoise() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("cdb-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let pg = work.appendingPathComponent("run/pg")
        try FileManager.default.createDirectory(at: pg, withIntermediateDirectories: true)
        try "15\n".write(to: pg.appendingPathComponent("PG_VERSION"), atomically: true, encoding: .utf8)
        try "4242\n/work/run/pg\n1761450000\n5432\n\n127.0.0.1\n  5432001  0\nready   \n".write(
            to: pg.appendingPathComponent("postmaster.pid"), atomically: true, encoding: .utf8)
        // Um cluster parado (sem postmaster.pid) e um dentro de node_modules não contam.
        let stopped = work.appendingPathComponent("old/pg")
        try FileManager.default.createDirectory(at: stopped, withIntermediateDirectories: true)
        try "15\n".write(to: stopped.appendingPathComponent("PG_VERSION"), atomically: true, encoding: .utf8)
        let noise = work.appendingPathComponent("node_modules/x/pg")
        try FileManager.default.createDirectory(at: noise, withIntermediateDirectories: true)
        try "15\n".write(to: noise.appendingPathComponent("PG_VERSION"), atomically: true, encoding: .utf8)
        try "1\n/x\n1\n6000\n".write(to: noise.appendingPathComponent("postmaster.pid"), atomically: true, encoding: .utf8)

        #expect(ComputerDatabaseScan.find(in: work) == [ComputerDatabaseScan.Found(path: "run/pg", port: 5432)])
        #expect(ComputerDatabaseScan.port(fromPostmasterPID: "1\n/x\n1\n80\n") == nil, "porta de sistema não")
    }

    @Test func datasetNamesFitTheDatasetRules() {
        #expect(ComputerDatabaseWatcher.datasetName(computer: "chicago", schema: "public", table: "listings") == "chicago-public-listings")
        #expect(ComputerDatabaseWatcher.datasetName(computer: "A.B", schema: "s", table: "Tâble") == "a_b-s-t_ble")
        #expect(ComputerDatabaseWatcher.datasetName(computer: String(repeating: "x", count: 80), schema: "s", table: "t").count == 64)
    }

    @Test func forwardUpgradesThroughTheAdminAndThenCarriesRawBytes() async throws {
        let admin = try FakeAdmin()
        let adminPort = try await admin.start()
        defer { admin.stop() }
        let forward = try ComputerPortForward(target: { AdminTunnelTarget(adminPort: adminPort, request: Data("GET /v1/tcp?port=5432 HTTP/1.1\r\nAuthorization: Bearer t\r\n\r\n".utf8)) })
        let local = try await forward.start()
        defer { forward.stop() }

        let reply = try await roundTrip(port: local, send: Data("hello".utf8))
        #expect(reply == Data("svc:hello".utf8))
        #expect(admin.lastHead().contains("GET /v1/tcp?port=5432"))
    }

    private func roundTrip(port: Int, send: Data) async throws -> Data {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        connection.start(queue: .global())
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in connection.send(content: send, completion: .contentProcessed { _ in c.resume() }) }
        let data: Data? = await withCheckedContinuation { c in
            connection.receive(minimumIncompleteLength: 9, maximumLength: 1024) { data, _, _, _ in c.resume(returning: data) }
        }
        connection.cancel()
        return data ?? Data()
    }
}

/// Admin API falsa: responde 101 ao upgrade e devolve `svc:` + o que receber, como um serviço do outro lado do túnel.
final class FakeAdmin: @unchecked Sendable {  // SAFETY: `head` só é tocado sob o lock.
    private let listener: NWListener
    private let lock = NSLock()
    private var head = ""

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func lastHead() -> String { lock.withLock { head } }

    func start() async throws -> Int {
        let record: @Sendable (Data?) -> Void = { [self] data in lock.withLock { head = String(decoding: data ?? Data(), as: UTF8.self) } }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                record(data)
                connection.send(content: Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: racky-tcp\r\n\r\n".utf8), completion: .contentProcessed { _ in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { body, _, _, _ in
                        connection.send(content: Data("svc:".utf8) + (body ?? Data()), completion: .contentProcessed { _ in })
                    }
                })
            }
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, any Error>) in
            let once = OnceFlag()
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready: once.run { continuation.resume(returning: Int(listener.port!.rawValue)) }
                case .failed(let error): once.run { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: .global())
        }
    }

    func stop() { listener.cancel() }
}
