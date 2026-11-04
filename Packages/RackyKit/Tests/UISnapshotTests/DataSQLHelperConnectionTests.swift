import RackyCore
import RackyDesignSystem
import RackyPlatform
import RackyProtocol
import RackyStore
import AppKit
import Foundation
import Testing

@testable import RackyUI

/// MySQL, SQL Server e Oracle pela área Data, com um helper falso (script de shell apontado por `RACKY_DB_HELPER`; nada sai da
/// máquina): conectar com campos ou URL, o segredo vai ao cofre, o explorer lista, a tabela abre, o SQL roda, a escrita é recusada,
/// o login errado e o servidor desligado aparecem no estado de saúde.
@MainActor
@Suite(.serialized) struct DataSQLHelperConnectionTests {
    /// Responde conforme a senha e o host que vieram no pedido: `wrong` recusa o login, `down` não alcança o servidor.
    static let script = """
        case "$req" in
          *down.invalid*) echo '{"ok":false,"error":{"kind":"unreachable","message":"dial tcp: lookup down.invalid: no such host"}}'; exit 0 ;;
          *wrong-pw*) echo '{"ok":false,"error":{"kind":"auth","message":"Access denied for user app"}}'; exit 0 ;;
        esac
        case "$req" in
          *'"op":"check"'*) echo '{"ok":true}' ;;
          *'"op":"catalog"'*) echo '{"ok":true,"schemas":[{"name":"shop","tables":[{"name":"orders","isView":false,"estimatedRows":250},{"name":"v_recent","isView":true,"estimatedRows":null}]}]}' ;;
          *'"op":"columns"'*) echo '{"ok":true,"columns":[{"name":"id","type":"int","nullable":false,"isKey":true},{"name":"city","type":"varchar(40)","nullable":true,"isKey":false}]}' ;;
          *'"op":"rowCount"'*) echo '{"ok":true,"rowCount":{"value":250,"exact":true}}' ;;
          *'"op":"rows"'*) echo '{"ok":true,"result":{"columns":["id","city"],"rows":[["1","Austin"],["2","NULL"]],"truncated":false}}' ;;
          *'"op":"query"'*delete*) echo '{"ok":false,"error":{"kind":"invalid","message":"Racky only reads: DELETE is not allowed. Start with SELECT or WITH."}}' ;;
          *'"op":"query"'*) echo '{"ok":true,"result":{"columns":["n"],"rows":[["1"],["2"]],"truncated":false}}' ;;
        esac
        """

    /// Helper falso: guarda cada pedido em `<dir>/seen.requests` e responde com `body` (`$req` é o pedido inteiro).
    static func fakeHelper(_ body: String) throws -> (helper: URL, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("racky-db-fake-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let text = "#!/bin/sh\nreq=$(cat)\nprintf '%s\\n' \"$req\" >> \"\(dir.path)/seen.requests\"\n\(body)\n"
        let url = dir.appendingPathComponent("racky-db")
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return (url, dir)
    }

    private func make() async throws -> (DataHubController, ActionRegistry, SecretVault, RackyStore, URL, URL) {
        let (helper, helperDir) = try Self.fakeHelper(Self.script)
        setenv(SQLHelperConnector.helperEnvironmentKey, helper.path, 1)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("racky-sqlhelper-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let store = try await RackyStore.open(paths: StorePaths(root: home))
        let hub = DataHubController(datasets: DatasetsController(), demo: false)
        let vault = SecretVault(store: store, keyring: VaultKeyring(backend: InMemoryMasterKeyBackend()))
        await hub.attach(store: store, vault: vault)
        let registry = ActionRegistry(flags: SliceFlags(current: .slice4), surface: FakeSurface())
        try hub.register(in: registry)
        return (hub, registry, vault, store, home, helperDir)
    }

    private func cleanup(_ store: RackyStore, _ home: URL, _ helperDir: URL) {
        unsetenv(SQLHelperConnector.helperEnvironmentKey)
        Task { try? await store.close(); try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: helperDir) }
    }

    static func fieldsForm(host: String = "db.example:3306", password: String = "s3cret-pw", database: String = "shop") -> String {
        #"{"name":"Shop DB","url":"","auth":"connectionString","user":"app","secret":"\#(password)","host":"\#(host)","database":"\#(database)"}"#
    }

    @Test func theThreeKindsAreConnectable() {
        for kind in [DataConnectionKind.mysql, .sqlServer, .oracle] {
            #expect(kind.connectable && kind.speaksLiveSQL && kind.helperEngine != nil && !kind.speaksPostgres)
        }
        #expect(DataConnectionKind.oracle.family == .database && DataConnectionKind.oracle.title == "Oracle")
        #expect(DSDataBrand.oracle.rawValue == "oracle")
        #expect(DataConnectionKind.sqlite.connectable == false)
    }

    @Test func connectBrowseQueryAndRemove() async throws {
        let (hub, registry, vault, store, home, helperDir) = try await make()
        defer { cleanup(store, home, helperDir) }
        _ = try await registry.perform(.dataConnectStart, .select("mysql"))
        #expect(hub.connecting == .mysql)
        _ = try await registry.perform(.dataConnectSave, .set(Self.fieldsForm()))

        // Salva: a URL canônica (com a senha) no cofre; no estado do app só host:porta/banco.
        let saved = try #require(hub.saved.first)
        #expect(saved.kind == .mysql && saved.name == "Shop DB" && saved.url == "db.example:3306/shop")
        let stored = try #require(try await store.uiState(DataHubController.savedKey, as: [SavedConnection].self))
        let json = String(data: try JSONEncoder().encode(stored), encoding: .utf8) ?? ""
        #expect(!json.contains("s3cret-pw") && !json.contains("mysql://"))
        #expect(try await vault.reveal(id: try #require(saved.secretID)).text == "mysql://app:s3cret-pw@db.example:3306/shop")

        // Explorer: schema → tabela com linhas estimadas, view sem número; a saúde mostra a contagem.
        let connection = try #require(hub.connection(saved.id))
        let schema = try #require(connection.children.first)
        #expect(schema.name == "shop" && schema.children.map(\.name) == ["orders", "v_recent"])
        #expect(schema.children.first?.size == 250 && schema.children.last?.kind == .view)
        #expect(hub.health[saved.id] == .ok("2 tables"))

        // A tabela abre com tipos reais, pela chave primária (sem `ctid`: isso é do Postgres).
        let table = DataObject.table(connection: saved.id, schema: "shop", name: "orders")
        _ = try await registry.perform(.dataOpen, .select(table.key))
        await hub.loadTable(table)
        let grid = hub.tableGrid(table)
        #expect(grid.columns.map(\.type) == ["int", "varchar(40)"] && grid.columns.first?.key == true)
        #expect(grid.rows == [["1", "Austin"], ["2", "NULL"]] && grid.total == 250)

        // A consulta nova começa com o SQL desse banco; roda; escrita volta recusada com a mensagem do helper.
        let query = hub.newQuery(on: saved.id)
        #expect(hub.queryText[query]?.contains("information_schema.tables") == true && hub.queryText[query]?.contains("limit 50") == true)
        _ = try await registry.perform(.dataQueryRun, .press)
        #expect(hub.queryResult[query]?.grid.rows.count == 2 && hub.queryErrors[query] == nil)
        hub.queryText[query] = "delete from orders"
        _ = try await registry.perform(.dataQueryRun, .press)
        #expect(hub.queryResult[query] == nil && hub.queryErrors[query]?.contains("only reads") == true)

        let secretID = try #require(saved.secretID)
        _ = try await registry.perform(.dataConnectionRemove, .select(saved.id))
        _ = try await registry.perform(.dataConnectionRemove, .select("\(saved.id)|confirm"))
        #expect(hub.saved.isEmpty && hub.catalogs.isEmpty && hub.tableStates.isEmpty)
        await #expect(throws: (any Error).self) { _ = try await vault.reveal(id: secretID) }
    }

    @Test func requestsAskForTheKeyOrderOnly() async throws {
        let (hub, registry, _, store, home, helperDir) = try await make()
        defer { cleanup(store, home, helperDir) }
        _ = try await registry.perform(.dataConnectStart, .select("oracle"))
        let form = #"{"name":"","url":"scott/tiger@ora.example:1521/FREEPDB1","auth":"connectionString","user":"","secret":""}"#
        _ = try await registry.perform(.dataConnectSave, .set(form))
        let saved = try #require(hub.saved.first)
        #expect(saved.kind == .oracle && saved.name == "Oracle" && saved.url == "ora.example:1521/FREEPDB1")
        await hub.loadTable(.table(connection: saved.id, schema: "SCOTT", name: "EMP"))
        let seen = try String(contentsOf: helperDir.appendingPathComponent("seen.requests"), encoding: .utf8)
        let rowsRequest = try #require(seen.split(separator: "\n").last { $0.contains(#""op":"rows""#) })
        #expect(rowsRequest.contains(#""engine":"oracle""#) && rowsRequest.contains(#""orderBy":["id"]"#) && !rowsRequest.contains("ctid"))
    }

    @Test func aPastedURLWinsOverTheFields() async throws {
        let (hub, registry, vault, store, home, helperDir) = try await make()
        defer { cleanup(store, home, helperDir) }
        _ = try await registry.perform(.dataConnectStart, .select("sqlServer"))
        let form = #"{"name":"","url":"sqlserver://sa:P%40ss@sql.example:1433?database=sales","auth":"connectionString","user":"ignored","secret":"","host":"other","database":"other"}"#
        _ = try await registry.perform(.dataConnectSave, .set(form))
        let saved = try #require(hub.saved.first)
        #expect(saved.kind == .sqlServer && saved.url == "sql.example:1433/sales")
        #expect(try await vault.reveal(id: try #require(saved.secretID)).text == "sqlserver://sa:P%40ss@sql.example:1433?database=sales")
    }

    @Test func aRefusedLoginSavesNothing() async throws {
        let (hub, registry, vault, store, home, helperDir) = try await make()
        defer { cleanup(store, home, helperDir) }
        _ = try await registry.perform(.dataConnectStart, .select("mysql"))
        await #expect(throws: ActionError.self) { _ = try await registry.perform(.dataConnectSave, .set(Self.fieldsForm(password: "wrong-pw"))) }
        #expect(hub.saved.isEmpty && hub.connecting == .mysql)
        #expect(hub.connectError?.contains("refused") == true && hub.connectError?.contains("wrong-pw") == false)
        #expect(try await vault.list().isEmpty)

        // Faltando o que a conexão precisa, a mensagem diz o quê, sem chamar o helper.
        await #expect(throws: ActionError.self) { _ = try await registry.perform(.dataConnectSave, .set(Self.fieldsForm(host: ""))) }
        #expect(hub.connectError?.contains("no host") == true)
        _ = try await registry.perform(.dataConnectStart, .select("oracle"))
        await #expect(throws: ActionError.self) { _ = try await registry.perform(.dataConnectSave, .set(Self.fieldsForm(database: ""))) }
        #expect(hub.connectError?.contains("service name") == true)
    }

    @Test func healthShowsOfflineAndRefusedLikePostgres() async throws {
        let (hub, _, vault, store, home, helperDir) = try await make()
        defer { cleanup(store, home, helperDir) }
        let down = try await vault.create(NewSecret(name: "a", value: "mysql://app:pw@down.invalid:3306/shop", kind: .envVar, delivery: .sidecarOnly, note: ""))
        let refused = try await vault.create(NewSecret(name: "b", value: "mysql://app:wrong-pw@db.example:3306/shop", kind: .envVar, delivery: .sidecarOnly, note: ""))
        let fine = try await vault.create(NewSecret(name: "c", value: "oracle://scott:tiger@ora.example:1521/FREEPDB1", kind: .envVar, delivery: .sidecarOnly, note: ""))
        hub.saved = [
            SavedConnection(id: "down", kind: .mysql, name: "Down", url: "down.invalid:3306/shop", auth: .connectionString, secretID: down.id),
            SavedConnection(id: "refused", kind: .mysql, name: "Refused", url: "db.example:3306/shop", auth: .connectionString, secretID: refused.id),
            SavedConnection(id: "fine", kind: .oracle, name: "Fine", url: "ora.example:1521/FREEPDB1", auth: .connectionString, secretID: fine.id),
        ]
        hub.rebuildConnections()
        await hub.checkConnections()
        guard case .offline? = hub.health["down"] else { Issue.record("down: \(String(describing: hub.health["down"]))"); return }
        guard case .refused? = hub.health["refused"] else { Issue.record("refused: \(String(describing: hub.health["refused"]))"); return }
        #expect(hub.health["down"]?.short == "Not running" && hub.health["refused"]?.short == "Login refused" && hub.health["fine"] == .ok("2 tables"))
    }
}
