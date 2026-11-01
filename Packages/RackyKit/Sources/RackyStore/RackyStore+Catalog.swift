import Foundation
import GRDB

// Índice do catálogo por referência (`catalog_item`, 06 §4.1) e registro de importações (`import_run`, 08 AR-340).
// O banco guarda metadados e o hash do arquivo principal; corpo de skill/agente nunca entra aqui.

public struct CatalogRow: Sendable, Equatable {
    public var id: String
    public var source: String       // claude | codex | agents | opencode | plugin
    public var kind: String         // agent | skill | plugin | mcp | instructions
    public var scope: String        // user | project | plugin
    public var path: String
    public var name: String
    public var description: String?
    public var contentHash: String?
    public var clients: [String]
    public var mtime: Date?
    public var frontmatterJSON: String?
    public var parseError: String?
    public var shadowedBy: String?
    public var discoveredAt: Date
    public var missingAt: Date?

    public init(id: String, source: String, kind: String, scope: String, path: String, name: String, description: String?,
                contentHash: String?, clients: [String], mtime: Date?, frontmatterJSON: String?, parseError: String?,
                shadowedBy: String? = nil, discoveredAt: Date, missingAt: Date? = nil) {
        self.id = id; self.source = source; self.kind = kind; self.scope = scope; self.path = path; self.name = name
        self.description = description; self.contentHash = contentHash; self.clients = clients; self.mtime = mtime
        self.frontmatterJSON = frontmatterJSON; self.parseError = parseError; self.shadowedBy = shadowedBy
        self.discoveredAt = discoveredAt; self.missingAt = missingAt
    }

    init(row: Row) throws {
        id = row["id"]; source = row["source"]; kind = row["kind"]; scope = row["scope"]; path = row["path"]
        name = row["name"]; description = row["description"]; contentHash = row["content_hash"]
        clients = try RowCodec.decode([String].self, row["clients_json"] as String, table: "catalog_item")
        mtime = RowCodec.date(row["mtime"] as Int64?); frontmatterJSON = row["frontmatter_json"]
        parseError = row["parse_error"]; shadowedBy = row["shadowed_by"]
        discoveredAt = RowCodec.date(row["discovered_at"] as Int64); missingAt = RowCodec.date(row["missing_at"] as Int64?)
    }
}

public struct CatalogDiff: Sendable, Equatable {
    public var added: [String] = []
    public var changed: [String] = []
    public var removed: [String] = []
    public var isEmpty: Bool { added.isEmpty && changed.isEmpty && removed.isEmpty }
    public init(added: [String] = [], changed: [String] = [], removed: [String] = []) {
        self.added = added; self.changed = changed; self.removed = removed
    }
}

public struct ImportRunRow: Sendable, Equatable {
    public var id: UUID
    public var source: String       // racky_json | other | racky_cli
    public var sourcePath: String
    public var fingerprint: String?
    public var dryRun: Bool
    public var status: String
    public var summaryJSON: String
    public var startedAt: Date
    public var finishedAt: Date?
    public init(id: UUID = UUID(), source: String, sourcePath: String, fingerprint: String?, dryRun: Bool, status: String,
                summaryJSON: String, startedAt: Date, finishedAt: Date?) {
        self.id = id; self.source = source; self.sourcePath = sourcePath; self.fingerprint = fingerprint
        self.dryRun = dryRun; self.status = status; self.summaryJSON = summaryJSON
        self.startedAt = startedAt; self.finishedAt = finishedAt
    }
}

extension RackyStore {
    private static let catalogColumns = """
        id, source, kind, scope, path, name, description, content_hash, clients_json, mtime, frontmatter_json,
        parse_error, shadowed_by, discovered_at, missing_at
        """

    public func catalogItems(includeMissing: Bool = false) async throws -> [CatalogRow] {
        try await read { db in
            let sql = "SELECT \(Self.catalogColumns) FROM catalog_item \(includeMissing ? "" : "WHERE missing_at IS NULL") ORDER BY kind, name, path"
            return try Row.fetchAll(db, sql: sql).map(CatalogRow.init(row:))
        }
    }

    /// Reconcilia o índice com a varredura: upsert por `id`, e o que sumiu ganha `missing_at` (histórico preservado).
    /// Itens inalterados (mesmo hash, mtime, nome, erro e sombra) não são reescritos nem entram no diff.
    @discardableResult
    public func reconcileCatalog(_ scanned: [CatalogRow], at date: Date) async throws -> CatalogDiff {
        let now: Int64 = RowCodec.ms(date)
        return try await write { db in
            var diff = CatalogDiff()
            var existing: [String: CatalogRow] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT \(Self.catalogColumns) FROM catalog_item") {
                let r = try CatalogRow(row: row); existing[r.id] = r
            }
            var seen = Set<String>()
            for item in scanned {
                guard seen.insert(item.id).inserted else { continue }
                let clients = try RowCodec.json(item.clients)
                let mtime: Int64? = RowCodec.ms(item.mtime)
                if let old = existing[item.id] {
                    let same = old.missingAt == nil && old.contentHash == item.contentHash && old.name == item.name
                        && old.description == item.description && old.parseError == item.parseError
                        && old.shadowedBy == item.shadowedBy && old.clients == item.clients && old.frontmatterJSON == item.frontmatterJSON
                    if same { continue }
                    try db.execute(sql: """
                        UPDATE catalog_item SET source=?, kind=?, scope=?, path=?, name=?, description=?, content_hash=?,
                            clients_json=?, mtime=?, frontmatter_json=?, parse_error=?, shadowed_by=?, missing_at=NULL WHERE id=?
                        """, arguments: [item.source, item.kind, item.scope, item.path, item.name, item.description,
                                         item.contentHash, clients, mtime, item.frontmatterJSON, item.parseError,
                                         item.shadowedBy, item.id])
                    if old.missingAt != nil { diff.added.append(item.id) } else { diff.changed.append(item.id) }
                } else {
                    try db.execute(sql: """
                        INSERT INTO catalog_item(id, source, kind, scope, path, name, description, content_hash, clients_json,
                                                 mtime, frontmatter_json, parse_error, shadowed_by, discovered_at)
                        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                        """, arguments: [item.id, item.source, item.kind, item.scope, item.path, item.name, item.description,
                                         item.contentHash, clients, mtime, item.frontmatterJSON, item.parseError,
                                         item.shadowedBy, now])
                    diff.added.append(item.id)
                }
            }
            for (id, old) in existing where !seen.contains(id) && old.missingAt == nil {
                try db.execute(sql: "UPDATE catalog_item SET missing_at = ? WHERE id = ?", arguments: [now, id])
                diff.removed.append(id)
            }
            return diff
        }
    }

    // MARK: import_run

    public func recordImportRun(_ run: ImportRunRow) async throws {
        let id = run.id.uuidString
        let started: Int64 = RowCodec.ms(run.startedAt), finished: Int64? = RowCodec.ms(run.finishedAt)
        try await write { db in
            try db.execute(sql: """
                INSERT INTO import_run(id, source, source_path, source_fingerprint, dry_run, status, summary_json, started_at, finished_at)
                VALUES (?,?,?,?,?,?,?,?,?)
                """, arguments: [id, run.source, run.sourcePath, run.fingerprint, run.dryRun ? 1 : 0, run.status,
                                 run.summaryJSON, started, finished])
        }
    }

    public func importRuns(source: String? = nil) async throws -> [ImportRunRow] {
        try await read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, source, source_path, source_fingerprint, dry_run, status, summary_json, started_at, finished_at
                FROM import_run \(source == nil ? "" : "WHERE source = ?") ORDER BY started_at, id
                """, arguments: source.map { [$0] } ?? [])
            return try rows.map {
                ImportRunRow(id: try RowCodec.id($0["id"] as String, table: "import_run"), source: $0["source"],
                             sourcePath: $0["source_path"], fingerprint: $0["source_fingerprint"],
                             dryRun: ($0["dry_run"] as Int) == 1, status: $0["status"], summaryJSON: $0["summary_json"],
                             startedAt: RowCodec.date($0["started_at"] as Int64),
                             finishedAt: RowCodec.date($0["finished_at"] as Int64?))
            }
        }
    }

    // MARK: Auxiliares do importador (INSERT idempotente por chave)

    /// Grava a configuração só se a chave ainda não existe. `true` se gravou.
    public func setSettingIfAbsent(key: String, json: String, at date: Date) async throws -> Bool {
        let ms: Int64 = RowCodec.ms(date)
        return try await write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO setting(key, value_json, updated_at) VALUES (?,?,?)", arguments: [key, json, ms])
            return db.changesCount == 1
        }
    }

    public func settingJSON(_ key: String) async throws -> String? {
        try await read { try String.fetchOne($0, sql: "SELECT value_json FROM setting WHERE key = ?", arguments: [key]) }
    }
}
