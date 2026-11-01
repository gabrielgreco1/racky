import Foundation
import GRDB

// Árvore pai -> filhos da orquestração (`v6_agent_tree`, T3-04, 07 §4.3), mensagens do pai aos filhos (P12, CS-307) e o espelho dos
// computadores com a fila persistente (`computer`, `computer_queue` de `v3_computers`, CS-131).

public enum OrchestrationChildState: String, Sendable, Codable, CaseIterable {
    /// Slot de worker do pai sem computador.
    case idle
    /// Computador reservado para o slot; o filho ainda não reivindicou (`box_claim`).
    case reserved
    case claimed
    case released
    /// O `SubagentStop` do filho chegou.
    case ended
    /// Reserva nunca reivindicada, liberada pelo tempo (CS-302).
    case expired

    /// Ainda conta como filho ativo do pai (segura `waitingOnSubagents`).
    public var isActive: Bool { self == .reserved || self == .claimed }
}

public struct OrchestrationChild: Sendable, Equatable, Identifiable {
    /// Identidade MCP do filho (`racky mcp --child <id>`).
    public var id: String
    /// Identidade MCP do pai (a execução do terminal pai).
    public var parentID: String
    public var parentRunID: UUID?
    public var slot: Int
    /// `subagent_type` do worker (`racky-worker-3`).
    public var agentType: String
    public var computerName: String?
    public var batchID: String?
    /// `agent_run` do filho nativo, preenchido quando o hook revela o `agent_id` (correlação por `mcp_server.name`, S-08).
    public var runID: UUID?
    public var providerAgentID: String?
    /// SHA-256 (hex) da capability do lançamento; permite a um app reiniciado voltar a aceitar o filho que seguiu vivo.
    public var capabilityHash: String?
    /// Codex: thread do worker ligada a este slot no pool (sobrevive ao app para o worker não precisar de novo `box_claim`).
    public var boundThread: String?
    /// CLI do worker de app (`claude`/`codex`/`opencode`); `nil` = subagente nativo do Claude (spec subagent-harness).
    public var harness: String?
    /// Terminal do worker de app (UUID do `terminal`); a sidebar e o painel o focam por aqui.
    public var workerTerminalID: UUID?
    /// Título curto da tarefa (linha na sidebar e título do painel).
    public var title: String?
    public var state: OrchestrationChildState
    public var createdAt: Date
    public var reservedAt: Date?
    public var claimedAt: Date?
    public var releasedAt: Date?
    public var endedAt: Date?

    public init(
        id: String, parentID: String, parentRunID: UUID? = nil, slot: Int, agentType: String, computerName: String? = nil, batchID: String? = nil,
        runID: UUID? = nil, providerAgentID: String? = nil, state: OrchestrationChildState = .idle, createdAt: Date = Date(),
        reservedAt: Date? = nil, claimedAt: Date? = nil, releasedAt: Date? = nil, endedAt: Date? = nil, capabilityHash: String? = nil,
        boundThread: String? = nil, harness: String? = nil, workerTerminalID: UUID? = nil, title: String? = nil
    ) {
        self.harness = harness; self.workerTerminalID = workerTerminalID; self.title = title
        self.boundThread = boundThread
        self.id = id; self.parentID = parentID; self.parentRunID = parentRunID; self.slot = slot; self.agentType = agentType
        self.computerName = computerName; self.batchID = batchID; self.runID = runID; self.providerAgentID = providerAgentID
        self.state = state; self.createdAt = createdAt; self.reservedAt = reservedAt; self.claimedAt = claimedAt
        self.releasedAt = releasedAt; self.endedAt = endedAt; self.capabilityHash = capabilityHash
    }
}

/// O que o app sabia de um pai (terminal Claude com Subagent computers ligado), para voltar a reconhecê-lo depois de reiniciar.
public struct OrchestrationParentRecord: Sendable, Equatable {
    public var id: String
    public var parentRunID: UUID?
    public var sessionID: UUID?
    public var sessionTitle: String
    /// `off`/`ask`/`full`.
    public var mode: String
    public var proxy: String?
    public var capabilityHash: String
    public var createdAt: Date
    /// CLI do pai (`claude`/`codex`/`opencode`).
    public var provider: String
    /// Codex: identidade do servidor MCP dos workers (só o hash da capability).
    public var poolID: String?
    public var poolCapabilityHash: String?

    public init(
        id: String, parentRunID: UUID? = nil, sessionID: UUID? = nil, sessionTitle: String = "", mode: String, proxy: String? = nil, capabilityHash: String,
        createdAt: Date = Date(), provider: String = "claude", poolID: String? = nil, poolCapabilityHash: String? = nil
    ) {
        self.id = id; self.parentRunID = parentRunID; self.sessionID = sessionID; self.sessionTitle = sessionTitle; self.mode = mode
        self.proxy = proxy; self.capabilityHash = capabilityHash; self.createdAt = createdAt
        self.provider = provider; self.poolID = poolID; self.poolCapabilityHash = poolCapabilityHash
    }
}

public enum AgentMessageDelivery: String, Sendable, Codable {
    /// Worker com PTY (v1.1): colado com bracketed paste e Enter.
    case pty
    /// Filho nativo: vai para a inbox e sai no próximo `box_status` como `parent_messages`.
    case inbox
    case queued
}

public struct StoredAgentMessage: Sendable, Equatable, Identifiable {
    public var id: String
    public var parentID: String
    public var childID: String
    public var text: String
    public var delivery: AgentMessageDelivery
    public var createdAt: Date
    public var deliveredAt: Date?

    public init(id: String, parentID: String, childID: String, text: String, delivery: AgentMessageDelivery, createdAt: Date, deliveredAt: Date? = nil) {
        self.id = id; self.parentID = parentID; self.childID = childID; self.text = text; self.delivery = delivery
        self.createdAt = createdAt; self.deliveredAt = deliveredAt
    }
}

/// Computador espelhado no SQLite (estado e fila sobrevivem a reiniciar o app).
public struct ComputerStateRow: Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var display: String
    public var state: String
    public var ownerParentID: String?
    public var createdAt: Date

    public init(id: UUID, name: String, display: String, state: String, ownerParentID: String? = nil, createdAt: Date = Date()) {
        self.id = id; self.name = name; self.display = display; self.state = state; self.ownerParentID = ownerParentID; self.createdAt = createdAt
    }
}

public struct ComputerQueueRow: Sendable, Equatable {
    public var computerID: UUID
    public var position: Int
    public var requestedAt: Date
    public var reason: String
    public init(computerID: UUID, position: Int, requestedAt: Date, reason: String = "memory") {
        self.computerID = computerID; self.position = position; self.requestedAt = requestedAt; self.reason = reason
    }
}

extension OrchestrationChild {
    fileprivate init(row: Row) throws {
        let state = row["state"] as String
        guard let parsed = OrchestrationChildState(rawValue: state) else { throw StoreError.invalidRow(table: "orchestration_child", detail: "bad state \(state)") }
        self.init(
            id: row["id"], parentID: row["parent_id"], parentRunID: (row["parent_run_id"] as String?).flatMap(UUID.init(uuidString:)), slot: row["slot"],
            agentType: row["agent_type"], computerName: row["computer_name"], batchID: row["batch_id"],
            runID: (row["run_id"] as String?).flatMap(UUID.init(uuidString:)), providerAgentID: row["provider_agent_id"], state: parsed,
            createdAt: RowCodec.date(row["created_at"] as Int64), reservedAt: RowCodec.date(row["reserved_at"] as Int64?),
            claimedAt: RowCodec.date(row["claimed_at"] as Int64?), releasedAt: RowCodec.date(row["released_at"] as Int64?),
            endedAt: RowCodec.date(row["ended_at"] as Int64?), capabilityHash: row["capability_hash"], boundThread: row["bound_thread"],
            harness: row["harness"], workerTerminalID: (row["worker_terminal_id"] as String?).flatMap(UUID.init(uuidString:)), title: row["title"])
    }
}

extension StoredAgentMessage {
    fileprivate init(row: Row) throws {
        let delivery = row["delivery"] as String
        guard let parsed = AgentMessageDelivery(rawValue: delivery) else { throw StoreError.invalidRow(table: "agent_message", detail: "bad delivery \(delivery)") }
        self.init(
            id: row["id"], parentID: row["parent_id"], childID: row["child_id"], text: row["text"], delivery: parsed,
            createdAt: RowCodec.date(row["created_at"] as Int64), deliveredAt: RowCodec.date(row["delivered_at"] as Int64?))
    }
}

extension RackyStore {
    // MARK: Árvore

    /// Cria o slot ou atualiza os campos de identidade; o estado e os vínculos existentes só mudam por `updateOrchestrationChild`.
    public func registerOrchestrationChild(_ child: OrchestrationChild) async throws {
        try await write { db in
            try db.execute(
                sql: """
                INSERT INTO orchestration_child (id, parent_id, parent_run_id, slot, agent_type, state, created_at, capability_hash, harness, title)
                VALUES (?, ?, ?, ?, ?, 'idle', ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET parent_run_id = COALESCE(excluded.parent_run_id, parent_run_id), agent_type = excluded.agent_type,
                    capability_hash = COALESCE(excluded.capability_hash, capability_hash), harness = COALESCE(excluded.harness, harness),
                    title = COALESCE(excluded.title, title)
                """,
                arguments: [
                    child.id, child.parentID, child.parentRunID?.uuidString, child.slot, child.agentType, RowCodec.ms(child.createdAt) as Int64, child.capabilityHash,
                    child.harness, child.title])
        }
    }

    public func orchestrationChild(id: String) async throws -> OrchestrationChild? {
        try await read { db in try Row.fetchOne(db, sql: "SELECT * FROM orchestration_child WHERE id = ?", arguments: [id]).map { try OrchestrationChild(row: $0) } }
    }

    /// Filhos do pai por ordem de slot.
    public func orchestrationChildren(parentID: String) async throws -> [OrchestrationChild] {
        try await read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM orchestration_child WHERE parent_id = ? ORDER BY slot", arguments: [parentID]).map { try OrchestrationChild(row: $0) }
        }
    }

    public func orchestrationChild(parentID: String, computerName: String) async throws -> OrchestrationChild? {
        try await read { db in
            try Row.fetchOne(
                db, sql: "SELECT * FROM orchestration_child WHERE parent_id = ? AND computer_name = ? AND state IN ('reserved','claimed') ORDER BY slot LIMIT 1",
                arguments: [parentID, computerName]).map { try OrchestrationChild(row: $0) }
        }
    }

    /// O filho que segura (ou segurou) o computador, em qualquer estado: a adoção precisa do vínculo mesmo após `released` (keep 24 h).
    public func orchestrationChild(parentID: String, anyStateComputerName computerName: String) async throws -> OrchestrationChild? {
        try await read { db in
            try Row.fetchOne(
                db, sql: "SELECT * FROM orchestration_child WHERE parent_id = ? AND computer_name = ? AND state != 'idle' ORDER BY slot LIMIT 1",
                arguments: [parentID, computerName]).map { try OrchestrationChild(row: $0) }
        }
    }

    // MARK: Pais (identidade que sobrevive ao app)

    public func saveOrchestrationParent(_ parent: OrchestrationParentRecord) async throws {
        try await write { db in
            try db.execute(
                sql: """
                INSERT INTO orchestration_parent (id, parent_run_id, session_id, session_title, mode, proxy, capability_hash, created_at, provider, pool_id, pool_capability_hash)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET parent_run_id = excluded.parent_run_id, session_id = excluded.session_id, session_title = excluded.session_title,
                    mode = excluded.mode, proxy = excluded.proxy, capability_hash = excluded.capability_hash, provider = excluded.provider,
                    pool_id = excluded.pool_id, pool_capability_hash = excluded.pool_capability_hash
                """,
                arguments: [
                    parent.id, parent.parentRunID?.uuidString, parent.sessionID?.uuidString, parent.sessionTitle, parent.mode, parent.proxy,
                    parent.capabilityHash, RowCodec.ms(parent.createdAt) as Int64, parent.provider, parent.poolID, parent.poolCapabilityHash,
                ])
        }
    }

    /// Codex: a thread do worker passou a falar como o slot `childID` no pool.
    public func bindOrchestrationThread(childID: String, thread: String) async throws {
        try await write { db in try db.execute(sql: "UPDATE orchestration_child SET bound_thread = ? WHERE id = ?", arguments: [thread, childID]) }
    }

    public func updateOrchestrationParentProxy(id: String, proxy: String?) async throws {
        try await write { db in try db.execute(sql: "UPDATE orchestration_parent SET proxy = ? WHERE id = ?", arguments: [proxy, id]) }
    }

    public func orchestrationParents() async throws -> [OrchestrationParentRecord] {
        try await read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM orchestration_parent ORDER BY created_at").map { row in
                OrchestrationParentRecord(
                    id: row["id"], parentRunID: (row["parent_run_id"] as String?).flatMap(UUID.init(uuidString:)),
                    sessionID: (row["session_id"] as String?).flatMap(UUID.init(uuidString:)), sessionTitle: row["session_title"], mode: row["mode"],
                    proxy: row["proxy"], capabilityHash: row["capability_hash"], createdAt: RowCodec.date(row["created_at"] as Int64),
                    provider: row["provider"], poolID: row["pool_id"], poolCapabilityHash: row["pool_capability_hash"])
            }
        }
    }

    /// O terminal pai terminou: some a identidade dele e a dos filhos (a árvore e as mensagens ficam; só a credencial sai).
    public func deleteOrchestrationParent(id: String) async throws {
        try await write { db in
            try db.execute(sql: "DELETE FROM orchestration_parent WHERE id = ?", arguments: [id])
            try db.execute(sql: "UPDATE orchestration_child SET capability_hash = NULL, bound_thread = NULL WHERE parent_id = ?", arguments: [id])
        }
    }

    /// Pais mais antigos que `date` (identidades que ninguém mais usa) saem na abertura do app.
    public func pruneOrchestrationParents(olderThan date: Date) async throws {
        let ms = RowCodec.ms(date) as Int64
        try await write { db in
            try db.execute(sql: "UPDATE orchestration_child SET capability_hash = NULL, bound_thread = NULL WHERE parent_id IN (SELECT id FROM orchestration_parent WHERE created_at < ?)", arguments: [ms])
            try db.execute(sql: "DELETE FROM orchestration_parent WHERE created_at < ?", arguments: [ms])
        }
    }

    /// Transição de estado (e vínculo com o computador) de um filho. Os carimbos de tempo acompanham o estado.
    public func updateOrchestrationChild(id: String, state: OrchestrationChildState, computerName: String?? = nil, batchID: String?? = nil, at: Date = Date()) async throws {
        let ms = RowCodec.ms(at)
        try await write { db in
            switch state {
            case .reserved: try db.execute(sql: "UPDATE orchestration_child SET state = ?, reserved_at = ? WHERE id = ?", arguments: [state.rawValue, ms, id])
            case .claimed: try db.execute(sql: "UPDATE orchestration_child SET state = ?, claimed_at = ? WHERE id = ?", arguments: [state.rawValue, ms, id])
            case .released, .expired: try db.execute(sql: "UPDATE orchestration_child SET state = ?, released_at = ? WHERE id = ?", arguments: [state.rawValue, ms, id])
            case .ended: try db.execute(sql: "UPDATE orchestration_child SET state = ?, ended_at = ? WHERE id = ?", arguments: [state.rawValue, ms, id])
            case .idle: try db.execute(sql: "UPDATE orchestration_child SET state = ?, computer_name = NULL, batch_id = NULL, run_id = NULL, provider_agent_id = NULL WHERE id = ?", arguments: [state.rawValue, id])
            }
            if let computerName { try db.execute(sql: "UPDATE orchestration_child SET computer_name = ? WHERE id = ?", arguments: [computerName, id]) }
            if let batchID { try db.execute(sql: "UPDATE orchestration_child SET batch_id = ? WHERE id = ?", arguments: [batchID, id]) }
        }
    }

    /// O terminal é de um worker de app? O `launch_spec` (gravado antes do lançamento) leva `workerChildID`.
    public func isWorkerTerminal(_ id: UUID) async throws -> Bool {
        let key = id.uuidString
        return try await read { db in
            try Int.fetchOne(db, sql: "SELECT 1 FROM terminal WHERE id = ? AND json_extract(launch_spec_json, '$.workerChildID') IS NOT NULL", arguments: [key]) != nil
        }
    }

    /// O terminal do worker de app foi aberto (spec subagent-harness): a sidebar acha o painel por aqui.
    public func setOrchestrationWorkerTerminal(id: String, terminalID: UUID?) async throws {
        try await write { db in try db.execute(sql: "UPDATE orchestration_child SET worker_terminal_id = ? WHERE id = ?", arguments: [terminalID?.uuidString, id]) }
    }

    /// Workers de app (CLI separado) do pai, por ordem de criação.
    public func orchestrationWorkers(parentID: String) async throws -> [OrchestrationChild] {
        try await read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM orchestration_child WHERE parent_id = ? AND harness IS NOT NULL ORDER BY created_at, slot", arguments: [parentID]).map { try OrchestrationChild(row: $0) }
        }
    }

    /// Todos os workers de app ainda ativos (sidebar): reservados ou reivindicados.
    public func activeOrchestrationWorkers() async throws -> [OrchestrationChild] {
        try await read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM orchestration_child WHERE harness IS NOT NULL ORDER BY created_at, slot").map { try OrchestrationChild(row: $0) }
        }
    }

    /// Correlação com o filho nativo: o hook trouxe `agent_id` e `mcp_server.name` (S-08). O `agent_run` do filho é opcional.
    public func linkOrchestrationChild(id: String, runID: UUID?, providerAgentID: String) async throws {
        try await write { db in
            try db.execute(sql: "UPDATE orchestration_child SET run_id = COALESCE(?, run_id), provider_agent_id = ? WHERE id = ?", arguments: [runID?.uuidString, providerAgentID, id])
        }
    }

    // MARK: Mensagens do pai (P12)

    public func appendAgentMessage(id: String = UUID().uuidString.lowercased(), parentID: String, childID: String, text: String, delivery: AgentMessageDelivery, at: Date = Date()) async throws -> StoredAgentMessage {
        guard !text.isEmpty, text.count <= 16_000 else { throw StoreError.invalidModel("agent message must have 1...16000 characters") }
        let ms = RowCodec.ms(at)
        try await write { db in
            try db.execute(
                sql: "INSERT INTO agent_message (id, parent_id, child_id, text, delivery, created_at) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [id, parentID, childID, text, delivery.rawValue, ms])
        }
        return StoredAgentMessage(id: id, parentID: parentID, childID: childID, text: text, delivery: delivery, createdAt: at, deliveredAt: nil)
    }

    public func pendingAgentMessages(childID: String) async throws -> [StoredAgentMessage] {
        try await read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM agent_message WHERE child_id = ? AND delivered_at IS NULL ORDER BY created_at, rowid", arguments: [childID]).map { try StoredAgentMessage(row: $0) }
        }
    }

    public func agentMessages(childID: String) async throws -> [StoredAgentMessage] {
        try await read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM agent_message WHERE child_id = ? ORDER BY created_at, rowid", arguments: [childID]).map { try StoredAgentMessage(row: $0) }
        }
    }

    public func markAgentMessagesDelivered(_ ids: [String], at: Date = Date()) async throws {
        guard !ids.isEmpty else { return }
        let ms = RowCodec.ms(at)
        try await write { db in
            for id in ids { try db.execute(sql: "UPDATE agent_message SET delivered_at = ? WHERE id = ? AND delivered_at IS NULL", arguments: [ms, id]) }
        }
    }

    // MARK: Computadores e fila

    public func saveComputerState(_ row: ComputerStateRow) async throws {
        let allowed: Set<String> = ["queued", "provisioning", "ready", "in_use", "stopped", "failed", "removing", "removed", "orphan"]
        guard allowed.contains(row.state) else { throw StoreError.invalidModel("computer state \(row.state)") }
        try await write { db in
            try db.execute(
                sql: """
                INSERT INTO computer (id, owner_run_id, name, display, state, created_at) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET state = excluded.state, display = excluded.display, last_used_at = ?
                """,
                arguments: [row.id.uuidString, row.ownerParentID, row.name, row.display, row.state, RowCodec.ms(row.createdAt) as Int64, RowCodec.ms(Date()) as Int64])
        }
    }

    public func computerStates() async throws -> [ComputerStateRow] {
        try await read { db in
            try Row.fetchAll(db, sql: "SELECT id, name, display, state, owner_run_id, created_at FROM computer ORDER BY created_at, name").compactMap { row in
                guard let id = UUID(uuidString: row["id"] as String) else { return nil }
                return ComputerStateRow(
                    id: id, name: row["name"], display: row["display"], state: row["state"], ownerParentID: row["owner_run_id"],
                    createdAt: RowCodec.date(row["created_at"] as Int64))
            }
        }
    }

    /// Substitui a fila persistente (FIFO por `position`, a partir de 1).
    public func replaceComputerQueue(_ rows: [ComputerQueueRow]) async throws {
        try await write { db in
            try db.execute(sql: "DELETE FROM computer_queue")
            for row in rows {
                try db.execute(
                    sql: "INSERT INTO computer_queue (id, computer_id, position, requested_at, reason) VALUES (?, ?, ?, ?, ?)",
                    arguments: [UUID().uuidString.lowercased(), row.computerID.uuidString, row.position, RowCodec.ms(row.requestedAt) as Int64, row.reason])
            }
        }
    }

    public func computerQueue() async throws -> [ComputerQueueRow] {
        try await read { db in
            try Row.fetchAll(db, sql: "SELECT computer_id, position, requested_at, reason FROM computer_queue ORDER BY position").compactMap { row in
                guard let id = UUID(uuidString: row["computer_id"] as String) else { return nil }
                return ComputerQueueRow(computerID: id, position: row["position"], requestedAt: RowCodec.date(row["requested_at"] as Int64), reason: row["reason"])
            }
        }
    }
}
