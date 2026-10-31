import RackyProtocol
import RackyStore
import CryptoKit
import Foundation

// Redutor de eventos de hook -> estado de atividade do agente (01 §6.3, 06 §3.1 e §3.3). Funções puras: a mesma
// sequência de eventos, em ordem de ocorrência, sempre produz o mesmo estado. Eventos fora de sequência são tratados
// reordenando por `atNs` e refazendo o estado (`ActivityReducer.fold`).

/// Eventos sintéticos gravados em `agent_event` para que o estado seja reconstruível só com a tabela.
public enum ActivitySyntheticEvent {
    /// `reason` = código de saída. Origem: evento `exit` do daemon (06 §3.3).
    public static let processExit = "ProcessExit"
    /// O PTY se perdeu (reboot ou crash do daemon): `interrupted`.
    public static let ptyLost = "PtyLost"
}

/// Posição de um evento na ordem de ocorrência: tempo do helper e, em empate, ordem de chegada.
public struct ActivityOrderKey: Comparable, Sendable, Equatable {
    public var atNs: Int64
    public var arrival: Int
    public init(atNs: Int64, arrival: Int) { self.atNs = atNs; self.arrival = arrival }
    public static func < (a: Self, b: Self) -> Bool { (a.atNs, a.arrival) < (b.atNs, b.arrival) }
}

public struct ActivityEvent: Sendable, Equatable {
    public var name: String
    public var payload: ReducedHookPayload
    public var atNs: Int64
    public init(name: String, payload: ReducedHookPayload = ReducedHookPayload(), atNs: Int64) {
        self.name = name; self.payload = payload; self.atNs = atNs
    }
}

public struct PendingInput: Sendable, Equatable {
    public var kind: NeedsInputKind
    /// "Wants to run: `git push origin …`" (06 §3.4) ou a mensagem da notificação.
    public var summary: String?
}

public struct ChildActivity: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case starting, working, done }
    public var agentID: String
    public var agentType: String?
    public var phase: Phase
    /// Criado por um evento de ferramenta sem `SubagentStart` visto: existe, mas não segura o pai em `waitingOnSubagents`
    /// (se o `SubagentStop` se perdeu, o pai não pode ficar esperando para sempre).
    public var implicit: Bool
    public var startedAtNs: Int64
    public var lastEventAtNs: Int64
    public var endedAtNs: Int64?
    public var lastMessage: String?
    public var subtitle: String?
    /// Descrição do spawn (`Agent` com `description`), emparelhada com o início do subagente.
    public var title: String?

    public var isLive: Bool { !implicit && phase != .done }
}

public struct ActivityState: Sendable, Equatable {
    public enum Base: Sendable, Equatable { case starting, idle, working, waiting, done, failed, interrupted, unknown }

    public var base: Base = .starting
    /// Motivo de `failed` ("exited with 1", erro do `StopFailure`) ou de `unknown`.
    public var reason: String?
    /// Pedidos de input abertos, por agente (`""` = agente principal, senão o `agent_id` do filho).
    public var pending: [String: PendingInput] = [:]
    public var children: [String: ChildActivity] = [:]
    /// Descrições dos spawns (`PreToolUse` de `Agent`/`Task` do agente principal) ainda sem `SubagentStart`: o primeiro início leva a primeira.
    public var pendingTitles: [String] = []
    public var subtitle: String?
    public var lastMessage: String?
    public var nativeSessionID: String?
    public var transcriptPath: String?
    public var cwd: String?
    public var sessionEndReason: String?
    public var startedAtNs: Int64?
    public var lastEventAtNs: Int64?
    public var endedAtNs: Int64?
    /// Flag, não estado (06 §3.1): OpenCode, shell e Codex por rollout. Hooks de verdade nunca marcam.
    public var estimated = false

    public init() {}

    public var liveChildCount: Int { children.values.filter(\.isLive).count }

    /// Subagentes para a sidebar (os implícitos, vistos só por eventos de ferramenta, entram também), na ordem de início.
    public var subagentInfos: [SubagentInfo] {
        func date(_ ns: Int64) -> Date { Date(timeIntervalSince1970: Double(ns) / 1_000_000_000) }
        // Subagentes internos do Claude Code (sem spawn pela ferramenta Agent/Task, sem tipo e sem título — ex. resumos e
        // títulos que o CLI dispara sozinho) não são do usuário: não viram linha na sidebar.
        let visible = children.values.filter { $0.title != nil || $0.agentType != nil }
        return visible.sorted { ($0.startedAtNs, $0.agentID) < ($1.startedAtNs, $1.agentID) }.map { c in
            let phase: SubagentInfo.Phase
            if c.phase == .done { phase = .done } else if pending[c.agentID] != nil { phase = .needsInput } else { phase = .running }
            return SubagentInfo(
                agentID: c.agentID, agentType: c.agentType, title: c.title, phase: phase, startedAt: date(c.startedAtNs),
                endedAt: c.endedAtNs.map(date), subtitle: c.subtitle ?? c.lastMessage.map { String($0.prefix(120)) })
        }
    }

    /// Pedido pendente que define o `needsInput` visível: permissão antes de pergunta antes de outros.
    public var visiblePending: PendingInput? {
        let rank: (NeedsInputKind) -> Int = { $0 == .permission ? 0 : $0 == .question ? 1 : 2 }
        return pending.sorted { a, b in
            let ra = rank(a.value.kind), rb = rank(b.value.kind)
            return ra != rb ? ra < rb : a.key < b.key
        }.first?.value
    }

    public var activity: AgentActivity {
        switch base {
        case .failed: return .failed
        case .interrupted: return .interrupted
        default: break
        }
        if let p = visiblePending { return .needsInput(p.kind) }
        switch base {
        case .starting: return .starting
        case .idle: return .idle
        case .working: return .working
        case .waiting: return .waitingOnSubagents
        case .done: return .done
        case .unknown: return .unknown
        case .failed, .interrupted: return .failed  // inalcançável: tratado acima
        }
    }

    /// Texto de apoio do estado: pedido de permissão, motivo da falha.
    public var statusReason: String? {
        switch activity {
        case .failed, .unknown: return reason
        case .needsInput: return visiblePending?.summary
        default: return nil
        }
    }
}

public enum ActivityReducer {
    /// Ferramenta de pergunta ao usuário (06 §3.3: "AskUserQuestion, verificar nome").
    public static let questionTools: Set<String> = ["AskUserQuestion"]

    public static func fold(_ events: [ActivityEvent], from initial: ActivityState = ActivityState()) -> ActivityState {
        events.reduce(initial) { reduce($0, $1) }
    }

    /// Ordena por ocorrência (estável: empates mantêm a ordem de chegada) e refaz o estado.
    public static func foldSorted(_ events: [ActivityEvent]) -> ActivityState {
        let ordered = events.enumerated().sorted {
            ActivityOrderKey(atNs: $0.element.atNs, arrival: $0.offset) < ActivityOrderKey(atNs: $1.element.atNs, arrival: $1.offset)
        }.map(\.element)
        return fold(ordered)
    }

    public static func reduce(_ state: ActivityState, _ event: ActivityEvent) -> ActivityState {
        var s = state
        if s.startedAtNs == nil { s.startedAtNs = event.atNs }
        s.lastEventAtNs = max(s.lastEventAtNs ?? event.atNs, event.atNs)
        let p = event.payload
        absorbIdentity(&s, p, event.name)

        switch event.name {
        case ActivitySyntheticEvent.processExit:
            processExit(&s, code: Int(p.reason ?? "") ?? 0, atNs: event.atNs)
        case ActivitySyntheticEvent.ptyLost:
            if [.starting, .idle, .working, .waiting].contains(s.base) || !s.pending.isEmpty {
                s.base = .interrupted; s.pending = [:]; s.endedAtNs = event.atNs
                endChildren(&s, atNs: event.atNs)
            }
        default:
            guard let name = HookEventName(rawValue: event.name) else { return s }  // evento futuro: só registrado
            if s.base == .interrupted { return s }  // processo morto: eventos atrasados não ressuscitam
            hook(&s, name, p, atNs: event.atNs)
        }
        return s
    }

    // MARK: - Hooks

    private static func absorbIdentity(_ s: inout ActivityState, _ p: ReducedHookPayload, _ name: String) {
        // Eventos de filho trazem o `session_id` do pai; só o principal define identidade.
        guard p.agentID == nil || name == HookEventName.sessionStart.rawValue else { return }
        if let id = p.sessionID { s.nativeSessionID = id }
        if let t = p.transcriptPath { s.transcriptPath = t }
        if let c = p.cwd { s.cwd = c }
    }

    private static func hook(_ s: inout ActivityState, _ name: HookEventName, _ p: ReducedHookPayload, atNs: Int64) {
        let childID = p.agentID
        switch name {
        case .sessionStart:
            if [.starting, .unknown, .idle].contains(s.base) { s.base = .idle; s.reason = nil }

        case .userPromptSubmit:
            s.base = .working; s.reason = nil; s.pending = [:]; s.subtitle = nil

        case .preToolUse:
            if let child = childID {
                touchChild(&s, child, p, atNs: atNs, working: true)
                s.children[child]?.subtitle = toolSubtitle(p.toolName, p.toolTarget)
                s.pending[child] = nil
            } else {
                s.pending[""] = nil
                if ![.waiting, .working].contains(s.base) { s.base = .working; s.reason = nil }
                s.subtitle = toolSubtitle(p.toolName, p.toolTarget)
                if let tool = p.toolName, tool == "Agent" || tool == "Task", let title = p.toolTarget, !title.isEmpty {
                    s.pendingTitles.append(title)
                    if s.pendingTitles.count > 16 { s.pendingTitles.removeFirst() }
                }
                if let tool = p.toolName, questionTools.contains(tool) {
                    s.pending[""] = PendingInput(kind: .question, summary: p.toolTarget)
                }
            }

        case .postToolUse, .postToolUseFailure:
            if let child = childID {
                touchChild(&s, child, p, atNs: atNs, working: true)
                s.pending[child] = nil
            } else {
                s.pending[""] = nil
                if [.starting, .idle, .unknown].contains(s.base) { s.base = .working; s.reason = nil }
                if name == .postToolUse, p.toolName == "TaskStop" { stopChild(&s, target: p.toolTarget, atNs: atNs) }
            }

        case .permissionRequest:
            let key = childID ?? ""
            if let child = childID { touchChild(&s, child, p, atNs: atNs, working: true) }
            else if [.starting, .idle, .unknown].contains(s.base) { s.base = .working; s.reason = nil }
            s.pending[key] = PendingInput(kind: .permission, summary: permissionSummary(p.toolName, p.toolTarget))

        case .notification:
            switch p.notificationType {
            case "permission_prompt":
                s.pending[""] = PendingInput(kind: .permission, summary: p.message)
            case "idle_prompt":
                // Sem turno ativo mantém o estado (`done`); com turno ativo é o agente esperando o usuário.
                if s.base == .working { s.pending[""] = PendingInput(kind: .other, summary: p.message) }
            default:
                s.pending[""] = PendingInput(kind: .other, summary: p.message)
            }

        case .stop:
            if childID != nil { return }  // `Stop` de filho não existe: o filho termina com `SubagentStop`
            s.pending[""] = nil
            if let m = p.lastAssistantMessage, !m.isEmpty { s.lastMessage = m }
            s.subtitle = nil; s.reason = nil
            s.base = s.liveChildCount > 0 ? .waiting : .done

        case .stopFailure:
            s.pending[""] = nil
            s.base = .failed
            s.reason = p.error ?? p.reason ?? p.message ?? "Turn failed"
            s.subtitle = nil

        case .subagentStart:
            guard let child = childID else { return }
            var c = s.children[child] ?? ChildActivity(
                agentID: child, agentType: p.agentType, phase: .starting, implicit: false, startedAtNs: atNs, lastEventAtNs: atNs)
            c.implicit = false
            if c.title == nil, !s.pendingTitles.isEmpty { c.title = s.pendingTitles.removeFirst() }
            if c.phase == .done && c.endedAtNs != nil && atNs > (c.endedAtNs ?? 0) { c.phase = .starting; c.endedAtNs = nil }
            c.agentType = p.agentType ?? c.agentType
            c.lastEventAtNs = max(c.lastEventAtNs, atNs)
            s.children[child] = c
            if s.base == .done { s.base = .waiting }

        case .subagentStop:
            guard let child = childID else { return }
            var c = s.children[child] ?? ChildActivity(
                agentID: child, agentType: p.agentType, phase: .done, implicit: false, startedAtNs: atNs, lastEventAtNs: atNs)
            c.phase = .done; c.implicit = false; c.endedAtNs = atNs; c.agentType = p.agentType ?? c.agentType
            c.lastEventAtNs = max(c.lastEventAtNs, atNs)
            if let m = p.lastAssistantMessage, !m.isEmpty { c.lastMessage = m }
            c.subtitle = nil
            s.children[child] = c
            s.pending[child] = nil
            if s.base == .waiting, s.liveChildCount == 0 { s.base = .done }

        case .sessionEnd:
            s.sessionEndReason = p.reason ?? "other"
            endChildren(&s, atNs: atNs)
            if s.base == .waiting { s.base = .done }
        }
    }

    private static func processExit(_ s: inout ActivityState, code: Int, atNs: Int64) {
        s.endedAtNs = atNs
        s.pending = [:]
        endChildren(&s, atNs: atNs)
        if code != 0 {
            if s.base != .failed { s.base = .failed; s.reason = "exited with \(code)" }
        } else if s.base == .starting {
            s.base = .unknown
            s.reason = "The agent exited without reporting any activity"
        } else if s.base == .waiting {
            s.base = .done
        }
    }

    private static func touchChild(_ s: inout ActivityState, _ id: String, _ p: ReducedHookPayload, atNs: Int64, working: Bool) {
        var c = s.children[id] ?? ChildActivity(
            agentID: id, agentType: p.agentType, phase: .working, implicit: true, startedAtNs: atNs, lastEventAtNs: atNs)
        c.lastEventAtNs = max(c.lastEventAtNs, atNs)
        c.agentType = p.agentType ?? c.agentType
        if working, c.phase != .done { c.phase = .working }
        s.children[id] = c
    }

    /// O agente principal parou um subagente em segundo plano (`TaskStop`): o Claude Code não manda `SubagentStop` nesse caso,
    /// então o filho termina aqui. Sem o id no evento (gravado antes de o Racky ler `task_id`), só termina se havia exatamente um
    /// filho vivo: era ele.
    private static func stopChild(_ s: inout ActivityState, target: String?, atNs: Int64) {
        let id: String?
        if let target, s.children[target] != nil {
            id = target
        } else if target == nil {
            let live = s.children.values.filter { $0.phase != .done }
            id = live.count == 1 ? live.first?.agentID : nil
        } else {
            id = nil
        }
        guard let id, var c = s.children[id], c.phase != .done else { return }
        c.phase = .done; c.endedAtNs = atNs; c.subtitle = nil
        s.children[id] = c
        s.pending[id] = nil
        if s.base == .waiting, s.liveChildCount == 0 { s.base = .done }
    }

    private static func endChildren(_ s: inout ActivityState, atNs: Int64) {
        for (id, var c) in s.children where c.phase != .done {
            c.phase = .done; c.endedAtNs = atNs
            s.children[id] = c
        }
    }

    // MARK: - Texto de apoio

    /// "Running Bash", "Editing x.swift" (06 §3.3).
    public static func toolSubtitle(_ tool: String?, _ target: String?) -> String? {
        guard let tool, !tool.isEmpty else { return nil }
        switch tool {
        case "Bash": return "Running Bash"
        case "Edit", "Write", "MultiEdit", "NotebookEdit": return target.map { "Editing \($0)" } ?? "Editing a file"
        case "Read": return target.map { "Reading \($0)" } ?? "Reading a file"
        case "Grep", "Glob": return "Searching"
        case "Agent", "Task": return "Running a subagent"
        default: return "Using \(tool)"
        }
    }

    /// "Wants to run: `git push origin …`" (06 §3.4).
    public static func permissionSummary(_ tool: String?, _ target: String?) -> String? {
        guard let tool, !tool.isEmpty else { return nil }
        switch tool {
        case "Bash": return target.map { "Wants to run: `\($0)`" } ?? "Wants to run a command"
        case "Edit", "Write", "MultiEdit", "NotebookEdit": return target.map { "Wants to edit: `\($0)`" } ?? "Wants to edit a file"
        case "Read": return target.map { "Wants to read: `\($0)`" } ?? "Wants to read a file"
        default: return target.map { "Wants to use \(tool): `\($0)`" } ?? "Wants to use \(tool)"
        }
    }
}

// MARK: - Projeção para `agent_run`

public enum ActivityProjector {
    /// UUID determinístico de um filho a partir do pai e do `agent_id`: reaplicar os eventos nunca duplica linhas.
    public static func childRunID(parent: UUID, agentID: String) -> UUID {
        var hasher = SHA256()
        withUnsafeBytes(of: parent.uuid) { hasher.update(bufferPointer: $0) }
        hasher.update(data: Data(agentID.utf8))
        var b = Array(hasher.finalize().prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    private static func date(ns: Int64?) -> Date? { ns.map { Date(timeIntervalSince1970: Double($0) / 1_000_000_000) } }

    /// Linhas de `agent_run` (principal + filhos nativos) e a atualização do terminal.
    /// `mainKind`: `.appWorkerLight` no terminal de um worker de app (spec subagent-harness). O `parent_run_id` fica vazio de propósito: as consultas por
    /// terminal (`latestMainRuns`, `agentRuns(terminalID:)`, reconcile) só enxergam execuções sem pai; o vínculo com o pai está em `orchestration_child`.
    public static func projection(
        runID: UUID, terminalID: UUID?, provider: HookProvider, state s: ActivityState, mainKind: AgentRunKind = .main
    ) -> ActivityProjection {
        let harness: TerminalProvider = provider == .claude ? .claude : .codex
        let main = AgentRun(
            id: runID, terminalID: terminalID, rootRunID: runID, kind: mainKind, harness: harness,
            providerSessionID: s.nativeSessionID, activity: s.activity, estimated: s.estimated,
            statusReason: s.statusReason, subtitle: s.subtitle, startedAt: date(ns: s.startedAtNs) ?? Date(timeIntervalSince1970: 0),
            lastEventAt: date(ns: s.lastEventAtNs), endedAt: date(ns: s.endedAtNs))
        var runs = [main]
        for c in s.children.values.sorted(by: { ($0.startedAtNs, $0.agentID) < ($1.startedAtNs, $1.agentID) }) {
            let activity: AgentActivity
            if let p = s.pending[c.agentID] { activity = .needsInput(p.kind) }
            else {
                switch c.phase {
                case .starting: activity = .starting
                case .working: activity = .working
                case .done: activity = .done
                }
            }
            runs.append(AgentRun(
                id: childRunID(parent: runID, agentID: c.agentID), terminalID: terminalID, parentRunID: runID, rootRunID: runID,
                kind: .nativeSubagent, harness: harness, agentType: c.agentType, providerSessionID: s.nativeSessionID,
                providerAgentID: c.agentID, activity: activity, estimated: s.estimated,
                statusReason: s.pending[c.agentID]?.summary, subtitle: c.subtitle ?? c.lastMessage.map { String($0.prefix(120)) },
                startedAt: date(ns: c.startedAtNs) ?? Date(timeIntervalSince1970: 0), lastEventAt: date(ns: c.lastEventAtNs),
                endedAt: date(ns: c.endedAtNs)))
        }
        let update = terminalID.map {
            TerminalActivityUpdate(terminalID: $0, lastMessage: s.lastMessage, nativeConversationID: s.nativeSessionID)
        }
        return ActivityProjection(runs: runs, terminalUpdate: update, guardRunID: runID)
    }
}

// MARK: - Agregação e tempo

public enum SessionActivity {
    /// Pior estado vence (01 §6.3). `unseenDone` marca os `done` ainda não vistos (negrito).
    public static func aggregate(_ runs: [AgentRun], unseenDone: Set<UUID> = []) -> AgentActivity? {
        AgentActivityMachine.aggregate(runs.map { .init($0.activity, unseen: unseenDone.contains($0.id)) })
    }
}

public enum ActivityTimeouts {
    /// `done` visto e sem atividade por 30 min vira `idle` (06 §3.1).
    public static let idleAfterDone: TimeInterval = 30 * 60

    public static func applyingIdleTimeout(_ run: AgentRun, seen: Bool, now: Date) -> AgentRun {
        guard run.activity == .done, seen, let last = run.lastEventAt, now.timeIntervalSince(last) >= idleAfterDone else { return run }
        var r = run
        r.activity = .idle
        return r
    }
}
