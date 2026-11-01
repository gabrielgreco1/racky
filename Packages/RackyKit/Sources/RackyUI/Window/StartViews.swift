import RackyCore
import RackyDesignSystem
import RackyProtocol
import RackyStore
import SwiftUI

/// Medidas da tela inicial e da sessão vazia.
enum StartMetrics {
    static let logo: CGFloat = 56
    static let cardWidth: CGFloat = 196
    static let cardHeight: CGFloat = 124
    static let agentCardWidth: CGFloat = 148
    static let agentCardHeight: CGFloat = 88
    static let icon: CGFloat = 20
    static let column: CGFloat = 632
    static let agentLogo: CGFloat = 28
    static let agentTileHeight: CGFloat = 116
    static let projectRowHeight: CGFloat = 60
    static let rowIcon: CGFloat = 18
    static let rowIconTile: CGFloat = 34
    static let agentHeroLogo: CGFloat = 44
    static let agentHeroHeight: CGFloat = 148
    static let hoverScale: CGFloat = 1.06
    static let actionRow: CGFloat = 28
    static let blockGap: CGFloat = 32
    static let panelTop: CGFloat = 56
}

/// Card de ação das telas de início: ícone (ou logo do agente), título, uma linha do que faz e o atalho. Passa pelo registro
/// de ações (a automação enxerga) e acende no hover.
struct StartCard<Icon: View>: View {
    let action: ActionID
    let id: A11yID
    var argument: ActionArgument = .press
    let title: String
    let detail: String?
    var width: CGFloat = StartMetrics.cardWidth
    var height: CGFloat = StartMetrics.cardHeight
    @ViewBuilder let icon: () -> Icon
    @State private var hovering = false

    var body: some View {
        ActionButton(action, id: id, argument: argument) {
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                HStack(alignment: .top) {
                    icon().frame(width: StartMetrics.icon, height: StartMetrics.icon)
                    Spacer(minLength: .zero)
                    let key = action.spec.shortcut
                    if !key.isEmpty {
                        Text(verbatim: key).dsFont(DS.Font.keycap).foregroundStyle(DS.Color.textTertiary)
                    }
                }
                Spacer(minLength: .zero)
                Text(verbatim: title).dsFont(DS.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                if let detail {
                    Text(verbatim: detail).dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(DS.Space.s4)
            .frame(width: width, height: height, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(hovering ? DS.Color.hoverRow : DS.Color.chrome))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(hovering ? DS.Color.borderStrong : DS.Color.border))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.card))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(MotionPolicy.shared.animation(MotionTokens.Springs.snappy), value: hovering)
    }
}

/// Tela inicial (nenhuma sessão selecionada), centrada e com pouca coisa: a marca, um botão grande por agente (abre uma sessão
/// limpa com ele, F37), dois atalhos que dizem o estado e levam às páginas (Computers e Data) e os caminhos de projeto.
struct LandingView: View {
    let automationOn: Bool
    let sidebar: SidebarModel
    let settings: SettingsModel
    var computers: ComputersController?
    var datasets: DatasetsController?
    var statusBar: StatusBarController?
    @Environment(\.actionRegistry) private var registry

    private static let agents: [TerminalProvider] = [.claude, .codex, .opencode]

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: StartMetrics.blockGap) {
                    VStack(spacing: DS.Space.s2) {
                        BrandMark(size: StartMetrics.logo)
                        Text("Racky", bundle: .module).dsFont(DS.Font.display).foregroundStyle(DS.Color.textPrimary).padding(.top, DS.Space.s2)
                        Text("Run coding agents side by side, and give each subagent its own computer.", bundle: .module)
                            .dsFont(DS.Font.dialogBody).foregroundStyle(DS.Color.textSecondary).multilineTextAlignment(.center)
                    }
                    if registry?.isOffered(.sessionNewClean) ?? true {
                        HStack(spacing: DS.Space.s3) {
                            ForEach(Self.agents, id: \.self) { provider in
                                LandingAgentTile(
                                    provider: provider, installed: settings.agent(provider)?.installedState != false,
                                    isDefault: settings.settings.agents.defaultAgent == provider)
                            }
                        }
                    }
                    HStack(spacing: DS.Space.s3) {
                        LandingShortcut(action: .pageComputers, id: .landingComputers, symbol: "desktopcomputer",
                                        title: String(localized: "Computers", bundle: .module), value: computersValue, alert: computersAlert)
                        LandingShortcut(action: .pageDatasets, id: .landingData, symbol: "tablecells",
                                        title: String(localized: "Data", bundle: .module), value: dataValue)
                    }
                    HStack(spacing: DS.Space.s4) {
                        if registry?.isOffered(.projectAdd) ?? true {
                            LandingLink(action: .projectAdd, id: .landingAddProject, symbol: "folder", title: String(localized: "Open a Folder…", bundle: .module))
                        }
                        if registry?.isOffered(.projectCloneFromGitHub) ?? true {
                            LandingLink(action: .projectCloneFromGitHub, id: .landingCloneProject, symbol: nil, title: String(localized: "Clone from GitHub…", bundle: .module))
                        }
                    }
                }
                .frame(width: StartMetrics.column)
                .padding(.vertical, StartMetrics.panelTop)
                .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
            .scrollIndicators(.never)
        }
        .background(DS.Color.canvas)
        .ignoresSafeArea()
        .overlay(alignment: .topTrailing) {
            // Selo do canal de automação (AR-806): fora da faixa de 280 pt, que não comporta o texto ao lado dos controles.
            if automationOn {
                Text("Automation on", bundle: .module)
                    .font(DS.Font.micro.font)
                    .foregroundStyle(DS.Color.warning)
                    .padding(DS.Space.s2)
                    .a11y(.windowAutomationBadge, kind: "text", label: "Automation on")
            }
        }
        .a11y(.landing, kind: "container")
    }

    private var computersValue: String {
        let count = computers?.model.rows.count ?? 0
        return count == 0 ? String(localized: "None running", bundle: .module) : String(localized: "\(count) running", bundle: .module)
    }

    private var computersAlert: String? {
        let waiting = computers?.model.rows.filter(\.needsYou).count ?? 0
        return waiting > 0 ? String(localized: "\(waiting) need you", bundle: .module) : nil
    }

    private var dataValue: String {
        let summaries = datasets?.summaries ?? []
        if summaries.isEmpty { return String(localized: "None yet", bundle: .module) }
        let rows = summaries.reduce(0) { $0 + $1.rowCount }
        return String(localized: "\(rows.formatted()) rows · \(summaries.count) datasets", bundle: .module)
    }
}

/// Atalho da landing: ícone, nome da página e o estado dela numa linha; clique abre a página.
private struct LandingShortcut: View {
    let action: ActionID
    let id: A11yID
    let symbol: String
    let title: String
    let value: String
    var alert: String?
    @State private var hovering = false

    var body: some View {
        ActionButton(action, id: id) {
            HStack(spacing: DS.Space.s3) {
                Image(systemName: symbol).dsFont(DS.Font.control).foregroundStyle(DS.Color.textPrimary)
                    .frame(width: StartMetrics.rowIconTile, height: StartMetrics.rowIconTile)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.Color.secondary))
                VStack(alignment: .leading, spacing: DS.Space.s0_5) {
                    Text(verbatim: title).dsFont(DS.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary)
                    HStack(spacing: DS.Space.s1_5) {
                        Text(verbatim: value).dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary).lineLimit(1)
                        if let alert {
                            Text(verbatim: alert).dsFont(DS.Font.small).foregroundStyle(DS.Color.warning).lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: DS.Space.s2)
                Image(systemName: "chevron.right").dsFont(DS.Font.small).foregroundStyle(hovering ? DS.Color.textSecondary : DS.Color.textTertiary)
            }
            .padding(.horizontal, DS.Space.s3)
            .frame(maxWidth: .infinity, minHeight: StartMetrics.projectRowHeight, maxHeight: StartMetrics.projectRowHeight)
            .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(hovering ? DS.Color.secondary : DS.Color.chrome))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(hovering ? DS.Color.borderStrong : DS.Color.border))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.card))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(MotionPolicy.shared.animation(MotionTokens.Springs.snappy), value: hovering)
    }
}

/// Link discreto da landing (projeto): ícone e texto, sem caixa.
private struct LandingLink: View {
    let action: ActionID
    let id: A11yID
    let symbol: String?
    let title: String
    @State private var hovering = false

    var body: some View {
        ActionButton(action, id: id) {
            HStack(spacing: DS.Space.s1_5) {
                if let symbol { Image(systemName: symbol).dsFont(DS.Font.small) } else { DSGitHubMark(size: StartMetrics.icon - 6) }
                Text(verbatim: title).dsFont(DS.Font.small)
            }
            .foregroundStyle(hovering ? DS.Color.textPrimary : DS.Color.textSecondary)
            .padding(.horizontal, DS.Space.s2)
            .frame(height: StartMetrics.actionRow)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Card de agente da landing: clique = sessão limpa nova com esse agente já rodando (`session.newClean` com o provider).
/// Logo grande no centro, o nome embaixo e o atalho do agente padrão no canto.
private struct LandingAgentTile: View {
    let provider: TerminalProvider
    let installed: Bool
    let isDefault: Bool
    @State private var hovering = false

    private var request: String { #"{"provider":"\#(provider.rawValue)"}"# }

    var body: some View {
        ActionButton(.sessionNewClean, id: .landingAgent(provider.rawValue), argument: .set(request)) {
            VStack(spacing: DS.Space.s3) {
                DSAgentLogo(QuickLaunchModel.kind(provider), size: StartMetrics.agentHeroLogo)
                    .scaleEffect(hovering ? StartMetrics.hoverScale : 1)
                VStack(spacing: DS.Space.s0_5) {
                    Text(verbatim: ProviderAdapters.name(provider)).dsFont(DS.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                    Text(installed ? String(localized: "Start a session", bundle: .module) : String(localized: "Not installed", bundle: .module))
                        .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: StartMetrics.agentHeroHeight, maxHeight: StartMetrics.agentHeroHeight)
            .overlay(alignment: .topTrailing) {
                if isDefault, installed {
                    Text(verbatim: ActionID.sessionNewClean.spec.shortcut).dsFont(DS.Font.keycap).foregroundStyle(DS.Color.textTertiary)
                        .padding(DS.Space.s3)
                }
            }
            .background(RoundedRectangle(cornerRadius: DS.Radius.large).fill(hovering ? DS.Color.secondary : DS.Color.chrome))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.large).strokeBorder(hovering ? DS.Color.borderStrong : DS.Color.border))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.large))
            .offset(y: hovering ? -2 : 0)
        }
        .buttonStyle(.plain)
        .disabled(!installed)
        .opacity(installed ? 1 : 0.5)
        .onHover { hovering = installed && $0 }
        .animation(MotionPolicy.shared.animation(MotionTokens.Springs.snappy), value: hovering)
    }
}

/// Sessão sem tabs (03 §4.7): o nome da sessão e um card por agente para começar, mais Terminal e "Reopen Closed Tab".
struct PaneEmptyView: View {
    let model: WorkspaceModel

    private static let agents: [TerminalProvider] = [.claude, .codex, .opencode]

    var body: some View {
        VStack(spacing: DS.Space.s6) {
            VStack(spacing: DS.Space.s1_5) {
                Text(verbatim: model.session?.title ?? "").dsFont(DS.Font.dialogTitle).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                Text("No terminals open. Start an agent in this session:", bundle: .module)
                    .dsFont(DS.Font.body).foregroundStyle(DS.Color.textSecondary).multilineTextAlignment(.center)
            }
            HStack(spacing: DS.Space.s3) {
                ForEach(Self.agents, id: \.self) { provider in
                    StartCard(
                        action: .tabNewWithAgent, id: .paneEmptyAgent(provider.rawValue), argument: .select(provider.rawValue),
                        title: ProviderAdapters.name(provider), detail: nil,
                        width: StartMetrics.agentCardWidth, height: StartMetrics.agentCardHeight
                    ) {
                        DSAgentLogo(QuickLaunchModel.kind(provider), size: StartMetrics.icon)
                    }
                }
                StartCard(
                    action: .tabNewTerminal, id: .paneEmptyNewTerminal, title: String(localized: "Terminal", bundle: .module), detail: nil,
                    width: StartMetrics.agentCardWidth, height: StartMetrics.agentCardHeight
                ) {
                    Image(systemName: "terminal").font(.system(size: StartMetrics.icon - 4)).foregroundStyle(DS.Color.textPrimary)
                }
            }
            if model.hasClosedTabs {
                DSButton(.tabReopen, id: .paneEmptyReopen, "Reopen Closed Tab", variant: .ghost, size: .sm)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Color.canvas)
        .a11y(.paneEmpty, kind: "container")
    }
}
