import RackyCore
import RackyDesignSystem
import RackyProtocol
import SwiftUI

/// Registro dos módulos do painel direito (10-right-panel). Um módulo novo implementa `RightPanelModule` e entra aqui.
@MainActor
enum RightPanelModules {
    static func registerAll(into controller: RightPanelController, env: AppEnvironment) {
        controller.register(FilesModule(controller: env.files))
        controller.register(makeInsightsModule(env: env))
        controller.register(ComputersModule(controller: env.computers, traffic: env.traffic, insights: env.insights))
        controller.register(DataModule(datasets: env.datasets))
        if let conversations = env.conversations { controller.register(ConversationsModule(controller: conversations)) }
        if env.flags.isEnabled(.slice2) {
            controller.register(SourceControlModule(controller: env.github))
            controller.register(ChecksModule(controller: env.github))
        }
        if env.flags.offersSlice4 { controller.register(ContextModule(controller: env.context)) }
    }

    static func makeInsightsModule(env: AppEnvironment) -> any RightPanelModule {
        InsightsModule(model: env.insights)
    }
}

/// Insights (uso de IA e máquina) como módulo do painel; mantém o botão da faixa de topo.
@MainActor
final class InsightsModule: RightPanelModule {
    let id = PanelModuleID.insights
    let title = String(localized: "Insights", bundle: .module)
    let icon = "chart.xyaxis.line"
    let toggleAction: ActionID? = .rightPanelToggleInsights
    let stripButtonID: A11yID? = .tabsInsightsToggle
    private let model: InsightsModel

    init(model: InsightsModel) { self.model = model }

    func makeView(context: RightPanelModuleContext) -> AnyView {
        AnyView(InsightsModuleView(model: model, compact: context.isCompact))
    }
}

/// Computers da sessão (03 §10.4): por computador, a tela, o tráfego, a máquina, os proxies com o custo e as requests ao vivo.
/// Tem botão na faixa de topo (⌥⌘4) como Files, Insights e Data.
@MainActor
final class ComputersModule: RightPanelModule {
    let id = PanelModuleID.computers
    let title = String(localized: "Computers", bundle: .module)
    let icon = "display"
    let toggleAction: ActionID? = .rightPanelToggleComputers
    let stripButtonID: A11yID? = .tabsComputersToggle
    private let controller: ComputersController
    private let traffic: TrafficController
    private let insights: InsightsModel

    init(controller: ComputersController, traffic: TrafficController, insights: InsightsModel) {
        self.controller = controller; self.traffic = traffic; self.insights = insights
    }

    func makeView(context: RightPanelModuleContext) -> AnyView {
        AnyView(ComputersModuleBody(controller: controller, traffic: traffic, insights: insights))
    }

    func makeHeaderAccessory(context: RightPanelModuleContext) -> AnyView? {
        guard !context.isCompact else { return nil }
        return AnyView(
            Text(verbatim: controller.model.summaryText)
                .font(DS.Font.small.font)
                .foregroundStyle(DS.Color.textTertiary)
                .lineLimit(1))
    }
}

/// Conversations (03 §10.5) como módulo do painel; abre por ⇧⌘H e não tem botão na faixa de topo.
@MainActor
final class ConversationsModule: RightPanelModule {
    let id = PanelModuleID.conversations
    let title = String(localized: "Conversations", bundle: .module)
    let icon = "clock.arrow.circlepath"
    private let controller: ConversationsController

    init(controller: ConversationsController) { self.controller = controller }

    func makeView(context: RightPanelModuleContext) -> AnyView {
        AnyView(ConversationsView(controller: controller))
    }
}

/// O detalhe `Result` de um computador quando aberto; senão o painel de tráfego.
private struct ComputersModuleBody: View {
    let controller: ComputersController
    let traffic: TrafficController
    let insights: InsightsModel

    var body: some View {
        if let detail = controller.detail {
            ComputerDetailView(controller: controller, detail: detail)
        } else {
            ComputersInsightsPanel(computers: controller, traffic: traffic, insights: insights)
        }
    }
}
