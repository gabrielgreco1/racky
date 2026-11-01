import Foundation
import Testing
@testable import RackyCore

/// Contra um Postgres de verdade, só quando `RACKY_PG_TEST_URL` aponta para um (ex.: um `initdb` temporário com TLS). Sem a
/// variável, a suíte não roda. Espera o schema `shop` com `books` (250 linhas, PK) e a view `cheap`, e `public.nopk` sem PK.
@Suite(.tags(.integration), .serialized, .enabled(if: ProcessInfo.processInfo.environment["RACKY_PG_TEST_URL"] != nil))
struct PostgresLiveTests {
    private var connector: PostgresConnector {
        get throws { try PostgresConnector(connectionString: ProcessInfo.processInfo.environment["RACKY_PG_TEST_URL"] ?? "") }
    }

    @Test func checkAndCatalogOverTLS() async throws {
        let c = try connector
        try await c.check()
        let catalog = try await c.catalog()
        let shop = try #require(catalog.first { $0.name == "shop" })
        #expect(shop.tables.contains { $0.name == "books" && !$0.isView })
        #expect(shop.tables.contains { $0.name == "cheap" && $0.isView })
        #expect(catalog.contains { $0.name == "public" && $0.tables.contains { $0.name == "nopk" } })
    }

    @Test func columnsCountAndPagedRows() async throws {
        let c = try connector
        let columns = try await c.columns(schema: "shop", table: "books")
        #expect(columns.map(\.name) == ["id", "title", "price", "added", "tags"])
        #expect(columns.first?.isKey == true)
        let count = try await c.rowCount(schema: "shop", table: "books")
        #expect(count.value == 250 && count.exact)
        let page2 = try await c.rows(schema: "shop", table: "books", limit: 100, offset: 100, orderBy: ["id"])
        #expect(page2.rows.count == 100)
        #expect(page2.rows.first?.first == "101")
        let noKey = try await c.rows(schema: "public", table: "nopk", limit: 100, offset: 0, orderBy: [])
        #expect(noKey.rows.count == 2)
        #expect(noKey.rows.contains { $0.contains("{\"k\": 1}") || $0.contains("{\"k\":1}") })
    }

    @Test func queryIsReadOnly() async throws {
        let c = try connector
        let result = try await c.query(sql: "select title, price from shop.books where id <= 3 order by id", limit: 1000)
        #expect(result.columns == ["title", "price"])
        #expect(result.rows.count == 3)
        await #expect(throws: (any Error).self) { _ = try await c.query(sql: "delete from shop.books", limit: 10) }
        let after = try await c.rowCount(schema: "shop", table: "books")
        #expect(after.value == 250, "a escrita não pode ter passado")
    }

    @Test func wrongPasswordIsAnAuthFailure() async throws {
        let url = (ProcessInfo.processInfo.environment["RACKY_PG_TEST_URL"] ?? "").replacingOccurrences(of: ":testpass@", with: ":wrong@")
        let c = try PostgresConnector(connectionString: url)
        await #expect(throws: (any Error).self) { try await c.check() }
    }
}
