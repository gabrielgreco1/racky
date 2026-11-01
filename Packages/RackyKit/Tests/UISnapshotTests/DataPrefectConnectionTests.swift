import RackyCore
import RackyPlatform
import RackyProtocol
import RackyStore
import AppKit
import Foundation
import Testing

@testable import RackyUI

/// Conectar um Prefect pela área Data: o formulário testa e salva, a senha vai para o cofre (não para o estado do app), a tela de flow
/// runs lê o servidor (falso aqui) e o filtro troca o que aparece. Remover apaga a senha.
@MainActor
@Suite(.serialized) struct DataPrefectConnectionTests {
    nonisolated final class Server: @unchecked Sendable {
        var requests: [URLRequest] = []
        var status = 200
        func handle(_ request: URLRequest) -> (Data, HTTPURLResponse) {
            requests.append(request)
            let path = request.url?.path ?? ""
            let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            var json = "[]"
            if path.hasSuffix("/flow_runs/filter") {
                let states = ((body["flow_runs"] as? [String: Any])?["state"] as? [String: Any]).flatMap { ($0["type"] as? [String: Any])?["any_"] as? [String] } ?? []
                json = states.contains("FAILED")
                    ? #"[{"id":"f1","name":"sad-crab","state_type":"FAILED","state_name":"Failed","deployment_id":"d1","tags":[],"start_time":"2026-10-22T19:00:00+00:00","end_time":"2026-10-22T19:01:00+00:00"}]"#
                    : #"[{"id":"r1","name":"brave-otter","state_type":"RUNNING","state_name":"Running","deployment_id":"d1","work_pool_name":"data-ecs-pool","tags":["listings"],"start_time":"2026-10-22T20:00:00+00:00"}]"#
            } else if path.hasSuffix("/deployments/filter") {
                json = #"[{"id":"d1","name":"austin-listings-daily"}]"#
            }
            return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func make() async throws -> (DataHubController, ActionRegistry, Server, SecretVault, RackyStore, URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("racky-prefect-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let store = try await RackyStore.open(paths: StorePaths(root: home))
        let datasets = DatasetsController()
        let hub = DataHubController(datasets: datasets, demo: false)
        let server = Server()
        hub.prefectTransport = { request in server.handle(request) }
        let vault = SecretVault(store: store, keyring: VaultKeyring(backend: InMemoryMasterKeyBackend()))
        await hub.attach(store: store, vault: vault)
        let registry = ActionRegistry(flags: SliceFlags(current: .slice4), surface: FakeSurface())
        try hub.register(in: registry)
        return (hub, registry, server, vault, store, home)
    }

    @Test func connectReadsTheRunsAndKeepsThePasswordInTheVault() async throws {
        let (hub, registry, server, vault, store, home) = try await make()
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: home) } }
        _ = try await registry.perform(.dataAddConnection, .press)
        _ = try await registry.perform(.dataConnectStart, .select("prefect"))
        #expect(hub.connecting == .prefect)
        // Um tipo que ainda não conecta não abre formulário.
        await #expect(throws: ActionError.self) { _ = try await registry.perform(.dataConnectStart, .select("mysql")) }

        let form = #"{"name":"RTI Prefect","url":"prefect.example.com","auth":"basic","user":"admin","secret":"s3cret"}"#
        _ = try await registry.perform(.dataConnectSave, .set(form))
        let saved = try #require(hub.saved.first)
        #expect(saved.name == "RTI Prefect" && saved.url == "https://prefect.example.com/api" && saved.secretID != nil)
        #expect(hub.connecting == nil && !hub.showingConnect)
        // A senha está no cofre e não no estado salvo do app.
        let stored = try #require(try await store.uiState(DataHubController.savedKey, as: [SavedConnection].self))
        let json = String(data: try JSONEncoder().encode(stored), encoding: .utf8) ?? ""
        #expect(!json.contains("s3cret"))
        #expect(try await vault.reveal(id: try #require(saved.secretID)).text == "admin:s3cret")

        // A conexão aparece no explorer com "Flow runs", já aberto.
        #expect(hub.connection(saved.id)?.children.first?.kind == .runs)
        #expect(hub.active == .runs(connection: saved.id))
        await hub.refreshRuns(saved.id)
        let state = try #require(hub.runs[saved.id])
        #expect(state.rows.first?.name == "brave-otter" && state.deployments["d1"] == "austin-listings-daily" && state.error == nil)
        let grid = PrefectRunsView.grid(state)
        #expect(grid.rows.first?[1] == "brave-otter" && grid.rows.first?[2] == "austin-listings-daily" && grid.rows.first?[5] == "data-ecs-pool")
        #expect(server.requests.last?.value(forHTTPHeaderField: "Authorization") == "Basic \(Data("admin:s3cret".utf8).base64EncodedString())")

        // O filtro de falhas pede FAILED/CRASHED.
        _ = try await registry.perform(.dataRunsFilter, .select("failed"))
        #expect(hub.runs[saved.id]?.rows.first?.name == "sad-crab")

        // Remover tira a conexão e apaga a senha.
        let secretID = try #require(saved.secretID)
        _ = try await registry.perform(.dataConnectionRemove, .select(saved.id))
        #expect(hub.saved.contains { $0.id == saved.id }, "o primeiro clique só pede confirmação")
        _ = try await registry.perform(.dataConnectionRemove, .select("\(saved.id)|confirm"))
        #expect(hub.saved.isEmpty && hub.connection(saved.id) == nil)
        await #expect(throws: (any Error).self) { _ = try await vault.reveal(id: secretID) }
    }

    @Test func aRefusedConnectionShowsWhyAndSavesNothing() async throws {
        let (hub, registry, server, _, store, home) = try await make()
        defer { Task { try? await store.close(); try? FileManager.default.removeItem(at: home) } }
        server.status = 401
        _ = try await registry.perform(.dataConnectStart, .select("prefect"))
        await #expect(throws: ActionError.self) {
            _ = try await registry.perform(.dataConnectSave, .set(#"{"name":"","url":"prefect.example.com","auth":"basic","user":"admin","secret":"wrong"}"#))
        }
        #expect(hub.saved.isEmpty && hub.connecting == .prefect)
        #expect(hub.connectError == PrefectClient.Failure.unauthorized.description)
    }
}
