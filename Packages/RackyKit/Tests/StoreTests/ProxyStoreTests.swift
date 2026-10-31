import RackyProtocol
import Foundation
import GRDB
import Testing
@testable import RackyStore

/// `v5_proxy_ext` (migração nova, encadeada após `v3_computers`) e a persistência de `ProxyProfile` (T3-02, P13).
@Suite struct ProxyStoreTests {
    private func sample(_ name: String = "zyte-us", default isDefault: Bool = false) -> ProxyProfile {
        ProxyProfile(
            name: name, preset: .zyte, scheme: .http, host: "proxy.zyte.com", port: 8011, username: nil, secretID: "proxy-abc",
            secretStorage: .vault, geo: ProxyGeo(country: "us", mode: .suffix, template: "-country-{cc}"), apiMode: true,
            renderEndpoint: "https://api.zyte.com/v1/extract", caPEM: "-----BEGIN CERTIFICATE-----\nX\n-----END CERTIFICATE-----",
            pricePerRequestMicros: 130, pricePerRenderMicros: 1500, isDefault: isDefault, createdAt: Fixture.t0)
    }

    @Test func v4IsChainedAfterV3AndOlderMigrationsAreUntouched() {
        let ids = StoreMigrations.all.map(\.id)
        #expect(ids == ["v1_initial", "v2_activity", "v3_computers", "v4_vault_catalog", "v5_proxy_ext", "v6_agent_tree", "v7_subagent_computers", "v8_orchestration_identity", "v9_orchestration_pool", "v10_datasets", "v11_subagent_harness"])
    }

    @Test func migratesFromV3KeepingDataAndBackingUpFirst() async throws {
        let home = try TempHome(); defer { home.remove() }
        let v3 = [StoreMigrations.v1Initial, StoreMigrations.v2Activity, StoreMigrations.v3Computers, StoreMigrations.v4VaultCatalog]
        let before = try await home.openStore(day: 0, migrations: v3)
        try await before.save(Fixture.project())
        // um proxy gravado direto na tabela de v3 (sem proxy_ext), como existiria antes da T3-02
        let id = UUID()
        try await before.writer.write { db in
            try db.execute(sql: "INSERT INTO proxy (id, name, preset, scheme, host, port, username, created_at, updated_at) VALUES (?, 'legacy', 'custom', 'socks5', 'h.example', 1080, 'u', 1, 1)", arguments: [id.uuidString])
        }
        try await before.close()
        #expect(!(try tableNames(at: home.paths.databaseFile)).contains("proxy_ext"))

        let after = try await home.openStore(day: 1)
        #expect(after.openNotices.isEmpty)
        let legacy = try #require(try await after.proxy(id: id))
        #expect(legacy.name == "legacy" && legacy.scheme == .socks5 && legacy.secretStorage == .vault && legacy.geo == nil && legacy.caPEM == nil)
        #expect(try await after.projects().count == 1, "dados de N-1 preservados")
        try await after.close()
        #expect(home.backups.filter { $0.hasPrefix("pre-migration-v5_proxy_ext-") }.count == 1)
        #expect(try tableNames(at: home.paths.databaseFile).contains("proxy_ext"))
    }

    @Test func roundTripKeepsEveryFieldAndNeverStoresTheSecretValue() async throws {
        let home = try TempHome(); defer { home.remove() }
        let store = try await home.openStore()
        let profile = sample()
        try await store.save(profile)
        let loaded = try #require(try await store.proxy(id: profile.id))
        #expect(loaded == profile)
        #expect(try await store.proxy(named: "zyte-us")?.id == profile.id)
        #expect(try await store.proxies().map(\.name) == ["zyte-us"])
        // o banco só guarda a REFERÊNCIA ao segredo
        let columns = try await store.writer.read { try Row.fetchAll($0, sql: "PRAGMA table_info(proxy)").map { $0["name"] as String } }
        #expect(!columns.contains { $0.contains("password") || $0.contains("key") || $0.contains("token") })
        try await store.close()
    }

    @Test func proxyExtHasNoBudgetOrLimitColumns() async throws {
        let home = try TempHome(); defer { home.remove() }
        try await home.openStore().close()
        var config = Configuration()
        config.readonly = true
        let queue = try DatabaseQueue(path: home.paths.databaseFile.path, configuration: config)
        let names = try await queue.read { try Row.fetchAll($0, sql: "PRAGMA table_info(proxy_ext)").map { $0["name"] as String } }
        #expect(names == ["proxy_id", "secret_storage", "geo_json", "render_endpoint", "ca_pem", "price_per_request_micros", "price_per_render_micros"])
        for name in names { #expect(!name.contains("budget") && !name.contains("limit") && !name.contains("cap_"), "P13: sem teto de orçamento") }
    }

    @Test func onlyOneDefaultProxyAndDefaultCanBeCleared() async throws {
        let home = try TempHome(); defer { home.remove() }
        let store = try await home.openStore()
        let a = sample("a", default: true), b = sample("b")
        try await store.save(a)
        try await store.save(b)
        #expect(try await store.defaultProxy()?.id == a.id)
        try await store.setDefaultProxy(id: b.id)
        #expect(try await store.defaultProxy()?.id == b.id)
        var a2 = a
        a2.isDefault = true
        try await store.save(a2)  // salvar com isDefault passa o padrão para ele
        #expect(try await store.defaultProxy()?.id == a.id)
        #expect(try await store.proxies().filter(\.isDefault).count == 1)
        try await store.setDefaultProxy(id: nil)
        #expect(try await store.defaultProxy() == nil, "padrão global volta a `direct`")
        try await store.close()
    }

    @Test func validationRejectsBadNameAndPort() async throws {
        let home = try TempHome(); defer { home.remove() }
        let store = try await home.openStore()
        var bad = sample()
        bad.port = 70000
        await #expect(throws: StoreError.self) { try await store.save(bad) }
        bad.port = 8011
        bad.name = "  "
        await #expect(throws: StoreError.self) { try await store.save(bad) }
        let a = sample("dup"), b = sample("dup")
        try await store.save(a)
        await #expect(throws: (any Error).self) { try await store.save(b) }  // nome único
        try await store.close()
    }

    @Test func usageAccumulatesPerDayAndComputerWithoutAnyCutoff() async throws {
        let home = try TempHome(); defer { home.remove() }
        let store = try await home.openStore()
        let proxy = sample()
        try await store.save(proxy)
        let computerA = UUID(), day = Date(timeIntervalSince1970: 1_800_000_000 - 1_800_000_000.truncatingRemainder(dividingBy: 86_400))
        try await store.writer.write { db in
            for id in [computerA] {
                try db.execute(sql: "INSERT INTO computer (id, name, display, created_at) VALUES (?, 'c', 'http', 1)", arguments: [id.uuidString])
            }
        }
        for _ in 0..<1000 {  // "10 mil requests" não corta nada: só soma
            try await store.addProxyUsage(proxyID: proxy.id, computerID: computerA, periodStart: day, requests: 10, bytes: 1_000)
        }
        try await store.addProxyUsage(proxyID: proxy.id, computerID: nil, periodStart: day, requests: 5, bytes: 50, costMicros: 650)
        try await store.addProxyUsage(proxyID: proxy.id, computerID: nil, periodStart: day, requests: 5, bytes: 50, costMicros: 650)
        let rows = try await store.proxyUsage(proxyID: proxy.id)
        let perComputer = try #require(rows.first { $0.computerID == computerA })
        #expect(perComputer.requests == 10_000 && perComputer.bytes == 1_000_000 && perComputer.costMicros == nil)
        let aggregate = try #require(rows.first { $0.computerID == nil })
        #expect(aggregate.requests == 10 && aggregate.costMicros == 1300)
        #expect(try await store.proxyUsage(proxyID: proxy.id, since: day.addingTimeInterval(86_400)).isEmpty)
        try await store.close()
    }

    @Test func deleteCascadesExtAndUsageAndDetachesComputers() async throws {
        let home = try TempHome(); defer { home.remove() }
        let store = try await home.openStore()
        let proxy = sample()
        try await store.save(proxy)
        let computer = UUID()
        try await store.writer.write { db in
            try db.execute(sql: "INSERT INTO computer (id, name, display, proxy_id, created_at) VALUES (?, 'c', 'http', ?, 1)", arguments: [computer.uuidString, proxy.id.uuidString])
        }
        try await store.addProxyUsage(proxyID: proxy.id, computerID: computer, periodStart: Fixture.t0, requests: 1, bytes: 1)
        try await store.deleteProxy(id: proxy.id)
        #expect(try await store.proxy(id: proxy.id) == nil)
        let counts = try await store.writer.read { db -> (Int, Int, String?) in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM proxy_ext") ?? -1, try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM proxy_usage") ?? -1,
             try String.fetchOne(db, sql: "SELECT proxy_id FROM computer WHERE id = ?", arguments: [computer.uuidString]))
        }
        #expect(counts.0 == 0 && counts.1 == 0 && counts.2 == nil, "computador volta a `direct` (proxy_id nulo)")
        try await store.close()
    }
}
