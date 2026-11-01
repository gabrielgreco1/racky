import RackyProtocol
import RackyTerminalCore
import Foundation

/// Rótulos de "Paste into <Agent>" (03 §16.12, AC-505): menus usam o nome curto, o popover o nome completo.
public enum AgentPasteLabel {
    public static func shortName(_ provider: TerminalProvider) -> String? {
        switch provider {
        case .claude: "Claude"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        case .shell, .custom: nil
        }
    }

    public static func menuTitle(_ provider: TerminalProvider) -> String? {
        shortName(provider).map { "Paste into \($0)" }
    }

    public static func popoverTitle(_ provider: TerminalProvider) -> String? {
        guard provider.isAgent else { return nil }
        return "Paste into \(AgentInfo.displayName(provider))"
    }
}

public enum AgentPasteOutcome: Sendable, Equatable {
    /// Entregue por bracketed paste, sem Enter, com origem `0x02`.
    case pasted
    /// Bracketed paste desligado no agente: o texto foi para o clipboard ("Copied — paste it into the agent").
    case copied
}

public enum AgentPasteError: Error, Sendable, Equatable {
    case notAnAgent
    case emptyText
}

/// Colagem por clique no prompt de um agente (T11, R5.1). Tudo injetado: `send` é o único caminho até o PTY.
public struct AgentPasteSender: Sendable {
    public var bracketedPasteActive: Bool
    public var send: @Sendable (InputOrigin, Data) async throws -> Void
    public var copy: @Sendable (String) -> Void

    public init(
        bracketedPasteActive: Bool,
        send: @escaping @Sendable (InputOrigin, Data) async throws -> Void,
        copy: @escaping @Sendable (String) -> Void
    ) {
        self.bracketedPasteActive = bracketedPasteActive
        self.send = send
        self.copy = copy
    }

    public func paste(_ text: String, provider: TerminalProvider) async throws -> AgentPasteOutcome {
        guard provider.isAgent else { throw AgentPasteError.notAnAgent }
        guard let bytes = AgentPaste.frame(text, bracketedPasteActive: bracketedPasteActive) else {
            guard !text.isEmpty else { throw AgentPasteError.emptyText }
            copy(text)
            return .copied
        }
        try await send(.appPaste, Data(bytes))
        return .pasted
    }
}
