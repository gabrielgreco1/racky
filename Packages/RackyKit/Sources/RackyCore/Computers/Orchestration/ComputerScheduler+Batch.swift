import RackyDocker
import RackyProtocol
import RackyStore
import Foundation

// T3-07: o lote do lado do scheduler. Agrega as entradas vivas e os runs já fechados da pasta da sessão (`box.json` + `result.json`),
// responde `batch_status` e `batch_collect` ao pai, alimenta o painel `Batch` e dispara "lote concluído" uma vez por lote.

extension ComputerScheduler {
    func folderKey(_ folder: URL, _ batch: String) -> String { "\(folder.standardizedFileURL.path)|\(batch)" }

    func trackBatch(parent: String, batch: String) {
        guard let folder = sessionFolders[parent] else { return }
        trackedBatches[folderKey(folder, batch)] = (parent, batch)
    }

    // MARK: Lote

    func batchFolder(parent: String) async -> URL {
        if let folder = sessionFolders[parent] { return folder }
        return await runURL(parent: parent, name: "_").deletingLastPathComponent()
    }

    /// Verificados por campo, com cache pelo estado dos arquivos (o painel consulta a cada poucos segundos).
    func fieldCounts(_ run: RunFolder) -> (verified: Int, citedMissing: Int, notVerified: Int) {
        func stamp(_ url: URL) -> String {
            let a = try? FileManager.default.attributesOfItem(atPath: url.path)
            return "\((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)-\((a?[.size] as? NSNumber)?.intValue ?? 0)"
        }
        let key = run.root.path
        let current = [run.resultFile, run.requestsFile, run.validationFile].map(stamp).joined(separator: "|")
        if let cached = summaryCache[key], cached.stamp == current { return cached.counts }
        let collected = RunCollector.collect(run: run, name: run.root.lastPathComponent, now: now())
        let counts = (collected.verified, collected.citedMissing, collected.notVerified)
        summaryCache[key] = (current, counts)
        return counts
    }

    func agentActivity(child: String?, parent: String?) async -> AgentActivity? {
        guard let child, let parent else { return nil }
        if let cached = activityCache[child] { return cached }
        guard let store, let record = (try? await store.orchestrationChildren(parentID: parent))?.first(where: { $0.id == child }),
              let runID = record.runID, let activity = (try? await store.agentRun(id: runID))?.activity else { return nil }
        if activity == .failed || activity == .done || activity == .interrupted { activityCache[child] = activity }
        return activity
    }

    func liveChild(_ entry: Entry) async -> BatchChild {
        let c = entry.computer
        let status: BatchChildStatus
        switch entry.phase {
        case .queued: status = .queued
        case .failed: status = .failed
        case .creating: status = .running
        case .active:
            if await c.openHelpID != nil { status = .needsYou } else if await c.openBlocked != nil { status = .blocked } else { status = .running }
        }
        let counts = fieldCounts(entry.spec.run)
        var requests: Int?
        if entry.phase == .active, let usage = try? await c.backend.usage() { requests = usage["requests"]?.int }
        let started = entry.startedAt ?? entry.requestedAt
        return BatchChild(
            name: entry.spec.name, childID: entry.childID, status: status, computerState: await c.state, verified: counts.verified,
            citedMissing: counts.citedMissing, notVerified: counts.notVerified, proxy: await c.proxy, proxyRequests: requests,
            durationSeconds: entry.phase == .queued ? nil : max(0, Int(now().timeIntervalSince(started))), lastDoing: await c.lastDoing,
            runPath: entry.spec.run.root.path)
    }

    func storedChild(_ run: RunFolder, meta: RunMetadata) async -> BatchChild {
        let counts = fieldCounts(run)
        let hasResult = FileManager.default.fileExists(atPath: run.resultFile.path)
        var status: BatchChildStatus
        switch meta.outcome {
        case .released: status = hasResult ? .done : .failed
        case .failed: status = .failed
        case .stopped, .running: status = .stopped
        }
        // O agente do filho pode ter falhado ou sido interrompido mesmo com o computador liberado direito (hooks: agent_run).
        if status == .done || status == .failed, let activity = await agentActivity(child: meta.child, parent: meta.parent) {
            if activity == .failed { status = .failed } else if activity == .interrupted, !hasResult { status = .stopped }
        }
        var requests: Int?
        if let data = try? Data(contentsOf: run.usageFile), let usage = try? JSON.parse(data) { requests = usage["requests"]?.int }
        return BatchChild(
            name: meta.computer, childID: meta.child, status: status, computerState: meta.outcome == .running ? nil : .stopped, verified: counts.verified,
            citedMissing: counts.citedMissing, notVerified: counts.notVerified, proxy: meta.proxy, proxyRequests: requests,
            durationSeconds: meta.durationSeconds ?? max(0, Int(now().timeIntervalSince(meta.startedAt))), runPath: run.root.path)
    }

    /// O lote de um pai: as entradas vivas e, para quem já saiu, os runs da pasta da sessão com o mesmo `batch`.
    public func batchSummary(parent: String, batch: String) async -> BatchSummary? {
        let folder = await batchFolder(parent: parent)
        var children: [(BatchChild, Date)] = []
        var live = Set<String>()
        for entry in entries.values where entry.spec.batch == batch && sessionFolders[entry.spec.parent] == folder {
            live.insert(entry.spec.name)
            children.append((await liveChild(entry), entry.requestedAt))
        }
        for run in RunArchive.runs(inSession: folder) {
            guard let meta = run.readMetadata(), meta.batch == batch, !live.contains(meta.computer) else { continue }
            children.append((await storedChild(run, meta: meta), meta.startedAt))
        }
        guard !children.isEmpty else { return nil }
        children.sort { $0.1 == $1.1 ? $0.0.name < $1.0.name : $0.1 < $1.1 }
        let session = await sessionInfo(parent)
        return BatchSummary(name: batch, sessionID: session?.id, sessionTitle: session?.title, parent: parent, children: children.map(\.0), createdAt: children.first?.1)
    }

    /// Lotes que o pai conhece: os rótulos das entradas vivas e dos runs da pasta da sessão.
    public func batchNames(parent: String) async -> [String] {
        let folder = await batchFolder(parent: parent)
        var names = Set(entries.values.filter { sessionFolders[$0.spec.parent] == folder }.compactMap(\.spec.batch))
        for run in RunArchive.runs(inSession: folder) { if let batch = run.readMetadata()?.batch { names.insert(batch) } }
        return names.sorted()
    }

    public func batchStatus(parent: String, batch: String) async throws -> JSON {
        guard let summary = await batchSummary(parent: parent, batch: batch) else { throw ToolError(.notFound, "no batch named \(batch) in this session") }
        return summary.statusJSON
    }

    /// Consolidado com os resultados lidos de cada run (para o painel, a exportação e `batch_collect`).
    public func consolidatedBatch(parent: String, batch: String) async -> BatchSummary? {
        guard var summary = await batchSummary(parent: parent, batch: batch) else { return nil }
        let folder = await batchFolder(parent: parent)
        for index in summary.children.indices {
            let run = RunFolder(root: folder.appendingPathComponent(summary.children[index].name, isDirectory: true))
            summary.children[index].result = await collectedRun(run: run, name: summary.children[index].name, parent: nil).result
        }
        return summary
    }

    /// `batch_collect` (07 §4.2): escreve `_batches/<lote>/results.jsonl` e devolve o resumo por alvo.
    public func collectBatch(parent: String, batch: String) async throws -> JSON {
        guard let summary = await consolidatedBatch(parent: parent, batch: batch) else { throw ToolError(.notFound, "no batch named \(batch) in this session") }
        let folder = await batchFolder(parent: parent)
        let file = BatchLedger.resultsFile(session: folder, batch: batch)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? summary.resultsJSONL().write(to: file, options: .atomic)
        let rows: [JSON] = summary.children.map { child in
            var row: [String: JSON] = [
                "name": .string(child.name), "status": .string(child.status.rawValue), "verified": .int(child.verified),
                "cited_missing": .int(child.citedMissing), "not_verified": .int(child.notVerified), "run": .string(child.runPath),
            ]
            if let requests = child.proxyRequests { row["usage"] = ["requests": .int(requests)] }
            return .object(row)
        }
        return ["batch": .string(batch), "results_jsonl_path": .string(file.path), "finished": .bool(summary.isFinished), "summary": .array(rows)]
    }

    // MARK: Conclusão do lote (CS-326)

    /// Olha os lotes conhecidos: o que acabou de terminar (todos os filhos terminais, nenhum pedido aberto) dispara `onBatchFinished` **uma**
    /// vez. O marcador em `_batches/<lote>/notified.json` vale depois de reiniciar o app e para `batch_collect` repetido.
    func checkBatches() async {
        for (key, ref) in trackedBatches {
            guard !batchTracker.hasNotified(key) else { trackedBatches[key] = nil; continue }
            guard let summary = await batchSummary(parent: ref.parent, batch: ref.batch), summary.isFinished else { continue }
            let folder = await batchFolder(parent: ref.parent)
            trackedBatches[key] = nil
            if BatchLedger.wasNotified(session: folder, batch: ref.batch) { _ = batchTracker.observe(summary, key: key); continue }
            guard batchTracker.observe(summary, key: key) else { continue }
            BatchLedger.markNotified(session: folder, batch: ref.batch, summary: summary, at: now())
            onBatchFinished?(summary)
        }
    }

    // MARK: Arquivar o lote (CS-182)

    public func archiveBatch(parent: String, batch: String) async -> [String] {
        let folder = await batchFolder(parent: parent)
        let names = entries.values.filter { $0.spec.batch == batch && sessionFolders[$0.spec.parent] == folder }.map(\.spec.name).sorted()
        return await archiveComputers(names: names)
    }
}
