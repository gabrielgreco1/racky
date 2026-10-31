import RackyCore
import RackyDesignSystem
import RackyProtocol
import AppKit
import Foundation
import Observation

/// Aba "Conversations" do painel direito (03 §10.5, ⇧⌘H): conversas passadas de Claude e Codex da sessão, do projeto ou de
/// tudo, lidas dos transcripts nativos (somente leitura; nada vai para o banco). Resume em tab ou split, copiar comando e ID,
/// e leitura do transcript.
@MainActor @Observable
final class ConversationsController {
    enum Scope: String, CaseIterable {
        case session, project, all
    }

    struct OpenTranscript: Equatable {
        var summary: ConversationSummary
        var blocks: [TranscriptBlock]
    }

    private(set) var scope: Scope = .session
    var query = ""
    private(set) var scan = ConversationScan()
    private(set) var isLoading = false
    private(set) var live: Set<String> = []
    private(set) var transcript: OpenTranscript?
    /// Muda quando a lista precisa ser relida (escopo ou sessão); a view recarrega por ele.
    var reloadKey: String { "\(scope.rawValue)-\(workspace.currentSessionID?.uuidString ?? "")" }

    @ObservationIgnored var history = ConversationHistory.standard()
    /// Relógio e área de transferência trocáveis nos testes.
    @ObservationIgnored var now: () -> Date = { Date() }
    @ObservationIgnored var copyToPasteboard: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    @ObservationIgnored var liveConversations: @Sendable () async -> Set<String>
    @ObservationIgnored private let workspace: WorkspaceModel
    @ObservationIgnored private let sidebar: SidebarModel
    @ObservationIgnored private let overlays: OverlayRouter
    @ObservationIgnored private let toasts: ToastCenter
    @ObservationIgnored private let elements: UIElementStore
    @ObservationIgnored private let rightPanel: RightPanelController

    init(
        workspace: WorkspaceModel, sidebar: SidebarModel, overlays: OverlayRouter, toasts: ToastCenter, elements: UIElementStore,
        rightPanel: RightPanelController
    ) {
        self.workspace = workspace
        self.sidebar = sidebar
        self.overlays = overlays
        self.toasts = toasts
        self.elements = elements
        self.rightPanel = rightPanel
        liveConversations = { [workspace] in await workspace.liveConversations() }
    }

    // MARK: Consulta

    /// Pastas do escopo; `nil` = todas as conversas da máquina.
    var scopeFolders: [String]? {
        guard let session = workspace.session else { return scope == .all ? nil : [] }
        switch scope {
        case .all: return nil
        case .session: return [session.folderPath]
        case .project:
            guard let pid = session.projectID else { return [session.folderPath] }
            var folders = sidebar.snapshot.sessions.filter { $0.projectID == pid }.map(\.folderPath)
            if let root = sidebar.snapshot.projects.first(where: { $0.id == pid })?.rootPath { folders.append(root) }
            return Array(Set(folders + [session.folderPath]))
        }
    }

    /// Lista filtrada pela busca (título, branch, agente).
    var rows: [ConversationSummary] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return scan.conversations }
        return scan.conversations.filter {
            $0.title.lowercased().contains(q) || ($0.branch ?? "").lowercased().contains(q)
                || ProviderAdapters.adapter(for: $0.provider).displayName.lowercased().contains(q)
        }
    }

    func isLive(_ c: ConversationSummary) -> Bool { live.contains(c.nativeID) }
    func conversation(_ id: String) -> ConversationSummary? { scan.conversations.first { $0.nativeID == id } }

    func reload() async {
        isLoading = true
        let folders = scopeFolders
        let history = history
        let result = await history.scanAsync(cwds: folders)
        let liveNow = await liveConversations()
        scan = result
        live = liveNow
        isLoading = false
    }

    func setScope(_ new: Scope) {
        guard new != scope else { return }
        scope = new
        transcript = nil
    }

    // MARK: Ações

    private func target(_ arg: ActionArgument, _ id: ActionID) throws -> ConversationSummary {
        guard arg.kind == .select, let raw = arg.value, let c = conversation(raw) else {
            throw ActionError.failed(id, message: "Conversation not found")
        }
        return c
    }

    /// Abre o painel direito neste módulo e relê a lista.
    private func present() {
        rightPanel.show(.conversations)
        Task { await reload() }
    }

    private func resume(_ c: ConversationSummary, split: Bool, _ id: ActionID) throws -> String {
        if isLive(c) {
            toasts.show(kind: .info, title: String(localized: "This conversation is already running in another terminal.", bundle: .module))
            throw ActionError.failed(id, message: "Open in another terminal")
        }
        guard workspace.isLoaded else { throw ActionError.failed(id, message: "Select a session first.") }
        guard let terminal = workspace.resumeConversation(c, split: split) else {
            throw ActionError.failed(id, message: "Couldn't open a terminal for this conversation.")
        }
        return terminal.uuidString
    }

    func register(in registry: ActionRegistry) throws {
        try registry.register(.panelConversations) { [unowned self] _ in
            if rightPanel.isOn(.conversations) {
                rightPanel.hide(.conversations)
                return "closed"
            }
            present()
            return "open"
        }
        try registry.register(.tabQuickLaunchResume) { [unowned self] _ in
            setScope(.session)
            present()
            return "open"
        }
        try registry.register(.conversationSetScope) { [unowned self] arg in
            guard arg.kind == .select, let raw = arg.value, let new = Scope(rawValue: raw) else {
                throw ActionError.failed(.conversationSetScope, message: "expected select(session|project|all)")
            }
            setScope(new)
            await reload()
            return new.rawValue
        }
        try registry.register(.conversationSetQuery) { [unowned self] arg in
            query = arg.value ?? ""
            return query
        }
        try registry.register(.conversationResume) { [unowned self] arg in try resume(target(arg, .conversationResume), split: false, .conversationResume) }
        try registry.register(.conversationResumeSplit) { [unowned self] arg in
            try resume(target(arg, .conversationResumeSplit), split: true, .conversationResumeSplit)
        }
        try registry.register(.conversationCopyResumeCommand) { [unowned self] arg in
            let command = try target(arg, .conversationCopyResumeCommand).resumeCommand
            copyToPasteboard(command)
            return command
        }
        try registry.register(.conversationCopyId) { [unowned self] arg in
            let id = try target(arg, .conversationCopyId).nativeID
            copyToPasteboard(id)
            return id
        }
        try registry.register(.conversationShowTranscript) { [unowned self] arg in
            let c = try target(arg, .conversationShowTranscript)
            let blocks = await history.transcriptAsync(of: c)
            transcript = OpenTranscript(summary: c, blocks: blocks)
            return String(blocks.count)
        }
        try registry.register(.conversationBack, enablement: { [unowned self] in
            transcript == nil ? .disabled(reason: String(localized: "No transcript is open.", bundle: .module)) : .enabled
        }) { [unowned self] _ in
            transcript = nil
            return nil
        }
        try registry.register(.conversationMenu) { [unowned self] arg in
            let c = try target(arg, .conversationMenu)
            let argument = ActionArgument.select(c.nativeID)
            let entries: [DSMenuEntry] = [
                .item(DSMenuItem("resume", String(localized: "Resume in New Tab", bundle: .module), shortcut: "↵", action: .conversationResume, argument: argument)),
                .item(DSMenuItem("resumeSplit", String(localized: "Resume in Split", bundle: .module), action: .conversationResumeSplit, argument: argument)),
                .item(DSMenuItem("copyCommand", String(localized: "Copy Resume Command", bundle: .module), action: .conversationCopyResumeCommand, argument: argument)),
                .item(DSMenuItem("transcript", String(localized: "Show Transcript", bundle: .module), action: .conversationShowTranscript, argument: argument)),
                .item(DSMenuItem("copyID", String(localized: "Copy Conversation ID", bundle: .module), action: .conversationCopyId, argument: argument)),
            ]
            let anchor = elements.frame(of: .rightPanelConversationsRow(c.nativeID)) ?? .zero
            return DSMenuPanel.present(router: overlays, registry: registry, name: "conversationMenu", anchor: anchor, entries: entries, alignment: .trailing)
                ? "opened" : nil
        }
    }
}
