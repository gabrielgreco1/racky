import RackyCore
import RackyDesignSystem
import RackyProtocol
import RackyStore
import Foundation

// Projeção pura (sem SwiftUI): snapshot do Store + estado da sidebar -> o que a sidebar mostra (03 §2).
// Toda regra de filtro, ordem, agregação de estado e texto de linha mora aqui e é testada sem janela.

/// Identidade de um item navegável da sidebar (teclado, foco, rolagem).
enum SidebarItemID: Hashable {
    case project(UUID)
    case session(UUID)
    case agent(session: UUID, terminal: UUID)
    case pending(UUID)
    case showMore(UUID)
}

nonisolated enum SidebarSort: String, Codable, CaseIterable, Equatable, Sendable {
    case recent, name
}

/// Filtros `Show` do menu Sort and Filter (03 §2.4). Padrão: tudo desmarcado, menos `Main Checkouts`.
nonisolated struct SidebarFilters: Codable, Equatable, Sendable {
    var idleOverWeek = false
    var archived = false
    var hiddenProjects = false
    var mainCheckouts = true

    var isDefault: Bool { self == SidebarFilters() }
}

/// Sessão em criação (03 §2.9). Existe só em memória: nasce quando o composer fecha e some quando a sessão fica pronta.
struct PendingLaunch: Identifiable, Equatable {
    enum Phase: Equatable {
        case preparing, fetching, creatingWorktree
        case startingAgent(String)
        /// `git clone` em andamento (F24); o texto já traz o percentual (`Cloning… 42%`).
        case cloning(String)
    }
    var id: UUID
    var name: String
    var projectID: UUID?
    var phase: Phase
    /// Mensagem curta da falha (`Couldn't create worktree`); não nula = estado de erro (M-205).
    var failure: String?
    /// Sessão já gravada no Store que esta linha esconde até ficar pronta (a linha vira o card, M-501).
    var sessionID: UUID?
    /// Agente da sessão em criação (logo e texto do centro).
    var provider: TerminalProvider = .claude
    /// Detalhe da falha para o centro (03 §6.4) e as saídas que a linha oferece além de `Discard`.
    var detail: String?
    var recoveries: [SessionRecovery] = []
    /// Fases já concluídas, na ordem (a PhaseList do centro mostra check nelas e spinner na atual).
    var history: [Phase] = []
    /// Linha de `Clone from GitHub` (F24): não tem agente, worktree nem terminal; o centro mostra só o andamento.
    var isClone = false

    init(
        id: UUID = .v7(), name: String, projectID: UUID?, phase: Phase = .preparing, failure: String? = nil, sessionID: UUID? = nil,
        provider: TerminalProvider = .claude
    ) {
        self.id = id; self.name = name; self.projectID = projectID; self.phase = phase; self.failure = failure; self.sessionID = sessionID
        self.provider = provider
    }

    var phaseText: String {
        if let failure { return failure }
        return Self.text(of: phase)
    }

    static func text(of phase: Phase) -> String {
        switch phase {
        case .preparing: String(localized: "Preparing…", bundle: .module)
        case .fetching: String(localized: "Fetching origin…", bundle: .module)
        case .creatingWorktree: String(localized: "Creating worktree…", bundle: .module)
        case .startingAgent(let agent): "Starting \(agent)…"
        case .cloning(let text): text
        }
    }
}

enum SidebarBadge: Equatable {
    case main, detached, conflicts, renameFailed

    var title: String {
        switch self {
        case .main: String(localized: "Main", bundle: .module)
        case .detached: String(localized: "Detached", bundle: .module)
        case .conflicts: String(localized: "Conflicts", bundle: .module)
        case .renameFailed: String(localized: "Rename failed", bundle: .module)
        }
    }
    var variant: DSBadgeVariant {
        switch self {
        case .main, .detached: .neutral
        case .conflicts: .warning
        case .renameFailed: .error
        }
    }
}

/// Segunda linha do card (03 §2.6).
enum SidebarLine2: Equatable {
    case branch(String)
    case folder(String)
    case missingFolder
}

/// Linha de um subagente sob o agente pai (hooks `SubagentStart`/`SubagentStop`, com ou sem computador).
struct SubagentRowData: Identifiable, Equatable {
    var id: String
    var title: String
    var phase: SubagentInfo.Phase
    var startedAt: Date
    var endedAt: Date?
    var subtitle: String?
    /// Computador do subagente (hover com a pré-visualização e o viewer).
    var computer: String?
    /// Worker de app (sessão separada de Codex / OpenCode / Claude): o CLI e o terminal dele (clique foca o pane).
    var worker: TerminalProvider?
    var workerTerminalID: UUID?
    /// Tarefa do worker, ao lado do nome do agente ("Codex 1  books p1–4").
    var task: String?

    var glyph: DSIndicatorGlyph {
        switch phase {
        case .running: .working
        case .needsInput: .needsInput
        case .done: .done
        case .failed: .dot(DS.ColorSpec.agentFailed)
        }
    }

    var stateLabel: String {
        switch phase {
        case .running: String(localized: "Running", bundle: .module)
        case .needsInput: String(localized: "Needs input", bundle: .module)
        case .done: String(localized: "Done", bundle: .module)
        case .failed: String(localized: "Failed", bundle: .module)
        }
    }

    /// `42s`, `38m`, `1h`, `2d`: tempo decorrido (parado no fim quando o subagente terminou).
    func elapsedText(now: Date) -> String {
        let seconds = max(0, Int((endedAt ?? now).timeIntervalSince(startedAt)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }
}

struct AgentRowData: Identifiable, Equatable {
    var id: UUID
    var sessionID: UUID
    var provider: TerminalProvider
    var glyph: DSIndicatorGlyph
    var lead: String
    var trail: String?
    var timeText: String
    var stateLabel: String
    /// Terminal com `done`, `failed` ou BEL ainda não visto: texto em 600 (03 §2.7).
    var unread = false
    /// Texto inteiro da última mensagem, para o tooltip da linha (03 §2.7).
    var fullMessage: String = ""
    /// Subagentes do agente (o chevron da linha recolhe e expande).
    var children: [SubagentRowData] = []
    var childrenCollapsed = false
}

/// Grupo da pílula-resumo (03 §2.6): estado + contagem.
struct SummaryGroup: Equatable {
    var glyph: DSIndicatorGlyph
    var providers: [TerminalProvider]
    var count: Int
}

struct SessionCardData: Identifiable, Equatable {
    var id: UUID
    var title: String
    var projectID: UUID?
    var kind: SessionKind
    var badges: [SidebarBadge]
    var timeText: String
    var line2: SidebarLine2
    var notStarted: Bool
    var glyph: DSIndicatorGlyph
    var stateLabel: String
    var unread: Bool
    var selected: Bool
    var note: String?
    /// Autor e tempo da nota, para o hover (AC-208), e se ela está em edição inline.
    var noteDetail: String?
    var editingNote = false
    /// Linha 2 (03 §2.6): commits não enviados (só > 0), ponto de alterações e chip de PR.
    var ahead = 0
    var dirty = false
    var pr: PullRequestChipModel?
    var agentRows: [AgentRowData]
    /// Terminais agrupados em `+N terminals` (shells ociosos com agentes na sessão).
    var groupedTerminals: Int
    var summary: [SummaryGroup]?
    var summaryExpanded: Bool
    var agentsCollapsed: Bool
    var branch: String?
    var folderPath: String
    var a11yLabel: String
    /// "Subagent computers" da sessão (F12) e se o card oferece o ícone (sessões só de shell ou de outros agentes não).
    var subagent: SubagentComputersMode = .off
    var offersSubagentToggle = false
    /// O Claude vivo foi lançado com outro modo: `Restart to apply`.
    var restartToApply = false
    /// Computadores da sessão (linhas filhas, 07 CS-320).
    var computers: [ComputerChildRow] = []
}

struct PendingRowData: Identifiable, Equatable {
    var id: UUID
    var name: String
    var phaseText: String
    var failed: Bool
}

struct ProjectSectionData: Identifiable, Equatable {
    var id: UUID
    var name: String
    var kind: ProjectKind
    var collapsed: Bool
    var sessionCount: Int
    var pending: [PendingRowData]
    var sessions: [SessionCardData]
    var hiddenCount: Int
    var showMoreExpanded: Bool
    var hasNoSessions: Bool
}

enum SidebarEmptyState: Equatable {
    case none
    /// Nenhum projeto e nenhuma sessão (03 §2.13).
    case workspace
    case searchNoResults
    case filtersNoResults
}

struct SidebarProjection: Equatable {
    var projects: [ProjectSectionData] = []
    var cleanSessions: [SessionCardData] = []
    var cleanPending: [PendingRowData] = []
    var showSessionsSection: Bool { !cleanSessions.isEmpty || !cleanPending.isEmpty }
    var empty: SidebarEmptyState = .none
    /// Sessões arquivadas que o filtro esconde e que apareceriam com "Archived Sessions" ligado (o vazio oferece mostrá-las).
    var archivedHidden = 0
    /// Itens navegáveis na ordem visual (teclado).
    var items: [SidebarItemID] = []
    /// Cards de sessão na ordem visual (⌘1…9, ⇧⌘↑/↓).
    var sessionOrder: [UUID] = []
}

/// Entrada da projeção: tudo que decide o que a sidebar mostra.
struct SidebarInput {
    var snapshot: StoreSnapshot
    var query = ""
    var sort: SidebarSort = .recent
    var filters = SidebarFilters()
    var collapsedProjects: Set<UUID> = []
    var showMoreOpen: Set<UUID> = []
    var hiddenProjects: Set<UUID> = []
    var collapsedSessions: Set<UUID> = []
    var expandedSummaries: Set<UUID> = []
    var selectedSession: UUID?
    var pending: [PendingLaunch] = []
    var now = Date()
    var home = NSHomeDirectory()
    /// Estado de atividade e leitura dos terminais (Fatia 2). Vazio na Fatia 1: o agente vivo fica `Status unavailable`.
    var attention = AttentionCenter()
    /// Computadores por sessão (F12) e as sessões com "Restart to apply" pendente.
    var computers: [UUID: [ComputerChildRow]] = [:]
    var restartPending: Set<UUID> = []
    var offersSubagentToggle: Set<UUID> = []
    /// Agentes com as linhas de subagentes recolhidas e o computador de cada subagente (`agent_id` -> nome).
    var collapsedChildren: Set<UUID> = []
    var agentComputers: [String: String] = [:]
    /// Computador de cada worker de app (terminal -> nome): vai na linha do worker, não como linha de computador solta.
    var workerComputers: [UUID: String] = [:]
    /// Workers que já entregaram o resultado: aparecem como concluídos mesmo com o CLI aberto esperando input.
    var finishedWorkers: Set<UUID> = []
    /// Nome de cada worker vindo do Store ("Codex 1"), para terminais abertos antes do nome entrar no título.
    var workerNames: [UUID: String] = [:]
    /// Status Git por pasta de worktree, PR por sessão (T2-05) e a sessão com a nota em edição.
    var gitStatus: [String: GitStatus] = [:]
    var pullRequests: [UUID: PullRequestChipModel] = [:]
    var editingNote: UUID?
}

enum SidebarProjector {
    // MARK: Texto

    /// `now`, `12m`, `3h`, `5d` (03 §2.6).
    static func relativeTime(since date: Date?, now: Date) -> String {
        guard let date else { return "" }
        let s = max(0, now.timeIntervalSince(date))
        if s < 60 { return String(localized: "now", bundle: .module) }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86400))d"
    }

    static func abbreviate(path: String, home: String) -> String {
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    static func providerName(_ p: TerminalProvider) -> String {
        switch p {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        case .shell: "Terminal"
        case .custom: "Command"
        }
    }

    // MARK: Estado

    /// Glifo e rótulo de um terminal na Fatia 1 (02 §2.6/§2.7): sem hooks, agente vivo é `unknown`.
    static func glyph(for t: Terminal) -> (glyph: DSIndicatorGlyph, label: String) {
        switch t.state {
        case .launching: return (.spinner, String(localized: "Starting…", bundle: .module))
        case .running:
            return t.provider.isAgent
                ? (.unknown, String(localized: "Status unavailable", bundle: .module)) : (.none, String(localized: "Running", bundle: .module))
        case .exited:
            if let code = t.exitCode, code != 0 {
                return (.dot(DS.ColorSpec.agentFailed), String(localized: "Exited with code \(code)", bundle: .module))
            }
            return (.dot(DS.ColorSpec.processExited), String(localized: "Exited", bundle: .module))
        case .killed: return (.dot(DS.ColorSpec.processExited), String(localized: "Stopped", bundle: .module))
        case .failedToStart: return (.dot(DS.ColorSpec.agentFailed), String(localized: "Couldn't start", bundle: .module))
        case .interrupted: return (.dot(DS.ColorSpec.agentInterrupted), String(localized: "Interrupted", bundle: .module))
        case .containerStopped: return (.dot(DS.ColorSpec.agentFailed), String(localized: "Container stopped", bundle: .module))
        case .notStarted: return (.none, String(localized: "Not started", bundle: .module))
        }
    }

    /// Um terminal na agregação: glifo, rótulo e posição na ordem de 01 §6.3 (maior primeiro).
    struct StatusSample: Equatable {
        var glyph: DSIndicatorGlyph
        var label: String
        var rank: Int
    }

    /// Ordem de gravidade da agregação só por glifo (processo e Fatia 1). A escala é a de 01 §6.3:
    /// needsInput > failed > blocked > working > waiting > done não lido > interrupted > starting > done lido > idle > unknown.
    private static func rank(_ g: DSIndicatorGlyph) -> Int {
        switch g {
        case .needsInput: 100
        case .alert: 95
        case .dot(let c):
            c == DS.ColorSpec.agentFailed ? 91 : (c == DS.ColorSpec.agentInterrupted ? 50 : (c == DS.ColorSpec.agentDone ? 30 : 25))
        case .working: 80
        case .waiting: 70
        case .done: 60
        case .spinner: 40
        case .unknown: 10
        case .none: 0
        }
    }

    static func aggregate(_ items: [(glyph: DSIndicatorGlyph, label: String)]) -> (glyph: DSIndicatorGlyph, label: String) {
        items.max { rank($0.glyph) < rank($1.glyph) } ?? (.none, "")
    }

    static func aggregate(_ samples: [StatusSample]) -> StatusSample? {
        samples.max { $0.rank < $1.rank }
    }

    /// Estado de um terminal com atividade de hooks (Fatia 2): vale só para agente com o processo vivo; o resto é do processo.
    /// Linha de um worker de app: título sem o prefixo do CLI, estado do terminal (rodando, precisa de você, terminou, falhou).
    static func workerRow(_ w: Terminal, input: SidebarInput) -> SubagentRowData {
        let g = status(for: w, center: input.attention, now: input.now)
        let phase: SubagentInfo.Phase
        switch g.glyph {
        case .needsInput: phase = .needsInput
        case .done: phase = .done
        default:
            if input.finishedWorkers.contains(w.id), (w.exitCode ?? 0) == 0 { phase = .done }
            else if w.state == .running || w.state == .launching { phase = .running }
            else if w.state == .failedToStart || (w.exitCode ?? 0) != 0 { phase = .failed }
            else { phase = .done }
        }
        // O título do worker é "<agente> · <tarefa>" ("Codex 1 · books p1–4"): o nome do agente lidera, a tarefa vem ao lado.
        let split = w.title.range(of: " · ")
        let name = input.workerNames[w.id] ?? split.map { String(w.title[..<$0.lowerBound]) } ?? w.title
        let task = split.map { String(w.title[$0.upperBound...]) }
        return SubagentRowData(
            id: "worker-\(w.id.uuidString)", title: name, phase: phase, startedAt: w.startedAt ?? w.createdAt, endedAt: w.endedAt,
            subtitle: w.lastMessage, computer: input.workerComputers[w.id], worker: w.provider, workerTerminalID: w.id, task: task)
    }

    static func status(for t: Terminal, center: AttentionCenter, now: Date) -> StatusSample {
        let process = glyph(for: t)
        let base = StatusSample(glyph: process.glyph, label: process.label, rank: rank(process.glyph))
        guard t.provider.isAgent, t.state == .running, let activity = center.effectiveActivity(of: t.id, now: now),
              let info = center.statuses[t.id] else { return base }
        let unread = center.unread.contains(t.id)
        switch activity {
        case .starting: return StatusSample(glyph: .spinner, label: String(localized: "Starting…", bundle: .module), rank: 40)
        case .idle: return StatusSample(glyph: .dot(DS.ColorSpec.agentIdle), label: String(localized: "Idle", bundle: .module), rank: 20)
        case .working: return StatusSample(glyph: .working, label: String(localized: "Working", bundle: .module), rank: 80)
        case .needsInput: return StatusSample(glyph: .needsInput, label: String(localized: "Needs input", bundle: .module), rank: 100)
        case .waitingOnSubagents:
            let n = info.liveChildren
            let label = n == 1 ? String(localized: "Waiting on 1 subagent", bundle: .module) : String(localized: "Waiting on \(n) subagents", bundle: .module)
            return StatusSample(glyph: .waiting, label: label, rank: 70)
        case .done: return StatusSample(glyph: .done, label: String(localized: "Done", bundle: .module), rank: unread ? 60 : 30)
        case .failed: return StatusSample(glyph: .dot(DS.ColorSpec.agentFailed), label: String(localized: "Failed", bundle: .module), rank: 91)
        case .blocked: return StatusSample(glyph: .dot(DS.ColorSpec.agentFailed), label: String(localized: "Blocked", bundle: .module), rank: 90)
        case .interrupted: return StatusSample(glyph: .dot(DS.ColorSpec.agentInterrupted), label: String(localized: "Interrupted", bundle: .module), rank: 50)
        case .unknown: return StatusSample(glyph: .unknown, label: String(localized: "Status unavailable", bundle: .module), rank: 10)
        }
    }

    /// Na coluna de status do card o `done` vira bolinha (02 §2.6); o resto mantém o glifo.
    static func cardGlyph(_ glyph: DSIndicatorGlyph) -> DSIndicatorGlyph {
        glyph == .done ? .dot(DS.ColorSpec.agentDone) : glyph
    }

    // MARK: Construção

    static func build(_ input: SidebarInput) -> SidebarProjection {
        let snap = input.snapshot
        let query = normalize(input.query.trimmingCharacters(in: .whitespaces))
        let searching = !query.isEmpty
        let cutoff = input.now.addingTimeInterval(-Double(SidebarMetrics.idleDays) * 86400)

        let worktrees = Dictionary(uniqueKeysWithValues: snap.worktrees.map { ($0.id, $0) })
        let projectsByID = Dictionary(uniqueKeysWithValues: snap.projects.map { ($0.id, $0) })
        let openTabs = snap.tabs.filter { $0.closedAt == nil }
        let tabsBySession = Dictionary(grouping: openTabs, by: \.sessionID)
        let terminalsByTab = Dictionary(grouping: snap.terminals, by: \.tabID)

        func terminals(of session: Session) -> [Terminal] {
            (tabsBySession[session.id] ?? []).sorted { $0.sortIndex < $1.sortIndex }
                .flatMap { (terminalsByTab[$0.id] ?? []).sorted { $0.createdAt < $1.createdAt } }
        }

        func activity(_ s: Session) -> Date { s.lastActiveAt ?? s.createdAt }

        func isArchived(_ s: Session) -> Bool { s.archivedAt != nil || s.lifecycle == .archived }

        func visibleByFilters(_ s: Session) -> Bool {
            if isArchived(s) { return input.filters.archived }
            if s.kind == .checkout, !input.filters.mainCheckouts, s.id != input.selectedSession { return false }
            if !input.filters.idleOverWeek, activity(s) < cutoff, s.id != input.selectedSession { return false }
            return true
        }

        func card(_ s: Session, projectMatch: Bool) -> SessionCardData? {
            let wt = s.worktreeID.flatMap { worktrees[$0] }
            let projectName = s.projectID.flatMap { projectsByID[$0]?.name } ?? ""
            let all = terminals(of: s)
            let note = s.statusNote?.text
            let branch = wt?.branch
            let git = input.gitStatus[s.folderPath] ?? wt.flatMap { input.gitStatus[$0.path] }
            let showsGit = s.kind != .folder && s.kind != .clean && !(branch ?? "").isEmpty

            var rows = all
            if searching {
                let selfMatch = projectMatch || [s.title, branch ?? "", s.folderPath, note ?? "", projectName].contains { normalize($0).contains(query) }
                let matching = all.filter {
                    [$0.title, providerName($0.provider), $0.lastMessage ?? ""].contains { normalize($0).contains(query) }
                }
                if !selfMatch && matching.isEmpty { return nil }
                rows = selfMatch ? all : matching
            }

            let samples = all.map { status(for: $0, center: input.attention, now: input.now) }
            let agg = aggregate(samples) ?? StatusSample(glyph: .none, label: "", rank: 0)
            let anyUnread = s.unread || all.contains { input.attention.unread.contains($0.id) }
            let agents = rows.filter { $0.provider.isAgent }
            // Shells só viram linha rodando comando (título OSC) ou quando a sessão não tem agentes (03 §2.6).
            let shellRows = rows.filter { !$0.provider.isAgent && ($0.titleSource == .osc || agents.isEmpty) }
            // Workers de app (sessões separadas pedidas por `agent_spawn`) não viram linha de agente: ficam embaixo do pai.
            let parentIDs = Set(rows.map(\.id))
            let workers = rows.filter { t in t.launchSpec.workerParentTerminalID.map(parentIDs.contains) ?? false }
            let workerIDs = Set(workers.map(\.id))
            let shown = rows.filter { t in !workerIDs.contains(t.id) && (agents.contains { $0.id == t.id } || shellRows.contains { $0.id == t.id }) }
            let grouped = rows.count - shown.count - workers.count  // workers já aparecem embaixo do pai

            let agentRows = shown.map { t -> AgentRowData in
                let g = status(for: t, center: input.attention, now: input.now)
                let live = t.state == .running || t.state == .launching
                let info = t.state == .running ? input.attention.statuses[t.id] : nil
                var lead = t.lastMessage ?? t.title
                var trail: String? = live ? nil : g.label
                var since = t.startedAt ?? t.createdAt
                if let info {
                    since = info.changedAt
                    switch input.attention.effectiveActivity(of: t.id, now: input.now) {
                    // Permissão: "Wants to run: `git push origin …`" no lugar da última mensagem (06 §3.4).
                    case .needsInput: if let reason = info.reason, !reason.isEmpty { lead = reason }; trail = nil
                    case .working: trail = info.subtitle
                    case .waitingOnSubagents: trail = g.label
                    case .failed: trail = AttentionText.failureText(info.reason)
                    default: trail = nil
                    }
                }
                return AgentRowData(
                    id: t.id, sessionID: s.id, provider: t.provider, glyph: g.glyph, lead: lead, trail: trail,
                    timeText: relativeTime(since: since, now: input.now), stateLabel: g.label,
                    unread: input.attention.unread.contains(t.id), fullMessage: lead,
                    children: ((t.state == .running ? input.attention.statuses[t.id]?.children : nil).map { list in
                        list.map {
                            SubagentRowData(
                                id: $0.agentID, title: $0.displayTitle, phase: $0.phase, startedAt: $0.startedAt, endedAt: $0.endedAt,
                                subtitle: $0.subtitle, computer: input.agentComputers[$0.agentID])
                        }
                    } ?? []) + workers.filter { $0.launchSpec.workerParentTerminalID == t.id }.map { w in
                        workerRow(w, input: input)
                    }, childrenCollapsed: input.collapsedChildren.contains(t.id))
            }

            var badges: [SidebarBadge] = []
            if let wt, wt.isMain || s.kind == .checkout { badges.append(.main) }
            if let b = branch, b.isEmpty || b == "HEAD" { badges.append(.detached) }

            let line2: SidebarLine2
            if let b = branch, !b.isEmpty, s.kind != .folder, s.kind != .clean { line2 = .branch(b) }
            else { line2 = .folder(abbreviate(path: s.folderPath, home: input.home)) }

            let notStarted = all.allSatisfy { $0.state == .notStarted }
            let label = a11yLabel(title: s.title, line2: line2, badges: badges, pr: showsGit ? input.pullRequests[s.id] : nil, notStarted: notStarted, state: agg.label, unread: anyUnread, rows: agentRows.count)

            let expandedSummary = input.expandedSummaries.contains(s.id)
            var summary: [SummaryGroup]?
            if agentRows.count > SidebarMetrics.agentRowsBeforeSummary {
                var groups: [SummaryGroup] = []
                for r in agentRows {
                    if let i = groups.firstIndex(where: { $0.glyph == r.glyph }) {
                        groups[i].count += 1
                        if !groups[i].providers.contains(r.provider) { groups[i].providers.append(r.provider) }
                    } else {
                        groups.append(SummaryGroup(glyph: r.glyph, providers: [r.provider], count: 1))
                    }
                }
                summary = Array(groups.prefix(3))
            }

            return SessionCardData(
                id: s.id, title: s.title, projectID: s.projectID, kind: s.kind, badges: Array(badges.prefix(2)),
                timeText: relativeTime(since: s.lastActiveAt ?? s.createdAt, now: input.now), line2: line2,
                notStarted: notStarted, glyph: cardGlyph(agg.glyph), stateLabel: agg.label, unread: anyUnread,
                selected: s.id == input.selectedSession, note: note,
                noteDetail: s.statusNote.map { noteDetail($0, now: input.now) }, editingNote: input.editingNote == s.id,
                ahead: showsGit ? max(0, git?.ahead ?? 0) : 0, dirty: showsGit && (git?.isDirty ?? false),
                pr: showsGit ? input.pullRequests[s.id] : nil, agentRows: agentRows, groupedTerminals: grouped,
                summary: summary, summaryExpanded: expandedSummary, agentsCollapsed: input.collapsedSessions.contains(s.id),
                branch: branch, folderPath: s.folderPath, a11yLabel: label, subagent: s.subagentComputers,
                offersSubagentToggle: input.offersSubagentToggle.contains(s.id), restartToApply: input.restartPending.contains(s.id),
                computers: (input.computers[s.id] ?? []).filter { row in
                    !input.agentComputers.values.contains(row.id) && !input.workerComputers.values.contains(row.id)
                })
        }

        func sorted(_ sessions: [Session]) -> [Session] {
            switch input.sort {
            case .recent: sessions.sorted { activity($0) > activity($1) }
            case .name: sessions.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            }
        }

        func pendingRows(_ projectID: UUID?) -> [PendingRowData] {
            guard !searching else { return [] }
            return input.pending.filter { $0.projectID == projectID }.map {
                PendingRowData(id: $0.id, name: $0.name, phaseText: $0.phaseText, failed: $0.failure != nil)
            }
        }

        let hiddenByPending = Set(input.pending.compactMap(\.sessionID))
        let liveSessions = snap.sessions.filter { $0.lifecycle != .deleted && !hiddenByPending.contains($0.id) }
        var out = SidebarProjection()

        // Projetos
        var projectSections: [(section: ProjectSectionData, recent: Date, sortIndex: Int)] = []
        for p in snap.projects where p.archivedAt == nil {
            if input.hiddenProjects.contains(p.id), !input.filters.hiddenProjects, !searching { continue }
            let projectMatch = searching && normalize(p.name).contains(query)
            let mine = liveSessions.filter { $0.projectID == p.id }
            let eligible = sorted(mine.filter(visibleByFilters))
            let cards = eligible.compactMap { card($0, projectMatch: projectMatch) }
            if searching, cards.isEmpty, !projectMatch { continue }
            let collapsed = !searching && input.collapsedProjects.contains(p.id)
            let showMoreOpen = input.showMoreOpen.contains(p.id) || searching
            let visible = showMoreOpen ? cards : Array(cards.prefix(SidebarMetrics.sessionsBeforeShowMore))
            let section = ProjectSectionData(
                id: p.id, name: p.name, kind: p.kind, collapsed: collapsed, sessionCount: cards.count,
                pending: pendingRows(p.id), sessions: visible, hiddenCount: cards.count - visible.count,
                showMoreExpanded: showMoreOpen && cards.count > SidebarMetrics.sessionsBeforeShowMore,
                // Só arquivadas (filtro desligado) contam como "sem sessões": o projeto oferece começar uma, não "nenhum resultado".
                hasNoSessions: mine.allSatisfy { isArchived($0) && !input.filters.archived } && input.pending.allSatisfy { $0.projectID != p.id })
            let recent = mine.map(activity).max() ?? p.createdAt
            projectSections.append((section, recent, p.sortIndex))
        }
        switch input.sort {
        case .recent:
            projectSections.sort { $0.recent != $1.recent ? $0.recent > $1.recent : $0.sortIndex < $1.sortIndex }
        case .name:
            projectSections.sort { $0.section.name.localizedCaseInsensitiveCompare($1.section.name) == .orderedAscending }
        }
        out.projects = projectSections.map(\.section)

        // Sessões limpas
        let clean = sorted(liveSessions.filter { $0.kind == .clean && visibleByFilters($0) })
        out.cleanSessions = clean.compactMap { card($0, projectMatch: false) }
        out.cleanPending = pendingRows(nil)

        // Vazio
        // Só arquivadas não contam como "algo guardado": com tudo arquivado a sidebar mostra o começo, não "nenhum resultado".
        let activeProjects = Set(snap.projects.filter { $0.archivedAt == nil }.map(\.id))
        let archived = liveSessions.filter(isArchived)
        let nothingStored = activeProjects.isEmpty && liveSessions.count == archived.count && input.pending.isEmpty
        if !input.filters.archived {
            out.archivedHidden = archived.filter { $0.projectID.map(activeProjects.contains) ?? true }.count
        }
        let nothingShown = out.projects.allSatisfy { $0.sessions.isEmpty && $0.pending.isEmpty } && !out.showSessionsSection
        if nothingStored {
            out.empty = .workspace
        } else if searching, out.projects.isEmpty, !out.showSessionsSection {
            out.empty = .searchNoResults
        } else if !searching, nothingShown, !liveSessions.isEmpty, !out.projects.contains(where: { $0.hasNoSessions }) {
            out.empty = .filtersNoResults
        }

        // Ordem navegável
        for p in out.projects {
            out.items.append(.project(p.id))
            guard !p.collapsed else { continue }
            for r in p.pending { out.items.append(.pending(r.id)) }
            for c in p.sessions { appendCard(c, to: &out) }
            if p.hiddenCount > 0 || p.showMoreExpanded { out.items.append(.showMore(p.id)) }
        }
        for r in out.cleanPending { out.items.append(.pending(r.id)) }
        for c in out.cleanSessions { appendCard(c, to: &out) }
        return out
    }

    private static func appendCard(_ c: SessionCardData, to out: inout SidebarProjection) {
        out.items.append(.session(c.id))
        out.sessionOrder.append(c.id)
        guard !c.agentsCollapsed, c.summary == nil || c.summaryExpanded else { return }
        for r in c.agentRows { out.items.append(.agent(session: c.id, terminal: r.id)) }
    }

    /// "user · 3h" / "Claude · now" no hover da nota (AC-208).
    static func noteDetail(_ note: StatusNote, now: Date) -> String {
        let author = note.author == "user" ? String(localized: "You", bundle: .module) : note.author
        return "\(author) · \(relativeTime(since: note.at, now: now))"
    }

    private static func a11yLabel(title: String, line2: SidebarLine2, badges: [SidebarBadge], pr: PullRequestChipModel?, notStarted: Bool, state: String, unread: Bool, rows: Int) -> String {
        var parts = [title]
        switch line2 {
        case .branch(let b): parts.append(String(localized: "branch \(b)", bundle: .module))
        case .folder(let f): parts.append(String(localized: "folder \(f)", bundle: .module))
        case .missingFolder: parts.append(String(localized: "Folder not found", bundle: .module))
        }
        parts.append(contentsOf: badges.map(\.title))
        if let pr { parts.append(PullRequestText.summary(pr)) }
        if notStarted { parts.append(String(localized: "Not started", bundle: .module)) } else if !state.isEmpty { parts.append(state) }
        if unread { parts.append(String(localized: "Unread", bundle: .module)) }
        if rows > 0 { parts.append(String(localized: "with \(rows) terminals", bundle: .module)) }
        return parts.joined(separator: ", ")
    }
}
