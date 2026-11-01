import Foundation

/// Host escolhido para um computador (o que o conector de SSH precisa para abrir o túnel).
public struct PlacedHost: Sendable, Equatable {
    public var id: String
    public var region: String
    public var address: String?
    public var shape: HostShape
}

public enum PlacementError: Error, Sendable, Equatable, LocalizedError {
    /// Teto `maxComputers` das configurações (soma de todos os hosts).
    case maxComputersReached(Int)
    public var errorDescription: String? {
        switch self {
        case .maxComputersReached(let limit): "Cloud computer limit reached (\(limit)). Release one or raise the limit in Computers."
        }
    }
}

/// Onde um computador roda quando `runOn == .cloud`: devolve o host (existente com vaga ou novo) e recolhe o host quando esvazia.
public protocol HostPlacement: Sendable {
    func acquire(computerID: String) async throws -> PlacedHost
    func release(computerID: String) async
}

/// Pool de hosts da nuvem (BK12-T10). Regras, de propósito simples:
/// - capacidade de um host = quantos computadores de referência (2 vCPU, 4 GiB) cabem no formato: `min(vCPU/2, GiB/4)`, no mínimo 1;
/// - reaproveita um host vivo com vaga antes de criar outro; só `CloudHostManager` cria (AUP, cota e teto de gasto passam por ele);
/// - `maxComputers` das configurações é um teto EXTRA, somado em todos os hosts (falha, não enfileira);
/// - quando o último computador sai, o host espera `idleGrace` (padrão: `DeadManPolicy.idleShutdown`, 15 min) e é encerrado;
///   um computador que chega nesse intervalo reaproveita o host;
/// - as aquisições são serializadas (duas chamadas simultâneas nunca sobem dois hosts quando um só basta).
public actor ComputerHostPool: HostPlacement {
    struct Slot {
        var host: CloudHost
        var computers: Set<String> = []
        var idleSince: Date?
    }

    private let manager: CloudHostManager
    private let region: String
    private let shape: HostShape
    private let access: CloudHostManager.Access
    private let clock: @Sendable () -> Date
    private let pause: @Sendable (Duration) async throws -> Void
    private let onHostClosed: @Sendable (String) async -> Void
    public private(set) var maxComputers: Int
    public private(set) var idleGrace: Duration
    private var slots: [String: Slot] = [:]
    private var placed: [String: String] = [:]  // computador -> host
    private var timers: [String: Task<Void, Never>] = [:]
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(
        manager: CloudHostManager, region: String, shape: HostShape, access: CloudHostManager.Access, maxComputers: Int,
        idleGrace: Duration = DeadManPolicy().idleShutdown, clock: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        onHostClosed: @escaping @Sendable (String) async -> Void = { _ in }
    ) {
        self.manager = manager; self.region = region; self.shape = shape; self.access = access
        self.maxComputers = max(1, maxComputers); self.idleGrace = idleGrace
        self.clock = clock; self.pause = sleep; self.onHostClosed = onHostClosed
    }

    public static func capacity(of shape: HostShape) -> Int { max(1, min(shape.vcpus / 2, Int(shape.memoryGiB / 4))) }

    public func update(maxComputers: Int, idleGrace: Duration? = nil) {
        self.maxComputers = max(1, maxComputers)
        if let idleGrace { self.idleGrace = idleGrace }
    }

    public var hostIDs: [String] { slots.keys.sorted() }
    public var computerCount: Int { placed.count }
    public func computers(on hostID: String) -> Set<String> { slots[hostID]?.computers ?? [] }

    private func lock() async {
        if !locked { locked = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func unlock() {
        if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() }
    }

    public func acquire(computerID: String) async throws -> PlacedHost {
        await lock()
        defer { unlock() }
        await dropDeadSlots()
        if let hostID = placed[computerID], let slot = slots[hostID] { return Self.placedHost(slot.host) }  // idempotente
        guard placed.count < maxComputers else { throw PlacementError.maxComputersReached(maxComputers) }
        let capacity = Self.capacity(of: shape)
        let reuse = slots.values.filter { $0.computers.count < capacity }.sorted { $0.host.id < $1.host.id }.first
        let hostID: String
        if let reuse {
            hostID = reuse.host.id
        } else {
            let host = try await manager.acquireHost(region: region, shape: shape, access: access)
            slots[host.id] = Slot(host: host)
            hostID = host.id
        }
        timers.removeValue(forKey: hostID)?.cancel()
        slots[hostID]?.idleSince = nil
        slots[hostID]?.computers.insert(computerID)
        placed[computerID] = hostID
        return Self.placedHost(slots[hostID]!.host)
    }

    /// Esquece os hosts que o gerente já não tem vivos (a VM se apagou, parou na tela ou o teto de gasto a encerrou): o próximo
    /// computador não reaproveita um host morto. Os computadores nele caem junto.
    private func dropDeadSlots() async {
        let live = Set(await manager.activeHosts.map(\.id))
        for id in slots.keys.sorted() where !live.contains(id) {
            timers.removeValue(forKey: id)?.cancel()
            slots.removeValue(forKey: id)
            for (computer, host) in placed where host == id { placed.removeValue(forKey: computer) }
            await onHostClosed(id)
        }
    }

    public func release(computerID: String) async {
        guard let hostID = placed.removeValue(forKey: computerID) else { return }
        slots[hostID]?.computers.remove(computerID)
        guard slots[hostID]?.computers.isEmpty == true else { return }
        slots[hostID]?.idleSince = clock()
        let grace = idleGrace
        timers[hostID]?.cancel()
        timers[hostID] = Task { [pause] in
            do { try await pause(grace) } catch { return }
            await self.sweepIdle()
        }
    }

    /// Encerra os hosts vazios há pelo menos `idleGrace`. Chamado pelo timer de cada host e pelo supervisor.
    @discardableResult
    public func sweepIdle() async -> [String] {
        let now = clock()
        let grace = TimeInterval(idleGrace.components.seconds)
        var closed: [String] = []
        for (id, slot) in slots.sorted(by: { $0.key < $1.key }) {
            guard slot.computers.isEmpty, let since = slot.idleSince, now.timeIntervalSince(since) >= grace else { continue }
            timers.removeValue(forKey: id)?.cancel()
            slots.removeValue(forKey: id)
            do { try await manager.releaseHost(id: id) } catch { continue }  // falhou: o reaper por tag recolhe
            await onHostClosed(id)
            closed.append(id)
        }
        return closed
    }

    /// Encerra tudo (ex.: teto de gasto estourado ou saída do app com "Quit and stop").
    public func closeAll() async {
        for (_, timer) in timers { timer.cancel() }
        timers = [:]
        for id in slots.keys.sorted() {
            try? await manager.releaseHost(id: id)
            await onHostClosed(id)
        }
        slots = [:]
        placed = [:]
    }

    private static func placedHost(_ host: CloudHost) -> PlacedHost {
        PlacedHost(id: host.id, region: host.region, address: host.address, shape: host.shape)
    }
}
