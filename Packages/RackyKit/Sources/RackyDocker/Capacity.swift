import Foundation

/// Modo de exibição do computador (07 §2.4): define a estimativa de memória para a admissão.
public enum ComputerDisplay: String, Sendable, CaseIterable, Codable {
    case http, headless, desktop
}

/// Recursos da VM do Docker lidos de `/info`.
public struct VMCapacity: Sendable, Equatable {
    public var memTotalBytes: Int64
    public var cpuCount: Int

    public init(memTotalBytes: Int64, cpuCount: Int) {
        self.memTotalBytes = memTotalBytes
        self.cpuCount = cpuCount
    }

    static let gib = Double(1 << 30)
    /// `M` da conta de referência de 07 §2.4, em GiB.
    public var memGiB: Double { Double(memTotalBytes) / Self.gib }
    /// `MemTotal` fica ~0,3 GiB abaixo do valor configurado no Docker Desktop: valor que o usuário vê em Settings.
    public var configuredGB: Int { Int((memGiB + 0.3).rounded()) }
}

public enum AdmissionDecision: Sendable, Equatable {
    case admit
    /// Entra na fila persistente (`ComputerQueue`, CS-131) com `reason: "memory"`.
    case queue(reason: String)
    /// Disco livre abaixo de 5 GiB no data root do Docker.
    case rejectDisk
}

/// Regra de capacidade de 07 CS-130: `soma(estimativas ativas) + estimativa nova <= M - 2 GiB`.
public struct CapacityPlanner: Sendable, Equatable {
    public static let reservedGiB = 2.0
    public static let minimumFreeDiskBytes: Int64 = 5 << 30
    /// Tabela inicial de 07 §2.4 (GiB). Fixa nos testes (`RACKY_CAPACITY_ESTIMATES=fixed`).
    public static let initialEstimatesGiB: [ComputerDisplay: Double] = [.http: 0.4, .headless: 1.2, .desktop: 2.2]

    public var vm: VMCapacity
    public var estimatesGiB: [ComputerDisplay: Double]

    public init(vm: VMCapacity, estimatesGiB: [ComputerDisplay: Double] = CapacityPlanner.initialEstimatesGiB) {
        self.vm = vm
        self.estimatesGiB = estimatesGiB
    }

    public func estimate(_ display: ComputerDisplay) -> Double { estimatesGiB[display] ?? Self.initialEstimatesGiB[display] ?? 1.2 }

    public var budgetGiB: Double { vm.memGiB - Self.reservedGiB }

    public func usedGiB(active: [ComputerDisplay]) -> Double { active.reduce(0) { $0 + estimate($1) } }

    public func admission(active: [ComputerDisplay], adding: ComputerDisplay, freeDiskBytes: Int64? = nil) -> AdmissionDecision {
        if let freeDiskBytes, freeDiskBytes < Self.minimumFreeDiskBytes { return .rejectDisk }
        return usedGiB(active: active) + estimate(adding) <= budgetGiB + 1e-9 ? .admit : .queue(reason: "memory")
    }

    /// Quantos computadores só deste modo cabem (VM de 8 GB: 4 headless, 07 §2.4).
    public func maxConcurrent(_ display: ComputerDisplay) -> Int { max(0, Int((budgetGiB / estimate(display)) + 1e-9)) }

    /// GB para configurar no Docker Desktop para comportar o alvo (15 headless + 2 desktop => 26).
    public func recommendedVMGB(headless: Int = 15, desktop: Int = 2, http: Int = 0) -> Int {
        let need = Double(headless) * estimate(.headless) + Double(desktop) * estimate(.desktop) + Double(http) * estimate(.http)
        let gb = Int((need + Self.reservedGiB + 0.3).rounded(.up))
        return gb % 2 == 0 ? gb : gb + 1
    }

    /// `"Docker VM has 8 GB. 15 headless and 2 desktop computers need about 26 GB."`; `nil` se a VM já comporta o alvo (CS-132).
    public func vmSizeWarning(headless: Int = 15, desktop: Int = 2) -> String? {
        let need = Double(headless) * estimate(.headless) + Double(desktop) * estimate(.desktop)
        guard need > budgetGiB else { return nil }
        return "Docker VM has \(vm.configuredGB) GB. \(headless) headless and \(desktop) desktop computers need about \(recommendedVMGB(headless: headless, desktop: desktop)) GB."
    }
}

/// Média móvel das últimas 20 medições de `stats` por display (07 CS-130).
public struct EstimateTracker: Sendable, Equatable {
    public static let window = 20
    private var samples: [ComputerDisplay: [Double]] = [:]
    public var fixed: Bool

    public init(fixed: Bool = false) { self.fixed = fixed }

    public mutating func record(_ display: ComputerDisplay, usedGiB: Double) {
        guard !fixed else { return }
        var list = samples[display, default: []]
        list.append(usedGiB)
        if list.count > Self.window { list.removeFirst(list.count - Self.window) }
        samples[display] = list
    }

    /// Estimativas efetivas: média móvel quando há 20 amostras no display, senão a tabela inicial.
    public var estimatesGiB: [ComputerDisplay: Double] {
        var result = CapacityPlanner.initialEstimatesGiB
        guard !fixed else { return result }
        for (display, list) in samples where list.count >= Self.window { result[display] = list.reduce(0, +) / Double(list.count) }
        return result
    }
}
