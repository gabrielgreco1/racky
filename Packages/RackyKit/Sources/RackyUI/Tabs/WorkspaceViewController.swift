import RackyDesignSystem
import RackyProtocol
import RackyStore
import AppKit
import SwiftUI

/// Raiz do centro da janela: landing (sem sessão selecionada) ou tab row (36) + área de panes.
@MainActor
final class WorkspaceRootView: NSView {
    let landing: NSView
    let tabRow: NSView
    let area: PaneAreaView
    /// Sessão em criação aberta pela linha pendente (03 §2.9): ocupa o centro inteiro, sem tab row.
    let pending: NSView
    /// Página do centro (Computers, viewer): substitui landing, tab row e panes enquanto aberta (03 §12).
    private(set) var page: NSView?
    private var workspaceVisible = false
    private var pendingVisible = false
    /// Cards de aprovação do modo Ask (F12): sobre o topo do pane da sessão, sem modal. Só ocupa a faixa dos cards.
    let approvals: NSView
    private var approvalCount = 0
    /// P25: "N agents stopped while Racky was closed · Resume All", no topo da sessão (só com a retomada automática desligada).
    var stoppedBanner: NSView?
    private var stoppedBannerVisible = false
    /// Sub-tabs da sessão (terminal + computadores dos subagentes), logo abaixo da tab row. Só com computadores na sessão.
    var subTabs: NSView?
    private(set) var subTabsVisible = false
    private var subTabsHeight: CGFloat { subTabsVisible && (workspaceVisible || pageKeepsTabs) ? SubTabMetrics.height : 0 }
    private var contentTop: CGFloat { TabMetrics.chromeHeight + subTabsHeight }

    func setSubTabsVisible(_ visible: Bool) {
        guard visible != subTabsVisible, let subTabs else { return }
        subTabsVisible = visible
        if visible { addSubview(subTabs) } else { subTabs.removeFromSuperview() }
        needsLayout = true
    }

    override var isFlipped: Bool { true }

    init(landing: NSView, tabRow: NSView, area: PaneAreaView, pending: NSView, approvals: NSView) {
        self.landing = landing
        self.tabRow = tabRow
        self.area = area
        self.pending = pending
        self.approvals = approvals
        super.init(frame: .zero)
        approvals.isHidden = true
        setWorkspaceVisible(false)
    }

    func setStoppedBannerVisible(_ visible: Bool) {
        guard visible != stoppedBannerVisible, let stoppedBanner else { return }
        stoppedBannerVisible = visible
        if visible { addSubview(stoppedBanner) } else { stoppedBanner.removeFromSuperview() }
        needsLayout = true
    }

    /// Quantos cards a sessão selecionada tem esperando. Com 0 a faixa some depois da animação de saída.
    func setApprovalCount(_ count: Int) {
        approvalCount = count
        if count > 0 {
            approvals.isHidden = false
            if approvals.superview == nil { addSubview(approvals) }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + MotionTokens.Duration.base * 2) { [weak self] in
                guard let self, self.approvalCount == 0 else { return }
                self.approvals.isHidden = true
            }
        }
        needsLayout = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }  // required init?(coder:) não usado

    /// Troca landing e workspace tirando a outra parte da hierarquia: controles ocultos não ficam em `ctl ui tree`.
    func setWorkspaceVisible(_ visible: Bool) {
        workspaceVisible = visible
        applyMode()
    }

    /// Enquanto as sessões restauram, sem landing (a sessão selecionada ainda vai voltar).
    private var landingHeld = false
    func setLandingHeld(_ held: Bool) {
        landingHeld = held
        applyMode()
    }

    func setPendingVisible(_ visible: Bool) {
        pendingVisible = visible
        applyMode()
    }

    private func applyMode() {
        guard page == nil else { return }
        if pendingVisible {
            landing.removeFromSuperview()
            area.removeFromSuperview()
            tabRow.removeFromSuperview()
            if pending.superview == nil { addSubview(pending) }
        } else if workspaceVisible {
            pending.removeFromSuperview()
            landing.removeFromSuperview()
            if area.superview == nil { addSubview(area) }
            if tabRow.superview == nil { addSubview(tabRow) }
        } else {
            pending.removeFromSuperview()
            area.removeFromSuperview()
            tabRow.removeFromSuperview()
            if landingHeld { landing.removeFromSuperview() } else if landing.superview == nil { addSubview(landing) }
        }
        needsLayout = true
    }

    /// A página aberta mantém a tab row da sessão visível em cima (viewer de computador): o usuário sempre vê as tabs e
    /// clicar numa delas volta para o terminal.
    private(set) var pageKeepsTabs = false
    /// Clique na tab row enquanto uma página está aberta: o controlador fecha a página e mostra o terminal.
    var onTabRowClickWhilePage: () -> Void = {}
    private lazy var tabRowClick: NSClickGestureRecognizer = {
        let g = NSClickGestureRecognizer(target: self, action: #selector(tabRowClicked))
        g.delaysPrimaryMouseButtonEvents = false
        return g
    }()

    @objc private func tabRowClicked() {
        if page != nil { onTabRowClickWhilePage() }
    }

    /// Troca a página do centro. `nil` volta ao landing ou ao workspace, conforme havia sessão.
    /// `keepTabs`: a página ocupa só a área dos panes e a tab row continua (viewer).
    func setPage(_ view: NSView?, keepTabs: Bool = false) {
        page?.removeFromSuperview()
        page = view
        pageKeepsTabs = view != nil && keepTabs && workspaceVisible
        if let view {
            landing.removeFromSuperview()
            pending.removeFromSuperview()
            area.removeFromSuperview()
            if pageKeepsTabs {
                if tabRow.superview == nil { addSubview(tabRow) }
                if !(tabRow.gestureRecognizers.contains { $0 === tabRowClick }) { tabRow.addGestureRecognizer(tabRowClick) }
            } else {
                tabRow.removeFromSuperview()
            }
            addSubview(view)
        } else {
            tabRow.removeGestureRecognizer(tabRowClick)
            applyMode()
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        page?.frame = pageKeepsTabs
            ? NSRect(x: 0, y: contentTop, width: bounds.width, height: max(0, bounds.height - contentTop))
            : bounds
        subTabs?.frame = NSRect(x: 0, y: TabMetrics.chromeHeight, width: bounds.width, height: subTabsHeight)
        landing.frame = bounds
        pending.frame = bounds
        tabRow.frame = NSRect(x: 0, y: 0, width: bounds.width, height: TabMetrics.chromeHeight)
        // Com a faixa "agents stopped" à mostra, os panes começam abaixo dela (antes ela cobria o topo de cada pane: o cabeçalho do
        // terminal e a barra do dataset com o nome e o lápis).
        let areaTop = contentTop + (stoppedBannerVisible && stoppedBanner != nil ? PaneMetrics.banner : 0)
        area.frame = NSRect(x: 0, y: areaTop, width: bounds.width, height: max(0, bounds.height - areaTop))
        if let subTabs, subTabsVisible { addSubview(subTabs, positioned: .above, relativeTo: nil) }
        if stoppedBannerVisible, let stoppedBanner {
            stoppedBanner.frame = NSRect(x: 0, y: contentTop, width: bounds.width, height: PaneMetrics.banner)
            addSubview(stoppedBanner, positioned: .above, relativeTo: nil)
        }
        let strip = SubagentMetrics.cardWidth + DS.Space.s3 * 2
        let height = CGFloat(min(max(approvalCount, 1), 3)) * SubagentMetrics.cardHeight + SubagentMetrics.cardTop * 2
        let width = min(strip, bounds.width)
        approvals.frame = NSRect(x: (bounds.width - width) / 2, y: contentTop, width: width, height: height)
        if approvals.superview != nil { addSubview(approvals, positioned: .above, relativeTo: nil) }
    }
}

/// Centro da janela (T1-14): tab row e árvore de panes da sessão selecionada, ligadas ao `WorkspaceModel`.
@MainActor
final class WorkspaceViewController: NSViewController {
    private let env: AppEnvironment
    private weak var root: WorkspaceRootView?

    /// Reavalia o número de cards da sessão selecionada sempre que os pedidos ou a seleção mudam.
    private func trackApprovals() {
        withObservationTracking {
            _ = env.computers.model.approvals
            _ = env.sidebar.selectedSession
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refreshApprovals()
                self?.trackApprovals()
            }
        }
        refreshApprovals()
    }

    /// A faixa de sub-tabs aparece quando a sessão selecionada tem algum computador de subagente.
    private func trackSubTabs() {
        // Os computadores dos subagentes agora são tabs da sessão (panes como o agente e as tabelas): a faixa de sub-tabs saiu.
        root?.setSubTabsVisible(false)
    }

    private func refreshApprovals() {
        let selected = env.sidebar.selectedSession
        root?.setApprovalCount(env.computers.model.approvals.filter { $0.sessionID == selected || $0.sessionID == nil }.count)
    }

    init(env: AppEnvironment) {
        self.env = env
        super.init(nibName: nil, bundle: nil)
        let blocked: () -> Bool = { [overlays = env.overlays] in overlays.blocksTerminalInput }
        let landing = ChromeHostingView(
            content: LandingView(automationOn: env.automationEnabled, sidebar: env.sidebar, settings: env.settings, computers: env.computers, datasets: env.datasets, statusBar: env.statusBar).environment(\.elementStore, env.elements)
                .environment(\.actionRegistry, env.registry).environment(\.a11yParent, .windowMain))
        landing.inputBlocked = blocked
        let tabRow = ChromeHostingView(
            content: TabRowView(model: env.workspace, rightPanel: env.rightPanel).environment(\.elementStore, env.elements)
                .environment(\.actionRegistry, env.registry).environment(\.overlayRouter, env.overlays).environment(\.a11yParent, .windowMain))
        tabRow.inputBlocked = blocked
        let area = PaneAreaView(model: env.workspace, registry: env.registry, elements: env.elements, router: env.terminalRouter)
        let pending = ChromeHostingView(
            content: PendingSessionView(model: env.sidebar).environment(\.elementStore, env.elements)
                .environment(\.actionRegistry, env.registry).environment(\.a11yParent, .windowMain))
        pending.inputBlocked = blocked
        let approvals = ChromeHostingView(
            content: ComputerApprovalStack(
                model: env.computers.model, session: nil, selection: { [weak env] in env?.sidebar.selectedSession },
                showsLeftovers: { [weak env] in env?.settings.settings.general.leftoversOnCard ?? true })
                .environment(\.elementStore, env.elements).environment(\.actionRegistry, env.registry).environment(\.a11yParent, .windowMain))
        approvals.inputBlocked = blocked
        let root = WorkspaceRootView(landing: landing, tabRow: tabRow, area: area, pending: pending, approvals: approvals)
        view = root
        self.root = root
        let stopped = ChromeHostingView(
            content: StoppedAgentsBanner(model: env.workspace).environment(\.elementStore, env.elements)
                .environment(\.actionRegistry, env.registry).environment(\.a11yParent, .windowMain))
        stopped.inputBlocked = blocked
        root.stoppedBanner = stopped
        let subTabs = ChromeHostingView(
            content: SessionSubTabs(workspace: env.workspace, computers: env.computers).environment(\.elementStore, env.elements)
                .environment(\.actionRegistry, env.registry).environment(\.a11yParent, .windowMain))
        subTabs.inputBlocked = blocked
        root.subTabs = subTabs
        trackApprovals()
        trackSubTabs()
        env.workspace.dragController.tabRowRect = { [weak tabRow] in
            guard let tabRow, tabRow.window != nil, tabRow.superview != nil else { return nil }
            return tabRow.convert(tabRow.bounds, to: nil)
        }
        root.setLandingHeld(env.restorePending)
        env.onRestored = { [weak root] in root?.setLandingHeld(false) }
        root.setWorkspaceVisible(env.workspace.currentSessionID != nil)
        env.workspace.addListener { [weak root, weak env] in
            guard let root, let env else { return }
            root.setWorkspaceVisible(env.workspace.currentSessionID != nil)
            root.setStoppedBannerVisible(env.workspace.showsStoppedAgentsBanner)
        }
        env.sidebar.onPendingFocusChange = { [weak root, weak env] in
            guard let root, let env else { return }
            root.setPendingVisible(env.sidebar.focusedPending != nil)
        }
        root.onTabRowClickWhilePage = { [weak env] in env?.computers.closePage() }
        // Pane de dataset: a tabela com o estado do dataset, o título que arrasta o pane e o ambiente completo (menus, registro).
        env.workspace.makePaneView = { [weak env] pane in
            guard let env else { return NSView() }
            if case .computer(let name) = pane.content {
                // A tela do computador de um subagente como pane da sessão (arrasta, divide, fica ao lado da tabela ou do agente).
                guard let viewer = env.computers.ensureViewer(name) else {
                    // O computador já foi encerrado e limpo: em vez de um pane preto e mudo, diz o que houve e oferece fechar a tab.
                    let workspace = env.workspace
                    return ChromeHostingView(
                        content: GoneComputerPane(
                            name: name, close: { workspace.closePane(id: pane.id) },
                            showAgent: workspace.terminalsInCurrentSession.first(where: { $0.provider.isAgent }).map { agent in
                                { workspace.show(terminalID: agent.id) }
                            },
                            showRuns: {
                                let runs = StorePaths.default(environment: ProcessInfo.processInfo.environment).root
                                    .appendingPathComponent("computers/runs", isDirectory: true)
                                NSWorkspace.shared.open(runs)
                            })
                            .environment(\.elementStore, env.elements).environment(\.a11yParent, .windowMain))
                }
                let workspace = env.workspace
                let host = ChromeHostingView(
                    content: ComputerViewerView(
                        controller: viewer, computers: env.computers, backTitle: nil, showsStrip: false, showsHeader: true,
                        pane: ViewerPane(id: pane.id, drag: workspace.dragController, title: workspace.computerTitle(name), close: { workspace.closePane(id: pane.id) }))
                        .environment(\.elementStore, env.elements).environment(\.actionRegistry, env.registry)
                        .environment(\.overlayRouter, env.overlays).environment(\.a11yParent, .windowMain))
                host.inputBlocked = { [overlays = env.overlays] in overlays.blocksTerminalInput }
                return host
            }
            if case .traffic(let name) = pane.content {
                // Traffic (mini Burp) do computador como pane da sessão.
                let host = ChromeHostingView(
                    content: TrafficPaneView(traffic: env.traffic, name: name, close: { [weak env] in env?.workspace.closePane(id: pane.id) })
                        .environment(\.elementStore, env.elements).environment(\.actionRegistry, env.registry)
                        .environment(\.overlayRouter, env.overlays).environment(\.a11yParent, .windowMain))
                host.inputBlocked = { [overlays = env.overlays] in overlays.blocksTerminalInput }
                return host
            }
            if case .notebook(let id) = pane.content {
                // Notebook como pane da sessão: ao lado do agente ou numa tab própria (antes só existia na área Data).
                let host = ChromeHostingView(
                    content: NotebookObjectView(hub: env.dataHub, id: id, inSession: true, close: { [weak env] in env?.workspace.closePane(id: pane.id) })
                        .environment(\.elementStore, env.elements).environment(\.actionRegistry, env.registry)
                        .environment(\.overlayRouter, env.overlays).environment(\.a11yParent, .windowMain))
                host.inputBlocked = { [overlays = env.overlays] in overlays.blocksTerminalInput }
                return host
            }
            guard case .dataset(let id) = pane.content else { return NSView() }
            let model = env.datasets.model(for: id)
            let host = ChromeHostingView(
                content: DatasetPageView(controller: env.datasets, model: model, paneID: pane.id, drag: env.workspace.dragController, hub: env.dataHub)
                    .environment(\.elementStore, env.elements).environment(\.actionRegistry, env.registry)
                    .environment(\.overlayRouter, env.overlays).environment(\.a11yParent, .windowMain))
            host.inputBlocked = { [overlays = env.overlays] in overlays.blocksTerminalInput }
            return host
        }
        env.computers.onPageChange = { [weak self, weak root, weak env] in
            guard let self, let root, let env else { return }
            root.setPage(self.pageView(for: env.computers.page, env: env), keepTabs: env.computers.page.isViewer)
            if env.computers.page != .workspace {
                root.window?.makeFirstResponder(root.page)
            } else {
                // Voltou ao workspace: o terminal da tab ativa recupera o teclado (a página que tinha o foco saiu da janela).
                env.workspace.focusTerminalOfActiveTab()
                DispatchQueue.main.async { [weak env] in env?.workspace.focusTerminalOfActiveTab() }
            }
        }
    }

    /// A view SwiftUI de uma página do centro (Computers) ou o viewer de um computador.
    private func pageView(for page: CenterPage, env: AppEnvironment) -> NSView? {
        let controller = env.computers
        let content: AnyView
        switch page {
        case .workspace: return nil
        case .computers: content = AnyView(ComputersPageView(controller: controller, settings: env.settings))
        case .batch(let id): content = AnyView(BatchPageView(controller: controller, batchID: id))
        case .library: content = AnyView(LibraryPageView(controller: env.library))
        case .datasets: content = AnyView(DataPageView(hub: env.dataHub, shell: env.shell))
        case .dataset(let id):
            // Dataset aberto fora da sessão: vira uma tab da área Data.
            env.dataHub.open(.dataset(id))
            content = AnyView(DataPageView(hub: env.dataHub, shell: env.shell))
        case .viewer(let name):
            guard let viewer = controller.ensureViewer(name) else { return nil }
            let origin = env.sidebar.selectedSession.flatMap { env.sidebar.session($0)?.title }
            // Com as sub-tabs da sessão (o computador é dela), elas fazem a navegação: sem "Back to…" nem a faixa de miniaturas.
            let inSubTabs = controller.model.sessionIDs[name] != nil && controller.model.sessionIDs[name] == env.workspace.currentSessionID
            content = AnyView(ComputerViewerView(
                controller: viewer, computers: controller, backTitle: inSubTabs ? nil : origin ?? String(localized: "workspace", bundle: .module),
                showsStrip: !inSubTabs, showsHeader: !inSubTabs))
        }
        let host = ChromeHostingView(
            content: PageInsetReader(rightPanel: env.rightPanel, content: content).environment(\.elementStore, env.elements)
                .environment(\.actionRegistry, env.registry).environment(\.overlayRouter, env.overlays).environment(\.a11yParent, .windowMain))
        host.inputBlocked = { [overlays = env.overlays] in overlays.blocksTerminalInput }
        return host
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }  // required init?(coder:) não usado
}
