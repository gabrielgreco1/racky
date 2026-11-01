import Foundation

/// Como falar com um Postgres: host, porta, usuário, senha, banco e o modo de TLS. Vem de uma connection string
/// (`postgresql://user:pass@host:port/db?sslmode=require`) ou de campos soltos. Serve para PostgreSQL puro, RDS e Supabase.
/// A connection string inteira é segredo (tem a senha): `displayAddress` é a parte que pode aparecer na tela.
public struct PostgresConnectionInfo: Sendable, Equatable {
    /// Igual ao `sslmode` do libpq. Sem `sslmode` na string, o padrão é `require` (TLS sempre); `disable` só se vier explícito.
    public enum SSLMode: String, Sendable, Equatable, CaseIterable {
        case disable, allow, prefer, require
        case verifyCA = "verify-ca"
        case verifyFull = "verify-full"
    }

    public enum ParseError: Error, Equatable, Sendable, CustomStringConvertible {
        case empty
        case notPostgres
        case placeholder
        case missingHost
        case missingUser
        case badPort(String)
        case badSSLMode(String)

        public var description: String {
            switch self {
            case .empty: "Paste the connection string."
            case .notPostgres: "The connection string must start with postgresql:// (or postgres://)."
            case .placeholder: "The connection string still has a [placeholder]: replace it with the real value (usually the database password)."
            case .missingHost: "The connection string has no host."
            case .missingUser: "The connection string has no user."
            case .badPort(let port): "The port \"\(port)\" is not a number."
            case .badSSLMode(let mode): "sslmode=\(mode) is not one of disable, allow, prefer, require, verify-ca, verify-full."
            }
        }
    }

    public var host: String
    public var port: Int
    public var user: String
    public var password: String?
    public var database: String
    public var sslMode: SSLMode

    public init(host: String, port: Int = 5432, user: String, password: String?, database: String = "postgres", sslMode: SSLMode = .require) {
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.database = database
        self.sslMode = sslMode
    }

    /// Lê `postgresql://user:pass@host:port/db?sslmode=…`. Usuário, senha e banco vêm com percent-encoding; uma senha com `@` sem
    /// escapar também é aceita (o último `@` separa as credenciais do host).
    public init(parsing text: String) throws(ParseError) {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !rest.isEmpty else { throw .empty }
        let lowered = rest.lowercased()
        if lowered.hasPrefix("postgresql://") { rest = rest.dropFirst("postgresql://".count) }
        else if lowered.hasPrefix("postgres://") { rest = rest.dropFirst("postgres://".count) }
        else { throw .notPostgres }
        // Os modelos de documentação trazem [YOUR-PASSWORD] ou [ref]: nenhum valor real tem colchetes (fora IPv6 no host).
        if rest.range(of: #"\[[A-Za-z][A-Za-z0-9 _-]*\]"#, options: .regularExpression) != nil { throw .placeholder }

        var queryText = ""
        if let q = rest.firstIndex(of: "?") {
            queryText = String(rest[rest.index(after: q)...])
            rest = rest[..<q]
        }
        var authority = rest
        var path = Substring("")
        // O primeiro `/` depois do último `@` abre o caminho (o banco).
        let search = rest.lastIndex(of: "@").map { rest.index(after: $0) } ?? rest.startIndex
        if let slash = rest[search...].firstIndex(of: "/") {
            authority = rest[..<slash]
            path = rest[rest.index(after: slash)...]
        }
        var hostPort = authority
        var user = ""
        var password: String?
        if let at = authority.lastIndex(of: "@") {
            let info = authority[..<at]
            hostPort = authority[authority.index(after: at)...]
            if let colon = info.firstIndex(of: ":") {
                user = String(info[..<colon])
                let raw = String(info[info.index(after: colon)...])
                password = raw.removingPercentEncoding ?? raw
            } else {
                user = String(info)
            }
            user = user.removingPercentEncoding ?? user
        }
        var host = String(hostPort)
        var port = 5432
        if hostPort.hasPrefix("[") {
            // IPv6: [::1]:5432
            guard let close = hostPort.firstIndex(of: "]") else { throw .missingHost }
            host = String(hostPort[hostPort.index(after: hostPort.startIndex)..<close])
            let after = hostPort[hostPort.index(after: close)...]
            if after.hasPrefix(":") {
                guard let p = Int(after.dropFirst()), (1...65_535).contains(p) else { throw .badPort(String(after.dropFirst())) }
                port = p
            }
        } else if let colon = hostPort.lastIndex(of: ":") {
            host = String(hostPort[..<colon])
            let raw = String(hostPort[hostPort.index(after: colon)...])
            guard let p = Int(raw), (1...65_535).contains(p) else { throw .badPort(raw) }
            port = p
        }
        guard !host.isEmpty else { throw .missingHost }
        guard !user.isEmpty else { throw .missingUser }

        var mode = SSLMode.require
        for pair in queryText.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2, kv[0].lowercased() == "sslmode" else { continue }
            let value = String(kv[1]).removingPercentEncoding ?? String(kv[1])
            guard let parsed = SSLMode(rawValue: value.lowercased()) else { throw .badSSLMode(value) }
            mode = parsed
        }
        let database = String(path).removingPercentEncoding ?? String(path)
        self.init(host: host, port: port, user: user, password: password, database: database.isEmpty ? user : database, sslMode: mode)
    }

    /// O que dá para mostrar sem segredo: `host:porta/banco`.
    public var displayAddress: String { "\(host):\(port)/\(database)" }
}

/// O SQL que o conector manda, em funções puras (testáveis sem servidor).
public enum PostgresSQL {
    /// Tempo máximo de cada comando no servidor.
    public static let statementTimeoutMilliseconds = 15_000

    /// `"nome"` com as aspas internas dobradas: o nome entra no SQL sem poder escapar dele.
    public static func quoteIdentifier(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Tudo que roda numa transação só de leitura: `BEGIN READ ONLY`, o limite de tempo, o comando e `ROLLBACK`. Nada grava.
    public static func readOnlyScript(_ statements: [String]) -> [String] {
        ["BEGIN READ ONLY", "SET LOCAL statement_timeout = \(statementTimeoutMilliseconds)"] + statements + ["ROLLBACK"]
    }

    /// Tira espaços e `;` do fim (o protocolo aceita um comando só; vários na mesma linha são recusados pelo servidor).
    public static func clean(_ sql: String) -> String {
        var text = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(";") {
            text.removeLast()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// Uma página da tabela com todas as colunas como texto (`col::text`), na ordem pedida (a chave primária; sem ela, `ctid`).
    public static func selectPage(schema: String, table: String, columns: [String], limit: Int, offset: Int, orderBy: [String]) -> String {
        let list = columns.isEmpty ? "*" : columns.map { "t.\(quoteIdentifier($0))::text AS \(quoteIdentifier($0))" }.joined(separator: ", ")
        var sql = "SELECT \(list) FROM \(quoteIdentifier(schema)).\(quoteIdentifier(table)) AS t"
        // `t.` ordena pela coluna original: sem ele o ORDER BY pegava o apelido em texto e o id 101 vinha depois do 19.
        if !orderBy.isEmpty { sql += " ORDER BY " + orderBy.map { "t." + quoteIdentifier($0) }.joined(separator: ", ") }
        return sql + " LIMIT \(max(limit, 1)) OFFSET \(max(offset, 0))"
    }

    public static func exactCount(schema: String, table: String) -> String {
        "SELECT count(*)::bigint FROM \(quoteIdentifier(schema)).\(quoteIdentifier(table))"
    }

    /// `integer` → `int4`, `timestamp with time zone` → `timestamptz`…: os nomes curtos que a grade já entende.
    public static func shortType(_ type: String) -> String {
        let table: [(String, String)] = [
            ("timestamp with time zone", "timestamptz"), ("timestamp without time zone", "timestamp"),
            ("time with time zone", "timetz"), ("time without time zone", "time"),
            ("character varying", "varchar"), ("character", "bpchar"), ("double precision", "float8"), ("integer", "int4"),
            ("bigint", "int8"), ("smallint", "int2"), ("boolean", "bool"), ("real", "float4"),
        ]
        for (long, short) in table where type == long || type.hasPrefix(long + "(") || type.hasPrefix(long + "[") {
            return short + type.dropFirst(long.count)
        }
        return type
    }
}
