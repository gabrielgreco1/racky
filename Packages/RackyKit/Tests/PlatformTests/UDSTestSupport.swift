import RackyProtocol
import Darwin
import Foundation

@testable import RackyPlatform

/// Diretório privado (0700) com caminho curto o bastante para `sun_path`.
final class TempSocketDir: Sendable {
    let url: URL
    var socketPath: String { url.appendingPathComponent("d.sock").path }

    init(mode: mode_t = 0o700) throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        url = base.appendingPathComponent("abx-\(UInt32.random(in: 0 ... 0xFFFFFF))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        chmod(url.path, mode)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

let testDaemonInfo = DaemonInfo(build: "test (1)", pid: 1, startedAt: Date(timeIntervalSince1970: 1_792_238_400), binary: "/test/rackyd")

func makeServerHandshake(version: ProtocolVersion = .current, capabilities: [Capability] = Capability.initialSet) -> ServerHandshake {
    ServerHandshake(version: version, capabilities: capabilities, daemon: testDaemonInfo)
}

func makeClientHandshake(version: ProtocolVersion = .current, accepted: [UInt16]? = nil) -> ClientHandshake {
    ClientHandshake(version: version, client: ClientInfo(kind: .app, build: "test"), acceptedMajors: accepted)
}

/// Daemon de brincadeira (sem PTY): handshake, depois `ping` → `pong`, `list` → vazio e input → `output` com `seq` contínuo.
func serveFakeDaemon(on listener: UDSListener, version: ProtocolVersion = .current) -> Task<Void, Never> {
    Task {
        await withTaskGroup(of: Void.self) { group in
            for await connection in listener.connections {
                group.addTask { await serveOne(connection, version: version) }
            }
        }
    }
}

private func serveOne(_ connection: UDSConnection, version: ProtocolVersion) async {
    let framed = FramedConnection(connection)
    do {
        _ = try await framed.acceptHandshake(makeServerHandshake(version: version), sessions: 0, timeout: .seconds(2))
        var seq: [SessionID: UInt64] = [:]
        while let frame = try await framed.receive() {
            switch frame {
            case .control(.request(let request)):
                switch request.command {
                case .ping:
                    try await framed.send(.control(.reply(.ok(id: request.id, .pong(PongInfo(at: Date(timeIntervalSince1970: 1_792_238_400), activeSessions: 0, uptimeMillis: 1))))))
                case .list:
                    try await framed.send(.control(.reply(.ok(id: request.id, .list(ListResult(sessions: []))))))
                default:
                    try await framed.send(.control(.reply(.error(id: request.id, DaemonError(.badRequest, "unsupported in fake daemon")))))
                }
            case .input(let input):
                let start = seq[input.sessionID, default: 0]
                let output = OutputFrame(sessionID: input.sessionID, seq: start, bytes: input.bytes)
                seq[input.sessionID] = output.nextSeq
                try await framed.send(.output(output))
            default:
                break
            }
        }
    } catch let error as FrameError {
        try? await framed.send(.control(.reply(.error(id: nil, error.daemonError))))
    } catch {
        // handshake rejeitado, timeout ou conexão caída: nada a fazer
    }
    await framed.close()
}

/// Lê até `count` bytes de uma `UDSConnection`.
func readExactly(_ connection: UDSConnection, count: Int) async throws -> Data {
    var data = Data()
    while data.count < count {
        guard let chunk = try await connection.receive() else { break }
        data.append(chunk)
    }
    return data
}

/// Mede o maior intervalo entre ticks de um `Task.sleep` curto: detecta pool cooperativo bloqueado.
actor LatencyProbe {
    private(set) var maxGap: Duration = .zero
    private var running = true

    func run() async {
        var last = ContinuousClock.now
        while running {
            try? await Task.sleep(for: .milliseconds(5))
            let now = ContinuousClock.now
            maxGap = max(maxGap, now - last - .milliseconds(5))
            last = now
        }
    }

    func stop() { running = false }
}

actor Flag {
    private(set) var isSet = false
    func set() { isSet = true }
}
