import Foundation
import RackyStore

/// De onde vem uma linha: o computador e o run de quem anexou, e como achar um request id no reqlog dele.
public struct DatasetProvenance: Sendable {
    public struct Request: Sendable, Equatable {
        public var url: String?
        public var trust: DatasetTrust
        public var info: DatasetRequestInfo?
        public init(url: String?, trust: DatasetTrust, info: DatasetRequestInfo? = nil) { self.url = url; self.trust = trust; self.info = info }
    }

    public var computer: String?
    public var runID: String?
    /// Procura o id no `requests.jsonl` deste computador; `nil` = não existe.
    public var lookup: @Sendable (String) -> Request?

    public init(computer: String? = nil, runID: String? = nil, lookup: @escaping @Sendable (String) -> Request? = { _ in nil }) {
        self.computer = computer; self.runID = runID; self.lookup = lookup
    }

    public static let none = DatasetProvenance()
}

/// As quatro operações de dataset (define, append, import, read) mais a lista do pai, em cima do `RackyStore`. As ferramentas MCP e os
/// testes falam com isto; erros saem como `ToolError` (o conjunto fechado de códigos).
public struct DatasetService: Sendable {
    public let store: RackyStore
    public init(store: RackyStore) { self.store = store }

    // MARK: define

    public func define(session: UUID, name: String, columns: [DatasetColumn], key: [String]?) async throws -> JSON {
        try Self.requireName(name)
        if let problem = DatasetEngine.schemaProblem(columns: columns, key: key ?? []) { throw ToolError.invalid(problem) }
        var created = false
        let result: Dataset
        if let existing = try await store.dataset(sessionID: session, name: name) {
            let hasRows = try await store.datasetRowCount(datasetID: existing.id) > 0
            switch DatasetEngine.evolve(existing: existing, columns: columns, key: key, hasRows: hasRows) {
            case .failure(let error): throw ToolError.invalid(error.message)
            case .success(let schema):
                if schema.columns != existing.columns || schema.key != existing.key {
                    try await store.updateDatasetSchema(id: existing.id, columns: schema.columns, key: schema.key)
                }
                result = Dataset(id: existing.id, sessionID: session, name: name, columns: schema.columns, key: schema.key, createdAt: existing.createdAt)
            }
        } else {
            result = Dataset(id: ULID.generate(), sessionID: session, name: name, columns: columns, key: key ?? [])
            try await store.createDataset(result)
            created = true
        }
        let total = try await store.datasetRowCount(datasetID: result.id)
        return ["dataset": .string(name), "created": .bool(created), "columns": Self.columnsJSON(result.columns), "key": .array(result.key.map { .string($0) }), "total_rows": .int(total)]
    }

    // MARK: append

    public func append(session: UUID, name: String, rows: [[String: JSON]], provenance: DatasetProvenance) async throws -> JSON {
        try Self.requireName(name)
        guard rows.count <= DatasetEngine.maxRowsPerAppend else {
            throw ToolError.invalid("at most \(DatasetEngine.maxRowsPerAppend) rows per call (got \(rows.count)); send batches of up to 500")
        }
        var warnings: [String] = []
        var createdNote: JSON?
        let dataset: Dataset
        if let existing = try await store.dataset(sessionID: session, name: name) {
            dataset = existing
        } else {
            guard let first = rows.first else { throw ToolError(.notFound, "no dataset named \(name); call dataset_define or send at least one row") }
            let columns = DatasetEngine.inferColumns(from: first)
            guard !columns.isEmpty else { throw ToolError.invalid("cannot infer columns from the first row; call dataset_define first") }
            dataset = Dataset(id: ULID.generate(), sessionID: session, name: name, columns: columns, key: [])
            try await store.createDataset(dataset)
            createdNote = ["columns": Self.columnsJSON(columns), "key": []]
            warnings.append("dataset \(name) did not exist: created it with columns inferred from the first row (\(columns.map(\.name).joined(separator: ", "))) and no key, so a row is a duplicate only when every column matches; call dataset_define to set types and a key")
        }
        let outcome = try await upsert(rows: rows.map { ProcessInput(raw: $0, line: nil) }, into: dataset, provenance: provenance, warnings: warnings)
        var json = outcome.json(name: name)
        if let createdNote, case .object(var object) = json {
            object["created"] = true
            object["inferred"] = createdNote
            json = .object(object)
        }
        return json
    }

    // MARK: import

    /// `parsed` vem de `DatasetImportParser`. Proveniência: `trust: none`, `source_url` da coluna `url` quando existe.
    public func importRows(session: UUID, name: String, parsed: ParsedImport, format: DatasetImportFormat, provenance: DatasetProvenance) async throws -> JSON {
        try Self.requireName(name)
        var warnings: [String] = []
        var createdNote: JSON?
        let dataset: Dataset
        if let existing = try await store.dataset(sessionID: session, name: name) {
            dataset = existing
        } else {
            let columns: [DatasetColumn]
            if format == .csv {
                columns = parsed.columns.map { DatasetColumn(name: $0) }
            } else if let first = parsed.rows.compactMap({ if case .row(let r) = $0 { r } else { nil } }).first {
                // Várias linhas dão colunas melhores: junta as chaves de todas, com o tipo da primeira linha em que a coluna aparece.
                var seen = DatasetEngine.inferColumns(from: first)
                for case .row(let row) in parsed.rows {
                    for column in DatasetEngine.inferColumns(from: row) where !seen.contains(where: { $0.name == column.name }) { seen.append(column) }
                }
                columns = seen.sorted { $0.name < $1.name }
            } else {
                throw ToolError.invalid("the file has no usable object rows")
            }
            if let problem = DatasetEngine.schemaProblem(columns: columns, key: []) { throw ToolError.invalid(problem) }
            dataset = Dataset(id: ULID.generate(), sessionID: session, name: name, columns: columns, key: [])
            try await store.createDataset(dataset)
            createdNote = ["columns": Self.columnsJSON(columns), "key": []]
            warnings.append("dataset \(name) did not exist: created it from the file (\(columns.map(\.name).joined(separator: ", "))) with no key; call dataset_define to set types and a key")
        }
        if parsed.extraCells > 0 { warnings.append("\(parsed.extraCells) cells beyond the header were ignored") }
        let inputs = parsed.rows.map { row -> ProcessInput in
            switch row {
            case .row(let raw): ProcessInput(raw: raw, line: nil)
            case .broken(let line, let reason, let raw): ProcessInput(raw: [:], line: line, brokenReason: reason, brokenRaw: raw)
            }
        }
        var total = Outcome(warnings: warnings)
        for start in stride(from: 0, to: inputs.count, by: DatasetEngine.maxRowsPerAppend) {
            let chunk = Array(inputs[start..<min(start + DatasetEngine.maxRowsPerAppend, inputs.count)])
            total.merge(try await upsert(rows: chunk, into: dataset, provenance: provenance, warnings: [], importing: true))
        }
        total.totalRows = try await store.datasetRowCount(datasetID: dataset.id)
        var json = total.json(name: name)
        if case .object(var object) = json {
            object["format"] = .string(format.rawValue)
            object["rows_read"] = .int(parsed.rows.count)
            if let createdNote { object["created"] = true; object["inferred"] = createdNote }
            json = .object(object)
        }
        return json
    }

    // MARK: read e list

    public func read(session: UUID, name: String, limit: Int?, offset: Int?, invalidOnly: Bool) async throws -> JSON {
        try Self.requireName(name)
        guard let dataset = try await store.dataset(sessionID: session, name: name) else { throw ToolError(.notFound, "no dataset named \(name) in this session") }
        let limit = min(max(limit ?? 100, 1), DatasetEngine.maxReadRows)
        let offset = max(offset ?? 0, 0)
        let filter: DatasetRowFilter = invalidOnly ? .invalid : .all
        let rows = try await store.datasetRows(datasetID: dataset.id, filter: filter, limit: limit, offset: offset)
        let summary = try await store.datasetSummary(id: dataset.id)
        let items = rows.map { row -> JSON in
            var item: [String: JSON] = ["data": (try? JSON.parse(row.data)) ?? .object([:]), "valid": .bool(row.valid), "trust": .string(row.trust.rawValue), "seen_count": .int(row.seenCount)]
            if let error = row.error { item["error"] = .string(error) }
            if let url = row.sourceURL { item["source_url"] = .string(url) }
            if let request = row.requestID { item["request_id"] = .string(request) }
            if let computer = row.computer { item["computer"] = .string(computer) }
            return .object(item)
        }
        return [
            "dataset": .string(name), "columns": Self.columnsJSON(dataset.columns), "key": .array(dataset.key.map { .string($0) }),
            "total_rows": .int(summary?.rowCount ?? 0), "invalid_rows": .int(summary?.invalidCount ?? 0), "offset": .int(offset), "returned": .int(rows.count), "rows": .array(items),
        ]
    }

    /// `dataset_list` do pai: os datasets da sessão dele.
    public func list(session: UUID) async throws -> JSON {
        let summaries = try await store.datasetSummaries(sessionID: session)
        let iso = ISO8601DateFormatter()
        return ["datasets": .array(summaries.map { s in
            ["name": .string(s.dataset.name), "rows": .int(s.rowCount), "invalid": .int(s.invalidCount), "updated": .string(iso.string(from: s.dataset.updatedAt)),
             "columns": .array(s.dataset.columns.map { .string($0.name) })]
        })]
    }

    // MARK: Núcleo

    struct ProcessInput {
        var raw: [String: JSON]
        var line: Int?
        var brokenReason: String?
        var brokenRaw: String?
    }

    struct Outcome {
        var counts = DatasetUpsertCounts()
        var invalid = 0
        var warnings: [String]
        var examples: [JSON] = []
        var totalRows = 0

        mutating func merge(_ other: Outcome) {
            counts.inserted += other.counts.inserted; counts.updated += other.counts.updated; counts.duplicate += other.counts.duplicate
            invalid += other.invalid
            for w in other.warnings where !warnings.contains(w) { warnings.append(w) }
            examples += other.examples.prefix(max(0, 5 - examples.count))
            totalRows = other.totalRows
        }

        func json(name: String) -> JSON {
            var out: [String: JSON] = [
                "dataset": .string(name), "inserted": .int(counts.inserted), "updated": .int(counts.updated), "duplicate": .int(counts.duplicate),
                "invalid": .int(invalid), "warnings": .array(warnings.map { .string($0) }), "total_rows": .int(totalRows),
            ]
            if !examples.isEmpty { out["invalid_examples"] = .array(examples) }
            return .object(out)
        }
    }

    private func upsert(rows: [ProcessInput], into dataset: Dataset, provenance: DatasetProvenance, warnings seed: [String], importing: Bool = false) async throws -> Outcome {
        var outcome = Outcome(warnings: seed)
        var dropped = Set<String>()
        var unknownRequests = Set<String>()
        var inputs: [DatasetRowInput] = []
        for (index, item) in rows.enumerated() {
            if let reason = item.brokenReason {
                outcome.invalid += 1
                if outcome.examples.count < 5 { outcome.examples.append(["row": .int(index), "error": .string(reason)]) }
                let key = DatasetEngine.sha256(Data("broken:\(item.line ?? index):".utf8) + Data((item.brokenRaw ?? "").utf8))
                inputs.append(DatasetRowInput(
                    rowKey: key, data: "{}", valid: false, error: reason, computer: provenance.computer, runID: provenance.runID, trust: .none,
                    errorKind: "unreadable line"))
                continue
            }
            let processed = DatasetEngine.process(item.raw, dataset: dataset)
            dropped.formUnion(processed.droppedColumns)
            var requestID: String?
            var sourceURL = processed.sourceURL
            var trust = DatasetTrust.none
            var request: DatasetRequestInfo?
            if let id = processed.requestID {
                if ResultValidator.looksLikeRequestID(id), let record = provenance.lookup(id) {
                    requestID = id; trust = record.trust; request = record.info
                    if let url = record.url { sourceURL = url }
                } else {
                    unknownRequests.insert(id)
                }
            }
            if importing, sourceURL == nil, let url = processed.data["url"]?.string ?? item.raw["url"]?.string, !url.isEmpty { sourceURL = url }
            if !processed.valid {
                outcome.invalid += 1
                if outcome.examples.count < 5 { outcome.examples.append(["row": .int(index), "error": .string(processed.error ?? "invalid")]) }
            }
            inputs.append(DatasetRowInput(
                rowKey: processed.rowKey, data: JSON.object(processed.data).text, valid: processed.valid, error: processed.error, computer: provenance.computer,
                runID: provenance.runID, requestID: requestID, sourceURL: sourceURL, trust: trust, request: request,
                errorKind: processed.valid ? nil : DatasetEngine.errorKind(processed.error)))
        }
        if !dropped.isEmpty { outcome.warnings.append("unknown columns dropped: \(dropped.sorted().joined(separator: ", ")); call dataset_define to add them") }
        if !unknownRequests.isEmpty {
            let shown = unknownRequests.sorted().prefix(3).joined(separator: ", ")
            outcome.warnings.append("\(unknownRequests.count) _request_id value(s) were not found in this computer's reqlog (\(shown)\(unknownRequests.count > 3 ? ", ..." : "")): those rows have trust none")
        }
        outcome.counts = try await store.upsertDatasetRows(datasetID: dataset.id, rows: inputs)
        outcome.totalRows = try await store.datasetRowCount(datasetID: dataset.id)
        return outcome
    }

    // MARK: Auxiliares

    static func requireName(_ name: String) throws {
        guard DatasetEngine.isValidName(name) else { throw ToolError.invalid("dataset name must match [a-z0-9_-] and be 1 to 64 characters") }
    }

    static func columnsJSON(_ columns: [DatasetColumn]) -> JSON {
        .array(columns.map { ["name": .string($0.name), "type": .string($0.type.rawValue), "required": .bool($0.required)] })
    }
}
