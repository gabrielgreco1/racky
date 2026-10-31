import Foundation

/// Fase OSC 133.
public enum PromptPhase: String, Sendable, Codable, Hashable, CaseIterable {
    case a = "A"
    case b = "B"
    case c = "C"
    case d = "D"
}

public struct TitleEvent: Sendable, Codable, Hashable {
    public var text: String
    public init(text: String) { self.text = text }
}

public struct CwdEvent: Sendable, Codable, Hashable {
    public var path: String
    public init(path: String) { self.path = path }
}

public struct PromptEvent: Sendable, Codable, Hashable {
    public var phase: PromptPhase
    public var exitStatus: Int32?
    public init(phase: PromptPhase, exitStatus: Int32? = nil) {
        self.phase = phase
        self.exitStatus = exitStatus
    }
}

public struct AltScreenEvent: Sendable, Codable, Hashable {
    public var on: Bool
    public init(on: Bool) { self.on = on }
}

public struct ModesEvent: Sendable, Codable, Hashable {
    public var bracketedPaste: Bool
    public var appCursor: Bool
    public var mouse: Bool
    public init(bracketedPaste: Bool, appCursor: Bool, mouse: Bool) {
        self.bracketedPaste = bracketedPaste
        self.appCursor = appCursor
        self.mouse = mouse
    }
}

public struct IdleEvent: Sendable, Codable, Hashable {
    public var since: Date
    public init(since: Date) { self.since = since }
}

/// Eventos sem bytes do daemon (`op:"event"`).
public enum EventPayload: Sendable, Hashable {
    case exit(ExitInfo)
    case title(TitleEvent)
    case cwd(CwdEvent)
    case bell
    case prompt(PromptEvent)
    case altScreen(AltScreenEvent)
    case modes(ModesEvent)
    case idle(IdleEvent)
    case stillAlive
    case resyncRequired
    case sessionGone

    /// Todos os nomes de evento, na ordem de 06 §1.3.
    public static let allNames: [String] = [
        "exit", "title", "cwd", "bell", "prompt", "altScreen", "modes", "idle", "stillAlive", "resyncRequired", "sessionGone",
    ]

    public var name: String {
        switch self {
        case .exit: "exit"
        case .title: "title"
        case .cwd: "cwd"
        case .bell: "bell"
        case .prompt: "prompt"
        case .altScreen: "altScreen"
        case .modes: "modes"
        case .idle: "idle"
        case .stillAlive: "stillAlive"
        case .resyncRequired: "resyncRequired"
        case .sessionGone: "sessionGone"
        }
    }

    /// Tipo assinável correspondente; `nil` para os que chegam sempre.
    public var subscribableKind: EventKind? {
        switch self {
        case .exit: .exit
        case .title: .title
        case .cwd: .cwd
        case .bell: .bell
        case .prompt: .prompt
        case .altScreen: .altScreen
        case .modes: .modes
        case .idle: .idle
        case .stillAlive, .resyncRequired, .sessionGone: nil
        }
    }
}

public struct DaemonEvent: Sendable, Hashable {
    public var sessionID: SessionID
    public var payload: EventPayload
    public init(sessionID: SessionID, payload: EventPayload) {
        self.sessionID = sessionID
        self.payload = payload
    }
}

extension DaemonEvent: Codable {
    private enum CodingKeys: String, CodingKey { case op, event, sessionID }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(String.self, forKey: .op) == "event" else {
            throw DecodingError.dataCorruptedError(forKey: .op, in: c, debugDescription: "not an event")
        }
        sessionID = try c.decode(SessionID.self, forKey: .sessionID)
        let name = try c.decode(String.self, forKey: .event)
        switch name {
        case "exit": payload = .exit(try ExitInfo(from: decoder))
        case "title": payload = .title(try TitleEvent(from: decoder))
        case "cwd": payload = .cwd(try CwdEvent(from: decoder))
        case "bell": payload = .bell
        case "prompt": payload = .prompt(try PromptEvent(from: decoder))
        case "altScreen": payload = .altScreen(try AltScreenEvent(from: decoder))
        case "modes": payload = .modes(try ModesEvent(from: decoder))
        case "idle": payload = .idle(try IdleEvent(from: decoder))
        case "stillAlive": payload = .stillAlive
        case "resyncRequired": payload = .resyncRequired
        case "sessionGone": payload = .sessionGone
        default:
            throw DecodingError.dataCorruptedError(forKey: .event, in: c, debugDescription: "unknown event '\(name)'")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("event", forKey: .op)
        try c.encode(payload.name, forKey: .event)
        try c.encode(sessionID, forKey: .sessionID)
        switch payload {
        case .exit(let v): try v.encode(to: encoder)
        case .title(let v): try v.encode(to: encoder)
        case .cwd(let v): try v.encode(to: encoder)
        case .prompt(let v): try v.encode(to: encoder)
        case .altScreen(let v): try v.encode(to: encoder)
        case .modes(let v): try v.encode(to: encoder)
        case .idle(let v): try v.encode(to: encoder)
        case .bell, .stillAlive, .resyncRequired, .sessionGone: break
        }
    }
}
