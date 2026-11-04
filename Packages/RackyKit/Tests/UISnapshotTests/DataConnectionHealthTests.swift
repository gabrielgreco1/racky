import RackyCore
import RackyPlatform
import RackyProtocol
import RackyStore
import Foundation
import Testing

@testable import RackyUI

/// O explorer diz se cada conexão responde sem precisar abrir, e uma leitura que trava não deixa a conexão em "Reading schemas…".
@MainActor
@Suite(.serialized) struct DataConnectionHealthTests {
    /// Banco falso: responde, recusa a senha, ou trava ignorando o cancelamento (como o connect do NIO às vezes faz).
    nonisolated final class Database: PostgresBrowsing, @unchecked Sendable {
        enum Mode { case ok, refused, offline, hang }
        var mode: Mode
        init(_ mode: Mode) { self.mode = mode }
        func check() async throws {}
        func schemas() async throws -> [String] { ["public"] }
        func tables(schema: String) async throws -> [PostgresTable] { [] }
        func catalog() async throws -> [PostgresSchema] {
            switch mode {
            case .ok: return [PostgresSchema(name: "public", tables: [PostgresTable(schema: "public", name: "a", isView: false, estimatedRows: 1),
                                                                       PostgresTable(schema: "public", name: "b", isView: false, estimatedRows: 2)])]
            case .refused: throw PostgresConnector.Failure.auth("password authentication failed")
            case .offline: throw PostgresConnector.Failure.unreachable("connection refused")
            case .hang:
                // Não olha o cancelamento: só o prazo de quem chama pode destravar.
                for _ in 0..<40 { usleep(50_000); await Task.yield() }  // ~2 s, para não prender uma thread do teste para sempre
                return []
            }
        }
        func columns(schema: String, table: String) async throws -> [PostgresColumn] { [] }
        func rowCount(schema: String, table: String) async throws -> PostgresRowCount { PostgresRowCount(value: 0, exact: true) }
        func rows(schema: String, table: String, limit: Int, offset: Int, orderBy: [String]) async throws -> PostgresResult { PostgresResult(columns: [], rows: []) }
        func query(sql: String, limit: Int) async throws -> PostgresResult { PostgresResult(columns: [], rows: []) }
    }

    private func hub(_ mode: Database.Mode) async throws -> (DataHubController, RackyStore, URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("racky-health-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let store = try await RackyStore.open(paths: StorePaths(root: home))
        let hub = DataHubController(datasets: DatasetsController(), demo: false)
        let database = Database(mode)
        hub.postgresFactory = { _ in database }
        let vault = SecretVault(store: store, keyring: VaultKeyring(backend: InMemoryMasterKeyBackend()))
        await hub.attach(store: store, vault: vault)
        let secret = try await vault.create(NewSecret(name: "db", value: "postgresql://u:p@db.example:5432/app", kind: .envVar, delivery: .sidecarOnly, note: ""))
        hub.saved = [SavedConnection(id: "c1", kind: .postgres, name: "Local", url: "db.example:5432/app", auth: .connectionString, secretID: secret.id)]
        hub.rebuildConnections()
        return (hub, store, home)
    }

    @Test func connectedShowsTableCountWithoutOpening() async throws {
        let (hub, store, home) = try await hub(.ok)
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: home) } }
        await hub.checkConnections()
        #expect(hub.health["c1"] == .ok("2 tables"))
        #expect(!hub.expanded.contains("c1/public"))  // checar não abre nada na árvore
    }

    @Test func refusedAndOfflineAreTold() async throws {
        let (refused, s1, h1) = try await hub(.refused)
        let (offline, s2, h2) = try await hub(.offline)
        defer { Task { try? await s1.close(); try? await s2.close(); try? FileManager.default.removeItem(at: h1); try? FileManager.default.removeItem(at: h2) } }
        await refused.checkConnections()
        await offline.checkConnections()
        #expect(refused.health["c1"]?.short == "Login refused")
        #expect(offline.health["c1"]?.short == "Not running")
        // Quem falhou é olhado de novo depois do intervalo curto; antes disso, não.
        await offline.checkConnections()
        #expect(offline.healthCheckedAt["c1"] != nil)
    }

    @Test func deadlineReturnsEvenWhenTheWorkIgnoresCancellation() async throws {
        let started = Date()
        await #expect(throws: PostgresConnector.Failure.timeout) {
            try await PostgresConnector.withDeadline(0.3) { () async throws -> Int in
                for _ in 0..<40 { usleep(50_000); await Task.yield() }
                return 0
            }
        }
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test func deadlinePassesTheResultThrough() async throws {
        let value = try await PostgresConnector.withDeadline(5) { 42 }
        #expect(value == 42)
    }
}
