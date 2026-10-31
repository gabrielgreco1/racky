import Foundation

/// Versão do protocolo: `major` quebra compatibilidade; `minor` só acrescenta capabilities (06 §1.3).
public struct ProtocolVersion: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public var major: UInt16
    public var minor: UInt16

    public init(major: UInt16, minor: UInt16) {
        self.major = major
        self.minor = minor
    }

    /// Versão que este build fala (`app.racky.ptyd.v1`).
    public static let current = ProtocolVersion(major: 1, minor: 0)

    public static func < (lhs: ProtocolVersion, rhs: ProtocolVersion) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }

    public var description: String { "\(major).\(minor)" }
}

/// Recurso negociado no handshake. Valores desconhecidos são preservados (compatibilidade para frente).
public struct Capability: Hashable, Sendable, Codable, RawRepresentable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    public static let coldLog: Capability = "coldLog"
    public static let osc133: Capability = "osc133"
    public static let textSnapshot: Capability = "textSnapshot"
    public static let inputOrigin: Capability = "inputOrigin"
    public static let drainWhenIdle: Capability = "drainWhenIdle"

    /// Capabilities iniciais (minor 0), na ordem canônica.
    public static let initialSet: [Capability] = [.coldLog, .osc133, .textSnapshot, .inputOrigin, .drainWhenIdle]

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Interseção preservando a ordem de `lhs`, sem duplicatas.
    public static func intersection(_ lhs: [Capability], _ rhs: [Capability]) -> [Capability] {
        let other = Set(rhs)
        var seen = Set<Capability>()
        return lhs.filter { other.contains($0) && seen.insert($0).inserted }
    }
}
