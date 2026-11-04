import Foundation

/// Uma linha do diário do computador (`logs/journal.jsonl`), como a aba do subagente mostra.
public struct JournalLine: Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: String
    public var text: String
    public var at: Date?
    /// Nota do próprio Racky (troca de proxy, etc.), não do agente.
    public var system: Bool

    public init(id: String, kind: String, text: String, at: Date?, system: Bool) {
        self.id = id; self.kind = kind; self.text = text; self.at = at; self.system = system
    }

    /// Lê o diário de um run, na ordem em que foi escrito. Linhas sem texto ficam de fora.
    public static func read(run root: URL) -> [JournalLine] {
        ChainedLog.read(RunFolder(root: root).file("journal.jsonl")).enumerated().compactMap { index, entry in
            guard case .string(let text)? = entry["text"], !text.isEmpty else { return nil }
            var kind = ""
            if case .string(let k)? = entry["kind"] { kind = k }
            var id = "\(index)"
            if case .string(let ulid)? = entry["id"] { id = ulid }
            var at: Date?
            switch entry["ts"] {
            case .double(let s)?: at = Date(timeIntervalSince1970: s)
            case .int(let s)?: at = Date(timeIntervalSince1970: Double(s))
            default: break
            }
            var system = false
            if case .bool(true)? = entry["system"] { system = true }
            return JournalLine(id: id, kind: kind, text: text, at: at, system: system)
        }
    }
}
