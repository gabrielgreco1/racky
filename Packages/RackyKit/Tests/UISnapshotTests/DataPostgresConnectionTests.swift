import RackyCore
import RackyPlatform
import RackyProtocol
import RackyStore
import AppKit
import Foundation
import Testing

@testable import RackyUI

/// Conectar um Postgres/Supabase pela área Data com um conector falso (nada sai da máquina): o formulário testa e salva, a connection
/// string vai inteira para o cofre, o explorer lista schemas e tabelas, a tabela abre com linhas reais paginadas, o SQL roda e
/// remover apaga o segredo.
@MainActor
@Suite(.serialized) struct DataPostgresConnectionTests {
    nonisolated final class FakeDatabase: PostgresBrowsing, @unchecked Sendable {
        var infos: [PostgresConnectionInfo] = []
        var queries: [String] = []
        var failCheck: PostgresConnector.Failure?
        var failRows: PostgresConnector.Failure?

        func check() async throws { if let failCheck { throw failCheck } }
        func schemas() async throws -> [String] { ["public"] }
        func tables(schema: String) async throws -> [PostgresTable] { try await catalog().first?.tables ?? [] }
        func catalog() async throws -> [PostgresSchema] {
            [PostgresSchema(name: "public", tables: [
                PostgresTable(schema: "public", name: "listings", isView: false, estimatedRows: 250),
                PostgresTable(schema: "public", name: "recent", isView: true, estimatedRows: nil),
            ]), PostgresSchema(name: "empty", tables: [])]
        }
        func columns(schema: String, table: String) async throws -> [PostgresColumn] {
            [PostgresColumn(name: "id", type: "int8", nullable: false, isKey: true), PostgresColumn(name: "city", type: "text", nullable: true, isKey: false)]
        }
        func rowCount(schema: String, table: String) async throws -> PostgresRowCount { PostgresRowCount(value: 250, exact: true) }
        func rows(schema: String, table: String, limit: Int, offset: Int, orderBy: [String]) async throws -> PostgresResult {
            if let failRows { throw failRows }
            queries.append("rows \(limit) \(offset) \(orderBy.joined(separator: ","))")
            return PostgresResult(columns: ["id", "city"], rows: (0..<min(limit, 250 - offset)).map { ["\(offset + $0)", $0 == 1 ? "NULL" : "Austin"] })
        }
        func query(sql: String, limit: Int) async throws -> PostgresResult {
            queries.append(sql)
            if sql.lowercased().contains("insert") { throw PostgresConnector.Failure.sql("cannot execute INSERT in a read-only transaction") }
            return PostgresResult(columns: ["n"], rows: [["1"], ["2"]])
        }
    }

    private func make() async throws -> (DataHubController, ActionRegistry, FakeDatabase, SecretVault, RackyStore, URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("racky-postgres-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let store = try await RackyStore.open(paths: StorePaths(root: home))
        let hub = DataHubController(datasets: DatasetsController(), demo: false)
        let database = FakeDatabase()
        hub.postgresFactory = { info in
            database.infos.append(info)
            return database
        }
        let vault = SecretVault(store: store, keyring: VaultKeyring(backend: InMemoryMasterKeyBackend()))
        await hub.attach(store: store, vault: vault)
        let registry = ActionRegistry(flags: SliceFlags(current: .slice4), surface: FakeSurface())
        try hub.register(in: registry)
        return (hub, registry, database, vault, store, home)
    }

    static let connectionString = "postgresql://postgres.abcd:s3cret@aws-0-us-east-1.pooler.supabase.com:6543/postgres"
    static var form: String {
        #"{"name":"Prod DB","url":"","auth":"connectionString","user":"","secret":"\#(connectionString)"}"#
    }

    @Test func connectBrowseQueryAndRemove() async throws {
        let (hub, registry, database, vault, store, home) = try await make()
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: home) } }
        #expect(DataConnectionKind.postgres.connectable && DataConnectionKind.supabase.connectable)
        _ = try await registry.perform(.dataConnectStart, .select("supabase"))
        #expect(hub.connecting == .supabase)
        _ = try await registry.perform(.dataConnectSave, .set(Self.form))

        // Salva: a string inteira no cofre, nada de segredo no estado do app, só host:porta/banco.
        let saved = try #require(hub.saved.first)
        #expect(saved.kind == .supabase && saved.name == "Prod DB" && saved.url == "aws-0-us-east-1.pooler.supabase.com:6543/postgres")
        let stored = try #require(try await store.uiState(DataHubController.savedKey, as: [SavedConnection].self))
        let json = String(data: try JSONEncoder().encode(stored), encoding: .utf8) ?? ""
        #expect(!json.contains("s3cret") && !json.contains("postgresql://"))
        #expect(try await vault.reveal(id: try #require(saved.secretID)).text == Self.connectionString)
        #expect(database.infos.first?.password == "s3cret" && database.infos.first?.sslMode == .require)

        // O explorer: schemas → tabelas com linhas estimadas, a view sem número.
        let connection = try #require(hub.connection(saved.id))
        let schema = try #require(connection.children.first)
        #expect(schema.name == "public" && schema.children.map(\.name) == ["listings", "recent"])
        #expect(schema.children.first?.size == 250 && schema.children.last?.kind == .view)
        #expect(hub.expanded.contains(saved.id) && hub.expanded.contains("\(saved.id)/public"))

        // Abrir a tabela lê a primeira página (100 linhas, pela chave primária) com os tipos reais.
        let table = DataObject.table(connection: saved.id, schema: "public", name: "listings")
        _ = try await registry.perform(.dataOpen, .select(table.key))
        await hub.loadTable(table)
        let grid = hub.tableGrid(table)
        #expect(grid.columns.map(\.type) == ["int8", "text"] && grid.columns.first?.key == true)
        #expect(grid.rows.count == 100 && grid.total == 250 && hub.pageCount(for: table) == 3)
        #expect(database.queries.contains("rows 100 0 id"))

        // Próxima página pede o deslocamento seguinte; a última tem o resto.
        _ = try await registry.perform(.dataTablePage, .select("next"))
        _ = try await registry.perform(.dataTablePage, .select("next"))
        #expect(hub.tablePage(table) == 2 && hub.tableGrid(table).rows.count == 50 && hub.tableGrid(table).rows.first?.first == "200")
        _ = try await registry.perform(.dataTablePage, .select("next"))
        #expect(hub.tablePage(table) == 2)

        // SQL de verdade: roda; escrita é recusada e o erro aparece na tela, sem derrubar nada.
        let query = hub.newQuery(on: saved.id)
        #expect(hub.queryText[query]?.lowercased().contains("information_schema") == true)
        _ = try await registry.perform(.dataQueryRun, .press)
        #expect(hub.queryResult[query]?.grid.rows.count == 2 && hub.queryErrors[query] == nil)
        hub.queryText[query] = "insert into listings values (1)"
        _ = try await registry.perform(.dataQueryRun, .press)
        #expect(hub.queryResult[query] == nil && hub.queryErrors[query]?.contains("read-only") == true)

        // Remover apaga o segredo, a conexão e o que se leu dela.
        let secretID = try #require(saved.secretID)
        _ = try await registry.perform(.dataConnectionRemove, .select(saved.id))
        #expect(hub.saved.contains { $0.id == saved.id }, "o primeiro clique só pede confirmação")
        _ = try await registry.perform(.dataConnectionRemove, .select("\(saved.id)|confirm"))
        #expect(hub.saved.isEmpty && hub.connection(saved.id) == nil && hub.tableStates.isEmpty && hub.catalogs.isEmpty)
        await #expect(throws: (any Error).self) { _ = try await vault.reveal(id: secretID) }
    }

    @Test func aRefusedConnectionSavesNothing() async throws {
        let (hub, registry, database, vault, store, home) = try await make()
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: home) } }
        database.failCheck = .auth("password authentication failed")
        _ = try await registry.perform(.dataConnectStart, .select("postgres"))
        await #expect(throws: ActionError.self) { _ = try await registry.perform(.dataConnectSave, .set(Self.form)) }
        #expect(hub.saved.isEmpty && hub.connecting == .postgres)
        #expect(hub.connectError?.contains("refused") == true)
        #expect(try await vault.list().isEmpty)

        // Um modelo com [placeholder] diz o que falta, sem tentar conectar.
        let template = #"{"name":"","url":"","auth":"connectionString","user":"","secret":"postgresql://postgres.[ref]:[YOUR-PASSWORD]@h:6543/postgres"}"#
        await #expect(throws: ActionError.self) { _ = try await registry.perform(.dataConnectSave, .set(template)) }
        #expect(hub.connectError?.contains("placeholder") == true)
    }

    @Test func aReadFailureShowsInTheViewNotACrash() async throws {
        let (hub, registry, database, _, store, home) = try await make()
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: home) } }
        _ = try await registry.perform(.dataConnectStart, .select("supabase"))
        _ = try await registry.perform(.dataConnectSave, .set(Self.form))
        let saved = try #require(hub.saved.first)
        database.failRows = .timeout
        let table = DataObject.table(connection: saved.id, schema: "public", name: "listings")
        await hub.loadTable(table)
        #expect(hub.tableStates[table]?.error == PostgresConnector.Failure.timeout.description && hub.tableStates[table]?.loaded == false)
    }
}
