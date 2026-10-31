import Foundation

public enum FieldStatus: String, Sendable, Equatable { case verified, citedMissing = "cited_missing", notVerified = "not_verified" }

public struct Citation: Sendable, Equatable {
    public enum Kind: String, Sendable { case request, file }
    public var ref: String
    public var kind: Kind
    /// `observed` (egress, runtime, app) ou `reported` (hooks do `work`); só para citações de request que existem.
    public var trust: String?
    public var exists: Bool

    public init(ref: String, kind: Kind, trust: String? = nil, exists: Bool) { self.ref = ref; self.kind = kind; self.trust = trust; self.exists = exists }

    public var json: JSON {
        var o: [String: JSON] = ["ref": .string(ref), "kind": .string(kind.rawValue)]
        if let trust { o["trust"] = .string(trust) }
        return .object(o)
    }
}

public struct FieldValidation: Sendable, Equatable {
    public var pointer: String
    public var status: FieldStatus
    public var citations: [Citation]

    public init(pointer: String, status: FieldStatus, citations: [Citation]) { self.pointer = pointer; self.status = status; self.citations = citations }
}

public struct ResultValidation: Sendable, Equatable {
    public var fields: [FieldValidation]

    public init(fields: [FieldValidation]) { self.fields = fields }

    public var verified: Int { fields.filter { $0.status == .verified }.count }
    public var citedMissing: Int { fields.filter { $0.status == .citedMissing }.count }
    public var notVerified: Int { fields.filter { $0.status == .notVerified }.count }

    public var json: JSON {
        ["fields": .array(fields.map { f in
            ["pointer": .string(f.pointer), "status": .string(f.status.rawValue), "citations": .array(f.citations.map(\.json))]
        }), "summary": ["verified": .int(verified), "cited_missing": .int(citedMissing), "not_verified": .int(notVerified)]]
    }
}

/// Validador de evidência (07 CS-262/263, audit/08 N8, N23): cada citação precisa ser um `request_id` existente no reqlog
/// **deste computador** ou um arquivo existente em `/work` (CS-234). Cada campo vira `verified`, `cited_missing` ou
/// `not_verified`. Registros `reported` mostram o selo `"Agent-reported"` na UI (CS-263); aqui só viaja o `trust`.
public struct ResultValidator: Sendable {
    /// `id` -> `trust` dos registros do reqlog deste computador.
    public var requests: [String: String]
    /// Decide se um arquivo citado existe em `/work` (já com `PathGuard`: symlink e `..` contam como inexistentes).
    public var fileExists: @Sendable (String) -> Bool

    public init(requests: [String: String], fileExists: @escaping @Sendable (String) -> Bool) {
        self.requests = requests
        self.fileExists = fileExists
    }

    /// Lê `id` e `trust` de cada linha de `requests.jsonl`.
    public static func index(requestsFile: URL) -> [String: String] {
        var out: [String: String] = [:]
        for entry in ChainedLog.read(requestsFile) {
            if let id = entry["id"]?.string { out[id] = entry["trust"]?.string ?? "observed" }
        }
        return out
    }

    static let ulidAlphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    public static func looksLikeRequestID(_ ref: String) -> Bool { ref.count == 26 && ref.allSatisfy { ulidAlphabet.contains($0) } }

    func citation(_ ref: String) -> Citation {
        if Self.looksLikeRequestID(ref) {
            let trust = requests[ref]
            return Citation(ref: ref, kind: .request, trust: trust, exists: trust != nil)
        }
        return Citation(ref: ref, kind: .file, trust: nil, exists: fileExists(ref))
    }

    /// Ponteiro JSON (RFC 6901) existe em `result`?
    static func resolve(_ pointer: String, in result: JSON) -> JSON? {
        if pointer.isEmpty { return result }
        guard pointer.hasPrefix("/") else { return nil }
        var current = result
        for raw in pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            let key = raw.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            switch current {
            case .object(let o):
                guard let next = o[key] else { return nil }
                current = next
            case .array(let a):
                guard let i = Int(key), i >= 0, i < a.count else { return nil }
                current = a[i]
            default: return nil
            }
        }
        return current
    }

    static func escape(_ key: String) -> String { key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1") }

    /// `evidence`: ponteiro -> citações. Um ponteiro cobre a si e aos descendentes. Ponteiro inválido ou que não existe em
    /// `result` lança `invalid_argument` (erro de uso, não de evidência).
    public func validate(result: JSON, evidence: [String: [String]]) throws -> ResultValidation {
        guard case .object(let top) = result else { throw ToolError.invalid("result must be an object") }
        for pointer in evidence.keys where Self.resolve(pointer, in: result) == nil {
            let hint = pointer.hasPrefix("/") ? "" : " (evidence keys are JSON Pointers into result, for example /title or /items/0/price)"
            throw ToolError.invalid("evidence pointer does not exist in result: \(pointer)\(hint)", details: ["pointer": .string(pointer)])
        }
        var pointers = top.keys.sorted().map { "/" + Self.escape($0) }
        for pointer in evidence.keys.sorted() where !pointers.contains(pointer) { pointers.append(pointer) }
        let fields = pointers.map { pointer -> FieldValidation in
            let cited = evidence.filter { pointer == $0.key || pointer.hasPrefix($0.key + "/") }.sorted { $0.key < $1.key }.flatMap(\.value)
            var seen = Set<String>()
            let citations = cited.filter { seen.insert($0).inserted }.map(citation)
            let status: FieldStatus = citations.isEmpty ? .notVerified : (citations.allSatisfy(\.exists) ? .verified : .citedMissing)
            return FieldValidation(pointer: pointer, status: status, citations: citations)
        }
        return ResultValidation(fields: fields)
    }

    /// `box_collect` sobre um `result.json` escrito à mão (audit/08 N8): procura ids pelo padrão em cada campo de topo.
    public func validateHandwritten(resultData: Data) throws -> ResultValidation {
        guard let result = try? JSON.parse(resultData) else { throw ToolError.invalid("result.json is not valid JSON") }
        guard case .object(let top) = result else { throw ToolError.invalid("result.json must be an object") }
        var evidence: [String: [String]] = [:]
        for (key, value) in top {
            let ids = Self.requestIDs(in: value)
            if !ids.isEmpty { evidence["/" + Self.escape(key)] = ids }
        }
        return try validate(result: result, evidence: evidence)
    }

    /// Todas as strings do valor que têm cara de ULID (também dentro de texto livre).
    static func requestIDs(in value: JSON) -> [String] {
        var out: [String] = []
        func scan(_ v: JSON) {
            switch v {
            case .string(let s):
                var run: [Character] = []
                func flush() { if run.count == 26 { out.append(String(run)) }; run.removeAll() }
                for ch in s { if ulidAlphabet.contains(ch) { run.append(ch) } else { flush() } }
                flush()
            case .array(let a): a.forEach(scan)
            case .object(let o): o.values.forEach(scan)
            default: break
            }
        }
        scan(value)
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }
}
