import Foundation

/// Um Postgres que o agente subiu dentro do computador (o `postmaster.pid` dele está no `/work`, que mora no disco do Mac).
public struct ComputerDatabase: Sendable, Equatable, Identifiable {
    /// `<computador>/<pasta do cluster no /work>`.
    public var id: String
    public var computer: String
    /// Pasta do cluster relativa ao `/work` (`run/pg`).
    public var path: String
    /// Porta do Mac que leva ao banco (`ComputerPortForward`).
    public var localPort: Int
    public var user: String
    public var sessionID: UUID?

    /// Leitura do banco pelo túnel (sem TLS: o tráfego nunca sai do Mac e da VM).
    public var connectionString: String { "postgresql://\(user)@127.0.0.1:\(localPort)/postgres?sslmode=disable" }
}

/// Acha clusters Postgres vivos numa pasta `work` de computador: cada `postmaster.pid` diz a porta (4ª linha) em que o servidor escuta.
public enum ComputerDatabaseScan {
    public struct Found: Sendable, Equatable {
        public var path: String
        public var port: Int
        public init(path: String, port: Int) { self.path = path; self.port = port }
    }

    static let skipped: Set<String> = [".git", "node_modules", ".venv", "venv", "__pycache__", ".cache", "store", "evidence", "site-packages"]

    public static func find(in work: URL, maxDepth: Int = 4) -> [Found] {
        var found: [Found] = []
        func walk(_ dir: URL, _ relative: [String], _ depth: Int) {
            let pid = dir.appendingPathComponent("postmaster.pid")
            if let text = try? String(contentsOf: pid, encoding: .utf8), let port = port(fromPostmasterPID: text),
               FileManager.default.fileExists(atPath: dir.appendingPathComponent("PG_VERSION").path) {
                found.append(Found(path: relative.isEmpty ? "." : relative.joined(separator: "/"), port: port))
                return
            }
            guard depth < maxDepth,
                let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            else { return }
            for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = item.lastPathComponent
                guard !skipped.contains(name),
                    let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                    values.isDirectory == true, values.isSymbolicLink != true
                else { continue }
                walk(item, relative + [name], depth + 1)
            }
        }
        walk(work, [], 0)
        return found
    }

    /// `postmaster.pid`: pid, pasta, início, porta, pasta do socket, endereço, ... A porta é a 4ª linha.
    static func port(fromPostmasterPID text: String) -> Int? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 4, let port = Int(lines[3].trimmingCharacters(in: .whitespaces)), (1024...65535).contains(port) else { return nil }
        return port
    }
}

/// Mostra no Racky os bancos que os agentes sobem nos computadores: acha o cluster, abre a porta do Mac até ele e copia as tabelas com
/// linhas para datasets da sessão do computador (`<computador>-<schema>-<tabela>`). Assim o painel Data da sessão abre sozinho com os
/// dados do smoke, e eles ficam no Racky depois que o computador (e o cluster descartável) somem. Só leitura no banco do agente.
public actor ComputerDatabaseWatcher {
    public typealias Connect = @Sendable (PostgresConnectionInfo) -> any PostgresBrowsing
    public typealias Append = @Sendable (_ session: UUID, _ dataset: String, _ rows: [[String: JSON]], _ computer: String) async throws -> Void

    struct Live {
        var forward: ComputerPortForward
        var database: ComputerDatabase
        var port: Int
    }

    private let computers: @Sendable () async -> [ManagedComputer]
    private let sessionOf: @Sendable (String) async -> UUID?
    private let append: Append?
    private let connect: Connect
    private var live: [String: Live] = [:]
    /// Linhas já copiadas por tabela (`<id do banco>/<schema>.<tabela>`): só relê quando a contagem muda.
    private var copied: [String: Int] = [:]
    private var observers: [@Sendable ([ComputerDatabase]) -> Void] = []

    /// No máximo isto de linhas por tabela vão para o dataset (uma amostra de smoke cabe; um banco grande não enche o Racky).
    public static let maxRowsPerTable = 20_000
    static let pageSize = 1_000
    static let users = ["postgres", "agent"]
    static let skippedSchemas: Set<String> = ["pg_catalog", "information_schema", "pg_toast"]

    public init(
        computers: @escaping @Sendable () async -> [ManagedComputer], sessionOf: @escaping @Sendable (String) async -> UUID?,
        append: Append?, connect: @escaping Connect = { PostgresConnector(info: $0) }
    ) {
        self.computers = computers
        self.sessionOf = sessionOf
        self.append = append
        self.connect = connect
    }

    public var databases: [ComputerDatabase] { live.values.map(\.database).sorted { $0.id < $1.id } }

    public func observe(_ observer: @escaping @Sendable ([ComputerDatabase]) -> Void) {
        observers.append(observer)
        observer(databases)
    }

    /// Uma passada: acha, abre ou fecha portas, copia o que mudou.
    public func tick() async {
        var seen: Set<String> = []
        for computer in await computers() {
            let state = await computer.state
            guard state == .ready || state == .inUse else { continue }
            for found in ComputerDatabaseScan.find(in: computer.run.work) {
                let id = "\(computer.name)/\(found.path)"
                seen.insert(id)
                if let current = live[id], current.port == found.port { continue }
                live[id]?.forward.stop()
                live[id] = nil
                if let opened = await open(computer, found: found, id: id) { live[id] = opened }
            }
        }
        for (id, gone) in live where !seen.contains(id) {
            gone.forward.stop()
            live[id] = nil
        }
        for item in live.values { await copyTables(of: item.database) }
        let snapshot = databases
        for observer in observers { observer(snapshot) }
    }

    public func stopAll() {
        for item in live.values { item.forward.stop() }
        live = [:]
    }

    private func open(_ computer: ManagedComputer, found: ComputerDatabaseScan.Found, id: String) async -> Live? {
        let port = found.port
        guard let forward = try? ComputerPortForward(target: { try await computer.adminTunnel(port: port) }),
            let localPort = try? await forward.start()
        else { return nil }
        for user in Self.users {
            let database = ComputerDatabase(id: id, computer: computer.name, path: found.path, localPort: localPort, user: user, sessionID: await sessionOf(computer.name))
            guard let info = try? PostgresConnectionInfo(parsing: database.connectionString) else { continue }
            if (try? await connect(info).check()) != nil { return Live(forward: forward, database: database, port: port) }
        }
        forward.stop()
        return nil
    }

    private func copyTables(of database: ComputerDatabase) async {
        guard let append, let session = database.sessionID,
            let info = try? PostgresConnectionInfo(parsing: database.connectionString)
        else { return }
        let browser = connect(info)
        guard let catalog = try? await browser.catalog() else { return }
        for schema in catalog where !Self.skippedSchemas.contains(schema.name) {
            for table in schema.tables where !table.isView {
                let key = "\(database.id)/\(schema.name).\(table.name)"
                guard let count = try? await browser.rowCount(schema: schema.name, table: table.name).value, count > 0, copied[key] != count else { continue }
                let name = Self.datasetName(computer: database.computer, schema: schema.name, table: table.name)
                var offset = 0
                var ok = true
                while offset < min(count, Self.maxRowsPerTable) {
                    guard let page = try? await browser.rows(schema: schema.name, table: table.name, limit: Self.pageSize, offset: offset, orderBy: []),
                        !page.rows.isEmpty
                    else { break }
                    let rows: [[String: JSON]] = page.rows.map { cells in
                        var row: [String: JSON] = [:]
                        for (column, cell) in zip(page.columns, cells) { row[column] = cell == "NULL" ? .null : .string(cell) }
                        return row
                    }
                    do { try await append(session, name, rows, database.computer) } catch {
                        ok = false
                        break
                    }
                    offset += page.rows.count
                    if page.rows.count < Self.pageSize { break }
                }
                if ok { copied[key] = count }
            }
        }
    }

    /// `<computador>-<schema>-<tabela>`, só `a-z 0-9 _ -`, até 64 (o limite de nome de dataset).
    static func datasetName(computer: String, schema: String, table: String) -> String {
        let raw = "\(computer)-\(schema)-\(table)".lowercased()
        let cleaned = String(raw.map { ($0.isLetter && $0.isASCII) || ($0.isNumber && $0.isASCII) || $0 == "_" || $0 == "-" ? $0 : "_" })
        return String(cleaned.prefix(64))
    }
}
