import Foundation

/// Identificador de acessibilidade tipado (08 AR-805, 02 §17, 03 §22).
///
/// A lista canônica vive em `A11yID.generated.swift` (gerada de 03 §22). Identificadores fixos são constantes
/// (`A11yID.windowMain`); os parametrizados por ID de modelo são funções (`A11yID.sidebarSession(id)`).
/// `init?(rawValue:)` só aceita strings que casam com algum padrão canônico; o teste de varredura (AC-T01)
/// usa essa mesma validação sobre a árvore `ctl ui tree`.
public struct A11yID: Hashable, Sendable, Codable, Comparable, CustomStringConvertible, RawRepresentable {
    public let rawValue: String

    /// Uso interno do código gerado: o valor já vem de um padrão canônico.
    init(unchecked rawValue: String) { self.rawValue = rawValue }

    public init?(rawValue: String) {
        guard A11yID.isCanonical(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let id = A11yID(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "A11yID fora da lista canônica: \(raw)"))
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public var description: String { rawValue }

    public static func < (lhs: A11yID, rhs: A11yID) -> Bool { lhs.rawValue < rhs.rawValue }

    // MARK: Validação

    /// `true` se `raw` casa com algum identificador ou padrão da lista canônica (03 §22).
    public static func isCanonical(_ raw: String) -> Bool {
        matchingSpec(raw) != nil
    }

    /// Padrão canônico que casa com `raw`, se houver.
    public static func matchingSpec(_ raw: String) -> A11yIDSpec? {
        let segs = raw.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !segs.isEmpty, !segs.contains("") else { return nil }
        return catalog.first { match(patternSegments($0.pattern)[...], segs[...]) }
    }

    private static func patternSegments(_ pattern: String) -> [String] {
        pattern.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    }

    private static let loosePlaceholders: Set<String> = ["<host>", "<region>", "<panel>", "<path>", "*"]

    private static func match(_ pat: ArraySlice<String>, _ id: ArraySlice<String>) -> Bool {
        guard let head = pat.first else { return id.isEmpty }
        let rest = pat.dropFirst()
        if loosePlaceholders.contains(head) {
            guard !id.isEmpty else { return false }
            for take in 1...id.count where match(rest, id.dropFirst(take)) { return true }
            return false
        }
        guard let first = id.first else { return false }
        if head.hasPrefix("<"), head.hasSuffix(">") { return match(rest, id.dropFirst()) }
        return head == first && match(rest, id.dropFirst())
    }

    // MARK: Segmentos de ID de modelo

    /// Um segmento comum não contém ponto nem espaço (o ponto separa níveis).
    public static func segment(_ value: String) -> String {
        String(value.map { $0 == "." || $0.isWhitespace ? "-" : $0 })
    }

    /// Placeholders `<host>`, `<path>`... aceitam pontos (são IDs inteiros ou caminhos).
    public static func rawSegment(_ value: String, loose: Bool) -> String { value }
}

/// Entrada da lista canônica: padrão com `<placeholder>`, superfície de 03 §22.
public struct A11yIDSpec: Sendable, Hashable {
    public let pattern: String
    public let surface: String

    public init(pattern: String, surface: String) {
        self.pattern = pattern
        self.surface = surface
    }

    public var isTemplate: Bool { pattern.contains("<") || pattern.contains("*") }
}
