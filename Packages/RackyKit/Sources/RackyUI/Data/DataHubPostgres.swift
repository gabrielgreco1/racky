import Foundation
import RackyCore
import RackyProtocol
import RackyStore

// Conexões Postgres de verdade (PostgreSQL, RDS, Supabase): a connection string fica no cofre, o conector lê (só leitura) e a área
// Data mostra schemas, tabelas, linhas e SQL no lugar dos dados de exemplo. Tudo aqui é leitura; erros viram texto na tela.

/// Última leitura do catálogo (schemas e tabelas) de uma conexão.
public struct PostgresCatalogState: Equatable, Sendable {
    public var schemas: [PostgresSchema]?
    public var error: String?
    public var loading = false
}

/// Última leitura de uma tabela aberta: colunas com tipos, a página atual e o total.
public struct PostgresTableState: Equatable, Sendable {
    public var columns: [PostgresColumn] = []
    public var rows: [[String]] = []
    public var total = 0
    /// O total é uma estimativa do servidor (tabela grande).
    public var approximate = false
    public var error: String?
    public var loading = false
    public var loaded = false
}

enum PostgresStarter {
    static let query = """
        select table_schema, table_name, table_type
        from information_schema.tables
        where table_schema not in ('pg_catalog', 'information_schema')
        order by 1, 2
        limit 50;
        """
}

extension DataHubController {
    /// Linhas por página da grade de uma tabela de verdade.
    static let livePageSize = 100
    /// Linhas que uma consulta SQL devolve no máximo.
    static let liveQueryLimit = 1_000

    /// A conexão é uma das salvas, do tipo Postgres/Supabase (as de exemplo continuam com dados de exemplo).
    func isLivePostgres(_ connection: String?) -> Bool {
        guard let connection else { return false }
        return saved.contains { $0.id == connection && $0.kind.speaksPostgres } || computerDatabase(connection) != nil
    }

    /// O conector de uma conexão salva: lê a string do cofre. `nil` + erro se o cofre não a tem.
    func postgresBrowser(for connection: String) async throws -> any PostgresBrowsing {
        if let database = computerDatabase(connection) {
            do { return postgresFactory(try PostgresConnectionInfo(parsing: database.connectionString)) } catch {
                throw PostgresConnector.Failure.invalidConnectionString(error.description)
            }
        }
        guard let entry = saved.first(where: { $0.id == connection }), let secretID = entry.secretID, let vault else {
            throw PostgresConnector.Failure.invalidConnectionString(String(localized: "The connection string is not in the vault. Remove the connection and add it again.", bundle: .module))
        }
        let text: String
        do { text = try await vault.reveal(id: secretID).text } catch {
            throw PostgresConnector.Failure.invalidConnectionString(String(localized: "The connection string is not in the vault. Remove the connection and add it again.", bundle: .module))
        }
        do {
            return postgresFactory(try PostgresConnectionInfo(parsing: text))
        } catch {
            throw PostgresConnector.Failure.invalidConnectionString(error.description)
        }
    }

    static func describe(_ error: Error) -> String {
        if let failure = error as? PostgresConnector.Failure { return failure.description }
        return error.localizedDescription
    }

    // MARK: Conectar

    /// Testa a connection string (`SELECT 1` numa transação só de leitura) e, se responder, guarda a string no cofre e a conexão no app.
    func savePostgres(_ form: ConnectForm, kind: DataConnectionKind) async -> Bool {
        let info: PostgresConnectionInfo
        do {
            info = try PostgresConnectionInfo(parsing: form.secret ?? "")
        } catch {
            connectError = error.description
            return false
        }
        guard let vault else {
            connectError = String(localized: "The secure vault is not available, so the connection string cannot be stored.", bundle: .module)
            return false
        }
        connectBusy = true
        defer { connectBusy = false }
        do {
            try await postgresFactory(info).check()
        } catch {
            connectError = Self.describe(error)
            return false
        }
        let id = "conn-\(UUID().uuidString.lowercased().prefix(8))"
        let name = form.name.isEmpty ? kind.title : form.name
        let secretID: UUID
        do {
            secretID = try await vault.create(NewSecret(
                name: "\(name) · \(kind.title) connection (\(id))", value: form.secret ?? "", kind: .envVar, delivery: .sidecarOnly,
                note: String(localized: "Data connection credential: only Racky reads it, never an agent's terminal.", bundle: .module))).id
        } catch {
            connectError = String(localized: "The connection string could not be stored in the vault.", bundle: .module)
            return false
        }
        saved.append(SavedConnection(id: id, kind: kind, name: name, url: info.displayAddress, auth: .connectionString, secretID: secretID))
        try? await store?.setUIState(Self.savedKey, saved)
        rebuildConnections()
        connecting = nil
        connectError = nil
        showingConnect = false
        expanded.insert(id)
        await loadCatalog(id)
        return true
    }

    // MARK: Catálogo

    /// Lê schemas e tabelas (com linhas estimadas) e os põe na árvore do explorer.
    func loadCatalog(_ connection: String) async {
        guard isLivePostgres(connection) else { return }
        var state = catalogs[connection] ?? PostgresCatalogState()
        state.loading = true
        catalogs[connection] = state
        rebuildConnections()
        do {
            let browser = try await postgresBrowser(for: connection)
            state.schemas = try await browser.catalog()
            state.error = nil
            // Os schemas que têm tabelas abrem sozinhos; "public" primeiro por já vir na frente.
            if let first = state.schemas?.first(where: { !$0.tables.isEmpty }) { expanded.insert("\(connection)/\(first.name)") }
        } catch {
            state.error = Self.describe(error)
        }
        state.loading = false
        catalogs[connection] = state
        rebuildConnections()
    }

    /// Os nós da árvore de uma conexão: schemas → tabelas e views, com o número de linhas ao lado.
    func postgresChildren(of connection: SavedConnection) -> [DataNode] {
        (catalogs[connection.id]?.schemas ?? []).map { schema in
            DataNode(
                id: "\(connection.id)/\(schema.name)", kind: .schema, name: schema.name,
                children: schema.tables.map { table in
                    DataNode(id: "\(connection.id)/\(schema.name)/\(table.name)", kind: table.isView ? .view : .table, name: table.name, size: table.estimatedRows)
                })
        }
    }

    func catalogTable(_ connection: String, schema: String, name: String) -> PostgresTable? {
        catalogs[connection]?.schemas?.first { $0.name == schema }?.tables.first { $0.name == name }
    }

    // MARK: Tabela

    /// Lê a página atual da tabela (e, na primeira vez, colunas e total).
    func loadTable(_ object: DataObject) async {
        guard case .table(let connection, let schema, let name) = object, isLivePostgres(connection) else { return }
        var state = tableStates[object] ?? PostgresTableState()
        state.loading = true
        tableStates[object] = state
        let page = tablePage(object)
        do {
            let browser = try await postgresBrowser(for: connection)
            if !state.loaded {
                state.columns = try await browser.columns(schema: schema, table: name)
                let count = try await browser.rowCount(schema: schema, table: name)
                state.total = count.value
                state.approximate = !count.exact
            }
            // Páginas estáveis: pela chave primária; sem ela, pelo `ctid` (tabelas; uma view não tem).
            let keys = state.columns.filter(\.isKey).map(\.name)
            let isView = catalogTable(connection, schema: schema, name: name)?.isView ?? false
            let order = keys.isEmpty ? (isView ? [] : ["ctid"]) : keys
            let result = try await browser.rows(schema: schema, table: name, limit: Self.livePageSize, offset: page * Self.livePageSize, orderBy: order)
            state.rows = result.rows
            state.loaded = true
            state.error = nil
        } catch {
            state.error = Self.describe(error)
        }
        state.loading = false
        tableStates[object] = state
    }

    /// A grade de uma tabela: a de verdade (conexão salva) ou a de exemplo.
    func tableGrid(_ object: DataObject) -> DataGrid {
        guard isLivePostgres(object.connectionID) else { return DataHubFixtures.grid(for: object, page: tablePage(object)) }
        let state = tableStates[object] ?? PostgresTableState()
        return DataGrid(
            columns: state.columns.map { .init(name: $0.name, type: $0.type, key: $0.isKey, nullable: $0.nullable) }, rows: state.rows, total: state.total)
    }

    func pageCount(for object: DataObject) -> Int {
        guard isLivePostgres(object.connectionID) else { return DataHubFixtures.pageCount(for: object) }
        let total = tableStates[object]?.total ?? 0
        return max(Int((Double(total) / Double(Self.livePageSize)).rounded(.up)), 1)
    }

    /// Total de linhas de uma tabela aberta (a barra de localização).
    func rowTotal(_ object: DataObject) -> (total: Int, approximate: Bool) {
        guard isLivePostgres(object.connectionID) else { return (DataHubFixtures.grid(for: object).total, false) }
        let state = tableStates[object]
        return (state?.total ?? catalogTable(object)?.estimatedRows ?? 0, state?.approximate ?? true)
    }

    private func catalogTable(_ object: DataObject) -> PostgresTable? {
        guard case .table(let c, let schema, let name) = object else { return nil }
        return catalogTable(c, schema: schema, name: name)
    }

    // MARK: SQL

    /// Roda o SQL do editor numa transação só de leitura (até 1.000 linhas, 15 s no servidor).
    func runQuery(_ object: DataObject) async {
        guard case .query(let connection, _) = object, isLivePostgres(connection), !queryBusy.contains(object) else { return }
        queryBusy.insert(object)
        defer { queryBusy.remove(object) }
        let started = ContinuousClock.now
        do {
            let browser = try await postgresBrowser(for: connection)
            let result = try await browser.query(sql: queryText[object] ?? "", limit: Self.liveQueryLimit)
            let elapsed = started.duration(to: .now)
            let ms = Int(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            queryResult[object] = (DataGrid(columns: result.columns.map { .init(name: $0, type: "") }, rows: result.rows, total: result.rows.count), ms)
            queryErrors[object] = nil
            if result.truncated { queryTruncated.insert(object) } else { queryTruncated.remove(object) }
        } catch {
            queryResult[object] = nil
            queryErrors[object] = Self.describe(error)
            queryTruncated.remove(object)
        }
    }

    /// Esquece o que se leu de uma conexão removida.
    func forgetPostgres(_ connection: String) {
        catalogs[connection] = nil
        for object in tableStates.keys where object.connectionID == connection { tableStates[object] = nil; tablePages[object] = nil }
        for object in Array(queryResult.keys) where object.connectionID == connection { queryResult[object] = nil }
        for object in Array(queryErrors.keys) where object.connectionID == connection { queryErrors[object] = nil }
        for object in Array(queryText.keys) where object.connectionID == connection { queryText[object] = nil }
    }
}
