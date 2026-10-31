import RackyCore
import RackyDesignSystem
import RackyProtocol
import Foundation
import SwiftUI

extension PanelModuleID {
    static let context: PanelModuleID = "context"
}

/// Aba Context do painel direito (03 §10.6): o que está carregado na sessão e a ativação aditiva (`context.toggleItem`), com o
/// banner `Changes apply the next time an agent starts in this session.` e `Restart Agents with Resume`.
@MainActor
final class ContextController {
    let library: LibraryController
    private let overlays: OverlayRouter
    private let showModule: @MainActor (PanelModuleID) -> Void
    /// Agentes Claude da sessão que a reinicialização atinge: rodando e com ID de conversa (os outros não são tocados).
    var restartableAgents: @MainActor () -> [UUID] = { [] }
    /// Encerra com calma e relança com `--resume` (as flags e o plugin da sessão são regerados no lançamento).
    var relaunch: @MainActor (UUID) async -> Void = { _ in }
    private var pendingRestart: [UUID] = []

    init(library: LibraryController, overlays: OverlayRouter, showModule: @escaping @MainActor (PanelModuleID) -> Void) {
        self.library = library
        self.overlays = overlays
        self.showModule = showModule
    }

    // MARK: Dados

    struct Group: Identifiable {
        var id: String
        var title: String
        var rows: [Row]
    }

    struct Row: Identifiable {
        var id: String { entry.id }
        var entry: LibraryEntry
        var activation: LibraryActivation
        var source: String
    }

    /// Itens que valem para o Claude Code desta sessão: os ligados nela, os que podem ser ligados e os globais (`Always on`).
    func groups() -> [Group] {
        let relevant = library.items.filter { entry in
            if case .unavailable = library.activation(of: entry) { return false }
            return entry.shadowedBy == nil
        }
        func rows(_ kind: LibraryKind) -> [Row] {
            relevant.filter { $0.kind == kind }.map { entry in
                let activation = library.activation(of: entry)
                return Row(entry: entry, activation: activation, source: entry.sourceLine(activation: activation))
            }
            .sorted { ($0.activation.sortRank, $0.entry.name.lowercased()) < ($1.activation.sortRank, $1.entry.name.lowercased()) }
        }
        return [Group(id: "agents", title: String(localized: "Agents", bundle: .module), rows: rows(.agent)),
                Group(id: "skills", title: String(localized: "Skills", bundle: .module), rows: rows(.skill))]
            .filter { !$0.rows.isEmpty }
    }

    // MARK: Ações

    func register(in registry: ActionRegistry) throws {
        try registry.register(.panelContext) { [unowned self] _ in
            showModule(.context)
            return "open"
        }
        try registry.register(
            .contextToggleItem,
            enablement: { [unowned self] in
                library.target == nil ? .disabled(reason: String(localized: "Select a session first.", bundle: .module)) : .enabled
            }
        ) { [unowned self] arg in
            guard arg.kind == .select, let id = arg.value, let entry = library.items.first(where: { $0.id == id }) else {
                throw ActionError.failed(.contextToggleItem, message: String(localized: "No such item.", bundle: .module))
            }
            if case .alwaysOn = library.activation(of: entry) {
                throw ActionError.failed(.contextToggleItem, message: String(localized: "Claude Code loads global skills in every session", bundle: .module))
            }
            do { return try await library.setInSession(entry, on: nil) ? "on" : "off" } catch ActionError.failed(_, let message) {
                throw ActionError.failed(.contextToggleItem, message: message)
            }
        }
        try registry.register(
            .contextRestartWithResume,
            enablement: { [unowned self] in
                restartableAgents().isEmpty ? .disabled(reason: String(localized: "No agent in this session can be restarted.", bundle: .module)) : .enabled
            }
        ) { [unowned self] _ in
            let agents = restartableAgents()
            guard !agents.isEmpty else { throw ActionError.failed(.contextRestartWithResume, message: String(localized: "No agent in this session can be restarted.", bundle: .module)) }
            pendingRestart = agents
            if overlays.present(.confirmation(.restartAgents(count: agents.count)), from: .rightPanelContextRestart) { return "confirming" }
            pendingRestart = []
            return "busy"
        }
        try registry.register(.dialogRestartAgentsCancel) { [unowned self] _ in
            pendingRestart = []
            overlays.dismiss(.action)
            return nil
        }
        try registry.register(.dialogRestartAgentsConfirm) { [unowned self] _ in
            let ids = pendingRestart
            pendingRestart = []
            overlays.dismiss(.action)
            for id in ids { await relaunch(id) }
            await library.refreshSession()
            return "restarted \(ids.count)"
        }
    }
}

extension LibraryActivation {
    /// Ordem da lista: ligados na sessão, depois os que podem ser ligados, depois os globais.
    fileprivate var sortRank: Int {
        switch self {
        case .thisSession: 0
        case .off: 1
        case .alwaysOn: 2
        case .unavailable: 3
        }
    }
}

extension ConfirmationModel {
    /// `Restart <n> agents?` (03 §10.6).
    static func restartAgents(count: Int) -> ConfirmationModel {
        ConfirmationModel(
            name: "confirmRestartAgents", rootID: .overlayConfirmRestartAgents,
            title: count == 1 ? String(localized: "Restart 1 agent?", bundle: .module) : String(localized: "Restart \(count) agents?", bundle: .module),
            message: String(localized: "Each agent is closed and relaunched with --resume, so its conversation continues with the new items.", bundle: .module),
            confirmTitle: "Restart Agents", confirmAction: .dialogRestartAgentsConfirm, confirmID: .overlayConfirmRestartAgentsConfirm,
            cancelAction: .dialogRestartAgentsCancel, cancelID: .overlayConfirmRestartAgentsCancel, destructive: false, symbol: "arrow.clockwise")
    }
}

/// Context (03 §10.6) como módulo do painel; abre por `panel.context` e não tem botão na faixa de topo.
@MainActor
final class ContextModule: RightPanelModule {
    let id = PanelModuleID.context
    let title = String(localized: "Context", bundle: .module)
    let icon = "square.stack.3d.up"
    private let controller: ContextController

    init(controller: ContextController) { self.controller = controller }

    func makeView(context: RightPanelModuleContext) -> AnyView {
        AnyView(ContextView(controller: controller))
    }
}
