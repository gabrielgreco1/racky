import Foundation
import Testing

@testable import RackyCore

/// O conector do helper `racky-db` sem banco: um script de shell faz o papel do helper (lê o pedido no stdin, responde JSON) e
/// os testes conferem o que ele recebeu e como as respostas e falhas viram o que a área Data mostra.
struct SQLHelperConnectorTests {
    /// Cria um helper falso. `body` é o shell que responde; `$req` é o pedido inteiro. O script guarda o pedido, o argc e o
    /// ambiente em `<dir>/seen.*` para os testes olharem.
    static func fakeHelper(_ body: String) throws -> (helper: URL, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("racky-db-fake-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = """
            #!/bin/sh
            req=$(cat)
            printf '%s\\n' "$req" >> "\(dir.path)/seen.requests"
            printf '%s\\n' "$#" > "\(dir.path)/seen.argc"
            env > "\(dir.path)/seen.env"
            echo $$ > "\(dir.path)/seen.pid"
            \(body)
            """
        let url = dir.appendingPathComponent("racky-db")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return (url, dir)
    }

    static let dsn = "mysql://app:s3cret-pw@db.example:3306/shop"

    static let okScript = """
        case "$req" in
          *'"op":"check"'*) echo '{"ok":true}' ;;
          *'"op":"catalog"'*) echo '{"ok":true,"schemas":[{"name":"shop","tables":[{"name":"orders","isView":false,"estimatedRows":4200},{"name":"v_recent","isView":true,"estimatedRows":null}]},{"name":"empty","tables":[]}]}' ;;
          *'"op":"columns"'*) echo '{"ok":true,"columns":[{"name":"id","type":"int","nullable":false,"isKey":true},{"name":"note","type":"varchar(80)","nullable":true,"isKey":false}]}' ;;
          *'"op":"rowCount"'*) echo '{"ok":true,"rowCount":{"value":4200,"exact":false}}' ;;
          *'"op":"rows"'*) echo '{"ok":true,"result":{"columns":["id","note"],"rows":[["1","a"],["2","NULL"]],"truncated":true}}' ;;
          *'"op":"query"'*) echo '{"ok":true,"result":{"columns":["n"],"rows":[["1"]],"truncated":false}}' ;;
        esac
        """

    @Test func mapsEveryOperation() async throws {
        let (helper, dir) = try Self.fakeHelper(Self.okScript)
        defer { try? FileManager.default.removeItem(at: dir) }
        let connector = SQLHelperConnector(engine: .mysql, dsn: Self.dsn, helper: helper)

        try await connector.check()
        let catalog = try await connector.catalog()
        #expect(catalog.map(\.name) == ["shop", "empty"])
        #expect(catalog[0].tables == [
            PostgresTable(schema: "shop", name: "orders", isView: false, estimatedRows: 4200),
            PostgresTable(schema: "shop", name: "v_recent", isView: true, estimatedRows: nil),
        ])
        #expect(try await connector.schemas() == ["shop", "empty"])
        #expect(try await connector.tables(schema: "shop").count == 2)
        let columns = try await connector.columns(schema: "shop", table: "orders")
        #expect(columns == [PostgresColumn(name: "id", type: "int", nullable: false, isKey: true), PostgresColumn(name: "note", type: "varchar(80)", nullable: true, isKey: false)])
        #expect(try await connector.rowCount(schema: "shop", table: "orders") == PostgresRowCount(value: 4200, exact: false))
        let page = try await connector.rows(schema: "shop", table: "orders", limit: 1, offset: 200, orderBy: ["id"])
        #expect(page == PostgresResult(columns: ["id", "note"], rows: [["1", "a"], ["2", "NULL"]], truncated: true))
        #expect(try await connector.query(sql: "select 1", limit: 10).rows == [["1"]])
    }

    @Test func theRequestCarriesTheSecretOnStdinOnly() async throws {
        let (helper, dir) = try Self.fakeHelper(Self.okScript)
        defer { try? FileManager.default.removeItem(at: dir) }
        let connector = SQLHelperConnector(engine: .oracle, dsn: Self.dsn, helper: helper)
        _ = try await connector.rows(schema: "HR", table: "EMP", limit: 100, offset: 300, orderBy: ["ID", "NAME"])

        let seen = try String(contentsOf: dir.appendingPathComponent("seen.requests"), encoding: .utf8)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(seen.utf8)) as? [String: Any])
        #expect(json["op"] as? String == "rows" && json["engine"] as? String == "oracle" && json["dsn"] as? String == Self.dsn)
        #expect(json["schema"] as? String == "HR" && json["table"] as? String == "EMP" && json["limit"] as? Int == 100 && json["offset"] as? Int == 300)
        #expect(json["orderBy"] as? [String] == ["ID", "NAME"])
        // O helper recebe um prazo menor que o do app, para ele mesmo dizer "timeout".
        #expect((json["timeoutSeconds"] as? Double ?? 0) < PostgresConnector.operationDeadline)

        // Nada de segredo em argv nem no ambiente do helper.
        #expect(try String(contentsOf: dir.appendingPathComponent("seen.argc"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == "0")
        let env = try String(contentsOf: dir.appendingPathComponent("seen.env"), encoding: .utf8)
        #expect(!env.contains("s3cret-pw") && !env.contains("RACKY_"))
    }

    @Test func errorKindsBecomeFailures() async throws {
        func failure(_ kind: String, _ message: String) async throws -> PostgresConnector.Failure? {
            let (helper, dir) = try Self.fakeHelper("echo '{\"ok\":false,\"error\":{\"kind\":\"\(kind)\",\"message\":\"\(message)\"}}'")
            defer { try? FileManager.default.removeItem(at: dir) }
            do { try await SQLHelperConnector(engine: .sqlserver, dsn: Self.dsn, helper: helper).check(); return nil } catch { return error as? PostgresConnector.Failure }
        }
        #expect(try await failure("auth", "Login failed for user sa") == .auth("Login failed for user sa"))
        #expect(try await failure("unreachable", "connection refused") == .unreachable("connection refused"))
        #expect(try await failure("tls", "x509") == .tls("x509"))
        #expect(try await failure("timeout", "slow") == .timeout)
        #expect(try await failure("sql", "Table x does not exist") == .sql("Table x does not exist"))
        #expect(try await failure("invalid", "Racky only reads: DELETE is not allowed.") == .invalidConnectionString("Racky only reads: DELETE is not allowed."))
    }

    @Test func aWriteIsRefusedWithTheHelpersMessage() async throws {
        let (helper, dir) = try Self.fakeHelper(#"echo '{"ok":false,"error":{"kind":"invalid","message":"Racky only reads: DELETE is not allowed. Start with SELECT or WITH."}}'"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        let connector = SQLHelperConnector(engine: .mysql, dsn: Self.dsn, helper: helper)
        await #expect(throws: PostgresConnector.Failure.self) { _ = try await connector.query(sql: "delete from orders", limit: 10) }
        do { _ = try await connector.query(sql: "delete from orders", limit: 10) } catch { #expect(String(describing: error).contains("only reads")) }
    }

    @Test func aHelperThatDiesOrBabblesIsAnError() async throws {
        let (silent, dir1) = try Self.fakeHelper("exit 3")
        let (garbage, dir2) = try Self.fakeHelper("echo 'not json'")
        defer { try? FileManager.default.removeItem(at: dir1); try? FileManager.default.removeItem(at: dir2) }
        for helper in [silent, garbage] {
            do { try await SQLHelperConnector(engine: .mysql, dsn: Self.dsn, helper: helper).check(); Issue.record("should fail") } catch {
                guard case .unreachable? = error as? PostgresConnector.Failure else { Issue.record("wrong error \(error)"); continue }
            }
        }
    }

    @Test func aMissingHelperSaysSo() async throws {
        let connector = SQLHelperConnector(engine: .mysql, dsn: Self.dsn, helper: URL(fileURLWithPath: "/nonexistent/racky-db"))
        do { try await connector.check(); Issue.record("should fail") } catch {
            guard case .unreachable? = error as? PostgresConnector.Failure else { Issue.record("wrong error \(error)"); return }
        }
    }

    @Test func cancelingKillsTheHelperProcess() async throws {
        let (helper, dir) = try Self.fakeHelper("sleep 30")
        defer { try? FileManager.default.removeItem(at: dir) }
        let connector = SQLHelperConnector(engine: .mysql, dsn: Self.dsn, helper: helper)
        let task = Task { try await connector.check() }
        var pid = ""
        for _ in 0..<50 where pid.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
            pid = ((try? String(contentsOf: dir.appendingPathComponent("seen.pid"), encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #expect(!pid.isEmpty)
        let started = ContinuousClock.now
        task.cancel()
        _ = await task.result
        #expect(started.duration(to: .now) < .seconds(5))
        // O processo some logo depois (o `sleep` filho pode ficar, o shell do helper não).
        var alive = true
        for _ in 0..<30 where alive {
            try await Task.sleep(for: .milliseconds(100))
            alive = kill(pid_t(pid) ?? 0, 0) == 0
        }
        #expect(!alive)
    }

    @Test func theEnvironmentOverrideWins() throws {
        let (helper, dir) = try Self.fakeHelper("echo '{\"ok\":true}'")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(SQLHelperConnector.locateHelper(environment: [SQLHelperConnector.helperEnvironmentKey: helper.path]) == helper)
        #expect(SQLHelperConnector.locateHelper(environment: [SQLHelperConnector.helperEnvironmentKey: "/nonexistent/racky-db"]) == nil)
    }
}

struct SQLConnectionSpecTests {
    @Test func parsesMySQLURLs() throws {
        let spec = try SQLConnectionSpec(parsing: "mysql://app:p%40ss%2Fw@db.example:3307/shop?tls=disable", engine: .mysql)
        #expect(spec.host == "db.example" && spec.port == 3307 && spec.user == "app" && spec.password == "p@ss/w" && spec.database == "shop")
        #expect(spec.options == ["tls": "disable"])
        #expect(spec.displayAddress == "db.example:3307/shop" && !spec.displayAddress.contains("app"))
        // A URL canônica volta a dar o mesmo.
        #expect(try SQLConnectionSpec(parsing: spec.url, engine: .mysql) == spec)
        let maria = try SQLConnectionSpec(parsing: "mariadb://root@localhost", engine: .mysql)
        #expect(maria.port == 3306 && maria.database.isEmpty && maria.password == nil && maria.url == "mysql://root@localhost:3306")
        #expect(try SQLConnectionSpec(parsing: "mysql://u:a@b@host/db", engine: .mysql).password == "a@b")
    }

    @Test func parsesSQLServerURLsAndFields() throws {
        let url = try SQLConnectionSpec(parsing: "sqlserver://sa:Str0ng!pw@10.0.0.4:1433?database=sales&encrypt=false", engine: .sqlserver)
        #expect(url.database == "sales" && url.port == 1433 && url.options == ["encrypt": "false"])
        #expect(url.url == "sqlserver://sa:Str0ng%21pw@10.0.0.4:1433?database=sales&encrypt=false")
        // `/banco` no caminho também vale.
        #expect(try SQLConnectionSpec(parsing: "mssql://sa:x@h/sales", engine: .sqlserver).database == "sales")
        let fields = try SQLConnectionSpec(engine: .sqlserver, hostField: "sql.contoso.com", user: "sa", password: "pw", database: "sales")
        #expect(fields.port == 1433 && fields.displayAddress == "sql.contoso.com:1433/sales")
        #expect(throws: SQLConnectionSpec.ParseError.missingDatabase(.sqlserver)) {
            _ = try SQLConnectionSpec(engine: .sqlserver, hostField: "h", user: "u", password: "p", database: "")
        }
    }

    @Test func parsesOracleURLsAndEZConnect() throws {
        let url = try SQLConnectionSpec(parsing: "oracle://scott:tiger@ora.example:1522/FREEPDB1", engine: .oracle)
        #expect(url.port == 1522 && url.database == "FREEPDB1" && url.url == "oracle://scott:tiger@ora.example:1522/FREEPDB1")
        let ez = try SQLConnectionSpec(parsing: "scott/tiger@ora.example:1521/FREEPDB1", engine: .oracle)
        #expect(ez.host == "ora.example" && ez.user == "scott" && ez.password == "tiger" && ez.database == "FREEPDB1")
        let slashes = try SQLConnectionSpec(parsing: "scott/tiger@//ora.example/ORCL", engine: .oracle)
        #expect(slashes.port == 1521 && slashes.database == "ORCL")
        #expect(throws: SQLConnectionSpec.ParseError.missingDatabase(.oracle)) { _ = try SQLConnectionSpec(parsing: "oracle://u:p@h:1521", engine: .oracle) }
    }

    @Test func fieldsTakeAPortAfterTheHost() throws {
        let spec = try SQLConnectionSpec(engine: .mysql, hostField: " db.local:3310 ", user: "root", password: "", database: "")
        #expect(spec.host == "db.local" && spec.port == 3310 && spec.password == nil)
        #expect(throws: SQLConnectionSpec.ParseError.badPort("abc")) { _ = try SQLConnectionSpec(engine: .mysql, hostField: "h:abc", user: "u", password: nil, database: "") }
    }

    @Test func mistakesGetAClearMessage() {
        #expect(throws: SQLConnectionSpec.ParseError.empty) { _ = try SQLConnectionSpec(parsing: "  ", engine: .mysql) }
        #expect(throws: SQLConnectionSpec.ParseError.wrongScheme(.mysql)) { _ = try SQLConnectionSpec(parsing: "postgresql://u:p@h/d", engine: .mysql) }
        #expect(throws: SQLConnectionSpec.ParseError.wrongScheme(.sqlserver)) { _ = try SQLConnectionSpec(parsing: "host:1433", engine: .sqlserver) }
        #expect(throws: SQLConnectionSpec.ParseError.placeholder) { _ = try SQLConnectionSpec(parsing: "mysql://u:[password]@h/d", engine: .mysql) }
        #expect(throws: SQLConnectionSpec.ParseError.missingUser) { _ = try SQLConnectionSpec(parsing: "mysql://h/d", engine: .mysql) }
        #expect(throws: SQLConnectionSpec.ParseError.badPort("99999")) { _ = try SQLConnectionSpec(parsing: "mysql://u:p@h:99999/d", engine: .mysql) }
    }
}
