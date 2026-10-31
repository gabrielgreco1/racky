import Foundation

/// Leitura de arquivos para `dataset_import`: CSV (RFC 4180, linha de cabeçalho), JSON Lines ou JSON (array de objetos).
public enum DatasetImportFormat: String, Sendable, CaseIterable {
    case csv, jsonl, json

    /// Pela extensão; sem extensão conhecida, `nil` (quem chama olha o conteúdo).
    public static func guess(fileName: String) -> DatasetImportFormat? {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "csv", "tsv": .csv
        case "jsonl", "ndjson": .jsonl
        case "json": .json
        default: nil
        }
    }

    /// Pelo primeiro caractere útil: `[` é array JSON; `{` é JSON Lines; o resto, CSV.
    public static func sniff(_ data: Data) -> DatasetImportFormat {
        let text = String(decoding: data.prefix(4096), as: UTF8.self).drop { $0 == "\u{FEFF}" || $0.isWhitespace }
        switch text.first {
        case "[": return .json
        case "{": return .jsonl
        default: return .csv
        }
    }
}

public enum DatasetImportError: Error, Equatable, Sendable {
    case empty
    case badHeader(String)
    case badJSON(String)
    case tooManyRows(Int)

    public var message: String {
        switch self {
        case .empty: "the file has no rows"
        case .badHeader(let m): m
        case .badJSON(let m): m
        case .tooManyRows(let n): "the file has more than \(n) rows; split it"
        }
    }
}

/// Uma linha lida: o objeto, ou o motivo de não ter virado objeto (vira linha inválida no dataset, nunca é descartada em silêncio).
public enum ParsedRow: Sendable, Equatable {
    case row([String: JSON])
    case broken(line: Int, reason: String, raw: String)
}

public struct ParsedImport: Sendable, Equatable {
    /// Colunas na ordem do arquivo (CSV: cabeçalho normalizado; JSON: união das chaves por ordem alfabética).
    public var columns: [String]
    public var rows: [ParsedRow]
    /// Quantas células além do cabeçalho foram ignoradas (CSV com linha mais larga que o cabeçalho).
    public var extraCells = 0
}

public enum DatasetImportParser {
    public static let maxRows = 100_000

    public static func parse(_ data: Data, format: DatasetImportFormat) throws -> ParsedImport {
        switch format {
        case .csv: try parseCSV(data)
        case .jsonl: try parseJSONLines(data)
        case .json: try parseJSONArray(data)
        }
    }

    // MARK: CSV

    /// Registros do CSV: aspas duplas, `""` dentro de campo entre aspas, quebra de linha dentro de aspas, CRLF ou LF, BOM, linhas vazias ignoradas.
    static func records(_ data: Data) -> [[String]] {
        var text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false
        var quotedField = false
        var wasQuoted = false
        let chars = Array(text.unicodeScalars)
        var i = 0
        func endField() { record.append(field); field = ""; quotedField = false }
        func endRecord() {
            endField()
            // Linha vazia (um campo só, vazio, sem aspas) não é registro.
            if !(record.count == 1 && record[0].isEmpty && !wasQuoted) { records.append(record) }
            record = []
            wasQuoted = false
        }
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.unicodeScalars.append("\""); i += 1 } else { inQuotes = false }
                } else {
                    field.unicodeScalars.append(c)
                }
            } else {
                switch c {
                case "\"" where field.isEmpty: inQuotes = true; quotedField = true; wasQuoted = true
                case ",": endField()
                case "\r":
                    if i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
                    endRecord()
                case "\n": endRecord()
                default: field.unicodeScalars.append(c)
                }
            }
            i += 1
        }
        if !field.isEmpty || !record.isEmpty || quotedField { endRecord() }
        return records
    }

    static func parseCSV(_ data: Data) throws -> ParsedImport {
        let all = records(data)
        guard let header = all.first else { throw DatasetImportError.empty }
        let names = header.map { DatasetEngine.normalizedColumnName($0) }
        var seen = Set<String>()
        for (index, name) in names.enumerated() {
            guard DatasetEngine.isValidColumnName(name) else {
                throw DatasetImportError.badHeader("header column \(index + 1) ('\(header[index])') is not a usable column name (letters and digits, starting with a letter)")
            }
            guard seen.insert(name).inserted else { throw DatasetImportError.badHeader("header column '\(name)' appears twice") }
        }
        let body = all.dropFirst()
        guard !body.isEmpty else { throw DatasetImportError.empty }
        guard body.count <= maxRows else { throw DatasetImportError.tooManyRows(maxRows) }
        var rows: [ParsedRow] = []
        var extra = 0
        for record in body {
            var object: [String: JSON] = [:]
            for (index, name) in names.enumerated() {
                // Células curtas ficam ausentes (obrigatória faltando vira linha inválida); texto vazio também é ausência.
                if index < record.count { object[name] = .string(record[index]) }
            }
            if record.count > names.count { extra += record.count - names.count }
            rows.append(.row(object))
        }
        return ParsedImport(columns: names, rows: rows, extraCells: extra)
    }

    // MARK: JSON Lines e array

    static func parseJSONLines(_ data: Data) throws -> ParsedImport {
        var text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        var rows: [ParsedRow] = []
        var columns = Set<String>()
        for (index, line) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard rows.count < maxRows else { throw DatasetImportError.tooManyRows(maxRows) }
            if let object = (try? JSON.parse(trimmed))?.object {
                columns.formUnion(object.keys)
                rows.append(.row(object))
            } else {
                rows.append(.broken(line: index + 1, reason: "line \(index + 1) is not a JSON object", raw: String(trimmed.prefix(200))))
            }
        }
        guard !rows.isEmpty else { throw DatasetImportError.empty }
        return ParsedImport(columns: columns.sorted(), rows: rows)
    }

    static func parseJSONArray(_ data: Data) throws -> ParsedImport {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        guard let parsed = try? JSON.parse(bytes), let items = parsed.array else { throw DatasetImportError.badJSON("the file is not a JSON array of objects") }
        guard !items.isEmpty else { throw DatasetImportError.empty }
        guard items.count <= maxRows else { throw DatasetImportError.tooManyRows(maxRows) }
        var rows: [ParsedRow] = []
        var columns = Set<String>()
        for (index, item) in items.enumerated() {
            if let object = item.object {
                columns.formUnion(object.keys)
                rows.append(.row(object))
            } else {
                rows.append(.broken(line: index + 1, reason: "item \(index + 1) is not a JSON object", raw: String(item.text.prefix(200))))
            }
        }
        return ParsedImport(columns: columns.sorted(), rows: rows)
    }
}
