import RackyProtocol
import RackyStore
import Foundation

// Atenção (01 §5.12, 06 §3.5–§3.6): o que pede ação do usuário. Tipos puros, sem UI e sem I/O.

public enum AttentionKind: String, Sendable, Codable, CaseIterable {
    case helpRequest, needsInput, failed, dockerStopped, childBlocked, done, batchDone

    /// Prioridade de 01 §5.12: 1 (mais alta) a 4.
    public var priority: Int {
        switch self {
        case .helpRequest: 1
        case .needsInput, .failed, .dockerStopped, .childBlocked: 2
        case .done, .batchDone: 3
        }
    }

    /// O badge do Dock e o item da barra de menus contam só prioridade 1–2.
    public var countsForBadge: Bool { priority <= 2 }
}

/// Quem é o terminal para fins de título e navegação: o que a notificação e o Inbox mostram.
public struct AttentionContext: Sendable, Equatable {
    public var sessionID: UUID
    public var sessionTitle: String
    /// `nil` em sessão limpa: o título fica só `<session> — …`.
    public var projectName: String?
    public var provider: TerminalProvider

    public init(sessionID: UUID, sessionTitle: String, projectName: String? = nil, provider: TerminalProvider) {
        self.sessionID = sessionID; self.sessionTitle = sessionTitle; self.projectName = projectName; self.provider = provider
    }

    /// Nome curto do agente nos títulos ("acme-platform / shop-pr-checkout — Claude finished", 06 §3.5).
    public var providerName: String {
        switch provider {
        case .claude: "Claude"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        case .shell: "Terminal"
        case .custom: "Command"
        }
    }

    /// Quem é cada terminal vivo do snapshot (sessão, projeto, agente).
    public static func contexts(in snapshot: StoreSnapshot) -> [UUID: AttentionContext] {
        let tabSession = Dictionary(snapshot.tabs.map { ($0.id, $0.sessionID) }, uniquingKeysWith: { a, _ in a })
        let sessions = Dictionary(snapshot.sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let projects = Dictionary(snapshot.projects.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        var out: [UUID: AttentionContext] = [:]
        for t in snapshot.terminals where t.deletedAt == nil {
            guard let sid = tabSession[t.tabID], let session = sessions[sid] else { continue }
            out[t.id] = AttentionContext(
                sessionID: sid, sessionTitle: session.title, projectName: session.projectID.flatMap { projects[$0] }, provider: t.provider)
        }
        return out
    }

    /// `"{project} / {session}"`, ou só a sessão (06 §3.5).
    public var place: String {
        guard let projectName, !projectName.isEmpty else { return sessionTitle }
        return "\(projectName) / \(sessionTitle)"
    }
}

/// Um subagente do agente (hooks `SubagentStart`/`SubagentStop`, com ou sem computador): a linha filha do card da sessão.
public struct SubagentInfo: Sendable, Equatable, Identifiable {
    public enum Phase: Sendable, Equatable { case running, needsInput, done, failed }

    public var id: String { agentID }
    public var agentID: String
    public var agentType: String?
    /// Título da tarefa (descrição do spawn); sem ele, o tipo do subagente.
    public var title: String?
    public var phase: Phase
    public var startedAt: Date
    public var endedAt: Date?
    /// Última nota do diário ou ferramenta em uso.
    public var subtitle: String?

    public init(
        agentID: String, agentType: String? = nil, title: String? = nil, phase: Phase, startedAt: Date, endedAt: Date? = nil, subtitle: String? = nil
    ) {
        self.agentID = agentID; self.agentType = agentType; self.title = title; self.phase = phase; self.startedAt = startedAt
        self.endedAt = endedAt; self.subtitle = subtitle
    }

    public var displayTitle: String { title ?? agentType ?? "Subagent" }
}

/// Estado de atividade de um terminal de agente, como a UI o enxerga (derivado de `agent_run`).
public struct TerminalActivity: Sendable, Equatable {
    public var terminalID: UUID
    public var runID: UUID?
    public var activity: AgentActivity
    /// Última mensagem do agente, já saneada (06 §3.4).
    public var lastMessage: String?
    public var reason: String?
    public var subtitle: String?
    public var liveChildren: Int
    public var estimated: Bool
    /// Quando `activity` mudou pela última vez (ordem de espera e tempo relativo).
    public var changedAt: Date
    /// Todos os subagentes vistos nos hooks (em ordem de início).
    public var children: [SubagentInfo] = []

    public init(
        terminalID: UUID, runID: UUID? = nil, activity: AgentActivity, lastMessage: String? = nil, reason: String? = nil,
        subtitle: String? = nil, liveChildren: Int = 0, estimated: Bool = false, changedAt: Date = Date(), children: [SubagentInfo] = []
    ) {
        self.children = children
        self.terminalID = terminalID; self.runID = runID; self.activity = activity; self.lastMessage = lastMessage
        self.reason = reason; self.subtitle = subtitle; self.liveChildren = liveChildren; self.estimated = estimated
        self.changedAt = changedAt
    }
}

/// Item da fila de atenção (01 §5.12).
public struct AttentionItem: Identifiable, Sendable, Equatable {
    public var id: String
    public var kind: AttentionKind
    public var sessionID: UUID
    public var terminalID: UUID
    public var runID: UUID?
    public var title: String
    public var body: String
    public var createdAt: Date
    public var seenAt: Date?
    public var resolvedAt: Date?
    public var systemNotified: Bool
    /// `batchDone`: o lote que terminou (o clique abre o painel `Batch`).
    public var batchID: String?

    public var priority: Int { kind.priority }
    public var isResolved: Bool { resolvedAt != nil }

    public init(
        id: String, kind: AttentionKind, sessionID: UUID, terminalID: UUID, runID: UUID? = nil, title: String, body: String,
        createdAt: Date, seenAt: Date? = nil, resolvedAt: Date? = nil, systemNotified: Bool = false, batchID: String? = nil
    ) {
        self.batchID = batchID
        self.id = id; self.kind = kind; self.sessionID = sessionID; self.terminalID = terminalID; self.runID = runID
        self.title = title; self.body = body; self.createdAt = createdAt; self.seenAt = seenAt; self.resolvedAt = resolvedAt
        self.systemNotified = systemNotified
    }
}

/// Texto de apoio ("Exited with code 1") a partir do motivo que o redutor guarda ("exited with 1").
public enum AttentionText {
    public static func failureText(_ reason: String?) -> String {
        guard let reason, !reason.isEmpty else { return "Failed" }
        let lower = reason.lowercased()
        if lower.hasPrefix("exited with "), let code = Int(lower.dropFirst("exited with ".count)) { return "Exited with code \(code)" }
        return reason
    }

    public static func statusWord(_ kind: AttentionKind) -> String {
        switch kind {
        case .needsInput, .helpRequest: "needs input"
        case .failed, .childBlocked: "failed"
        case .done, .batchDone: "finished"
        case .dockerStopped: "needs Docker"
        }
    }

    /// `"{project} / {session} — {Agent} {status}"` (06 §3.5).
    public static func title(_ context: AttentionContext, kind: AttentionKind) -> String {
        "\(context.place) — \(context.providerName) \(statusWord(kind))"
    }
}
