import Foundation
import Observation

/// Uma linha da aba Computers e da página Computers (07 CS-403, CS-440).
public struct ComputerRow: Identifiable, Sendable, Equatable {
    public var id: String { snapshot.name }
    public var snapshot: ViewerSnapshot
    /// JPEG da miniatura (≤ 1 fps); decodificado fora do main thread pela UI (audit/09 N13).
    public var thumbnail: Data?
    public var sessionTitle: String?
    public var owner: String?
    public var lastActivity: Date
    public var needsYou: Bool { snapshot.help != nil }

    public init(snapshot: ViewerSnapshot, thumbnail: Data? = nil, sessionTitle: String? = nil, owner: String? = nil, lastActivity: Date = Date()) {
        self.snapshot = snapshot; self.thumbnail = thumbnail; self.sessionTitle = sessionTitle; self.owner = owner; self.lastActivity = lastActivity
    }
}

/// Item do Inbox para pedidos de ajuda de computador (03 §9.1): um por `request_id`.
public struct InboxItem: Identifiable, Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case needsYou, resolved, declined, cancelled }
    public var id: String
    public var computer: String
    public var summary: HelpSummary
    public var createdAt: Date
    public var read = false
    public var phase: Phase = .needsYou
    /// Linha 2 do item: `<computer> needs you · CAPTCHA on <host>`.
    public var message: String { "\(computer) needs you · \(summary.headline)" }

    public init(id: String, computer: String, summary: HelpSummary, createdAt: Date, read: Bool = false, phase: Phase = .needsYou) {
        self.id = id; self.computer = computer; self.summary = summary; self.createdAt = createdAt; self.read = read; self.phase = phase
    }
}

/// Texto da notificação do macOS para um pedido de ajuda (CS-433): sem conteúdo de página nem dado sensível.
public struct HelpNotificationContent: Sendable, Equatable {
    public var title: String
    public var body: String
    public var threadID: String

    public static func make(session: String?, computer: String, summary: HelpSummary) -> HelpNotificationContent {
        HelpNotificationContent(
            title: session.map { "\($0) — \(computer) needs you" } ?? "\(computer) needs you", body: summary.headline, threadID: session ?? computer)
    }
}

/// Diretório dos computadores da UI: linhas ordenadas ("precisa de você" e depois atividade recente), Inbox de pedidos de ajuda,
/// contagem para o Dock e notificação uma vez por `request_id`. O Docker e o hub ficam atrás de `ManagedComputer`.
@MainActor
@Observable
public final class ComputersModel {
    public private(set) var rows: [ComputerRow] = []
    public private(set) var inbox: [InboxItem] = []
    /// Lotes das sessões abertas (painel `Batch`, T3-07): reagregados do scheduler a cada poucos segundos.
    public private(set) var batches: [BatchSummary] = []
    /// Pedidos de computador esperando o usuário no modo Ask (F12): card no pane, item no Inbox e notificação.
    public private(set) var approvals: [ComputerApprovalRequest] = []
    /// Qual sessão do app é dona de cada computador (linha filha da sidebar).
    public var sessionIDs: [String: UUID] = [:]
    /// Agente pai de cada computador (`Claude`, `Codex`, `OpenCode`).
    public var agentNames: [String: String] = [:]
    /// Computador de cada subagente nativo (`agent_id` dos hooks -> nome), ligado quando o filho chama a primeira ferramenta.
    public var agentComputers: [String: String] = [:]
    /// Workers de app (`agent_spawn`): computador de cada terminal de worker e o nome do agente de cada computador ("Codex 1").
    public var workerComputers: [UUID: String] = [:]
    public var computerAgentNames: [String: String] = [:]
    /// Terminais de workers que já terminaram (resultado entregue e computador solto), mesmo com o CLI ainda aberto.
    public private(set) var finishedWorkers: Set<UUID> = []

    /// Estado dos workers vindo do orquestrador (sobrevive a reabrir o app: o Store guarda terminal, computador e fim).
    public func setWorkers(_ list: [AppWorkerSummary]) {
        for worker in list {
            if let computer = worker.computer {
                if workerComputers[worker.terminalID] != computer { workerComputers[worker.terminalID] = computer }
                if computerAgentNames[computer] != worker.agentName { computerAgentNames[computer] = worker.agentName }
            }
        }
        let finished = Set(list.filter { $0.state.isFinal }.map(\.terminalID))
        if finished != finishedWorkers { finishedWorkers = finished }
    }
    /// Pedidos de ajuda abertos e pedidos de computador sem decisão: o número do badge do Dock (03 §9.3).
    public var attentionCount: Int { inbox.filter { $0.phase == .needsYou }.count + approvals.count }
    public var sessionTitle: (String) -> String? = { _ in nil }
    /// Decisão do usuário sobre um pedido (o app liga ao `ComputerApprovalCenter`).
    @ObservationIgnored public var decide: (String, ComputerApprovalDecision) -> Void = { _, _ in }
    /// F29: o proxy escolhido no card do pedido (`nil` = Direct).
    @ObservationIgnored public var chooseProxy: (String, String?) -> Void = { _, _ in }
    @ObservationIgnored public var chooseLeftovers: (String, LeftoversPolicy) -> Void = { _, _ in }
    @ObservationIgnored public var onApprovalRequested: (ComputerApprovalRequest) -> Void = { _ in }
    private var announcedApprovals: Set<String> = []
    @ObservationIgnored public var onHelpRequested: (InboxItem, HelpNotificationContent) -> Void = { _, _ in }
    @ObservationIgnored public var onAttentionChange: (Int) -> Void = { _ in }

    private var computers: [String: ManagedComputer] = [:]
    private var activity: [String: Date] = [:]
    private var notified: Set<String> = []
    private var thumbnails: [String: (data: Data, at: Date)] = [:]
    private var thumbnailInFlight: Set<String> = []

    public init() {}

    public func computer(named name: String) -> ManagedComputer? { computers[name] }

    public func setBatches(_ list: [BatchSummary]) { if list != batches { batches = list } }

    /// Lista atual de pedidos abertos do `ComputerApprovalCenter`; cada pedido novo gera a notificação uma vez.
    public func setApprovals(_ requests: [ComputerApprovalRequest]) {
        approvals = requests
        for request in requests where announcedApprovals.insert(request.id).inserted { onApprovalRequested(request) }
        onAttentionChange(attentionCount)
    }

    /// Computadores da sessão, na ordem de criação.
    public func rows(forSession id: UUID) -> [ComputerRow] { rows.filter { sessionIDs[$0.id] == id } }

    /// Passa a acompanhar um computador: eventos (pedido de ajuda, controle) chegam aqui.
    public func attach(_ computer: ManagedComputer) async {
        computers[computer.name] = computer
        activity[computer.name] = activity[computer.name] ?? Date()
        let name = computer.name
        await computer.setObserver { [weak self] event in
            Task { @MainActor in self?.ingest(event, computer: name) }
        }
        await refresh()
    }

    public func detach(name: String) {
        computers[name] = nil
        sessionIDs[name] = nil
        agentNames[name] = nil
        rows.removeAll { $0.id == name }
    }

    // MARK: Eventos

    public func ingest(_ event: ComputerEvent, computer name: String, now: Date = Date()) {
        activity[name] = now
        switch event {
        case .helpRequested(_, let requestID, _):
            Task { await self.recordHelp(requestID, computer: name, now: now) }
        case .helpResolved(_, let requestID, let status):
            guard let index = inbox.firstIndex(where: { $0.id == requestID }) else { return }
            inbox[index].phase = switch status {
            case .declined: .declined
            case .cancelled, .expired: .cancelled
            default: .resolved
            }
            inbox[index].read = true
            onAttentionChange(attentionCount)
        case .control, .doing, .blocked, .released, .unclaimed: break
        }
    }

    private func recordHelp(_ requestID: String, computer name: String, now: Date) async {
        guard !notified.contains(requestID), let computer = computers[name] else { return }
        guard let summary = await computer.helpSummary(requestID) else { return }
        notified.insert(requestID)
        let item = InboxItem(id: requestID, computer: name, summary: summary, createdAt: now)
        inbox.insert(item, at: 0)
        onAttentionChange(attentionCount)
        onHelpRequested(item, .make(session: sessionTitle(name), computer: name, summary: summary))
        await refresh()
    }

    /// F28: devolve ao agente os computadores cujo humano ficou sem input pelo prazo; devolve os nomes (o app mostra o aviso).
    public func returnIdleControl(now: Date = Date(), after timeout: TimeInterval = ManagedComputer.humanIdleTimeout) async -> [String] {
        var returned: [String] = []
        for (name, computer) in computers {
            if await computer.returnIdleControl(now: now, after: timeout) { returned.append(name) }
        }
        if !returned.isEmpty { await refresh() }
        return returned.sorted()
    }

    public func markRead(_ id: String) { if let i = inbox.firstIndex(where: { $0.id == id }) { inbox[i].read = true } }
    public func markAllRead() { for i in inbox.indices { inbox[i].read = true } }
    public var unreadCount: Int { inbox.filter { !$0.read }.count }

    // MARK: Linhas

    /// Atualiza snapshots (barato) e a miniatura no máximo a cada `thumbnailEvery` segundos por computador (CS-403: 1 s com a tela
    /// grande à vista; a sidebar, que mostra o último quadro de cada computador, pede bem menos).
    public func refresh(now: Date = Date(), withThumbnails: Bool = false, thumbnailEvery: TimeInterval = 1) async {
        var next: [ComputerRow] = []
        for (name, computer) in computers {
            let snapshot = await computer.viewerSnapshot()
            if withThumbnails, snapshot.display != "http", snapshot.state == .ready || snapshot.state == .inUse,
               !thumbnailInFlight.contains(name), now.timeIntervalSince(thumbnails[name]?.at ?? .distantPast) >= thumbnailEvery {
                thumbnailInFlight.insert(name)
                if let data = await computer.thumbnail() { thumbnails[name] = (data, now) }
                thumbnailInFlight.remove(name)
            }
            next.append(ComputerRow(
                snapshot: snapshot, thumbnail: thumbnails[name]?.data, sessionTitle: sessionTitle(name), owner: nil,
                lastActivity: activity[name] ?? .distantPast))
        }
        // Só troca quando algo mudou: atribuir a mesma lista a cada segundo refazia a sidebar inteira (ela observa `rows`).
        let sorted = Self.sorted(next)
        if sorted != rows { rows = sorted }
    }

    /// "Precisa de você" primeiro, depois atividade recente, depois nome (audit/10 R4.8).
    public static func sorted(_ rows: [ComputerRow]) -> [ComputerRow] {
        rows.sorted {
            if $0.needsYou != $1.needsYou { return $0.needsYou }
            if $0.lastActivity != $1.lastActivity { return $0.lastActivity > $1.lastActivity }
            return $0.id < $1.id
        }
    }

    public var summaryText: String {
        let running = rows.filter { $0.snapshot.state == .ready || $0.snapshot.state == .inUse }.count
        return "\(running) running"
    }
}
