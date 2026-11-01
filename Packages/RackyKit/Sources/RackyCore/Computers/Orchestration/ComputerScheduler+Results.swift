import RackyDocker
import RackyProtocol
import RackyStore
import Foundation

// T3-06 / T3-07: resultado, run folder e lote do lado do scheduler. O que o pai chama (`box_collect`, `batch_status`, `batch_collect`),
// o que o app chama (arquivar computadores e lotes, a lista de lotes para o painel) e o fechamento do run quando o computador sai.

extension ComputerScheduler {
    // MARK: Run folder

    /// Pasta do run: `<pasta da sessão>/<computador>`. A pasta da sessão sai da primeira reserva do pai e fica.
    func runURL(parent: String, name: String) async -> URL {
        if let folder = sessionFolders[parent] { return folder.appendingPathComponent(name, isDirectory: true) }
        let url = await runDirectory(parent, name)
        let folder = sessionFolders[parent] ?? url.deletingLastPathComponent()
        sessionFolders[parent] = folder
        return folder.appendingPathComponent(name, isDirectory: true)
    }

    func writeStartMetadata(_ entry: Entry) async {
        let session = await sessionInfo(entry.spec.parent)
        entry.spec.run.writeMetadata(RunMetadata(
            computer: entry.spec.name, computerID: entry.id.uuidString.lowercased(), display: entry.spec.display.rawValue, proxy: entry.spec.proxy,
            parent: entry.spec.parent, child: entry.childID, batch: entry.spec.batch, session: session?.title, runID: await entry.computer.runID,
            startedAt: entry.requestedAt, leftovers: await leftovers(parent: entry.spec.parent)))
    }

    /// O run terminou (release, SubagentStop, parada ou falha): carimba `box.json`, guarda uso, timeline e integridade. Só tira os
    /// containers (quem chama): a pasta, os logs e o resultado ficam (AC-422). Não reabre nem sobrescreve um run já fechado.
    func closeRun(_ entry: Entry, outcome: RunOutcome) async {
        let run = entry.spec.run
        var meta = run.readMetadata() ?? RunMetadata(
            computer: entry.spec.name, computerID: entry.id.uuidString.lowercased(), display: entry.spec.display.rawValue, proxy: entry.spec.proxy,
            parent: entry.spec.parent, child: entry.childID, batch: entry.spec.batch, startedAt: entry.requestedAt)
        guard meta.outcome == .running else { return }
        if entry.phase == .active, outcome != .failed, let usage = try? await entry.computer.backend.usage() {
            try? usage.data(pretty: true).write(to: run.usageFile)
        }
        if entry.phase == .active || entry.phase == .failed { ComputerToolService.writeTimelineFile(entry.computer) }
        let requests = (try? ReqlogIntegrity.verify(file: run.requestsFile))?.message ?? "Log integrity: OK"
        let journal = (try? ReqlogIntegrity.verify(file: run.file("journal.jsonl")))?.message ?? "Log integrity: OK"
        try? (["requests": .string(requests), "journal": .string(journal)] as JSON).data(pretty: true).write(to: run.integrityFile)
        meta.proxy = await entry.computer.proxy
        meta.endedAt = now()
        meta.outcome = outcome
        run.writeMetadata(meta)
    }

    /// SubagentStop (AC-422): o computador do filho para, o perfil e o run folder ficam. Se o filho já liberou, não há mais nada a fazer.
    func childStopped(_ childID: String) async {
        guard let entry = entries.values.first(where: { $0.childID == childID }) else { await checkBatches(); return }
        let name = entry.spec.name
        switch entry.phase {
        case .queued, .creating, .failed:
            await discard(name, childState: .ended)
            await drain()
        case .active:
            await entry.computer.release()
            await entry.computer.emit(.released(computer: name))
            await finish(entry.computer, keep24h: false)
        }
        await checkBatches()
    }

    /// Onde está o run de `name` para este pai: na pasta da sessão dele, ou (sessão renomeada ou pai retomado) em qualquer pasta de
    /// sessão ao lado cujo `box.json` aponte para este pai.
    func locateRun(parent: String, name: String) async -> RunFolder? {
        let primary = RunFolder(root: await runURL(parent: parent, name: name))
        if FileManager.default.fileExists(atPath: primary.root.path) { return primary }
        let root = primary.root.deletingLastPathComponent().deletingLastPathComponent()
        for session in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where !session.lastPathComponent.hasPrefix("_") {
            let candidate = RunFolder(root: session.appendingPathComponent(name, isDirectory: true))
            if let meta = candidate.readMetadata(), meta.parent == parent { return candidate }
        }
        return nil
    }

    // MARK: box_collect

    public func collect(parent: String, name: String, include: Set<CollectedRun.Section>) async throws -> JSON {
        guard let run = await locateRun(parent: parent, name: name) else {
            throw ToolError(.notFound, "no run named \(name) for this session", details: ["box": .string(name)])
        }
        let collected = await collectedRun(run: run, name: name, parent: parent)
        return collected.json(include: include)
    }

    /// Run coletado; se o computador ainda está de pé, com o uso e a timeline de agora.
    func collectedRun(run: RunFolder, name: String, parent: String?) async -> CollectedRun {
        var usage: JSON?
        var timeline: String?
        if let entry = entries[name], entry.spec.run == run, parent == nil || entry.spec.parent == parent {
            if entry.phase == .active { usage = try? await entry.computer.backend.usage() }
            ComputerToolService.writeTimelineFile(entry.computer)
            timeline = try? String(contentsOf: run.timelineFile, encoding: .utf8)
        }
        return RunCollector.collect(run: run, name: name, usage: usage, timeline: timeline, now: now())
    }

    // MARK: Parar e arquivar (AC-423, CS-182)

    /// Remove containers, rede e volume de trabalho dos computadores; runs, resultados e perfis nomeados ficam. Ação do usuário
    /// (`Archive Computers`, `Archive Batch`): não pede a identidade do pai.
    @discardableResult
    public func archiveComputers(names: [String]) async -> [String] {
        var archived: [String] = []
        for name in names {
            guard let entry = entries[name] else { continue }
            if entry.phase == .active {
                await entry.computer.release()
                await entry.computer.emit(.released(computer: name))
            }
            await discard(name, childState: .released)
            archived.append(name)
        }
        await drain()
        await checkBatches()
        return archived
    }

}
