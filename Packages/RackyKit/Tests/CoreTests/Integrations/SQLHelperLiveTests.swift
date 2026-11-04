import Foundation
import Testing

@testable import RackyCore

/// Contra um servidor de verdade e o helper de verdade. Só roda com `RACKY_DB_LIVE_MYSQL` (uma URL mysql://) e `RACKY_DB_HELPER`
/// (o binário racky-db); o servidor precisa ter uma tabela `customers` (id, name) no banco da URL. Sem as variáveis, passa em branco.
@Suite(.tags(.integration)) struct SQLHelperLiveTests {
    @Test func mysqlEndToEnd() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let dsn = env["RACKY_DB_LIVE_MYSQL"], let helper = SQLHelperConnector.locateHelper() else { return }
        let connector = SQLHelperConnector(engine: .mysql, dsn: dsn)
        try await connector.check()
        let catalog = try await connector.catalog()
        let schema = try #require(catalog.first { $0.tables.contains { $0.name == "customers" } })
        let columns = try await connector.columns(schema: schema.name, table: "customers")
        #expect(columns.first?.name == "id" && columns.first?.isKey == true)
        let count = try await connector.rowCount(schema: schema.name, table: "customers")
        #expect(count.exact && count.value >= 1)
        let page = try await connector.rows(schema: schema.name, table: "customers", limit: 1, offset: 0, orderBy: ["id"])
        #expect(page.rows.count == 1 && page.truncated == (count.value > 1))
        #expect(try await connector.query(sql: "select count(*) from customers", limit: 10).rows.count == 1)
        do { _ = try await connector.query(sql: "delete from customers", limit: 10); Issue.record("a write must be refused") } catch {
            #expect(String(describing: error).contains("only reads"))
        }
        // A senha errada é "auth" e a mensagem não a repete.
        var wrong = URLComponents(string: dsn)
        wrong?.password = "definitely-wrong-pw"
        do { try await SQLHelperConnector(engine: .mysql, dsn: wrong?.string ?? dsn).check(); Issue.record("login must fail") } catch {
            guard case .auth(let message)? = error as? PostgresConnector.Failure else { Issue.record("wrong error \(error)"); return }
            #expect(!message.contains("definitely-wrong-pw"))
        }
        _ = helper
    }
}
