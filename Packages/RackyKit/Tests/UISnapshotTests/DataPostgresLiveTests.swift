import RackyCore
import RackyPlatform
import RackyProtocol
import RackyStore
import AppKit
import Foundation
import Testing

@testable import RackyUI

/// O fluxo inteiro da área Data contra um Postgres de verdade (`RACKY_PG_TEST_URL`, com `shop.books` de 250 linhas): o formulário
/// conecta com o conector real, o explorer lista o catálogo, a tabela abre paginada pela chave e o SQL recusa escrita.
@MainActor
@Suite(.tags(.integration), .serialized, .enabled(if: ProcessInfo.processInfo.environment["RACKY_PG_TEST_URL"] != nil))
struct DataPostgresLiveTests {
    @Test func connectBrowsePageAndQueryAgainstARealServer() async throws {
        let url = try #require(ProcessInfo.processInfo.environment["RACKY_PG_TEST_URL"])
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("racky-pg-live-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let store = try await RackyStore.open(paths: StorePaths(root: home))
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: home) } }
        let hub = DataHubController(datasets: DatasetsController(), demo: false)
        await hub.attach(store: store, vault: SecretVault(store: store, keyring: VaultKeyring(backend: InMemoryMasterKeyBackend())))
        let registry = ActionRegistry(flags: SliceFlags(current: .slice4), surface: FakeSurface())
        try hub.register(in: registry)

        _ = try await registry.perform(.dataConnectStart, .select("postgres"))
        let form = try String(data: JSONSerialization.data(withJSONObject: ["name": "Local", "url": "", "auth": "connectionString", "user": "", "secret": url]), encoding: .utf8)!
        _ = try await registry.perform(.dataConnectSave, .set(form))
        let saved = try #require(hub.saved.first)

        // O catálogo chega do servidor (o salvar já pede a leitura).
        for _ in 0 ..< 100 where hub.connection(saved.id)?.children.contains(where: { $0.name == "shop" }) != true {
            try await Task.sleep(for: .milliseconds(50))
        }
        let shop = try #require(hub.connection(saved.id)?.children.first { $0.name == "shop" })
        #expect(shop.children.map(\.name).contains("books") && shop.children.map(\.name).contains("cheap"))

        let table = DataObject.table(connection: saved.id, schema: "shop", name: "books")
        _ = try await registry.perform(.dataOpen, .select(table.key))
        await hub.loadTable(table)
        #expect(hub.tableGrid(table).rows.count == 100 && hub.tableGrid(table).total == 250 && hub.pageCount(for: table) == 3)
        _ = try await registry.perform(.dataTablePage, .select("next"))
        for _ in 0 ..< 100 where hub.tableGrid(table).rows.first?.first != "101" { try await Task.sleep(for: .milliseconds(50)) }
        #expect(hub.tableGrid(table).rows.first?.first == "101", "página 2 em ordem numérica da chave")

        let query = hub.newQuery(on: saved.id)
        hub.queryText[query] = "select count(*) from shop.books"
        _ = try await registry.perform(.dataQueryRun, .press)
        #expect(hub.queryResult[query]?.grid.rows.first?.first == "250")
        hub.queryText[query] = "delete from shop.books"
        _ = try await registry.perform(.dataQueryRun, .press)
        #expect(hub.queryErrors[query]?.contains("read-only") == true)
        _ = try await registry.perform(.dataConnectionRemove, .select(saved.id))
        #expect(hub.saved.contains { $0.id == saved.id }, "o primeiro clique só pede confirmação")
        _ = try await registry.perform(.dataConnectionRemove, .select("\(saved.id)|confirm"))
    }
}
