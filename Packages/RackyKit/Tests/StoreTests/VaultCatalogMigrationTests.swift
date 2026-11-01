import Foundation
import GRDB
import Testing
@testable import RackyStore

/// `v4_vault_catalog` (T2-10): migração encadeada sobre banco da versão anterior, sem alterar as migrações antigas.
@Suite struct VaultCatalogMigrationTests {
    private func readOnly(_ home: TempHome) throws -> DatabaseQueue {
        var config = Configuration()
        config.readonly = true
        return try DatabaseQueue(path: home.paths.databaseFile.path, configuration: config)
    }

    private let upToV3 = [StoreMigrations.v1Initial, StoreMigrations.v2Activity, StoreMigrations.v3Computers]

    @Test func migratesFromV3KeepingRowsAndAddingDefaults() async throws {
        let home = try TempHome(); defer { home.remove() }
        let before = try await home.openStore(day: 0, migrations: upToV3)
        try await before.write { db in
            try db.execute(sql: "INSERT INTO secret(id, name, ciphertext, nonce, key_version, created_at, updated_at) VALUES ('s1','OLD',x'0102',x'0304',1,1,1)")
            try db.execute(sql: "INSERT INTO catalog_item(id, source, kind, path, name, clients_json, discovered_at) VALUES ('c1','claude','agent','/a.md','a','[\"claude\"]',1)")
        }
        try await before.close()

        let after = try await home.openStore(day: 1)
        let mode = await after.mode
        #expect(mode == .readWrite && after.openNotices.isEmpty)
        try await after.close()

        #expect(home.backups.filter { $0.hasPrefix("pre-migration-v4_vault_catalog-") }.count == 1, "backup antes de migrar")
        let q = try readOnly(home)
        try await q.read { db in
            guard let secret = try Row.fetchOne(db, sql: "SELECT * FROM secret WHERE id = 's1'") else { Issue.record("secret row lost"); return }
            #expect(secret["name"] as String == "OLD" && secret["kind"] as String == "envVar" && secret["scope"] as String == "global"
                    && secret["delivery"] as String == "profileEnv")
            #expect((secret["expires_at"] as Int64?) == nil && (secret["imported_from"] as String?) == nil)
            guard let item = try Row.fetchOne(db, sql: "SELECT * FROM catalog_item WHERE id = 'c1'") else { Issue.record("catalog row lost"); return }
            #expect(item["scope"] as String == "user" && (item["frontmatter_json"] as String?) == nil && (item["shadowed_by"] as String?) == nil)
            let ids = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
            #expect(ids == ["v1_initial", "v2_activity", "v3_computers", "v4_vault_catalog", "v5_proxy_ext", "v6_agent_tree", "v7_subagent_computers", "v8_orchestration_identity", "v9_orchestration_pool", "v10_datasets", "v11_subagent_harness"])
        }
    }

    @Test func newConstraintsRejectInvalidValues() async throws {
        let home = try TempHome(); defer { home.remove() }
        let store = try await home.openStore()
        await #expect(throws: DatabaseError.self) {
            try await store.write { db in
                try db.execute(sql: "INSERT INTO secret(id, name, ciphertext, nonce, key_version, created_at, updated_at, kind) VALUES ('x','x',x'00',x'00',1,1,1,'nope')")
            }
        }
        await #expect(throws: DatabaseError.self) {
            try await store.write { db in
                try db.execute(sql: "INSERT INTO secret(id, name, ciphertext, nonce, key_version, created_at, updated_at, delivery) VALUES ('y','y',x'00',x'00',1,1,1,'carrier-pigeon')")
            }
        }
        await #expect(throws: DatabaseError.self) {
            try await store.write { db in
                try db.execute(sql: "INSERT INTO catalog_item(id, source, kind, path, name, discovered_at, frontmatter_json) VALUES ('z','claude','agent','/p','n',1,'{bad')")
            }
        }
        try await store.close()
    }

    @Test func secretStoreRoundTripsBindingsAndCascades() async throws {
        let home = try TempHome(); defer { home.remove() }
        let store = try await home.openStore()
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.insertSecret(StoredSecret(id: id, name: "A", ciphertext: Data([1, 2]), nonce: Data([3]), keyVersion: 1, createdAt: now, updatedAt: now))
        await #expect(throws: StoreError.self) {
            try await store.insertSecret(StoredSecret(id: UUID(), name: "A", ciphertext: Data(), nonce: Data(), keyVersion: 1, createdAt: now, updatedAt: now))
        }
        try await store.addSecretBinding(SecretBinding(secretID: id, targetKind: "profile", targetID: "p", envName: "A_KEY"))
        try await store.addSecretBinding(SecretBinding(secretID: id, targetKind: "profile", targetID: "p", envName: "A_KEY"))
        #expect(try await store.secretBindings(secretID: id).count == 1, "binding repetido é ignorado")
        try await store.deleteSecret(id: id)
        #expect(try await store.secretBindings(secretID: id).isEmpty)
        try await store.close()
    }
}
