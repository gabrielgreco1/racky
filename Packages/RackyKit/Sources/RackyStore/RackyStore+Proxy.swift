import RackyProtocol
import Foundation
import GRDB

// Persistência de proxies (T3-02, 07 §2.6, P13). A senha/chave NUNCA entra aqui: só `secret_id` (referência).
// Sem coluna ou regra de orçamento: o app configura, registra e mostra uso.

extension RackyStore {
    public func save(_ proxy: ProxyProfile) async throws {
        guard !proxy.name.trimmingCharacters(in: .whitespaces).isEmpty else { throw StoreError.invalidModel("proxy sem nome") }
        guard (1...65535).contains(proxy.port) else { throw StoreError.invalidModel("porta de proxy inválida: \(proxy.port)") }
        let record = ProxyRecord(proxy), ext = try ProxyExtRecord(proxy), id = record.id, isDefault = proxy.isDefault
        try await write { db in
            try record.save(db)
            try ext.save(db)
            if isDefault { try db.execute(sql: "UPDATE proxy SET is_default = 0 WHERE id <> ?", arguments: [id]) }
        }
    }

    public func proxies() async throws -> [ProxyProfile] {
        try await read { db in
            let exts = Dictionary(uniqueKeysWithValues: try ProxyExtRecord.fetchAll(db).map { ($0.proxyId, $0) })
            return try ProxyRecord.order(Column("name")).fetchAll(db).map { try $0.domain(ext: exts[$0.id]) }
        }
    }

    public func proxy(id: UUID) async throws -> ProxyProfile? {
        let key = id.uuidString
        return try await read { db in
            guard let record = try ProxyRecord.fetchOne(db, key: key) else { return nil }
            return try record.domain(ext: try ProxyExtRecord.fetchOne(db, key: key))
        }
    }

    public func proxy(named name: String) async throws -> ProxyProfile? {
        try await read { db in
            guard let record = try ProxyRecord.filter(Column("name") == name).fetchOne(db) else { return nil }
            return try record.domain(ext: try ProxyExtRecord.fetchOne(db, key: record.id))
        }
    }

    /// Proxy padrão global (Settings, CS-161). `nil` = `direct`.
    public func defaultProxy() async throws -> ProxyProfile? {
        try await read { db in
            guard let record = try ProxyRecord.filter(Column("is_default") == 1).fetchOne(db) else { return nil }
            return try record.domain(ext: try ProxyExtRecord.fetchOne(db, key: record.id))
        }
    }

    public func setDefaultProxy(id: UUID?) async throws {
        let key = id?.uuidString
        try await write { db in
            try db.execute(sql: "UPDATE proxy SET is_default = 0")
            if let key { try db.execute(sql: "UPDATE proxy SET is_default = 1 WHERE id = ?", arguments: [key]) }
        }
    }

    /// Apaga o perfil (`proxy_ext` e `proxy_usage` em cascata; computadores que o usavam ficam com `proxy_id` nulo = `direct`).
    /// Quem chama remove também o segredo do armazenamento.
    public func deleteProxy(id: UUID) async throws {
        let key = id.uuidString
        try await write { _ = try ProxyRecord.deleteOne($0, key: key) }
    }

    /// Soma ao uso do período (espelho do contador do egress, CS-162). `periodStart` = início do dia (UTC).
    public func addProxyUsage(proxyID: UUID, computerID: UUID?, periodStart: Date, requests: Int, bytes: Int, costMicros: Int64? = nil) async throws {
        let proxy = proxyID.uuidString, computer = computerID?.uuidString, period = Int64(periodStart.timeIntervalSince1970), now = RowCodec.ms(clock())
        try await write { db in
            let existing = try Row.fetchOne(
                db, sql: "SELECT id FROM proxy_usage WHERE proxy_id = ? AND period_start = ? AND computer_id IS ?", arguments: [proxy, period, computer])
            if let id: Int64 = existing?["id"] {
                try db.execute(
                    sql: "UPDATE proxy_usage SET requests = requests + ?, bytes = bytes + ?, cost_micros = CASE WHEN ? IS NULL THEN cost_micros ELSE COALESCE(cost_micros, 0) + ? END, updated_at = ? WHERE id = ?",
                    arguments: [requests, bytes, costMicros, costMicros, now, id])
            } else {
                try db.execute(
                    sql: "INSERT INTO proxy_usage (proxy_id, computer_id, period_start, requests, bytes, cost_micros, updated_at) VALUES (?,?,?,?,?,?,?)",
                    arguments: [proxy, computer, period, requests, bytes, costMicros, now])
            }
        }
    }

    public func proxyUsage(proxyID: UUID? = nil, since: Date? = nil) async throws -> [ProxyUsageRow] {
        let proxy = proxyID?.uuidString, from = since.map { Int64($0.timeIntervalSince1970) }
        return try await read { db in
            var sql = "SELECT proxy_id, computer_id, period_start, requests, bytes, cost_micros FROM proxy_usage WHERE 1=1"
            var args: [(any DatabaseValueConvertible)?] = []
            if let proxy { sql += " AND proxy_id = ?"; args.append(proxy) }
            if let from { sql += " AND period_start >= ?"; args.append(from) }
            sql += " ORDER BY period_start, id"
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map { row in
                ProxyUsageRow(
                    proxyID: try RowCodec.id(row["proxy_id"] as String, table: "proxy_usage"),
                    computerID: try RowCodec.id(row["computer_id"] as String?, table: "proxy_usage"),
                    periodStart: Date(timeIntervalSince1970: Double(row["period_start"] as Int64)),
                    requests: row["requests"], bytes: row["bytes"], costMicros: row["cost_micros"])
            }
        }
    }
}
