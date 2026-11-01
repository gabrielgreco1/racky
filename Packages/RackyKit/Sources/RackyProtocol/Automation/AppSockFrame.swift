import Foundation

/// Framing de `app.sock`: `u32 len (big-endian) | payload JSON` (08 AR-106).
public enum AppSockFrame {
    /// Limite padrão por frame do `ctl` (um screenshot @2x em base64 cabe com folga).
    public static let defaultMaxLength = 64 * 1024 * 1024

    public static func encode(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        var out = Data(bytes: &length, count: 4)
        out.append(payload)
        return out
    }
}

public enum AppSockFrameError: Error, Equatable, Sendable {
    case tooLarge(length: Int, max: Int)
}

/// Remonta frames a partir de bytes parciais.
public struct AppSockFrameDecoder: Sendable {
    private var buffer = Data()
    public let maxLength: Int

    public init(maxLength: Int = AppSockFrame.defaultMaxLength) { self.maxLength = maxLength }

    public mutating func append(_ data: Data) { buffer.append(data) }

    /// Próximo frame completo, ou `nil` se faltam bytes. Lança se o tamanho declarado passa do limite.
    public mutating func next() throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard length <= maxLength else { throw AppSockFrameError.tooLarge(length: length, max: maxLength) }
        guard buffer.count >= 4 + length else { return nil }
        let start = buffer.startIndex + 4
        let payload = Data(buffer[start..<(start + length)])
        buffer.removeFirst(4 + length)
        return payload
    }
}
