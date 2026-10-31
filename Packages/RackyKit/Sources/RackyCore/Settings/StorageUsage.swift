import Foundation

/// Settings › General › Storage: quanto o app ocupa no disco, lido fora da main (pode levar segundos com runs grandes).
public struct StorageUsage: Sendable, Equatable {
    /// Pastas dos computadores (`computers/runs`), cópias arquivadas incluídas.
    public var runs: Int64 = 0
    /// O que sobrou no `work/` de computadores terminados (sai com "Clean up now", menos os marcados Keep).
    public var leftovers: Int64 = 0
    /// Runtime dos computadores sem Docker (`vz/`: kernel, imagem e as VMs).
    public var runtime: Int64 = 0

    public init(runs: Int64 = 0, leftovers: Int64 = 0, runtime: Int64 = 0) {
        self.runs = runs; self.leftovers = leftovers; self.runtime = runtime
    }

    public static func measure(runsRoot: URL, runtimeRoot: URL, active: Set<String> = []) -> StorageUsage {
        let leftovers = RunLeftovers.list(runsRoot: runsRoot, active: active).filter { $0.policy != .keep }.reduce(Int64(0)) { $0 + $1.bytes }
        return StorageUsage(runs: size(of: runsRoot), leftovers: leftovers, runtime: size(of: runtimeRoot))
    }

    /// Bytes alocados de uma pasta (ou arquivo), sem seguir links. Pasta inexistente: 0.
    public static func size(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        if let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true {
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in walker {
            guard let values = try? item.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}
