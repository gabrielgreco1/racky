import Foundation
import GRDB

// Datasets v1 (`v10_datasets`): tabelas nomeadas que os subagentes de uma sessão preenchem. O store só guarda e deduplica; validação,
// coerção de tipos e hash da chave moram em RackyCore (`DatasetEngine`), que entrega as linhas já prontas (`DatasetRowInput`).

public enum DatasetColumnType: String, Sendable, Codable, CaseIterable {
    case string, integer, number, boolean, date, datetime, url, json
}

public struct DatasetColumn: Sendable, Codable, Equatable, Hashable {
    public var name: String
    public var type: DatasetColumnType
    public var required: Bool
    public init(name: String, type: DatasetColumnType = .string, required: Bool = false) {
        self.name = name; self.type = type; self.required = required
    }
}

public struct Dataset: Sendable, Equatable, Identifiable {
    /// ULID.
    public var id: String
    public var sessionID: UUID
    public var name: String
    public var columns: [DatasetColumn]
    /// Nomes das colunas da chave; vazio = a linha inteira é a chave.
    public var key: [String]
    public var createdAt: Date
    public var updatedAt: Date
    public init(id: String, sessionID: UUID, name: String, columns: [DatasetColumn], key: [String], createdAt: Date = Date(), updatedAt: Date? = nil) {
        self.id = id; self.sessionID = sessionID; self.name = name; self.columns = columns; self.key = key
        self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt
    }
}

/// Confiança da origem da linha: `observed` (o egress viu a página), `reported` (o agente disse) ou `none` (sem request id).
public enum DatasetTrust: String, Sendable, Codable, CaseIterable {
    case observed, reported, none
}

/// Linha pronta para o upsert (o core já validou e calculou `rowKey`).
public struct DatasetRowInput: Sendable, Equatable {
    public var rowKey: String
    /// Objeto JSON só com as colunas do dataset.
    public var data: String
    public var valid: Bool
    public var error: String?
    public var computer: String?
    public var runID: String?
    public var requestID: String?
    public var sourceURL: String?
    public var trust: DatasetTrust
    /// Pedido de rede citado (método, status e duração vindos do reqlog), para o painel da linha.
    public var request: DatasetRequestInfo?
    /// Problema principal de uma linha inválida, curto e agrupável ("price missing", "rating not a number").
    public var errorKind: String?

    public init(
        rowKey: String, data: String, valid: Bool = true, error: String? = nil, computer: String? = nil, runID: String? = nil,
        requestID: String? = nil, sourceURL: String? = nil, trust: DatasetTrust = .none, request: DatasetRequestInfo? = nil, errorKind: String? = nil
    ) {
        self.rowKey = rowKey; self.data = data; self.valid = valid; self.error = error; self.computer = computer; self.runID = runID
        self.requestID = requestID; self.sourceURL = sourceURL; self.trust = trust; self.request = request; self.errorKind = errorKind
    }
}

/// Método, status e duração do pedido de rede de onde a linha veio.
public struct DatasetRequestInfo: Sendable, Equatable, Codable {
    public var method: String?
    public var status: Int?
    public var milliseconds: Int?
    public init(method: String? = nil, status: Int? = nil, milliseconds: Int? = nil) { self.method = method; self.status = status; self.milliseconds = milliseconds }
}

/// Domínio de uma URL sem `www.` (a faceta "Source" agrupa por ele).
public func datasetHost(_ url: String?) -> String? {
    guard let url, let host = URL(string: url)?.host?.lowercased(), !host.isEmpty else { return nil }
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
}

public struct DatasetRow: Sendable, Equatable, Identifiable {
    public var id: String { rowKey }
    public var rowKey: String
    public var data: String
    public var valid: Bool
    public var error: String?
    public var computer: String?
    public var runID: String?
    public var requestID: String?
    public var sourceURL: String?
    public var trust: DatasetTrust
    public var request: DatasetRequestInfo?
    public var errorKind: String?
    public var firstSeen: Date
    public var lastSeen: Date
    public var seenCount: Int

    public init(
        rowKey: String, data: String, valid: Bool = true, error: String? = nil, computer: String? = nil, runID: String? = nil, requestID: String? = nil,
        sourceURL: String? = nil, trust: DatasetTrust = .none, request: DatasetRequestInfo? = nil, errorKind: String? = nil,
        firstSeen: Date, lastSeen: Date, seenCount: Int = 1
    ) {
        self.rowKey = rowKey; self.data = data; self.valid = valid; self.error = error; self.computer = computer; self.runID = runID
        self.requestID = requestID; self.sourceURL = sourceURL; self.trust = trust; self.request = request; self.errorKind = errorKind
        self.firstSeen = firstSeen; self.lastSeen = lastSeen; self.seenCount = seenCount
    }
}

/// Uma faixa do gráfico de volume: quantas linhas novas chegaram a partir de `start`.
public struct DatasetActivityBucket: Sendable, Equatable {
    public var start: Date
    public var valid: Int
    public var invalid: Int
}

public struct DatasetUpsertCounts: Sendable, Equatable {
    public var inserted = 0
    public var updated = 0
    public var duplicate = 0
    public init(inserted: Int = 0, updated: Int = 0, duplicate: Int = 0) { self.inserted = inserted; self.updated = updated; self.duplicate = duplicate }
}

/// Uma linha da lista de datasets (contagens vêm de uma consulta só).
public struct DatasetSummary: Sendable, Equatable, Identifiable {
    public var dataset: Dataset
    public var rowCount: Int
    public var invalidCount: Int
    public var id: String { dataset.id }
    public init(dataset: Dataset, rowCount: Int, invalidCount: Int) { self.dataset = dataset; self.rowCount = rowCount; self.invalidCount = invalidCount }
}

public enum DatasetRowFilter: String, Sendable, CaseIterable {
    case all, invalid
}

extension Dataset {
    fileprivate init(row: Row) throws {
        guard let session = UUID(uuidString: row["session_id"] as String) else { throw StoreError.invalidRow(table: "dataset", detail: "bad session id") }
        self.init(
            id: row["id"], sessionID: session, name: row["name"],
            columns: try RowCodec.decode([DatasetColumn].self, row["columns"], table: "dataset"),
            key: try RowCodec.decode([String].self, row["key"], table: "dataset"),
            createdAt: RowCodec.date(row["created_at"] as Int64), updatedAt: RowCodec.date(row["updated_at"] as Int64) as Date)
    }
}

extension DatasetRow {
    fileprivate init(row: Row) throws {
        let trust = row["trust"] as String? ?? "none"
        guard let parsed = DatasetTrust(rawValue: trust) else { throw StoreError.invalidRow(table: "dataset_row", detail: "bad trust \(trust)") }
        self.init(
            rowKey: row["row_key"], data: row["data"], valid: (row["valid"] as Int) == 1, error: row["error"], computer: row["computer"],
            runID: row["run_id"], requestID: row["request_id"], sourceURL: row["source_url"], trust: parsed,
            request: (row["request_method"] as String?) == nil && (row["request_status"] as Int?) == nil ? nil
                : DatasetRequestInfo(method: row["request_method"], status: row["request_status"], milliseconds: row["request_ms"]),
            errorKind: row["error_kind"],
            firstSeen: RowCodec.date(row["first_seen"] as Int64), lastSeen: RowCodec.date(row["last_seen"] as Int64), seenCount: row["seen_count"])
    }
}

/// `LIKE` sem curinga: escapa `%`, `_` e a barra (o `ESCAPE '\\'` vem na consulta).
private func likePattern(_ text: String) -> String {
    let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    return "%" + escaped + "%"
}

extension RackyStore {
    // MARK: Esquema

    public func createDataset(_ dataset: Dataset) async throws {
        let columns = try RowCodec.json(dataset.columns), key = try RowCodec.json(dataset.key)
        try await write { db in
            try db.execute(
                sql: "INSERT INTO dataset (id, session_id, name, columns, key, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
                arguments: [dataset.id, dataset.sessionID.uuidString, dataset.name, columns, key, RowCodec.ms(dataset.createdAt) as Int64, RowCodec.ms(dataset.updatedAt) as Int64])
        }
    }

    /// Troca colunas e chave (o core decide o que pode mudar; o store só grava).
    public func updateDatasetSchema(id: String, columns: [DatasetColumn], key: [String], at date: Date? = nil) async throws {
        let columns = try RowCodec.json(columns), key = try RowCodec.json(key)
        let ms = RowCodec.ms(date ?? clock()) as Int64
        try await write { db in
            try db.execute(sql: "UPDATE dataset SET columns = ?, key = ?, updated_at = ? WHERE id = ?", arguments: [columns, key, ms, id])
        }
    }

    public func dataset(id: String) async throws -> Dataset? {
        try await read { db in try Row.fetchOne(db, sql: "SELECT * FROM dataset WHERE id = ?", arguments: [id]).map { try Dataset(row: $0) } }
    }

    public func dataset(sessionID: UUID, name: String) async throws -> Dataset? {
        let session = sessionID.uuidString
        return try await read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM dataset WHERE session_id = ? AND name = ?", arguments: [session, name]).map { try Dataset(row: $0) }
        }
    }

    /// Resumos (com contagens) de todos os datasets, ou só os de uma sessão; os mais recentes primeiro.
    public func datasetSummaries(sessionID: UUID? = nil) async throws -> [DatasetSummary] {
        let session = sessionID?.uuidString
        return try await read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT d.*, COUNT(r.row_key) AS row_count, COALESCE(SUM(1 - r.valid), 0) AS invalid_count FROM dataset d
                LEFT JOIN dataset_row r ON r.dataset_id = d.id
                WHERE (?1 IS NULL OR d.session_id = ?1) GROUP BY d.id ORDER BY d.updated_at DESC, d.id DESC
                """, arguments: [session]
            ).map { DatasetSummary(dataset: try Dataset(row: $0), rowCount: $0["row_count"], invalidCount: $0["invalid_count"]) }
        }
    }

    /// O resumo de um dataset só (antes somava as linhas de todos os datasets para ler um, a cada segundo).
    public func datasetSummary(id: String) async throws -> DatasetSummary? {
        try await read { db in
            try Row.fetchOne(
                db,
                sql: """
                SELECT d.*, COUNT(r.row_key) AS row_count, COALESCE(SUM(1 - r.valid), 0) AS invalid_count FROM dataset d
                LEFT JOIN dataset_row r ON r.dataset_id = d.id
                WHERE d.id = ?1 GROUP BY d.id
                """, arguments: [id]
            ).map { DatasetSummary(dataset: try Dataset(row: $0), rowCount: $0["row_count"], invalidCount: $0["invalid_count"]) }
        }
    }

    // MARK: Linhas

    /// Upsert por `rowKey` numa transação: igual = `duplicate` (só `last_seen` e `seen_count`), dado diferente = `updated`
    /// (troca dado, validade e proveniência; mantém `first_seen`), chave nova = `inserted`.
    public func upsertDatasetRows(datasetID: String, rows: [DatasetRowInput], at date: Date? = nil) async throws -> DatasetUpsertCounts {
        let now = RowCodec.ms(date ?? clock()) as Int64
        return try await write { db in
            var counts = DatasetUpsertCounts()
            for row in rows {
                let existing = try Row.fetchOne(db, sql: "SELECT data, valid, error FROM dataset_row WHERE dataset_id = ? AND row_key = ?", arguments: [datasetID, row.rowKey])
                if let existing {
                    let same = (existing["data"] as String) == row.data && ((existing["valid"] as Int) == 1) == row.valid
                    if same {
                        try db.execute(
                            sql: "UPDATE dataset_row SET last_seen = ?, seen_count = seen_count + 1 WHERE dataset_id = ? AND row_key = ?", arguments: [now, datasetID, row.rowKey])
                        counts.duplicate += 1
                    } else {
                        try db.execute(
                            sql: """
                            UPDATE dataset_row SET data = ?, valid = ?, error = ?, computer = ?, run_id = ?, request_id = ?, source_url = ?, source_host = ?,
                                trust = ?, request_method = ?, request_status = ?, request_ms = ?, error_kind = ?,
                                last_seen = ?, seen_count = seen_count + 1 WHERE dataset_id = ? AND row_key = ?
                            """,
                            arguments: [
                                row.data, row.valid ? 1 : 0, row.error, row.computer, row.runID, row.requestID, row.sourceURL, datasetHost(row.sourceURL),
                                row.trust.rawValue, row.request?.method, row.request?.status, row.request?.milliseconds, row.errorKind, now, datasetID, row.rowKey,
                            ])
                        counts.updated += 1
                    }
                } else {
                    try db.execute(
                        sql: """
                        INSERT INTO dataset_row (dataset_id, row_key, data, valid, error, computer, run_id, request_id, source_url, source_host, trust,
                            request_method, request_status, request_ms, error_kind, first_seen, last_seen, seen_count)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
                        """,
                        arguments: [
                            datasetID, row.rowKey, row.data, row.valid ? 1 : 0, row.error, row.computer, row.runID, row.requestID, row.sourceURL,
                            datasetHost(row.sourceURL), row.trust.rawValue, row.request?.method, row.request?.status, row.request?.milliseconds, row.errorKind, now, now,
                        ])
                    counts.inserted += 1
                }
            }
            if !rows.isEmpty { try db.execute(sql: "UPDATE dataset SET updated_at = ? WHERE id = ?", arguments: [now, datasetID]) }
            return counts
        }
    }

    /// Linhas por ordem de chegada (`rowid`; `newestFirst` inverte, para a tabela viva), com filtro de validade e busca de texto no dado e na URL de origem.
    public func datasetRows(
        datasetID: String, filter: DatasetRowFilter = .all, search: String? = nil, limit: Int = 1000, offset: Int = 0, newestFirst: Bool = false
    ) async throws -> [DatasetRow] {
        try await read { db in
            var sql = "SELECT * FROM dataset_row WHERE dataset_id = ?"
            var arguments: StatementArguments = [datasetID]
            if filter == .invalid { sql += " AND valid = 0" }
            if let search, !search.isEmpty {
                sql += " AND (data LIKE ? ESCAPE '\\' OR COALESCE(source_url, '') LIKE ? ESCAPE '\\')"
                arguments += [likePattern(search), likePattern(search)]
            }
            sql += newestFirst ? " ORDER BY rowid DESC LIMIT ? OFFSET ?" : " ORDER BY rowid LIMIT ? OFFSET ?"
            arguments += [limit, offset]
            return try Row.fetchAll(db, sql: sql, arguments: arguments).map { try DatasetRow(row: $0) }
        }
    }

    /// Total que casa o filtro e a busca (a paginação da UI e o "n of m").
    public func datasetRowCount(datasetID: String, filter: DatasetRowFilter = .all, search: String? = nil) async throws -> Int {
        try await read { db in
            var sql = "SELECT COUNT(*) FROM dataset_row WHERE dataset_id = ?"
            var arguments: StatementArguments = [datasetID]
            if filter == .invalid { sql += " AND valid = 0" }
            if let search, !search.isEmpty {
                sql += " AND (data LIKE ? ESCAPE '\\' OR COALESCE(source_url, '') LIKE ? ESCAPE '\\')"
                arguments += [likePattern(search), likePattern(search)]
            }
            return try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0
        }
    }

    /// Linhas novas por faixa de tempo (`first_seen`), separadas em válidas e inválidas: o gráfico de volume da página do dataset.
    /// Devolve exatamente `buckets` faixas de `bucket` segundos terminando em `until`, as vazias com zero.
    /// Linhas novas por faixa; com `query`, só as que casam o filtro (o gráfico acompanha a tabela).
    public func datasetActivity(datasetID: String, until: Date, bucket: TimeInterval, buckets: Int, query: DatasetQuery? = nil) async throws -> [DatasetActivityBucket] {
        let width = max(Int64(bucket * 1000), 1)
        let end = RowCodec.ms(until)
        let start = end - width * Int64(buckets)
        let counted = try await read { db in
            var filter = DatasetQuery.all
            if let query { filter = query; filter.since = nil }
            let (clauses, filterArguments) = datasetWhere(datasetID: datasetID, query: filter, skipping: nil)
            var arguments: StatementArguments = [start, width]
            arguments += filterArguments
            arguments += [start, end]
            return try Row.fetchAll(
                db,
                sql: """
                    SELECT (first_seen - ?) / ? AS slot, SUM(valid) AS valid, SUM(1 - valid) AS invalid FROM dataset_row
                    WHERE \(clauses) AND first_seen >= ? AND first_seen < ? GROUP BY slot
                    """,
                arguments: arguments
            ).map { (Int($0["slot"] as Int64), $0["valid"] as Int, $0["invalid"] as Int) }
        }
        var result = (0..<buckets).map { DatasetActivityBucket(start: RowCodec.date(start + width * Int64($0)), valid: 0, invalid: 0) }
        for (slot, valid, invalid) in counted where slot >= 0 && slot < buckets {
            result[slot].valid = valid
            result[slot].invalid = invalid
        }
        return result
    }

    public func datasetRow(datasetID: String, rowKey: String) async throws -> DatasetRow? {
        try await read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM dataset_row WHERE dataset_id = ? AND row_key = ?", arguments: [datasetID, rowKey]).map { try DatasetRow(row: $0) }
        }
    }

    public func deleteDataset(id: String) async throws {
        try await write { db in try db.execute(sql: "DELETE FROM dataset WHERE id = ?", arguments: [id]) }
    }
}

// MARK: Consulta da página do dataset (facetas, condições por coluna, período)

/// Comparação de uma condição `coluna:op valor` da barra de consulta.
public enum DatasetComparison: String, Sendable, Equatable {
    case equals = "=", notEquals = "!=", greater = ">", greaterOrEqual = ">=", less = "<", lessOrEqual = "<=", contains = "~"
}

/// Uma condição sobre o valor de uma coluna (`price:>200`, `name:~plaza`).
public struct DatasetCondition: Sendable, Equatable {
    public var column: String
    public var comparison: DatasetComparison
    public var value: String
    public init(column: String, comparison: DatasetComparison, value: String) { self.column = column; self.comparison = comparison; self.value = value }
}

/// Faceta da coluna da esquerda.
public enum DatasetFacet: String, Sendable, CaseIterable {
    case status, computer, source, evidence, error
}

/// O que a página pede ao store: facetas desmarcadas (status, computador, site, evidência), tipos de erro escolhidos (vazio = todos),
/// texto livre, condições por coluna e desde quando (`first_seen`).
public struct DatasetQuery: Sendable, Equatable {
    /// Valores desmarcados por faceta (`status` usa `valid` / `invalid`; `evidence` usa os valores de `DatasetTrust`).
    public var excluded: [DatasetFacet: Set<String>] = [:]
    /// Só linhas com um destes tipos de erro (faceta `error`); vazio = sem filtro.
    public var errorKinds: Set<String> = []
    public var text = ""
    public var conditions: [DatasetCondition] = []
    public var since: Date?
    /// Limite superior exclusivo de `first_seen` (janela escolhida no gráfico).
    public var until: Date?

    public init(
        excluded: [DatasetFacet: Set<String>] = [:], errorKinds: Set<String> = [], text: String = "", conditions: [DatasetCondition] = [], since: Date? = nil,
        until: Date? = nil
    ) {
        self.excluded = excluded; self.errorKinds = errorKinds; self.text = text; self.conditions = conditions; self.since = since; self.until = until
    }

    public static let all = DatasetQuery()
}

/// Uma linha da faceta: valor e quantas linhas (já com texto, condições e período aplicados).
public struct DatasetFacetCount: Sendable, Equatable, Identifiable {
    public var value: String
    public var count: Int
    public var id: String { value }
    public init(value: String, count: Int) { self.value = value; self.count = count }
}

/// Um site e quantas linhas vieram dele.
public struct DatasetHostCount: Sendable, Equatable {
    public var host: String
    public var rows: Int
    public init(host: String, rows: Int) { self.host = host; self.rows = rows }
}

/// Um valor de coluna e quantas linhas o têm.
public struct DatasetValueCount: Sendable, Equatable {
    public var value: String
    public var count: Int
    public init(value: String, count: Int) { self.value = value; self.count = count }
}

/// Perfil de uma coluna (com a consulta aplicada, menos as condições da própria coluna).
public struct DatasetColumnProfile: Sendable, Equatable {
    public var filled = 0
    public var distinct = 0
    /// Só texto/url/booleano com poucos valores distintos (≤ 30); os 8 mais frequentes.
    public var topValues: [DatasetValueCount] = []
    public var min: Double?
    public var max: Double?
    /// 24 faixas iguais entre `min` e `max` (numéricas); vazio nas outras.
    public var histogram: [Int] = []
    public init(filled: Int = 0, distinct: Int = 0, topValues: [DatasetValueCount] = [], min: Double? = nil, max: Double? = nil, histogram: [Int] = []) {
        self.filled = filled; self.distinct = distinct; self.topValues = topValues; self.min = min; self.max = max; self.histogram = histogram
    }
}

/// Números do topo da página.
public struct DatasetStats: Sendable, Equatable {
    public var rows = 0
    public var invalid = 0
    public var computers = 0
    /// Células preenchidas / células esperadas, de 0 a 1 (linhas × colunas).
    public var filled: Double = 0
    /// Linhas que chegaram de novo e foram fundidas pela chave (`seen_count - 1` somado).
    public var duplicatesMerged = 0
    /// Chegada da linha mais antiga (o começo do gráfico em "All time").
    public var firstSeen: Date?
    /// Chegada da linha mais nova ("last row 3m ago").
    public var lastSeen: Date?
    /// Linhas que chegaram desde `recentSince` (o "+12 in 5 min" do topo).
    public var recent = 0
    /// Requisições distintas que deram linhas, as que voltaram com status ≥ 400 e o tempo médio delas (ms).
    public var requests = 0
    public var failedRequests = 0
    public var averageRequestMs: Int?
    /// Sites distintos das linhas.
    public var hosts = 0
    /// Preenchimento de cada coluna, de 0 a 1 (a coluna mais fraca aparece no topo).
    public var columnFill: [String: Double] = [:]
    /// Requisições distintas por classe de status (2, 3, 4, 5 = 2xx..5xx); linhas sem status ficam de fora.
    public var requestStatus: [Int: Int] = [:]
    /// Os 5 sites com mais linhas.
    public var topHosts: [DatasetHostCount] = []

    public init(rows: Int = 0, invalid: Int = 0, computers: Int = 0, filled: Double = 0, duplicatesMerged: Int = 0, firstSeen: Date? = nil) {
        self.rows = rows; self.invalid = invalid; self.computers = computers; self.filled = filled; self.duplicatesMerged = duplicatesMerged
        self.firstSeen = firstSeen
    }

    /// A coluna menos preenchida, quando alguma não está completa.
    public var weakestColumn: (name: String, fill: Double)? {
        columnFill.filter { $0.value < 1 }.min { ($0.value, $0.key) < ($1.value, $1.key) }.map { ($0.key, $0.value) }
    }

    public static func == (a: DatasetStats, b: DatasetStats) -> Bool {
        a.rows == b.rows && a.invalid == b.invalid && a.computers == b.computers && a.filled == b.filled && a.duplicatesMerged == b.duplicatesMerged
            && a.firstSeen == b.firstSeen && a.lastSeen == b.lastSeen && a.recent == b.recent && a.requests == b.requests
            && a.failedRequests == b.failedRequests && a.averageRequestMs == b.averageRequestMs && a.hosts == b.hosts && a.columnFill == b.columnFill
            && a.requestStatus == b.requestStatus && a.topHosts == b.topHosts
    }
}

extension RackyStore {
    /// Linhas da página atual (mais nova primeiro) para a consulta.
    public func datasetRows(datasetID: String, query: DatasetQuery, limit: Int, offset: Int) async throws -> [DatasetRow] {
        try await read { db in
            var (sql, arguments) = datasetWhere(datasetID: datasetID, query: query, skipping: nil)
            sql = "SELECT * FROM dataset_row WHERE " + sql + " ORDER BY rowid DESC LIMIT ? OFFSET ?"
            arguments += [limit, offset]
            return try Row.fetchAll(db, sql: sql, arguments: arguments).map { try DatasetRow(row: $0) }
        }
    }

    public func datasetRowCount(datasetID: String, query: DatasetQuery) async throws -> Int {
        try await read { db in
            let (sql, arguments) = datasetWhere(datasetID: datasetID, query: query, skipping: nil)
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM dataset_row WHERE " + sql, arguments: arguments) ?? 0
        }
    }

    /// Contagens de cada faceta com o resto da consulta aplicado, menos a própria faceta (como no Datadog: desmarcar um valor não zera
    /// a contagem dele).
    public func datasetFacets(datasetID: String, query: DatasetQuery) async throws -> [DatasetFacet: [DatasetFacetCount]] {
        try await read { db in
            var result: [DatasetFacet: [DatasetFacetCount]] = [:]
            for facet in DatasetFacet.allCases {
                let (sql, arguments) = datasetWhere(datasetID: datasetID, query: query, skipping: facet)
                let column: String
                switch facet {
                case .status: column = "CASE valid WHEN 1 THEN 'valid' ELSE 'invalid' END"
                case .computer: column = "computer"
                case .source: column = "source_host"
                case .evidence: column = "trust"
                case .error: column = "error_kind"
                }
                let extra = facet == .error ? " AND error_kind IS NOT NULL" : " AND \(column) IS NOT NULL"
                let rows = try Row.fetchAll(
                    db, sql: "SELECT \(column) AS value, COUNT(*) AS n FROM dataset_row WHERE \(sql)\(extra) GROUP BY value ORDER BY n DESC, value LIMIT 50",
                    arguments: arguments)
                result[facet] = rows.map { DatasetFacetCount(value: $0["value"], count: $0["n"]) }
            }
            return result
        }
    }

    /// Perfil de cada coluna com a consulta aplicada, menos as condições da própria coluna (como as facetas com a delas).
    public func datasetColumnProfiles(datasetID: String, columns: [DatasetColumn], query: DatasetQuery) async throws -> [String: DatasetColumnProfile] {
        try await read { db in
            var result: [String: DatasetColumnProfile] = [:]
            for column in columns {
                let (clauses, base) = datasetWhere(datasetID: datasetID, query: query, skipping: nil, skippingColumn: column.name)
                let path = jsonPath(column.name)
                let present = "json_extract(data, ?) IS NOT NULL AND json_extract(data, ?) != ''"
                var profile = DatasetColumnProfile()
                var withPresent = base
                withPresent += [path, path]
                guard let counts = try Row.fetchOne(
                    db, sql: "SELECT COUNT(*) AS filled, COUNT(DISTINCT json_extract(data, ?)) AS distinct_n FROM dataset_row WHERE \(clauses) AND \(present)",
                    arguments: StatementArguments([path]) + withPresent)
                else { result[column.name] = profile; continue }
                profile.filled = counts["filled"]
                profile.distinct = counts["distinct_n"]
                switch column.type {
                case .string, .url, .boolean:
                    if profile.distinct > 0, profile.distinct <= 30 {
                        profile.topValues = try Row.fetchAll(
                            db, sql: """
                                SELECT CAST(json_extract(data, ?) AS TEXT) AS value, COUNT(*) AS n FROM dataset_row WHERE \(clauses) AND \(present)
                                GROUP BY value ORDER BY n DESC, value LIMIT 8
                                """, arguments: StatementArguments([path]) + withPresent
                        ).map { DatasetValueCount(value: $0["value"], count: $0["n"]) }
                    }
                case .integer, .number:
                    var numeric = base
                    numeric += [path]
                    let values = try Double.fetchAll(
                        db, sql: "SELECT CAST(json_extract(data, ?) AS REAL) FROM dataset_row WHERE \(clauses) AND json_type(data, ?) IN ('integer', 'real')",
                        arguments: StatementArguments([path]) + numeric)
                    if let low = values.min(), let high = values.max() {
                        profile.min = low
                        profile.max = high
                        var bins = [Int](repeating: 0, count: 24)
                        for value in values {
                            let slot = high == low ? 0 : Swift.min(23, Int((value - low) / (high - low) * 24))
                            bins[slot] += 1
                        }
                        profile.histogram = bins
                    }
                default: break
                }
                result[column.name] = profile
            }
            return result
        }
    }

    /// Números do topo: linhas, inválidas, computadores, preenchimento e duplicadas fundidas (dataset inteiro, sem filtro).
    public func datasetStats(datasetID: String, columns: [String], recentSince: Date? = nil) async throws -> DatasetStats {
        try await read { db in
            var sql = """
                SELECT COUNT(*) AS rows, COALESCE(SUM(1 - valid), 0) AS invalid, COUNT(DISTINCT computer) AS computers,
                COALESCE(SUM(seen_count - 1), 0) AS dups, MIN(first_seen) AS first, MAX(first_seen) AS last,
                COALESCE(SUM(first_seen >= ?), 0) AS recent, COUNT(DISTINCT request_id) AS requests,
                COUNT(DISTINCT CASE WHEN request_status >= 400 THEN request_id END) AS failed, COUNT(DISTINCT source_host) AS hosts
                """
            var arguments: StatementArguments = [RowCodec.ms(recentSince ?? .distantFuture) as Int64]
            for (index, column) in columns.enumerated() {
                sql += ", COALESCE(SUM(json_extract(data, ?) IS NOT NULL AND json_extract(data, ?) != ''), 0) AS c\(index)"
                arguments += [jsonPath(column), jsonPath(column)]
            }
            sql += " FROM dataset_row WHERE dataset_id = ?"
            arguments += [datasetID]
            guard let row = try Row.fetchOne(db, sql: sql, arguments: arguments) else { return DatasetStats() }
            let rows: Int = row["rows"]
            var cells = 0
            var columnFill: [String: Double] = [:]
            for (index, column) in columns.enumerated() {
                let count: Int = row["c\(index)"]
                cells += count
                columnFill[column] = rows == 0 ? 0 : Double(count) / Double(rows)
            }
            let expected = rows * columns.count
            var stats = DatasetStats(
                rows: rows, invalid: row["invalid"], computers: row["computers"], filled: expected == 0 ? 0 : Double(cells) / Double(expected),
                duplicatesMerged: row["dups"], firstSeen: RowCodec.date(row["first"] as Int64?))
            stats.lastSeen = RowCodec.date(row["last"] as Int64?)
            stats.recent = row["recent"]
            stats.requests = row["requests"]
            stats.failedRequests = row["failed"]
            stats.hosts = row["hosts"]
            stats.columnFill = columnFill
            // Tempo médio por requisição (cada requisição conta uma vez, não uma por linha).
            let average = try Double.fetchOne(
                db, sql: """
                    SELECT AVG(ms) FROM (SELECT MAX(request_ms) AS ms FROM dataset_row
                    WHERE dataset_id = ? AND request_id IS NOT NULL AND request_ms IS NOT NULL GROUP BY request_id)
                    """, arguments: [datasetID])
            stats.averageRequestMs = average.map { Int($0.rounded()) }
            for status in try Row.fetchAll(
                db, sql: """
                    SELECT request_status / 100 AS klass, COUNT(DISTINCT request_id) AS n FROM dataset_row
                    WHERE dataset_id = ? AND request_status IS NOT NULL AND request_id IS NOT NULL GROUP BY klass
                    """, arguments: [datasetID])
            {
                stats.requestStatus[status["klass"]] = status["n"]
            }
            stats.topHosts = try Row.fetchAll(
                db, sql: """
                    SELECT source_host AS host, COUNT(*) AS n FROM dataset_row WHERE dataset_id = ? AND source_host IS NOT NULL
                    GROUP BY source_host ORDER BY n DESC, host LIMIT 5
                    """, arguments: [datasetID]
            ).map { DatasetHostCount(host: $0["host"], rows: $0["n"]) }
            return stats
        }
    }
}

/// Caminho JSON de uma coluna (`$."nome"`), sempre passado como argumento da consulta.
private func jsonPath(_ column: String) -> String { "$.\"" + column.replacingOccurrences(of: "\"", with: "\\\"") + "\"" }

/// Cláusula `WHERE` da consulta; `skipping` deixa uma faceta de fora (para contar os valores dela).
private func datasetWhere(datasetID: String, query: DatasetQuery, skipping: DatasetFacet?, skippingColumn: String? = nil) -> (String, StatementArguments) {
    var clauses = ["dataset_id = ?"]
    var arguments: StatementArguments = [datasetID]
    func excludedValues(_ facet: DatasetFacet) -> [String] { facet == skipping ? [] : (query.excluded[facet] ?? []).sorted() }
    let status = excludedValues(.status)
    if status.contains("valid") { clauses.append("valid = 0") }
    if status.contains("invalid") { clauses.append("valid = 1") }
    for (facet, column) in [(DatasetFacet.computer, "computer"), (.source, "source_host"), (.evidence, "trust")] {
        let values = excludedValues(facet)
        guard !values.isEmpty else { continue }
        clauses.append("COALESCE(\(column), '') NOT IN (" + values.map { _ in "?" }.joined(separator: ", ") + ")")
        for value in values { arguments += [value] }
    }
    if skipping != .error, !query.errorKinds.isEmpty {
        let kinds = query.errorKinds.sorted()
        clauses.append("error_kind IN (" + kinds.map { _ in "?" }.joined(separator: ", ") + ")")
        for kind in kinds { arguments += [kind] }
    }
    let text = query.text.trimmingCharacters(in: .whitespaces)
    if !text.isEmpty {
        clauses.append("(data LIKE ? ESCAPE '\\' OR COALESCE(source_url, '') LIKE ? ESCAPE '\\')")
        arguments += [likePattern(text), likePattern(text)]
    }
    for condition in query.conditions where condition.column != skippingColumn {
        let path = jsonPath(condition.column)
        if condition.comparison == .contains {
            clauses.append("CAST(json_extract(data, ?) AS TEXT) LIKE ? ESCAPE '\\'")
            arguments += [path, likePattern(condition.value)]
        } else if let number = Double(condition.value) {
            clauses.append("CAST(json_extract(data, ?) AS REAL) \(condition.comparison.rawValue) ? AND json_type(data, ?) IN ('integer', 'real')")
            arguments += [path, number, path]
        } else {
            clauses.append("CAST(json_extract(data, ?) AS TEXT) \(condition.comparison.rawValue) ? COLLATE NOCASE")
            arguments += [path, condition.value]
        }
    }
    if let since = query.since {
        clauses.append("first_seen >= ?")
        arguments += [RowCodec.ms(since)]
    }
    if let until = query.until {
        clauses.append("first_seen < ?")
        arguments += [RowCodec.ms(until)]
    }
    return (clauses.joined(separator: " AND "), arguments)
}
