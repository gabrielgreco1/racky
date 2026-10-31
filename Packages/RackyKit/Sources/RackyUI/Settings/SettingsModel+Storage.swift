import RackyCore
import Foundation

/// Onde o Settings › General › Storage mede e limpa: ligado pelo `AppEnvironment` (testes passam pastas temporárias).
struct StorageHooks {
    var runsRoot: URL
    var runtimeRoot: URL
    /// Pastas de run de computadores ainda vivos (a limpeza não toca).
    var activeRuns: @Sendable () async -> Set<String> = { [] }
    /// Depois de uma limpeza (a seção "Left on disk" de Computers relê).
    var didClean: @MainActor () -> Void = {}
    /// Apaga o checkout das sessões arquivadas que nada perdem (a branch fica). Devolve os bytes liberados.
    var removeArchivedWorktrees: @MainActor () async -> Int64 = { 0 }
}

extension SettingsModel {
    /// Mede fora da main; a linha "Space used" mostra "Measuring…" até chegar.
    func refreshStorage() {
        guard let hooks = storage, !storageMeasuring else { return }
        storageMeasuring = true
        Task { [weak self] in
            let active = await hooks.activeRuns()
            // DETACHED: medir e apagar pastas grandes leva segundos de disco; fora do MainActor.
            let usage = await Task.detached(priority: .utility) {
                StorageUsage.measure(runsRoot: hooks.runsRoot, runtimeRoot: hooks.runtimeRoot, active: active)
            }.value
            self?.storageUsage = usage
            self?.storageMeasuring = false
        }
    }

    /// "Clean up now": esvazia já o `work/` de todo computador terminado que não está marcado Keep e, com a escolha em Delete, tira o
    /// checkout das sessões arquivadas.
    func cleanUpStorage() async -> Int64 {
        guard let hooks = storage else { return 0 }
        let active = await hooks.activeRuns()
        // DETACHED: medir e apagar pastas grandes leva segundos de disco; fora do MainActor.
        var freed = await Task.detached(priority: .utility) { RunLeftovers.cleanAll(runsRoot: hooks.runsRoot, active: active) }.value
        if settings.general.archivedWorktrees == .delete { freed += await hooks.removeArchivedWorktrees() }
        hooks.didClean()
        storageMeasuring = false
        refreshStorage()
        return freed
    }

    /// `Computer runs 21 GB, 13 GB left by finished computers · Computer runtime 2.2 GB`.
    var storageSummary: String {
        guard let usage = storageUsage else { return String(localized: "Measuring…", bundle: .module) }
        func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        var runs = String(localized: "Computer runs \(size(usage.runs))", bundle: .module)
        if usage.leftovers > 0 { runs += String(localized: ", \(size(usage.leftovers)) left by finished computers", bundle: .module) }
        return runs + " · " + String(localized: "Computer runtime \(size(usage.runtime))", bundle: .module)
    }
}
