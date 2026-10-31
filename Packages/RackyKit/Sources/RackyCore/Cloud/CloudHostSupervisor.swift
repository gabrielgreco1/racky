import RackyDocker
import Foundation

/// Manda o sinal de vida (chave morta, `DeadManPolicy.heartbeatCommand`) a UM host.
public protocol HeartbeatSending: Sendable {
    func sendHeartbeat(hostID: String) async throws
}

public enum HeartbeatError: Error, Sendable, Equatable {
    case noTunnel(String)
    case remoteFailed(Int32, String)
}

/// Heartbeat real: `ssh -S ctl host -- <cmd>` pelo mestre do túnel (`SSHTunnel.runRemote`). `tunnel(hostID)` devolve o túnel do host, se há.
public struct TunnelHeartbeatSender: HeartbeatSending {
    public let tunnel: @Sendable (String) async -> SSHTunnel?
    public init(tunnel: @escaping @Sendable (String) async -> SSHTunnel?) { self.tunnel = tunnel }

    public func sendHeartbeat(hostID: String) async throws {
        guard let tunnel = await tunnel(hostID) else { throw HeartbeatError.noTunnel(hostID) }
        let result = try await tunnel.runRemote(DeadManPolicy.heartbeatCommand)
        guard result.status == 0 else { throw HeartbeatError.remoteFailed(result.status, result.stderr) }
    }
}

/// Parte do app que mantém os hosts vivos e limpos (BK12-T11):
/// - heartbeat a cada `heartbeatInterval` para cada host vivo do gerente;
/// - reaper por tag ao iniciar e a cada `reaperInterval` (padrão 10 min);
/// - `stop()` (quit) para os dois laços; os hosts NÃO são encerrados: sem heartbeat a chave morta os apaga, e `start()` ao reabrir
///   readota por tag os que ainda vivem (`CloudHostManager.adoptExisting`).
/// Relógio e espera são injetados: os testes avançam à mão.
public actor CloudHostSupervisor {
    public static let defaultReaperInterval: Duration = .seconds(600)

    private let manager: CloudHostManager
    private let sender: any HeartbeatSending
    private let regions: [String]
    private let heartbeatInterval: Duration
    private let reaperInterval: Duration
    private let pool: ComputerHostPool?
    private let pause: @Sendable (Duration) async throws -> Void
    private var heartbeatTask: Task<Void, Never>?
    private var reaperTask: Task<Void, Never>?

    public private(set) var heartbeatTicks = 0
    public private(set) var reaperRuns = 0
    /// Último erro de heartbeat por host (`nil` = a última tentativa deu certo). A UI pode avisar "host sem sinal".
    public private(set) var heartbeatFailures: [String: String] = [:]
    public private(set) var lastReaperError: String?
    public private(set) var lastReport: ReaperReport?

    public var isRunning: Bool { heartbeatTask != nil }

    public init(
        manager: CloudHostManager, sender: any HeartbeatSending, regions: [String], heartbeatInterval: Duration = DeadManPolicy().heartbeatInterval,
        reaperInterval: Duration = CloudHostSupervisor.defaultReaperInterval, pool: ComputerHostPool? = nil,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.manager = manager; self.sender = sender; self.regions = regions
        self.heartbeatInterval = heartbeatInterval; self.reaperInterval = reaperInterval; self.pool = pool; self.pause = sleep
    }

    /// Reabre: readota os hosts do dono por tag, varre uma vez e liga os laços. Idempotente.
    public func start() async {
        guard heartbeatTask == nil else { return }
        _ = try? await manager.adoptExisting(regions: regions)
        heartbeatTask = Task { [pause, heartbeatInterval] in
            while !Task.isCancelled {
                await self.heartbeatTick()
                do { try await pause(heartbeatInterval) } catch { return }
            }
        }
        reaperTask = Task { [pause, reaperInterval] in
            while !Task.isCancelled {
                await self.reapNow()
                do { try await pause(reaperInterval) } catch { return }
            }
        }
    }

    /// Quit: para os laços e espera terminarem.
    public func stop() async {
        let tasks = [heartbeatTask, reaperTask].compactMap { $0 }
        heartbeatTask = nil; reaperTask = nil
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
    }

    /// Um ciclo: heartbeat a todos os hosts vivos (falha de um não impede os outros), teto de gasto e hosts ociosos.
    public func heartbeatTick() async {
        heartbeatTicks += 1
        for host in await manager.activeHosts {
            do {
                try await sender.sendHeartbeat(hostID: host.id)
                heartbeatFailures[host.id] = nil
            } catch {
                heartbeatFailures[host.id] = "\(error)"
            }
        }
        if await manager.enforceCaps() != nil { await pool?.closeAll() }  // teto estourado: o gerente já encerrou os hosts
        if let pool { await pool.sweepIdle() }
    }

    public func reapNow() async {
        reaperRuns += 1
        do {
            let report = try await manager.reap(regions: regions)
            lastReport = report
            lastReaperError = report.regionErrors.isEmpty ? nil : report.regionErrors.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "; ")
        } catch {
            lastReaperError = "\(error)"
        }
    }
}
