import Foundation

// T3-06, 07 §2.8: o run folder no host. `box.json` guarda os metadados (modo, proxy, dono, lote, tempos), e quem termina um run
// (release, SubagentStop, "Archive") só tira os containers: a pasta fica. Um `boxes_reserve` com nome repetido na mesma sessão
// arquiva o run anterior em `_archive/<computador>-<YYYYmmdd-HHMMSS>/`; o que sai do `work/` e quando é do `RunLeftovers`.

/// Como o run terminou (campo `outcome` de `box.json`).
public enum RunOutcome: String, Sendable, Codable, Equatable {
    /// Ainda rodando (ou o app caiu antes de fechar o run).
    case running
    /// O filho liberou o computador (`box_release`) ou o SubagentStop o encerrou.
    case released
    /// O usuário parou o computador, arquivou o lote ou o pai terminou.
    case stopped
    /// O computador nunca subiu.
    case failed
}

/// `box.json` (07 §2.8): metadados do run.
public struct RunMetadata: Sendable, Codable, Equatable {
    public var computer: String
    public var computerID: String?
    public var display: String
    public var proxy: String
    public var parent: String
    public var child: String?
    public var batch: String?
    public var session: String?
    public var runID: String?
    public var startedAt: Date
    public var endedAt: Date?
    public var outcome: RunOutcome
    /// O que acontece com o `work/` depois do fim (card de aprovação ou Settings; `nil` em runs de antes da escolha).
    public var leftovers: LeftoversPolicy?
    /// Quando o `work/` foi esvaziado (varredura, Delete now ou Clean up now).
    public var leftoversDeletedAt: Date?

    public init(
        computer: String, computerID: String? = nil, display: String, proxy: String = "direct", parent: String, child: String? = nil,
        batch: String? = nil, session: String? = nil, runID: String? = nil, startedAt: Date, endedAt: Date? = nil, outcome: RunOutcome = .running,
        leftovers: LeftoversPolicy? = nil
    ) {
        self.computer = computer; self.computerID = computerID; self.display = display; self.proxy = proxy; self.parent = parent
        self.child = child; self.batch = batch; self.session = session; self.runID = runID; self.startedAt = startedAt; self.endedAt = endedAt
        self.outcome = outcome; self.leftovers = leftovers
    }

    enum CodingKeys: String, CodingKey {
        case computer, display, proxy, parent, child, batch, session, outcome, leftovers
        case computerID = "computer_id", runID = "run_id", startedAt = "started_at", endedAt = "ended_at"
        case leftoversDeletedAt = "leftovers_deleted_at"
    }

    public var durationSeconds: Int? {
        endedAt.map { max(0, Int($0.timeIntervalSince(startedAt))) }
    }
}

extension RunFolder {
    public var metadataFile: URL { root.appendingPathComponent("box.json") }
    public var validationFile: URL { file("validation.json") }
    public var usageFile: URL { file("usage.json") }
    public var integrityFile: URL { file("integrity.json") }
    public var resultFile: URL { work.appendingPathComponent("result.json") }

    static let metadataEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let metadataDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public func readMetadata() -> RunMetadata? {
        guard let data = try? Data(contentsOf: metadataFile) else { return nil }
        return try? Self.metadataDecoder.decode(RunMetadata.self, from: data)
    }

    public func writeMetadata(_ metadata: RunMetadata) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? Self.metadataEncoder.encode(metadata) { try? data.write(to: metadataFile, options: .atomic) }
    }

    /// Há algum arquivo (não só as pastas vazias do layout) no run? Decide se um nome repetido precisa arquivar o run anterior.
    public var hasContent: Bool {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return false }
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { return true }
        return false
    }
}

/// Arquivamento e descoberta de runs (a pasta da sessão é `runs/<session-slug>/`).
public enum RunArchive {
    public static let folderName = "_archive"
    public static let batchesFolderName = "_batches"

    /// `phoenix-az-20261020-143005`.
    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    /// Move o run anterior para `<sessão>/_archive/<computador>-<stamp>/`. `nil` se não havia nada a guardar. O `box.json` vai junto, e
    /// com ele a escolha do que sai do `work/` (`RunLeftovers`). Se o destino existir (dois arquivamentos no mesmo segundo), ganha um sufixo.
    @discardableResult
    public static func archivePrevious(run: RunFolder, name: String, now: Date = Date()) throws -> URL? {
        guard FileManager.default.fileExists(atPath: run.root.path), run.hasContent else { return nil }
        let archive = run.root.deletingLastPathComponent().appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        var destination = archive.appendingPathComponent("\(name)-\(stamp(now))", isDirectory: true)
        var suffix = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            suffix += 1
            destination = archive.appendingPathComponent("\(name)-\(stamp(now))-\(suffix)", isDirectory: true)
        }
        try FileManager.default.moveItem(at: run.root, to: destination)
        return destination
    }

    /// Runs (pastas com computador) da sessão, sem `_archive` e `_batches`, em ordem de nome.
    public static func runs(inSession folder: URL) -> [RunFolder] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return items
            .filter { !$0.lastPathComponent.hasPrefix("_") && (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { RunFolder(root: $0) }
    }

    /// `listings-oct` a partir do título da sessão (`Listings Oct!` -> `listings-oct`). Sem letras ou dígitos, `fallback`.
    public static func slug(_ title: String?, fallback: String) -> String {
        var out = ""
        var pendingDash = false
        for scalar in (title ?? "").lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                if pendingDash, !out.isEmpty { out.append("-") }
                pendingDash = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        out = String(out.prefix(48))
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? fallback : out
    }
}
