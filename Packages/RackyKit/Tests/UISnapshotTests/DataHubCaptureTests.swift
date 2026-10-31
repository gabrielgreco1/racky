import RackyCore
import RackyPlatform
import RackyProtocol
import RackyStore
import AppKit
import Foundation
import Testing

@testable import RackyUI

/// Prints da área Data (spec data-hub) com as conexões de exemplo: dataset do Racky, tabela do Supabase, consulta, pasta do S3,
/// webhook, planilha, "Add connection" e a tela vazia. Só roda com `RACKY_CAPTURE_DIR=<pasta>`.
@MainActor
@Suite(.serialized, .offscreenAppKit, .enabled(if: ProcessInfo.processInfo.environment["RACKY_CAPTURE_DIR"] != nil)) struct DataHubCaptureTests {
    private func write(_ view: NSView, _ name: String) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RACKY_CAPTURE_DIR"]!)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
    }

    @Test func captureDataScreens() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("racky-data-capture-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let env = AppEnvironment(environment: ["RACKY_SKIP_ONBOARDING": "1", "RACKY_HOME": home.path, "RACKY_TEST_HEADLESS": "1", "RACKY_DATA_DEMO": "1"])
        let cast = SidebarFixtures.full()
        env.sidebar.apply(cast.snapshot)
        let session = try #require(cast.selectedSessionID)
        env.sidebar.select(session)
        let c = await EmptyWindowTreeTests.host(env, size: NSSize(width: 1680, height: 980))
        defer { c.window?.close() }
        let store = try await RackyStore.open(paths: StorePaths(root: home))
        defer { Task { try? await store.close() } }
        try await store.save(Session(id: session, kind: .clean, folderPath: "/tmp/books", title: "Book prices"))
        await env.datasets.attach(store: store)
        let service = DatasetService(store: store)
        _ = try await service.define(
            session: session, name: "books2",
            columns: [DatasetColumn(name: "title", required: true), DatasetColumn(name: "price", type: .number), DatasetColumn(name: "rating", type: .integer), DatasetColumn(name: "url", type: .url)],
            key: ["url"])
        let titles = ["Cometh the Hour", "Crazy Love", "Daily Fantasy Sports", "Dear Mr. Knightley", "Demigods & Magicians", "Doctor Sleep", "Don't Get Caught", "Eat Fat, Get Thin"]
        // Em lotes ao longo do tempo, como uma coleta de verdade: o gráfico do Overview mostra a curva, não um degrau só.
        for batch in 0..<8 {
            _ = try await service.append(
                session: session, name: "books2",
                rows: (batch * 10..<batch * 10 + 10).map { i in
                    ["title": .string("\(titles[i % titles.count]) \(i)"), "price": .double(11.21 + Double(i * 7 % 50)), "rating": .int(1 + i % 5),
                     "url": .string("https://books.toscrape.com/catalogue/book_\(900 + i)")]
                }, provenance: .none)
            try await Task.sleep(for: .milliseconds(1500))
        }
        try await DatasetsFixture.seedHotels(service: service, session: session)
        await env.datasets.reloadList()
        _ = try? await env.registry.perform(.rightPanelToggle, .press)

        _ = try await env.registry.perform(.pageDatasets, .press)
        await VisualBatchTests.settle(600)
        write(c.window!.contentView!, "data-empty")

        let books = try #require(env.datasets.summaries.first { $0.dataset.name == "books2" })
        _ = try await env.registry.perform(.dataOpen, .select("dataset:\(books.dataset.id)"))
        await VisualBatchTests.settle(900)
        write(c.window!.contentView!, "data-dataset")

        // Janela estreita com o painel direito aberto: nada sai da tela, o lado direito encolhe.
        c.window?.setContentSize(NSSize(width: 1180, height: 860))
        _ = try? await env.registry.perform(.rightPanelToggle, .press)
        await VisualBatchTests.settle(700)
        write(c.window!.contentView!, "data-narrow-panel")
        _ = try? await env.registry.perform(.rightPanelToggle, .press)
        // Sidebar recolhida: o topo da área Data deixa o canto para os botões da janela.
        _ = try await env.registry.perform(.viewToggleSidebar, .press)
        await VisualBatchTests.settle(700)
        write(c.window!.contentView!, "data-sidebar-collapsed")
        // As duas recolhidas: o botão de reabrir o explorer e o da sidebar continuam à vista.
        _ = try await env.registry.perform(.dataToggleExplorer, .press)
        await VisualBatchTests.settle(600)
        write(c.window!.contentView!, "data-both-collapsed")
        _ = try await env.registry.perform(.dataToggleExplorer, .press)
        _ = try await env.registry.perform(.viewToggleSidebar, .press)
        c.window?.setContentSize(NSSize(width: 1680, height: 980))
        await VisualBatchTests.settle(500)

        _ = try await env.registry.perform(.dataOpen, .select("table:\(DataHubFixtures.supabase):public:books"))
        await VisualBatchTests.settle(500)
        write(c.window!.contentView!, "data-table-books")

        _ = try await env.registry.perform(.dataOpen, .select("table:\(DataHubFixtures.supabase):public:listings"))
        await VisualBatchTests.settle(500)
        write(c.window!.contentView!, "data-table-listings")
        _ = try await env.registry.perform(.dataTablePage, .select("next"))
        await VisualBatchTests.settle(400)
        write(c.window!.contentView!, "data-table-page2")
        _ = try await env.registry.perform(.dataTableTab, .select("structure"))
        await VisualBatchTests.settle(400)
        write(c.window!.contentView!, "data-table-structure")
        // A cópia no Supabase: as mesmas abas e os mesmos números da coleta no Mac.
        _ = try await env.registry.perform(.dataOpen, .select("table:\(DataHubFixtures.supabase):public:books"))
        _ = try await env.registry.perform(.dataTableTab, .select("overview"))
        await VisualBatchTests.settle(700)
        write(c.window!.contentView!, "data-copy-overview")
        _ = try await env.registry.perform(.dataTableTab, .select("writers"))
        await VisualBatchTests.settle(400)
        write(c.window!.contentView!, "data-table-writers")
        // O dataset no Mac: Overview e renomear.
        _ = try await env.registry.perform(.dataOpen, .select("dataset:\(books.dataset.id)"))
        _ = try await env.registry.perform(.dataTableTab, .select("overview"))
        await VisualBatchTests.settle(700)
        write(c.window!.contentView!, "data-dataset-overview")
        _ = try await env.registry.perform(.dataTableTab, .select("data"))
        _ = try await env.registry.perform(.dataRenameDataset, .select(books.dataset.id))
        await VisualBatchTests.settle(400)
        write(c.window!.contentView!, "data-rename")
        _ = try await env.registry.perform(.dataRenameDataset, .select("\(books.dataset.id)|Livros do teste"))
        await VisualBatchTests.settle(400)
        write(c.window!.contentView!, "data-renamed")

        _ = try await env.registry.perform(.dataNewQuery, .select(DataHubFixtures.supabase))
        _ = try await env.registry.perform(.dataQueryRun, .press)
        await VisualBatchTests.settle(500)
        write(c.window!.contentView!, "data-query")

        _ = try await env.registry.perform(.dataToggleNode, .select(DataHubFixtures.bucket))
        _ = try await env.registry.perform(.dataOpen, .select("folder:\(DataHubFixtures.bucket):books/2026-10-22"))
        await VisualBatchTests.settle(500)
        write(c.window!.contentView!, "data-folder")

        _ = try await env.registry.perform(.dataOpen, .select("webhook:\(DataHubFixtures.webhook)"))
        await VisualBatchTests.settle(500)
        write(c.window!.contentView!, "data-webhook")

        _ = try await env.registry.perform(.dataToggleNode, .select(DataHubFixtures.sheets))
        _ = try await env.registry.perform(.dataToggleNode, .select("\(DataHubFixtures.sheets)/pricing"))
        _ = try await env.registry.perform(.dataOpen, .select("sheet:\(DataHubFixtures.sheets):Hotel pricing:LA"))
        await VisualBatchTests.settle(500)
        write(c.window!.contentView!, "data-sheet")

        _ = try await env.registry.perform(.dataAddConnection, .press)
        await VisualBatchTests.settle(500)
        write(c.window!.contentView!, "data-connect")
        _ = try await env.registry.perform(.dataAddConnection, .select("close"))

        // Nova sessão gravando direto numa tabela de produção.
        let project = try #require(cast.snapshot.projects.first { $0.archivedAt == nil })
        _ = try await env.registry.perform(.projectNewSession, .select(project.id.uuidString))
        _ = try? await env.registry.perform(.composerSetDataDestination, .select("table:\(DataHubFixtures.supabase):public:listings"))
        await VisualBatchTests.settle(700)
        write(c.window!.contentView!, "data-composer")
        // Perfil que pula permissões + destino protegido: o primeiro Create pede confirmação.
        _ = try? await env.registry.perform(.composerSubmit, .press)
        await VisualBatchTests.settle(500)
        write(c.window!.contentView!, "data-composer-risk")
        _ = try? await env.registry.perform(.composerKeepEditing, .press)

        // Conexão de verdade: o formulário do Prefect e a tela de flow runs (servidor falso).
        _ = try? await env.registry.perform(.composerCancel, .press)
        await VisualBatchTests.settle(300)
        _ = try? await env.registry.perform(.dataAddConnection, .press)
        _ = try? await env.registry.perform(.dataConnectStart, .select("prefect"))
        await VisualBatchTests.settle(500)
        write(c.window!.contentView!, "data-connect-prefect")
        env.dataHub.prefectTransport = { request in
            let path = request.url?.path ?? ""
            let json = path.hasSuffix("/deployments/filter")
                ? #"[{"id":"d1","name":"austin-listings-daily"},{"id":"d2","name":"nyc-listings-backfill"}]"#
                : #"[{"id":"r1","name":"brave-otter","state_type":"RUNNING","state_name":"Running","deployment_id":"d1","work_pool_name":"data-ecs-pool","tags":["listings","us"],"start_time":"2026-10-22T20:00:00+00:00"},{"id":"r2","name":"calm-heron","state_type":"PENDING","state_name":"Pending","deployment_id":"d2","work_pool_name":"data-ecs-pool","tags":["listings"],"expected_start_time":"2026-10-22T20:05:00+00:00"}]"#
            return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        _ = try? await env.registry.perform(.dataConnectSave, .set(#"{"name":"RTI Prefect","url":"prefect.example.com","auth":"none"}"#))
        await VisualBatchTests.settle(900)
        write(c.window!.contentView!, "data-prefect-runs")

        // Supabase de verdade (banco falso): o formulário e uma tabela aberta.
        _ = try? await env.registry.perform(.dataAddConnection, .press)
        _ = try? await env.registry.perform(.dataConnectStart, .select("supabase"))
        await VisualBatchTests.settle(500)
        write(c.window!.contentView!, "data-connect-supabase")
        // O app de verdade tem o cofre do Keychain; aqui um cofre em memória num banco temporário.
        let vaultHome = FileManager.default.temporaryDirectory.appendingPathComponent("racky-cap-vault-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vaultHome) }
        let vaultStore = try await RackyStore.open(paths: StorePaths(root: vaultHome))
        await env.dataHub.attach(store: vaultStore, vault: SecretVault(store: vaultStore, keyring: VaultKeyring(backend: InMemoryMasterKeyBackend())))
        let database = DataPostgresConnectionTests.FakeDatabase()
        env.dataHub.postgresFactory = { _ in database }
        _ = try? await env.registry.perform(
            .dataConnectSave, .set(#"{"name":"Prod DB","url":"","auth":"connectionString","user":"","secret":"postgresql://postgres.abcd:pw@aws-0-us-east-1.pooler.supabase.com:6543/postgres"}"#))
        await VisualBatchTests.settle(800)
        if let saved = env.dataHub.saved.first(where: { $0.kind == .supabase }) {
            let table = DataObject.table(connection: saved.id, schema: "public", name: "listings")
            _ = try? await env.registry.perform(.dataOpen, .select(table.key))
            await env.dataHub.loadTable(table)
            await VisualBatchTests.settle(800)
            write(c.window!.contentView!, "data-postgres-table")
        }

        // S3: o formulário.
        _ = try? await env.registry.perform(.dataAddConnection, .press)
        _ = try? await env.registry.perform(.dataConnectStart, .select("s3"))
        await VisualBatchTests.settle(500)
        write(c.window!.contentView!, "data-connect-s3")
    }
}
