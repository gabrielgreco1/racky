import Foundation

/// Versão semântica de um CLI (`2.1.302`, `0.163.0`). Sufixos (`-beta`) são ignorados na comparação.
public struct CLIVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(_ major: Int, _ minor: Int = 0, _ patch: Int = 0) {
        self.major = major; self.minor = minor; self.patch = patch
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: CLIVersion, rhs: CLIVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    /// Primeira ocorrência de `N.N` ou `N.N.N` no texto de `--version` (ex.: `2.1.302 (Claude Code)`, `codex-cli 0.163.0`).
    public static func parse(_ text: String) -> CLIVersion? {
        guard let match = text.firstMatch(of: /(\d+)\.(\d+)(?:\.(\d+))?/),
              let major = Int(match.1), let minor = Int(match.2) else { return nil }
        let patch = match.3.flatMap { Int($0) } ?? 0
        return CLIVersion(major, minor, patch)
    }
}

/// Tokenização "shell-words" para Custom Command e `extraArgs` digitados (06 §2.2): aspas simples e duplas,
/// barra invertida, sem expansão de variáveis nem de `$(...)`. Nada é interpretado por um shell.
public enum ShellWords {
    public enum Failure: Error, Equatable, Sendable { case unterminatedQuote, danglingEscape }

    public static func split(_ input: String) throws -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escaping = false
        for ch in input {
            if escaping {
                current.append(ch); escaping = false; inWord = true
                continue
            }
            if let q = quote {
                if ch == q { quote = nil }
                else if ch == "\\", q == "\"" { escaping = true }
                else { current.append(ch) }
                continue
            }
            switch ch {
            case "'", "\"": quote = ch; inWord = true
            case "\\": escaping = true
            case " ", "\t", "\n", "\r":
                if inWord { words.append(current); current = ""; inWord = false }
            default: current.append(ch); inWord = true
            }
        }
        if escaping { throw Failure.danglingEscape }
        if quote != nil { throw Failure.unterminatedQuote }
        if inWord { words.append(current) }
        return words
    }
}
