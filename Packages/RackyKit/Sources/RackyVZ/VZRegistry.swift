import Foundation

/// Uma VM de computador conhecida pelo app. Substitui os labels do Docker (`racky.owner`, `racky.computer`...): o Virtualization.framework
/// não tem inventário, então o app guarda o seu.
public struct VZRegistryEntry: Codable, Sendable, Equatable {
    public var vmID: String
    public var computerID: String
    public var name: String
    /// `racky.owner` equivalente (instâncias isoladas por `RACKY_HOME` têm owner próprio).
    public var owner: String
    /// Processo dono da VM: a VM morre com ele.
    public var hostPID: Int32
    public var createdAt: Date

    public init(vmID: String, computerID: String, name: String, owner: String, hostPID: Int32, createdAt: Date = Date()) {
        self.vmID = vmID; self.computerID = computerID; self.name = name; self.owner = owner; self.hostPID = hostPID; self.createdAt = createdAt
    }
}

/// O que o sweep de início fez.
public struct VZSweepReport: Sendable, Equatable {
    /// Entradas de processos mortos, removidas do registro junto com a pasta de cada uma.
    public var removedEntries: [String] = []
    /// Pastas em `containers/` que nenhum registro reivindica (sobra de queda no meio do boot).
    public var removedOrphanDirectories: [String] = []
    /// Entradas de outro processo ainda vivo (outra instância do app): intactas.
    public var keptForLiveHosts: [String] = []
}

/// Registro JSON das VMs (`vz/registry.json`), escrito de forma atômica. Um actor: o arquivo só muda por aqui.
public actor VZRegistry {
    private struct File: Codable {
        var version = 1
        var entries: [VZRegistryEntry] = []
    }

    public let url: URL
    private var file: File

    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let decoded = try? Self.decoder().decode(File.self, from: data) {
            file = decoded
        } else {
            file = File()
        }
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public var entries: [VZRegistryEntry] { file.entries }

    public func entry(vmID: String) -> VZRegistryEntry? { file.entries.first { $0.vmID == vmID } }

    public func add(_ entry: VZRegistryEntry) throws {
        file.entries.removeAll { $0.vmID == entry.vmID }
        file.entries.append(entry)
        try save()
    }

    public func remove(vmID: String) throws {
        let before = file.entries.count
        file.entries.removeAll { $0.vmID == vmID }
        if file.entries.count != before { try save() }
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(file).write(to: url, options: .atomic)
    }

    /// Sweep de início (antes de qualquer VM subir): remove entradas de processos que já não existem (a VM morreu com eles) e apaga
    /// a pasta da VM (rootfs clonado, bootlog), mais pastas órfãs sem registro. Entradas do PRÓPRIO processo viram VMs paradas por
    /// `stopOwn`. Nunca toca em VM de outro processo vivo.
    @discardableResult
    public func sweep(
        containersDirectory: URL, currentPID: Int32 = getpid(), isAlive: (Int32) -> Bool = VZRegistry.processIsAlive,
        stopOwn: (VZRegistryEntry) async -> Void = { _ in }
    ) async -> VZSweepReport {
        var report = VZSweepReport()
        let fm = FileManager.default
        var keep: [VZRegistryEntry] = []
        for entry in file.entries {
            if entry.hostPID == currentPID {
                await stopOwn(entry)
            } else if isAlive(entry.hostPID) {
                keep.append(entry)
                report.keptForLiveHosts.append(entry.vmID)
                continue
            }
            try? fm.removeItem(at: containersDirectory.appendingPathComponent(entry.vmID, isDirectory: true))
            report.removedEntries.append(entry.vmID)
        }
        file.entries = keep
        let claimed = Set(keep.map(\.vmID))
        for name in (try? fm.contentsOfDirectory(atPath: containersDirectory.path)) ?? [] where !claimed.contains(name) && !name.hasPrefix(".") {
            try? fm.removeItem(at: containersDirectory.appendingPathComponent(name, isDirectory: true))
            report.removedOrphanDirectories.append(name)
        }
        try? save()
        return report
    }

    /// `kill(pid, 0)`: existe (ou existe mas é de outro usuário, `EPERM`).
    public static func processIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
