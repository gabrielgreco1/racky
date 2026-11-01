import RackyPlatform
import Foundation

@testable import RackyDocker

/// Proxy de socket Unix (o papel do `ssh -L socket:socket` sem sshd): aceita em `listenPath` e repassa bytes, nos dois sentidos e com
/// half-close, para `targetPath`. Prova que o `DockerClient` funciona por um caminho de socket encaminhado.
final class SocketProxy: Sendable {
    private let listener: UDSListener
    private let serving: Task<Void, Never>

    static func start(listenPath: String, targetPath: String) async throws -> SocketProxy {
        let listener = try await UDSListener.listen(path: listenPath)
        return SocketProxy(listener: listener, targetPath: targetPath)
    }

    private init(listener: UDSListener, targetPath: String) {
        self.listener = listener
        serving = Task {
            await withTaskGroup(of: Void.self) { group in
                for await inbound in listener.connections {
                    group.addTask {
                        guard let outbound = try? await UDSClient.connect(path: targetPath) else { inbound.close(); return }
                        await withTaskGroup(of: Void.self) { pumps in
                            pumps.addTask { await Self.pump(from: inbound, to: outbound) }
                            pumps.addTask { await Self.pump(from: outbound, to: inbound) }
                        }
                        inbound.close()
                        outbound.close()
                    }
                }
            }
        }
    }

    private static func pump(from source: UDSConnection, to sink: UDSConnection) async {
        while let chunk = try? await source.receive() {
            if (try? await sink.send(chunk)) == nil { break }
        }
        sink.finishWriting()
    }

    func stop() {
        listener.close()
        serving.cancel()
    }
}

final class FakeTunnelProcess: TunnelProcess {
    private let exit = ProcessExitSignal()
    private let proxy: SocketProxy
    init(proxy: SocketProxy) { self.proxy = proxy }
    func terminate() { proxy.stop(); exit.finish(15) }
    /// Queda do mestre (rede, `kill -9`): o socket some e o processo sai com erro.
    func crash() { proxy.stop(); exit.finish(255) }
    func waitUntilExit() async -> Int32 { await exit.wait() }
}

/// `TunnelRunner` de teste: o "mestre" é um `SocketProxy` até o socket real/falso do Docker; `-O forward` só registra.
actor ForwardingTunnelRunner: TunnelRunner {
    let targetSocket: String
    private(set) var launched: [[String]] = []
    private(set) var commands: [[String]] = []
    private(set) var processes: [FakeTunnelProcess] = []
    var failLaunch = 0
    var forwardStatus: Int32 = 0

    init(targetSocket: String) { self.targetSocket = targetSocket }

    func setFailLaunch(_ count: Int) { failLaunch = count }
    func setForwardStatus(_ status: Int32) { forwardStatus = status }

    func launch(_ arguments: [String]) async throws -> any TunnelProcess {
        launched.append(arguments)
        if failLaunch > 0 { failLaunch -= 1; throw SSHTunnelError.masterExited(255) }
        // `-L <socket local>:<socket remoto>`
        guard let index = arguments.firstIndex(of: "-L"), let spec = arguments[safe: index + 1], let colon = spec.firstIndex(of: ":") else {
            throw SSHTunnelError.masterExited(2)
        }
        let local = String(spec[spec.startIndex ..< colon])
        let process = FakeTunnelProcess(proxy: try await SocketProxy.start(listenPath: local, targetPath: targetSocket))
        processes.append(process)
        return process
    }

    func run(_ arguments: [String], timeout: Duration) async throws -> TunnelCommandResult {
        commands.append(arguments)
        let isForward = arguments.starts(with: ["-O", "forward"])
        return TunnelCommandResult(status: isForward ? forwardStatus : 0)
    }

    func crashMaster() { processes.last?.crash() }
    func forwardCommands(_ op: String) -> [[String]] { commands.filter { $0.starts(with: ["-O", op]) } }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// Endpoint com arquivos reais (chave 0600 e known_hosts) numa pasta temporária.
struct TunnelFixture {
    let directory: URL
    let endpoint: SSHEndpoint
    let tunnelDirectory: URL

    init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("rk-\(UInt32.random(in: 0 ... 0xFFFFFF))", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        directory = base
        let key = base.appendingPathComponent("id")
        try Data("not-a-real-key\n".utf8).write(to: key)
        chmod(key.path, 0o600)
        let known = base.appendingPathComponent("known_hosts")
        try KnownHosts.write(host: "203.0.113.7", publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGJhZGJhZGJhZGJhZGJhZGJhZGJhZGJhZGJhZGJhZGJh", to: known)
        endpoint = SSHEndpoint(user: "racky", host: "203.0.113.7", identityFile: key, knownHostsFile: known)
        tunnelDirectory = base.appendingPathComponent("t", isDirectory: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}
