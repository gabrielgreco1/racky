import Foundation

/// Link achado numa linha do terminal (03 §4.1): URL ou caminho de arquivo/pasta que existe.
nonisolated public struct TerminalLink: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case url(String)
        /// `path` já resolvido (absoluto, sem `~`, `.` ou `..`); `line`/`column` vêm do sufixo `:12:5`.
        case file(path: String, line: Int?, column: Int?)
    }

    public var kind: Kind
    /// Índices de `Character` na linha (sufixo `:linha:col` incluso, pontuação final fora).
    public var range: Range<Int>
}

/// Detecção pura de link sob uma coluna da linha de texto (ANSI já removido). Sem I/O: a existência do arquivo entra por `exists`.
nonisolated public enum TerminalLinkDetector {
    private static let urlSchemes = ["https://", "http://"]
    private static let wrappers: Set<Character> = ["(", "[", "{"]

    /// Caracteres que nunca fazem parte de um token de link: espaço, aspas, crase, `<>|` e a moldura de TUIs (box drawing).
    private static func isSeparator(_ c: Character) -> Bool {
        if c.isWhitespace || c == "\"" || c == "'" || c == "`" || c == "<" || c == ">" || c == "|" { return true }
        guard let v = c.unicodeScalars.first?.value else { return true }
        return (0x2500...0x257F).contains(v) || v == 0x200B
    }

    public static func detect(
        line: String, column: Int, cwd: String?, home: String = NSHomeDirectory(), exists: (String) -> Bool
    ) -> TerminalLink? {
        let chars = Array(line)
        guard chars.indices.contains(column), !isSeparator(chars[column]) else { return nil }
        var lo = column
        var hi = column + 1
        while lo > 0, !isSeparator(chars[lo - 1]) { lo -= 1 }
        while hi < chars.count, !isSeparator(chars[hi]) { hi += 1 }
        while lo < hi, wrappers.contains(chars[lo]) { lo += 1 }
        guard lo < hi else { return nil }

        if let url = detectURL(chars, lo: lo, hi: hi, column: column) { return url }
        return detectFile(chars, lo: lo, hi: hi, column: column, cwd: cwd, home: home, exists: exists)
    }

    // MARK: URL

    private static func detectURL(_ chars: [Character], lo: Int, hi: Int, column: Int) -> TerminalLink? {
        let token = String(chars[lo..<hi]).lowercased()
        guard let scheme = urlSchemes.first(where: { token.hasPrefix($0) }) else { return nil }
        let end = trimmedEnd(chars, lo: lo, hi: hi, closers: true)
        guard end - lo > scheme.count, column < end else { return nil }
        return TerminalLink(kind: .url(String(chars[lo..<end])), range: lo..<end)
    }

    /// Tira pontuação final de frase e fechamento sem abertura (`(veja https://x.com/a)` → sem o `)`).
    private static func trimmedEnd(_ chars: [Character], lo: Int, hi: Int, closers: Bool) -> Int {
        var end = hi
        while end > lo {
            let c = chars[end - 1]
            if ".,;:!?*".contains(c) {
                end -= 1
            } else if closers, let open = Self.opener(for: c) {
                let slice = chars[lo..<end]
                if slice.filter({ $0 == open }).count < slice.filter({ $0 == c }).count { end -= 1 } else { break }
            } else {
                break
            }
        }
        return end
    }

    private static func opener(for closer: Character) -> Character? {
        switch closer {
        case ")": "("
        case "]": "["
        case "}": "{"
        default: nil
        }
    }

    // MARK: Arquivo

    private static func detectFile(
        _ chars: [Character], lo: Int, hi tokenHi: Int, column: Int, cwd: String?, home: String, exists: (String) -> Bool
    ) -> TerminalLink? {
        var lo = lo
        // `--out=build/x`: o que vem antes do `=` (sem barra) é a opção, não o caminho.
        if let eq = chars[lo..<tokenHi].firstIndex(of: "="), !chars[lo..<eq].contains("/") { lo = eq + 1 }
        guard lo < tokenHi else { return nil }
        let end = trimmedEnd(chars, lo: lo, hi: tokenHi, closers: true)
        guard lo < end, column >= lo, column < end else { return nil }
        let (base, line, col) = splitLocation(String(chars[lo..<end]))
        guard isPlausible(base), let candidates = candidates(for: base, cwd: cwd, home: home) else { return nil }
        guard let path = candidates.first(where: exists) else { return nil }
        return TerminalLink(kind: .file(path: path, line: line, column: col), range: lo..<end)
    }

    /// `src/a.swift:12:5` → (`src/a.swift`, 12, 5); `a.ts(12,5)` → (`a.ts`, 12, 5). Sem número, devolve o texto como veio.
    static func splitLocation(_ text: String) -> (base: String, line: Int?, column: Int?) {
        if text.hasSuffix(")"), let open = text.lastIndex(of: "(") {
            let nums = text[text.index(after: open)..<text.index(before: text.endIndex)].split(separator: ",", omittingEmptySubsequences: false)
            if (1...2).contains(nums.count), let l = Int(nums[0]), nums.count == 1 || Int(nums[1]) != nil {
                return (String(text[..<open]), l, nums.count == 2 ? Int(nums[1]) : nil)
            }
        }
        var parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if parts.count > 1, parts.last == "" { parts.removeLast() }  // `foo.swift:12:` (erro do compilador)
        var numbers: [Int] = []
        while parts.count > 1, numbers.count < 2, let n = Int(parts[parts.count - 1]), n >= 0, parts[parts.count - 1].allSatisfy(\.isASCII) {
            numbers.insert(n, at: 0)
            parts.removeLast()
        }
        return (parts.joined(separator: ":"), numbers.first, numbers.count > 1 ? numbers[1] : nil)
    }

    /// Descarta o que obviamente não é caminho: vazio, só pontos/barras, outro esquema (`ftp://`) ou número solto (`12:30`).
    private static func isPlausible(_ base: String) -> Bool {
        guard !base.isEmpty, !base.contains("://"), !base.unicodeScalars.contains("\0") else { return false }
        if base.allSatisfy({ $0 == "." || $0 == "/" }) { return false }
        return base.contains("/") || base.contains(where: \.isLetter)
    }

    /// Caminhos a testar, em ordem: o resolvido e, se vier de `git diff` (`a/…`, `b/…`), o sem o prefixo.
    private static func candidates(for base: String, cwd: String?, home: String) -> [String]? {
        func resolve(_ p: String) -> String? {
            let full: String
            if p == "~" { full = home } else if p.hasPrefix("~/") { full = home + "/" + p.dropFirst(2) } else if p.hasPrefix("/") { full = p } else {
                guard let cwd, cwd.hasPrefix("/") else { return nil }
                full = cwd + "/" + p
            }
            return (full as NSString).standardizingPath
        }
        guard let first = resolve(base) else { return nil }
        var list = [first]
        if (base.hasPrefix("a/") || base.hasPrefix("b/")), let stripped = resolve(String(base.dropFirst(2))) { list.append(stripped) }
        return list
    }

    // MARK: Colunas do terminal

    /// Células ocupadas por um caractere: 2 para CJK/emoji largos, senão 1. O SwiftTerm omite a célula de continuação ao
    /// montar o texto da linha, então índice de `Character` e coluna divergem depois de um glifo largo.
    static func cellWidth(_ c: Character) -> Int {
        guard let v = c.unicodeScalars.first?.value else { return 1 }
        switch v {
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE6F, 0xFF00...0xFF60,
            0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }

    /// Índice do `Character` que cobre a coluna (células); `nil` além do fim do texto.
    public static func characterIndex(forColumn column: Int, in line: String) -> Int? {
        guard column >= 0 else { return nil }
        var cell = 0
        for (index, c) in line.enumerated() {
            cell += cellWidth(c)
            if column < cell { return index }
        }
        return nil
    }

    /// Faixa de colunas (células) coberta por uma faixa de `Character`.
    public static func columns(of range: Range<Int>, in line: String) -> Range<Int> {
        var cell = 0
        var start = 0
        var end = 0
        for (index, c) in line.enumerated() {
            if index == range.lowerBound { start = cell }
            cell += cellWidth(c)
            if index == range.upperBound - 1 { end = cell }
        }
        return start..<max(start, end)
    }
}
