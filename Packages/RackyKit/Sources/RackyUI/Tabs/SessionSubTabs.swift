import RackyCore
import RackyDesignSystem
import RackyProtocol
import SwiftUI

enum SubTabMetrics {
    static let height: CGFloat = 36
    static let itemHeight: CGFloat = 26
    static let dot: CGFloat = 6
    static let separator: CGFloat = 1
}

/// "Tabs dentro de tabs" (pedido do dono): abaixo da tab row, quando a sessão tem computadores de subagentes, uma faixa com o
/// terminal do agente e um item por computador. Troca entre o terminal e a tela de cada computador sem "Back to…".
struct SessionSubTabs: View {
    let workspace: WorkspaceModel
    let computers: ComputersController

    static func computerNames(workspace: WorkspaceModel, computers: ComputersController) -> [String] {
        guard let session = workspace.currentSessionID else { return [] }
        return computers.model.rows.filter { computers.model.sessionIDs[$0.id] == session }.map(\.id)
    }

    private var current: String? { if case .viewer(let name) = computers.page { name } else { nil } }

    private var agent: (kind: DSAgentKind, name: String) {
        guard let id = workspace.focusedTerminalID, let t = workspace.terminal(id) else { return (.shell, "Terminal") }
        let name: String
        switch t.provider {
        case .claude: name = "Claude"
        case .codex: name = "Codex"
        case .opencode: name = "OpenCode"
        case .shell, .custom: name = "Terminal"
        }
        return (QuickLaunchModel.kind(t.provider), name)
    }

    var body: some View {
        let names = Self.computerNames(workspace: workspace, computers: computers)
        HStack(spacing: DS.Space.s1) {
            item(selected: current == nil, id: .subtabsTerminal, action: .pageClose, argument: .press) {
                DSAgentLogo(agent.kind, size: DS.Space.s3)
                Text(verbatim: agent.name)
            }
            ForEach(names, id: \.self) { name in
                item(selected: current == name, id: .subtabsComputer(name), action: .computerOpenViewer, argument: .select(name)) {
                    Image(systemName: "display")
                    // O computador de um worker leva o nome do agente que o usa ("Codex 1"); o nome da máquina fica no hover.
                    Text(verbatim: computers.model.computerAgentNames[name] ?? name)
                    statusBadge(name)
                }
                .help(name)
            }
            Spacer(minLength: DS.Space.s2)
            // A barra também é o header do viewer aberto: endereço, quem está no controle, Take Over e ações.
            if let current, let viewer = computers.ensureViewer(current) {
                ViewerHeader(controller: viewer, embedded: true)
            }
        }
        .padding(.horizontal, DS.Space.s2)
        .frame(height: SubTabMetrics.height)
        .frame(maxWidth: .infinity)
        .background(DS.Color.chrome)
        .overlay(alignment: .bottom) { DS.Color.border.frame(height: SubTabMetrics.separator) }
        .a11y(.subtabs, kind: "container")
    }

    /// Ponto de status e uma palavra (Starting/Live/Needs you/Done) ao lado do nome do computador.
    private func statusBadge(_ name: String) -> some View {
        let (color, text) = status(name)
        return HStack(spacing: DS.Space.s1) {
            Circle().fill(color).frame(width: SubTabMetrics.dot, height: SubTabMetrics.dot)
            Text(verbatim: text).dsFont(DS.Font.micro).foregroundStyle(DS.Color.textTertiary)
        }
    }

    private func status(_ name: String) -> (Color, String) {
        guard let row = computers.model.rows.first(where: { $0.id == name }) else { return (DS.Color.border, "") }
        if row.needsYou { return (DS.Color.agentNeedsInput, String(localized: "Needs you", bundle: .module)) }
        switch row.snapshot.state {
        case .inUse: return row.snapshot.control == .human
            ? (DS.Color.textPrimary, String(localized: "You", bundle: .module)) : (DS.Color.aiAccent, String(localized: "Live", bundle: .module))
        case .queued, .provisioning: return (DS.Color.warning, String(localized: "Starting", bundle: .module))
        case .failed: return (DS.Color.agentFailed, String(localized: "Failed", bundle: .module))
        case .ready: return (DS.Color.textTertiary, String(localized: "Ready", bundle: .module))
        case .stopped: return (DS.Color.textTertiary, String(localized: "Done", bundle: .module))
        }
    }

    private func item<Label: View>(selected: Bool, id: A11yID, action: ActionID, argument: ActionArgument, @ViewBuilder label: () -> Label) -> some View {
        ActionButton(action, argument: argument) {
            HStack(spacing: DS.Space.s1_5) { label() }
                .dsFont(selected ? DS.Font.tabActive : DS.Font.tab)
                .foregroundStyle(selected ? DS.Color.textPrimary : DS.Color.textSecondary)
                .padding(.horizontal, DS.Space.s2)
                .frame(height: SubTabMetrics.itemHeight)
                .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(selected ? DS.Color.fg10 : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .a11y(id, kind: "tab", value: selected ? "selected" : nil)
    }
}
