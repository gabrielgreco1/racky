import CryptoKit
import Foundation
import RackyStore

/// Regras puras dos datasets (Datasets v1): nomes, evolução do esquema, coerção de tipos, validação de linha e hash da chave.
/// Não toca em disco nem no store; quem chama (`DatasetService`) entrega o resultado ao `RackyStore`.
public enum DatasetEngine {
    // MARK: Limites

    public static let maxRowsPerAppend = 5_000
    public static let maxRowBytes = 1 << 20
    public static let maxColumns = 200
    public static let maxReadRows = 500
    /// Campos reservados em cada linha do `dataset_append`.
    public static let requestIDField = "_request_id"
    public static let sourceURLField = "_source_url"

    // MARK: Nomes

    /// `[a-z0-9_-]{1,64}`.
    public static func isValidName(_ name: String) -> Bool {
        (1...64).contains(name.utf8.count) && name.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x5F || $0 == 0x2D }
    }

    /// Nome de coluna: letra primeiro, depois letras, dígitos e `_`, até 64 (o `_` inicial é reservado aos campos de proveniência).
    public static func isValidColumnName(_ name: String) -> Bool {
        guard (1...64).contains(name.utf8.count), let first = name.utf8.first, (first | 0x20) >= 0x61 && (first | 0x20) <= 0x7A else { return false }
        return name.utf8.allSatisfy { ($0 | 0x20) >= 0x61 && ($0 | 0x20) <= 0x7A || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x5F }
    }

    /// Cabeçalho de CSV vira nome de coluna: minúsculas, o resto vira `_`, sem `_` nas pontas (`Hotel Name` -> `hotel_name`).
    public static func normalizedColumnName(_ header: String) -> String {
        var out = ""
        for scalar in header.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().unicodeScalars {
            let ascii = scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_")
            out.append(ascii ? Character(scalar) : "_")
        }
        while out.contains("__") { out = out.replacingOccurrences(of: "__", with: "_") }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    // MARK: Esquema

    /// Valida colunas e chave. Devolve o motivo (texto para o agente) ou `nil`.
    public static func schemaProblem(columns: [DatasetColumn], key: [String]) -> String? {
        if columns.count > maxColumns { return "a dataset has at most \(maxColumns) columns" }
        var seen = Set<String>()
        for column in columns {
            guard isValidColumnName(column.name) else { return "column name '\(column.name)' is invalid: letters, digits and _, starting with a letter, up to 64 characters" }
            guard seen.insert(column.name).inserted else { return "column '\(column.name)' is listed twice" }
        }
        var keys = Set<String>()
        for name in key {
            guard seen.contains(name) else { return "key column '\(name)' is not one of the columns" }
            guard keys.insert(name).inserted else { return "key column '\(name)' is listed twice" }
        }
        return nil
    }

    /// `dataset_define` sobre um dataset que já existe: acrescentar colunas é livre; com linhas, trocar o tipo de uma coluna ou a chave não é.
    /// `key == nil` mantém a chave atual. Devolve o esquema resultante ou o motivo da recusa.
    public static func evolve(existing: Dataset, columns: [DatasetColumn], key: [String]?, hasRows: Bool) -> Result<(columns: [DatasetColumn], key: [String]), SchemaError> {
        var merged = existing.columns
        for column in columns {
            if let index = merged.firstIndex(where: { $0.name == column.name }) {
                if merged[index].type != column.type, hasRows {
                    return .failure(SchemaError("column '\(column.name)' is \(merged[index].type.rawValue) and the dataset already has rows; it cannot become \(column.type.rawValue)"))
                }
                merged[index] = column
            } else {
                merged.append(column)
            }
        }
        let newKey = key ?? existing.key
        if hasRows, newKey != existing.key {
            return .failure(SchemaError("the key of a dataset with rows cannot change (it is \(existing.key.isEmpty ? "the whole row" : existing.key.joined(separator: ", ")))"))
        }
        if let problem = schemaProblem(columns: merged, key: newKey) { return .failure(SchemaError(problem)) }
        // Coluna que a chave já usa e que passou a ser obrigatória a posteriori continua válida: linhas antigas não são revalidadas.
        return .success((merged, newKey))
    }

    public struct SchemaError: Error, Equatable, Sendable {
        public var message: String
        init(_ message: String) { self.message = message }
    }

    /// Esquema inferido da primeira linha do `dataset_append` num dataset que ainda não existe: tudo `string`, exceto inteiros, números,
    /// booleanos e estruturas (`json`) nativos do JSON. Colunas em ordem alfabética (o objeto JSON não guarda a ordem). Chave vazia.
    public static func inferColumns(from row: [String: JSON]) -> [DatasetColumn] {
        row.keys.filter { !$0.hasPrefix("_") && isValidColumnName($0) }.sorted().prefix(maxColumns).map { name in
            let type: DatasetColumnType
            switch row[name] {
            case .int?: type = .integer
            case .double?: type = .number
            case .bool?: type = .boolean
            case .array?, .object?: type = .json
            default: type = .string
            }
            return DatasetColumn(name: name, type: type)
        }
    }

    // MARK: Coerção

    private static func isDigits(_ s: Substring) -> Bool { !s.isEmpty && s.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 } }

    private static func matches(_ text: String, _ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }

    /// Coage `value` para `type`. `nil` = ausente (`null` ou texto vazio). Erro = texto curto do motivo.
    public static func coerce(_ value: JSON, to type: DatasetColumnType) -> Result<JSON?, CoercionError> {
        if value.isNull { return .success(nil) }
        if case .string(let raw) = value, raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .success(nil) }
        func fail(_ expected: String) -> Result<JSON?, CoercionError> {
            let shown = value.text
            return .failure(CoercionError("expected \(expected), got \(shown.count > 60 ? String(shown.prefix(60)) + "..." : shown)"))
        }
        switch type {
        case .string:
            switch value {
            case .string(let s): return .success(.string(s))
            case .int, .double, .bool: return .success(.string(value.text))
            default: return fail("text")
            }
        case .integer:
            if let n = value.int, case .int = value { return .success(.int(n)) }
            if case .double = value, let n = value.int { return .success(.int(n)) }
            if case .string(let raw) = value {
                let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if matches(s, #"^[+-]?[0-9]{1,18}$"#), let n = Int(s) { return .success(.int(n)) }
            }
            return fail("an integer")
        case .number:
            switch value {
            case .int(let n): return .success(.int(n))
            case .double(let d): return d.isFinite ? .success(canonicalNumber(d)) : fail("a finite number")
            case .string(let raw):
                let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if matches(s, #"^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$"#), let d = Double(s), d.isFinite { return .success(canonicalNumber(d)) }
                return fail("a number with '.' as the decimal separator")
            default: return fail("a number")
            }
        case .boolean:
            if case .bool = value { return .success(value) }
            if case .string(let raw) = value {
                switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "true", "yes", "1": return .success(.bool(true))
                case "false", "no", "0": return .success(.bool(false))
                default: break
                }
            }
            return fail("true or false")
        case .date:
            if case .string(let raw) = value {
                let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if matches(s, #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#), validDate(s) { return .success(.string(s)) }
            }
            return fail("an ISO 8601 date (YYYY-MM-DD)")
        case .datetime:
            if case .string(let raw) = value, let normalized = normalizedDatetime(raw) { return .success(.string(normalized)) }
            return fail("an ISO 8601 date-time")
        case .url:
            if case .string(let raw) = value {
                let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.contains(where: \.isWhitespace), let components = URLComponents(string: s), let scheme = components.scheme?.lowercased(),
                   scheme == "http" || scheme == "https", let host = components.host, !host.isEmpty { return .success(.string(s)) }
            }
            return fail("an http(s) URL")
        case .json:
            if case .string(let raw) = value {
                let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if s.hasPrefix("{") || s.hasPrefix("["), let parsed = try? JSON.parse(s) { return .success(parsed) }
                return .success(value)
            }
            return .success(value)
        }
    }

    public struct CoercionError: Error, Equatable, Sendable {
        public var message: String
        init(_ message: String) { self.message = message }
    }

    /// `4.0` e `4` são o mesmo número (o hash da chave não pode distinguir).
    private static func canonicalNumber(_ d: Double) -> JSON {
        if d == d.rounded(), abs(d) < 9e15 { return .int(Int(d)) }
        return .double(d)
    }

    private static func validDate(_ s: String) -> Bool {
        let parts = s.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let date = calendar.date(from: components) else { return false }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        return back.year == parts[0] && back.month == parts[1] && back.day == parts[2]
    }

    /// `2026-10-20T14:30[:05[.123]][Z|+02:00]` (também com espaço no lugar do `T`). Devolve com `T`.
    private static func normalizedDatetime(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard matches(s, #"^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]+)?)?(Z|[+-][0-9]{2}:?[0-9]{2})?$"#) else { return nil }
        let normalized = s.replacingOccurrences(of: " ", with: "T")
        guard validDate(String(normalized.prefix(10))) else { return nil }
        let time = normalized.dropFirst(11).split(whereSeparator: { "Z+-".contains($0) }).first.map(String.init) ?? ""
        let hms = time.split(separator: ":").map { Int($0.prefix(2)) ?? 99 }
        guard hms.count >= 2, hms[0] < 24, hms[1] < 60, hms.count < 3 || hms[2] <= 60 else { return nil }
        return normalized
    }

    // MARK: Linha

    /// O que sai de validar uma linha contra o esquema.
    public struct ProcessedRow: Sendable, Equatable {
        public var rowKey: String
        public var data: [String: JSON]
        public var valid: Bool
        public var error: String?
        /// Colunas que o dataset não tem (descartadas).
        public var droppedColumns: [String]
        public var requestID: String?
        public var sourceURL: String?
    }

    /// Valida `raw` contra `dataset`: descarta colunas desconhecidas, coage tipos, exige as obrigatórias. Linha inválida é devolvida
    /// com `valid == false` e `error`; nunca some. Os campos reservados `_request_id` e `_source_url` saem do dado e vão para o resultado.
    public static func process(_ raw: [String: JSON], dataset: Dataset) -> ProcessedRow {
        var data: [String: JSON] = [:]
        var problems: [String] = []
        var dropped: [String] = []
        let known = Dictionary(uniqueKeysWithValues: dataset.columns.map { ($0.name, $0) })
        var failedColumns = Set<String>()
        for name in raw.keys.sorted() where name != requestIDField && name != sourceURLField {
            guard let column = known[name] else { dropped.append(name); continue }
            switch coerce(raw[name] ?? .null, to: column.type) {
            case .success(let value?): data[name] = value
            case .success(nil): break
            case .failure(let error): problems.append("\(name): \(error.message)"); failedColumns.insert(name)
            }
        }
        for column in dataset.columns where column.required && data[column.name] == nil && !failedColumns.contains(column.name) {
            problems.append("\(column.name): required")
            failedColumns.insert(column.name)
        }
        var valid = problems.isEmpty
        var error: String? = valid ? nil : problems.joined(separator: "; ")
        var stored = data
        if JSON.object(data).data().count > maxRowBytes {
            valid = false
            error = "row is larger than 1 MiB"
            stored = [:]
        }
        // Linha inválida sem chave utilizável (chave vazia, faltando ou que não coagiu) usa o hash da linha crua.
        let keyHealthy = !dataset.key.isEmpty && dataset.key.allSatisfy { data[$0] != nil }
        let rowKey = (valid || keyHealthy) ? self.rowKey(key: dataset.key, data: data) : rawRowKey(raw)
        return ProcessedRow(
            rowKey: rowKey, data: stored, valid: valid, error: error, droppedColumns: dropped, requestID: raw[requestIDField]?.string,
            sourceURL: raw[sourceURLField]?.string)
    }

    /// Problema principal de uma linha inválida, curto e agrupável para a faceta "Error": `price: required` vira `price missing`,
    /// `rating: expected a number, got "four"` vira `rating not a number`.
    public static func errorKind(_ error: String?) -> String? {
        guard let first = error?.components(separatedBy: "; ").first, !first.isEmpty else { return nil }
        if first == "row is larger than 1 MiB" { return "row too large" }
        guard let colon = first.firstIndex(of: ":") else { return String(first.prefix(40)) }
        let column = first[..<colon]
        let message = first[first.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if message == "required" { return "\(column) missing" }
        if message.hasPrefix("expected "), let comma = message.range(of: ", got ") {
            return "\(column) not \(message[message.index(message.startIndex, offsetBy: 9)..<comma.lowerBound])"
        }
        return String(first.prefix(40))
    }

    /// SHA-256 (hex) do JSON canônico (chaves ordenadas) dos valores da chave; chave vazia = a linha inteira. A ordem das chaves no objeto
    /// do agente e a ordem da lista `key` não mudam o hash.
    public static func rowKey(key: [String], data: [String: JSON]) -> String {
        let basis: JSON = key.isEmpty ? .object(data) : .object(Dictionary(uniqueKeysWithValues: key.map { ($0, data[$0] ?? .null) }))
        return sha256(basis.data())
    }

    /// Linha inválida cuja chave não existe (faltou ou não coagiu): hash da linha crua, para que linhas inválidas diferentes não colapsem.
    static func rawRowKey(_ raw: [String: JSON]) -> String {
        sha256(Data("invalid:".utf8) + JSON.object(raw).data())
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
