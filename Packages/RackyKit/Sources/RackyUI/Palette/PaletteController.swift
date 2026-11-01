import RackyCore
import RackyDesignSystem
import RackyProtocol
import Foundation
import Observation
import SwiftUI

struct PaletteRow: Identifiable, Equatable {
    var group: String
    var kind: String
    var itemID: String
    var title: String
    var context: String?
    var symbol: String?
    var logo: DSAgentKind?
    /// Linha desabilitada, com o motivo (insert mode sem agente focado).
    var disabledReason: String?

    var id: String { "\(kind).\(itemID)" }
}

/// Estado da palette (03 §8): texto, modo `Insert Skill or Agent` e a linha destacada.
@MainActor @Observable
final class PaletteModel {
    var query = ""
    var insertMode = false
    var highlighted: String?
    private(set) var rows: [PaletteRow] = []
    var source: @MainActor (_ query: String, _ insertMode: Bool) -> [PaletteRow] = { _, _ in [] }

    /// `/` no início do campo põe a palette em modo de inserção; o texto depois dele filtra.
    func queryChanged() {
        if !insertMode, query.hasPrefix("/") {
            insertMode = true
            query = String(query.dropFirst())
        }
        refresh()
    }

    func refresh() {
        rows = source(query, insertMode)
        if !rows.contains(where: { $0.id == highlighted }) { highlighted = rows.first { $0.disabledReason == nil }?.id }
    }

    func move(_ delta: Int) {
        let enabled = rows.filter { $0.disabledReason == nil }
        guard !enabled.isEmpty else { return }
        let index = enabled.firstIndex { $0.id == highlighted } ?? (delta > 0 ? -1 : enabled.count)
        highlighted = enabled[min(max(index + delta, 0), enabled.count - 1)].id
    }

    var placeholder: String {
        insertMode ? String(localized: "Insert a skill or agent into the focused prompt…", bundle: .module)
            : String(localized: "Jump to a session, terminal, computer or command…", bundle: .module)
    }
}

/// Command palette (⌘J, 03 §8): sessões, terminais e comandos, e o modo `Insert Skill or Agent…` (T4-03). Resultados mudam sem animação.
@MainActor
final class PaletteController {
    let model = PaletteModel()
    let inserter: PromptInsertController
    private let overlays: OverlayRouter
    private let sidebar: SidebarModel
    private let workspace: WorkspaceModel
    private let registry: () -> ActionRegistry?

    init(inserter: PromptInsertController, overlays: OverlayRouter, sidebar: SidebarModel, workspace: WorkspaceModel, registry: @escaping () -> ActionRegistry?) {
        self.inserter = inserter
        self.overlays = overlays
        self.sidebar = sidebar
        self.workspace = workspace
        self.registry = registry
        model.source = { [unowned self] query, insert in rows(query: query, insertMode: insert) }
    }

    var isOpen: Bool { overlays.top?.spec.name == "palette" }

    // MARK: Linhas

    static let commands: [(action: ActionID, title: String, symbol: String)] = [
        (.promptInsertSkillOrAgent, "Insert Skill or Agent…", "text.insert"),
        (.pageLibrary, "Library", "books.vertical"),
        (.pageComputers, "Computers", "display"),
        (.appSettings, "Settings", "gearshape"),
    ]

    func rows(query: String, insertMode: Bool) -> [PaletteRow] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        func matches(_ text: String) -> Bool { needle.isEmpty || text.lowercased().contains(needle) }
        if insertMode {
            let reason: String? = inserter.focusedAgent() == nil ? String(localized: "Focus an agent terminal first.", bundle: .module) : nil
            let list = reason == nil ? inserter.candidates() : inserter.library.items.filter { $0.shadowedBy == nil && $0.works(with: .claude) }.map {
                InsertCandidate(entry: $0, text: "", client: .claude)
            }
            return list.filter { matches($0.entry.name) || matches($0.entry.summary ?? "") }.map { candidate in
                PaletteRow(
                    group: "Skills & Agents", kind: candidate.entry.kind.rawValue, itemID: candidate.entry.id, title: candidate.entry.name,
                    context: candidate.entry.category.label, logo: candidate.client.agentKind, disabledReason: reason)
            }
        }
        var out: [PaletteRow] = []
        for session in sidebar.snapshot.sessions where session.archivedAt == nil && matches(session.title) {
            out.append(PaletteRow(group: "Sessions", kind: "session", itemID: session.id.uuidString, title: session.title, context: nil, symbol: "square.stack"))
        }
        if !needle.isEmpty {
            for terminal in workspace.terminalsInCurrentSession where matches(terminal.title) || matches(AgentInfo.displayName(terminal.provider)) {
                out.append(PaletteRow(
                    group: "Terminals", kind: "terminal", itemID: terminal.id.uuidString,
                    title: terminal.title.isEmpty ? AgentInfo.displayName(terminal.provider) : terminal.title, context: nil, symbol: "terminal",
                    logo: terminal.provider.isAgent ? terminal.provider.dsKind : nil))
            }
        }
        let registry = registry()
        for command in Self.commands where matches(command.title) && (registry?.isOffered(command.action) ?? true) {
            out.append(PaletteRow(group: "Commands", kind: "command", itemID: command.action.rawValue, title: command.title, context: nil, symbol: command.symbol))
        }
        return out
    }

    // MARK: Abrir e agir

    @discardableResult
    func open(insertMode: Bool) -> Bool {
        if isOpen {
            model.insertMode = insertMode || model.insertMode
            model.refresh()
            return true
        }
        model.query = ""
        model.insertMode = insertMode
        model.refresh()
        return overlays.present(
            OverlaySpec(name: "palette", id: .overlayPalette, width: DS.Layout.paletteWidth, cornerRadius: DS.Radius.large, content: { [model] in AnyView(PaletteView(model: model)) }),
            from: nil)
    }

    func register(in registry: ActionRegistry) throws {
        try registry.register(.paletteOpen) { [unowned self] _ in
            if isOpen { overlays.dismiss(.action); return "closed" }
            return open(insertMode: false) ? "open" : "busy"
        }
        try registry.register(.paletteInsertMode, enablement: { [unowned self] in isOpen ? .enabled : .disabled(reason: String(localized: "Open the palette first.", bundle: .module)) }) { [unowned self] _ in
            model.insertMode = true
            model.refresh()
            return "insert"
        }
        try registry.register(.paletteOpenRow, enablement: { [unowned self] in isOpen ? .enabled : .disabled(reason: String(localized: "Open the palette first.", bundle: .module)) }) { [unowned self] arg in
            let key = arg.kind == .select ? arg.value : model.highlighted
            guard let key, let row = model.rows.first(where: { $0.id == key }) else {
                throw ActionError.failed(.paletteOpenRow, message: String(localized: "No such row.", bundle: .module))
            }
            if let reason = row.disabledReason { throw ActionError.failed(.paletteOpenRow, message: reason) }
            return try await activate(row)
        }
    }

    private func activate(_ row: PaletteRow) async throws -> String {
        overlays.dismiss(.action)
        switch row.kind {
        case "session":
            if let id = UUID(uuidString: row.itemID) { _ = sidebar.select(id) }
            return "session"
        case "terminal":
            if let id = UUID(uuidString: row.itemID) { workspace.show(terminalID: id) }
            return "terminal"
        case "command":
            guard let action = ActionID(rawValue: row.itemID), let registry = registry() else { return "command" }
            if action == .promptInsertSkillOrAgent {
                // O comando fecha a palette e a reabre no modo de inserção.
                _ = open(insertMode: true)
                return "insert"
            }
            Task { _ = try? await registry.perform(action, .press) }
            return "command"
        default:
            // Skill ou agente (modo de inserção): cola sem Enter e devolve o foco ao terminal.
            guard let entry = inserter.library.items.first(where: { $0.id == row.itemID }) else { throw ActionError.failed(.paletteOpenRow, message: "No such item.") }
            return try await inserter.insert(entry, action: .paletteOpenRow)
        }
    }
}
