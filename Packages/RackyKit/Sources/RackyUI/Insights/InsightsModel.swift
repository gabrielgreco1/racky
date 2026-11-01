import RackyCore
import RackyProtocol
import Foundation
import Observation

public enum InsightsTab: String, CaseIterable, Sendable, Identifiable {
    case claude, codex, machine, proxy
    public var id: String { rawValue }
}

/// Histórico curto das amostras da máquina (sparklines). Anel de capacidade fixa.
public struct InsightsHistory: Sendable, Equatable {
    public static let capacity = 60
    public private(set) var cpu: [Double] = []
    public private(set) var memory: [Double] = []
    public private(set) var down: [Double] = []
    public private(set) var up: [Double] = []

    public init() {}

    public init(cpu: [Double], memory: [Double], down: [Double], up: [Double]) {
        self.cpu = cpu; self.memory = memory; self.down = down; self.up = up
    }

    public mutating func append(_ machine: MachineSnapshot) {
        func push(_ array: inout [Double], _ value: Double?) {
            guard let value else { return }
            array.append(value)
            if array.count > Self.capacity { array.removeFirst(array.count - Self.capacity) }
        }
        push(&cpu, machine.cpu?.total)
        push(&memory, machine.memory?.usedFraction)
        push(&down, machine.network?.downBytesPerSec)
        push(&up, machine.network?.upBytesPerSec)
    }
}

/// Estado da view do módulo. O `InsightsService` é a fonte; o modelo só assina enquanto a view está em cena e liga a
/// amostragem da máquina apenas nesse intervalo (R7 de 04: nada trabalha fora de vista).
@MainActor @Observable
public final class InsightsModel {
    public private(set) var snapshot: InsightsSnapshot
    public private(set) var history: InsightsHistory
    public var tab: InsightsTab { didSet { if tab != oldValue { pushCadence() } } }
    /// Lista de apps do Machine: por CPU ou por memória.
    public var appsSortedByMemory = false
    public private(set) var now: Date

    let service: InsightsService?
    private var task: Task<Void, Never>?
    private let clock: @Sendable () -> Date

    public init(service: InsightsService?, tab: InsightsTab = .claude, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.service = service
        self.snapshot = .empty
        self.history = InsightsHistory()
        self.tab = tab
        self.clock = clock
        self.now = clock()
    }

    /// Modelo estático (previews, snapshots, Bench): nenhum serviço, estado fixo.
    public init(preview snapshot: InsightsSnapshot, history: InsightsHistory = InsightsHistory(), tab: InsightsTab = .claude, now: Date) {
        self.service = nil
        self.snapshot = snapshot
        self.history = history
        self.tab = tab
        self.clock = { now }
        self.now = now
    }

    /// Só a aba Machine pede amostras da máquina na cadência cheia (o resto se contenta com 5 s: CPU ocioso ≤ 1%, AR-720).
    private func pushCadence() {
        guard let service else { return }
        let detail = tab == .machine
        Task { await service.setMachineDetail(detail) }
    }

    public func viewDidAppear() {
        pushCadence()
        guard task == nil, let service else { return }
        task = Task { [weak self] in
            await service.start()
            await service.setVisible(true)
            for await next in await service.subscribe() {
                guard let self else { return }
                self.apply(next)
            }
        }
    }

    public func viewDidDisappear() {
        task?.cancel()
        task = nil
        guard let service else { return }
        Task { await service.setVisible(false) }
    }

    func apply(_ next: InsightsSnapshot) {
        if let machine = next.machine, machine.at != snapshot.machine?.at { history.append(machine) }
        snapshot = next
        now = clock()
    }

    /// Clique explícito em "Show exact limits" (P23): só então o serviço lê o login do Claude Code no Keychain.
    public func enableExactLimits() async { await service?.enableExactLimits() }

    func register(in registry: ActionRegistry) throws {
        try registry.register(
            .insightsShowExactLimits,
            enablement: { [unowned self] in
                snapshot.claudeLimits == .notEnabled ? .enabled : .disabled(reason: String(localized: "Exact limits are on.", bundle: .module))
            }
        ) { [unowned self] _ in
            await enableExactLimits()
            return "enabled"
        }
    }

    public func summary(for provider: InsightsProvider) -> ProviderSummary {
        provider == .claude ? snapshot.claude : snapshot.codex
    }
}
