import Foundation

/// Os bancos que o helper `racky-db` fala (MySQL/MariaDB, SQL Server, Oracle).
public enum SQLHelperEngine: String, Sendable, Equatable, CaseIterable {
    case mysql, sqlserver, oracle

    public var defaultPort: Int {
        switch self {
        case .mysql: 3306
        case .sqlserver: 1433
        case .oracle: 1521
        }
    }

    /// Esquemas de URL aceitos (o primeiro é o canônico).
    var schemes: [String] {
        switch self {
        case .mysql: ["mysql", "mariadb"]
        case .sqlserver: ["sqlserver", "mssql"]
        case .oracle: ["oracle"]
        }
    }
}

/// Como falar com um MySQL/MariaDB, SQL Server ou Oracle: host, porta, usuário, senha e banco (no Oracle, o service name). Vem de
/// uma URL (`mysql://user:pass@host:3306/db`, `sqlserver://…?database=db`, `oracle://user:pass@host:1521/SERVICE`), de uma string
/// EZConnect do Oracle (`user/pass@host:1521/SERVICE`) ou de campos soltos. A URL canônica (com a senha) é o segredo que vai ao
/// cofre e ao helper; `displayAddress` é o que pode aparecer na tela.
public struct SQLConnectionSpec: Sendable, Equatable {
    public enum ParseError: Error, Equatable, Sendable, CustomStringConvertible {
        case empty
        case wrongScheme(SQLHelperEngine)
        case placeholder
        case missingHost
        case missingUser
        case missingDatabase(SQLHelperEngine)
        case badPort(String)

        public var description: String {
            switch self {
            case .empty: "Paste the connection string, or fill in the host, user and password."
            case .wrongScheme(let engine):
                switch engine {
                case .mysql: "The connection string must start with mysql:// (or mariadb://)."
                case .sqlserver: "The connection string must start with sqlserver://."
                case .oracle: "The connection string must start with oracle:// (or look like user/password@host:1521/SERVICE)."
                }
            case .placeholder: "The connection string still has a [placeholder]: replace it with the real value."
            case .missingHost: "The connection has no host."
            case .missingUser: "The connection has no user."
            case .missingDatabase(let engine): engine == .oracle ? "The connection has no service name (the SERVICE after the slash)." : "The connection has no database."
            case .badPort(let port): "The port \"\(port)\" is not a number."
            }
        }
    }

    public var engine: SQLHelperEngine
    public var host: String
    public var port: Int
    public var user: String
    public var password: String?
    /// Banco (MySQL, SQL Server) ou service name (Oracle). Vazio vale no MySQL (lista todos os bancos do servidor).
    public var database: String
    /// Opções que a URL trazia (`tls=disable`, `encrypt=false`…), repassadas ao helper.
    public var options: [String: String]

    public init(engine: SQLHelperEngine, host: String, port: Int? = nil, user: String, password: String?, database: String, options: [String: String] = [:]) throws(ParseError) {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { throw .missingHost }
        guard !user.trimmingCharacters(in: .whitespaces).isEmpty else { throw .missingUser }
        let database = database.trimmingCharacters(in: .whitespacesAndNewlines)
        if engine != .mysql, database.isEmpty { throw .missingDatabase(engine) }
        self.engine = engine
        self.host = host
        self.port = port ?? engine.defaultPort
        self.user = user.trimmingCharacters(in: .whitespaces)
        self.password = (password?.isEmpty ?? true) ? nil : password
        self.database = database
        self.options = options
    }

    /// Campos de um formulário: o host pode vir com a porta (`db.local:3307`).
    public init(engine: SQLHelperEngine, hostField: String, user: String, password: String?, database: String) throws(ParseError) {
        var host = hostField.trimmingCharacters(in: .whitespacesAndNewlines)
        var port: Int?
        if let colon = host.lastIndex(of: ":"), !host.hasSuffix("]"), host.filter({ $0 == ":" }).count == 1 {
            let text = String(host[host.index(after: colon)...])
            guard let value = Int(text), (1...65535).contains(value) else { throw .badPort(text) }
            port = value
            host = String(host[..<colon])
        }
        try self.init(engine: engine, host: host, port: port, user: user, password: password, database: database)
    }

    public init(parsing text: String, engine: SQLHelperEngine) throws(ParseError) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .empty }
        if trimmed.range(of: #"\[[A-Za-z][A-Za-z0-9 _-]*\]"#, options: .regularExpression) != nil { throw .placeholder }
        guard let schemeEnd = trimmed.range(of: "://") else {
            if engine == .oracle { try self.init(ezConnect: trimmed); return }
            throw .wrongScheme(engine)
        }
        let scheme = trimmed[..<schemeEnd.lowerBound].lowercased()
        guard engine.schemes.contains(scheme) else { throw .wrongScheme(engine) }
        var rest = Substring(trimmed[schemeEnd.upperBound...])
        var query = ""
        if let q = rest.firstIndex(of: "?") {
            query = String(rest[rest.index(after: q)...])
            rest = rest[..<q]
        }
        var path = ""
        var authority = rest
        // O último `@` separa as credenciais do host (uma senha com `@` sem escapar também vale).
        let credentials: Substring?
        if let at = rest.lastIndex(of: "@") {
            credentials = rest[..<at]
            authority = rest[rest.index(after: at)...]
        } else {
            credentials = nil
        }
        if let slash = authority.firstIndex(of: "/") {
            path = String(authority[authority.index(after: slash)...])
            authority = authority[..<slash]
        }
        var user = "", password: String?
        if let credentials {
            if let colon = credentials.firstIndex(of: ":") {
                user = Self.decode(String(credentials[..<colon]))
                password = Self.decode(String(credentials[credentials.index(after: colon)...]))
            } else {
                user = Self.decode(String(credentials))
            }
        }
        var host = String(authority)
        var port: Int?
        if host.hasPrefix("["), let close = host.firstIndex(of: "]") {  // IPv6
            let after = host[host.index(after: close)...]
            if after.hasPrefix(":") {
                let text = String(after.dropFirst())
                guard let value = Int(text), (1...65535).contains(value) else { throw .badPort(text) }
                port = value
            }
            host = String(host[host.index(after: host.startIndex)..<close])
        } else if let colon = host.lastIndex(of: ":") {
            let text = String(host[host.index(after: colon)...])
            guard let value = Int(text), (1...65535).contains(value) else { throw .badPort(text) }
            port = value
            host = String(host[..<colon])
        }
        var options: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = parts.first, !key.isEmpty else { continue }
            options[Self.decode(String(key))] = parts.count > 1 ? Self.decode(String(parts[1])) : ""
        }
        var database = Self.decode(path)
        if engine == .sqlserver, let named = options.removeValue(forKey: "database") ?? options.removeValue(forKey: "databaseName") { database = named }
        try self.init(engine: engine, host: host, port: port, user: user, password: password, database: database, options: options)
    }

    /// `user/password@host:port/SERVICE` ou `user/password@//host:port/SERVICE`.
    private init(ezConnect text: String) throws(ParseError) {
        guard let at = text.lastIndex(of: "@") else { throw .wrongScheme(.oracle) }
        let credentials = text[..<at]
        var address = text[text.index(after: at)...]
        if address.hasPrefix("//") { address = address.dropFirst(2) }
        let user: String, password: String?
        if let slash = credentials.firstIndex(of: "/") {
            user = String(credentials[..<slash])
            password = String(credentials[credentials.index(after: slash)...])
        } else {
            user = String(credentials)
            password = nil
        }
        let hostPart: Substring, service: String
        if let slash = address.firstIndex(of: "/") {
            hostPart = address[..<slash]
            service = String(address[address.index(after: slash)...])
        } else {
            hostPart = address
            service = ""
        }
        try self.init(engine: .oracle, hostField: String(hostPart), user: user, password: password, database: service)
    }

    private static func decode(_ text: String) -> String { text.removingPercentEncoding ?? text }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encode(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text }

    /// A URL canônica, com a senha: é o que vai para o cofre e, no pedido, para o helper.
    public var url: String {
        var out = "\(engine.schemes[0])://\(Self.encode(user))"
        if let password { out += ":" + Self.encode(password) }
        out += "@" + (host.contains(":") ? "[\(host)]" : host) + ":\(port)"
        var query = options
        switch engine {
        case .sqlserver:
            if !database.isEmpty { query["database"] = database }
        case .mysql, .oracle:
            if !database.isEmpty { out += "/" + Self.encode(database) }
        }
        if !query.isEmpty {
            out += "?" + query.sorted { $0.key < $1.key }.map { "\(Self.encode($0.key))=\(Self.encode($0.value))" }.joined(separator: "&")
        }
        return out
    }

    /// `host:porta/banco`, sem usuário nem senha.
    public var displayAddress: String {
        let base = "\(host):\(port)"
        return database.isEmpty ? base : "\(base)/\(database)"
    }
}
