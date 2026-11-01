import Foundation
import GRDB
import Testing
@testable import RackyStore

/// `v3_computers` (08 §3.2): migração sobre banco da versão anterior com dados, restrições do schema e FKs.
@Suite struct ComputersMigrationTests {
    private func readOnly(_ home: TempHome) throws -> DatabaseQueue {
        var config = Configuration()
        config.readonly = true
        return try DatabaseQueue(path: home.paths.databaseFile.path, configuration: config)
    }

    @Test func migratesFromV1FixtureKeepingDataAndBackingUpFirst() async throws {
        let home = try TempHome(); defer { home.remove() }
        let before = try await home.openStore(day: 0, migrations: [StoreMigrations.v1Initial, StoreMigrations.v2Activity])
        let project = Fixture.project()
        try await before.save(project)
        let session = Fixture.cleanSession()
        try await before.savePreV7(session)
        try await before.close()
        #expect(!(try tableNames(at: home.paths.databaseFile)).contains("computer"))

        let after = try await home.openStore(day: 1)
        let mode = await after.mode
        #expect(after.openNotices.isEmpty && mode == .readWrite)
        try await after.close()

        let backups = home.backups.filter { $0.hasPrefix("pre-migration-v3_computers-") }
        #expect(backups.count == 1)
        let backupURL = home.paths.backupsDirectory.appendingPathComponent(backups[0])
        let backupTables = try tableNames(at: backupURL)
        let backupProjects = try rowCount(at: backupURL, table: "project")
        #expect(!backupTables.contains("computer") && backupProjects == 1)
        #expect(try rowCount(at: home.paths.databaseFile, table: "project") == 1, "dados de N-1 preservados")
        #expect(try rowCount(at: home.paths.databaseFile, table: "session") == 1)
        for table in ["computer", "computer_queue", "browser_profile", "help_request", "proxy", "proxy_usage"] {
            #expect(try rowCount(at: home.paths.databaseFile, table: table) == 0, "\(table) criada vazia")
        }
    }

    @Test func proxyTablesHaveNoBudgetOrLimitColumns() async throws {
        let home = try TempHome(); defer { home.remove() }
        try await home.openStore().close()
        let queue = try readOnly(home)
        let proxy = try await queue.read { try Row.fetchAll($0, sql: "PRAGMA table_info(proxy)").map { $0["name"] as String } }
        let usage = try await queue.read { try Row.fetchAll($0, sql: "PRAGMA table_info(proxy_usage)").map { $0["name"] as String } }
        #expect(proxy == ["id", "name", "preset", "scheme", "host", "port", "username", "secret_id", "geo", "api_mode", "is_default", "created_at", "updated_at"])
        #expect(usage == ["id", "proxy_id", "computer_id", "period_start", "requests", "bytes", "cost_micros", "updated_at"])
        for name in proxy + usage { #expect(!name.contains("budget") && !name.contains("limit") && !name.contains("cap"), "P13: sem teto de orçamento") }
        let computer = try await queue.read { try Row.fetchAll($0, sql: "PRAGMA table_info(computer)").map { $0["name"] as String } }
        #expect(computer == ["id", "owner_run_id", "session_id", "name", "mode", "display", "persistent", "proxy_id", "browser_profile_id", "image_ref",
                             "image_digest", "network_name", "runtime_container_id", "egress_container_id", "work_container_id", "api_port", "vnc_port",
                             "egress_admin_port", "generation", "state", "created_at", "last_used_at", "expires_at", "removed_at"])
    }

    @Test func checkConstraintsRejectInvalidValues() async throws {
        let home = try TempHome(); defer { home.remove() }
        let store = try await home.openStore()
        let pool = store.writer
        func insertComputer(_ id: String, mode: String = "light", display: String = "headless", state: String = "queued") async throws {
            try await pool.write { db in
                try db.execute(sql: "INSERT INTO computer(id, name, mode, display, state, created_at) VALUES (?, 'phoenix-az', ?, ?, ?, 0)",
                               arguments: [id, mode, display, state])
            }
        }
        try await insertComputer("ok")
        await #expect(throws: DatabaseError.self) { try await insertComputer("bad-mode", mode: "remote") }
        await #expect(throws: DatabaseError.self) { try await insertComputer("bad-display", display: "vnc") }
        await #expect(throws: DatabaseError.self) { try await insertComputer("bad-state", state: "paused") }
        for state in ["queued", "provisioning", "ready", "in_use", "stopped", "failed", "removing", "removed", "orphan"] {
            try await insertComputer("s-\(state)", state: state)
        }
        await #expect(throws: DatabaseError.self) {
            try await pool.write { db in
                try db.execute(sql: "INSERT INTO proxy(id, name, scheme, host, port, created_at, updated_at) VALUES ('p', 'x', 'ftp', 'h', 80, 0, 0)")
            }
        }
        await #expect(throws: DatabaseError.self) {
            try await pool.write { db in
                try db.execute(sql: "INSERT INTO proxy(id, name, scheme, host, port, created_at, updated_at) VALUES ('p', 'x', 'http', 'h', 70000, 0, 0)")
            }
        }
        await #expect(throws: DatabaseError.self) {
            try await pool.write { db in
                try db.execute(sql: "INSERT INTO help_request(id, computer_id, kind, reason, created_at) VALUES ('h', 'ok', 'telepathy', 'r', 0)")
            }
        }
        await #expect(throws: DatabaseError.self) {
            try await pool.write { db in
                try db.execute(sql: "INSERT INTO help_request(id, computer_id, kind, reason, created_at) VALUES ('h', 'no-such-computer', 'captcha', 'r', 0)")
            }
        }
        await #expect(throws: DatabaseError.self) {
            try await pool.write { db in
                try db.execute(sql: "INSERT INTO browser_profile(id, name, volume, sites_json, created_at) VALUES ('b', 'n', 'v', '{oops', 0)")
            }
        }
        try await store.close()
    }

    @Test func foreignKeysCascadeOrNullAsDocumented() async throws {
        let home = try TempHome(); defer { home.remove() }
        let store = try await home.openStore()
        let pool = store.writer
        let session = Fixture.cleanSession()
        try await store.save(session)
        try await pool.write { db in
            try db.execute(sql: "INSERT INTO proxy(id, name, preset, scheme, host, port, api_mode, created_at, updated_at) VALUES ('px', 'Zyte', 'zyte', 'http', 'proxy.example', 8011, 1, 0, 0)")
            try db.execute(sql: "INSERT INTO computer(id, owner_run_id, session_id, name, display, proxy_id, state, created_at) VALUES ('c1', 'run-1', ?, 'phoenix-az', 'desktop', 'px', 'ready', 0)",
                           arguments: [session.id.uuidString])
            try db.execute(sql: "INSERT INTO browser_profile(id, name, volume, locked_by_computer_id, created_at) VALUES ('bp', 'listings', 'racky-profile-listings', 'c1', 0)")
            try db.execute(sql: "UPDATE computer SET browser_profile_id = 'bp' WHERE id = 'c1'")
            try db.execute(sql: "INSERT INTO computer_queue(id, computer_id, position, requested_at) VALUES ('q1', 'c1', 1, 0)")
            try db.execute(sql: "INSERT INTO help_request(id, computer_id, kind, reason, created_at) VALUES ('h1', 'c1', 'captcha', 'solve it', 0)")
            try db.execute(sql: "INSERT INTO proxy_usage(proxy_id, computer_id, period_start, requests, bytes, updated_at) VALUES ('px', 'c1', 100, 5, 1024, 0)")
            try db.execute(sql: "INSERT INTO proxy_usage(proxy_id, computer_id, period_start, requests, bytes, cost_micros, updated_at) VALUES ('px', NULL, 100, 7, 2048, 1500, 0)")
        }
        // Chave de uso é única por (proxy, computador, período); linhas sem computador (agregado) podem repetir.
        await #expect(throws: DatabaseError.self) {
            try await pool.write { db in
                try db.execute(sql: "INSERT INTO proxy_usage(proxy_id, computer_id, period_start, updated_at) VALUES ('px', 'c1', 100, 0)")
            }
        }
        // Fila: um item por computador.
        await #expect(throws: DatabaseError.self) {
            try await pool.write { db in
                try db.execute(sql: "INSERT INTO computer_queue(id, computer_id, position, requested_at) VALUES ('q2', 'c1', 2, 0)")
            }
        }
        // Remover a sessão não apaga o computador; remover o computador leva fila e pedidos junto e solta o lock do perfil.
        try await pool.write { db in try db.execute(sql: "DELETE FROM session WHERE id = ?", arguments: [session.id.uuidString]) }
        let sessionAfter = try await text(pool, "SELECT session_id FROM computer WHERE id = 'c1'")
        #expect(sessionAfter == nil)
        try await pool.write { db in try db.execute(sql: "DELETE FROM computer WHERE id = 'c1'") }
        let queued = try await scalar(pool, "SELECT COUNT(*) FROM computer_queue")
        let helps = try await scalar(pool, "SELECT COUNT(*) FROM help_request")
        let lock = try await text(pool, "SELECT locked_by_computer_id FROM browser_profile WHERE id = 'bp'")
        let orphanUsage = try await scalar(pool, "SELECT COUNT(*) FROM proxy_usage WHERE computer_id IS NULL")
        #expect(queued == 0 && helps == 0 && lock == nil)
        #expect(orphanUsage == 2, "uso do computador removido vira agregado sem dono")
        // Remover o proxy leva o uso e solta o computador.
        try await pool.write { db in
            try db.execute(sql: "INSERT INTO computer(id, name, display, proxy_id, created_at) VALUES ('c2', 'austin', 'http', 'px', 0)")
            try db.execute(sql: "DELETE FROM proxy WHERE id = 'px'")
        }
        let usageLeft = try await scalar(pool, "SELECT COUNT(*) FROM proxy_usage")
        let proxyLeft = try await text(pool, "SELECT proxy_id FROM computer WHERE id = 'c2'")
        #expect(usageLeft == 0 && proxyLeft == nil)
        try await store.close()
    }

    @Test func fullComputerRowRoundTripsEveryColumn() async throws {
        let home = try TempHome(); defer { home.remove() }
        let store = try await home.openStore()
        try await store.writer.write { db in
            try db.execute(sql: """
            INSERT INTO computer(id, owner_run_id, session_id, name, mode, display, persistent, proxy_id, browser_profile_id, image_ref, image_digest,
                network_name, runtime_container_id, egress_container_id, work_container_id, api_port, vnc_port, egress_admin_port, generation, state,
                created_at, last_used_at, expires_at, removed_at)
            VALUES ('c', 'r', NULL, 'n', 'isolated', 'headless', 1, NULL, NULL, 'racky-box:ctx-abc', 'sha256:d', 'racky-net-c', 'rt', 'eg', 'wk',
                50001, 50002, 50003, 4, 'in_use', 1, 2, 3, 4)
            """)
        }
        let writer = store.writer
        let mode = try await text(writer, "SELECT mode FROM computer WHERE id = 'c'")
        let generation = try await scalar(writer, "SELECT generation FROM computer WHERE id = 'c'")
        let adminPort = try await scalar(writer, "SELECT egress_admin_port FROM computer WHERE id = 'c'")
        let imageRef = try await text(writer, "SELECT image_ref FROM computer WHERE id = 'c'")
        let removedAt = try await scalar(writer, "SELECT removed_at FROM computer WHERE id = 'c'")
        #expect(mode == "isolated" && generation == 4 && adminPort == 50003)
        #expect(imageRef == "racky-box:ctx-abc" && removedAt == 4)
        try await store.close()
    }
}

private func scalar(_ writer: any DatabaseWriter, _ sql: String) async throws -> Int? {
    try await writer.read { try Int.fetchOne($0, sql: sql) }
}

private func text(_ writer: any DatabaseWriter, _ sql: String) async throws -> String? {
    try await writer.read { try String.fetchOne($0, sql: sql) }
}
