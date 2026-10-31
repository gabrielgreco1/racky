import RackyCore
import RackyProtocol
import AppKit
import Foundation

// T3-07: o painel `Batch` (03 §12.4) e as ações `batch.*`.

extension ComputersController {
    // MARK: Atualização

    /// A cada 2 s reagrega os lotes das sessões abertas (estado vivo + runs já fechados).
    func refreshBatches() async {
        batchTick += 1
        if let orchestrator, batchTick % 2 == 0 {
            model.setBatches(await orchestrator.batches())
            model.setWorkers(await orchestrator.appWorkers())
        }
    }

    // MARK: Lote

    public func openBatch(_ id: String) {
        guard model.batch(id) != nil else { return }
        show(.batch(id))
    }

    public func setBatchFilter(_ filter: BatchSummary.Filter) { batchFilter = filter }

    /// O consolidado do lote com os resultados (lê o disco fora da thread principal).
    @discardableResult
    public func loadConsolidated(_ id: String) async -> BatchSummary? {
        guard let batch = model.batch(id) else { return consolidated[id] }
        guard let orchestrator, let full = await orchestrator.consolidated(batch: batch) else { return consolidated[id] }
        consolidated[id] = full
        return full
    }

    func confirmArchive(of batch: BatchSummary) -> ConfirmationModel? {
        let running = batch.children.filter { !$0.status.isTerminal }.count
        guard running > 0 else { return nil }
        return .archiveBatch(running: running)
    }

    // MARK: Ações

    public func registerBatch(in registry: ActionRegistry, automationEnabled: Bool) throws {
        func batchID(_ arg: ActionArgument, _ id: ActionID) throws -> String {
            let raw: String? = arg.kind == .select ? arg.value : (page.batchName ?? model.batches.first?.id)
            guard let raw, model.batch(raw) != nil else { throw ActionError.failed(id, message: String(localized: "No such batch.", bundle: .module)) }
            return raw
        }
        try registry.register(.batchOpen) { [unowned self] arg in
            guard arg.kind == .select, let raw = arg.value, model.batch(raw) != nil else {
                throw ActionError.failed(.batchOpen, message: String(localized: "No such batch.", bundle: .module))
            }
            openBatch(raw)
            return raw
        }
        try registry.register(.batchFilter) { [unowned self] arg in
            guard arg.kind == .select, let raw = arg.value, let filter = BatchSummary.Filter(rawValue: raw) else {
                throw ActionError.failed(.batchFilter, message: "expected select(All|Needs You|Blocked|Done)")
            }
            setBatchFilter(filter)
            return filter.rawValue
        }
        try registry.register(.batchCollectAll) { [unowned self] arg in
            let id = try batchID(arg, .batchCollectAll)
            guard let batch = model.batch(id), let orchestrator else { throw ActionError.failed(.batchCollectAll, message: "Computers are not available") }
            guard let file = await orchestrator.collectAll(batch: batch) else { throw ActionError.failed(.batchCollectAll, message: "Nothing to collect") }
            await loadConsolidated(id)
            return file.path
        }
        for (action, format) in [(ActionID.batchExportCSV, BatchExportFormat.csv), (.batchExportJSON, .json)] {
            try registry.register(action) { [unowned self] arg in
                let id = try batchID(arg, action)
                guard let summary = await loadConsolidated(id) ?? consolidated[id] ?? model.batch(id) else { throw ActionError.failed(action, message: "No such batch.") }
                if arg.kind == .set, let path = arg.value, !path.isEmpty {
                    guard automationEnabled else { throw ActionError.failed(action, message: "Automation is off") }
                    return try BatchExporter.write(summary, format: format, to: URL(fileURLWithPath: path)).path
                }
                let panel = NSSavePanel()
                panel.nameFieldStringValue = BatchExporter.suggestedName(batch: id, format: format)
                let response = await withCheckedContinuation { (c: CheckedContinuation<NSApplication.ModalResponse, Never>) in panel.begin { c.resume(returning: $0) } }
                guard response == .OK, let url = panel.url else { return "cancelled" }
                return try BatchExporter.write(summary, format: format, to: url).path
            }
        }
        // `Archive Batch`: com filhos rodando pede `Stop <n> running subagents?`; sem eles remove direto.
        try registry.register(.batchArchive) { [unowned self] arg in
            let id = try batchID(arg, .batchArchive)
            guard let batch = model.batch(id) else { throw ActionError.failed(.batchArchive, message: "No such batch.") }
            if let model = confirmArchive(of: batch), let overlays {
                pendingArchive = id
                if overlays.present(.confirmation(model), from: .batchArchive(id)) { return "confirming" }
                pendingArchive = nil
                return "busy"
            }
            return try await archiveBatch(batch)
        }
        try registry.register(.dialogArchiveBatchCancel) { [unowned self] _ in
            pendingArchive = nil
            overlays?.dismiss(.action)
            return nil
        }
        try registry.register(.dialogArchiveBatchConfirm) { [unowned self] _ in
            guard let id = pendingArchive, let batch = model.batch(id) else { throw ActionError.failed(.dialogArchiveBatchConfirm, message: "Nothing to archive") }
            pendingArchive = nil
            overlays?.dismiss(.action)
            return try await archiveBatch(batch)
        }
    }

    fileprivate func archiveBatch(_ batch: BatchSummary) async throws -> String {
        guard let orchestrator else { throw ActionError.failed(.batchArchive, message: "Computers are not available") }
        let names = await orchestrator.archive(batch: batch)
        model.setBatches(await orchestrator.batches())
        return "archived \(names.count)"
    }
}

extension CenterPage {
    /// Nome do lote da página aberta.
    var batchName: String? { if case .batch(let name) = self { name } else { nil } }
}

extension ComputersModel {
    public func batch(_ id: String) -> BatchSummary? { batches.first { $0.id == id } }
}

extension ConfirmationModel {
    /// "Stop <n> running subagents?" (03 §24.5): arquivar o lote remove os computadores; runs, resultados e perfis ficam.
    static func archiveBatch(running: Int) -> ConfirmationModel {
        ConfirmationModel(
            name: "confirmArchiveBatch", rootID: .overlayConfirmArchiveBatch,
            title: running == 1 ? String(localized: "Stop 1 running subagent?", bundle: .module) : String(localized: "Stop \(running) running subagents?", bundle: .module),
            message: String(localized: "Removes the computers of this batch. Run folders, results and named profiles stay.", bundle: .module),
            confirmTitle: "Archive Batch", confirmAction: .dialogArchiveBatchConfirm, confirmID: .overlayConfirmArchiveBatchConfirm,
            cancelAction: .dialogArchiveBatchCancel, cancelID: .overlayConfirmArchiveBatchCancel, destructive: true, symbol: "archivebox")
    }
}
