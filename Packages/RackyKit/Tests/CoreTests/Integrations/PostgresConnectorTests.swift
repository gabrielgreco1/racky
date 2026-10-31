import Foundation
import PostgresNIO
import Testing

@testable import RackyCore

/// Partes puras do conector Postgres, sem servidor: connection string, SQL só de leitura, decodificação das células e erros.
struct PostgresConnectorTests {
    // MARK: Connection string

    @Test func parsesASupabasePoolerString() throws {
        let info = try PostgresConnectionInfo(parsing: "postgresql://postgres.abcd:p%40ss%2Fw@aws-0-us-east-1.pooler.supabase.com:6543/postgres")
        #expect(info.host == "aws-0-us-east-1.pooler.supabase.com" && info.port == 6543)
        #expect(info.user == "postgres.abcd" && info.password == "p@ss/w" && info.database == "postgres")
        // Sem sslmode, TLS obrigatório.
        #expect(info.sslMode == .require)
        #expect(info.displayAddress == "aws-0-us-east-1.pooler.supabase.com:6543/postgres")
        #expect(!info.displayAddress.contains("ss"))
    }

    @Test func defaultsAndSSLModes() throws {
        let rds = try PostgresConnectionInfo(parsing: "postgres://u:p@mydb.x.us-east-1.rds.amazonaws.com/app?sslmode=verify-full&application_name=x")
        #expect(rds.port == 5432 && rds.sslMode == .verifyFull && rds.database == "app")
        let off = try PostgresConnectionInfo(parsing: "postgresql://u:p@localhost:5433/db?sslmode=disable")
        #expect(off.sslMode == .disable && off.port == 5433)
        let bare = try PostgresConnectionInfo(parsing: "postgresql://u@h")
        #expect(bare.password == nil && bare.database == "u" && bare.sslMode == .require)
        // Senha com @ sem escapar: o último @ separa o host.
        let raw = try PostgresConnectionInfo(parsing: "postgresql://u:a@b@host:5432/db")
        #expect(raw.password == "a@b" && raw.host == "host")
        let v6 = try PostgresConnectionInfo(parsing: "postgresql://u:p@[::1]:5433/db")
        #expect(v6.host == "::1" && v6.port == 5433)
    }

    @Test func rejectsBadStrings() {
        #expect(throws: PostgresConnectionInfo.ParseError.empty) { try PostgresConnectionInfo(parsing: "  ") }
        #expect(throws: PostgresConnectionInfo.ParseError.notPostgres) { try PostgresConnectionInfo(parsing: "mysql://u:p@h/db") }
        #expect(throws: PostgresConnectionInfo.ParseError.placeholder) {
            try PostgresConnectionInfo(parsing: "postgresql://postgres.[ref]:[YOUR-PASSWORD]@h:6543/postgres")
        }
        #expect(throws: PostgresConnectionInfo.ParseError.missingHost) { try PostgresConnectionInfo(parsing: "postgresql://u:p@/db") }
        #expect(throws: PostgresConnectionInfo.ParseError.missingUser) { try PostgresConnectionInfo(parsing: "postgresql://h:5432/db") }
        #expect(throws: PostgresConnectionInfo.ParseError.badPort("abc")) { try PostgresConnectionInfo(parsing: "postgresql://u:p@h:abc/db") }
        #expect(throws: PostgresConnectionInfo.ParseError.badSSLMode("maybe")) { try PostgresConnectionInfo(parsing: "postgresql://u:p@h/db?sslmode=maybe") }
    }

    @Test func connectorReportsAParseFailureAsATypedFailure() {
        #expect(throws: PostgresConnector.Failure.self) { try PostgresConnector(connectionString: "nope") }
    }

    // MARK: SQL

    @Test func quotesIdentifiers() {
        #expect(PostgresSQL.quoteIdentifier("users") == "\"users\"")
        #expect(PostgresSQL.quoteIdentifier("a\"; drop table x; --") == "\"a\"\"; drop table x; --\"")
    }

    @Test func wrapsEverythingInAReadOnlyTransaction() {
        let script = PostgresSQL.readOnlyScript(["select 1"])
        #expect(script == ["BEGIN READ ONLY", "SET LOCAL statement_timeout = 15000", "select 1", "ROLLBACK"])
        #expect(script.first == "BEGIN READ ONLY" && script.last == "ROLLBACK")
    }

    @Test func buildsAStablePageOfTextCells() {
        let sql = PostgresSQL.selectPage(schema: "public", table: "my\"t", columns: ["id", "Name"], limit: 100, offset: 200, orderBy: ["id"])
        #expect(sql == "SELECT t.\"id\"::text AS \"id\", t.\"Name\"::text AS \"Name\" FROM \"public\".\"my\"\"t\" AS t ORDER BY t.\"id\" LIMIT 100 OFFSET 200")
        #expect(PostgresSQL.selectPage(schema: "s", table: "t", columns: [], limit: 0, offset: -5, orderBy: []) == "SELECT * FROM \"s\".\"t\" AS t LIMIT 1 OFFSET 0")
    }

    @Test func cleansTrailingSemicolons() {
        #expect(PostgresSQL.clean("  select 1 ;; \n") == "select 1")
        #expect(PostgresSQL.clean(" ; ") == "")
    }

    @Test func shortensTypeNames() {
        #expect(PostgresSQL.shortType("timestamp with time zone") == "timestamptz")
        #expect(PostgresSQL.shortType("character varying(80)") == "varchar(80)")
        #expect(PostgresSQL.shortType("integer") == "int4")
        #expect(PostgresSQL.shortType("integer[]") == "int4[]")
        #expect(PostgresSQL.shortType("uuid") == "uuid")
    }

    // MARK: Células

    private func cell(_ type: PostgresDataType, _ buffer: ByteBuffer?, format: PostgresFormat = .binary) -> PostgresCell {
        PostgresCell(bytes: buffer, dataType: type, format: format, columnName: "c", columnIndex: 0)
    }

    @Test func decodesCellsToText() {
        #expect(PostgresCellText.string(cell(.text, nil)) == "NULL")
        #expect(PostgresCellText.string(cell(.text, ByteBuffer(string: "olá"))) == "olá")
        #expect(PostgresCellText.string(cell(.int4, ByteBuffer(integer: Int32(-7)))) == "-7")
        #expect(PostgresCellText.string(cell(.int8, ByteBuffer(integer: Int64(1 << 40)))) == "1099511627776")
        #expect(PostgresCellText.string(cell(.bool, ByteBuffer(integer: UInt8(1)))) == "true")
        #expect(PostgresCellText.string(cell(.bytea, ByteBuffer(bytes: [0xde, 0xad]))) == "\\xdead")
        // Sem decodificador, em formato texto: o texto como veio.
        #expect(PostgresCellText.string(cell(.inet, ByteBuffer(string: "10.0.0.1/32"), format: .text)) == "10.0.0.1/32")
    }

    @Test func formatsDatesInUTC() {
        let date = Date(timeIntervalSince1970: 1_792_670_344)  // 2026-10-22 11:59:04 UTC
        #expect(PostgresCellText.format(date, dateOnly: false) == "2026-10-22 11:59:04+00")
        #expect(PostgresCellText.format(date, dateOnly: true) == "2026-10-22")
    }

    // MARK: Erros

    @Test func mapsServerErrors() {
        #expect(PostgresConnector.Failure.fromServer(sqlState: "28P01", message: "bad") == .auth("bad"))
        #expect(PostgresConnector.Failure.fromServer(sqlState: "57014", message: "canceling statement") == .timeout)
        #expect(PostgresConnector.Failure.fromServer(sqlState: "25006", message: "cannot execute INSERT in a read-only transaction")
            == .sql("cannot execute INSERT in a read-only transaction"))
        #expect(PostgresConnector.map(CancellationError()) == .timeout)
        #expect(PostgresConnector.map(PostgresConnector.Failure.timeout) == .timeout)
    }
}
