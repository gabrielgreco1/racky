import Foundation

/// Categoria de um trecho colorido. A UI mapeia cada uma para um token do DS (paleta do terminal).
public enum SyntaxKind: String, Sendable, Equatable, CaseIterable {
    case comment, string, keyword, number, type, function, key, attribute, heading, tag
}

public struct SyntaxSpan: Sendable, Equatable {
    public var range: NSRange
    public var kind: SyntaxKind

    public init(range: NSRange, kind: SyntaxKind) {
        self.range = range
        self.kind = kind
    }
}

public enum SyntaxLanguage: String, Sendable, CaseIterable {
    case plain, swift, javascript, typescript, python, ruby, go, rust, c, cpp, java, kotlin, shell, json, yaml, toml
    case markdown, html, xml, css, sql, php, lua

    /// Linguagem pela extensão ou pelo nome do arquivo.
    public static func forFile(named name: String) -> SyntaxLanguage {
        let lower = name.lowercased()
        switch lower {
        case "makefile", "dockerfile", "gemfile", "rakefile", "podfile", "brewfile": return lower == "dockerfile" || lower == "makefile" ? .shell : .ruby
        case ".zshrc", ".bashrc", ".zprofile", ".profile", ".bash_profile", ".envrc": return .shell
        case ".gitignore", ".dockerignore", ".gitattributes": return .shell
        default: break
        }
        switch (lower as NSString).pathExtension {
        case "swift": return .swift
        case "js", "jsx", "mjs", "cjs": return .javascript
        case "ts", "tsx", "mts", "cts": return .typescript
        case "py", "pyi": return .python
        case "rb", "rake", "gemspec": return .ruby
        case "go": return .go
        case "rs": return .rust
        case "c", "h", "m", "mm": return .c
        case "cc", "cpp", "cxx", "hpp", "hh", "hxx": return .cpp
        case "java": return .java
        case "kt", "kts": return .kotlin
        case "sh", "zsh", "bash", "fish", "env": return .shell
        case "json", "jsonc", "json5", "geojson", "resolved": return .json
        case "yml", "yaml": return .yaml
        case "toml", "ini", "cfg", "conf": return .toml
        case "md", "markdown", "mdx": return .markdown
        case "html", "htm", "xhtml", "vue", "svelte": return .html
        case "xml", "plist", "svg", "xib", "storyboard", "xcconfig": return lower.hasSuffix("xcconfig") ? .toml : .xml
        case "css", "scss", "less": return .css
        case "sql": return .sql
        case "php": return .php
        case "lua": return .lua
        default: return .plain
        }
    }
}

/// Realce leve de sintaxe (10-right-panel §2): comentários, strings, palavras-chave, números, tipos, chamadas e chaves.
/// Um scanner de uma passada sobre UTF-16, sem regex e sem gramática completa: errar um caso raro custa só uma cor.
public enum SyntaxHighlighter {
    /// Acima disto o resto do arquivo fica sem cor (a UI avisa que o realce foi limitado).
    public static let defaultLimit = 400_000

    public static func spans(in text: String, language: SyntaxLanguage, limit: Int = defaultLimit) -> [SyntaxSpan] {
        guard language != .plain else { return [] }
        let all = Array(text.utf16)
        let units = all.count > limit ? Array(all.prefix(limit)) : all
        if language == .markdown { return markdownSpans(units) }
        var scanner = HighlightScanner(units: units, spec: Spec.spec(for: language))
        scanner.run()
        return scanner.spans
    }
}

// MARK: - Especificação por linguagem

struct Spec {
    var lineComments: [String] = []
    var blockComments: [(String, String)] = []
    var quotes: Set<UInt16> = [0x22, 0x27]  // " '
    var multilineQuotes: Set<UInt16> = []
    var tripleQuotes = false
    var keywords: Set<String> = []
    var caseInsensitiveKeywords = false
    var typesCapitalized = true
    var calls = true
    /// `@nome` (Swift, Java, Kotlin, Python decorators) e `#[...]`.
    var atAttributes = false
    /// `#word` no começo de linha (preprocessador C, `#if` do Swift).
    var hashDirectives = false
    var markup = false
    var jsonKeys = false
    var yamlKeys = false
    var tomlKeys = false
    var cssMode = false
    var shellComments = false
    /// Aspas simples só como literal de caractere (Rust: `'a'`, mas `'a` é lifetime).
    var charLiteralQuote = false
    var identExtra: Set<UInt16> = []

    static func words(_ list: String) -> Set<String> { Set(list.split(separator: " ").map(String.init)) }

    // swiftlint:disable:next function_body_length
    static func spec(for language: SyntaxLanguage) -> Spec {
        var s = Spec()
        switch language {
        case .plain, .markdown:
            break
        case .swift:
            s.lineComments = ["//"]
            s.blockComments = [("/*", "*/")]
            s.quotes = [0x22]
            s.atAttributes = true
            s.hashDirectives = true
            s.keywords = words("""
                associatedtype async await break case catch class continue default defer deinit do else enum extension fallthrough \
                false fileprivate final for func guard if import in indirect init inout internal is lazy let mutating nil nonisolated \
                open operator override precedencegroup private protocol public repeat rethrows return self Self static struct subscript \
                super switch throw throws true try typealias var weak where while actor some any macro consuming borrowing
                """)
        case .javascript, .typescript:
            s.lineComments = ["//"]
            s.blockComments = [("/*", "*/")]
            s.multilineQuotes = [0x60]
            s.quotes = [0x22, 0x27, 0x60]
            s.atAttributes = language == .typescript
            s.keywords = words("""
                async await break case catch class const continue debugger default delete do else export extends false finally for from \
                function if import in instanceof let new null of return static super switch this throw true try typeof undefined var void \
                while with yield interface type enum implements namespace declare readonly abstract as keyof satisfies private public protected
                """)
        case .python:
            s.lineComments = ["#"]
            s.tripleQuotes = true
            s.atAttributes = true
            s.keywords = words("""
                and as assert async await break class continue def del elif else except False finally for from global if import in is \
                lambda None nonlocal not or pass raise return True try while with yield match case self cls
                """)
        case .ruby:
            s.lineComments = ["#"]
            s.keywords = words("""
                alias and begin break case class def defined do else elsif end ensure false for if in module next nil not or redo rescue \
                retry return self super then true undef unless until when while yield require require_relative attr_accessor attr_reader \
                attr_writer private public protected include extend
                """)
        case .go:
            s.lineComments = ["//"]
            s.blockComments = [("/*", "*/")]
            s.multilineQuotes = [0x60]
            s.quotes = [0x22, 0x27, 0x60]
            s.keywords = words("""
                break case chan const continue default defer else fallthrough for func go goto if import interface map package range return \
                select struct switch type var nil true false iota
                """)
        case .rust:
            s.lineComments = ["//"]
            s.blockComments = [("/*", "*/")]
            s.charLiteralQuote = true
            s.atAttributes = true
            s.keywords = words("""
                as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref \
                return self Self static struct super trait true type unsafe use where while macro_rules
                """)
        case .c, .cpp:
            s.lineComments = ["//"]
            s.blockComments = [("/*", "*/")]
            s.hashDirectives = true
            s.atAttributes = true
            s.keywords = words("""
                auto break case char const continue default do double else enum extern float for goto if inline int long register return \
                short signed sizeof static struct switch typedef union unsigned void volatile while bool true false NULL nil class public \
                private protected namespace template typename using virtual new delete this nullptr constexpr override final try catch throw \
                operator explicit friend mutable noexcept static_cast dynamic_cast reinterpret_cast const_cast id self super YES NO
                """)
        case .java, .kotlin:
            s.lineComments = ["//"]
            s.blockComments = [("/*", "*/")]
            s.atAttributes = true
            s.keywords = words("""
                abstract assert boolean break byte case catch char class const continue default do double else enum extends final finally \
                float for goto if implements import instanceof int interface long native new null package private protected public return \
                short static strictfp super switch synchronized this throw throws transient true false try void volatile while fun val var \
                when object companion data sealed override open internal lateinit by in is as typealias suspend inline
                """)
        case .shell:
            s.lineComments = []
            s.shellComments = true
            s.typesCapitalized = false
            s.calls = false
            s.identExtra = [0x2D]  // -
            s.keywords = words("""
                if then else elif fi for while until do done case esac in function select time return exit break continue export local \
                readonly declare unset source alias set shift trap eval exec cd echo test FROM RUN CMD COPY ADD ENV ARG WORKDIR EXPOSE ENTRYPOINT \
                VOLUME USER LABEL HEALTHCHECK
                """)
        case .json:
            s.quotes = [0x22]
            s.jsonKeys = true
            s.typesCapitalized = false
            s.calls = false
            s.lineComments = ["//"]
            s.blockComments = [("/*", "*/")]
            s.keywords = words("true false null")
        case .yaml:
            s.lineComments = ["#"]
            s.yamlKeys = true
            s.typesCapitalized = false
            s.calls = false
            s.identExtra = [0x2D, 0x2E, 0x2F]  // - . /
            s.keywords = words("true false null yes no on off True False Null")
        case .toml:
            s.lineComments = ["#", ";"]
            s.tomlKeys = true
            s.typesCapitalized = false
            s.calls = false
            s.identExtra = [0x2D, 0x2E]
            s.keywords = words("true false")
        case .html, .xml:
            s.blockComments = [("<!--", "-->")]
            s.markup = true
            s.quotes = []
            s.typesCapitalized = false
            s.calls = false
        case .css:
            s.blockComments = [("/*", "*/")]
            s.cssMode = true
            s.typesCapitalized = false
            s.calls = false
            s.identExtra = [0x2D]
        case .sql:
            s.lineComments = ["--"]
            s.blockComments = [("/*", "*/")]
            s.quotes = [0x27, 0x22]
            s.caseInsensitiveKeywords = true
            s.typesCapitalized = false
            s.keywords = words("""
                select from where and or not insert into values update set delete create table alter drop index view join left right inner outer \
                full on as group by order having limit offset union all distinct case when then else end null is in like between exists primary key \
                foreign references default unique constraint begin commit rollback with returning asc desc int integer text varchar boolean \
                timestamp date uuid serial
                """)
        case .php:
            s.lineComments = ["//", "#"]
            s.blockComments = [("/*", "*/")]
            s.keywords = words("""
                abstract and array as break case catch class clone const continue declare default do echo else elseif empty extends final \
                finally fn for foreach function global if implements include include_once instanceof interface isset list namespace new or \
                print private protected public require require_once return static switch throw trait try unset use var while yield null true false
                """)
        case .lua:
            s.lineComments = ["--"]
            s.blockComments = [("--[[", "]]")]
            s.keywords = words("""
                and break do else elseif end false for function goto if in local nil not or repeat return then true until while
                """)
        }
        return s
    }
}

// MARK: - Scanner

private struct HighlightScanner {
    let units: [UInt16]
    let spec: Spec
    var spans: [SyntaxSpan] = []
    private var i = 0
    private var braceDepth = 0
    private let lineComments: [[UInt16]]
    private let blockComments: [([UInt16], [UInt16])]

    init(units: [UInt16], spec: Spec) {
        self.units = units
        self.spec = spec
        lineComments = spec.lineComments.map { Array($0.utf16) }
        blockComments = spec.blockComments.map { (Array($0.0.utf16), Array($0.1.utf16)) }
    }

    private static let newline: UInt16 = 0x0A

    private func starts(with token: [UInt16], at index: Int) -> Bool {
        guard index + token.count <= units.count else { return false }
        for k in 0..<token.count where units[index + k] != token[k] { return false }
        return true
    }

    private func isIdentStart(_ c: UInt16) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c == 0x24 || c > 0x7F
    }

    private func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }

    private func isIdentPart(_ c: UInt16) -> Bool { isIdentStart(c) || isDigit(c) || spec.identExtra.contains(c) }

    private func lineEnd(from index: Int) -> Int {
        var j = index
        while j < units.count, units[j] != Self.newline { j += 1 }
        return j
    }

    private func atLineStart(_ index: Int) -> Bool {
        var j = index - 1
        while j >= 0 {
            if units[j] == Self.newline { return true }
            if units[j] != 0x20 && units[j] != 0x09 { return false }
            j -= 1
        }
        return true
    }

    private mutating func add(_ kind: SyntaxKind, _ start: Int, _ end: Int) {
        guard end > start else { return }
        spans.append(SyntaxSpan(range: NSRange(location: start, length: end - start), kind: kind))
    }

    private func nextNonBlank(from index: Int) -> UInt16? {
        var j = index
        while j < units.count, units[j] == 0x20 || units[j] == 0x09 { j += 1 }
        return j < units.count ? units[j] : nil
    }

    private func word(_ start: Int, _ end: Int) -> String { String(decoding: units[start..<end], as: UTF16.self) }

    mutating func run() {
        let n = units.count
        while i < n {
            let c = units[i]
            if scanComment(c) { continue }
            if spec.markup, c == 0x3C, scanTag() { continue }
            if spec.tripleQuotes, scanTriple(c) { continue }
            if spec.quotes.contains(c) {
                if spec.charLiteralQuote, c == 0x27 {
                    if scanCharLiteral() { continue }
                    i += 1
                    continue
                }
                scanString(c)
                continue
            }
            if spec.cssMode {
                if c == 0x7B { braceDepth += 1 } else if c == 0x7D { braceDepth = max(0, braceDepth - 1) }
                if c == 0x40, scanAtRule() { continue }
            }
            if c == 0x40, spec.atAttributes, scanAtAttribute() { continue }
            if c == 0x23, spec.hashDirectives, atLineStart(i), scanHashDirective() { continue }
            if c == 0x5B, spec.tomlKeys, atLineStart(i) { scanTomlSection(); continue }
            if isDigit(c), i == 0 || !isIdentPart(units[i - 1]) {
                scanNumber()
                continue
            }
            if isIdentStart(c) {
                scanIdentifier()
                continue
            }
            i += 1
        }
    }

    // MARK: Comentários

    private mutating func scanComment(_ c: UInt16) -> Bool {
        if spec.shellComments, c == 0x23 {
            let boundary = i == 0 || units[i - 1] == 0x20 || units[i - 1] == 0x09 || units[i - 1] == Self.newline
            if boundary {
                let end = lineEnd(from: i)
                add(.comment, i, end)
                i = end
                return true
            }
        }
        for token in lineComments where starts(with: token, at: i) {
            // `#` em YAML/TOML/Python só abre comentário no começo da palavra.
            if token == [0x23], i > 0, units[i - 1] != 0x20, units[i - 1] != 0x09, units[i - 1] != Self.newline { continue }
            let end = lineEnd(from: i)
            add(.comment, i, end)
            i = end
            return true
        }
        for (open, close) in blockComments where starts(with: open, at: i) {
            var j = i + open.count
            while j < units.count, !starts(with: close, at: j) { j += 1 }
            let end = min(units.count, j + close.count)
            add(.comment, i, end)
            i = end
            return true
        }
        return false
    }

    // MARK: Strings

    private mutating func scanString(_ quote: UInt16) {
        let start = i
        var j = i + 1
        let multiline = spec.multilineQuotes.contains(quote)
        while j < units.count {
            let u = units[j]
            if u == 0x5C {
                j += 2
                continue
            }
            if u == quote {
                j += 1
                break
            }
            if u == Self.newline, !multiline { break }
            j += 1
        }
        let end = min(j, units.count)
        if spec.jsonKeys, nextNonBlank(from: end) == 0x3A {
            add(.key, start, end)
        } else if (spec.yamlKeys || spec.tomlKeys), nextNonBlank(from: end) == (spec.tomlKeys ? 0x3D : 0x3A) {
            add(.key, start, end)
        } else {
            add(.string, start, end)
        }
        i = end
    }

    private mutating func scanTriple(_ c: UInt16) -> Bool {
        guard c == 0x22 || c == 0x27, i + 2 < units.count, units[i + 1] == c, units[i + 2] == c else { return false }
        var j = i + 3
        while j + 2 < units.count, !(units[j] == c && units[j + 1] == c && units[j + 2] == c) {
            if units[j] == 0x5C { j += 1 }
            j += 1
        }
        let end = min(units.count, j + 3)
        add(.string, i, end)
        i = end
        return true
    }

    private mutating func scanCharLiteral() -> Bool {
        // 'a'  '\n'  '\u{1F600}'  (lifetime `'a` não fecha logo depois e fica sem cor)
        let n = units.count
        if i + 2 < n, units[i + 1] != 0x5C, units[i + 2] == 0x27 {
            add(.string, i, i + 3)
            i += 3
            return true
        }
        if i + 1 < n, units[i + 1] == 0x5C {
            var j = i + 2
            while j < n, j < i + 12, units[j] != 0x27 { j += 1 }
            if j < n, units[j] == 0x27 {
                add(.string, i, j + 1)
                i = j + 1
                return true
            }
        }
        return false
    }

    // MARK: Atributos, diretivas, números, identificadores

    private mutating func scanAtAttribute() -> Bool {
        var j = i + 1
        guard j < units.count, isIdentStart(units[j]) else { return false }
        while j < units.count, isIdentPart(units[j]) || units[j] == 0x2E { j += 1 }
        add(.attribute, i, j)
        i = j
        return true
    }

    private mutating func scanHashDirective() -> Bool {
        var j = i + 1
        while j < units.count, isIdentPart(units[j]) { j += 1 }
        guard j > i + 1 else { return false }
        add(.attribute, i, j)
        i = j
        return true
    }

    private mutating func scanAtRule() -> Bool {
        var j = i + 1
        while j < units.count, isIdentPart(units[j]) { j += 1 }
        guard j > i + 1 else { return false }
        add(.keyword, i, j)
        i = j
        return true
    }

    private mutating func scanTomlSection() {
        let end = lineEnd(from: i)
        var j = i
        while j < end, units[j] != 0x5D { j += 1 }
        add(.type, i, min(end, j + 1))
        i = min(end, j + 1)
    }

    private mutating func scanNumber() {
        var j = i
        while j < units.count {
            let u = units[j]
            if isIdentPart(u) { j += 1 } else if u == 0x2E, j + 1 < units.count, isDigit(units[j + 1]) { j += 1 } else if spec.cssMode, u == 0x25 { j += 1; break } else { break }
        }
        add(.number, i, j)
        i = j
    }

    private mutating func scanIdentifier() {
        let start = i
        var j = i
        while j < units.count, isIdentPart(units[j]) { j += 1 }
        // Hífen final em identificadores com `-` permitido não pertence à palavra.
        while j > start + 1, units[j - 1] == 0x2D || units[j - 1] == 0x2E { j -= 1 }
        let text = word(start, j)
        let next = j < units.count ? units[j] : nil
        i = j
        if spec.yamlKeys, next == 0x3A, atLineOrListStart(start) {
            add(.key, start, j)
            return
        }
        if spec.tomlKeys, nextNonBlank(from: j) == 0x3D, atLineStart(start) {
            add(.key, start, j)
            return
        }
        if spec.cssMode {
            if braceDepth > 0, nextNonBlank(from: j) == 0x3A { add(.key, start, j) }
            return
        }
        let lookup = spec.caseInsensitiveKeywords ? text.lowercased() : text
        if spec.keywords.contains(lookup) {
            add(.keyword, start, j)
        } else if spec.typesCapitalized, units[start] >= 0x41, units[start] <= 0x5A, j - start > 1, text.contains(where: \.isLowercase) {
            add(.type, start, j)
        } else if spec.calls, next == 0x28 {
            add(.function, start, j)
        }
    }

    private func atLineOrListStart(_ index: Int) -> Bool {
        var j = index - 1
        while j >= 0 {
            let u = units[j]
            if u == Self.newline { return true }
            if u != 0x20, u != 0x09, u != 0x2D { return false }
            j -= 1
        }
        return true
    }

    // MARK: Marcação (HTML/XML)

    private mutating func scanTag() -> Bool {
        guard i + 1 < units.count else { return false }
        let first = units[i + 1]
        guard isIdentStart(first) || first == 0x2F || first == 0x21 || first == 0x3F else { return false }
        var j = i + 1
        if units[j] == 0x2F || units[j] == 0x21 || units[j] == 0x3F { j += 1 }
        while j < units.count, isIdentPart(units[j]) || units[j] == 0x3A || units[j] == 0x2D { j += 1 }
        add(.tag, i, j)
        // Atributos até `>`.
        while j < units.count, units[j] != 0x3E {
            let u = units[j]
            if u == 0x22 || u == 0x27 {
                var k = j + 1
                while k < units.count, units[k] != u { k += 1 }
                add(.string, j, min(units.count, k + 1))
                j = min(units.count, k + 1)
            } else if isIdentStart(u) {
                var k = j
                while k < units.count, isIdentPart(units[k]) || units[k] == 0x3A || units[k] == 0x2D { k += 1 }
                add(.attribute, j, k)
                j = k
            } else {
                j += 1
            }
        }
        if j < units.count { add(.tag, j, j + 1) }
        i = min(units.count, j + 1)
        return true
    }
}

// MARK: - Markdown (por linhas)

private func markdownSpans(_ units: [UInt16]) -> [SyntaxSpan] {
    var spans: [SyntaxSpan] = []
    var inFence = false
    var lineStart = 0
    let n = units.count
    func hasPrefix(_ prefix: String, at index: Int) -> Bool {
        let p = Array(prefix.utf16)
        guard index + p.count <= n else { return false }
        for k in 0..<p.count where units[index + k] != p[k] { return false }
        return true
    }
    while lineStart < n {
        var lineEnd = lineStart
        while lineEnd < n, units[lineEnd] != 0x0A { lineEnd += 1 }
        let range = NSRange(location: lineStart, length: lineEnd - lineStart)
        if hasPrefix("```", at: lineStart) || hasPrefix("~~~", at: lineStart) {
            spans.append(SyntaxSpan(range: range, kind: .string))
            inFence.toggle()
        } else if inFence {
            spans.append(SyntaxSpan(range: range, kind: .string))
        } else if hasPrefix("#", at: lineStart) {
            var hashes = 0
            while lineStart + hashes < lineEnd, units[lineStart + hashes] == 0x23 { hashes += 1 }
            if hashes <= 6, lineStart + hashes < lineEnd, units[lineStart + hashes] == 0x20 {
                spans.append(SyntaxSpan(range: range, kind: .heading))
            }
        } else if hasPrefix(">", at: lineStart) {
            spans.append(SyntaxSpan(range: range, kind: .comment))
        } else {
            // Código em linha: `...`
            var j = lineStart
            while j < lineEnd {
                if units[j] == 0x60 {
                    var k = j + 1
                    while k < lineEnd, units[k] != 0x60 { k += 1 }
                    if k < lineEnd {
                        spans.append(SyntaxSpan(range: NSRange(location: j, length: k - j + 1), kind: .string))
                        j = k + 1
                        continue
                    }
                }
                j += 1
            }
        }
        lineStart = lineEnd + 1
    }
    return spans
}
