import RackyCore
import RackyProtocol
import RackyStore
import AppKit
import Foundation
import Testing

@testable import RackyUI

/// O caminho de quem usa: numa sessão com agentes e um dataset, abrir a tabela pelo "+", pôr ao lado do agente, voltar para as tabs
/// e seguir a trilha. Tudo com cliques de mouse de verdade (eventos da janela), não as ações direto.
@MainActor
@Suite(.serialized, .offscreenAppKit, .tags(.integration)) struct SessionDataFlowClickTests {
    private struct Rig {
        let env: AppEnvironment
        let window: NSWindow
        let controller: MainWindowController
        let store: RackyStore
        let home: URL
        let datasetID: String
    }

    private func make() async throws -> Rig {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("racky-flow-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let env = AppEnvironment(environment: ["RACKY_SKIP_ONBOARDING": "1", "RACKY_HOME": home.path, "RACKY_TEST_HEADLESS": "1", "RACKY_DATA_DEMO": "1"])
        let cast = SidebarFixtures.full()
        env.sidebar.apply(cast.snapshot)
        let session = try #require(cast.selectedSessionID)
        env.sidebar.select(session)
        let c = await EmptyWindowTreeTests.host(env, size: NSSize(width: 1500, height: 900))
        let window = try #require(c.window)
        window.makeKeyAndOrderFront(nil)
        let store = try await RackyStore.open(paths: StorePaths(root: home))
        try await store.save(Session(id: session, kind: .clean, folderPath: "/tmp/books", title: "Book prices"))
        await env.datasets.attach(store: store)
        let service = DatasetService(store: store)
        _ = try await service.define(session: session, name: "books2", columns: [DatasetColumn(name: "title", required: true)], key: ["title"])
        _ = try await service.append(session: session, name: "books2", rows: [["title": .string("Doctor Sleep")]], provenance: .none)
        await env.datasets.reloadList()
        let id = try #require(env.datasets.summaries.first { $0.dataset.name == "books2" }?.dataset.id)
        await VisualBatchTests.settle(500)
        return Rig(env: env, window: window, controller: c, store: store, home: home, datasetID: id)
    }

    private func close(_ rig: Rig) async {
        rig.window.close()
        try? await rig.store.close()
        try? FileManager.default.removeItem(at: rig.home)
    }

    /// Com `RACKY_FLOW_SHOTS=<pasta>`, salva a janela como ela está (para a rodada de testers por tarefa).
    private func shot(_ rig: Rig, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["RACKY_FLOW_SHOTS"], let view = rig.window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    private func click(_ rig: Rig, _ id: A11yID, count: Int = 1) throws {
        let frame = try #require(rig.env.elements.frame(of: id), "\(id.rawValue) is not on screen")
        let height = rig.window.contentView?.bounds.height ?? 0
        let point = CGPoint(x: frame.midX, y: height - frame.midY)
        for n in 1...count {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                rig.window.sendEvent(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: rig.window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: n, pressure: type == .leftMouseUp ? 0 : 1)!)
            }
        }
    }

    /// Bug do dono: com o dataset numa tab da sessão e a área Data sem nada aberto (o app recém-aberto), as abas Overview e
    /// Structure não respondiam: agiam no objeto da área Data.
    @Test func datasetTabControlsWorkWithNothingOpenInTheDataArea() async throws {
        let rig = try await make()
        defer { Task { await close(rig) } }
        _ = try await rig.env.registry.perform(.datasetOpen, .select(rig.datasetID))
        await VisualBatchTests.settle(500)
        let object = DataObject.dataset(rig.datasetID)
        if rig.env.dataHub.active != nil { _ = try await rig.env.registry.perform(.dataClose, .select(rig.env.dataHub.active!.key)) }
        #expect(rig.env.dataHub.active == nil, "a área Data sem nada aberto, como ao reabrir o app")
        try click(rig, .dataTableTab("overview"))
        await VisualBatchTests.settle(300)
        #expect(rig.env.dataHub.tableTab(object) == .overview)
        await VisualBatchTests.settle(1200)  // o gráfico termina de se desenhar antes da foto
        shot(rig, "flow-6-dataset-overview")
        #expect(rig.env.elements.frame(of: .datasetTable) != nil, "a grade continua na tela com o painel aberto")
        try click(rig, .dataTableTab("structure"))
        await VisualBatchTests.settle(300)
        #expect(rig.env.dataHub.tableTab(object) == .structure)
        shot(rig, "flow-7-dataset-structure")
        // Clicar de novo no mesmo botão recolhe o painel; o botão de minimizar faz o mesmo.
        try click(rig, .dataTableTab("structure"))
        await VisualBatchTests.settle(300)
        #expect(rig.env.dataHub.tableTab(object) == .data)
        try click(rig, .dataTableTab("writers"))
        await VisualBatchTests.settle(300)
        #expect(rig.env.dataHub.tableTab(object) == .writers)
        shot(rig, "flow-8-dataset-writers")
        try click(rig, .dataPanelCollapse)
        await VisualBatchTests.settle(300)
        #expect(rig.env.dataHub.tableTab(object) == .data)
        // Bug do dono: com título longo o ✕ da tab ativa ficava em cima das letras; o título corta antes dele.
        if let tab = rig.env.workspace.activeTab {
            rig.env.workspace.commitRename("confirmar-estrutura-do-projeto-e-mediadores", tabID: tab.id)
            await VisualBatchTests.settle(300)
            shot(rig, "flow-9-long-tab-title")
        }
    }

    /// Abre a tabela, vai para o agente e volta clicando na tab da tabela: as duas tabs têm nomes diferentes e o clique troca de tab.
    @Test func goingToTheAgentAndBackToTheTableByClickingTabs() async throws {
        let rig = try await make()
        defer { Task { await close(rig) } }
        let agentTab = try #require(rig.env.workspace.activeTab)
        _ = try await rig.env.registry.perform(.datasetOpen, .select(rig.datasetID))
        await VisualBatchTests.settle(500)
        let datasetTab = try #require(rig.env.workspace.activeTab)
        #expect(datasetTab.id != agentTab.id)
        #expect(rig.env.workspace.displayTitle(of: agentTab) != rig.env.workspace.displayTitle(of: datasetTab), "two tabs with the same name can't be told apart")
        try click(rig, .tabsTab(agentTab.id.uuidString))
        await VisualBatchTests.settle(400)
        shot(rig, "flow-6-agent-tab-with-table-tab")
        #expect(rig.env.workspace.activeTab?.id == agentTab.id, "clicking the agent's tab shows the agent")
        try click(rig, .tabsTab(datasetTab.id.uuidString))
        await VisualBatchTests.settle(400)
        #expect(rig.env.workspace.activeTab?.id == datasetTab.id, "clicking the table's tab goes back to the table")
    }


    /// O "+" abre o menu logo abaixo dele (não no canto da janela), com seções nomeadas e o dataset da sessão.
    @Test func plusOpensTheMenuUnderItAndOffersTheSessionData() async throws {
        let rig = try await make()
        defer { Task { await close(rig) } }
        shot(rig, "flow-1-session")
        try click(rig, .tabsNew)
        await VisualBatchTests.settle(500)
        shot(rig, "flow-2-plus-menu")
        // A view do menu na janela (os frames de dentro do menu são relativos a ele).
        func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
        let root = try #require(rig.window.contentView)
        let plus = try #require(rig.env.elements.frame(of: .tabsNew))
        let menu = try #require(views(root).first { abs($0.frame.width - QuickLaunchModel.width) < 1 && $0 !== root }, "the menu should open")
        let menuFrame = menu.convert(menu.bounds, to: nil)
        let menuTop = root.bounds.height - menuFrame.maxY
        #expect(abs(menuTop - plus.maxY) < 40, "the menu hangs right under the + (menu top \(menuTop), + bottom \(plus.maxY))")
        #expect(abs(menuFrame.minX - plus.minX) < QuickLaunchModel.width, "the menu sits by the +, not in the window corner (x \(menuFrame.minX), + \(plus.minX))")
        // Digita o nome e aperta Enter: "Open books2" abre a tabela numa tab da sessão.
        func key(_ chars: String, code: UInt16) throws {
            rig.window.sendEvent(try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: rig.window.windowNumber,
                context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)))
        }
        for ch in "books2" { try key(String(ch), code: 0) }
        await VisualBatchTests.settle(200)
        try key("\r", code: 36)
        await VisualBatchTests.settle(600)
        shot(rig, "flow-3-table-tab")
        let active = try #require(rig.env.workspace.activeTab)
        #expect(rig.env.workspace.datasetOnly(active) == rig.datasetID, "Open books2 should show the table in its own tab")
        #expect(rig.env.workspace.displayTitle(of: active) == "books2")
    }

    /// Da tab do dataset, "Beside the agent" junta a tabela com o agente na mesma tab; o nome da tab dos agentes não vira books2.
    @Test func besideTheAgentFromTheDatasetTabJoinsTheAgentTab() async throws {
        let rig = try await make()
        defer { Task { await close(rig) } }
        _ = try await rig.env.registry.perform(.datasetOpen, .select(rig.datasetID))
        await VisualBatchTests.settle(600)
        try click(rig, .dataBeside)
        await VisualBatchTests.settle(600)
        shot(rig, "flow-4-beside")
        let active = try #require(rig.env.workspace.activeTab)
        #expect(!active.layout.terminalIDs.isEmpty, "the table should now sit in the agent's tab")
        #expect(active.layout.pane(forDataset: rig.datasetID) != nil)
        #expect(rig.env.workspace.displayTitle(of: active) != "books2", "the agents' tab keeps its own name")
        // Ao lado do agente, "Own tab" devolve a tabela para uma tab própria.
        try click(rig, .dataOwnTab)
        await VisualBatchTests.settle(500)
        let own = try #require(rig.env.workspace.activeTab)
        #expect(rig.env.workspace.datasetOnly(own) == rig.datasetID, "Own tab puts the table back in its own tab")
    }

    /// A tabela que a sessão coletou aparece no card dela na sidebar; um clique abre a tabela numa tab da sessão.
    @Test func theSessionCardListsItsTableAndOpensIt() async throws {
        let rig = try await make()
        defer { Task { await close(rig) } }
        await rig.env.datasets.reloadList()
        await VisualBatchTests.settle(400)
        let session = try #require(rig.env.workspace.currentSessionID)
        try click(rig, .sidebarSessionDataset(session.uuidString, rig.datasetID))
        await VisualBatchTests.settle(500)
        let active = try #require(rig.env.workspace.activeTab)
        #expect(rig.env.workspace.datasetOnly(active) == rig.datasetID, "the sidebar row opens the table in a session tab")
    }

    /// Vendo a tabela na área Data, "Open in session" leva para uma tab da sessão que a coletou.
    @Test func openInSessionFromTheDataArea() async throws {
        let rig = try await make()
        defer { Task { await close(rig) } }
        _ = try await rig.env.registry.perform(.pageDatasets, .press)
        _ = try await rig.env.registry.perform(.dataOpen, .select("dataset:\(rig.datasetID)"))
        await VisualBatchTests.settle(600)
        try click(rig, .dataOpenInSession)
        await VisualBatchTests.settle(600)
        #expect(rig.env.datasets.currentPage() == .workspace, "goes back to the session")
        let active = try #require(rig.env.workspace.activeTab)
        #expect(rig.env.workspace.datasetOnly(active) == rig.datasetID)
    }
}
