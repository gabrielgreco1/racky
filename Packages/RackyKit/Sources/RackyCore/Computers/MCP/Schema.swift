import Foundation

/// Subconjunto de JSON Schema suficiente para os schemas EXATOS de 07 §3.2, com validação no servidor. O que o JSON Schema não
/// diz (XOR entre campos, "pelo menos um") vira restrição de `ObjectSpec`, validada aqui e escrita na `description` (a API do
/// Claude recusa `oneOf`/`anyOf` no topo do `input_schema`).
public struct Schema: Sendable {
    public indirect enum Kind: Sendable {
        case string, integer, number, boolean, any
        case array(Schema)
        case object(ObjectSpec)
    }

    public var kind: Kind
    public var enumValues: [JSON]?
    public var minimum: Double?
    public var maximum: Double?
    public var minLength: Int?
    public var maxLength: Int?
    public var minItems: Int?
    public var maxItems: Int?
    public var description: String?
    public var defaultValue: JSON?

    public init(_ kind: Kind, description: String? = nil, defaultValue: JSON? = nil) {
        self.kind = kind
        self.description = description
        self.defaultValue = defaultValue
    }

    // MARK: Construtores

    public static func string(_ description: String? = nil, minLength: Int? = nil, maxLength: Int? = nil, def: JSON? = nil) -> Schema {
        var s = Schema(.string, description: description, defaultValue: def)
        s.minLength = minLength
        s.maxLength = maxLength
        return s
    }

    public static func oneOf(_ values: [String], _ description: String? = nil, def: JSON? = nil) -> Schema {
        var s = Schema(.string, description: description, defaultValue: def)
        s.enumValues = values.map { .string($0) }
        return s
    }

    public static func integer(_ description: String? = nil, min: Int? = nil, max: Int? = nil, def: JSON? = nil) -> Schema {
        var s = Schema(.integer, description: description, defaultValue: def)
        s.minimum = min.map(Double.init)
        s.maximum = max.map(Double.init)
        return s
    }

    public static func intEnum(_ values: [Int], _ description: String? = nil, def: JSON? = nil) -> Schema {
        var s = Schema(.integer, description: description, defaultValue: def)
        s.enumValues = values.map { .int($0) }
        return s
    }

    public static func number(_ description: String? = nil, min: Double? = nil, max: Double? = nil, def: JSON? = nil) -> Schema {
        var s = Schema(.number, description: description, defaultValue: def)
        s.minimum = min
        s.maximum = max
        return s
    }

    public static func boolean(_ description: String? = nil, def: JSON? = nil) -> Schema { Schema(.boolean, description: description, defaultValue: def) }

    public static func any(_ description: String? = nil) -> Schema { Schema(.any, description: description) }

    public static func array(_ item: Schema, _ description: String? = nil, minItems: Int? = nil, maxItems: Int? = nil) -> Schema {
        var s = Schema(.array(item), description: description)
        s.minItems = minItems
        s.maxItems = maxItems
        return s
    }

    public static func object(_ spec: ObjectSpec, _ description: String? = nil) -> Schema { Schema(.object(spec), description: description) }

    // MARK: JSON Schema

    public func json() -> JSON {
        var out: [String: JSON] = [:]
        var text = description ?? ""
        switch kind {
        case .string: out["type"] = "string"
        case .integer: out["type"] = "integer"
        case .number: out["type"] = "number"
        case .boolean: out["type"] = "boolean"
        case .any: break
        case .array(let item):
            out["type"] = "array"
            out["items"] = item.json()
        case .object(let spec):
            out["type"] = "object"
            out["properties"] = .object(Dictionary(uniqueKeysWithValues: spec.properties.map { ($0.name, $0.schema.json()) }))
            if !spec.required.isEmpty { out["required"] = .array(spec.required.map { .string($0) }) }
            switch spec.additional {
            case .forbidden: out["additionalProperties"] = false
            case .any: out["additionalProperties"] = true
            case .schema(let s): out["additionalProperties"] = s.json()
            }
            let notes = spec.constraintNotes()
            if !notes.isEmpty { text += (text.isEmpty ? "" : " ") + notes }
        }
        if let enumValues { out["enum"] = .array(enumValues) }
        if let minimum { out["minimum"] = minimum == minimum.rounded() ? .int(Int(minimum)) : .double(minimum) }
        if let maximum { out["maximum"] = maximum == maximum.rounded() ? .int(Int(maximum)) : .double(maximum) }
        if let minLength { out["minLength"] = .int(minLength) }
        if let maxLength { out["maxLength"] = .int(maxLength) }
        if let minItems { out["minItems"] = .int(minItems) }
        if let maxItems { out["maxItems"] = .int(maxItems) }
        if let defaultValue { out["default"] = defaultValue }
        if !text.isEmpty { out["description"] = .string(text) }
        return .object(out)
    }

    // MARK: Validação

    /// Violações no formato `"<caminho>: <problema>"`. Vazio = válido.
    public func validate(_ value: JSON, path: String = "") -> [String] {
        let here = path.isEmpty ? "arguments" : path
        var errors: [String] = []
        switch kind {
        case .any: break
        case .string:
            guard let s = value.string else { return ["\(here): expected string"] }
            if let minLength, s.count < minLength { errors.append("\(here): shorter than \(minLength)") }
            if let maxLength, s.count > maxLength { errors.append("\(here): longer than \(maxLength)") }
        case .integer:
            guard let n = value.int else { return ["\(here): expected integer"] }
            errors += range(Double(n), here)
        case .number:
            guard let n = value.double else { return ["\(here): expected number"] }
            errors += range(n, here)
        case .boolean:
            if value.bool == nil { return ["\(here): expected boolean"] }
        case .array(let item):
            guard let items = value.array else { return ["\(here): expected array"] }
            if let minItems, items.count < minItems { errors.append("\(here): fewer than \(minItems) items") }
            if let maxItems, items.count > maxItems { errors.append("\(here): more than \(maxItems) items") }
            for (i, element) in items.enumerated() { errors += item.validate(element, path: "\(path)[\(i)]") }
        case .object(let spec):
            guard let object = value.object else { return ["\(here): expected object"] }
            errors += spec.validate(object, path: path)
        }
        if let enumValues, errors.isEmpty, !enumValues.contains(value) {
            errors.append("\(here): must be one of \(enumValues.map { $0.text }.joined(separator: ", "))")
        }
        return errors
    }

    private func range(_ n: Double, _ here: String) -> [String] {
        var errors: [String] = []
        if let minimum, n < minimum { errors.append("\(here): below minimum \(minimum)") }
        if let maximum, n > maximum { errors.append("\(here): above maximum \(maximum)") }
        return errors
    }
}

public struct Property: Sendable {
    public var name: String
    public var schema: Schema
}

public struct ObjectSpec: Sendable {
    public enum Additional: Sendable {
        case forbidden, any
        case schema(Schema)
    }

    public var properties: [Property]
    public var required: [String]
    public var additional: Additional
    /// Exatamente UMA alternativa presente por completo e nenhuma chave de outra (`selector` XOR `x`+`y`).
    public var exactlyOne: [[String]]
    /// No máximo um destes campos (`body` XOR `json` XOR `form`).
    public var atMostOne: [String]
    /// Pelo menos um destes campos.
    public var atLeastOne: [String]

    public init(_ properties: [(String, Schema)] = [], required: [String] = [], additional: Additional = .forbidden,
                exactlyOne: [[String]] = [], atMostOne: [String] = [], atLeastOne: [String] = []) {
        self.properties = properties.map { Property(name: $0.0, schema: $0.1) }
        self.required = required
        self.additional = additional
        self.exactlyOne = exactlyOne
        self.atMostOne = atMostOne
        self.atLeastOne = atLeastOne
    }

    func constraintNotes() -> String {
        var notes: [String] = []
        if !exactlyOne.isEmpty {
            notes.append("Give exactly one of: " + exactlyOne.map { $0.count == 1 ? $0[0] : "(" + $0.joined(separator: " + ") + ")" }.joined(separator: " | ") + ".")
        }
        if !atMostOne.isEmpty { notes.append("At most one of: " + atMostOne.joined(separator: ", ") + ".") }
        if !atLeastOne.isEmpty { notes.append("At least one of: " + atLeastOne.joined(separator: ", ") + ".") }
        return notes.joined(separator: " ")
    }

    func validate(_ object: [String: JSON], path: String) -> [String] {
        var errors: [String] = []
        let prefix = path.isEmpty ? "" : path + "."
        for name in required where object[name] == nil || object[name]?.isNull == true {
            errors.append("\(prefix)\(name): required")
        }
        let known = Dictionary(uniqueKeysWithValues: properties.map { ($0.name, $0.schema) })
        for (key, value) in object.sorted(by: { $0.key < $1.key }) {
            if let schema = known[key] {
                if value.isNull { continue }  // `null` = ausente (modelos costumam mandar null no lugar de omitir)
                errors += schema.validate(value, path: prefix + key)
            } else {
                switch additional {
                case .forbidden: errors.append("\(prefix)\(key): unknown argument")
                case .any: break
                case .schema(let schema): errors += schema.validate(value, path: prefix + key)
                }
            }
        }
        func present(_ key: String) -> Bool { object[key].map { !$0.isNull } ?? false }
        if !exactlyOne.isEmpty {
            let complete = exactlyOne.filter { $0.allSatisfy(present) }
            let touched = exactlyOne.filter { $0.contains(where: present) }
            if complete.count != 1 || touched.count != 1 {
                errors.append("\(path.isEmpty ? "arguments" : path): give exactly one of " +
                              exactlyOne.map { $0.count == 1 ? $0[0] : "(\($0.joined(separator: ", ")))" }.joined(separator: " or "))
            }
        }
        if atMostOne.filter(present).count > 1 { errors.append("\(path.isEmpty ? "arguments" : path): at most one of \(atMostOne.joined(separator: ", "))") }
        if !atLeastOne.isEmpty, !atLeastOne.contains(where: present) {
            errors.append("\(path.isEmpty ? "arguments" : path): give at least one of \(atLeastOne.joined(separator: ", "))")
        }
        return errors
    }

    /// Objeto de argumentos sem as chaves `null` (equivalem a "ausente").
    static func stripNulls(_ object: [String: JSON]) -> [String: JSON] { object.filter { !$0.value.isNull } }
}
