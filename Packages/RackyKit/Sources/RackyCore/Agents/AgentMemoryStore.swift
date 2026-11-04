import Foundation
import SQLite3

public enum AgentMemoryError: Error, Equatable, Sendable {
    case openFailed(String)
    case sqlFailed(String)
    case notFound(Int64)
    case emptyEntry
}

public struct AgentMemoryEntry: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var createdAt: Date
    public var title: String
    public var body: String
    /// Resultado de compactar entradas antigas.
    public var compacted: Bool
}

public struct AgentMemoryHit: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var title: String
    public var snippet: String
    public var createdAt: Date
}

/// Memória compacta de um agente: `<pasta do agente>/memory.sqlite`, com busca FTS5. Depois de cada tarefa o agente (ou o Racky)
/// grava uma entrada curta; no início só o índice curto vai no prompt e o resto vem de `search` e `read` (memory_search, memory_read).
/// O usuário vê e edita pela UI (`update`, `delete`).
public actor AgentMemoryStore {
    nonisolated(unsafe) private var db: OpaquePointer?
    private let clock: @Sendable () -> Date
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: URL, clock: @escaping @Sendable () -> Date = { Date() }) throws {
        self.clock = clock
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open"
            sqlite3_close(handle)
            throw AgentMemoryError.openFailed(msg)
        }
        db = handle
        try Self.exec(handle, """
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS entry(
              id INTEGER PRIMARY KEY AUTOINCREMENT, created_at REAL NOT NULL,
              title TEXT NOT NULL, body TEXT NOT NULL, compacted INTEGER NOT NULL DEFAULT 0);
            CREATE VIRTUAL TABLE IF NOT EXISTS entry_fts USING fts5(title, body, content='entry', content_rowid='id', tokenize='unicode61 remove_diacritics 2');
            CREATE TRIGGER IF NOT EXISTS entry_ai AFTER INSERT ON entry BEGIN
              INSERT INTO entry_fts(rowid, title, body) VALUES (new.id, new.title, new.body); END;
            CREATE TRIGGER IF NOT EXISTS entry_ad AFTER DELETE ON entry BEGIN
              INSERT INTO entry_fts(entry_fts, rowid, title, body) VALUES('delete', old.id, old.title, old.body); END;
            CREATE TRIGGER IF NOT EXISTS entry_au AFTER UPDATE ON entry BEGIN
              INSERT INTO entry_fts(entry_fts, rowid, title, body) VALUES('delete', old.id, old.title, old.body);
              INSERT INTO entry_fts(rowid, title, body) VALUES (new.id, new.title, new.body); END;
            """)
    }

    deinit { sqlite3_close(db) }

    // MARK: escrita

    @discardableResult
    public func add(title: String, body: String, compacted: Bool = false) throws -> Int64 {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines), b = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty || !b.isEmpty else { throw AgentMemoryError.emptyEntry }
        let st = try prepare("INSERT INTO entry(created_at, title, body, compacted) VALUES(?,?,?,?)")
        defer { sqlite3_finalize(st) }
        sqlite3_bind_double(st, 1, clock().timeIntervalSince1970)
        sqlite3_bind_text(st, 2, t.isEmpty ? String(b.prefix(60)) : t, -1, Self.transient)
        sqlite3_bind_text(st, 3, b, -1, Self.transient)
        sqlite3_bind_int(st, 4, compacted ? 1 : 0)
        try step(st)
        return sqlite3_last_insert_rowid(db)
    }

    /// Edição pelo usuário.
    public func update(id: Int64, title: String, body: String) throws {
        let st = try prepare("UPDATE entry SET title=?, body=? WHERE id=?")
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, title, -1, Self.transient)
        sqlite3_bind_text(st, 2, body, -1, Self.transient)
        sqlite3_bind_int64(st, 3, id)
        try step(st)
        if sqlite3_changes(db) == 0 { throw AgentMemoryError.notFound(id) }
    }

    public func delete(id: Int64) throws {
        let st = try prepare("DELETE FROM entry WHERE id=?")
        defer { sqlite3_finalize(st) }
        sqlite3_bind_int64(st, 1, id)
        try step(st)
    }

    // MARK: leitura

    /// memory_read
    public func read(id: Int64) throws -> AgentMemoryEntry {
        let st = try prepare("SELECT id, created_at, title, body, compacted FROM entry WHERE id=?")
        defer { sqlite3_finalize(st) }
        sqlite3_bind_int64(st, 1, id)
        guard sqlite3_step(st) == SQLITE_ROW else { throw AgentMemoryError.notFound(id) }
        return Self.entry(st)
    }

    public func all() throws -> [AgentMemoryEntry] {
        let st = try prepare("SELECT id, created_at, title, body, compacted FROM entry ORDER BY created_at DESC, id DESC")
        defer { sqlite3_finalize(st) }
        var out: [AgentMemoryEntry] = []
        while sqlite3_step(st) == SQLITE_ROW { out.append(Self.entry(st)) }
        return out
    }

    public func count() throws -> Int {
        let st = try prepare("SELECT COUNT(*) FROM entry")
        defer { sqlite3_finalize(st) }
        _ = sqlite3_step(st)
        return Int(sqlite3_column_int(st, 0))
    }

    /// memory_search: cada palavra vira prefixo, todas precisam aparecer; ranking BM25. Texto livre nunca quebra a consulta FTS.
    public func search(_ query: String, limit: Int = 8) throws -> [AgentMemoryHit] {
        guard let match = Self.ftsQuery(query) else { return [] }
        let st = try prepare("""
            SELECT e.id, e.title, snippet(entry_fts, 1, '', '', '…', 14), e.created_at FROM entry_fts
            JOIN entry e ON e.id = entry_fts.rowid WHERE entry_fts MATCH ? ORDER BY bm25(entry_fts) LIMIT ?
            """)
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, match, -1, Self.transient)
        sqlite3_bind_int(st, 2, Int32(max(1, limit)))
        var out: [AgentMemoryHit] = []
        while sqlite3_step(st) == SQLITE_ROW {
            out.append(AgentMemoryHit(
                id: sqlite3_column_int64(st, 0), title: String(cString: sqlite3_column_text(st, 1)),
                snippet: String(cString: sqlite3_column_text(st, 2)), createdAt: Date(timeIntervalSince1970: sqlite3_column_double(st, 3))))
        }
        return out
    }

    static func ftsQuery(_ q: String) -> String? {
        let words = q.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        return words.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    /// Índice curto para o início da tarefa: uma linha por entrada (`#id título`), as mais recentes primeiro, dentro do limite
    /// de caracteres. Quando sobra entrada, a última linha diz quantas ficaram de fora.
    public func index(maxCharacters: Int = 1200) throws -> String {
        var lines: [String] = []
        var used = 0
        let entries = try all()
        for (i, e) in entries.enumerated() {
            let line = "#\(e.id) \(e.title.replacingOccurrences(of: "\n", with: " ").prefix(100))"
            if used + line.count + 1 > maxCharacters {
                lines.append("(+\(entries.count - i) older, use memory_search)")
                break
            }
            lines.append(line); used += line.count + 1
        }
        return lines.joined(separator: "\n")
    }

    /// Compactação periódica: as entradas além das `keepRecent` mais novas viram uma só (por `summarize`, que a UI liga ao modelo;
    /// por padrão junta os títulos). Devolve quantas entradas foram trocadas.
    @discardableResult
    public func compact(keepRecent: Int, summarize: @Sendable ([AgentMemoryEntry]) -> (title: String, body: String) = AgentMemoryStore.joinTitles) throws -> Int {
        let old = Array(try all().dropFirst(max(0, keepRecent)))
        guard old.count >= 2 else { return 0 }
        let s = summarize(old)
        try Self.exec(db, "BEGIN")
        do {
            try add(title: s.title, body: s.body, compacted: true)
            for e in old { try delete(id: e.id) }
            try Self.exec(db, "COMMIT")
        } catch {
            try? Self.exec(db, "ROLLBACK"); throw error
        }
        return old.count
    }

    public static let joinTitles: @Sendable ([AgentMemoryEntry]) -> (title: String, body: String) = { old in
        let sorted = old.sorted { $0.createdAt < $1.createdAt }
        return ("Compacted \(sorted.count) older entries", sorted.map { "- \($0.title): \($0.body)" }.joined(separator: "\n"))
    }

    // MARK: SQLite

    private static func entry(_ st: OpaquePointer?) -> AgentMemoryEntry {
        AgentMemoryEntry(
            id: sqlite3_column_int64(st, 0), createdAt: Date(timeIntervalSince1970: sqlite3_column_double(st, 1)),
            title: String(cString: sqlite3_column_text(st, 2)), body: String(cString: sqlite3_column_text(st, 3)),
            compacted: sqlite3_column_int(st, 4) != 0)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { throw AgentMemoryError.sqlFailed(String(cString: sqlite3_errmsg(db))) }
        return st
    }

    private func step(_ st: OpaquePointer?) throws {
        let rc = sqlite3_step(st)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw AgentMemoryError.sqlFailed(String(cString: sqlite3_errmsg(db))) }
    }

    private static func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "exec"
            sqlite3_free(err)
            throw AgentMemoryError.sqlFailed(msg)
        }
    }
}
