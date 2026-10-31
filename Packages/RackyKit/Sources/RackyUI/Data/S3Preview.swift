import Foundation

/// O que a prévia de um arquivo do S3 mostra: uma grade (CSV, JSON Lines, JSON de objetos), texto ou só os metadados.
enum S3PreviewContent: Equatable, Sendable {
    case grid(DataGrid)
    case text(String)
    /// Formato que não se mostra (parquet, imagem, zip…) ou binário: só nome, tamanho e data.
    case metadataOnly
    case failed(String)
}

/// Prévia de um objeto: metadados do que a lista já sabe + o conteúdo dos primeiros 256 KB.
struct S3Preview: Equatable, Sendable {
    var key: String
    var size: Int64
    var modified: Date?
    var content: S3PreviewContent?
    /// Só os primeiros bytes foram lidos (o arquivo é maior).
    var truncated = false
    var loading = false
}

/// Leitura da prévia: o que o formato do arquivo permite e como vira grade ou texto. Funções puras (testáveis sem rede).
enum S3PreviewParser {
    static let maxRows = 200
    static let maxColumns = 40
    static let maxTextCharacters = 20_000

    enum Format: Equatable { case csv(delimiter: Character), jsonLines, json, text, other }

    static func format(of name: String) -> Format {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "csv": return .csv(delimiter: ",")
        case "tsv": return .csv(delimiter: "\t")
        case "jsonl", "ndjson": return .jsonLines
        case "json": return .json
        case "txt", "log", "md", "markdown", "yaml", "yml", "xml", "html", "htm", "sql", "py", "sh", "ini", "toml", "conf", "cfg", "text", "rst":
            return .text
        default: return .other
        }
    }

    /// Nome legível do formato (coluna "Type" da lista).
    static func label(of name: String) -> String {
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? "–" : ext.uppercased()
    }

    /// `data` são os primeiros bytes do objeto; `truncated` diz que há mais depois deles.
    static func parse(_ data: Data, name: String, truncated: Bool) -> S3PreviewContent {
        let format = format(of: name)
        if format == .other { return .metadataOnly }
        // Binário disfarçado de texto (byte nulo): não mostra lixo.
        if data.contains(0) { return .metadataOnly }
        var text = String(decoding: data, as: UTF8.self)
        // O corte pode ter partido um caractere no meio.
        while truncated, text.hasSuffix("\u{FFFD}") { text.removeLast() }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        switch format {
        case .csv(let delimiter): return csv(text, delimiter: delimiter, truncated: truncated)
        case .jsonLines: return jsonLines(text, truncated: truncated)
        case .json: return json(text, truncated: truncated)
        case .text, .other: return .text(String(text.prefix(maxTextCharacters)))
        }
    }

    // MARK: CSV

    static func csv(_ text: String, delimiter: Character, truncated: Bool) -> S3PreviewContent {
        var rows = parseCSV(text, delimiter: delimiter)
        // Linha cortada no fim do trecho: some (só vale se o trecho não terminou numa quebra de linha).
        if truncated, !text.hasSuffix("\n"), !rows.isEmpty { rows.removeLast() }
        guard var header = rows.first else { return .text(String(text.prefix(maxTextCharacters))) }
        // `;` no lugar de `,` (planilhas em português): se o cabeçalho não tem vírgula mas tem ponto e vírgula, usa ele.
        if delimiter == ",", header.count == 1, header[0].contains(";") {
            rows = parseCSV(text, delimiter: ";")
            if truncated, !text.hasSuffix("\n"), !rows.isEmpty { rows.removeLast() }
            header = rows.first ?? header
        }
        let width = min(header.count, maxColumns)
        let columns = (0 ..< width).map { DataGrid.Column(name: header[$0].isEmpty ? "column\($0 + 1)" : header[$0], type: "text") }
        let body = rows.dropFirst().prefix(maxRows).map { row in (0 ..< width).map { $0 < row.count ? row[$0] : "" } }
        return .grid(DataGrid(columns: columns, rows: Array(body), total: max(rows.count - 1, 0)))
    }

    /// RFC 4180: campos entre aspas (com `""` e quebras de linha dentro).
    static func parseCSV(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var chars = text.makeIterator()
        var pending: Character? = chars.next()
        while let c = pending {
            pending = chars.next()
            if quoted {
                if c == "\"" {
                    if pending == "\"" { field.append("\""); pending = chars.next() } else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" && field.isEmpty {
                quoted = true
            } else if c == delimiter {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field); field = ""
                rows.append(row); row = []
            } else {
                field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }

    // MARK: JSON

    static func jsonLines(_ text: String, truncated: Bool) -> S3PreviewContent {
        var lines = text.split(whereSeparator: \.isNewline).map(String.init)
        if truncated, !text.hasSuffix("\n"), !lines.isEmpty { lines.removeLast() }
        var objects: [[String: Any]] = []
        var ordered: [[(String, Any)]] = []
        for line in lines.prefix(maxRows) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return .text(String(text.prefix(maxTextCharacters))) }
            objects.append(object)
            ordered.append(orderedPairs(line, object))
        }
        guard !objects.isEmpty else { return .text(String(text.prefix(maxTextCharacters))) }
        return .grid(grid(ordered, total: lines.count))
    }

    static func json(_ text: String, truncated: Bool) -> S3PreviewContent {
        if !truncated, let value = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) {
            if let array = value as? [[String: Any]], !array.isEmpty {
                let ordered = array.prefix(maxRows).map { orderedPairs(nil, $0) }
                return .grid(grid(Array(ordered), total: array.count))
            }
            if let pretty = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]) {
                return .text(String(String(decoding: pretty, as: UTF8.self).prefix(maxTextCharacters)))
            }
        }
        return .text(String(text.prefix(maxTextCharacters)))
    }

    /// As chaves de um objeto na ordem em que aparecem na linha (o dicionário do Foundation perde a ordem); sem a linha, em ordem alfabética.
    private static func orderedPairs(_ line: String?, _ object: [String: Any]) -> [(String, Any)] {
        guard let line else { return object.keys.sorted().map { ($0, object[$0] ?? NSNull()) } }
        let keys = object.keys.sorted { (line.range(of: "\"\($0)\"")?.lowerBound ?? line.endIndex) < (line.range(of: "\"\($1)\"")?.lowerBound ?? line.endIndex) }
        return keys.map { ($0, object[$0] ?? NSNull()) }
    }

    private static func grid(_ rows: [[(String, Any)]], total: Int) -> DataGrid {
        var names: [String] = []
        for row in rows { for (key, _) in row where !names.contains(key) && names.count < maxColumns { names.append(key) } }
        let body = rows.map { row -> [String] in
            let map = Dictionary(row.map { ($0.0, $0.1) }, uniquingKeysWith: { $1 })
            return names.map { cell(map[$0]) }
        }
        return DataGrid(columns: names.map { DataGrid.Column(name: $0, type: "text") }, rows: body, total: total)
    }

    private static func cell(_ value: Any?) -> String {
        switch value {
        case nil, is NSNull: return ""
        case let text as String: return text
        case let number as NSNumber:
            // Booleanos do JSON chegam como NSNumber.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        default:
            if let value, JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
                return String(decoding: data, as: UTF8.self)
            }
            return "\(value ?? "")"
        }
    }
}
