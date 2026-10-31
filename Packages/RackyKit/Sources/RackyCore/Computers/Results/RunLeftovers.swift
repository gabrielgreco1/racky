import Foundation

// O que um computador deixa no Mac depois de terminar: o `work/` do run (clone do repositório, downloads, scripts). A escolha é feita
// por computador no card de aprovação (padrão em Settings › General › Storage), fica em `box.json` e é aplicada por uma varredura do
// app. Logs, transcript, `result.json` e os datasets (no banco) ficam: só o `work/` esvazia.

/// Quando o `work/` de um run terminado sai do disco.
public enum LeftoversPolicy: String, Codable, Sendable, CaseIterable {
    case keep, whenDone, days7, days30

    /// Dias depois do fim do run; `nil` = nunca.
    public var days: Int? {
        switch self {
        case .keep: nil
        case .whenDone: 0
        case .days7: 7
        case .days30: 30
        }
    }
}

/// Um run terminado com arquivos no `work/` (a seção "Left on disk" da página Computers).
public struct RunLeftover: Sendable, Equatable, Identifiable {
    public var id: String { key }
    /// Caminho do run relativo a `computers/runs` (`<sessão>/<computador>` ou `<sessão>/_archive/<cópia>`): argumento das ações.
    public var key: String
    public var root: URL
    public var computer: String
    public var session: String?
    public var endedAt: Date
    /// `nil`: run de antes da escolha existir (só o "Clean up now" mexe nele).
    public var policy: LeftoversPolicy?
    public var bytes: Int64

    /// Quando a varredura apaga; `nil` = fica.
    public var due: Date? { policy?.days.map { endedAt.addingTimeInterval(TimeInterval($0) * 86_400) } }
}

public enum RunLeftovers {
    /// Todos os runs: `runs/<sessão>/<computador>` e as cópias em `runs/<sessão>/_archive/<cópia>`.
    static func runFolders(runsRoot: URL) -> [RunFolder] {
        let fm = FileManager.default
        var out: [RunFolder] = []
        for session in (try? fm.contentsOfDirectory(at: runsRoot, includingPropertiesForKeys: nil)) ?? [] where !session.lastPathComponent.hasPrefix(".") {
            out += RunArchive.runs(inSession: session)
            out += RunArchive.runs(inSession: session.appendingPathComponent(RunArchive.folderName, isDirectory: true))
        }
        return out
    }

    /// Arquivos do `work/` que a limpeza tira (o `result.json` fica: a aba Result lê dele).
    static func removable(in run: RunFolder) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: run.work, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.lastPathComponent != run.resultFile.lastPathComponent }
    }

    /// Runs terminados (fora de `active`, os roots ainda em uso pelo scheduler) com algo no `work/`, o maior primeiro.
    public static func list(runsRoot: URL, active: Set<String> = []) -> [RunLeftover] {
        var out: [RunLeftover] = []
        let base = runsRoot.standardizedFileURL.path + "/"
        for run in runFolders(runsRoot: runsRoot) where !active.contains(run.root.standardizedFileURL.path) {
            guard let meta = run.readMetadata(), meta.outcome != .running, let ended = meta.endedAt, meta.leftoversDeletedAt == nil else { continue }
            let bytes = removable(in: run).reduce(Int64(0)) { $0 + StorageUsage.size(of: $1) }
            guard bytes > 0 else { continue }
            let path = run.root.standardizedFileURL.path
            let key = path.hasPrefix(base) ? String(path.dropFirst(base.count)) : run.root.lastPathComponent
            out.append(RunLeftover(key: key, root: run.root, computer: meta.computer, session: meta.session, endedAt: ended, policy: meta.leftovers, bytes: bytes))
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    /// Esvazia o `work/` (menos o `result.json`) e carimba `box.json`. Devolve os bytes liberados.
    @discardableResult
    public static func delete(_ run: RunFolder, now: Date = Date()) -> Int64 {
        var freed: Int64 = 0
        for item in removable(in: run) {
            let size = StorageUsage.size(of: item)
            if (try? FileManager.default.removeItem(at: item)) != nil { freed += size }
        }
        if var meta = run.readMetadata() {
            meta.leftoversDeletedAt = now
            run.writeMetadata(meta)
        }
        return freed
    }

    /// O run de uma `key` (só dentro de `runsRoot`; `nil` para o que escapa dela ou não existe).
    public static func run(key: String, runsRoot: URL) -> RunFolder? {
        let root = runsRoot.appendingPathComponent(key, isDirectory: true).standardizedFileURL
        guard !key.isEmpty, root.path.hasPrefix(runsRoot.standardizedFileURL.path + "/"), !key.split(separator: "/").contains(".."),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("box.json").path) else { return nil }
        return RunFolder(root: root)
    }

    /// "Keep" na página Computers: o run deixa de ter prazo.
    public static func keep(_ run: RunFolder) {
        guard var meta = run.readMetadata() else { return }
        meta.leftovers = .keep
        run.writeMetadata(meta)
    }

    /// Varredura do app: apaga o que venceu. Runs sem escolha gravada não são tocados.
    @discardableResult
    public static func sweep(runsRoot: URL, active: Set<String> = [], now: Date = Date()) -> Int64 {
        list(runsRoot: runsRoot, active: active)
            .filter { ($0.due.map { $0 <= now }) == true }
            .reduce(Int64(0)) { $0 + delete(RunFolder(root: $1.root), now: now) }
    }

    /// "Clean up now": apaga já o que sobrou de todo run terminado, menos os marcados Keep (os sem escolha entram).
    @discardableResult
    public static func cleanAll(runsRoot: URL, active: Set<String> = [], now: Date = Date()) -> Int64 {
        list(runsRoot: runsRoot, active: active)
            .filter { $0.policy != .keep }
            .reduce(Int64(0)) { $0 + delete(RunFolder(root: $1.root), now: now) }
    }
}
