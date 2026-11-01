import Foundation

// Mensagens do serviço `ctl` de `app.sock` (08 AR-106, AR-806). Framing `u32 len | JSON` (big-endian).

public enum AppSockService: String, Codable, Sendable { case mcp, hook, ctl }

/// Primeiro frame de toda conexão: escolhe o serviço (multiplexado por handshake, AR-106).
public struct AppSockHello: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var service: AppSockService
    public var protocolVersion: Int
    public init(service: AppSockService, protocolVersion: Int = AppSockHello.currentVersion) {
        self.service = service
        self.protocolVersion = protocolVersion
    }
}

public struct AppSockHelloReply: Codable, Sendable, Equatable {
    public var ok: Bool
    public var error: CtlError?
    public init(ok: Bool, error: CtlError? = nil) {
        self.ok = ok
        self.error = error
    }
}

public enum CtlCommand: String, Codable, Sendable {
    case state
    case uiTree
    case uiAction
    case uiWait
    case screenshot
    case recordStart
    case recordStop
}

/// Estados de `ui wait --state`.
public enum UIWaitState: String, Codable, Sendable {
    case appear, gone, enabled, disabled
}

public struct CtlRequest: Codable, Sendable, Equatable {
    public var command: CtlCommand
    /// `ui tree --root`.
    public var root: A11yID?
    /// `ui action <alvo>`: um `ActionID` (`session.new`) ou o `A11yID` de um controle.
    public var target: String?
    public var argument: ActionArgument?
    /// `ui wait <a11yID>`.
    public var element: A11yID?
    public var waitState: UIWaitState?
    public var timeoutMs: Int?
    /// `screenshot`: `window` (padrão) ou `element`.
    public var screenshotElement: A11yID?
    public var size: UISize?
    public var outPath: String?

    public init(
        command: CtlCommand, root: A11yID? = nil, target: String? = nil, argument: ActionArgument? = nil,
        element: A11yID? = nil, waitState: UIWaitState? = nil, timeoutMs: Int? = nil,
        screenshotElement: A11yID? = nil, size: UISize? = nil, outPath: String? = nil
    ) {
        self.command = command
        self.root = root
        self.target = target
        self.argument = argument
        self.element = element
        self.waitState = waitState
        self.timeoutMs = timeoutMs
        self.screenshotElement = screenshotElement
        self.size = size
        self.outPath = outPath
    }
}

public struct CtlError: Codable, Sendable, Equatable, Error {
    /// `ctl_disabled`, `bad_request`, `action_not_registered`, `action_unavailable`, `action_disabled`,
    /// `action_failed`, `unknown_target`, `timeout`, `screenshot_failed`, `recording_failed`, `service_unavailable`.
    public var code: String
    public var message: String
    /// Motivo exato de desabilitado (`action_disabled`).
    public var reason: String?

    public init(code: String, message: String, reason: String? = nil) {
        self.code = code
        self.message = message
        self.reason = reason
    }
}

public struct CtlResponse: Codable, Sendable, Equatable {
    public var ok: Bool
    public var error: CtlError?
    public var state: AppStateSnapshot?
    public var tree: UITreeSnapshot?
    public var action: ActionResult?
    /// `ui wait`: o nó encontrado e quanto esperou.
    public var waited: UITreeNode?
    public var waitedMs: Int?
    public var screenshot: ScreenshotResult?
    public var recording: RecordingResult?

    public init(
        ok: Bool = true, error: CtlError? = nil, state: AppStateSnapshot? = nil, tree: UITreeSnapshot? = nil,
        action: ActionResult? = nil, waited: UITreeNode? = nil, waitedMs: Int? = nil,
        screenshot: ScreenshotResult? = nil, recording: RecordingResult? = nil
    ) {
        self.ok = ok
        self.error = error
        self.state = state
        self.tree = tree
        self.action = action
        self.waited = waited
        self.waitedMs = waitedMs
        self.screenshot = screenshot
        self.recording = recording
    }

    public static func failure(_ error: CtlError) -> CtlResponse { CtlResponse(ok: false, error: error) }
}

public enum CtlCodec {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static func decoder() -> JSONDecoder { JSONDecoder() }
}
