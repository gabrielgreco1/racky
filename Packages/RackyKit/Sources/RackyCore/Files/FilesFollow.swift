import Foundation

/// De onde veio um `cwd` do agente: OSC 7 do terminal (06 §3, evento `cwd` do daemon) ou o campo `cwd` de um hook.
public enum AgentCwdSource: String, Sendable, Equatable {
    case osc7, hook
}

/// Guarda o `cwd` mais recente de cada terminal, venha de OSC 7 ou de hook: quem chegou por último vale (shell comum só
/// emite OSC 7; o Claude Code não emite e só informa pelos hooks).
public struct AgentCwdTracker: Sendable, Equatable {
    private struct Entry: Sendable, Equatable {
        var path: String
        var at: Date
        var source: AgentCwdSource
    }

    private var entries: [UUID: Entry] = [:]

    public init() {}

    public mutating func record(_ path: String, terminal: UUID, source: AgentCwdSource, at: Date = Date()) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let current = entries[terminal], current.at > at { return }
        entries[terminal] = Entry(path: trimmed, at: at, source: source)
    }

    public mutating func forget(_ terminal: UUID) { entries[terminal] = nil }

    public func cwd(for terminal: UUID) -> String? { entries[terminal]?.path }
    public func source(for terminal: UUID) -> AgentCwdSource? { entries[terminal]?.source }
}

/// Como a raiz da árvore foi decidida.
public enum FilesRootMode: Sendable, Equatable {
    /// Sem sessão selecionada: nada a mostrar.
    case none
    /// Seguindo o terminal focado (`agent` é o nome curto: Claude, Codex, OpenCode, Terminal).
    case following(agent: String?)
    /// Fixada pelo usuário (pin).
    case pinned
}

public struct FilesRootResolution: Sendable, Equatable {
    public var root: String?
    public var mode: FilesRootMode
    /// A raiz está fora da pasta da sessão (o agente foi para outro lugar).
    public var isOutsideSession: Bool

    public init(root: String?, mode: FilesRootMode, isOutsideSession: Bool) {
        self.root = root
        self.mode = mode
        self.isOutsideSession = isOutsideSession
    }
}

/// Regra pura de "qual pasta a árvore mostra" (10-right-panel §2): pin vence; senão o `cwd` do terminal focado, se existir
/// como pasta; senão a pasta da sessão.
public enum FilesFollow {
    public static func resolve(
        sessionRoot: String?, agentCwd: String?, agentName: String?, pinnedRoot: String?,
        isDirectory: (String) -> Bool = FileTreeLoader.isDirectory
    ) -> FilesRootResolution {
        let session = sessionRoot.map(FileTreeLoader.canonical)
        func outside(_ root: String) -> Bool {
            guard let session else { return false }
            return root != session && !root.hasPrefix(session.hasSuffix("/") ? session : session + "/")
        }
        if let pinnedRoot {
            let pinned = FileTreeLoader.canonical(pinnedRoot)
            if isDirectory(pinned) { return FilesRootResolution(root: pinned, mode: .pinned, isOutsideSession: outside(pinned)) }
        }
        guard let session else { return FilesRootResolution(root: nil, mode: .none, isOutsideSession: false) }
        if let agentCwd, !agentCwd.isEmpty {
            let candidate = FileTreeLoader.canonical(agentCwd)
            if candidate != "/", isDirectory(candidate) {
                return FilesRootResolution(root: candidate, mode: .following(agent: agentName), isOutsideSession: outside(candidate))
            }
        }
        return FilesRootResolution(root: session, mode: .following(agent: agentName), isOutsideSession: false)
    }
}
