import Foundation

/// Valor de frontmatter, reduzido ao que o catálogo usa. Estruturas aninhadas (`mcpServers`, mapas) ficam como texto cru.
public enum FrontmatterValue: Sendable, Equatable {
    case string(String)
    case list([String])
    case raw(String)

    public var text: String? {
        switch self {
        case .string(let s), .raw(let s): s
        case .list(let l): l.joined(separator: ", ")
        }
    }
}

public struct FrontmatterError: Sendable, Equatable {
    /// Linha (1-based) no arquivo.
    public var line: Int
    public var message: String
    public var summary: String { "Invalid frontmatter (line \(line)): \(message)" }
}

public struct FrontmatterResult: Sendable, Equatable {
    public var hasFrontmatter: Bool
    public var fields: [String: FrontmatterValue]
    public var error: FrontmatterError?
}

/// Subconjunto de YAML suficiente para `---` de agentes e skills: escalares (puros, com aspas, `|` e `>`), listas inline
/// e em bloco, e valores aninhados mantidos como texto cru. Nunca avalia nada (08: dados, não código).
public enum FrontmatterParser {
    /// O texto depois do `---` de fechamento (sem a linha em branco inicial). Sem frontmatter, o texto inteiro; frontmatter aberto
    /// e nunca fechado, nada (o arquivo está inválido: o preview mostra o erro).
    public static func body(of text: String) -> String {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let first = lines.first, first.hasPrefix("\u{FEFF}") { lines[0] = String(first.dropFirst()) }
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else { return text }
        guard let close = lines.indices.dropFirst().first(where: {
            let t = lines[$0].trimmingCharacters(in: .whitespaces)
            return t == "---" || t == "..."
        }) else { return "" }
        var rest = Array(lines[(close + 1)...])
        while rest.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { rest.removeFirst() }
        return rest.joined(separator: "\n")
    }

    public static func parse(_ text: String) -> FrontmatterResult {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let first = lines.first, first.hasPrefix("\u{FEFF}") { lines[0] = String(first.dropFirst()) }
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else {
            return FrontmatterResult(hasFrontmatter: false, fields: [:], error: nil)
        }
        guard let close = lines.indices.dropFirst().first(where: {
            let t = lines[$0].trimmingCharacters(in: .whitespaces)
            return t == "---" || t == "..."
        }) else {
            return FrontmatterResult(hasFrontmatter: true, fields: [:], error: FrontmatterError(line: 1, message: "frontmatter is never closed"))
        }
        var fields: [String: FrontmatterValue] = [:]
        var i = 1
        func fail(_ line: Int, _ message: String) -> FrontmatterResult {
            FrontmatterResult(hasFrontmatter: true, fields: fields, error: FrontmatterError(line: line, message: message))
        }
        func indent(_ s: String) -> Int { s.prefix(while: { $0 == " " }).count }
        while i < close {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { i += 1; continue }
            if line.hasPrefix("\t") { return fail(i + 1, "tab used for indentation") }
            guard indent(line) == 0, let colon = line.firstIndex(of: ":"),
                  line[..<colon].range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil else {
                return fail(i + 1, "expected `key: value`")
            }
            let key = String(line[..<colon])
            let rest = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            let startLine = i + 1
            i += 1
            // Linhas de continuação: indentadas, em branco entre elas, ou itens de lista no nível 0.
            func continuation() -> [String] {
                var out: [String] = []
                while i < close {
                    let l = lines[i]
                    if l.trimmingCharacters(in: .whitespaces).isEmpty { out.append(""); i += 1; continue }
                    if indent(l) > 0 || l.hasPrefix("- ") || l == "-" { out.append(l); i += 1 } else { break }
                }
                while out.last == "" { out.removeLast() }
                return out
            }
            if rest.isEmpty {
                let block = continuation()
                let items = block.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
                if items.isEmpty { fields[key] = .string("") }
                else if items.allSatisfy({ $0.hasPrefix("- ") && !$0.dropFirst(2).contains(": ") }) {
                    fields[key] = .list(items.map { unquote(String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces)) })
                } else { fields[key] = .raw(block.joined(separator: "\n")) }
            } else if rest.hasPrefix("|") || rest.hasPrefix(">") {
                let block = continuation()
                let trimmedBlock = block.map { $0.trimmingCharacters(in: .whitespaces) }
                fields[key] = .string(rest.hasPrefix("|") ? trimmedBlock.joined(separator: "\n")
                                                          : trimmedBlock.filter { !$0.isEmpty }.joined(separator: " "))
            } else if rest.hasPrefix("[") {
                var joined = rest
                for extra in continuation() where !joined.hasSuffix("]") { joined += " " + extra.trimmingCharacters(in: .whitespaces) }
                guard joined.hasSuffix("]") else { return fail(startLine, "list is never closed") }
                fields[key] = .list(splitInline(String(joined.dropFirst().dropLast())))
            } else if rest.hasPrefix("{") {
                var joined = rest
                for extra in continuation() where !joined.hasSuffix("}") { joined += " " + extra.trimmingCharacters(in: .whitespaces) }
                guard joined.hasSuffix("}") else { return fail(startLine, "mapping is never closed") }
                fields[key] = .raw(joined)
            } else if let quote = rest.first, quote == "\"" || quote == "'" {
                var joined = rest
                while !closesQuote(joined, quote: quote) {
                    guard i < close, indent(lines[i]) > 0 else { return fail(startLine, "quoted string is never closed") }
                    joined += " " + lines[i].trimmingCharacters(in: .whitespaces); i += 1
                }
                fields[key] = .string(unquote(joined))
            } else {
                var value = stripComment(rest)
                for extra in continuation() where !extra.isEmpty { value += " " + stripComment(extra.trimmingCharacters(in: .whitespaces)) }
                fields[key] = .string(value)
            }
        }
        return FrontmatterResult(hasFrontmatter: true, fields: fields, error: nil)
    }

    private static func closesQuote(_ s: String, quote: Character) -> Bool {
        let chars = Array(s)
        var idx = 1
        while idx < chars.count {
            let c = chars[idx]
            if quote == "\"" && c == "\\" { idx += 2; continue }
            if c == quote {
                if quote == "'" && idx + 1 < chars.count && chars[idx + 1] == "'" { idx += 2; continue }
                return true
            }
            idx += 1
        }
        return false
    }

    private static func stripComment(_ s: String) -> String {
        if let r = s.range(of: " #") { return String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespaces) }
        return s
    }

    static func unquote(_ s: String) -> String {
        guard s.count >= 2, let q = s.first, q == "\"" || q == "'" else { return s }
        guard let end = s.lastIndex(of: q), end > s.startIndex else { return s }
        let inner = String(s[s.index(after: s.startIndex)..<end])
        if q == "'" { return inner.replacingOccurrences(of: "''", with: "'") }
        var out = "", escaping = false
        for c in inner {
            if escaping {
                switch c { case "n": out.append("\n"); case "t": out.append("\t"); default: out.append(c) }
                escaping = false
            } else if c == "\\" { escaping = true } else { out.append(c) }
        }
        return out
    }

    private static func splitInline(_ s: String) -> [String] {
        var items: [String] = [], current = "", quote: Character?
        for c in s {
            if let q = quote { current.append(c); if c == q { quote = nil } }
            else if c == "\"" || c == "'" { quote = c; current.append(c) }
            else if c == "," { items.append(current); current = "" }
            else { current.append(c) }
        }
        items.append(current)
        return items.map { unquote($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
    }
}

/// Leitor mínimo de TOML para `~/.codex/agents/*.toml`: só chaves de topo com string (`"..."`, `'...'` ou `"""..."""`).
/// Outras formas de valor são ignoradas; tabelas `[x]` encerram o topo.
public enum AgentTOML {
    public struct Result: Sendable, Equatable {
        public var fields: [String: String]
        public var error: FrontmatterError?
    }

    public static func parse(_ text: String) -> Result {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var fields: [String: String] = [:]
        var i = 0
        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { i += 1; continue }
            if line.hasPrefix("[") { break }
            guard let eq = line.firstIndex(of: "="),
                  line[..<eq].trimmingCharacters(in: .whitespaces).range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
                return Result(fields: fields, error: FrontmatterError(line: i + 1, message: "expected `key = value`"))
            }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            let start = i + 1
            i += 1
            if value.hasPrefix("\"\"\"") || value.hasPrefix("'''") {
                let delim = String(value.prefix(3))
                var body = String(value.dropFirst(3))
                if let end = body.range(of: delim) { fields[key] = String(body[..<end.lowerBound]); continue }
                var collected: [String] = body.isEmpty ? [] : [body]
                var closed = false
                while i < lines.count {
                    if let end = lines[i].range(of: delim) { collected.append(String(lines[i][..<end.lowerBound])); closed = true; i += 1; break }
                    collected.append(lines[i]); i += 1
                }
                guard closed else { return Result(fields: fields, error: FrontmatterError(line: start, message: "multi-line string is never closed")) }
                body = collected.joined(separator: "\n")
                fields[key] = body
            } else if value.hasPrefix("\"") || value.hasPrefix("'") {
                let q = value.first!
                guard value.count >= 2, let end = value.dropFirst().lastIndex(of: q) else {
                    return Result(fields: fields, error: FrontmatterError(line: start, message: "string is never closed"))
                }
                let inner = String(value[value.index(after: value.startIndex)..<end])
                fields[key] = q == "\"" ? FrontmatterParser.unquote("\"" + inner + "\"") : inner
            } else if value.hasPrefix("[") && !value.contains("]") {
                while i < lines.count, !lines[i].contains("]") { i += 1 }
                i += 1
            }
        }
        return Result(fields: fields, error: nil)
    }
}
