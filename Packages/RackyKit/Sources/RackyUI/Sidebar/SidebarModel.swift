import RackyCore
import RackyPlatform
import RackyProtocol
import RackyStore
import Foundation
import Observation

/// Parte do estado da sidebar que sobrevive ao reinício (`ui_state`, 08 §3): projetos recolhidos, `Show more`,
/// ordenação, filtros, projetos escondidos, sessões recolhidas e a sessão selecionada (03 §2.5, §2.4).
nonisolated struct SidebarPersistedState: Codable, Equatable, Sendable {
    var collapsedProjects: [UUID] = []
    var showMoreOpen: [UUID] = []
    var hiddenProjects: [UUID] = []
    var collapsedSessions: [UUID] = []
    var expandedSummaries: [UUID] = []
    var sort: SidebarSort = .recent
    var filters = SidebarFilters()
    var selectedSession: UUID?
}

/// Modelo observável da sidebar. Só a UI muda estas propriedades (no MainActor); a persistência vai ao Store por tarefas
/// separadas e o Store é a fonte de verdade dos dados (a sidebar observa `snapshots()`, nunca grava a lista).
@MainActor
@Observable
final class SidebarModel {
    static let uiStateKey = "sidebar"

    private(set) var snapshot = StoreSnapshot()
    var query = ""
    private(set) var sort: SidebarSort = .recent
    private(set) var filters = SidebarFilters()
    private(set) var collapsedProjects: Set<UUID> = []
    private(set) var showMoreOpen: Set<UUID> = []
    private(set) var hiddenProjects: Set<UUID> = []
    private(set) var collapsedSessions: Set<UUID> = []
    private(set) var expandedSummaries: Set<UUID> = []
    private(set) var collapsedChildren: Set<UUID> = []
    private(set) var selectedSession: UUID? {
        didSet { if oldValue != selectedSession { onSelectionChange?(selectedSession) } }
    }
    /// Avisa quem mostra o conteúdo da sessão (tabs e panes, T1-14) quando a seleção muda.
    @ObservationIgnored var onSelectionChange: ((UUID?) -> Void)?
    /// Tabelas que a sessão coletou (id, nome, linhas), listadas no card dela; ligado pelo `AppEnvironment`.
    @ObservationIgnored var sessionDatasets: (UUID) -> [SessionDatasetRow] = { _ in [] }
    /// Toda seleção de sessão (mesmo repetida): quem estava numa página do centro (viewer, Computers) volta ao terminal.
    @ObservationIgnored var onSelected: ((UUID) -> Void)?
    /// Mostra o terminal do agente principal da sessão (o item do agente no caminho de dados leva até ele).
    @ObservationIgnored var onShowAgent: ((UUID) -> Void)?
    /// Histórico de navegação: seleção ou Inbox mudou.
    @ObservationIgnored var onNavigate: (() -> Void)?
    /// Avisa a cada snapshot novo do Store (o workspace carrega a sessão selecionada quando ela chega).
    @ObservationIgnored var onSnapshot: ((StoreSnapshot) -> Void)?
    private(set) var pending: [PendingLaunch] = []
    /// Linha pendente aberta no centro (PhaseList ou erro com ações, 03 §2.9). Some quando a sessão fica pronta ou é descartada.
    private(set) var focusedPending: UUID? {
        didSet { if oldValue != focusedPending { onPendingFocusChange?() } }
    }
    @ObservationIgnored var onPendingFocusChange: (() -> Void)?
    /// Atenção (Fatia 2): estado de atividade, não lido e fila. `nil` na Fatia 1 (sem hooks, o agente vivo é `Status unavailable`).
    @ObservationIgnored var attention: AttentionCoordinator?
    /// Inbox (⇧⌘I) no lugar do corpo da sidebar (03 §9.1). Só em memória: reabrir o app volta à lista de sessões.
    private(set) var inboxOpen = false
    /// Diretório de computadores (T3-05): fonte dos pedidos de ajuda que o Inbox mostra ao lado da atenção dos agentes.
    @ObservationIgnored var helpInbox: ComputersModel?
    /// "Subagent computers" (F12): ícone do card, `Restart to apply` e as linhas filhas dos computadores.
    @ObservationIgnored var subagent: SubagentComputersController?
    var inboxFilter: InboxFilter = .all
    var inboxFilterMenuOpen = false
    /// Sessão em edição inline (03 §2.11): no máximo uma.
    private(set) var renamingSession: UUID?
    /// Projeto em edição inline (T1-19): no máximo um, e nunca junto com uma sessão em edição.
    private(set) var renamingProject: UUID?
    /// Último status Git visto por worktree (caminho canônico), alimentado pelo refresh em segundo plano (T1-19).
    private(set) var gitStatus: [String: GitStatus] = [:]
    /// PR de cada sessão (chip do card, T2-05); alimentado pelo `GitHubController`, nunca consultado aqui.
    private(set) var pullRequests: [UUID: PullRequestChipModel] = [:]
    /// Sessão com a nota em edição inline (03 §2.6 linha 3, AC-208): no máximo uma.
    private(set) var editingNote: UUID?
    /// Avisa quem acompanha o Git (o `GitHubController` detecta push e refaz a lista de mudanças).
    var onGitStatus: (@MainActor (GitStatus, String) -> Void)?
    /// Item com o anel do teclado (`nil` = a lista não tem foco de teclado).
    var keyboardFocus: SidebarItemID?
    /// `true` enquanto o popover Sort and Filter está aberto.
    var filterMenuOpen = false
    /// Incrementa para pedir foco da lista (`⇧⌘0`) ou do campo de busca (`⌘F`).
    private(set) var focusListRequest = 0
    private(set) var focusSearchRequest = 0
    /// Pedido de rolagem até o card ativo (M-211): `nonce` muda a cada pedido, mesmo para o mesmo alvo.
    private(set) var reveal: (id: UUID, nonce: Int)?
    /// Ligada ao Store real em `attach`; nos testes de projeção fica nula.
    private var store: RackyStore?
    private var observation: Task<Void, Never>?
    var clock: () -> Date = { Date() }
    private let log = LogFacade(.app, category: "sidebar")

    /// Chamada quando o usuário cancela uma sessão em criação (o orquestrador de lançamento aborta o trabalho).
    var onCancelPending: (UUID) -> Void = { _ in }
    /// `session.cancelLaunch` com o ID de um terminal em ignição (Cancel do pane): `true` se alguém cuidou.
    @ObservationIgnored var cancelLaunchFallback: (UUID) -> Bool = { _ in false }
    /// `Discard` de uma linha pendente com erro: o orquestrador solta o pedido guardado.
    @ObservationIgnored var onDiscardPending: (UUID) -> Void = { _ in }
    /// Cancelamento específico de uma linha pendente que não é de sessão (o clone de `Clone from GitHub…`).
    @ObservationIgnored var pendingCancelHooks: [UUID: () -> Void] = [:]

    init() {}

    // MARK: Projeção

    var input: SidebarInput {
        SidebarInput(
            snapshot: snapshot, query: query, sort: sort, filters: filters, collapsedProjects: collapsedProjects,
            showMoreOpen: showMoreOpen, hiddenProjects: hiddenProjects, collapsedSessions: collapsedSessions,
            expandedSummaries: expandedSummaries, selectedSession: selectedSession, pending: pending, now: clock(),
            attention: attention?.center ?? AttentionCenter(), computers: computerRows, restartPending: restartPendingSessions,
            offersSubagentToggle: toggleSessions, collapsedChildren: collapsedChildren, agentComputers: helpInbox?.agentComputers ?? [:],
            workerComputers: helpInbox?.workerComputers ?? [:], finishedWorkers: helpInbox?.finishedWorkers ?? [], workerNames: workerNames,
            gitStatus: gitStatus, pullRequests: pullRequests, editingNote: editingNote)
    }

    private var workerNames: [UUID: String] {
        guard let helpInbox else { return [:] }
        return helpInbox.workerComputers.compactMapValues { helpInbox.computerAgentNames[$0] }
    }

    /// Linhas filhas por sessão (nome, estado, miniatura) a partir do diretório de computadores.
    private var computerRows: [UUID: [ComputerChildRow]] {
        guard let helpInbox else { return [:] }
        var out: [UUID: [ComputerChildRow]] = [:]
        for row in helpInbox.rows {
            guard let session = helpInbox.sessionIDs[row.id] else { continue }
            out[session, default: []].append(ComputerChildRow(row))
        }
        for key in out.keys { out[key]?.sort { $0.id < $1.id } }
        return out
    }

    private var restartPendingSessions: Set<UUID> {
        guard let subagent else { return [] }
        return Set(snapshot.sessions.filter { subagent.restartPending(session: $0.id) }.map(\.id))
    }

    private var toggleSessions: Set<UUID> {
        guard let subagent else { return [] }
        return Set(snapshot.sessions.filter { subagent.offersToggle(for: $0.id) }.map(\.id))
    }

    /// Quem é cada terminal de agente (sessão, projeto, agente) para títulos de notificação e linhas do Inbox.
    func attentionContexts() -> [UUID: AttentionContext] { AttentionContext.contexts(in: snapshot) }

    // MARK: Inbox

    func setInbox(open: Bool) {
        guard inboxOpen != open else { return }
        inboxOpen = open
        onNavigate?()
    }

    /// Pedidos de ajuda de computador abertos (T3-05): entram em `Needs You` do mesmo Inbox, antes dos agentes (prioridade 1).
    var helpItems: [InboxItem] {
        guard let helpInbox else { return [] }
        return helpInbox.inbox.filter { $0.phase == .needsYou && (inboxFilter != .unread || !$0.read) }
    }

    /// Pedidos de computador esperando você no modo Ask (F12): primeiro em `Needs You`.
    var approvalItems: [ComputerApprovalRequest] { helpInbox?.approvals ?? [] }

    /// "Lote concluído" (07 CS-326, AC-429): um item por lote, em `Done` do mesmo Inbox. Clicar abre o painel `Batch`.
    var batchItems: [AttentionItem] { (attention?.center.batchItems ?? []).sorted { $0.createdAt > $1.createdAt } }

    var inboxFeed: InboxFeed {
        (attention?.center ?? AttentionCenter()).inbox(contexts: attentionContexts(), filter: inboxFilter, now: clock())
    }

    var projection: SidebarProjection { SidebarProjector.build(input) }

    func session(_ id: UUID) -> Session? { snapshot.sessions.first { $0.id == id } }
    func project(_ id: UUID) -> Project? { snapshot.projects.first { $0.id == id } }
    func worktree(of session: Session) -> Worktree? { session.worktreeID.flatMap { id in snapshot.worktrees.first { $0.id == id } } }

    // MARK: Store

    /// Liga ao Store: carrega o estado salvo e passa a observar os snapshots (T1-05).
    func attach(store: RackyStore) async {
        self.store = store
        if let saved = try? await store.uiState(Self.uiStateKey, as: SidebarPersistedState.self) { apply(saved) }
        observation?.cancel()
        observation = Task { [weak self] in
            do {
                for try await snap in store.snapshots() { self?.apply(snap) }
            } catch {
                self?.log.error("sidebar observation ended: \(error)")
            }
        }
    }

    func detach() {
        observation?.cancel()
        observation = nil
    }

    /// Aplica um snapshot novo. Mantém a seleção válida: se a sessão selecionada sumiu, a seleção é limpa.
    func apply(_ snap: StoreSnapshot) {
        snapshot = snap
        onSnapshot?(snap)
        if let s = selectedSession, !snap.sessions.contains(where: { $0.id == s }) { selectedSession = nil }
        // Sessão arquivada escondida pelo filtro (ex.: a seleção salva ao relançar): a landing volta em vez de uma sessão que a
        // sidebar não mostra.
        if let s = selectedSession, !filters.archived,
           let session = snap.sessions.first(where: { $0.id == s }), session.archivedAt != nil || session.lifecycle == .archived {
            selectedSession = nil
            persist()
        }
        // A sessão aberta é de um projeto escondido (ex.: New Session nele): o projeto volta a aparecer, senão a sessão some.
        if let s = selectedSession, let project = snap.sessions.first(where: { $0.id == s })?.projectID,
           hiddenProjects.contains(project) {
            hiddenProjects.remove(project)
            persist()
        }
        if let r = renamingSession, !snap.sessions.contains(where: { $0.id == r }) { renamingSession = nil }
        if let r = renamingProject, !snap.projects.contains(where: { $0.id == r }) { renamingProject = nil }
    }

    private func apply(_ saved: SidebarPersistedState) {
        collapsedProjects = Set(saved.collapsedProjects)
        showMoreOpen = Set(saved.showMoreOpen)
        hiddenProjects = Set(saved.hiddenProjects)
        collapsedSessions = Set(saved.collapsedSessions)
        expandedSummaries = Set(saved.expandedSummaries)
        sort = saved.sort
        filters = saved.filters
        selectedSession = saved.selectedSession
    }

    private func persist() {
        guard let store else { return }
        let state = SidebarPersistedState(
            collapsedProjects: Array(collapsedProjects), showMoreOpen: Array(showMoreOpen), hiddenProjects: Array(hiddenProjects),
            collapsedSessions: Array(collapsedSessions), expandedSummaries: Array(expandedSummaries), sort: sort, filters: filters,
            selectedSession: selectedSession)
        Task { try? await store.scheduleUIState(Self.uiStateKey, state) }
    }

    // MARK: Seleção

    /// Seleciona a sessão e a marca como vista. Devolve `false` se ela não existe.
    @discardableResult
    func select(_ id: UUID, closingInbox: Bool = true, requestingListFocus: Bool = true) -> Bool {
        guard let session = session(id) else { return false }
        focusedPending = nil
        selectedSession = id
        if closingInbox { inboxOpen = false }
        keyboardFocus = nil
        if requestingListFocus { focusListRequest += 1 }
        if session.unread, let store {
            Task { try? await store.markSessionViewed(id: id, at: clock()) }
        }
        persist()
        onSelected?(id)
        onNavigate?()
        return true
    }

    /// Sai da sessão que acabou de ser arquivada ou apagada: vai para a vizinha visível (a seguinte, senão a anterior) ou, sem
    /// nenhuma, deixa a seleção vazia (a landing volta).
    func leave(session id: UUID) {
        guard selectedSession == id else { return }
        let order = projection.sessionOrder
        if let i = order.firstIndex(of: id), let next = order.indices.contains(i + 1) ? order[i + 1] : (i > 0 ? order[i - 1] : nil) {
            select(next)
        } else {
            selectedSession = nil
            persist()
        }
    }

    /// Sessão vizinha na ordem visível (⇧⌘↑/↓); sem seleção, o primeiro/último.
    @discardableResult
    func selectNeighbor(_ delta: Int) -> UUID? {
        let order = projection.sessionOrder
        guard !order.isEmpty else { return nil }
        let current = selectedSession.flatMap { order.firstIndex(of: $0) }
        let next: Int
        if let current { next = min(max(current + delta, 0), order.count - 1) } else { next = delta > 0 ? 0 : order.count - 1 }
        select(order[next])
        return order[next]
    }

    /// ⌘1…⌘9: sessão N na ordem visível.
    @discardableResult
    func selectNth(_ n: Int) -> UUID? {
        let order = projection.sessionOrder
        guard order.indices.contains(n - 1) else { return nil }
        select(order[n - 1])
        return order[n - 1]
    }

    // MARK: Projetos

    func toggleProject(_ id: UUID) {
        if collapsedProjects.contains(id) { collapsedProjects.remove(id) } else { collapsedProjects.insert(id) }
        persist()
    }

    func setProject(_ id: UUID, collapsed: Bool) {
        if collapsed { collapsedProjects.insert(id) } else { collapsedProjects.remove(id) }
        persist()
    }

    func showMore(_ projectID: UUID, open: Bool = true) {
        if open { showMoreOpen.insert(projectID) } else { showMoreOpen.remove(projectID) }
        persist()
    }

    func collapseAllSessions(in projectID: UUID) {
        let ids = snapshot.sessions.filter { $0.projectID == projectID }.map(\.id)
        collapsedSessions.formUnion(ids)
        persist()
    }

    func setSession(_ id: UUID, agentsCollapsed: Bool) {
        if agentsCollapsed { collapsedSessions.insert(id) } else { collapsedSessions.remove(id) }
        persist()
    }

    /// Chevron da linha do agente: recolhe ou expande os subagentes dele (só em memória).
    func toggleChildren(terminal id: UUID) {
        if collapsedChildren.contains(id) { collapsedChildren.remove(id) } else { collapsedChildren.insert(id) }
    }

    func toggleSummary(_ id: UUID) {
        if expandedSummaries.contains(id) { expandedSummaries.remove(id) } else { expandedSummaries.insert(id) }
        persist()
    }

    func hideProject(_ id: UUID) {
        hiddenProjects.insert(id)
        persist()
    }

    // MARK: Ordenação e filtros

    func setSort(_ value: SidebarSort) {
        sort = value
        persist()
    }

    func setFilter(_ key: String, on: Bool) {
        switch key {
        case "idleOverWeek": filters.idleOverWeek = on
        case "archived": filters.archived = on
        case "hiddenProjects": filters.hiddenProjects = on
        case "mainCheckouts": filters.mainCheckouts = on
        default: return
        }
        persist()
    }

    func resetFilters() {
        sort = .recent
        filters = SidebarFilters()
        persist()
    }

    func clearFilters() {
        filters = SidebarFilters()
        persist()
    }

    // MARK: Renomear (03 §2.11)

    func beginRename(_ id: UUID) -> Bool {
        guard session(id) != nil else { return false }
        renamingProject = nil
        renamingSession = id
        return true
    }

    func cancelRename() { renamingSession = nil }

    /// Confirma o nome. Vazio volta ao nome automático: a pasta (ou a branch) da sessão. Não renomeia pasta nem branch.
    func commitRename(_ text: String) async throws {
        guard let id = renamingSession, var s = session(id) else { return }
        renamingSession = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? automaticName(for: s) : trimmed
        guard name != s.title, let store else { return }
        s.title = name
        // Reflete já; o snapshot do Store confirma em seguida.
        snapshot.sessions = snapshot.sessions.map { $0.id == id ? s : $0 }
        try await store.save(s)
    }

    private func automaticName(for s: Session) -> String {
        if let wt = worktree(of: s), !wt.branch.isEmpty { return wt.branch }
        return URL(fileURLWithPath: s.folderPath).lastPathComponent
    }

    // MARK: Renomear projeto (T1-19)

    func beginRenameProject(_ id: UUID) -> Bool {
        guard project(id) != nil else { return false }
        renamingSession = nil
        renamingProject = id
        return true
    }

    func cancelRenameProject() { renamingProject = nil }

    /// Fecha a edição e devolve o que gravar; reflete o nome já na tela (o snapshot do Store confirma em seguida).
    /// Vazio devolve nome vazio: o `ProjectService` o troca pelo nome da pasta.
    func finishRenameProject(_ text: String) -> (id: UUID, name: String)? {
        guard let id = renamingProject, let p = project(id) else {
            renamingProject = nil
            return nil
        }
        renamingProject = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = trimmed.isEmpty ? URL(fileURLWithPath: p.rootPath).lastPathComponent : trimmed
        snapshot.projects = snapshot.projects.map { $0.id == id ? { var c = $0; c.name = shown; return c }($0) : $0 }
        return (id, trimmed)
    }

    func setGitStatus(_ status: GitStatus, at path: String) {
        gitStatus[path] = status
        onGitStatus?(status, path)
    }

    func setPullRequests(_ chips: [UUID: PullRequestChipModel]) {
        if chips != pullRequests { pullRequests = chips }
    }

    // MARK: Nota da sessão (03 §2.6 linha 3, AC-208)

    func beginEditNote(_ id: UUID) -> Bool {
        guard session(id) != nil else { return false }
        renamingSession = nil
        renamingProject = nil
        editingNote = id
        return true
    }

    func cancelEditNote() { editingNote = nil }

    /// Grava a nota do usuário; texto vazio remove a nota. Reflete já; o snapshot do Store confirma em seguida.
    func commitNote(_ text: String, to id: UUID? = nil) async throws {
        guard let id = id ?? editingNote, var s = session(id) else { return }
        editingNote = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = trimmed.isEmpty ? nil : StatusNote(text: trimmed, author: "user", at: clock())
        guard note?.text != s.statusNote?.text else { return }
        s.statusNote = note
        snapshot.sessions = snapshot.sessions.map { $0.id == id ? s : $0 }
        try await store?.save(s)
    }

    // MARK: Linhas pendentes (03 §2.9)

    func beginPending(_ launch: PendingLaunch) { pending.append(launch) }

    func advance(pending id: UUID, to phase: PendingLaunch.Phase) {
        guard let i = pending.firstIndex(where: { $0.id == id }) else { return }
        if pending[i].phase != phase, pending[i].failure == nil, !pending[i].history.contains(pending[i].phase) {
            pending[i].history.append(pending[i].phase)
        }
        pending[i].phase = phase
        pending[i].failure = nil
        pending[i].detail = nil
        pending[i].recoveries = []
    }

    /// Atualiza o texto de andamento de um clone sem acumular fases no histórico.
    func setCloneProgress(pending id: UUID, text: String) {
        guard let i = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[i].phase = .cloning(text)
        pending[i].failure = nil
    }

    /// Volta a linha ao começo para uma nova tentativa (Try Again): sem histórico nem erro.
    func restart(pending id: UUID) {
        guard let i = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[i].phase = .preparing
        pending[i].history = []
        pending[i].failure = nil
        pending[i].detail = nil
        pending[i].recoveries = []
    }

    func fail(pending id: UUID, message: String, detail: String? = nil, recoveries: [SessionRecovery] = []) {
        guard let i = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[i].failure = message
        pending[i].detail = detail
        pending[i].recoveries = recoveries
    }

    func pending(_ id: UUID) -> PendingLaunch? { pending.first { $0.id == id } }

    /// Informa a sessão que a linha esconde (o ID final só existe depois de reaproveitar uma sessão "não iniciada").
    func hide(session sessionID: UUID, behind pendingID: UUID) {
        guard let i = pending.firstIndex(where: { $0.id == pendingID }) else { return }
        pending[i].sessionID = sessionID
    }

    /// Abre a linha pendente no centro (clique na linha, ou criação pelo composer).
    func focus(pending id: UUID) {
        guard pending.contains(where: { $0.id == id }) else { return }
        focusedPending = id
        keyboardFocus = nil
    }

    func finish(pending id: UUID) {
        pending.removeAll { $0.id == id }
        if focusedPending == id { focusedPending = nil }
    }

    /// `Cancel` da linha pendente: remove e avisa o orquestrador para abortar. `false` se já terminou.
    @discardableResult
    func cancel(pending id: UUID) -> Bool {
        guard pending.contains(where: { $0.id == id }) else { return false }
        pending.removeAll { $0.id == id }
        if focusedPending == id { focusedPending = nil }
        onCancelPending(id)
        pendingCancelHooks.removeValue(forKey: id)?()
        return true
    }

    // MARK: Foco e rolagem

    func requestListFocus() {
        if keyboardFocus == nil { keyboardFocus = selectedSession.map(SidebarItemID.session) ?? projection.items.first }
        focusListRequest += 1
    }

    func requestSearchFocus() { focusSearchRequest += 1 }

    @discardableResult
    func revealCurrent() -> Bool {
        guard let id = selectedSession else { return false }
        // Se o projeto da sessão está recolhido, expande para o card existir (M-211).
        if let pid = session(id)?.projectID {
            if collapsedProjects.contains(pid) { setProject(pid, collapsed: false) }
            if !projection.projects.contains(where: { $0.id == pid && $0.sessions.contains { $0.id == id } }) { showMore(pid) }
        }
        reveal = (id, (reveal?.nonce ?? 0) + 1)
        return true
    }
}

/// Uma tabela coletada por uma sessão, como linha do card dela na sidebar.
struct SessionDatasetRow: Identifiable, Equatable {
    let id: String
    let name: String
    let rows: Int
}
