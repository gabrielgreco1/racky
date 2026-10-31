import Foundation
import PostgresNIO

/// O que a área Data precisa de um Postgres (PostgreSQL, RDS, Supabase): validar, listar schemas, tabelas e colunas, ler linhas e
/// rodar SQL só de leitura. Um protocolo para os testes trocarem o servidor por um falso.
public protocol PostgresBrowsing: Sendable {
    func check() async throws
    func schemas() async throws -> [String]
    func tables(schema: String) async throws -> [PostgresTable]
    /// Todos os schemas com suas tabelas, numa conexão só (é o que o explorer mostra).
    func catalog() async throws -> [PostgresSchema]
    func columns(schema: String, table: String) async throws -> [PostgresColumn]
    func rowCount(schema: String, table: String) async throws -> PostgresRowCount
    func rows(schema: String, table: String, limit: Int, offset: Int, orderBy: [String]) async throws -> PostgresResult
    func query(sql: String, limit: Int) async throws -> PostgresResult
}

public struct PostgresTable: Sendable, Equatable {
    public var schema: String
    public var name: String
    /// View (comum ou materializada) em vez de tabela.
    public var isView: Bool
    /// Linhas estimadas pelo `pg_class.reltuples` (`nil` = o servidor nunca analisou a tabela, ou é uma view).
    public var estimatedRows: Int?

    public init(schema: String, name: String, isView: Bool, estimatedRows: Int?) {
        self.schema = schema; self.name = name; self.isView = isView; self.estimatedRows = estimatedRows
    }
}

public struct PostgresSchema: Sendable, Equatable {
    public var name: String
    public var tables: [PostgresTable]
    public init(name: String, tables: [PostgresTable]) { self.name = name; self.tables = tables }
}

public struct PostgresColumn: Sendable, Equatable {
    public var name: String
    /// Tipo curto (`int4`, `timestamptz`, `varchar(80)`).
    public var type: String
    public var nullable: Bool
    public var isKey: Bool

    public init(name: String, type: String, nullable: Bool, isKey: Bool) {
        self.name = name; self.type = type; self.nullable = nullable; self.isKey = isKey
    }
}

public struct PostgresRowCount: Sendable, Equatable {
    public var value: Int
    /// `false` = estimativa do `pg_class` (tabelas grandes; contar tudo seria lento).
    public var exact: Bool
    public init(value: Int, exact: Bool) { self.value = value; self.exact = exact }
}

/// Linhas lidas, todas as células como texto (`NULL` para nulo).
public struct PostgresResult: Sendable, Equatable {
    public var columns: [String]
    public var rows: [[String]]
    /// Havia mais linhas que o limite pedido.
    public var truncated: Bool
    public init(columns: [String], rows: [[String]], truncated: Bool = false) {
        self.columns = columns; self.rows = rows; self.truncated = truncated
    }
}

/// Cliente PostgreSQL de leitura (PostgresNIO). Cada chamada abre uma conexão, roda dentro de `BEGIN READ ONLY … ROLLBACK` com
/// limite de tempo e fecha: nada grava e nada fica aberto. TLS é obrigatório, a menos que a string diga `sslmode=disable`.
public struct PostgresConnector: PostgresBrowsing {
    public enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
        case invalidConnectionString(String)
        /// Usuário ou senha recusados.
        case auth(String)
        case unreachable(String)
        case tls(String)
        case timeout
        /// O servidor recusou o SQL (a mensagem dele, sem a consulta).
        case sql(String)

        public var description: String {
            switch self {
            case .invalidConnectionString(let why): why
            case .auth(let why): "The server refused the user or password. \(why)"
            case .unreachable(let why): "Could not reach the server: \(why)"
            case .tls(let why): "Could not set up a secure (TLS) connection: \(why)"
            case .timeout: "The server did not answer in time."
            case .sql(let message): message
            }
        }

        /// Traduz o SQLSTATE de um erro do servidor.
        static func fromServer(sqlState: String?, message: String) -> Failure {
            switch sqlState {
            case "28P01", "28000": .auth(message)
            case "57014": .timeout
            default: .sql(message)
            }
        }
    }

    public let info: PostgresConnectionInfo
    /// Quantas linhas uma consulta devolve no máximo, e quanto o app espera por uma operação inteira.
    static let operationDeadline: Double = 30

    public init(info: PostgresConnectionInfo) { self.info = info }

    /// A connection string inteira (com a senha) vira um conector, ou um erro que diz o que falta.
    public init(connectionString: String) throws(Failure) {
        do { self.info = try PostgresConnectionInfo(parsing: connectionString) } catch { throw .invalidConnectionString(error.description) }
    }

    // MARK: Chamadas

    public func check() async throws {
        _ = try await readOnly { connection in try await run(connection, "SELECT 1") }
    }

    public func schemas() async throws -> [String] {
        try await readOnly { connection in try await schemaNames(connection) }
    }

    public func tables(schema: String) async throws -> [PostgresTable] {
        try await readOnly { connection in try await tableList(connection, schema: schema) }
    }

    public func catalog() async throws -> [PostgresSchema] {
        try await readOnly { connection in
            let names = try await schemaNames(connection)
            let all = try await tableList(connection, schema: nil)
            return names.map { name in PostgresSchema(name: name, tables: all.filter { $0.schema == name }) }
        }
    }

    public func columns(schema: String, table: String) async throws -> [PostgresColumn] {
        try await readOnly { connection in try await columnList(connection, schema: schema, table: table) }
    }

    public func rowCount(schema: String, table: String) async throws -> PostgresRowCount {
        try await readOnly { connection in
            let estimate = try await tableList(connection, schema: schema).first { $0.name == table }?.estimatedRows
            // Estimativa só nas grandes: contar uma tabela pequena é rápido e dá o número certo (estimativa pode estar defasada).
            if let estimate, estimate >= Self.countExactBelow { return PostgresRowCount(value: estimate, exact: false) }
            let rows = try await run(connection, PostgresSQL.exactCount(schema: schema, table: table))
            let value = try rows.first.map { try $0.decode(Int64.self) } ?? 0
            return PostgresRowCount(value: Int(value), exact: true)
        }
    }

    static let countExactBelow = 100_000

    public func rows(schema: String, table: String, limit: Int, offset: Int, orderBy: [String]) async throws -> PostgresResult {
        try await readOnly { connection in
            let columns = try await columnList(connection, schema: schema, table: table)
            guard !columns.isEmpty else { throw Failure.sql("\(schema).\(table) does not exist or has no readable columns.") }
            let sql = PostgresSQL.selectPage(schema: schema, table: table, columns: columns.map(\.name), limit: limit, offset: offset, orderBy: orderBy)
            return try await collect(connection, sql, limit: limit)
        }
    }

    public func query(sql: String, limit: Int) async throws -> PostgresResult {
        let text = PostgresSQL.clean(sql)
        guard !text.isEmpty else { throw Failure.sql("Write a query first.") }
        return try await readOnly { connection in try await collect(connection, text, limit: limit) }
    }

    // MARK: Conexão

    private func makeLogger() -> Logger {
        var logger = Logger(label: "racky.postgres")
        // Nada de SQL, senha ou string de conexão em log.
        logger.logLevel = .critical
        return logger
    }

    private func configuration() throws -> PostgresConnection.Configuration {
        let tls: PostgresConnection.Configuration.TLS
        if info.sslMode == .disable {
            tls = .disable
        } else {
            var config = TLSConfiguration.makeClientConfiguration()
            // Como o libpq: `require` cifra mas não confere o certificado (RDS e Supabase usam CA própria); `verify-*` confere.
            switch info.sslMode {
            case .verifyFull: config.certificateVerification = .fullVerification
            case .verifyCA: config.certificateVerification = .noHostnameVerification
            default: config.certificateVerification = .none
            }
            do {
                let context = try NIOSSLContext(configuration: config)
                tls = (info.sslMode == .allow || info.sslMode == .prefer) ? .prefer(context) : .require(context)
            } catch {
                throw Failure.tls("the TLS setup failed")
            }
        }
        var configuration = PostgresConnection.Configuration(
            host: info.host, port: info.port, username: info.user, password: info.password, database: info.database, tls: tls)
        configuration.options.connectTimeout = .seconds(10)
        return configuration
    }

    /// Abre, roda dentro de uma transação só de leitura, desfaz e fecha. Falhas viram `Failure`.
    private func readOnly<T: Sendable>(_ body: @escaping @Sendable (PostgresConnection) async throws -> T) async throws -> T {
        let configuration = try configuration()
        let logger = makeLogger()
        return try await Self.withDeadline(Self.operationDeadline) {
            let connection: PostgresConnection
            do {
                connection = try await PostgresConnection.connect(configuration: configuration, id: 1, logger: logger)
            } catch {
                throw Self.map(error)
            }
            do {
                let script = PostgresSQL.readOnlyScript([])
                for statement in script.dropLast(1) { _ = try await connection.query(PostgresQuery(unsafeSQL: statement), logger: logger).collect() }
                let value = try await body(connection)
                _ = try? await connection.query(PostgresQuery(unsafeSQL: script[script.count - 1]), logger: logger).collect()
                try? await connection.close()
                return value
            } catch {
                // Fechar a conexão desfaz a transação no servidor.
                try? await connection.close()
                throw Self.map(error)
            }
        }
    }

    static func withDeadline<T: Sendable>(_ seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw Failure.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw Failure.timeout }
            return first
        }
    }

    /// Erros do PostgresNIO e do NIO viram um `Failure` sem a consulta nem a senha.
    static func map(_ error: Error) -> Failure {
        if let failure = error as? Failure { return failure }
        if error is CancellationError { return .timeout }
        if let psql = error as? PSQLError {
            switch psql.code {
            case .server:
                return Failure.fromServer(sqlState: psql.serverInfo?[.sqlState], message: psql.serverInfo?[.message] ?? "The server refused the request.")
            case .sslUnsupported:
                return .tls("the server does not support TLS (use sslmode=disable only if you are sure that is intended)")
            case .failedToAddSSLHandler, .receivedUnencryptedDataAfterSSLRequest:
                return .tls("the TLS handshake failed")
            case .connectionError:
                let text = psql.underlying.map { String(describing: $0) } ?? ""
                if text.localizedCaseInsensitiveContains("ssl") || text.localizedCaseInsensitiveContains("tls") || text.localizedCaseInsensitiveContains("certificate") {
                    return .tls("the TLS handshake failed (\(text.prefix(120)))")
                }
                if text.localizedCaseInsensitiveContains("timeout") { return .timeout }
                return .unreachable(text.isEmpty ? "connection failed" : String(text.prefix(160)))
            case .saslError, .unsupportedAuthMechanism, .authMechanismRequiresPassword:
                return .auth("")
            case .serverClosedConnection, .clientClosedConnection, .uncleanShutdown:
                return .unreachable("the server closed the connection")
            default:
                return .sql(psql.serverInfo?[.message] ?? "Unexpected answer from the server (\(psql.code)).")
            }
        }
        if let ssl = error as? NIOSSLError { return .tls(String(describing: ssl).prefix(120).description) }
        return .unreachable(String(String(describing: error).prefix(160)))
    }

    // MARK: Consultas

    @discardableResult
    private func run(_ connection: PostgresConnection, _ sql: String) async throws -> [PostgresRow] {
        try await connection.query(PostgresQuery(unsafeSQL: sql), logger: makeLogger()).collect()
    }

    private func schemaNames(_ connection: PostgresConnection) async throws -> [String] {
        let sql = """
            SELECT nspname::text FROM pg_namespace
            WHERE nspname <> 'information_schema' AND nspname NOT LIKE 'pg\\_%'
            ORDER BY (nspname = 'public') DESC, nspname
            """
        return try await run(connection, sql).map { try $0.decode(String.self) }
    }

    private func tableList(_ connection: PostgresConnection, schema: String?) async throws -> [PostgresTable] {
        var query = PostgresQuery(unsafeSQL: "")
        query.sql = """
            SELECT n.nspname::text, c.relname::text, c.relkind::text, c.reltuples::bigint
            FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f') AND n.nspname <> 'information_schema' AND n.nspname NOT LIKE 'pg\\_%'
            """
        if let schema {
            query.sql += " AND n.nspname = $1"
            query.binds.append(schema, context: .default)
        }
        query.sql += " ORDER BY n.nspname, c.relname"
        let rows = try await connection.query(query, logger: makeLogger()).collect()
        return try rows.map { row in
            let (schema, name, kind, tuples) = try row.decode((String, String, String, Int64).self)
            let isView = kind == "v" || kind == "m"
            return PostgresTable(schema: schema, name: name, isView: isView, estimatedRows: isView || tuples < 0 ? nil : Int(tuples))
        }
    }

    private func columnList(_ connection: PostgresConnection, schema: String, table: String) async throws -> [PostgresColumn] {
        var query = PostgresQuery(unsafeSQL: "")
        query.sql = """
            SELECT a.attname::text, format_type(a.atttypid, a.atttypmod), NOT a.attnotnull,
                   COALESCE(a.attnum = ANY (i.indkey::int2[]), false)
            FROM pg_attribute a
            JOIN pg_class c ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            LEFT JOIN pg_index i ON i.indrelid = c.oid AND i.indisprimary
            WHERE n.nspname = $1 AND c.relname = $2 AND a.attnum > 0 AND NOT a.attisdropped
            ORDER BY a.attnum
            """
        query.binds.append(schema, context: .default)
        query.binds.append(table, context: .default)
        let rows = try await connection.query(query, logger: makeLogger()).collect()
        return try rows.map { row in
            let (name, type, nullable, key) = try row.decode((String, String, Bool, Bool).self)
            return PostgresColumn(name: name, type: PostgresSQL.shortType(type), nullable: nullable, isKey: key)
        }
    }

    /// Lê no máximo `limit` linhas (o que passar disso só marca `truncated`; o resto não é lido).
    private func collect(_ connection: PostgresConnection, _ sql: String, limit: Int) async throws -> PostgresResult {
        let sequence = try await connection.query(PostgresQuery(unsafeSQL: sql), logger: makeLogger())
        var columns: [String] = []
        var out: [[String]] = []
        var truncated = false
        for try await row in sequence {
            if out.count >= limit { truncated = true; break }
            var cells: [String] = []
            for cell in row {
                if out.isEmpty { columns.append(cell.columnName) }
                cells.append(PostgresCellText.string(cell))
            }
            out.append(cells)
        }
        return PostgresResult(columns: columns, rows: out, truncated: truncated)
    }
}

/// Uma célula do PostgresNIO como texto para a grade. As consultas de tabela já pedem `col::text`; as do usuário voltam em binário,
/// então os tipos comuns são decodificados aqui e o resto aparece como o que dá para ler.
public enum PostgresCellText {
    public static func string(_ cell: PostgresCell) -> String {
        guard cell.bytes != nil else { return "NULL" }
        let type = cell.dataType
        do {
            switch type {
            case .bool: return try cell.decode(Bool.self) ? "true" : "false"
            case .int2: return String(try cell.decode(Int16.self))
            case .int4: return String(try cell.decode(Int32.self))
            case .int8: return String(try cell.decode(Int64.self))
            case .oid:
                var buffer = cell.bytes
                if cell.format == .binary, let value = buffer?.readInteger(as: UInt32.self) { return String(value) }
            case .float4: return String(try cell.decode(Float.self))
            case .float8: return String(try cell.decode(Double.self))
            case .numeric: return "\(try cell.decode(Decimal.self))"
            case .uuid: return try cell.decode(UUID.self).uuidString.lowercased()
            case .date: return format(try cell.decode(Date.self), dateOnly: true)
            case .timestamp, .timestamptz: return format(try cell.decode(Date.self), dateOnly: false)
            case .bytea:
                let bytes = cell.bytes.map { Array($0.readableBytesView) } ?? []
                return "\\x" + bytes.map { String(format: "%02x", $0) }.joined()
            case .text, .varchar, .bpchar, .name, .json, .jsonb, .xml, .char, .unknown: return try cell.decode(String.self)
            case .int4Array: return "{" + (try cell.decode([Int32].self)).map(String.init).joined(separator: ",") + "}"
            case .int8Array: return "{" + (try cell.decode([Int64].self)).map(String.init).joined(separator: ",") + "}"
            case .textArray, .varcharArray: return "{" + (try cell.decode([String].self)).joined(separator: ",") + "}"
            default: break
            }
        } catch {
            return fallback(cell)
        }
        return fallback(cell)
    }

    /// Um tipo sem decodificador (inet, interval, enum…): o texto, se os bytes são texto; senão o tamanho. `::text` na consulta resolve.
    private static func fallback(_ cell: PostgresCell) -> String {
        guard var copy = cell.bytes else { return "NULL" }
        let size = copy.readableBytes
        guard let text = copy.readString(length: size) else { return "(\(size) bytes, add ::text)" }
        if cell.format == .text || text.isEmpty { return text }
        if text.unicodeScalars.allSatisfy({ !$0.properties.isDefaultIgnorableCodePoint && ($0.value >= 0x20 || $0 == "\n" || $0 == "\t") }) {
            return text
        }
        return "(\(cell.bytes?.readableBytes ?? 0) bytes, add ::text)"
    }

    /// `2026-10-22 11:59:04+00` (UTC, o mesmo jeito que o psql mostra).
    static func format(_ date: Date, dateOnly: Bool) -> String {
        let calendar = Calendar(identifier: .gregorian)
        var utc = calendar
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        let day = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        if dateOnly { return day }
        var out = day + String(format: " %02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        let micro = (c.nanosecond ?? 0) / 1000
        if micro > 0 { out += String(format: ".%06d", micro).replacingOccurrences(of: "0+$", with: "", options: .regularExpression) }
        return out + "+00"
    }
}
