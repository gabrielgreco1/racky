import Foundation
import RackyStore

/// Exportadores de dataset: CSV (RFC 4180, CRLF, guarda de injeção de fórmula), JSON Lines e JSON. As colunas saem na ordem do esquema;
/// só linhas válidas. Texto vindo de página da web é não confiável: célula de texto que começa com `=`, `+`, `-`, `@` ganha `'` no CSV.
public enum DatasetExporter {
    public enum Format: String, Sendable, CaseIterable {
        case csv, jsonl, json
        public var fileExtension: String { self == .jsonl ? "jsonl" : rawValue }
    }

    public static func decode(_ row: DatasetRow) -> [String: JSON] {
        (try? JSON.parse(row.data))?.object ?? [:]
    }

    /// Texto da célula; `nil` (ausente) é vazio. Números e booleanos já foram validados, então não passam pela guarda de fórmula.
    static func cell(_ value: JSON?, type: DatasetColumnType) -> String {
        guard let value else { return "" }
        switch value {
        case .null: return ""
        case .int, .double, .bool: return value.text
        case .string(let s): return CSVFormat.cell(CSVFormat.safe(s))
        default: return CSVFormat.cell(CSVFormat.safe(value.text))
        }
    }

    public static func csv(columns: [DatasetColumn], rows: [DatasetRow]) -> Data {
        var lines = [columns.map { CSVFormat.cell($0.name) }.joined(separator: ",")]
        for row in rows where row.valid {
            let object = decode(row)
            lines.append(columns.map { cell(object[$0.name], type: $0.type) }.joined(separator: ","))
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    /// Um objeto por linha, chaves na ordem do esquema (o `JSON` do core ordena por nome, então o objeto é montado à mão).
    static func objectText(columns: [DatasetColumn], object: [String: JSON]) -> String {
        "{" + columns.compactMap { column in object[column.name].map { "\(JSON.string(column.name).text):\($0.text)" } }.joined(separator: ",") + "}"
    }

    public static func jsonLines(columns: [DatasetColumn], rows: [DatasetRow]) -> Data {
        var out = ""
        for row in rows where row.valid { out += objectText(columns: columns, object: decode(row)) + "\n" }
        return Data(out.utf8)
    }

    public static func json(columns: [DatasetColumn], rows: [DatasetRow]) -> Data {
        let items = rows.filter(\.valid).map { "  " + objectText(columns: columns, object: decode($0)) }
        return Data(("[" + (items.isEmpty ? "" : "\n" + items.joined(separator: ",\n") + "\n") + "]\n").utf8)
    }

    public static func data(_ format: Format, columns: [DatasetColumn], rows: [DatasetRow]) -> Data {
        switch format {
        case .csv: csv(columns: columns, rows: rows)
        case .jsonl: jsonLines(columns: columns, rows: rows)
        case .json: json(columns: columns, rows: rows)
        }
    }
}

extension DatasetExporter {
    public static func suggestedName(dataset: String, format: Format) -> String { "\(dataset).\(format.fileExtension)" }

    /// Lê as linhas válidas do store em páginas de 5.000 e grava o arquivo (fora da UI). Devolve quantas linhas saíram.
    @discardableResult
    public static func write(store: RackyStore, dataset: Dataset, format: Format, to url: URL) async throws -> Int {
        var rows: [DatasetRow] = []
        var offset = 0
        let page = DatasetEngine.maxRowsPerAppend
        while true {
            let chunk = try await store.datasetRows(datasetID: dataset.id, limit: page, offset: offset)
            rows += chunk.filter(\.valid)
            guard chunk.count == page else { break }
            offset += page
        }
        try data(format, columns: dataset.columns, rows: rows).write(to: url, options: .atomic)
        return rows.count
    }
}
