import RackyCore
import RackyProtocol
import Foundation

/// O agente do pane focado que pode receber a invocação (03 §8).
struct FocusedAgent: Equatable, Sendable {
    var terminal: UUID
    var provider: TerminalProvider

    var client: LibraryClient? {
        switch provider {
        case .claude: .claude
        case .codex: .codex
        case .opencode: .opencode
        case .shell, .custom: nil
        }
    }
}

/// Uma skill ou um agente que o agente do pane focado entende, com o texto que a colagem leva.
struct InsertCandidate: Identifiable, Equatable {
    var id: String { entry.id }
    var entry: LibraryEntry
    var text: String
    var client: LibraryClient
}

/// `Insert Skill or Agent…` (03 §8, T4-03, AC-909): cola o texto de invocação definido pelo adapter do CLI no prompt do pane focado por
/// bracketed paste, origem `app-paste` (0x02), **sem Enter** (T11: é clique ou tecla explícita do usuário). O caminho até o PTY é o do
/// `Paste into <Agent>` da T2-06 (`dialog.pasteToAgent.confirm` → `AgentPasteSender`).
@MainActor
final class PromptInsertController {
    let library: LibraryController
    private let registry: () -> ActionRegistry?
    var focusedAgent: @MainActor () -> FocusedAgent? = { nil }
    var returnFocusToTerminal: @MainActor () -> Void = {}
    var closeLibraryPage: @MainActor () -> Void = {}
    var openPalette: @MainActor (_ insertMode: Bool) -> Bool = { _ in false }

    init(library: LibraryController, registry: @escaping () -> ActionRegistry?) {
        self.library = library
        self.registry = registry
    }

    /// Skills e agentes que o agente focado entende agora: os globais e os ligados na sessão (os outros ainda não existem para ele).
    func candidates() -> [InsertCandidate] {
        guard let client = focusedAgent()?.client else { return [] }
        var out: [InsertCandidate] = []
        for entry in library.items where entry.shadowedBy == nil {
            let activation = library.activation(of: entry)
            let usable: Bool
            switch client {
            case .claude: usable = activation == .alwaysOn || activation == .thisSession
            default: usable = entry.works(with: client)
            }
            guard usable, let text = LibraryInvocation.text(for: entry, provider: client, addedToSession: activation == .thisSession) else { continue }
            out.append(InsertCandidate(entry: entry, text: text, client: client))
        }
        return out.sorted { ($0.entry.name.lowercased(), $0.entry.path) < ($1.entry.name.lowercased(), $1.entry.path) }
    }

    /// Cola o texto (nunca com Enter). Devolve `pasted` ou `copied` (bracketed paste desligado no agente).
    @discardableResult
    func insert(_ entry: LibraryEntry, action: ActionID) async throws -> String {
        guard let agent = focusedAgent(), let client = agent.client else {
            throw ActionError.failed(action, message: String(localized: "Focus an agent terminal first.", bundle: .module))
        }
        let activation = library.activation(of: entry)
        guard let text = LibraryInvocation.text(for: entry, provider: client, addedToSession: activation == .thisSession) else {
            throw ActionError.failed(action, message: String(localized: "\(client.displayName) can't use this item.", bundle: .module))
        }
        guard let registry = registry() else { throw ActionError.failed(action, message: String(localized: "Focus an agent terminal first.", bundle: .module)) }
        struct Payload: Encodable { var terminal: String; var text: String }
        let json = (try? JSONEncoder().encode(Payload(terminal: agent.terminal.uuidString.lowercased(), text: text))).map { String(decoding: $0, as: UTF8.self) } ?? text
        let result = try await registry.perform(.dialogPasteToAgentConfirm, .set(json))
        closeLibraryPage()
        returnFocusToTerminal()
        return result.message ?? "pasted"
    }

    func register(in registry: ActionRegistry) throws {
        let needsAgent: ActionRegistry.Enablement = { [unowned self] in
            focusedAgent() == nil ? .disabled(reason: String(localized: "Focus an agent terminal first.", bundle: .module)) : .enabled
        }
        try registry.register(.promptInsertItem, enablement: needsAgent) { [unowned self] arg in
            let entry = try library.item(for: arg, .promptInsertItem)
            return try await insert(entry, action: .promptInsertItem)
        }
        try registry.register(.promptInsertSkillOrAgent, enablement: needsAgent) { [unowned self] _ in
            openPalette(true) ? "opened" : "busy"
        }
    }
}
