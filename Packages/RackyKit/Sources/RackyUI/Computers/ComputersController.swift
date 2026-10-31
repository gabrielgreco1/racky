import RackyCore
import RackyPlatform
import RackyProtocol
import AppKit
import Foundation
import Observation

/// O que ocupa o centro da janela no lugar das tabs de terminal (03 §12): páginas e o viewer.
public enum CenterPage: Equatable, Sendable {
    case workspace
    case viewer(String)
    case computers
    /// Painel do lote (03 §12.4); o valor é o nome do lote.
    case batch(String)
    /// Library (03 §13, ⇧⌘L): Agents, Skills e Profiles.
    case library
    /// Datasets (03 §12.5): a lista e, com o id, a tabela viva de um dataset.
    case datasets
    case dataset(String)
}

extension CenterPage {
    var isViewer: Bool { if case .viewer = self { true } else { false } }
}

/// Detalhe de um computador ou run no painel direito (03 §11.7): hoje a aba `Result`.
public struct ComputerDetail: Equatable, Sendable {
    public var name: String
    /// Pasta do run no host (`runs/<sessão>/<computador>/`).
    public var run: URL
    public var tab = "result"
}

/// F28: saída do viewer pedida enquanto o humano tem o controle; a UI mostra `Hand back to <Agent>?` antes de sair.
public struct PendingViewerExit: Equatable, Sendable {
    public var computer: String
    public var target: CenterPage
}

/// Controlador de computadores da UI (T3-05): registro dos computadores, viewer, página Computers, painel direito,
/// pedido de ajuda (Inbox, Dock, notificação) e as ações `computer.*` (03 §24.5). O hub é o mesmo que o MCP usa.
@MainActor
@Observable
public final class ComputersController {
    public let model = ComputersModel()
    /// O hub do app: o mesmo que o MCP usa. `useOrchestrator` troca pelo do orquestrador (F12).
    @ObservationIgnored public private(set) var hub = ComputerHub()
    @ObservationIgnored public private(set) var orchestrator: ComputerOrchestrator?
    public private(set) var page: CenterPage = .workspace
    public private(set) var panelOpen = false
    public private(set) var viewers: [String: ComputerViewerController] = [:]
    /// F28: o viewer só fecha depois da resposta do overlay `Hand back to <Agent>?`.
    public private(set) var pendingExit: PendingViewerExit?
    /// Detalhe aberto no painel direito (aba `Result`) e o que o run mostra agora.
    public internal(set) var detail: ComputerDetail?
    public internal(set) var detailCollected: CollectedRun?
    /// Filtro do painel do lote (03 §12.4) e o consolidado já lido por lote (`Collect All`, lote concluído).
    public internal(set) var batchFilter: BatchSummary.Filter = .all
    public internal(set) var consolidated: [String: BatchSummary] = [:]
    @ObservationIgnored let loader = RunResultLoader()
    @ObservationIgnored var batchTick = 0
    @ObservationIgnored var detailTick = 0
    /// Overlays (confirmação de `Archive Batch`, `New Batch…`); ligado pelo `AppEnvironment`.
    @ObservationIgnored weak var overlays: OverlayRouter?
    /// Lote cujo `Archive Batch` espera a confirmação.
    var pendingArchive: String?
    /// Computador cujo `Stop` espera a confirmação (03 §16.3).
    var pendingStop: String?
    /// F28: um lease humano ocioso voltou sozinho ao agente (o app mostra o toast `Control returned to <Agent>`).
    /// F29: nomes dos proxies salvos (Settings › Computers › Proxies) e o menu do card de aprovação; ligados pelo app.
    @ObservationIgnored public var proxyNames: () async -> [String] = { [] }
    @ObservationIgnored public var presentProxyMenu: (_ request: ComputerApprovalRequest, _ names: [String]) -> Void = { _, _ in }
    /// O menu `Keep files` / `Delete when done` / `Delete in 7 days` / `Delete in 30 days` do card de aprovação; ligado pelo app.
    @ObservationIgnored public var presentLeftoversMenu: (_ request: ComputerApprovalRequest) -> Void = { _ in }
    /// Runs terminados com arquivos no `work/` (seção "Left on disk" da página Computers).
    public internal(set) var leftovers: [RunLeftover] = []
    @ObservationIgnored var leftoversLoading = false
    /// Left on disk mostra todos (senão os 4 maiores).
    var leftoversExpanded = false
    /// `Delete now` liberou isto (o app mostra o toast).
    @ObservationIgnored public var onLeftoversFreed: (Int64) -> Void = { _ in }
    @ObservationIgnored public var onControlReturned: (_ computer: String, _ agent: String) -> Void = { _, _ in }
    @ObservationIgnored public var onPageChange: () -> Void = {}
    /// Histórico de navegação: a página do centro mudou (independe do `onPageChange`, que a janela já usa).
    @ObservationIgnored var onNavigate: () -> Void = {}
    @ObservationIgnored public var onPanelChange: (Bool) -> Void = { _ in }
    @ObservationIgnored public var notifier: any HelpNotifying = NoopHelpNotifier()
    @ObservationIgnored let log = LogFacade(.app, category: "computers")
    @ObservationIgnored private var refresher: Task<Void, Never>?
    @ObservationIgnored private var popOuts: [String: ViewerPopOut] = [:]
    @ObservationIgnored private var demoRig: DemoComputerRig?
    /// O hover card de um subagente está aberto: só então a miniatura corre (≤ 1 fps) fora do painel e da página Computers.
    @ObservationIgnored private var hoverPreviewOpen = false
    /// O hover card dos subagentes (ligado pelo `AppEnvironment`).
    @ObservationIgnored var hoverCards: SubagentHoverCardController?

    public func setHoverPreview(open: Bool) { hoverPreviewOpen = open }

    public init() {
        // Sem coordenador de atenção (Fatia 1) o próprio controlador mantém o badge; com ele, `AppEnvironment` religa isto
        // e o badge é a soma única (agentes + pedidos de ajuda) em `AttentionCoordinator.refreshDock`.
        model.onAttentionChange = { count in
            NSApp?.dockTile.badgeLabel = count > 0 ? "\(count)" : ""
        }
        model.onApprovalRequested = { [weak self] request in
            guard let self else { return }
            self.notifier.notify(approval: request)
            if NSApp?.isActive == false { NSApp.requestUserAttention(.informationalRequest) }
        }
        model.onHelpRequested = { [weak self] item, content in
            guard let self else { return }
            self.notifier.notify(item: item, content: content)
            if NSApp?.isActive == false { NSApp.requestUserAttention(.informationalRequest) }
        }
    }

    // MARK: Computadores

    /// F12: os computadores que o scheduler cria no `boxes_reserve` chegam aqui (linha filha da sidebar, viewer) e saem quando liberados.
    public func useOrchestrator(_ orchestrator: ComputerOrchestrator) async {
        self.orchestrator = orchestrator
        hub = orchestrator.hub
        let model = model
        await hub.setObservers(
            onRegister: { [weak self] computer in
                Task { @MainActor in
                    await model.attach(computer)
                    model.sessionIDs[computer.name] = await orchestrator.sessionID(ofComputer: computer.name)
                    let agent = await orchestrator.agentName(ofComputer: computer.name)
                    model.agentNames[computer.name] = agent
                    self?.viewers[computer.name]?.model.agentName = agent
                    self?.popOuts[computer.name]?.controller.model.agentName = agent
                }
            },
            onRemove: { [weak self] name in Task { @MainActor in self?.computerRemoved(name) } })
        await orchestrator.approvals.setObserver { requests in Task { @MainActor in model.setApprovals(requests) } }
        model.decide = { id, decision in Task { await orchestrator.approvals.decide(id: id, decision) } }
        model.chooseProxy = { id, proxy in Task { await orchestrator.approvals.setProxy(id: id, proxy: proxy) } }
        model.chooseLeftovers = { id, policy in Task { await orchestrator.approvals.setLeftovers(id: id, policy) } }
    }

    public func add(_ computer: ManagedComputer) async {
        await hub.register(computer)
        await model.attach(computer)
    }

    public func startRefreshing() {
        refresher?.cancel()
        refresher = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Miniaturas a ≤ 1 fps por computador só com a tela grande à vista (painel, página Computers, hover card; CS-403);
                // fora disso, um quadro a cada 15 s basta para a miniatura de cada subagente na sidebar.
                let visible = self.panelOpen || self.page == .computers || self.hoverPreviewOpen
                await self.model.refresh(withThumbnails: true, thumbnailEvery: visible ? 1 : 15)
                await self.refreshDetail()
                await self.refreshBatches()
                for name in await self.model.returnIdleControl() { self.onControlReturned(name, self.agentName(forComputer: name)) }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    public func stopRefreshing() { refresher?.cancel() }

    // MARK: Centro

    /// Nome do agente dono do computador, para os textos `Hand back to <Agent>?` e `Control returned to <Agent>`.
    public func agentName(forComputer name: String) -> String { model.agentNames[name] ?? "Claude" }

    /// O computador foi liberado/removido: o chrome do viewer dele (banner de ajuda, `Hand back to <Agent>?`, saída pendente) não pode
    /// ficar por cima de outra aba. Fecha a página se ela mostrava esse computador (sem perguntar: não há mais a quem devolver).
    func computerRemoved(_ name: String) {
        model.detach(name: name)
        if pendingExit?.computer == name { pendingExit = nil }
        if case .viewer(let current) = page, current == name {
            forceShow(.workspace)
        } else if viewers[name] != nil {
            closeViewer(name)
        }
        popOuts[name]?.close()
    }

    /// O humano tem o controle (ou o pediu) do computador do viewer aberto.
    func humanHasControl(_ name: String) -> Bool {
        guard let control = viewers[name]?.model.control else { return false }
        return control == .human
    }

    public func show(_ page: CenterPage) {
        guard self.page != page else { return }
        // F28: qualquer saída do viewer (tab, sidebar, Esc, ⌘W, ←) com lease humano pergunta antes.
        if case .viewer(let name) = self.page, humanHasControl(name) {
            pendingExit = PendingViewerExit(computer: name, target: page)
            return
        }
        forceShow(page)
    }

    private func forceShow(_ page: CenterPage) {
        guard self.page != page else { return }
        pendingExit = nil
        let old = self.page
        self.page = page
        if case .viewer(let name) = old, old != page { closeViewer(name) }
        if case .viewer(let name) = page { ensureViewer(name) }
        onPageChange()
        onNavigate()
    }

    /// Resposta do overlay: `Hand Back` (padrão) devolve o controle e sai; `Keep control` sai mantendo o lease (volta sozinho depois de
    /// 3 min sem input); `nil` cancela e continua no viewer.
    public func resolveExit(handBack: Bool?) async {
        guard let pending = pendingExit else { return }
        guard let handBack else { pendingExit = nil; return }
        if handBack { await viewers[pending.computer]?.handBack() }
        forceShow(pending.target)
    }

    /// F28: `Hand Back` sem abrir o viewer (linha do subagente, card da sessão).
    public func handBackNow(_ name: String) async {
        if let viewer = viewers[name] ?? popOuts[name]?.controller {
            await viewer.handBack()
        } else {
            try? await model.computer(named: name)?.handBack(note: nil)
            await model.refresh()
        }
    }

    public func closePage() {
        guard page != .workspace else { return }
        show(.workspace)
    }

    @discardableResult
    func ensureViewer(_ name: String) -> ComputerViewerController? {
        if let existing = viewers[name] { return existing }
        guard let computer = model.computer(named: name) else { return nil }
        let controller = ComputerViewerController(computer: computer)
        controller.model.agentName = agentName(forComputer: name)
        controller.onClose = { [weak self] in self?.closePage() }
        viewers[name] = controller
        return controller
    }

    private func closeViewer(_ name: String) {
        // Fechar o viewer não para o computador, não resolve o pedido e não muda o lease (CS-405).
        viewers[name]?.stop()
        viewers[name] = nil
    }

    /// Abre a tela de um computador como tab da sessão dona dele; ligado pelo `AppEnvironment`. `false` = sem sessão (vai para a página).
    @ObservationIgnored public var openInSession: (_ name: String, _ sessionID: UUID) -> Bool = { _, _ in false }

    public func openViewer(_ name: String) {
        guard model.computer(named: name) != nil else { return }
        // Computador de um subagente: abre como tab da sessão (mesmo nível do agente e das tabelas), não numa página à parte.
        if let sid = model.sessionIDs[name], openInSession(name, sid) {
            closePage()
            model.markReadForComputer(name)
            return
        }
        show(.viewer(name))
        model.markReadForComputer(name)
    }

    /// O viewer no centro, ou o da janela própria.
    public var activeViewer: ComputerViewerController? {
        if case .viewer(let name) = page { return viewers[name] }
        if let popOut = popOuts.values.first?.controller { return popOut }
        // Viewer como pane da sessão: não é página nem janela, então vale o último em que se pegou o controle (ou o único aberto).
        // Sem isso o Take Over/Hand Back de um computador ao lado do agente falhava com "no viewer is open".
        if let name = lastPaneViewer, let controller = viewers[name] { return controller }
        return viewers.count == 1 ? viewers.values.first : nil
    }

    /// Último viewer usado por nome (Take Over de um pane da sessão): o alvo do ⇧⌘R e do Hand Back sem argumento.
    @ObservationIgnored private var lastPaneViewer: String?

    func viewer(for argument: ActionArgument) -> ComputerViewerController? {
        if let name = argument.value, !name.isEmpty, let controller = viewers[name] ?? popOuts[name]?.controller { return controller }
        return activeViewer
    }

    // MARK: Painel direito

    public func setPanel(open: Bool) {
        guard panelOpen != open else { return }
        panelOpen = open
        onPanelChange(open)
    }

    public func togglePanel() { setPanel(open: !panelOpen) }

    // MARK: Janela própria (03 §11)

    public func popOut(_ name: String) {
        guard popOuts[name] == nil, let controller = viewers[name] else { return }
        let popOut = ViewerPopOut(controller: controller, computers: self) { [weak self] in
            self?.popOuts[name] = nil
            controller.stop()
        }
        popOuts[name] = popOut
        viewers[name] = nil
        if page == .viewer(name) {
            page = .workspace
            onPageChange()
            onNavigate()
        }
        popOut.show()
    }

    // MARK: Ações

    public func register(in registry: ActionRegistry) throws {
        let hasComputer: ActionRegistry.Enablement = { [unowned self] in
            model.rows.isEmpty && viewers.isEmpty ? .disabled(reason: String(localized: "No computers yet.", bundle: .module)) : .enabled
        }
        let viewerOpen: ActionRegistry.Enablement = { [unowned self] in
            activeViewer == nil ? .disabled(reason: String(localized: "Open a computer first.", bundle: .module)) : .enabled
        }
        // Clicar de novo no item da página aberta não volta para a sessão (era um vai-e-volta confuso): fica onde está.
        try registry.register(.pageComputers) { [unowned self] _ in
            if page != .computers { show(.computers) }
            return "computers"
        }
        try registry.register(.panelComputers) { [unowned self] _ in
            togglePanel()
            return panelOpen ? "open" : "closed"
        }
        try registry.register(.pageClose, enablement: { [unowned self] in page == .workspace ? .disabled(reason: "No page is open") : .enabled }) { [unowned self] _ in
            closePage()
            return nil
        }
        try registry.register(.computerOpenViewer, enablement: hasComputer) { [unowned self] arg in
            guard let name = arg.value ?? model.rows.first?.id else { throw ActionError.failed(.computerOpenViewer, message: "expected select(<computer>)") }
            openViewer(name)
            return name
        }
        try registry.register(.computerPopOut, enablement: viewerOpen) { [unowned self] arg in
            guard let controller = viewer(for: arg) else { return nil }
            popOut(controller.name)
            return controller.name
        }
        // ⇧⌘R: Take Over e Hand Back. De fora do viewer (Inbox, miniatura, notificação) abre o viewer antes.
        try registry.register(.computerTakeOver, enablement: hasComputer) { [unowned self] arg in
            if let name = arg.value, viewers[name] == nil, popOuts[name] == nil {
                openViewer(name)
                // Computador de sessão abre como pane, que só nasce no próximo layout: o viewer é criado já, senão a ação não
                // achava viewer nenhum (Take Over do "Needs You" na sidebar não fazia nada).
                _ = ensureViewer(name)
            }
            guard let controller = viewer(for: arg) ?? activeViewer else { throw ActionError.failed(.computerTakeOver, message: "no viewer is open") }
            lastPaneViewer = controller.name
            await controller.toggleControl()
            return controller.model.control.rawValue
        }
        let handBackEnabled: ActionRegistry.Enablement = { [unowned self] in
            activeViewer != nil || model.rows.contains { $0.snapshot.control == .human }
                ? .enabled : .disabled(reason: String(localized: "Open a computer first.", bundle: .module))
        }
        try registry.register(.computerHandBack, enablement: handBackEnabled) { [unowned self] arg in
            // F28: `select("now:<computer>")` devolve já, sem viewer; `exit-handback`/`exit-keep`/`exit-stay` respondem ao overlay de saída.
            if let value = arg.value, value.hasPrefix("now:") {
                let name = String(value.dropFirst(4))
                await handBackNow(name)
                return model.computer(named: name) == nil ? nil : "agent"
            }
            switch arg.value {
            case "exit-handback": await resolveExit(handBack: true); return page.isViewer ? "stayed" : "left"
            case "exit-keep": await resolveExit(handBack: false); return page.isViewer ? "stayed" : "left"
            case "exit-stay": await resolveExit(handBack: nil); return "stayed"
            default: break
            }
            guard let controller = viewer(for: arg) else { return nil }
            if arg.kind == .set, controller.model.control == .human {  // `ctl ui action computer.handBack set "<nota>"`
                controller.model.handBackNote = arg.value ?? ""
                await controller.handBack()
                return controller.model.control.rawValue
            }
            switch arg.value {
            case "confirm": await controller.handBack()
            case "cancel": controller.model.cancelHandBackNote()
            default:
                if controller.model.control == .human { controller.model.showHandBackNote() }
            }
            return controller.model.control.rawValue
        }
        try registry.register(.computerForceTakeOver, enablement: viewerOpen) { [unowned self] arg in
            guard let controller = viewer(for: arg) else { return nil }
            await controller.takeOver(force: true)
            return controller.model.control.rawValue
        }
        try registry.register(.computerDeclineHelp, enablement: viewerOpen) { [unowned self] arg in
            guard let controller = viewer(for: arg) else { return nil }
            switch arg.value {
            case "confirm": await controller.model.confirmDecline()
            case "cancel": controller.model.cancelDecline()
            default: controller.model.showDecline()
            }
            return nil
        }
        try registry.register(
            .computerReleaseKeyboard,
            enablement: { [unowned self] in activeViewer?.model.keyboardCaptured == true ? .enabled : .disabled(reason: String(localized: "The keyboard is not captured.", bundle: .module)) }
        ) { [unowned self] _ in
            activeViewer?.releaseKeyboard()
            return nil
        }
        try registry.register(.computerReconnect, enablement: viewerOpen) { [unowned self] arg in
            viewer(for: arg)?.reconnectNow()
            return nil
        }
        let humanOnly: ActionRegistry.Enablement = { [unowned self] in
            activeViewer?.model.control == .human ? .enabled : .disabled(reason: String(localized: "Take over first.", bundle: .module))
        }
        try registry.register(.computerPaste, enablement: humanOnly) { [unowned self] _ in
            let count = await activeViewer?.pasteFromClipboard() ?? 0
            return "\(count)"
        }
        try registry.register(.computerCopySelection, enablement: viewerOpen) { [unowned self] _ in
            await activeViewer?.copySelection() == true ? "copied" : "empty"
        }
        // F12, modo Ask: o card de aprovação, o item do Inbox e a notificação disparam estas ações.
        let waiting: ActionRegistry.Enablement = { [unowned self] in
            model.approvals.isEmpty ? .disabled(reason: String(localized: "No computer request is waiting.", bundle: .module)) : .enabled
        }
        func decision(_ id: ActionID, _ decision: ComputerApprovalDecision) throws {
            try registry.register(id, enablement: waiting) { [unowned self] arg in
                guard let request = arg.value.flatMap({ value in model.approvals.first { $0.id == value } }) ?? model.approvals.first else {
                    throw ActionError.failed(id, message: "No computer request is waiting.")
                }
                model.decide(request.id, decision)
                return request.id
            }
        }
        try decision(.computerAllowRequest, .allow)
        try decision(.computerAllowRequestSession, .allowForSession)
        try decision(.computerDenyRequest, .deny)
        // O card de aprovação escolhe o que sai do disco quando o computador terminar.
        try registry.register(.computerRequestLeftovers, enablement: waiting) { [unowned self] arg in
            let parts = (arg.value ?? "").split(separator: "|", maxSplits: 1).map(String.init)
            guard let request = parts.first.flatMap({ value in model.approvals.first { $0.id == value } }) ?? model.approvals.first else {
                throw ActionError.failed(.computerRequestLeftovers, message: "No computer request is waiting.")
            }
            guard parts.count == 2 else {
                presentLeftoversMenu(request)
                return "menu"
            }
            guard let policy = LeftoversPolicy(rawValue: parts[1]) else {
                throw ActionError.failed(.computerRequestLeftovers, message: "expected keep, whenDone, days7 or days30")
            }
            model.chooseLeftovers(request.id, policy)
            return policy.rawValue
        }
        // F29: o card de aprovação escolhe o proxy (o menu lista `Direct` + os proxies salvos).
        try registry.register(.computerRequestProxy, enablement: waiting) { [unowned self] arg in
            let parts = (arg.value ?? "").split(separator: "|", maxSplits: 1).map(String.init)
            guard let request = parts.first.flatMap({ value in model.approvals.first { $0.id == value } }) ?? model.approvals.first else {
                throw ActionError.failed(.computerRequestProxy, message: "No computer request is waiting.")
            }
            guard parts.count == 2 else {
                presentProxyMenu(request, await proxyNames())
                return "menu"
            }
            let proxy = parts[1] == "direct" ? nil : parts[1]
            model.chooseProxy(request.id, proxy)
            return proxy ?? "direct"
        }
        try registry.register(.computerShowPreview, enablement: hasComputer) { [unowned self] arg in
            guard arg.kind == .select, let name = arg.value else {
                hoverCards?.hide()
                return "closed"
            }
            guard hoverCards?.present(computer: name, window: NSApp.windows.first { $0.canBecomeMain }) == true else {
                throw ActionError.failed(.computerShowPreview, message: "No subagent row shows \(name)")
            }
            return name
        }
        // "Open Docker": a linha do computador e o Settings oferecem quando o Docker está parado (07 CS-104).
        try registry.register(.dockerStart) { _ in
            DockerLauncher.open()
            return "opening"
        }
    }

    // MARK: Desenvolvimento e evidência (nunca em uso normal)

    /// `RACKY_DEMO_COMPUTER=1`: sobe um computador de teste (labels `racky.test=1`), abre o viewer e, com `RACKY_DEMO_HELP=1`,
    /// simula o filho pedindo ajuda (CAPTCHA). `RACKY_VIEWER_MEASURE=<arquivo>` grava fps e latência medidos no WKWebView.
    public func startDemo(environment: [String: String]) {
        guard environment["RACKY_DEMO_COMPUTER"] == "1" else { return }
        let home = (environment["RACKY_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) })
            ?? DemoComputerRig.defaultHome
        guard let root = environment["RACKY_REPO_ROOT"].map({ URL(fileURLWithPath: $0, isDirectory: true) }) else {
            log.error("demo computer needs RACKY_REPO_ROOT")
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let rig = try await DemoComputerRig.provision(repoRoot: root, home: home)
                self.demoRig = rig
                let marker = home.appendingPathComponent("demo-computer.run")
                try? Data("\(rig.runID)\n".utf8).write(to: marker)
                await self.add(rig.computer)
                await self.hub.registerChild(id: "demo-child", capability: "demo-capability")
                let service = ComputerToolService(hub: self.hub)
                _ = await service.call("box_claim", arguments: ["name": "demo-a", "wait_s": 5], child: "demo-child")
                _ = await service.call("browser_eval", arguments: DemoComputerRig.installScript(DemoComputerRig.animationHTML), child: "demo-child")
                self.startRefreshing()
                self.openViewer("demo-a")
                self.watchSnapshotRequests(home: home)
                await self.runDemoScript(rig: rig, service: service, environment: environment, home: home)
            } catch {
                self.log.error("demo computer failed: \(error)")
            }
        }
    }

    /// Evidência: o canvas do noVNC não entra na captura AppKit da janela (`ctl screenshot`). Escrever um caminho PNG em
    /// `<home>/snapshot-request` faz o app gravar a imagem do próprio WebView nesse caminho (`WKWebView.takeSnapshot`).
    private func watchSnapshotRequests(home: URL) {
        let trigger = home.appendingPathComponent("snapshot-request")
        try? Data().write(to: trigger)
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                guard let path = (try? String(contentsOf: trigger, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { continue }
                try? Data().write(to: trigger)
                if let png = await self.activeViewer?.web.snapshotPNG() { try? png.write(to: URL(fileURLWithPath: path)) }
            }
        }
    }

    private func runDemoScript(rig: DemoComputerRig, service: ComputerToolService, environment: [String: String], home: URL) async {
        if let path = environment["RACKY_VIEWER_MEASURE"], let controller = viewers["demo-a"] {
            let seconds = Int(environment["RACKY_VIEWER_MEASURE_SECONDS"] ?? "") ?? 12
            let result = await controller.measure(seconds: seconds) {
                _ = try? await rig.computer.backend.runtime("eval", DemoComputerRig.installScript(DemoComputerRig.inputHTML), timeout: 15)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(result) { try? data.write(to: URL(fileURLWithPath: path)) }
            await controller.handBack()
            _ = try? await rig.computer.backend.runtime("eval", DemoComputerRig.installScript(DemoComputerRig.animationHTML), timeout: 15)
        }
        guard environment["RACKY_DEMO_HELP"] == "1" else { return }
        _ = try? await rig.computer.backend.runtime("eval", DemoComputerRig.installScript(DemoComputerRig.captchaHTML), timeout: 15)
        let requested = await service.call(
            "help_request", arguments: ["kind": "captcha", "reason": "hCaptcha on the listing search page", "url": "http://aca-prod.example.test/search"], child: "demo-child")
        let requestID = requested.content.first?["text"].flatMap { try? JSON.parse($0.string ?? "") }?["request_id"]?.string ?? ""
        let waited = await service.call("help_wait", arguments: ["request_id": .string(requestID), "wait_s": 50], child: "demo-child")
        var outcome = waited.content.first?["text"]?.string ?? ""
        for _ in 0..<20 where outcome.contains("\"open\"") {
            let again = await service.call("help_wait", arguments: ["request_id": .string(requestID), "wait_s": 50], child: "demo-child")
            outcome = again.content.first?["text"]?.string ?? ""
        }
        try? Data(outcome.utf8).write(to: home.appendingPathComponent("demo-help-wait.json"))
    }

    public func tearDownDemo() async { await demoRig?.cleanup() }
}

extension ComputersModel {
    /// Abrir o viewer de um computador marca como lidos os pedidos dele (03 §9.1: clicar leva ao viewer e marca lido).
    func markReadForComputer(_ name: String) {
        for item in inbox where item.computer == name { markRead(item.id) }
    }
}
