import Foundation

// T3-06: o que a UI precisa do disco sem tocar `FileManager` (regra AR-131: a UI não lê nem grava arquivo).

/// Lê runs fora da thread principal: a aba `Result` e o painel `Batch` pedem aqui.
public actor RunResultLoader {
    public init() {}

    public func collect(run: URL, name: String) -> CollectedRun { RunCollector.collect(run: RunFolder(root: run), name: name) }

    /// O que `Open Evidence` mostra no Finder: o arquivo citado de `/work`; para um request, o corpo salvo (`logs/bodies/<id>.*`) ou o
    /// `requests.jsonl`. `nil` se a citação não aponta para nada (`Cited request not found.`).
    public func evidenceTarget(run: URL, ref: String) -> URL? {
        let folder = RunFolder(root: run)
        if ResultValidator.looksLikeRequestID(ref) {
            let bodies = folder.logs.appendingPathComponent("bodies", isDirectory: true)
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: bodies.path)) ?? []).sorted()
            if let match = names.first(where: { $0.hasPrefix(ref + ".") }) { return bodies.appendingPathComponent(match) }
            let known = ChainedLog.read(folder.requestsFile).contains { $0["id"]?.string == ref }
            return known ? folder.requestsFile : nil
        }
        guard let parts = try? PathGuard.components(ref), (try? PathGuard.rejectSymlinks(root: folder.work, parts)) != nil else { return nil }
        let url = parts.reduce(folder.work) { $0.appendingPathComponent($1) }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// `work/result.json` se existe; senão a pasta `work/`; `nil` sem run.
    public func revealTarget(run: URL) -> URL? {
        let folder = RunFolder(root: run)
        if FileManager.default.fileExists(atPath: folder.resultFile.path) { return folder.resultFile }
        return FileManager.default.fileExists(atPath: folder.work.path) ? folder.work : nil
    }

    public func runExists(_ run: URL) -> Bool { FileManager.default.fileExists(atPath: run.path) }
}
