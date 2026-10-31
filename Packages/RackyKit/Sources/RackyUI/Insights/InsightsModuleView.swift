import RackyCore
import RackyDesignSystem
import SwiftUI

/// Raiz do módulo Insights do painel direito. Adapta-se continuamente ao espaço (`InsightsAdaptive`): duas colunas, uma coluna ou
/// só barras e números principais; `compact` força o modo compacto e abaixo de `InsightsMetrics.iconTabsBelowWidth` as abas viram ícones.
public struct InsightsModuleView: View {
    @Bindable private var model: InsightsModel
    private let forceCompact: Bool
    @Namespace private var tabNamespace

    public init(model: InsightsModel, compact: Bool = false) {
        self.model = model
        self.forceCompact = compact
    }

    public var body: some View {
        GeometryReader { proxy in
            let narrow = forceCompact || proxy.size.width < InsightsMetrics.iconTabsBelowWidth
            // Compacto forçado (contêiner estreito) vale como largura abaixo do breakpoint médio.
            let width = forceCompact ? min(proxy.size.width, InsightsMetrics.mediumMinWidth - 1) : proxy.size.width
            let gutter = narrow ? DS.Space.s2 : DS.Space.s3
            VStack(spacing: .zero) {
                tabStrip(compact: narrow)
                    .padding(.horizontal, gutter)
                    .padding(.vertical, DS.Space.s2)
                    .layoutProbe("tabs")
                pane(width: width)
                    .padding(.horizontal, gutter)
                    .padding(.bottom, DS.Space.s2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .layoutProbeRoot()
        }
        .background(DS.Color.panel)
        .onAppear { model.viewDidAppear() }
        .onDisappear { model.viewDidDisappear() }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func pane(width: CGFloat) -> some View {
        switch model.tab {
        case .claude:
            InsightsProviderPane(summary: model.snapshot.claude, now: model.now, width: width,
                                 limitsStatus: model.snapshot.claudeLimits, scanning: model.snapshot.scanning)
        case .codex:
            InsightsProviderPane(summary: model.snapshot.codex, now: model.now, width: width, scanning: model.snapshot.scanning)
        case .machine:
            InsightsMachinePane(snapshot: model.snapshot, history: model.history, sortByMemory: $model.appsSortedByMemory, width: width)
        case .proxy: InsightsProxyPane(proxies: model.snapshot.proxies, width: width)
        }
    }

    private func tabStrip(compact: Bool) -> some View {
        HStack(spacing: .zero) {
            ForEach(InsightsTab.allCases) { tab in
                let active = tab == model.tab
                // lint-ui: allow buttons seletor de aba local do módulo; não é uma ação do app
                Button { model.tab = tab } label: { tabLabel(tab, compact: compact) }
                    .buttonStyle(DSSegmentStyle(active: active, fillWidth: true))
                    .background {
                        if active {
                            RoundedRectangle(cornerRadius: DS.Radius.sm).fill(DS.Color.accent)
                                .matchedGeometryEffect(id: "insights-tab", in: tabNamespace)
                        }
                    }
                    .accessibilityAddTraits(active ? .isSelected : [])
                    .accessibilityLabel(Text(tab.title, bundle: .module))
            }
        }
        .padding(DSMetrics.segmentedPadding)
        .frame(height: DSMetrics.segmentedHeight)
        .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.Color.secondary))
        .animation(MotionPolicy.shared.animation(MotionTokens.Springs.snappy), value: model.tab)
    }

    @ViewBuilder private func tabLabel(_ tab: InsightsTab, compact: Bool) -> some View {
        if compact {
            switch tab {
            case .claude: DSAgentLogo(DSAgentKind.claude, size: DS.Space.s3)
            case .codex: DSAgentLogo(DSAgentKind.codex, size: DS.Space.s3)
            case .machine: Image(systemName: "gauge.with.dots.needle.bottom.50percent").font(.system(size: DS.Space.s3))
            case .proxy: Image(systemName: "network").font(.system(size: DS.Space.s3))
            }
        } else {
            Text(tab.title, bundle: .module)
        }
    }
}

extension InsightsTab {
    var title: LocalizedStringKey {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .machine: "Machine"
        case .proxy: "Proxy"
        }
    }
}
