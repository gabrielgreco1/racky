import RackyCore
import RackyProtocol
import AppKit
import Foundation

// T3-06: a aba `Result` no detalhe do painel direito (03 §11.7) e as ações `computer.*` que a alimentam.

extension ComputersController {
    // MARK: Atualização

    /// A cada 3 s relê o run aberto no detalhe (o resultado pode chegar enquanto o painel está aberto).
    func refreshDetail() async {
        detailTick += 1
        if let detail, detailTick % 3 == 0 { detailCollected = await loader.collect(run: detail.run, name: detail.name) }
    }

    // MARK: Detalhe do computador (03 §11.7)

    /// Pasta do run de um computador: a do computador vivo ou a do filho de um lote que já terminou.
    func runURL(forComputer name: String) -> URL? {
        if let live = model.computer(named: name) { return live.run.root }
        for batch in model.batches { if let child = batch.children.first(where: { $0.name == name }), !child.runPath.isEmpty { return URL(fileURLWithPath: child.runPath) } }
        return nil
    }

    /// Abre o detalhe `Result` no painel direito. `false` sem pasta de run (`No run folder for this computer.`).
    @discardableResult
    public func showDetail(computer name: String) async -> Bool {
        guard let url = runURL(forComputer: name), await loader.runExists(url) else { return false }
        detail = ComputerDetail(name: name, run: url)
        detailCollected = await loader.collect(run: url, name: name)
        if page != .workspace { closePage() }
        setPanel(open: true)
        return true
    }

    public func closeDetail() {
        detail = nil
        detailCollected = nil
    }

    /// Só para testes de UI e snapshots: põe um detalhe já lido sem tocar o disco.
    func setDetailForTesting(_ detail: ComputerDetail?, collected: CollectedRun?) {
        self.detail = detail
        detailCollected = collected
    }

    // MARK: Ações

    public func registerResults(in registry: ActionRegistry) throws {
        func noRun() -> ActionError { ActionError.failed(.computerShowTab, message: String(localized: "No run folder for this computer.", bundle: .module)) }
        // `select(<computer>)` ou `select(<computer>:result)` abre a aba; sem argumento volta à lista (`← Back`).
        try registry.register(.computerShowTab) { [unowned self] arg in
            guard arg.kind == .select, let raw = arg.value, !raw.isEmpty else {
                closeDetail()
                return "list"
            }
            let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
            let name = parts[0]
            if parts.count == 2, parts[1] != "result" { throw ActionError.failed(.computerShowTab, message: "tab \(parts[1]) is not available yet") }
            guard await showDetail(computer: name) else { throw noRun() }
            return "\(name):result"
        }
        try registry.register(.computerOpenRunFolder) { [unowned self] arg in
            guard let name = arg.value, let url = runURL(forComputer: name), await loader.runExists(url) else {
                throw ActionError.failed(.computerOpenRunFolder, message: String(localized: "No run folder for this computer.", bundle: .module))
            }
            NSWorkspace.shared.open(url)
            return url.path
        }
        try registry.register(.computerRevealResult) { [unowned self] arg in
            guard let name = arg.value ?? detail?.name, let url = runURL(forComputer: name), let target = await loader.revealTarget(run: url) else {
                throw ActionError.failed(.computerRevealResult, message: String(localized: "No run folder for this computer.", bundle: .module))
            }
            NSWorkspace.shared.activateFileViewerSelecting([target])
            return target.path
        }
        try registry.register(.computerOpenEvidence) { [unowned self] arg in
            let parts = (arg.value ?? "").split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let url = runURL(forComputer: parts[0]) else { throw noRun() }
            guard let target = await loader.evidenceTarget(run: url, ref: parts[1]) else {
                throw ActionError.failed(.computerOpenEvidence, message: String(localized: "Cited request not found", bundle: .module))
            }
            NSWorkspace.shared.activateFileViewerSelecting([target])
            return target.path
        }
    }
}
