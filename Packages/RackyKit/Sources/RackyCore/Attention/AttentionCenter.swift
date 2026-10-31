import RackyProtocol
import Foundation

/// Fila de atenção e estado de leitura (01 §5.12, 06 §3.5–§3.6). Valor puro: o coordenador (`AttentionCoordinator`) guarda
/// uma instância, e os testes a exercitam sem UI, banco nem relógio de verdade.
///
/// Regras:
/// - Um item nasce na **entrada** em `needsInput`, `failed` ou `done` (nunca em atualizações que repetem o estado).
/// - Sair do estado (novo prompt, permissão concedida, relançamento) resolve os itens do terminal.
/// - Ver o pane (`markViewed`) resolve os itens e limpa o não lido; um novo turno também limpa.
/// - O badge conta só prioridade 1–2 não resolvidos.
public struct AttentionCenter: Sendable, Equatable {
    public static let itemLimit = 200

    public private(set) var statuses: [UUID: TerminalActivity] = [:]
    public private(set) var items: [AttentionItem] = []
    /// Terminais com `done`, `failed` ou bell ainda não vistos (negrito na linha, ponto âmbar na tab).
    public private(set) var unread: Set<UUID> = []
    /// Subconjunto de `unread` que veio de BEL (a tab ganha sino, não só o ponto).
    public private(set) var bells: Set<UUID> = []
    /// Terminais cujo `done` o usuário já viu: só esses viram `idle` depois de 30 min (06 §3.1).
    public private(set) var seenDone: Set<UUID> = []
    private var sequence = 0

    public init() {}

    // MARK: - Entrada de estado

    /// Aplica o estado novo de um terminal. Devolve o item criado, se a mudança abriu um (para notificar).
    /// `context == nil` (terminal ainda desconhecido da UI) grava o estado sem abrir item.
    /// `seeding` (estado lido do banco na abertura): `needsInput` ainda pendente vira item; `done`/`failed` só se `unreadHint`.
    @discardableResult
    public mutating func apply(
        _ new: TerminalActivity, context: AttentionContext?, now: Date, seeding: Bool = false, unreadHint: Bool = false
    ) -> AttentionItem? {
        let id = new.terminalID
        let previous = statuses[id]
        var status = new
        if let previous, Self.sameState(previous.activity, new.activity) { status.changedAt = previous.changedAt } else { status.changedAt = new.changedAt }
        statuses[id] = status

        let entered = previous == nil || !Self.sameKind(previous!.activity, new.activity)
        switch new.activity {
        case .working, .starting:
            resolve(terminal: id, now: now)
            unread.remove(id); bells.remove(id); seenDone.remove(id)
        case .idle, .waitingOnSubagents, .unknown:
            resolve(terminal: id, now: now)
        case .interrupted:
            resolve(terminal: id, now: now)
        case .blocked:
            break
        case .needsInput:
            guard entered, let context else { return nil }
            resolve(terminal: id, kinds: [.done, .failed], now: now)
            return open(.needsInput, status: status, context: context, now: now, body: status.reason ?? status.lastMessage ?? "Needs your input")
        case .failed:
            guard entered else { return nil }
            resolve(terminal: id, kinds: [.needsInput, .done], now: now)
            if seeding && !unreadHint { return nil }
            unread.insert(id)
            guard let context else { return nil }
            return open(.failed, status: status, context: context, now: now, body: AttentionText.failureText(status.reason))
        case .done:
            guard entered else { return nil }
            resolve(terminal: id, kinds: [.needsInput, .failed], now: now)
            if seeding && !unreadHint { return nil }
            unread.insert(id)
            seenDone.remove(id)
            guard let context else { return nil }
            return open(.done, status: status, context: context, now: now, body: status.lastMessage ?? "Finished")
        }
        return nil
    }

    private static func sameKind(_ a: AgentActivity, _ b: AgentActivity) -> Bool {
        switch (a, b) {
        case (.needsInput, .needsInput): true
        default: a == b
        }
    }

    private static func sameState(_ a: AgentActivity, _ b: AgentActivity) -> Bool { sameKind(a, b) }

    private mutating func open(
        _ kind: AttentionKind, status: TerminalActivity, context: AttentionContext, now: Date, body: String
    ) -> AttentionItem? {
        // Já há item aberto desse tipo para o terminal: é o mesmo pedido.
        if items.contains(where: { $0.terminalID == status.terminalID && $0.kind == kind && !$0.isResolved }) { return nil }
        sequence += 1
        let item = AttentionItem(
            id: "\(status.terminalID.uuidString.lowercased()).\(kind.rawValue).\(sequence)", kind: kind, sessionID: context.sessionID,
            terminalID: status.terminalID, runID: status.runID, title: AttentionText.title(context, kind: kind), body: body, createdAt: now)
        items.append(item)
        if items.count > Self.itemLimit { items.removeFirst(items.count - Self.itemLimit) }
        return item
    }

    /// "Lote concluído" (07 CS-326, AC-429): **um** item por lote (o `id` é o do lote), sem mexer no estado do terminal pai. Devolve o item
    /// criado, ou `nil` se esse lote já tem item (um segundo `batch_collect` ou o reinício do app não geram outro).
    @discardableResult
    public mutating func openBatchDone(
        batchID: String, sessionID: UUID, terminalID: UUID, runID: UUID? = nil, title: String, body: String, now: Date
    ) -> AttentionItem? {
        let id = "batch.\(batchID).\(AttentionKind.batchDone.rawValue)"
        if items.contains(where: { $0.id == id }) { return nil }
        let item = AttentionItem(
            id: id, kind: .batchDone, sessionID: sessionID, terminalID: terminalID, runID: runID, title: title, body: body, createdAt: now, batchID: batchID)
        items.append(item)
        if items.count > Self.itemLimit { items.removeFirst(items.count - Self.itemLimit) }
        return item
    }

    /// O usuário abriu o painel do lote (ou o item): o item sai da fila.
    public mutating func resolveBatch(_ batchID: String, now: Date) {
        for i in items.indices where items[i].batchID == batchID && !items[i].isResolved {
            items[i].seenAt = items[i].seenAt ?? now
            items[i].resolvedAt = now
        }
    }

    /// Itens de lote concluído ainda abertos (o Inbox os mostra em `Done`).
    public var batchItems: [AttentionItem] { items.filter { $0.kind == .batchDone && !$0.isResolved } }

    private mutating func resolve(terminal id: UUID, kinds: Set<AttentionKind>? = nil, now: Date) {
        for i in items.indices where items[i].terminalID == id && !items[i].isResolved && (kinds?.contains(items[i].kind) ?? true) {
            items[i].resolvedAt = now
        }
    }

    // MARK: - Leitura

    /// O pane ficou visível com a janela key (1 s, 06 §3.6): resolve os itens e limpa o não lido. `true` se algo mudou.
    @discardableResult
    public mutating func markViewed(terminals ids: Set<UUID>, now: Date) -> Bool {
        var changed = false
        for id in ids {
            for i in items.indices where items[i].terminalID == id && !items[i].isResolved {
                items[i].seenAt = items[i].seenAt ?? now
                items[i].resolvedAt = now
                changed = true
            }
            if unread.remove(id) != nil { changed = true }
            bells.remove(id)
            if statuses[id]?.activity == .done, seenDone.insert(id).inserted { changed = true }
        }
        return changed
    }

    /// "Mark All as Read".
    @discardableResult
    public mutating func markAllRead(now: Date) -> Bool {
        markViewed(terminals: Set(statuses.keys).union(unread).union(items.map(\.terminalID)), now: now)
    }

    public mutating func markUnread(terminal id: UUID) { unread.insert(id); seenDone.remove(id) }

    /// BEL num terminal (06 §3.6): fica não lido até o pane ser visto.
    @discardableResult
    public mutating func bell(terminal id: UUID) -> Bool {
        let inserted = unread.insert(id).inserted
        bells.insert(id)
        return inserted
    }

    /// O terminal foi fechado: nada dele fica na fila.
    public mutating func remove(terminal id: UUID) {
        statuses[id] = nil
        unread.remove(id); bells.remove(id); seenDone.remove(id)
        items.removeAll { $0.terminalID == id }
    }

    public mutating func markNotified(itemID: String) {
        if let i = items.firstIndex(where: { $0.id == itemID }) { items[i].systemNotified = true }
    }

    // MARK: - Consultas

    /// Itens abertos por prioridade e, dentro dela, por ordem de espera (o mais antigo primeiro).
    public var pending: [AttentionItem] {
        items.filter { !$0.isResolved }.sorted { ($0.priority, $0.createdAt, $0.id) < ($1.priority, $1.createdAt, $1.id) }
    }

    /// Itens abertos de prioridade 1–2: o número do badge do Dock, do item `Inbox` e da barra de menus.
    public var badgeCount: Int { items.filter { !$0.isResolved && $0.kind.countsForBadge }.count }

    public func hasUnresolvedItem(terminal id: UUID) -> Bool { items.contains { $0.terminalID == id && !$0.isResolved } }

    /// "Next Needing Attention": o próximo item aberto depois do terminal atual, na ordem de `pending`, dando a volta.
    public func next(after currentTerminal: UUID?) -> AttentionItem? {
        var firstPerTerminal: [AttentionItem] = []
        for item in pending where !firstPerTerminal.contains(where: { $0.terminalID == item.terminalID }) { firstPerTerminal.append(item) }
        guard !firstPerTerminal.isEmpty else { return nil }
        guard let currentTerminal, let at = firstPerTerminal.firstIndex(where: { $0.terminalID == currentTerminal }) else {
            return firstPerTerminal.first
        }
        return firstPerTerminal[(at + 1) % firstPerTerminal.count]
    }

    /// Estado efetivo: `done` visto e sem atividade por 30 min vira `idle` (06 §3.1).
    public func effectiveActivity(of id: UUID, now: Date) -> AgentActivity? {
        guard let s = statuses[id] else { return nil }
        if s.activity == .done, seenDone.contains(id), now.timeIntervalSince(s.changedAt) >= ActivityTimeouts.idleAfterDone { return .idle }
        return s.activity
    }

    /// Estado agregado de um conjunto de terminais (01 §6.3): o pior vence; `done` não lido pesa mais que `done` lido.
    public func aggregate(_ ids: [UUID], now: Date) -> AgentActivity? {
        AgentActivityMachine.aggregate(ids.compactMap { id in
            effectiveActivity(of: id, now: now).map { .init($0, unseen: unread.contains(id)) }
        })
    }
}
