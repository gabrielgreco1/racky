import Foundation

/// Fatia de entrega de um controle ou ação (09 §1, 03 §24 coluna Versão).
/// Feature flag por fatia (AR-805, AC-T28): controle de fatia futura não é renderizado.
public enum ReleaseSlice: Int, Sendable, Codable, Comparable, CaseIterable {
    case slice1 = 1, slice2, slice3, slice4
    /// v1.1 (modo isolado etc.): nunca disponível na v1.
    case v11 = 100
    case later = 200

    public static func < (lhs: ReleaseSlice, rhs: ReleaseSlice) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Fatias ligadas no build/ambiente atual.
public struct SliceFlags: Sendable, Equatable {
    /// Última fatia entregue. O app liga por padrão tudo o que as Fatias 1 a 3 já implementam (F13); `RACKY_SLICE=<n>`
    /// (dev/testes) restringe o app a uma fatia menor.
    public let current: ReleaseSlice
    /// `true`: a fatia foi escolhida (testes, `RACKY_SLICE`) e o gating vale para todo controle. `false` (padrão do app):
    /// só controles sem handler registrado ficam de fora (F13).
    public let restricted: Bool

    public static let deliveredSlice = ReleaseSlice.slice3

    public init(current: ReleaseSlice = .slice1, restricted: Bool = true) { self.current = current; self.restricted = restricted }

    public static func fromEnvironment(_ env: [String: String]) -> SliceFlags {
        if let raw = env["RACKY_SLICE"], let n = Int(raw), let s = ReleaseSlice(rawValue: n), s <= .slice4 {
            return SliceFlags(current: s, restricted: true)
        }
        return SliceFlags(current: deliveredSlice, restricted: false)
    }

    public func isEnabled(_ slice: ReleaseSlice) -> Bool {
        slice <= current && slice < .v11
    }
}

/// Identificador de ação do registro (03 §24): `<grupo>.<ação>` em lowerCamelCase.
/// As constantes vêm de `ActionID.generated.swift`.
public struct ActionID: Hashable, Sendable, Codable, Comparable, CustomStringConvertible, RawRepresentable {
    public let rawValue: String

    init(unchecked rawValue: String) { self.rawValue = rawValue }

    public init?(rawValue: String) {
        guard ActionID.catalogIndex[rawValue] != nil else { return nil }
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let id = ActionID(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "ActionID desconhecido: \(raw)"))
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public var description: String { rawValue }
    public static func < (lhs: ActionID, rhs: ActionID) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Grupo (`session` em `session.new`).
    public var group: String { String(rawValue.split(separator: ".").first ?? "") }

    /// Linha do índice (03 §24).
    public var spec: ActionSpec { ActionID.catalogIndex[rawValue] ?? ActionSpec(id: self, label: rawValue, shortcut: "", slice: .later) }

    static let catalogIndex: [String: ActionSpec] = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id.rawValue, $0) })
}

/// Linha do índice de ações (03 §24).
public struct ActionSpec: Sendable, Hashable {
    public let id: ActionID
    public let label: String
    /// Atalho para exibição (`⌘N`); vazio = sem atalho.
    public let shortcut: String
    public let slice: ReleaseSlice

    public init(id: ActionID, label: String, shortcut: String, slice: ReleaseSlice) {
        self.id = id
        self.label = label
        self.shortcut = shortcut
        self.slice = slice
    }
}
