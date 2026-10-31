import RackyCore
import RackyDesignSystem
import RackyProtocol
import Foundation
import SwiftUI

/// "Resume Agents…" (03 §16.7, R2.5): lista os agentes parados da sessão com o contexto que a retomada recarrega, deixa
/// desmarcar, e relança só os marcados com `--resume`, escalonados. Nunca automático; nunca relança uma conversa viva
/// em outro processo (F32).
@MainActor
final class ResumeAgentsController {
    private let workspace: WorkspaceModel
    private let sessionTitle: (UUID) -> String?
    private let selectedSession: () -> UUID?
    private let overlays: OverlayRouter
    private let toasts: ToastCenter

    /// Onde estão os transcripts (os testes apontam para pastas temporárias).
    var history = ConversationHistory.standard()
    var stagger: Duration = .milliseconds(300)
    private(set) var model: ResumeAgentsModel?

    init(
        workspace: WorkspaceModel, sessionTitle: @escaping (UUID) -> String?, selectedSession: @escaping () -> UUID?, overlays: OverlayRouter,
        toasts: ToastCenter
    ) {
        self.workspace = workspace
        self.sessionTitle = sessionTitle
        self.selectedSession = selectedSession
        self.overlays = overlays
        self.toasts = toasts
    }

    var isOpen: Bool { overlays.top?.spec.name == "resume" && model != nil }

    /// Sessão atual; se ela não tem agente parado (banner da janela depois de perder o daemon), a do que parou por último.
    func defaultTarget() -> UUID? {
        let current = workspace.currentSessionID ?? selectedSession()
        if workspace.hasInterruptedAgents(in: current) { return current }
        return workspace.mostRecentSessionWithInterruptedAgents() ?? current
    }

    // MARK: Abrir

    func open(session sid: UUID, from origin: A11yID?) async -> Bool {
        if isOpen { return true }
        let terminals = workspace.resumableAgents(in: sid)
        guard !terminals.isEmpty else { return false }
        let title = sessionTitle(sid) ?? workspace.session?.title ?? ""
        let live = await workspace.liveConversations()
        let costs = await Self.costs(of: terminals, history: history)
        let candidates = terminals.map { t -> ResumeCandidate in
            let native = RestorePlanner.nativeID(of: t) ?? ""
            return ResumeCandidate(
                id: t.id, sessionID: sid, sessionTitle: title, provider: t.provider, model: t.launchSpec.model, lastMessage: t.lastMessage,
                nativeID: native, estimatedTokens: costs[t.id], isLive: live.contains(native), exited: t.state == .exited)
        }
        let model = ResumeAgentsModel(sessionID: sid, sessionTitle: title, candidates: candidates)
        self.model = model
        let opened = overlays.present(
            OverlaySpec(
                name: "resume", id: .overlayResume, width: DS.Layout.dialogWidth, cancelAction: .dialogResumeAgentsCancel,
                content: { AnyView(ResumeAgentsView(model: model)) }),
            from: origin)
        if !opened { self.model = nil }
        return opened
    }

    /// Contexto estimado de cada conversa, lido do fim do transcript (somente leitura, fora do ator principal).
    nonisolated private static func costs(of terminals: [Terminal], history: ConversationHistory) async -> [UUID: Int] {
        var out: [UUID: Int] = [:]
        for t in terminals {
            guard let native = RestorePlanner.nativeID(of: t) else { continue }
            if let s = history.locate(nativeID: native, provider: t.provider, cwd: t.cwd) { out[t.id] = s.estimatedTokens }
        }
        return out
    }

    // MARK: Confirmar

    /// `Resume <n>`: fecha o overlay e relança os marcados. Volta quantos foram relançados.
    func confirm() async throws -> Int {
        guard let model, isOpen else { throw ActionError.failed(.dialogResumeAgentsConfirm, message: "The resume panel isn't open") }
        guard model.count > 0 else { throw ActionError.failed(.dialogResumeAgentsConfirm, message: "Select at least one agent.") }
        let ids = model.selection.chosen.map(\.id)
        self.model = nil
        overlays.dismiss(.action)
        let result = await workspace.resumeSelected(ids, stagger: stagger)
        if result.resumed > 0 {
            toasts.show(
                kind: .info,
                title: result.resumed == 1
                    ? String(localized: "Resumed 1 agent", bundle: .module) : String(localized: "Resumed \(result.resumed) agents", bundle: .module))
        }
        if result.skippedLive > 0 {
            toasts.show(
                kind: .info, title: String(localized: "Skipped \(result.skippedLive) already running in another terminal.", bundle: .module))
        }
        return result.resumed
    }

    // MARK: Ações

    func register(in registry: ActionRegistry) throws {
        func target(_ arg: ActionArgument) -> UUID? {
            if arg.kind == .select, let raw = arg.value, let id = UUID(uuidString: raw) { return id }
            return defaultTarget()
        }
        try registry.register(
            .sessionResumeAgents,
            enablement: { [unowned self] in
                workspace.hasInterruptedAgents(in: defaultTarget())
                    ? .enabled : .disabled(reason: String(localized: "No interrupted agents in this session.", bundle: .module))
            }
        ) { [unowned self] arg in
            guard let sid = target(arg) else { throw ActionError.failed(.sessionResumeAgents, message: "Session not found") }
            let origin: A11yID? = arg.kind == .select ? .sidebarSession(sid.uuidString) : nil
            guard await open(session: sid, from: origin) else {
                throw ActionError.failed(.sessionResumeAgents, message: "No interrupted agents in this session.")
            }
            return "opened"
        }
        func edit(_ id: ActionID, _ change: @escaping @MainActor (ResumeAgentsModel, ActionArgument) throws -> String?) throws {
            try registry.register(id) { [unowned self] arg in
                guard let model, isOpen else { throw ActionError.failed(id, message: "The resume panel isn't open") }
                return try change(model, arg)
            }
        }
        try edit(.dialogResumeAgentsToggleRow) { model, arg in
            guard arg.kind == .select, let raw = arg.value, let id = UUID(uuidString: raw), model.candidates.contains(where: { $0.id == id }) else {
                throw ActionError.failed(.dialogResumeAgentsToggleRow, message: "Agent not found in the list")
            }
            guard model.toggle(id) else {
                throw ActionError.failed(.dialogResumeAgentsToggleRow, message: "Open in another terminal")
            }
            return model.isSelected(id) ? "on" : "off"
        }
        try edit(.dialogResumeAgentsSelectAll) { model, _ in
            model.selectAll()
            return String(model.count)
        }
        try edit(.dialogResumeAgentsSelectNone) { model, _ in
            model.selectNone()
            return "0"
        }
        try registry.register(
            .dialogResumeAgentsConfirm,
            enablement: { [unowned self] in
                guard let model, isOpen else { return .enabled }
                return model.count == 0 ? .disabled(reason: String(localized: "Select at least one agent.", bundle: .module)) : .enabled
            }
        ) { [unowned self] _ in String(try await confirm()) }
        try registry.register(.dialogResumeAgentsCancel) { [unowned self] _ in
            model = nil
            overlays.dismiss(.escape)
            return "closed"
        }
    }
}
