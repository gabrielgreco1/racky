import Foundation

/// Limites normativos do protocolo do daemon (06 §1.3, 08 §0.3).
public enum ProtocolLimits {
    /// Tamanho máximo de `len` (bytes de `kind` + payload) de um frame: 1 MiB.
    public static let maxFrameLength = 1 << 20
    /// Fila de saída por cliente no daemon: 2 MiB (estourou: `resyncRequired`).
    public static let clientQueueLimit = 2 << 20
    /// Timeout do handshake (primeiro frame obrigatório).
    public static let handshakeTimeout: Duration = .seconds(2)
    /// Coalescência de saída: até 16 ms ou 64 KiB por frame.
    public static let coalesceWindow: Duration = .milliseconds(16)
    public static let coalesceBytes = 64 << 10
    /// Tamanho do cabeçalho de frame: `u32 len`.
    public static let lengthPrefixSize = 4
}

/// Identificador de sessão de PTY (UUID gerado pelo app). Texto minúsculo no JSON, 16 bytes no binário.
public struct SessionID: Hashable, Sendable, Codable, CustomStringConvertible {
    public static let byteCount = 16
    public let uuid: UUID

    public init(_ uuid: UUID = UUID()) { self.uuid = uuid }

    public init?(string: String) {
        guard let value = UUID(uuidString: string) else { return nil }
        self.uuid = value
    }

    /// `bytes` precisa ter exatamente 16 elementos.
    public init?(bytes: some Collection<UInt8>) {
        guard bytes.count == Self.byteCount else { return nil }
        var raw: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &raw) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
        }
        self.uuid = UUID(uuid: raw)
    }

    public var bytes: [UInt8] { withUnsafeBytes(of: uuid.uuid) { Array($0) } }
    public var description: String { uuid.uuidString.lowercased() }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let value = UUID(uuidString: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "invalid session UUID")
        }
        self.uuid = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// Identificador de requisição de controle (`id` do JSON). A resposta repete o `id`.
public struct RequestID: Hashable, Sendable, Codable, RawRepresentable, ExpressibleByIntegerLiteral, CustomStringConvertible {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public init(integerLiteral value: UInt64) { self.rawValue = value }
    public var description: String { String(rawValue) }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UInt64.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
