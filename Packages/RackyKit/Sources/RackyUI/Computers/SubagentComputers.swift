import RackyCore
import RackyDesignSystem
import RackyProtocol
import RackyStore
import AppKit
import Observation
import SwiftUI

// F12 "Subagent computers": o atributo por sessão (Off / Ask / Full access), o controle dele no card da sessão, no composer e no header do
// pane, "Restart to apply", e o card de aprovação do modo Ask. As regras (injeção, consentimento) moram no Core; aqui só a UI.

extension SubagentComputersMode {
    var segmentTitle: LocalizedStringKey {
        switch self {
        case .off: "Off"
        case .ask: "Ask"
        case .full: "Full access"
        }
    }

    /// Frase curta sob o segmented do composer e do Settings.
    var explanation: String {
        switch self {
        case .off: String(localized: "Subagents run on this Mac as usual. No computers.", bundle: .module)
        case .ask: String(localized: "Claude can ask for a computer for subagents that study sites. You approve each request.", bundle: .module)
        case .full: String(localized: "Claude creates computers for subagents that study sites, without asking.", bundle: .module)
        }
    }

    var menuTitle: String {
        switch self {
        case .off: String(localized: "Off", bundle: .module)
        case .ask: String(localized: "Ask", bundle: .module)
        case .full: String(localized: "Full access", bundle: .module)
        }
    }

    var menuDetail: String {
        switch self {
        case .off: String(localized: "Normal subagents", bundle: .module)
        case .ask: String(localized: "Approve each computer", bundle: .module)
        case .full: String(localized: "Create computers directly", bundle: .module)
        }
    }

    var symbol: String {
        switch self {
        case .off: "desktopcomputer"
        case .ask: "desktopcomputer.and.arrow.down"
        case .full: "desktopcomputer"
        }
    }

    /// Cor do ícone: apagado desligado, aviso no Ask (espera você), verde no Full.
    var tint: Color {
        switch self {
        case .off: DS.Color.textQuaternary
        case .ask: DS.Color.warning
        case .full: DS.Color.success
        }
    }

    var tooltip: String {
        String(localized: "Subagent computers: \(menuTitle)", bundle: .module)
    }
}

// MARK: Controlador

/// Liga o atributo "Subagent computers" às ações do registro: mudar o modo, abrir o menu do ícone, "Restart to apply".
@MainActor
@Observable
final class SubagentComputersController {
    @ObservationIgnored private let sidebar: SidebarModel
    @ObservationIgnored private let workspace: WorkspaceModel
    @ObservationIgnored private let overlays: OverlayRouter
    @ObservationIgnored private let elements: UIElementStore
    @ObservationIgnored private weak var registry: ActionRegistry?
    @ObservationIgnored private(set) var store: RackyStore?
    /// Modo com que cada terminal Claude foi lançado (em memória); o resto se deduz dos argumentos gravados.
    private(set) var launchedModes: [UUID: SubagentComputersMode] = [:]

    init(sidebar: SidebarModel, workspace: WorkspaceModel, overlays: OverlayRouter, elements: UIElementStore) {
        self.sidebar = sidebar
        self.workspace = workspace
        self.overlays = overlays
        self.elements = elements
    }

    func attach(store: RackyStore) { self.store = store }

    func noteLaunched(terminal id: UUID, mode: SubagentComputersMode) { launchedModes[id] = mode }

    // MARK: Consultas

    /// O card mostra o controle em sessões que têm (ou terão) um agente; só com shells não faz sentido.
    func offersToggle(for session: UUID) -> Bool {
        let terminals = agentTerminals(in: session, includeAll: true)
        return terminals.isEmpty ? !hasOnlyOtherAgents(session) : true
    }

    private func hasOnlyOtherAgents(_ session: UUID) -> Bool {
        let all = terminals(in: session)
        return !all.isEmpty && !all.contains { $0.provider.supportsSubagentComputers }
    }

    private func terminals(in session: UUID) -> [Terminal] {
        let tabs = Set(sidebar.snapshot.tabs.filter { $0.sessionID == session && $0.closedAt == nil }.map(\.id))
        return sidebar.snapshot.terminals.filter { tabs.contains($0.tabID) }
    }

    private func agentTerminals(in session: UUID, includeAll: Bool = false) -> [Terminal] {
        // Workers de app (`agent_spawn`) não são pais: lançados só com a identidade do filho, nunca pedem "Restart to apply".
        terminals(in: session).filter {
            $0.provider.supportsSubagentComputers && $0.launchSpec.workerChildID == nil && (includeAll || $0.state == .running || $0.state == .launching)
        }
    }

    /// O agente vivo foi lançado com outro modo que o da sessão: precisa de "Restart to apply".
    func restartPending(session id: UUID) -> Bool {
        guard let session = sidebar.session(id) else { return false }
        let wanted = session.subagentComputers
        return agentTerminals(in: id).contains { terminal in
            let injected = terminal.resolvedArgv?.injected ?? []
            let injectedAgents = injected.contains("--agents") || injected.contains { $0.hasPrefix("mcp_servers.\(OrchestrationText.parentServerName)=") }
            let launched = launchedModes[terminal.id] ?? (injectedAgents ? (wanted.isOn ? wanted : .full) : .off)
            return launched != wanted
        }
    }

    // MARK: Ações

    func register(in registry: ActionRegistry) throws {
        self.registry = registry
        try registry.register(.sessionSetSubagentComputers) { [unowned self] arg in
            let parts = (arg.value ?? "").split(separator: ":", maxSplits: 1).map(String.init)
            var sessionID = sidebar.selectedSession
            var mode: SubagentComputersMode?
            if parts.count == 2 {
                sessionID = UUID(uuidString: parts[0])
                mode = SubagentComputersMode(rawValue: parts[1])
            } else if let only = parts.first {
                if let parsed = SubagentComputersMode(rawValue: only) { mode = parsed } else if let id = UUID(uuidString: only) { sessionID = id }
            }
            guard let sessionID, let session = sidebar.session(sessionID) else {
                throw ActionError.failed(.sessionSetSubagentComputers, message: "No session selected")
            }
            guard let mode else {
                presentMenu(for: session)
                return "menu"
            }
            guard let store else { throw ActionError.failed(.sessionSetSubagentComputers, message: "The database isn't open") }
            try await store.setSubagentComputers(sessionID: sessionID, mode: mode)
            return mode.rawValue
        }
        // Quem roda os próximos subagentes: vale no próximo `agent_spawn`, sem reiniciar o agente.
        try registry.register(.sessionSetSubagentHarness) { [unowned self] arg in
            let parts = (arg.value ?? "").split(separator: ":", maxSplits: 1).map(String.init)
            let sessionID = parts.count == 2 ? UUID(uuidString: parts[0]) : sidebar.selectedSession
            guard let sessionID, sidebar.session(sessionID) != nil else {
                throw ActionError.failed(.sessionSetSubagentHarness, message: "No such session.")
            }
            guard let raw = parts.last, let harness = SubagentHarness(rawValue: raw) else {
                throw ActionError.failed(.sessionSetSubagentHarness, message: "expected select(<sessionId>:claude|codex|opencode|mixed)")
            }
            guard let store else { throw ActionError.failed(.sessionSetSubagentHarness, message: "The database isn't open") }
            try await store.setSubagentHarness(sessionID: sessionID, harness: harness)
            return harness.rawValue
        }
        try registry.register(
            .sessionRestartToApply,
            enablement: { [unowned self] in
                guard let id = sidebar.selectedSession, restartPending(session: id) else {
                    return .disabled(reason: String(localized: "Already applied.", bundle: .module))
                }
                return .enabled
            }
        ) { [unowned self] arg in
            guard let id = arg.value.flatMap(UUID.init(uuidString:)) ?? sidebar.selectedSession else {
                throw ActionError.failed(.sessionRestartToApply, message: "No session selected")
            }
            let count = await restart(session: id)
            return "\(count)"
        }
    }

    /// Menu do ícone: Off / Ask / Full access, com o atual marcado, mais "Restart to apply" quando há o que aplicar.
    private func presentMenu(for session: Session) {
        let sid = session.id.uuidString
        let anchor = elements.frame(of: .sidebarSessionComputers(sid))
            ?? workspace.focusedTerminalID.flatMap { elements.frame(of: .paneComputers($0.uuidString)) }
            ?? elements.frame(of: .sidebarSession(sid)) ?? .zero
        var entries: [DSMenuEntry] = SubagentComputersMode.allCases.map { mode in
            .item(DSMenuItem(
                mode.rawValue, mode.menuTitle, icon: .symbol(mode.symbol), detail: mode.menuDetail, checked: session.subagentComputers == mode,
                action: .sessionSetSubagentComputers, argument: .select("\(sid):\(mode.rawValue)")))
        }
        entries.append(.separator("harness"))
        entries.append(.header(String(localized: "Subagents run as", bundle: .module)))
        entries += SubagentHarness.allCases.map { harness in
            .item(DSMenuItem(
                "harness.\(harness.rawValue)", harness.segmentTitle, icon: harness.menuIcon, detail: harness.menuDetail,
                checked: session.subagentHarness == harness, action: .sessionSetSubagentHarness, argument: .select("\(sid):\(harness.rawValue)")))
        }
        if restartPending(session: session.id) {
            entries.append(.separator("restart"))
            entries.append(.item(DSMenuItem(
                "restart", String(localized: "Restart to apply", bundle: .module), icon: .symbol("arrow.clockwise"), action: .sessionRestartToApply,
                argument: .select(sid))))
        }
        DSMenuPanel.present(
            router: overlays, registry: registry, name: "subagentComputers", anchor: anchor, width: SubagentMetrics.menuWidth, entries: entries,
            alignment: .trailing)
    }

    /// Relança com Resume os agentes vivos da sessão, para o próximo lançamento levar o modo novo.
    @discardableResult
    func restart(session id: UUID) async -> Int {
        let targets = agentTerminals(in: id).map(\.id)
        guard !targets.isEmpty else { return 0 }
        _ = sidebar.select(id)
        for _ in 0 ..< 100 where !workspace.isLoaded(session: id) { try? await Task.sleep(for: .milliseconds(20)) }
        for target in targets { await workspace.relaunchApplyingSettings(target) }
        return targets.count
    }
}

enum SubagentMetrics {
    static let menuWidth: CGFloat = 260
    static let cardWidth: CGFloat = 720
    static let cardHeight: CGFloat = 72
    static let cardTop = DS.Space.s3
    static let iconBox = DS.Space.s8
    static let toggleBox: CGFloat = 20
    static let toggleIcon = DS.Space.s3 + DS.Space.s0_5
    static let badge = DS.Space.s1_5
    static let thumbnailHeight: CGFloat = 150
    static let connector: CGFloat = 1
    /// O tempo decorrido da linha do subagente se atualiza a cada 30 s.
    static let elapsedTick: TimeInterval = 30
    /// O fio das linhas filhas fica sob o centro do indicador do card.
    static let connectorInset: CGFloat = SidebarMetrics.statusColumn / 2 - SidebarMetrics.agentRowPaddingH + SidebarMetrics.statusGap + SidebarMetrics.agentRowPaddingH
    static let pulseSeconds = 1.4
    /// Miniatura do computador na sidebar (v5): o último quadro, 42×27, e a linha que a carrega.
    static let thumbSize = CGSize(width: 42, height: 27)
    static let thumbRadius: CGFloat = 5
    static let thumbRowHeight: CGFloat = 33
}

extension SubagentHarness {
    var segmentTitle: String {
        switch self {
        case .claude: String(localized: "Claude", bundle: .module)
        case .codex: String(localized: "Codex", bundle: .module)
        case .opencode: String(localized: "OpenCode", bundle: .module)
        case .mixed: String(localized: "Mixed", bundle: .module)
        }
    }

    /// Uma linha do que a escolha faz (composer e Settings).
    var explanation: String {
        switch self {
        case .claude: String(localized: "Claude Code's own subagents, inside the agent. Each gets its own computer.", bundle: .module)
        case .codex: String(localized: "Each subagent runs as a separate Codex session in a pane beside the agent, with its own computer.", bundle: .module)
        case .opencode: String(localized: "Each subagent runs as a separate OpenCode session in a pane beside the agent, with its own computer.", bundle: .module)
        case .mixed: String(localized: "The agent picks per task: its own subagents or Codex / OpenCode sessions.", bundle: .module)
        }
    }

    var menuDetail: String? {
        switch self {
        case .claude: String(localized: "native", bundle: .module)
        case .mixed: String(localized: "agent picks", bundle: .module)
        default: nil
        }
    }

    /// Logos no seletor do composer: o do agente; Mixed mostra os três.
    var logos: [DSAgentKind] {
        switch self {
        case .claude: [.claude]
        case .codex: [.codex]
        case .opencode: [.opencode]
        case .mixed: [.claude, .codex, .opencode]
        }
    }

    /// Logo do agente no menu (Mixed sem logo).
    var menuIcon: DSMenuItem.Icon? {
        switch self {
        case .claude: .agent(.claude)
        case .codex: .agent(.codex)
        case .opencode: .agent(.opencode)
        case .mixed: .symbol("square.stack.3d.up")
        }
    }
}

// MARK: Ícone do card e do header

/// Ícone de computador clicável: abre o menu Off / Ask / Full access. Desligado fica apagado; Ask tem um ponto de aviso, Full um verde.
struct SubagentToggleButton: View {
    let sessionID: UUID
    let mode: SubagentComputersMode
    let id: A11yID
    var restartPending = false
    var style: DSIconButtonVariant = .row

    var body: some View {
        ActionButton(.sessionSetSubagentComputers, id: id, argument: .select(sessionID.uuidString), tooltip: mode.tooltip) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: mode.symbol)
                    .font(.system(size: SubagentMetrics.toggleIcon, weight: .regular))
                    .foregroundStyle(mode.tint)
                    .symbolEffect(.bounce, value: mode)
                    .frame(width: SubagentMetrics.toggleBox, height: SubagentMetrics.toggleBox)
                Circle()
                    .fill(restartPending ? DS.Color.warning : mode.tint)
                    .frame(width: SubagentMetrics.badge, height: SubagentMetrics.badge)
                    .scaleEffect(mode.isOn || restartPending ? 1 : 0.01)
                    .opacity(mode.isOn || restartPending ? 1 : 0)
                    .offset(x: -DS.Space.s0_5, y: DS.Space.s0_5)
            }
            .animation(MotionPolicy.shared.animation(MotionTokens.Springs.snappy), value: mode)
            .animation(MotionPolicy.shared.animation(MotionTokens.Springs.snappy), value: restartPending)
        }
        .buttonStyle(DSIconButtonStyle(style))
        .accessibilityValue(Text(verbatim: mode.rawValue))
    }
}

/// "Restart to apply" no card e no header: a sessão está rodando com outro modo.
/// Em amarelo (a mesma cor do ponto do ícone): o modo novo só vale depois de reiniciar o agente, e isso tem que saltar aos olhos (F38).
struct RestartToApplyPill: View {
    let sessionID: UUID
    var id: A11yID?
    @State private var hovering = false

    var body: some View {
        ActionButton(
            .sessionRestartToApply, id: id, argument: .select(sessionID.uuidString),
            tooltip: String(localized: "Subagent computers change when the agent restarts. The conversation continues.", bundle: .module)
        ) {
            HStack(spacing: DS.Space.s1) {
                Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
                Text("Restart to apply", bundle: .module).dsFont(DS.Font.label).lineLimit(1).fixedSize()
            }
            .foregroundStyle(DS.Color.warning)
            .padding(.horizontal, DS.Space.s2)
            .frame(height: DSButtonSize.xs.height)
            .background(Capsule().fill(DS.Color.warning.opacity(hovering ? 0.2 : 0.12)))
            .overlay(Capsule().strokeBorder(DS.Color.warningBorder))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .fixedSize()
        .transition(MotionPolicy.shared.reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: MotionTokens.Scale.menuFrom, anchor: .trailing)))
    }
}

// MARK: Linha filha do computador na sidebar

/// O que a sidebar mostra de um computador (07 CS-320): nome, estado, o que ele está fazendo e a miniatura do hover.
struct ComputerChildRow: Identifiable, Equatable {
    var id: String
    var glyph: DSIndicatorGlyph
    var stateLabel: String
    var detail: String?
    var thumbnail: Data?
    var needsDocker: Bool
    var needsYou: Bool
    var tooltip: String

    init(_ row: ComputerRow) {
        let snapshot = row.snapshot
        id = row.id
        thumbnail = row.thumbnail
        needsDocker = snapshot.detail?.hasPrefix(ComputerSetupError.dockerNotRunningMessage) == true
        needsYou = snapshot.help != nil
        detail = snapshot.detail ?? snapshot.lastDoing
        switch snapshot.state {
        case .queued:
            glyph = .dot(DS.ColorSpec.agentIdle)
            stateLabel = snapshot.queuePosition.map { String(localized: "Queued · \($0)", bundle: .module) } ?? String(localized: "Queued", bundle: .module)
        case .provisioning:
            glyph = .spinner
            stateLabel = String(localized: "Starting…", bundle: .module)
        case .ready:
            glyph = .dot(DS.ColorSpec.agentDone)
            stateLabel = String(localized: "Ready", bundle: .module)
        case .inUse:
            glyph = .working
            stateLabel = String(localized: "In use", bundle: .module)
        case .stopped:
            glyph = .dot(DS.ColorSpec.processExited)
            stateLabel = String(localized: "Stopped", bundle: .module)
        case .failed:
            glyph = .dot(DS.ColorSpec.agentFailed)
            stateLabel = String(localized: "Failed", bundle: .module)
        }
        if snapshot.help != nil {
            glyph = .needsInput
            stateLabel = String(localized: "Needs You", bundle: .module)
        }
        tooltip = [row.id, snapshot.url, snapshot.detail ?? snapshot.lastDoing].compactMap { $0 }.joined(separator: " · ")
    }
}

/// O último quadro do computador na sidebar (v5): é o que torna o subagente palpável. Sem quadro ainda, a tela vazia com o ícone;
/// pedindo ajuda, a borda azul.
struct SidebarComputerThumb: View {
    let data: Data?
    var needsYou = false
    @State private var decoded: DecodedThumbnail?

    var body: some View {
        ZStack(alignment: .topLeading) {
            DS.Color.secondary
            if let decoded {
                Image(decorative: decoded.image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: SubagentMetrics.thumbSize.width, height: SubagentMetrics.thumbSize.height, alignment: .topLeading)
                    .saturation(0.75)
            } else {
                Image(systemName: "display")
                    .font(.system(size: SidebarMetrics.line2Icon))
                    .foregroundStyle(DS.Color.textQuaternary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: SubagentMetrics.thumbSize.width, height: SubagentMetrics.thumbSize.height)
        .clipShape(RoundedRectangle(cornerRadius: SubagentMetrics.thumbRadius))
        .overlay(
            RoundedRectangle(cornerRadius: SubagentMetrics.thumbRadius)
                .strokeBorder(needsYou ? DS.Color.agentNeedsInput : DS.Color.fg10, lineWidth: needsYou ? ComputersMetrics.stateBorder : DSMetrics.hairline))
        .task(id: data?.count ?? 0) {
            guard let data else { decoded = nil; return }
            decoded = await ThumbnailDecoder.shared.decode(data)
        }
        .accessibilityHidden(true)
    }
}

struct ComputerChildRowView: View {
    let sessionID: UUID
    let row: ComputerChildRow
    @State private var hovering = false

    var body: some View {
        let sid = sessionID.uuidString
        ZStack(alignment: .trailing) {
            ActionButton(.computerOpenViewer, id: .sidebarSessionChild(sid, row.id), argument: .select(row.id)) {
                HStack(spacing: SidebarMetrics.statusGap) {
                    SidebarComputerThumb(data: row.thumbnail, needsYou: row.needsYou)
                        .a11y(.sidebarSessionChildStatus(sid, row.id), kind: "image", label: row.stateLabel)
                    Text(verbatim: row.id)
                        .dsFont(DS.Font.sidebarMeta)
                        .foregroundStyle(DS.Color.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: DS.Space.s1)
                    if !row.needsDocker {
                        Text(verbatim: row.needsYou ? row.stateLabel : (row.detail ?? row.stateLabel))
                            .dsFont(DS.Font.sidebarMetaNumeric)
                            .foregroundStyle(row.needsYou ? DS.Color.agentNeedsInputText : DS.Color.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .id(row.detail ?? row.stateLabel)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, SidebarMetrics.agentRowPaddingH)
                .frame(height: SubagentMetrics.thumbRowHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: SidebarMetrics.agentRowRadius).fill(hovering ? DS.Color.hoverAgentRow : Color.clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .dsTooltip(row.tooltip, delay: .standard, side: .top, thumbnail: row.thumbnail)
            if row.needsDocker {
                DSButton(.dockerStart, id: nil, "Open Docker", variant: .link, size: .xs)
                    .padding(.trailing, SidebarMetrics.agentRowPaddingH)
            }
        }
        .onHover { hovering = $0 }
        .animation(MotionPolicy.shared.animation(MotionTokens.Easing.ease, MotionTokens.Duration.hover), value: hovering)
        .animation(MotionPolicy.shared.animation(MotionTokens.Easing.standard, MotionTokens.Duration.fast), value: row.detail)
        .transition(MotionPolicy.shared.reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -DS.Space.s1)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "\(row.id), \(row.stateLabel)"))
    }
}

// MARK: Card de aprovação (modo Ask)

/// `Claude wants a computer · <nome> · Headless · <proxy>` com Allow / Allow for this session / Deny. Não modal: fica no topo do pane da
/// sessão enquanto o usuário decide; o pai espera (ou repete a chamada) e o terminal segue utilizável. Ao lado do proxy, o que sai do
/// disco quando o computador terminar (`Delete in 7 days`).
struct ComputerApprovalCard: View {
    let request: ComputerApprovalRequest
    var showsLeftovers = true
    @State private var pulse = false

    private var spawn: Bool { request.kind == .spawn }

    var body: some View {
        let id = request.id
        HStack(alignment: .center, spacing: DS.Space.s3) {
            ZStack {
                Circle().fill(DS.Color.warning.opacity(0.14))
                Circle()
                    .strokeBorder(DS.Color.warning.opacity(pulse ? 0.0 : 0.55), lineWidth: DSMetrics.hairline * 2)
                    .scaleEffect(pulse ? 1.45 : 1)
                Image(systemName: "desktopcomputer")
                    .font(.system(size: SubagentMetrics.toggleIcon + DS.Space.s0_5, weight: .medium))
                    .foregroundStyle(DS.Color.warning)
            }
            .frame(width: SubagentMetrics.iconBox, height: SubagentMetrics.iconBox)
            VStack(alignment: .leading, spacing: DS.Space.s0_5) {
                Text(verbatim: spawn ? String(localized: "Give this subagent a computer?", bundle: .module) : headline)
                    .dsFont(DS.Font.bodyStrong)
                    .foregroundStyle(DS.Color.textPrimary)
                    .lineLimit(1)
                Text(verbatim: detail)
                    .dsFont(DS.Font.small)
                    .foregroundStyle(DS.Color.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            Spacer(minLength: DS.Space.s2)
            HStack(spacing: DS.Space.s1_5) {
                if !spawn {
                    DSButton(
                        .computerRequestProxy, id: .paneApprovalProxy(id), LocalizedStringKey(request.proxyLabel), variant: .ghost, size: .xs, symbol: "network",
                        argument: .select(id))
                    if showsLeftovers {
                        DSButton(
                            .computerRequestLeftovers, id: .paneApprovalLeftovers(id), request.leftovers.labelKey, variant: .ghost, size: .xs,
                            symbol: request.leftovers == .keep ? "folder" : "trash", argument: .select(id))
                    }
                }
                DSButton(.computerDenyRequest, id: .paneApprovalDeny(id), "Deny", variant: .ghost, size: .xs, argument: .select(id))
                DSButton(.computerAllowRequestSession, id: .paneApprovalAllowSession(id), "Allow for this session", variant: .outline, size: .xs, argument: .select(id))
                DSButton(.computerAllowRequest, id: .paneApprovalAllow(id), "Allow", variant: .primary, size: .xs, argument: .select(id))
            }
            .fixedSize()  // sem lugar, quem encolhe é o texto, nunca os botões
        }
        .padding(.horizontal, DS.Space.s3)
        .padding(.vertical, DS.Space.s2_5)
        .frame(maxWidth: SubagentMetrics.cardWidth)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Color.chrome))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Color.warning.opacity(0.35), lineWidth: DSMetrics.hairline))
        .dsShadow(DS.Shadow.floating)
        .a11y(.paneApproval(id), kind: "banner", label: request.summary)
        .onAppear {
            guard !MotionPolicy.shared.reduceMotion else { return }
            withAnimation(.easeOut(duration: SubagentMetrics.pulseSeconds).repeatForever(autoreverses: false)) { pulse = true }
        }
    }

    private var headline: String {
        request.names.count == 1
            ? String(localized: "\(request.agentName) wants a computer", bundle: .module)
            : String(localized: "\(request.agentName) wants \(request.names.count) computers", bundle: .module)
    }

    /// `phoenix-az · Headless · Direct` (ou, no gatilho de spawn, o que o subagente vai fazer).
    private var detail: String {
        if spawn {
            return [request.subject, String(localized: "A computer gives it a browser, a shell and a request log.", bundle: .module)].compactMap { $0 }.joined(separator: " · ")
        }
        return "\(request.computerName) · \(request.displayLabel)"  // o proxy fica no botão ao lado (F29)
    }
}

/// Pilha de cards no topo do pane da sessão selecionada: entram deslizando de cima com mola; saem com fade e escala.
struct ComputerApprovalStack: View {
    let model: ComputersModel
    let session: UUID?
    /// A sessão selecionada agora (a pilha acompanha a seleção).
    var selection: () -> UUID? = { nil }
    /// Settings › General › Storage › Choose on the approval card.
    var showsLeftovers: () -> Bool = { true }

    private var visible: [ComputerApprovalRequest] {
        let current = session ?? selection()
        return model.approvals.filter { $0.sessionID == current || $0.sessionID == nil }
    }

    var body: some View {
        VStack(spacing: DS.Space.s2) {
            ForEach(visible.prefix(3)) { request in
                ComputerApprovalCard(request: request, showsLeftovers: showsLeftovers())
                    .transition(
                        MotionPolicy.shared.reduceMotion
                            ? .opacity
                            : .asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: MotionTokens.Scale.menuFrom, anchor: .top)),
                                removal: .opacity.combined(with: .scale(scale: MotionTokens.Scale.menuFrom, anchor: .top))))
            }
            if visible.count > 3 {
                Text(verbatim: String(localized: "+\(visible.count - 3) more waiting", bundle: .module))
                    .dsFont(DS.Font.small)
                    .foregroundStyle(DS.Color.textTertiary)
            }
        }
        .padding(.top, SubagentMetrics.cardTop)
        .padding(.horizontal, DS.Space.s3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(MotionPolicy.shared.animation(MotionTokens.Springs.snappy), value: visible.map(\.id))
    }
}

/// Item do Inbox para o mesmo pedido (03 §9.1): `Allow` e `Deny` na própria linha.
struct ComputerApprovalRowView: View {
    let request: ComputerApprovalRequest
    @State private var hovering = false

    var body: some View {
        let id = request.id
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            HStack(spacing: DS.Space.s1_5) {
                DSAgentIndicator(.needsInput, size: .sm)
                Text(verbatim: request.sessionTitle)
                    .dsFont(DS.Font.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(DS.Color.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: DS.Space.s1)
                DSButton(.computerDenyRequest, id: .inboxItemDeny(id), "Deny", variant: .ghost, size: .xs, argument: .select(id))
                DSButton(.computerAllowRequest, id: .inboxItemAllow(id), "Allow", variant: .outline, size: .xs, argument: .select(id))
            }
            Text(verbatim: request.summary)
                .dsFont(DS.Font.small)
                .foregroundStyle(DS.Color.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, DSIndicatorSize.sm.box + DS.Space.s1_5)
        }
        .padding(.horizontal, DS.Space.s2_5)
        .padding(.vertical, DS.Space.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: InboxMetrics.rowHeight)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(hovering ? DS.Color.fg8 : Color.clear))
        .onHover { hovering = $0 }
        .a11y(.inboxItem(id), kind: "row", label: request.summary, value: "needs_you")
    }
}
