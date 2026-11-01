import Foundation
import GRDB

// Persistência de segredos (`secret`, `secret_binding`; 08 AR-311/511). O store só guarda ciphertext: quem cifra e
// decifra é o Vault (Core). Nenhum valor em claro passa por aqui.

public struct StoredSecret: Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var defaultEnvName: String?
    public var ciphertext: Data
    public var nonce: Data
    public var keyVersion: Int
    public var note: String?
    public var kind: String
    public var scope: String
    public var delivery: String
    public var createdAt: Date
    public var updatedAt: Date
    public var lastUsedAt: Date?
    public var expiresAt: Date?
    public var importedFrom: String?

    public init(id: UUID, name: String, defaultEnvName: String? = nil, ciphertext: Data, nonce: Data, keyVersion: Int,
                note: String? = nil, kind: String = "envVar", scope: String = "global", delivery: String = "profileEnv",
                createdAt: Date, updatedAt: Date, lastUsedAt: Date? = nil, expiresAt: Date? = nil, importedFrom: String? = nil) {
        self.id = id; self.name = name; self.defaultEnvName = defaultEnvName; self.ciphertext = ciphertext
        self.nonce = nonce; self.keyVersion = keyVersion; self.note = note; self.kind = kind; self.scope = scope
        self.delivery = delivery; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt; self.expiresAt = expiresAt; self.importedFrom = importedFrom
    }

    init(row: Row) throws {
        id = try RowCodec.id(row["id"] as String, table: "secret")
        name = row["name"]; defaultEnvName = row["default_env_name"]
        ciphertext = row["ciphertext"]; nonce = row["nonce"]; keyVersion = row["key_version"]
        note = row["note"]; kind = row["kind"]; scope = row["scope"]; delivery = row["delivery"]
        createdAt = RowCodec.date(row["created_at"] as Int64); updatedAt = RowCodec.date(row["updated_at"] as Int64)
        lastUsedAt = RowCodec.date(row["last_used_at"] as Int64?)
        expiresAt = RowCodec.date(row["expires_at"] as Int64?)
        importedFrom = row["imported_from"]
    }
}

public struct SecretBinding: Sendable, Equatable, Hashable {
    public var secretID: UUID
    public var targetKind: String   // profile | session | computer | proxy
    public var targetID: String
    public var envName: String
    public init(secretID: UUID, targetKind: String, targetID: String, envName: String) {
        self.secretID = secretID; self.targetKind = targetKind; self.targetID = targetID; self.envName = envName
    }
}

public struct ReencryptedSecret: Sendable {
    public var id: UUID
    public var ciphertext: Data
    public var nonce: Data
    public var keyVersion: Int
    public init(id: UUID, ciphertext: Data, nonce: Data, keyVersion: Int) {
        self.id = id; self.ciphertext = ciphertext; self.nonce = nonce; self.keyVersion = keyVersion
    }
}

extension RackyStore {
    private static let secretColumns = """
        id, name, default_env_name, ciphertext, nonce, key_version, note, kind, scope, delivery,
        created_at, updated_at, last_used_at, expires_at, imported_from
        """

    /// `StoreError.invalidModel` se o nome já existe.
    public func insertSecret(_ s: StoredSecret) async throws {
        let created = RowCodec.ms(s.createdAt), updated = RowCodec.ms(s.updatedAt)
        let used: Int64? = RowCodec.ms(s.lastUsedAt), expires: Int64? = RowCodec.ms(s.expiresAt)
        try await write { db in
            if try Int.fetchOne(db, sql: "SELECT 1 FROM secret WHERE name = ?", arguments: [s.name]) != nil {
                throw StoreError.invalidModel("secret name already exists")
            }
            try db.execute(sql: """
                INSERT INTO secret(id, name, default_env_name, ciphertext, nonce, key_version, note, kind, scope, delivery,
                                   created_at, updated_at, last_used_at, expires_at, imported_from)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, arguments: [s.id.uuidString, s.name, s.defaultEnvName, s.ciphertext, s.nonce, s.keyVersion, s.note,
                                 s.kind, s.scope, s.delivery, created, updated, used, expires, s.importedFrom])
        }
    }

    public func secrets() async throws -> [StoredSecret] {
        try await read { db in
            try Row.fetchAll(db, sql: "SELECT \(Self.secretColumns) FROM secret ORDER BY name").map(StoredSecret.init(row:))
        }
    }

    public func secret(id: UUID) async throws -> StoredSecret? {
        let key = id.uuidString
        return try await read { db in
            try Row.fetchOne(db, sql: "SELECT \(Self.secretColumns) FROM secret WHERE id = ?", arguments: [key]).map(StoredSecret.init(row:))
        }
    }

    public func secret(named name: String) async throws -> StoredSecret? {
        try await read { db in
            try Row.fetchOne(db, sql: "SELECT \(Self.secretColumns) FROM secret WHERE name = ?", arguments: [name]).map(StoredSecret.init(row:))
        }
    }

    /// Troca ciphertext/nonce/versão de um segredo (rotação de valor).
    public func updateSecretCipher(id: UUID, ciphertext: Data, nonce: Data, keyVersion: Int, at date: Date) async throws {
        let key = id.uuidString, ms: Int64 = RowCodec.ms(date)
        try await write { db in
            try db.execute(sql: "UPDATE secret SET ciphertext = ?, nonce = ?, key_version = ?, updated_at = ? WHERE id = ?",
                           arguments: [ciphertext, nonce, keyVersion, ms, key])
            guard db.changesCount == 1 else { throw StoreError.invalidModel("unknown secret") }
        }
    }

    public func updateSecretMetadata(id: UUID, defaultEnvName: String?, note: String?, expiresAt: Date?, at date: Date) async throws {
        let key = id.uuidString, ms: Int64 = RowCodec.ms(date), exp: Int64? = RowCodec.ms(expiresAt)
        try await write { db in
            try db.execute(sql: "UPDATE secret SET default_env_name = ?, note = ?, expires_at = ?, updated_at = ? WHERE id = ?",
                           arguments: [defaultEnvName, note, exp, ms, key])
            guard db.changesCount == 1 else { throw StoreError.invalidModel("unknown secret") }
        }
    }

    public func deleteSecret(id: UUID) async throws {
        let key = id.uuidString
        try await write { db in try db.execute(sql: "DELETE FROM secret WHERE id = ?", arguments: [key]) }
    }

    public func touchSecrets(ids: [UUID], at date: Date) async throws {
        let keys = ids.map(\.uuidString), ms: Int64 = RowCodec.ms(date)
        try await write { db in
            for k in keys { try db.execute(sql: "UPDATE secret SET last_used_at = ? WHERE id = ?", arguments: [ms, k]) }
        }
    }

    /// Reescreve vários ciphertexts numa só transação (rotação de `key_version`): ou todos ou nenhum.
    public func replaceSecretCiphers(_ items: [ReencryptedSecret]) async throws {
        try await write { db in
            for i in items {
                try db.execute(sql: "UPDATE secret SET ciphertext = ?, nonce = ?, key_version = ? WHERE id = ?",
                               arguments: [i.ciphertext, i.nonce, i.keyVersion, i.id.uuidString])
            }
        }
    }

    // MARK: Bindings

    public func addSecretBinding(_ b: SecretBinding) async throws {
        try await write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO secret_binding(secret_id, target_kind, target_id, env_name) VALUES (?,?,?,?)",
                           arguments: [b.secretID.uuidString, b.targetKind, b.targetID, b.envName])
        }
    }

    public func removeSecretBinding(_ b: SecretBinding) async throws {
        try await write { db in
            try db.execute(sql: "DELETE FROM secret_binding WHERE secret_id = ? AND target_kind = ? AND target_id = ? AND env_name = ?",
                           arguments: [b.secretID.uuidString, b.targetKind, b.targetID, b.envName])
        }
    }

    public func secretBindings(targetKind: String, targetID: String) async throws -> [SecretBinding] {
        try await read { db in
            try Row.fetchAll(db, sql: """
                SELECT secret_id, target_kind, target_id, env_name FROM secret_binding
                WHERE target_kind = ? AND target_id = ? ORDER BY env_name
                """, arguments: [targetKind, targetID]).map {
                SecretBinding(secretID: try RowCodec.id($0["secret_id"] as String, table: "secret_binding"),
                              targetKind: $0["target_kind"], targetID: $0["target_id"], envName: $0["env_name"])
            }
        }
    }

    public func secretBindings(secretID: UUID) async throws -> [SecretBinding] {
        let key = secretID.uuidString
        return try await read { db in
            try Row.fetchAll(db, sql: """
                SELECT secret_id, target_kind, target_id, env_name FROM secret_binding
                WHERE secret_id = ? ORDER BY target_kind, target_id, env_name
                """, arguments: [key]).map {
                SecretBinding(secretID: try RowCodec.id($0["secret_id"] as String, table: "secret_binding"),
                              targetKind: $0["target_kind"], targetID: $0["target_id"], envName: $0["env_name"])
            }
        }
    }
}
