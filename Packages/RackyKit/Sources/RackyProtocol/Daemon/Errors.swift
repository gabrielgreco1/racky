import Foundation

/// Códigos de erro do protocolo. Lista fechada: código novo entra como capability (06 §1.3).
public enum DaemonErrorCode: String, Sendable, Codable, CaseIterable {
    case protocolMajorMismatch
    case badRequest
    case unknownSession
    case sessionExited
    case spawnFailed
    case frameTooLarge
    case notCapable
    /// Peer recusado na autenticação da conexão (uid ou requisito de assinatura; 06 §1.4, 08 AR-503).
    case peerRejected
    case `internal`
}

/// Corpo de `error{code, message}`; `errno` e `path` só em `spawnFailed`.
public struct DaemonError: Error, Sendable, Hashable, Codable {
    public var code: DaemonErrorCode
    public var message: String
    public var errnoValue: Int32?
    public var path: String?

    public init(_ code: DaemonErrorCode, _ message: String, errnoValue: Int32? = nil, path: String? = nil) {
        self.code = code
        self.message = message
        self.errnoValue = errnoValue
        self.path = path
    }

    private enum CodingKeys: String, CodingKey {
        case code, message, path
        case errnoValue = "errno"
    }
}

/// Falhas de framing e de decodificação de frames (camada de bytes).
public enum FrameError: Error, Sendable, Hashable {
    /// `len` acima de 1 MiB (ou payload que não cabe no limite ao codificar).
    case frameTooLarge(length: Int)
    /// `len == 0`: falta até o byte `kind`.
    case emptyFrame
    case unknownKind(UInt8)
    /// Fim do stream no meio de um frame.
    case truncatedFrame(expected: Int, available: Int)
    case payloadTooShort(kind: UInt8, minimum: Int, actual: Int)
    case invalidInputOrigin(UInt8)
    case malformedControl(String)

    /// Código de `error{}` correspondente.
    public var daemonErrorCode: DaemonErrorCode {
        switch self {
        case .frameTooLarge: .frameTooLarge
        default: .badRequest
        }
    }

    public var daemonError: DaemonError {
        DaemonError(daemonErrorCode, String(describing: self))
    }
}
