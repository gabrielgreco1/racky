import Foundation

/// Uma linha de `.gitignore` (subconjunto prático da sintaxe do git: `*`, `**`, `?`, classes `[...]`, `!` de negação,
/// `/` inicial ou intermediária que ancora, `/` final que restringe a pastas). Casamento por tokens, sem regex.
public struct GitIgnoreRule: Sendable {
    enum Token: Sendable, Equatable {
        case literal(Character)
        case anyChar
        case star
        /// `**/`: zero ou mais pastas.
        case dirs
        /// `/**` no fim: tudo que há dentro.
        case rest
        case set(negated: Bool, singles: [Character], ranges: [ClosedRange<Character>])
    }

    public let source: String
    public let isNegated: Bool
    public let directoryOnly: Bool
    let anchored: Bool
    let tokens: [Token]

    public init?(line rawLine: String) {
        var line = rawLine
        if line.hasSuffix("\r") { line.removeLast() }
        // Espaços finais não escapados são descartados.
        while line.hasSuffix(" "), !line.hasSuffix("\\ ") { line.removeLast() }
        guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
        var negated = false
        if line.hasPrefix("!") {
            negated = true
            line.removeFirst()
        } else if line.hasPrefix("\\!") || line.hasPrefix("\\#") {
            line.removeFirst()
        }
        var directoryOnly = false
        if line.hasSuffix("/") {
            directoryOnly = true
            line.removeLast()
        }
        guard !line.isEmpty else { return nil }
        var anchored = false
        if line.hasPrefix("/") {
            anchored = true
            line.removeFirst()
        } else if line.contains("/") {
            anchored = true
        }
        source = rawLine
        isNegated = negated
        self.directoryOnly = directoryOnly
        self.anchored = anchored
        tokens = Self.tokenize(line)
    }

    /// `relativePath` usa `/` e é relativo à pasta do `.gitignore`.
    public func matches(_ relativePath: String, isDirectory: Bool) -> Bool {
        if directoryOnly, !isDirectory { return false }
        let path = Array(relativePath)
        if Self.match(tokens, 0, path, 0) { return true }
        guard !anchored else { return false }
        for (index, char) in path.enumerated() where char == "/" {
            if Self.match(tokens, 0, path, index + 1) { return true }
        }
        return false
    }

    static func tokenize(_ glob: String) -> [Token] {
        let chars = Array(glob)
        var out: [Token] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "*":
                if i + 1 < chars.count, chars[i + 1] == "*" {
                    let atStart = i == 0 || chars[i - 1] == "/"
                    if atStart, i + 2 < chars.count, chars[i + 2] == "/" {
                        out.append(.dirs)
                        i += 3
                        continue
                    }
                    if i > 0, chars[i - 1] == "/", i + 2 == chars.count {
                        // `/**` no fim: o `/` já virou literal; "tudo dentro".
                        out.append(.rest)
                        i += 2
                        continue
                    }
                    out.append(.star)
                    i += 2
                    continue
                }
                out.append(.star)
            case "?": out.append(.anyChar)
            case "[":
                if let close = chars[(i + 1)...].firstIndex(of: "]"), close > i + 1 {
                    var body = Array(chars[(i + 1)..<close])
                    var negated = false
                    if body.first == "!" || body.first == "^" {
                        negated = true
                        body.removeFirst()
                    }
                    var singles: [Character] = []
                    var ranges: [ClosedRange<Character>] = []
                    var k = 0
                    while k < body.count {
                        if k + 2 < body.count, body[k + 1] == "-", body[k] <= body[k + 2] {
                            ranges.append(body[k]...body[k + 2])
                            k += 3
                        } else {
                            singles.append(body[k])
                            k += 1
                        }
                    }
                    out.append(.set(negated: negated, singles: singles, ranges: ranges))
                    i = close
                } else {
                    out.append(.literal("["))
                }
            case "\\":
                if i + 1 < chars.count {
                    i += 1
                    out.append(.literal(chars[i]))
                }
            default:
                out.append(.literal(c))
            }
            i += 1
        }
        return out
    }

    static func match(_ tokens: [Token], _ start: Int, _ path: [Character], _ from: Int) -> Bool {
        var ti = start
        var pi = from
        while ti < tokens.count {
            switch tokens[ti] {
            case .literal(let c):
                guard pi < path.count, path[pi] == c else { return false }
                pi += 1
                ti += 1
            case .anyChar:
                guard pi < path.count, path[pi] != "/" else { return false }
                pi += 1
                ti += 1
            case .set(let negated, let singles, let ranges):
                guard pi < path.count, path[pi] != "/" else { return false }
                let ch = path[pi]
                let inSet = singles.contains(ch) || ranges.contains { $0.contains(ch) }
                guard inSet != negated else { return false }
                pi += 1
                ti += 1
            case .star:
                // Casa zero ou mais caracteres que não sejam `/`.
                var end = pi
                while true {
                    if match(tokens, ti + 1, path, end) { return true }
                    guard end < path.count, path[end] != "/" else { return false }
                    end += 1
                }
            case .dirs:
                // Zero ou mais pastas completas.
                if match(tokens, ti + 1, path, pi) { return true }
                var end = pi
                while end < path.count {
                    if path[end] == "/", match(tokens, ti + 1, path, end + 1) { return true }
                    end += 1
                }
                return false
            case .rest:
                return pi < path.count
            }
        }
        return pi == path.count
    }
}

/// Regras de um `.gitignore` (ou `.git/info/exclude`) com a pasta a que valem.
public struct GitIgnoreFile: Sendable {
    /// Caminho absoluto da pasta que contém o arquivo.
    public let directory: String
    public let rules: [GitIgnoreRule]

    public init(directory: String, rules: [GitIgnoreRule]) {
        self.directory = directory
        self.rules = rules
    }

    public init(directory: String, contents: String) {
        self.init(directory: directory, rules: contents.split(separator: "\n", omittingEmptySubsequences: false).compactMap { GitIgnoreRule(line: String($0)) })
    }
}

/// Pilha de `.gitignore` do repositório até a pasta listada. A última regra que casa decide (como no git).
public struct GitIgnoreStack: Sendable {
    public private(set) var files: [GitIgnoreFile]

    public init(files: [GitIgnoreFile] = []) { self.files = files }

    public mutating func push(_ file: GitIgnoreFile) { files.append(file) }

    public var isEmpty: Bool { files.allSatisfy { $0.rules.isEmpty } }

    /// `path` é absoluto. Pastas pai ignoradas devem ser tratadas por quem percorre (a listagem não desce nelas).
    public func isIgnored(_ path: String, isDirectory: Bool) -> Bool {
        var ignored = false
        for file in files {
            let prefix = file.directory.hasSuffix("/") ? file.directory : file.directory + "/"
            guard path.hasPrefix(prefix) else { continue }
            let relative = String(path.dropFirst(prefix.count))
            for rule in file.rules where rule.matches(relative, isDirectory: isDirectory) {
                ignored = !rule.isNegated
            }
        }
        return ignored
    }
}
