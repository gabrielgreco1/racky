import Foundation

/// Conjunto FECHADO de códigos de erro das ferramentas (07 §3.1). Nenhum outro código chega ao agente.
public enum ToolErrorCode: String, Sendable, CaseIterable, Codable {
    case notClaimed = "not_claimed"
    case alreadyClaimed = "already_claimed"
    case queued
    case humanInControl = "human_in_control"
    case waitingHelp = "waiting_help"
    case blockedByPolicy = "blocked_by_policy"
    case pathRejected = "path_rejected"
    case notSupported = "not_supported"
    case proxyError = "proxy_error"
    case timeout
    case boxRestarted = "box_restarted"
    case boxReleased = "box_released"
    case dockerUnavailable = "docker_unavailable"
    case appUnavailable = "app_unavailable"
    case notFound = "not_found"
    case invalidArgument = "invalid_argument"
}

/// Erro de ferramenta: `{error: <code>, message, retry_after_s?, details?}` (07 §3.1).
public struct ToolError: Error, Sendable, Equatable {
    public var code: ToolErrorCode
    public var message: String
    public var retryAfterS: Int?
    public var details: JSON?

    public init(_ code: ToolErrorCode, _ message: String, retryAfterS: Int? = nil, details: JSON? = nil) {
        self.code = code
        self.message = message
        self.retryAfterS = retryAfterS
        self.details = details
    }

    public var json: JSON {
        var object: [String: JSON] = ["error": .string(code.rawValue), "message": .string(message)]
        if let retryAfterS { object["retry_after_s"] = .int(retryAfterS) }
        if let details { object["details"] = details }
        return .object(object)
    }

    public static func invalid(_ message: String, details: JSON? = nil) -> ToolError { ToolError(.invalidArgument, message, details: details) }
}
