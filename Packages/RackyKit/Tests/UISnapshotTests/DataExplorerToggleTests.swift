import RackyProtocol
import Testing

@testable import RackyUI

/// Bug do teste completo: com a lista recolhida por falta de largura (painel direito aberto), "Show Data list" mandava um toggle
/// e escondia o que já estava invisível. O botão agora diz o que quer ("show"/"hide") e o pedido de mostrar vence o recolhimento.
@MainActor
@Suite struct DataExplorerToggleTests {
    func hub() throws -> (DataHubController, ActionRegistry) {
        let hub = DataHubController(datasets: DatasetsController(), demo: false)
        let registry = ActionRegistry(flags: SliceFlags(current: .slice4), surface: FakeSurface())
        try hub.register(in: registry)
        return (hub, registry)
    }

    @Test func showForcesTheListAndHideHidesIt() async throws {
        let (hub, registry) = try hub()
        #expect(!hub.explorerHidden && !hub.explorerForced)
        _ = try await registry.perform(.dataToggleExplorer, .select("show"))
        #expect(!hub.explorerHidden && hub.explorerForced, "mostrar mesmo sem a largura do recolhimento automático")
        _ = try await registry.perform(.dataToggleExplorer, .select("hide"))
        #expect(hub.explorerHidden && !hub.explorerForced)
        _ = try await registry.perform(.dataToggleExplorer, .select("show"))
        #expect(!hub.explorerHidden)
    }

    @Test func plainPressStillToggles() async throws {
        let (hub, registry) = try hub()
        _ = try await registry.perform(.dataToggleExplorer, .press)
        #expect(hub.explorerHidden)
        _ = try await registry.perform(.dataToggleExplorer, .press)
        #expect(!hub.explorerHidden && hub.explorerForced)
    }
}
