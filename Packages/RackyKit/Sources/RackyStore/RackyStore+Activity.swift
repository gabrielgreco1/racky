import RackyProtocol
import Foundation
import GRDB

// Persistência de atividade de agentes (`v2_activity`, 08 AR-311): `agent_run` (projeção do estado) e `agent_event`
// (eventos de hook reduzidos, a fonte de verdade: o estado se reconstrói reaplicando-os em ordem de ocorrência).

/// Evento a gravar. `eventID` é a chave de idempotência (única por execução); `atNs` define a ordem de ocorrência.
public struct NewAgentEvent: Sendable, Equatable {
    public var runID: UUID
    public var eventID: String
    public var type: String
    public var payloadJSON: String
    public var atNs: Int64
    public init(runID: UUID, eventID: String, type: String, payloadJSON: String, atNs: Int64) {
        self.runID = runID; self.eventID = eventID; self.type = type; self.payloadJSON = payloadJSON; self.atNs = atNs
    }
}

public struct StoredAgentEvent: Sendable, Equatable {
    public var runID: UUID
    public var seq: Int
    public var eventID: String
    public var type: String
    public var payloadJSON: String
    public var at: Date
    public var atNs: Int64
}

/// Campos do terminal derivados da atividade. Só são aplicados se a execução ainda é a do terminal
/// (`current_run_id` nulo ou igual): eventos atrasados de uma execução antiga não sobrescrevem a última mensagem.
public struct TerminalActivityUpdate: Sendable, Equatable {
    public var terminalID: UUID
    /// `nil` mantém o valor atual. Já saneado; o store só garante o limite de 500 caracteres.
    public var lastMessage: String?
    public var nativeConversationID: String?
    public init(terminalID: UUID, lastMessage: String? = nil, nativeConversationID: String? = nil) {
        self.terminalID = terminalID; self.lastMessage = lastMessage; self.nativeConversationID = nativeConversationID
    }
}

/// Resultado do redutor para uma execução principal e seus filhos nativos.
public struct ActivityProjection: Sendable, Equatable {
    public var runs: [AgentRun]
    public var terminalUpdate: TerminalActivityUpdate?
    public var guardRunID: UUID
    public init(runs: [AgentRun], terminalUpdate: TerminalActivityUpdate? = nil, guardRunID: UUID) {
        self.runs = runs; self.terminalUpdate = terminalUpdate; self.guardRunID = guardRunID
    }
}

enum AgentStatusCodec {
    static func encode(_ a: AgentActivity) -> (status: String, kind: String?) {
        switch a {
        case .starting: ("starting", nil)
        case .idle: ("idle", nil)
        case .working: ("working", nil)
        case .needsInput(let k): ("needs_input", k.rawValue)
        case .waitingOnSubagents: ("waiting_on_subagents", nil)
        case .done: ("done", nil)
        case .failed: ("failed", nil)
        case .blocked: ("blocked", nil)
        case .interrupted: ("interrupted", nil)
        case .unknown: ("unknown", nil)
        }
    }

    static func decode(status: String, kind: String?) throws -> AgentActivity {
        switch status {
        case "starting": return .starting
        case "idle": return .idle
        case "working": return .working
        case "needs_input": return .needsInput(NeedsInputKind(rawValue: kind ?? "other") ?? .other)
        case "waiting_on_subagents": return .waitingOnSubagents
        case "done": return .done
        case "failed": return .failed
        case "blocked": return .blocked
        case "interrupted": return .interrupted
        case "unknown", "stalled": return .unknown  // `stalled` é v1.1; até lá lê como `unknown`
        default: throw StoreError.invalidRow(table: "agent_run", detail: "bad status \(status)")
        }
    }
}

struct AgentRunRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "agent_run"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var id: String
    var terminalId: String?
    var parentRunId: String?
    var rootRunId: String
    var kind: String
    var harness: String
    var agentType: String?
    var providerSessionId: String?
    var providerAgentId: String?
    var mode: String?
    var batchId: String?
    var status: String
    var statusKind: String?
    var estimated: Bool
    var statusReason: String?
    var subtitle: String?
    var startedAt: Int64
    var lastEventAt: Int64?
    var endedAt: Int64?

    init(_ r: AgentRun) {
        id = r.id.uuidString; terminalId = r.terminalID?.uuidString; parentRunId = r.parentRunID?.uuidString
        rootRunId = r.rootRunID.uuidString; kind = r.kind.rawValue; harness = r.harness.rawValue
        agentType = r.agentType; providerSessionId = r.providerSessionID; providerAgentId = r.providerAgentID
        mode = nil; batchId = nil
        let s = AgentStatusCodec.encode(r.activity)
        status = s.status; statusKind = s.kind; estimated = r.estimated
        statusReason = r.statusReason.map { String($0.prefix(500)) }; subtitle = r.subtitle.map { String($0.prefix(500)) }
        startedAt = RowCodec.ms(r.startedAt); lastEventAt = RowCodec.ms(r.lastEventAt); endedAt = RowCodec.ms(r.endedAt)
    }

    func domain() throws -> AgentRun {
        AgentRun(
            id: try RowCodec.id(id, table: "agent_run"), terminalID: try RowCodec.id(terminalId, table: "agent_run"),
            parentRunID: try RowCodec.id(parentRunId, table: "agent_run"), rootRunID: try RowCodec.id(rootRunId, table: "agent_run") as UUID,
            kind: try RowCodec.enumValue(kind, AgentRunKind.self, table: "agent_run"),
            harness: try RowCodec.enumValue(harness, TerminalProvider.self, table: "agent_run"),
            agentType: agentType, providerSessionID: providerSessionId, providerAgentID: providerAgentId,
            activity: try AgentStatusCodec.decode(status: status, kind: statusKind), estimated: estimated,
            statusReason: statusReason, subtitle: subtitle, startedAt: RowCodec.date(startedAt),
            lastEventAt: RowCodec.date(lastEventAt), endedAt: RowCodec.date(endedAt))
    }
}

extension RackyStore {
    /// Grava o evento (e a execução, se ainda não existir) numa transação. `false` = duplicado (mesmo `eventID`).
    /// O `terminal_id` só é gravado se o terminal existe (FK); senão a execução nasce sem terminal.
    public func recordAgentEvent(_ event: NewAgentEvent, ensuringRun run: AgentRun) async throws -> Bool {
        guard event.payloadJSON.utf8.count <= HookLimits.maxStoredPayloadBytes else {
            throw StoreError.invalidModel("agent event payload above \(HookLimits.maxStoredPayloadBytes) bytes")
        }
        let record = AgentRunRecord(run)
        let runKey = event.runID.uuidString
        let ms = Int64(event.atNs / 1_000_000)
        return try await write { db in
            if try AgentRunRecord.fetchOne(db, key: runKey) == nil {
                var r = record
                if let t = r.terminalId, try Int.fetchOne(db, sql: "SELECT 1 FROM terminal WHERE id = ?", arguments: [t]) == nil {
                    r.terminalId = nil
                }
                try r.insert(db)
            }
            let seen = try Int.fetchOne(db, sql: "SELECT 1 FROM agent_event WHERE run_id = ? AND event_id = ?", arguments: [runKey, event.eventID])
            if seen != nil { return false }
            let next = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(seq), 0) + 1 FROM agent_event WHERE run_id = ?", arguments: [runKey]) ?? 1
            try db.execute(
                sql: "INSERT INTO agent_event(run_id, seq, event_id, type, payload_json, at, at_ns) VALUES (?, ?, ?, ?, ?, ?, ?)",
                arguments: [runKey, next, event.eventID, event.type, event.payloadJSON, ms, event.atNs])
            return true
        }
    }

    /// Eventos de uma execução em ordem de ocorrência (`at_ns`, depois chegada).
    public func agentEvents(runID: UUID) async throws -> [StoredAgentEvent] {
        let key = runID.uuidString
        return try await read { db in
            try Row.fetchAll(
                db, sql: "SELECT seq, event_id, type, payload_json, at, at_ns FROM agent_event WHERE run_id = ? ORDER BY at_ns, seq",
                arguments: [key]
            ).map { row in
                StoredAgentEvent(
                    runID: runID, seq: row["seq"], eventID: row["event_id"], type: row["type"], payloadJSON: row["payload_json"],
                    at: RowCodec.date(row["at"] as Int64), atNs: row["at_ns"])
            }
        }
    }

    public func agentEventCount(runID: UUID) async throws -> Int {
        let key = runID.uuidString
        return try await read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM agent_event WHERE run_id = ?", arguments: [key]) ?? 0 }
    }

    /// Aplica a projeção do redutor: upsert das execuções e, se couber, `last_message` e ID nativo do terminal.
    public func saveActivity(_ projection: ActivityProjection) async throws {
        let records = projection.runs.map(AgentRunRecord.init)
        let update = projection.terminalUpdate
        let guardKey = projection.guardRunID.uuidString
        try await write { db in
            let ordered = records.sorted { ($0.parentRunId == nil ? 0 : 1) < ($1.parentRunId == nil ? 0 : 1) }
            for var r in ordered {
                if let t = r.terminalId, try Int.fetchOne(db, sql: "SELECT 1 FROM terminal WHERE id = ?", arguments: [t]) == nil {
                    r.terminalId = nil
                }
                try r.save(db)
            }
            guard let update else { return }
            let tid = update.terminalID.uuidString
            guard let current = try Row.fetchOne(db, sql: "SELECT current_run_id FROM terminal WHERE id = ?", arguments: [tid]) else { return }
            let currentRun: String? = current["current_run_id"]
            guard currentRun == nil || currentRun == guardKey else { return }
            if let message = update.lastMessage {
                try db.execute(sql: "UPDATE terminal SET last_message = ? WHERE id = ?", arguments: [String(message.prefix(500)), tid])
            }
            if let native = update.nativeConversationID, !native.isEmpty {
                try db.execute(sql: "UPDATE terminal SET native_conversation_id = ? WHERE id = ?", arguments: [native, tid])
            }
        }
    }

    public func agentRun(id: UUID) async throws -> AgentRun? {
        let key = id.uuidString
        return try await read { try AgentRunRecord.fetchOne($0, key: key)?.domain() }
    }

    public func childRuns(parentRunID: UUID) async throws -> [AgentRun] {
        let key = parentRunID.uuidString
        return try await read { db in
            try AgentRunRecord.filter(Column("parent_run_id") == key).order(Column("started_at"), Column("id")).fetchAll(db).map { try $0.domain() }
        }
    }

    /// Execuções principais do terminal, a mais recente primeiro.
    public func agentRuns(terminalID: UUID) async throws -> [AgentRun] {
        let key = terminalID.uuidString
        return try await read { db in
            try AgentRunRecord.filter(Column("terminal_id") == key && Column("parent_run_id") == nil)
                .order(Column("started_at").desc, Column("id").desc).fetchAll(db).map { try $0.domain() }
        }
    }

    /// A execução principal mais recente de cada terminal (a UI semeia o estado de atividade com elas ao abrir).
    public func latestMainRuns() async throws -> [AgentRun] {
        try await read { db in
            try AgentRunRecord.fetchAll(db, sql: """
                SELECT r.* FROM agent_run r
                WHERE r.parent_run_id IS NULL AND r.terminal_id IS NOT NULL
                  AND r.id = (SELECT r2.id FROM agent_run r2 WHERE r2.terminal_id = r.terminal_id AND r2.parent_run_id IS NULL
                              ORDER BY r2.started_at DESC, r2.id DESC LIMIT 1)
                """).map { try $0.domain() }
        }
    }

    /// Execuções principais cuja projeção ficou para trás dos eventos gravados (crash entre os dois passos) ou que estão esperando
    /// subagentes: refazer a projeção com o redutor atual cura esperas presas (um subagente parado sem `SubagentStop`).
    public func runsNeedingReconcile() async throws -> [UUID] {
        try await read { db in
            try String.fetchAll(db, sql: """
                SELECT r.id FROM agent_run r
                WHERE r.parent_run_id IS NULL
                  AND ((SELECT MAX(e.at) FROM agent_event e WHERE e.run_id = r.id) > COALESCE(r.last_event_at, -1)
                       OR r.status = 'waiting_on_subagents')
                """).compactMap { UUID(uuidString: $0) }
        }
    }

    /// Retenção (08 §0.4): 30 dias **e** 10 mil eventos por execução. Devolve quantas linhas apagou.
    @discardableResult
    public func pruneAgentEvents(
        now: Date? = nil, maxAgeDays: Int = HookLimits.retentionDays, maxPerRun: Int = HookLimits.retentionMaxEventsPerRun
    ) async throws -> Int {
        let cutoff = RowCodec.ms((now ?? clock()).addingTimeInterval(-Double(maxAgeDays) * 86_400))
        return try await write { db in
            try db.execute(sql: "DELETE FROM agent_event WHERE at < ?", arguments: [cutoff])
            var removed = db.changesCount
            let heavy = try String.fetchAll(db, sql: "SELECT run_id FROM agent_event GROUP BY run_id HAVING COUNT(*) > ?", arguments: [maxPerRun])
            for run in heavy {
                try db.execute(sql: """
                    DELETE FROM agent_event WHERE run_id = ? AND seq NOT IN
                    (SELECT seq FROM agent_event WHERE run_id = ? ORDER BY at_ns DESC, seq DESC LIMIT ?)
                    """, arguments: [run, run, maxPerRun])
                removed += db.changesCount
            }
            return removed
        }
    }
}
