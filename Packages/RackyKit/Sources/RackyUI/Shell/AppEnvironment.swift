import RackyCore
import RackyDesignSystem
import RackyPlatform
import RackyProtocol
import RackyStore
import AppKit
import Foundation
import Observation

/// Estado mínimo da casca vazia (T1-02). O modelo de domínio (projetos, sessões, tabs) entra com T1-05.
@MainActor
@Observable
public final class ShellModel {
    public var appNameHidden = false
    /// Sidebar recolhida (⌘B): a faixa da titlebar vira flutuante (03 §1.3).
    public var sidebarCollapsed = false
    /// Largura da faixa da titlebar (semáforos, nome, voltar/avançar) quando flutua sobre o conteúdo (sidebar recolhida).
    public var titlebarStripWidth: CGFloat = 0
    /// Tela cheia: semáforos somem e o pad de 80 vira 0 (03 §1.2).
    public var isFullScreen = false
    /// Histórico de navegação (⌥⌘←/→). Sem páginas ainda: os dois lados ficam desabilitados com motivo.
    public var canGoBack = false
    public var canGoForward = false
    public init() {}
}

/// Ambiente de serviços montado no `@main` (08 AR-133): registro de ações, atalhos, árvore de UI,
/// feature flag por fatia e o canal `ctl` (opt-in). Sem singletons.
@MainActor
public final class AppEnvironment {
    public let flags: SliceFlags
    public let shell = ShellModel()
    /// Histórico ←/→ (sessão, terminal, viewer, Inbox, Computers) e a trava enquanto o próprio histórico navega.
    var navigation = NavigationHistory()
    var navigating = false
    public let elements = UIElementStore()
    public let registry: ActionRegistry
    public let overlays = OverlayRouter()
    public let toasts = ToastCenter()
    let sidebar = SidebarModel()
    /// Tab row e árvore de panes da sessão selecionada (T1-14).
    let workspace: WorkspaceModel
    /// Settings em página inteira e onboarding mínimo (T1-26): detecção de CLIs, perfis de lançamento e configuração.
    public let settings: SettingsModel
    public let onboarding: OnboardingModel
    /// Settings › Diagnostics, log em disco, métricas, crash e pacote exportável (T4-04).
    public let diagnostics: DiagnosticsController
    let projects: ProjectsController
    public let keyBindings: KeyBindingRegistry
    /// Atenção, Inbox e notificações (Fatia 2). `nil` na Fatia 1: sem hooks o agente vivo é `Status unavailable`.
    public let attention: AttentionCoordinator?
    /// `RACKY_NOTIFICATIONS=fake`: o que seria entregue ao sistema fica em memória e em `run/fake-notifications.jsonl`.
    public let fakeNotifier: RecordingNotificationCenter?
    /// Troca o `NSApp.dockTile.badgeLabel` (testes).
    let dockBadgeOverride: (@MainActor (String?) -> Void)?
    /// Pane de terminal focado: destino das ações de zoom, busca, copiar/colar e limpar (T1-09).
    public let terminalRouter = TerminalActionRouter()
    /// Computadores (T3-05): viewer, página Computers, painel direito, pedido de ajuda e ações `computer.*`.
    public let computers = ComputersController()
    /// Tráfego de cada computador (aba Computers do painel e a tela Traffic).
    public private(set) lazy var traffic = TrafficController(computers: computers)
    /// Datasets (Datasets v1): a lista e a tabela viva do que os subagentes de uma sessão coletam.
    public let datasets = DatasetsController()
    /// Área Data (spec data-hub): datasets do Racky e conexões. Conexões de exemplo só com `RACKY_DATA_DEMO=1` (etapa 2).
    public private(set) var dataHub: DataHubController!
    /// Painel direito (10-right-panel): contêiner dos módulos Files, Insights e Computers.
    public let rightPanel = RightPanelController()
    /// Módulo Files: árvore do diretório da sessão que acompanha o cwd do terminal focado.
    let files: FilesController
    /// GitHub (T2-05): chips de PR da sidebar, Source Control, Checks e "Create Pull Request…". Só consulta o `gh` na Fatia 2.
    let github: GitHubController
    /// Módulo Insights: uso de IA (transcripts do Claude/Codex) e máquina; só amostra enquanto a view está em cena.
    let insights: InsightsModel
    /// Library só leitura (03 §13) e a aba Context (03 §10.6): ativação aditiva por sessão, plugin gerado no lançamento.
    let library: LibraryController
    private(set) var context: ContextController!
    let activations: SessionActivationStore
    /// `Insert Skill or Agent…` (03 §8) e a palette (⌘J) onde ele mora.
    private(set) var inserter: PromptInsertController!
    private(set) var palette: PaletteController!
    private var catalogWatch: Task<Void, Never>?
    /// Status bar (03 §5): lê o Insights e os computadores; nada de polling próprio.
    let statusBar: StatusBarController
    /// "Subagent computers" por sessão (F12): ícone, menu, `Restart to apply`.
    private(set) var subagentComputers: SubagentComputersController!
    /// Hover card do computador de um subagente (pré-visualização ao vivo).
    private(set) var subagentHoverCards: SubagentHoverCardController!
    /// O orquestrador nasce depois do Store (as identidades e a árvore são persistidas); o lançamento o encontra por aqui.
    let orchestratorHolder: OrchestratorHolder
    var computerSweeper: Task<Void, Never>?
    /// ⌘Q com agentes vivos, modo accessory e barra de menus (T1-24).
    public private(set) var lifecycle: AppLifecycleCoordinator!
    public let automationEnabled: Bool
    /// `RACKY_TEST_HEADLESS=1`: instância de teste/evidência que nunca aparece (sem Dock, janela, menu, status item nem notificações).
    public let headless: Bool
    public let fixture: String?
    public let socketPath: String
    private var ctl: CtlServer?
    private var hub: AppSockHub?
    var activity: ActivityService?
    private var store: RackyStore?
    /// Resultado da reconciliação ao abrir; consumido pela retomada automática (P25) depois que o workspace e as settings carregam.
    private var restoreReport: ReconcileReport?
    /// `session.launch`: sessão com o agente já rodando (P9, M-501).
    private var launcher: SessionLauncher?
    /// Sessões limpas (⇧⌘N, ⌥⇧⌘N, arquivar, apagar, mover) e Quick Launch (⌥⌘N, "+" da tab row) — T1-17 e T1-21.
    private(set) var cleanSessions: CleanSessionController?
    private var quickLaunch: QuickLaunchController?
    /// Composer ⌘N (T1-20): overlay, ações `composer.*` e `session.new*`.
    private(set) var composer: ComposerController?
    /// Clone from GitHub… (F24): overlay, ações `project.cloneFromGitHub` e `dialog.cloneRepo.*`.
    private(set) var cloneRepo: CloneRepoController?
    /// "Resume Agents…" em lote (T2-07, 03 §16.7) e a aba Conversations (⇧⌘H, 03 §10.5).
    private(set) var resumeAgents: ResumeAgentsController?
    private(set) var conversations: ConversationsController?
    /// "Open in…" e "Open in Editor" (T1-27).
    private(set) var openIn: OpenInController?
    /// "New Batch…" (T3-07, 03 §16.15).
    private(set) var newBatch: NewBatchController?
    let environmentVariables: [String: String]
    private let log = LogFacade(.app, category: "ui")

    /// `RACKY_AUTOMATION=1` liga o canal `ctl` (o toggle em Settings > Advanced chega com T1-26).
    /// `RACKY_SLICE=<n>` e `RACKY_SCREEN=<tela>` valem só para dev e testes.
    public init(environment: [String: String] = ProcessInfo.processInfo.environment, dockBadge: (@MainActor (String?) -> Void)? = nil) {
        dockBadgeOverride = dockBadge
        let holder = OrchestratorHolder()
        orchestratorHolder = holder
        let activations = SessionActivationStore()
        self.activations = activations
        library = LibraryController(activations: activations)
        let flags = SliceFlags.fromEnvironment(environment)
        self.flags = flags
        self.automationEnabled = environment["RACKY_AUTOMATION"] == "1"
        // 04 §11.3: `RACKY_MOTION_MODE=normal|instant|slow:<fator>`, só com o canal de automação ligado (revisar motion quadro a quadro).
        if automationEnabled, let raw = environment["RACKY_MOTION_MODE"] {
            if raw == "instant" { MotionPolicy.shared.mode = .instant }
            else if raw.hasPrefix("slow:"), let factor = Double(raw.dropFirst(5)), factor > 0 { MotionPolicy.shared.mode = .slow(factor: factor) }
        }
        self.dataHub = DataHubController(datasets: datasets, demo: environment["RACKY_DATA_DEMO"] == "1")
        self.headless = environment["RACKY_TEST_HEADLESS"] == "1"
        self.fixture = environment["RACKY_SCREEN"]
        self.socketPath = AppSockPath.resolve(environment: environment)
        self.environmentVariables = environment
        let surface = WindowAutomation(store: elements, flags: flags, fixture: fixture, automationEnabled: automationEnabled)
        self.registry = ActionRegistry(flags: flags, surface: surface)
        var bindings = KeyBindingRegistry()
        do { bindings = try KeyBindingRegistry.canonical() } catch { log.publicError("canonical key bindings invalid") }
        if !bindings.conflicts().isEmpty { log.publicError("key binding conflicts detected") }
        self.keyBindings = bindings
        let settings = SettingsModel(flags: flags, probe: Self.makeProbe(fixture: environment["RACKY_SCREEN"]))
        self.settings = settings
        let choice = ConflictChoiceBox()
        let supportRoot = StorePaths.default(environment: environment).root
        // Com sondas de mentira, "Disable Globally…" mexe numa home de mentira dentro do RACKY_HOME, nunca na do usuário.
        let backup = Self.usesFakeDiagnostics(environment)
            ? GlobalSkillBackup(home: supportRoot.appendingPathComponent("fake-home", isDirectory: true), backupRoot: supportRoot)
            : GlobalSkillBackup(backupRoot: supportRoot)
        let probes = Self.makeDiagnosticsProbes(
            environment: environment, backup: backup, choice: choice, supportRoot: supportRoot,
            forceDocker: { await MainActor.run { settings.settings.computers.forceDocker } })
        self.onboarding = OnboardingModel(settings: settings, diagnostics: DiagnosticsEngine(probes: probes), conflictChoice: choice, backup: backup)
        let diagnostics = DiagnosticsController(paths: StorePaths(root: supportRoot), settings: settings, onboarding: onboarding, toasts: toasts)
        self.diagnostics = diagnostics
        settings.diagnostics = diagnostics
        let screen = environment["RACKY_SCREEN"]
        autoOnboarding = environment["RACKY_SKIP_ONBOARDING"] != "1" && (screen == nil || screen == Self.setupDemoFixture)
        self.projects = ProjectsController(sidebar: sidebar, overlays: overlays, toasts: toasts, automationEnabled: automationEnabled)
        surface.inputBlockedProbe = { [overlays] in overlays.blocksTerminalInput }
        elements.enablement = { [registry] id in registry.availability(of: id) }
        let storeRoot = StorePaths.default(environment: environment).root
        let slice2 = flags.isEnabled(.slice2)
        if slice2 {
            let center: any NotificationCentering
            if environment["RACKY_NOTIFICATIONS"] == "fake" || environment["RACKY_TEST_HEADLESS"] == "1" {
                let recorder = RecordingNotificationCenter(
                    authorization: .notDetermined, logURL: storeRoot.appendingPathComponent("run/fake-notifications.jsonl"))
                fakeNotifier = recorder
                center = recorder
            } else {
                fakeNotifier = nil
                center = SystemNotificationCenter()
            }
            attention = AttentionCoordinator(notifier: center)
        } else {
            fakeNotifier = nil
            attention = nil
        }
        let loginProvider = LoginShellEnvProvider(
            config: LoginShellEnvConfig(runDirectory: storeRoot.appendingPathComponent("run", isDirectory: true)))
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1.0 (dev)"
        let runtime = TerminalRuntime(
            configuration: TerminalRuntime.Configuration(
                daemonHome: storeRoot, daemonExecutable: environment["RACKY_DAEMON"].map { URL(fileURLWithPath: $0) },
                stopDaemonOnQuit: automationEnabled || environment["RACKY_STOP_DAEMON_ON_QUIT"] == "1",
                appSocketPath: socketPath, build: build,
                backgroundAgent: Self.makeBackgroundAgent(environment: environment, storeRoot: storeRoot),
                loginEnvironment: { await loginProvider.environment().variables },
                slice: slice2 ? .slice2 : .slice1, helperPath: slice2 ? Self.helperPath(environment) : nil,
                sessionLibrary: { session in
                    // Itens da Library ligados só nesta sessão: o plugin nasce a cada lançamento e o que ele levou fica registrado.
                    let refs = await activations.refs(for: session)
                    await activations.noteLaunched(session: session, ids: Set(refs.map(\.id)))
                    guard !refs.isEmpty else { return nil }
                    return await BlockingIOBridge.run { SessionLibraryBuilder.build(refs) }
                },
                prepareOrchestration: { info in
                    guard let orchestrator = holder.value else { return nil }
                    return try? await orchestrator.prepareParent(info)
                },
                endOrchestration: { parent in await holder.value?.endParent(parent) }),
            registry: registry, elements: elements)
        workspace = WorkspaceModel(runtime: runtime)
        files = Self.makeFilesController(workspace: workspace)
        // 45 s com a janela ativa (03/06 §5.5: 30–60 s), 5 min em segundo plano; o serviço só vai à rede quando o cache vence.
        var githubPolicy = GitHubPollingPolicy()
        githubPolicy.activeInterval = 45
        github = GitHubController(
            service: GitHubService(policy: githubPolicy), source: Self.makeGitHubSource(sidebar: sidebar), overlays: overlays,
            toasts: toasts, openURL: { NSWorkspace.shared.open($0) })
        // Limites exatos (Keychain + rede) só no produto; testes e execuções fora do bundle ficam offline.
        let limits: ClaudeLimitsClient = Bundle.main.bundleURL.pathExtension == "app" ? ClaudeLimitsClient() : .offline
        insights = InsightsModel(service: InsightsService(config: .standard(supportDirectory: storeRoot), limitsClient: limits))
        statusBar = StatusBarController(insights: insights, computers: computers, overlays: overlays, elements: elements, flags: flags)
        // Ícone real na barra de menus só no produto (`.app`): testes e execuções fora do bundle usam o item de mentira.
        let menuBarItem: any StatusBarProviding = Bundle.main.bundleURL.pathExtension == "app" ? SystemStatusBar() : InMemoryStatusBar()
        subagentComputers = SubagentComputersController(sidebar: sidebar, workspace: workspace, overlays: overlays, elements: elements)
        workspace.subagent = subagentComputers
        sidebar.subagent = subagentComputers
        lifecycle = AppLifecycleCoordinator(registry: registry, overlays: overlays, statusBar: menuBarItem)
        registerShellActions()
        wireLifecycle()
        do { try sidebar.registerActions(in: registry) } catch { log.publicError("duplicate sidebar action registration") }
        do { try projects.registerActions(in: registry) } catch { log.publicError("duplicate project action registration") }
        wireOverlays()
        wireWorkspace()
        if fixture == Self.overlayDemoFixture || fixture == SidebarFixtures.screenID { registerOverlayDemo() }
        if fixture == SidebarFixtures.screenID { registerSidebarDemo() }
        do { try terminalRouter.register(in: registry) } catch { log.publicError("duplicate terminal action registration") }
        wireSettings()
        wireDiagnostics()
        wireAttention(environment: environment)
        wireComputers()
        wireLibrary()
        wireRightPanel()
        wireStatusBar()
        wireGitHub(slice2: slice2, environment: environment)
    }

    /// Liga a Library e a aba Context: ações `page.library`, `library.*` e `context.*`, abrir no editor pelo `OpenInController` e a sessão
    /// em foco da sidebar. O índice do catálogo entra quando o Store abre (`startStore`).
    private func wireLibrary() {
        library.projectRoots = { [sidebar] in sidebar.snapshot.projects.map { URL(fileURLWithPath: $0.rootPath, isDirectory: true) } }
        library.currentSession = { [sidebar] in
            guard let id = sidebar.selectedSession, let session = sidebar.session(id) else { return nil }
            return LibrarySessionTarget(id: id, title: session.title, folder: session.folderPath)
        }
        library.profiles = { [settings] in settings.catalog.profiles }
        library.openFile = { [weak self] url in
            guard let openIn = self?.openIn else { throw ActionError.failed(.libraryOpenInEditor, message: "Open in… isn't available.") }
            _ = try await openIn.openFile(url, target: nil)
        }
        library.reveal = { [weak self] url in self?.openIn?.system.reveal(url) }
        library.showPage = { [computers, sidebar] in
            sidebar.setInbox(open: false)
            computers.show(.library)
        }
        library.hidePage = { [computers] in computers.closePage() }
        library.isPageOpen = { [computers] in computers.page == .library }
        library.openSettings = { [settings] section in settings.open(section: section) }
        do { try library.register(in: registry) } catch { log.publicError("duplicate library registration") }
        let controller = ContextController(library: library, overlays: overlays, showModule: { [rightPanel] in rightPanel.show($0) })
        controller.restartableAgents = { [workspace] in
            workspace.terminalsInCurrentSession
                .filter { $0.provider == .claude && ($0.state == .running || $0.state == .launching) && RestorePlanner.nativeID(of: $0) != nil }
                .map(\.id)
        }
        controller.relaunch = { [workspace] id in await workspace.relaunchApplyingSettings(id) }
        context = controller
        do { try controller.register(in: registry) } catch { log.publicError("duplicate context registration") }
        let insert = PromptInsertController(library: library, registry: { [weak self] in self?.registry })
        insert.focusedAgent = { [workspace] in
            guard let id = workspace.focusedTerminalID, let terminal = workspace.terminal(id), terminal.provider.isAgent, workspace.paneState(id) == .running else { return nil }
            return FocusedAgent(terminal: id, provider: terminal.provider)
        }
        insert.returnFocusToTerminal = { [workspace] in workspace.focusTerminalOfActiveTab() }
        insert.closeLibraryPage = { [computers] in if computers.page == .library { computers.closePage() } }
        inserter = insert
        let commandPalette = PaletteController(inserter: insert, overlays: overlays, sidebar: sidebar, workspace: workspace, registry: { [weak self] in self?.registry })
        insert.openPalette = { [commandPalette] in commandPalette.open(insertMode: $0) }
        palette = commandPalette
        do { try insert.register(in: registry) } catch { log.publicError("duplicate prompt insert registration") }
        do { try commandPalette.register(in: registry) } catch { log.publicError("duplicate palette registration") }
    }

    /// Índice do catálogo (`CatalogService`) sobre o Store aberto: leitura das pastas nativas, só com FSEvents/kqueue no app de verdade.
    private func startCatalog(store: RackyStore) async {
        let service = CatalogService(store: store, roots: .current())
        library.loadRows = { roots in
            try? await service.setProjectRoots(roots)
            return ((try? await service.items()) ?? []).map { $0 }
        }
        guard !headless, fixture == nil else { return }
        catalogWatch?.cancel()
        catalogWatch = Task { [weak self] in
            guard let stream = try? await service.startWatching() else { return }
            for await _ in stream { await self?.library.reload() }
        }
    }

    /// Liga a status bar: ações `view.toggleStatusBar` e `statusBar.*`, Docker parado vindo do Settings e `Start Docker`.
    private func wireStatusBar() {
        statusBar.dockerStopped = { [settings] in settings.dockerStatus.stopped }
        // Agents (03 §5): mesma fila e mesma contagem do badge do Inbox.
        statusBar.agentsSource = { [attention, computers] in
            guard let attention else { return nil }
            return StatusBarAgents.summary(center: attention.center, contexts: attention.contexts(), extraNeedYou: computers.model.attentionCount)
        }
        do { try statusBar.register(in: registry) } catch { log.publicError("duplicate status bar registration") }
        do { try computers.registerStop(in: registry) } catch { log.publicError("duplicate stop computer registration") }
    }

    /// Sessões da sidebar como o `GitHubController` as lê: pasta, branch do worktree e o último status Git.
    private static func makeGitHubSource(sidebar: SidebarModel) -> GitHubSource {
        func ref(_ s: Session) -> GitHubSessionRef {
            let branch = sidebar.worktree(of: s)?.branch
            let usable = s.kind == .worktree || s.kind == .checkout
            return GitHubSessionRef(
                id: s.id, title: s.title, folderPath: s.folderPath,
                branch: usable && !(branch ?? "").isEmpty && branch != "HEAD" ? branch : nil,
                status: usable ? sidebar.gitStatus[s.folderPath] : nil)
        }
        return GitHubSource(
            selected: { sidebar.selectedSession.flatMap { sidebar.session($0) }.map(ref) },
            sessions: { sidebar.snapshot.sessions.filter { $0.archivedAt == nil && $0.lifecycle != .archived }.map(ref) })
    }

    /// Liga o GitHub: ações `git.*`/`panel.*`, chips na sidebar, push detectado pelo status Git e o ciclo de consulta (só app
    /// de verdade: instância headless e telas de fixture nunca chamam o `gh`).
    private func wireGitHub(slice2: Bool, environment: [String: String]) {
        guard slice2 else { return }
        github.copyText = { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        github.isAppActive = { NSApp?.isActive ?? true }
        github.showModule = { [rightPanel] id in rightPanel.show(id) }
        github.onChips = { [sidebar] chips in sidebar.setPullRequests(chips) }
        github.openFile = { [weak self] url in _ = try await self?.openIn?.openFile(url, target: nil) }
        sidebar.onGitStatus = { [github] status, path in github.gitStatusChanged(status, at: path) }
        do { try github.register(in: registry) } catch { log.publicError("duplicate github registration") }
        if !headless, fixture == nil, environment["RACKY_GITHUB"] != "off" { github.startPolling() }
    }

    /// Fonte do módulo Files: sessão selecionada, pasta dela e terminal focado (nome curto do agente e último cwd conhecido).
    private static func makeFilesController(workspace: WorkspaceModel) -> FilesController {
        FilesController(
            source: FilesSource(
                sessionID: { workspace.currentSessionID },
                sessionRoot: { workspace.currentSessionID.flatMap { workspace.sessionLookup($0)?.folderPath } },
                focusedTerminal: {
                    guard let id = workspace.focusedTerminalID, let terminal = workspace.terminal(id) else { return nil }
                    let agent: String? =
                        switch terminal.provider {
                        case .claude: "Claude"
                        case .codex: "Codex"
                        case .opencode: "OpenCode"
                        case .shell, .custom: "Terminal"
                        }
                    return FilesFocusedTerminal(id: id, agent: agent, fallbackCwd: terminal.cwd)
                }))
    }

    /// Liga o painel direito: módulos, ações `rightPanel.*` e `files.*`, e o seguimento do cwd (OSC 7 e hooks).
    private func wireRightPanel() {
        rightPanel.toasts = toasts
        // Clique que falhou: toast de erro com o motivo (antes o botão não fazia nada e ninguém sabia por quê).
        registry.onUIFailure = { [toasts] id, message in
            toasts.show(kind: .error, title: String(localized: "\(id.spec.label) didn't work", bundle: .module), detail: message)
        }
        files.toasts = toasts
        files.externalOpen = { [openIn] url, target in
            guard let openIn else { throw ActionError.failed(.filesOpenInTarget, message: "Open in… isn't available.") }
            return try await openIn.openFile(url, target: target)
        }
        files.revealInFinder = { [openIn] url in openIn?.system.reveal(url) }
        RightPanelModules.registerAll(into: rightPanel, env: self)
        do { try rightPanel.register(in: registry) } catch { log.publicError("duplicate right panel registration") }
        do { try insights.register(in: registry) } catch { log.publicError("duplicate insights registration") }
        do { try files.register(in: registry, openIn: openIn, overlays: overlays, elements: elements) } catch {
            log.publicError("duplicate files registration")
        }
        workspace.addListener { [files] in files.recompute() }
        workspace.onCwd = { [files] terminal, path in files.noteCwd(path, terminal: terminal, source: .osc7) }
        workspace.runtime.cwdProvider = { [files, workspace] id in
            files.trackedCwd(for: id) ?? workspace.terminal(id)?.cwd ?? workspace.currentSessionID.flatMap { workspace.sessionLookup($0)?.folderPath }
        }
        workspace.runtime.onOpenFile = { [weak self] _, target, mode in self?.openTerminalFile(target, mode: mode) }
        files.recompute()
    }

    /// Caminho clicado na saída do terminal: ⌘ abre no visualizador do painel Files (pasta: mostra na árvore); ⇧⌘ no app padrão
    /// (pasta: Finder). O que o sistema executaria em vez de mostrar só é revelado no Finder.
    func openTerminalFile(_ target: TerminalFileTarget, mode: TerminalLinkOpenMode) {
        let url = URL(fileURLWithPath: target.path)
        switch mode {
        case .system:
            if TerminalLinkPolicy.opensSafelyWithDefaultApp(target.path, isDirectory: target.isDirectory) {
                NSWorkspace.shared.open(url)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        case .inApp:
            rightPanel.show(.files)
            if target.isDirectory {
                if !files.revealFolder(target.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } else {
                files.open(target.path, line: target.line)
            }
        }
    }

    /// Liga os datasets: ações `page.datasets` e `dataset.*`, o título da sessão, "algum computador dela roda?" (atualização a 1 s) e a evidência.
    private func wireDatasets() {
        datasets.currentPage = { [computers] in computers.page }
        datasets.showPage = { [computers, sidebar] page in
            sidebar.setInbox(open: false)
            computers.show(page)
        }
        datasets.hidePage = { [computers] in computers.closePage() }
        datasets.automationEnabled = automationEnabled
        datasets.sessionTitle = { [sidebar] id in sidebar.session(id)?.title }
        datasets.sessionAgent = { [sidebar] id in
            let tabs = Set(sidebar.snapshot.tabs.filter { $0.sessionID == id }.map(\.id))
            return sidebar.snapshot.terminals.first { tabs.contains($0.tabID) && $0.provider.isAgent && $0.launchSpec.workerChildID == nil }?.provider
        }
        datasets.workerTerminal = { [weak model = computers.model] computer in model?.workerComputers.first { $0.value == computer }?.key }
        datasets.isRunning = { [computers] session in
            computers.model.rows.contains { row in
                computers.model.sessionIDs[row.id] == session && [.inUse, .ready, .provisioning, .queued].contains(row.snapshot.state)
            }
        }
        datasets.openEvidence = { [registry] computer, request in
            _ = try await registry.perform(.computerOpenEvidence, .select("\(computer)|\(request)"))
        }
        // Dataset aberto vira tab (ou pane ao lado do agente) da sessão dele: seleciona a sessão, fecha a página do centro e abre.
        datasets.openInSession = { [workspace, sidebar, computers] datasetID, sessionID, beside in
            guard workspace.store != nil || workspace.isLoaded(session: sessionID) || sidebar.session(sessionID) != nil else { return false }
            if workspace.currentSessionID != sessionID {
                _ = sidebar.select(sessionID, closingInbox: true, requestingListFocus: false)
                workspace.setSession(sessionID)
            }
            guard workspace.currentSessionID == sessionID, workspace.isLoaded else { return false }
            if computers.page != .workspace { computers.closePage() }
            return workspace.openDataset(datasetID, beside: beside) != nil
        }
        datasets.closePane = { [workspace] paneID in workspace.closePane(id: paneID) }
        datasets.currentSession = { [workspace] in workspace.currentSessionID }
        // Os dados entram em cima e com mais espaço: a tabela precisa de altura, o outro módulo fica como resumo embaixo.
        datasets.showDataPanel = { [rightPanel, weak datasets] in
            // Já na área Data, a prévia não abre.
            if let page = datasets?.currentPage(), page == .datasets || page.datasetID != nil { return }
            rightPanel.show(.data)
            if rightPanel.layout.visible.count == 2 {
                if rightPanel.layout.visible.first != .data { rightPanel.swapVisible() }
                rightPanel.setTopFraction(0.64)
            }
        }
        datasets.hideDataPanel = { [rightPanel] in rightPanel.hide(.data) }
        datasets.computerLabel = { [weak model = computers.model] name in model?.computerAgentNames[name] }
        sidebar.sessionDatasets = { [datasets] sid in
            datasets.summaries.filter { $0.dataset.sessionID == sid }.map { SessionDatasetRow(id: $0.dataset.id, name: datasets.displayName($0), rows: $0.rowCount) }
        }
        // Tela do computador como tab da sessão: o título é o subagente ("Codex 1 · computer") e abrir leva para a sessão dona.
        workspace.computerTitle = { [weak model = computers.model] name in
            let agent = model?.computerAgentNames[name] ?? name
            return String(localized: "\(agent) · computer", bundle: .module)
        }
        computers.openInSession = { [weak sidebar, workspace] name, sid in
            if workspace.currentSessionID != sid { sidebar?.select(sid) }
            guard workspace.currentSessionID == sid else { return false }
            return workspace.openComputer(name) != nil
        }
        datasets.isShownInSession = { [workspace] id, sid in workspace.datasetPane(id, in: sid) != nil }
        workspace.datasetTitle = { [datasets] id in datasets.name(of: id) }
        workspace.renameDataset = { [datasets] id, name in Task { await datasets.rename(id, to: name) } }
        datasets.paneIsAlone = { [workspace] id in workspace.paneIsAlone(id) }
        datasets.detachDataset = { [workspace] id in
            guard let sid = workspace.currentSessionID, let (_, pane) = workspace.datasetPane(id, in: sid) else { return false }
            return workspace.detachPane(paneID: pane.id) == .applied
        }
        do { try datasets.register(in: registry) } catch { log.publicError("duplicate dataset action registration") }
        do { try dataHub.register(in: registry) } catch { log.publicError("duplicate data action registration") }
        do { try traffic.register(in: registry) } catch { log.publicError("duplicate traffic action registration") }
        traffic.currentSession = { [weak self] in self?.workspace.currentSessionID }
        traffic.openPane = { [weak self] name in
            guard let self, self.workspace.currentSessionID != nil else { return false }
            if self.computers.page != .workspace { self.computers.closePage() }
            return self.workspace.openTraffic(name) != nil
        }
        traffic.sessionRuns = { [weak self] in
            guard let self, let sid = self.workspace.currentSessionID, let title = self.sidebar.session(sid)?.title,
                  let root = self.computers.orchestrator?.runsRoot else { return [:] }
            let folder = root.appendingPathComponent(RunArchive.slug(title, fallback: ""), isDirectory: true)
            return Dictionary(RunArchive.runs(inSession: folder).map { ($0.root.lastPathComponent, $0.root) }, uniquingKeysWith: { a, _ in a })
        }
        // `Change` da saída na aba Computers: `Direct` + proxies salvos, o atual marcado.
        traffic.presentExitMenu = { [weak self] computer, current, names in
            guard let self else { return }
            let entries = (["direct"] + names).map { self.exitMenuEntry(computer: computer, proxy: $0, current: current) }
            let anchor = self.elements.frame(of: .rightPanelComputersChangeExit) ?? .zero
            _ = DSMenuPanel.present(router: self.overlays, registry: self.registry, name: "exitProxy", anchor: anchor, width: 240, entries: entries, alignment: .trailing)
        }
        traffic.start()
        dataHub.openNotebookInSession = { [weak self] id in
            guard let self, self.workspace.currentSessionID != nil else { return false }
            if self.datasets.currentPage() != .workspace { self.datasets.showPage(.workspace) }
            return self.workspace.openNotebook(id, beside: true) != nil
        }
    }

    /// Liga o controlador de computadores: ações `computer.*`, ⌘W fecha a página do viewer e a notificação de pedido de ajuda.
    private func wireComputers() {
        do { try computers.register(in: registry) } catch { log.publicError("duplicate computer action registration") }
        computers.overlays = overlays
        attention?.openBatch = { [weak self] id in
            NSApp.activate()
            self?.computers.openBatch(id)
        }
        do { try computers.registerResults(in: registry) } catch { log.publicError("duplicate result action registration") }
        do { try computers.registerLeftovers(in: registry) } catch { log.publicError("duplicate leftovers action registration") }
        computers.onLeftoversFreed = { [toasts] freed in
            let size = ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)
            toasts.show(kind: .success, title: String(localized: "Freed \(size).", bundle: .module))
        }
        wireDatasets()
        do { try computers.registerBatch(in: registry, automationEnabled: automationEnabled) } catch { log.publicError("duplicate batch action registration") }
        do { try subagentComputers.register(in: registry) } catch { log.publicError("duplicate subagent computers registration") }
        subagentHoverCards = SubagentHoverCardController(computers: computers, registry: registry, elements: elements)
        computers.hoverCards = subagentHoverCards
        // F29: menu `Direct` + proxies salvos no card de aprovação.
        computers.presentProxyMenu = { [weak self] request, names in
            guard let self else { return }
            let id = request.id
            let entries: [DSMenuEntry] = (["direct"] + names.sorted()).map { name in
                .item(DSMenuItem(
                    name, name == "direct" ? String(localized: "Direct", bundle: .module) : name, icon: .symbol("network"),
                    checked: request.proxy == name || (name == "direct" && request.proxy == "direct"),
                    action: .computerRequestProxy, argument: .select("\(id)|\(name)")))
            }
            let anchor = self.elements.frame(of: .paneApprovalProxy(id)) ?? .zero
            _ = DSMenuPanel.present(router: self.overlays, registry: self.registry, name: "approvalProxy", anchor: anchor, width: 220, entries: entries, alignment: .trailing)
        }
        // O que sai do disco quando o computador terminar (card de aprovação).
        computers.presentLeftoversMenu = { [weak self] request in
            guard let self else { return }
            let id = request.id
            let entries: [DSMenuEntry] = LeftoversPolicy.allCases.map { policy in
                .item(DSMenuItem(
                    policy.rawValue, policy.label, icon: .symbol(policy == .keep ? "folder" : "trash"), checked: request.leftovers == policy,
                    action: .computerRequestLeftovers, argument: .select("\(id)|\(policy.rawValue)")))
            }
            let anchor = self.elements.frame(of: .paneApprovalLeftovers(id)) ?? .zero
            _ = DSMenuPanel.present(router: self.overlays, registry: self.registry, name: "approvalLeftovers", anchor: anchor, width: 220, entries: entries, alignment: .trailing)
        }
        computers.model.sessionTitle = { [computers, sidebar] name in computers.model.sessionIDs[name].flatMap { sidebar.session($0)?.title } }
        wireNavigation()
        workspace.pageCloser = { [computers] in
            guard computers.page != .workspace else { return false }
            computers.closePage()
            return true
        }
        computers.onControlReturned = { [toasts] computer, agent in
            toasts.show(kind: .info, title: String(localized: "Control returned to \(agent)", bundle: .module), detail: computer)
        }
        if !automationEnabled && !headless {
            let system = SystemHelpNotifier(open: { [computers, registry] name, takeOver in
                NSApp.activate()
                computers.openViewer(name)
                if takeOver { Task { _ = try? await registry.perform(.computerTakeOver, .select(name)) } }
            })
            system?.decide = { [computers] id, decision in computers.model.decide(id, decision) }
            computers.notifier = system ?? NoopHelpNotifier()
        }
    }

    /// `RACKY_SCREEN=setup-demo`: onboarding e Settings com CLIs de mentira (Claude logado, Codex deslogado, OpenCode ausente),
    /// para a evidência visual não depender do que está instalado no Mac.
    public static let setupDemoFixture = "setup-demo"
    private let autoOnboarding: Bool

    private static func makeProbe(fixture: String?) -> AgentProbe {
        if fixture == setupDemoFixture {
            return { provider, _ in
                switch provider {
                case .claude: CLIProbeResult(provider: .claude, executable: "/Users/demo/.local/bin/claude", version: CLIVersion(2, 1, 302), login: .loggedIn)
                case .codex: CLIProbeResult(provider: .codex, executable: "/opt/homebrew/bin/codex", version: CLIVersion(0, 160, 0), login: .loggedOut)
                default: CLIProbeResult(provider: provider, executable: nil, login: .unknown("not installed"))
                }
            }
        }
        let loginEnv = LoginShellEnvProvider()
        let prober = CLIProber(environment: { await loginEnv.environment().captured.variables })
        return { provider, force in await prober.probe(ProviderAdapters.adapter(for: provider), checkLogin: true, force: force) }
    }

    /// Sondas da checklist (gh, Docker, imagem, conflitos). Testes headless, `RACKY_DIAGNOSTICS=fake` e a tela `setup-demo`
    /// usam respostas de mentira: nada de `gh`, Docker nem configs do Mac na evidência nem nos testes.
    private static func usesFakeDiagnostics(_ environment: [String: String]) -> Bool {
        environment["RACKY_SCREEN"] == setupDemoFixture || environment["RACKY_TEST_HEADLESS"] == "1"
            || environment["RACKY_DIAGNOSTICS"] == "fake"
    }

    private static func makeDiagnosticsProbes(
        environment: [String: String], backup: GlobalSkillBackup, choice: ConflictChoiceBox, supportRoot: URL,
        forceDocker: @escaping @Sendable () async -> Bool
    ) -> DiagnosticsProbes {
        guard usesFakeDiagnostics(environment) else {
            var probes = LiveDiagnosticsProbes.make(backup: backup, choice: { choice.value })
            probes.runtime = { ComputerRuntimeProbe.mode(environment: environment, supportRoot: supportRoot, forceDocker: await forceDocker()) }
            return probes
        }
        return DiagnosticsProbes(
            gh: { GitHubProbeResult(installed: true, version: "2.60.1", auth: GitHubAuthStatus(state: .notLoggedIn, host: "github.com")) },
            docker: { .installedNotRunning(kind: .desktop) },
            image: { _ in .missing },
            conflicts: {
                ConflictScan(
                    findings: [
                        ConflictFinding(
                            kind: .globalSkill, provider: .claude, path: "~/.claude/skills/\(GlobalConfigScanner.competingName)",
                            message: "A global \"\(GlobalConfigScanner.competingName)\" skill is installed and may compete with Racky tools."),
                        ConflictFinding(
                            kind: .notify, provider: .codex, path: "~/.codex/config.toml",
                            message: "Codex notify is used by another app (left untouched)."),
                    ], choice: choice.value)
            })
    }

    /// Liga Settings e onboarding ao registro de ações, aos overlays e aos toasts.
    private func wireSettings() {
        settings.toasts = toasts
        do {
            try settings.registerActions(in: registry)
            try onboarding.registerActions(in: registry)
        } catch {
            log.publicError("duplicate settings action registration")
        }
        onboarding.present = { [overlays, onboarding] in overlays.present(onboarding.overlaySpec(), from: nil) }
        onboarding.dismiss = { [overlays] in
            if overlays.top?.spec.name == "onboarding" { overlays.dismiss(.action) }
        }
        let previous = settings.onPresentationChange
        settings.onPresentationChange = { [onboarding] open in
            previous(open)
            // Abrir o Settings (Review Profiles, ⌘,) tira o onboarding da frente sem registrá-lo como concluído.
            if open { onboarding.hide() }
        }
    }

    /// Diagnostics (T4-04): estado do daemon, versão e modos do app, e as ações `app.checkProblems`, `help.exportDiagnostics` etc.
    /// No fixture do overlay (`overlay-demo`) o `app.checkProblems` de exemplo continua sendo o dele.
    private func wireDiagnostics() {
        let flags = flags, automation = automationEnabled, headless = headless, fixture = fixture
        diagnostics.daemonProbe = { [workspace] in await workspace.runtime.diagnosticsStatus() }
        diagnostics.appInfo = {
            let info = Bundle.main.infoDictionary
            let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
            let build = info?["CFBundleVersion"] as? String ?? "dev"
            var modes = [flags.restricted ? "slice \(flags.current.rawValue)" : "all slices"]
            if automation { modes.append("automation on") }
            if headless { modes.append("headless") }
            if fixture != nil { modes.append("fixture") }
            modes.append(Bundle.main.bundleURL.pathExtension == "app" ? "app bundle" : "development build")
            return [("Racky version", version), ("Build", build), ("Modes", modes.joined(separator: ", ")), ("macOS", ProcessInfo.processInfo.operatingSystemVersionString)]
        }
        if fixture == Self.overlayDemoFixture { return }
        do { try diagnostics.registerActions(in: registry) } catch { log.publicError("duplicate diagnostics registration") }
    }

    /// Fixture de dev e evidência (`RACKY_SCREEN=workspace-demo`): uma sessão limpa com uma tab de shell, selecionada.
    /// Os splits vêm de `ctl ui action pane.splitRight` etc.
    static let workspaceDemoFixture = "workspace-demo"

    private func seedWorkspaceDemo(into store: RackyStore) async throws {
        guard try await store.sessions().isEmpty else { return }
        let folder = StorePaths.default(environment: environmentVariables).root
        var session = Session(kind: .clean, folderPath: folder.path, title: "demo-session")
        session.managedFolder = true
        try await store.save(session)
        let tabID = UUID.v7(), termID = UUID.v7()
        let terminal = Terminal(id: termID, tabID: tabID, provider: .shell, title: "demo-session", cwd: folder.path, launchSpec: LaunchSpec(provider: .shell))
        let tab = Tab(id: tabID, sessionID: session.id, title: "demo-session", layout: .leaf(Pane(content: .terminal(termID))), focusedTerminalID: termID)
        try await store.save(tab)
        try await store.save(terminal)
        try await store.setUIState(SidebarModel.uiStateKey, SidebarPersistedState(selectedSession: session.id))
    }

    /// Liga o workspace (tabs e panes) à sidebar, aos overlays e ao registro de ações (T1-14). No fixture do overlay
    /// (`overlay-demo`) as ações de fechar do demo continuam suas.
    private func wireWorkspace() {
        workspace.overlays = overlays
        workspace.autoFocusAllowed = { [overlays, settings, computers] in
            !overlays.blocksTerminalInput && !settings.isOpen && computers.page == .workspace
        }
        workspace.toasts = toasts
        workspace.sessionLookup = { [sidebar] id in sidebar.session(id) }
        sidebar.onSelectionChange = { [workspace] id in workspace.setSession(id) }
        sidebar.onSnapshot = { [workspace, lifecycle] snapshot in
            workspace.ingest(snapshot)
            lifecycle?.update(terminals: snapshot.terminals)
        }
        workspace.runtime.onPaneContext = { [workspace, registry] id, point in workspace.presentPaneContextMenu(registry: registry, terminalID: id, at: point) }
        let demo = fixture == Self.overlayDemoFixture
        do {
            try workspace.registerActions(
                in: registry, elements: elements, includeCloseDialog: !demo, excluding: demo ? [.paneClose] : [])
        } catch {
            log.publicError("duplicate workspace action registration")
        }
        sidebar.cancelLaunchFallback = { [workspace] id in
            guard workspace.terminal(id) != nil else { return false }
            workspace.cancelLaunch(id)
            return true
        }
        // Agente padrão e instalação detectada vêm do Settings; ⌥⌘T e o Quick Launch usam os mesmos.
        workspace.defaultAgent = { [settings] in settings.settings.agents.defaultAgent }
        workspace.agentInstalled = { [settings] in settings.agent($0)?.installedState }
        let isolatedHome = environmentVariables["RACKY_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        let sessionsRoot: () -> URL = { [settings] in
            CleanSessionPaths.sessionsRoot(configured: settings.settings.general.cleanSessionFolder, isolatedHome: isolatedHome)
        }
        let sessionLauncher = SessionLauncher(sidebar: sidebar, workspace: workspace, elements: elements, sessionsRoot: sessionsRoot)
        launcher = sessionLauncher
        sessionLauncher.settings = settings
        do { try sessionLauncher.register(in: registry) } catch { log.publicError("duplicate session.launch registration") }
        let clean = CleanSessionController(
            launcher: sessionLauncher, sidebar: sidebar, workspace: workspace, overlays: overlays, toasts: toasts, elements: elements,
            settings: settings, projects: projects, sessionsRoot: sessionsRoot,
            runsRoot: { CleanSessionPaths.runsRoot(isolatedHome: isolatedHome) }, automationEnabled: automationEnabled)
        cleanSessions = clean
        let dataRoot = StorePaths.default(environment: environmentVariables).root
        settings.storage = StorageHooks(
            runsRoot: dataRoot.appendingPathComponent("computers/runs", isDirectory: true),
            runtimeRoot: dataRoot.appendingPathComponent("vz", isDirectory: true),
            activeRuns: { [computers] in
                guard let orchestrator = await MainActor.run(body: { computers.orchestrator }) else { return [] }
                return await orchestrator.scheduler.activeRunRoots()
            },
            didClean: { [computers] in Task { await computers.refreshLeftovers() } },
            removeArchivedWorktrees: { [weak clean] in await clean?.removeArchivedWorktrees() ?? 0 })
        do { try clean.register(in: registry) } catch { log.publicError("duplicate clean session registration") }
        let open = OpenInController(sidebar: sidebar, overlays: overlays, toasts: toasts, elements: elements)
        openIn = open
        do { try open.register(in: registry) } catch { log.publicError("duplicate open-in registration") }
        let quick = QuickLaunchController(workspace: workspace, overlays: overlays, elements: elements, settings: settings)
        quickLaunch = quick
        quick.sessionDatasets = { [datasets, workspace] in
            guard let sid = workspace.currentSessionID else { return [] }
            return datasets.summaries.filter { $0.dataset.sessionID == sid }.map { ($0.dataset.id, datasets.displayName($0)) }
        }
        do { try quick.register(in: registry) } catch { log.publicError("duplicate quick launch registration") }
        let composerController = ComposerController(
            sidebar: sidebar, settings: settings, overlays: overlays, toasts: toasts, elements: elements, launcher: sessionLauncher,
            automationEnabled: automationEnabled)
        composer = composerController
        composerController.dataDestinations = { [dataHub] in dataHub?.composerDestinations() ?? [] }
        // Um só seletor de pasta: o do composer (fake nos testes) também atende "New Clean Session in Folder…".
        clean.picker = CleanFolderPicker(base: { [weak composerController] in composerController?.picker ?? OpenPanelSessionFolderPicker() })
        do { try composerController.register(in: registry) } catch { log.publicError("duplicate composer registration") }
        let cloneController = CloneRepoController(
            sidebar: sidebar, overlays: overlays, toasts: toasts, projects: projects,
            projectsRoot: { [settings] in
                CleanSessionPaths.projectsRoot(configured: settings.settings.general.projectsFolder, isolatedHome: isolatedHome)
            })
        cloneController.onCloned = { [weak composerController] project in composerController?.projectCloned(project) }
        cloneController.canOpenLoginTerminal = { [workspace] in workspace.isLoaded }
        cloneController.openLoginTerminal = { [workspace] argv in workspace.newTab(provider: .custom, customArgv: argv) != nil }
        cloneRepo = cloneController
        do { try cloneController.register(in: registry) } catch { log.publicError("duplicate clone registration") }
        let newBatchController = NewBatchController(
            sidebar: sidebar, workspace: workspace, settings: settings, overlays: overlays, computers: computers, launcher: sessionLauncher,
            automationEnabled: automationEnabled)
        newBatch = newBatchController
        do { try newBatchController.register(in: registry) } catch { log.publicError("duplicate new batch registration") }
        let resume = ResumeAgentsController(
            workspace: workspace, sessionTitle: { [sidebar] in sidebar.session($0)?.title }, selectedSession: { [sidebar] in sidebar.selectedSession },
            overlays: overlays, toasts: toasts)
        resumeAgents = resume
        do { try resume.register(in: registry) } catch { log.publicError("duplicate resume agents registration") }
        let conversationsController = ConversationsController(
            workspace: workspace, sidebar: sidebar, overlays: overlays, toasts: toasts, elements: elements, rightPanel: rightPanel)
        conversations = conversationsController
        do { try conversationsController.register(in: registry) } catch { log.publicError("duplicate conversations registration") }
    }

    /// Ações reais da casca vazia; as demais entram com a tela que as possui.
    private func registerShellActions() {
        do {
            try registry.register(.appHideAppName) { [shell] _ in
                shell.appNameHidden.toggle()
                return shell.appNameHidden ? "hidden" : "shown"
            }
            try registry.register(
                .navBack,
                enablement: { [shell] in shell.canGoBack ? .enabled : .disabled(reason: "No earlier page") },
                handler: { [unowned self] _ in navigate(-1) ? "back" : nil })
            try registry.register(
                .navForward,
                enablement: { [shell] in shell.canGoForward ? .enabled : .disabled(reason: "No later page") },
                handler: { [unowned self] _ in navigate(1) ? "forward" : nil })
            try registry.register(.appQuit) { _ in
                AppLifecycleCoordinator.requestTermination()
                return nil
            }
            try registry.register(.appQuitCompletely) { [unowned self] _ in
                lifecycle.quitCompletely()
                return nil
            }
            try registry.register(.appOpenMainWindow) { [unowned self] _ in
                lifecycle.leaveBackground()
                return nil
            }
            try registry.register(
                .appStopAllAgents,
                enablement: { [weak self] in (self?.lifecycle.cachedCounts.agents ?? 0) > 0 ? .enabled : .disabled(reason: "No agents are running.") }
            ) { [unowned self] _ in
                guard await lifecycle.requestStopAll() else { throw ActionError.failed(.appStopAllAgents, message: "No agents are running.") }
                return nil
            }
            try registry.register(.dialogQuitKeepRunning) { [unowned self] _ in
                lifecycle.choose(.keepRunning(dontAskAgain: lifecycle.dontAskChecked))
                return nil
            }
            try registry.register(.dialogQuitStopAll) { [unowned self] _ in
                lifecycle.choose(.stopAll)
                return nil
            }
            try registry.register(.dialogQuitStopAllConfirm) { [unowned self] _ in
                lifecycle.confirmStopAll()
                return nil
            }
            try registry.register(.dialogQuitCancel) { [unowned self] _ in
                lifecycle.choose(.cancel)
                return nil
            }
            try registry.register(.dialogQuitDontAsk) { [unowned self] arg in
                lifecycle.setDontAsk(arg.value.map { $0 == "on" } ?? !lifecycle.dontAskChecked)
                return lifecycle.dontAskChecked ? "on" : "off"
            }
        } catch {
            log.publicError("duplicate action registration")
        }
    }

    /// LaunchAgent do daemon (T1-24). Só dentro do `.app` com o plist embutido, e nunca em fixtures, automação ou com
    /// `RACKY_HOME` próprio (testes usam o daemon filho), salvo `RACKY_LAUNCHD=1` (label de teste, 08 §0.1).
    /// `/tmp`, `/private/tmp`, `/var/folders` (o `TMPDIR` do usuário): builds descartáveis.
    static func isTemporaryBundle(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
        return ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/"].contains { path.hasPrefix($0) } || path.hasPrefix(temp)
    }

    /// Bundle instalado de verdade: direto em `/Applications` ou `~/Applications` (não em subpastas de projetos).
    static func isInstalledBundle(_ url: URL, home: String = NSHomeDirectory()) -> Bool {
        let parent = url.resolvingSymlinksInPath().deletingLastPathComponent().path
        return parent == "/Applications" || parent == "/System/Volumes/Data/Applications" || parent == (home as NSString).appendingPathComponent("Applications")
    }

    static func makeBackgroundAgent(environment: [String: String], storeRoot: URL) -> BackgroundAgentHost? {
        let explicit = environment["RACKY_LAUNCHD"] == "1"
        if environment["RACKY_LAUNCHD"] == "0" { return nil }
        if !explicit, environment["RACKY_HOME"] != nil || environment["RACKY_AUTOMATION"] == "1" || environment["RACKY_SCREEN"] != nil
            || environment["RACKY_DAEMON"] != nil
        {
            return nil
        }
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else { return nil }
        // F33: só a cópia instalada (`/Applications` ou `~/Applications`) vira o daemon oficial do launchd do dono; build de
        // worktree, DerivedData, `build/` ou pasta temporária usa o daemon filho.
        guard explicit || (Self.isInstalledBundle(bundleURL) && !Self.isTemporaryBundle(bundleURL)) else { return nil }
        let identity = BackgroundAgentIdentity.resolve(environment: environment)
        return BackgroundAgentHost(
            identity: identity, service: SMBackgroundAgentService(plistName: identity.plistName), bundleURL: bundleURL,
            daemonExecutable: ChildDaemon.launcherExecutable(),
            stateFile: storeRoot.appendingPathComponent("run/ptyd-registration.json"),
            pointer: ChildDaemon.defaultExecutable().map {
                .init(
                    home: storeRoot, daemonBinary: $0,
                    build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0")
            })
    }

    /// ⌘Q, accessory, barra de menus e o aviso de aprovação do LaunchAgent.
    private func wireLifecycle() {
        lifecycle.dependencies = AppLifecycleCoordinator.Dependencies(
            countLive: { [weak self] in await self?.liveCounts() ?? LiveProcessCounts() },
            preferences: { [weak self] in
                let general = self?.settings.settings.general
                return QuitPreferences(keepAgentsRunning: general?.keepAgentsRunning ?? true, askBeforeQuit: general?.askBeforeQuit ?? true)
            },
            disableAsking: { [weak self] in self?.settings.disableAskBeforeQuit() },
            promptShownBefore: { [weak self] in await self?.quitPromptShown() ?? false },
            markPromptShown: { [weak self] in self?.recordQuitPromptShown() },
            stopAll: { [weak self] in await self?.stopAllProcesses() },
            markCleanExit: { [weak self] in await self?.markCleanExit() })
        settings.openLoginItems = { [workspace] in workspace.runtime.openLoginItemsSettings() }
        workspace.runtime.onHostModeChange = { [settings] mode in
            settings.backgroundNeedsApproval = mode.fallbackReason == .requiresApproval
        }
    }

    private static let quitPromptKey = "quit.promptShown"

    /// Terminais com processo vivo segundo o banco (também sessões que não estão na tela).
    func liveCounts() async -> LiveProcessCounts {
        guard let store else { return lifecycle.cachedCounts }
        let running = (try? await store.terminals(in: .running)) ?? []
        let launching = (try? await store.terminals(in: .launching)) ?? []
        return LiveProcessCounts(counting: running + launching)
    }

    private func quitPromptShown() async -> Bool {
        guard let store else { return false }
        return (try? await store.uiState(Self.quitPromptKey, as: Bool.self)) ?? false
    }

    private func recordQuitPromptShown() {
        guard let store else { return }
        Task { try? await store.setUIState(Self.quitPromptKey, true) }
    }

    /// `Stop All and Quit`: `kill graceful` em todos, espera até 5 s e só então força o que sobrou (o usuário já confirmou duas vezes).
    func stopAllProcesses() async {
        if let store {
            let live = ((try? await store.terminals(in: .running)) ?? []) + ((try? await store.terminals(in: .launching)) ?? [])
            await SessionReconciler.recordExplicitStop(store: store, terminalIDs: live.map(\.id))
        }
        let client = workspace.runtime.client
        func running() async -> [SessionSummary] { ((try? await client.list()) ?? []).filter { $0.state == .running } }
        for summary in await running() { try? await client.kill(sessionID: summary.sessionID, mode: .graceful) }
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline, !(await running()).isEmpty { try? await Task.sleep(for: .milliseconds(150)) }
        for summary in await running() { try? await client.kill(sessionID: summary.sessionID, mode: .force) }
    }

    /// Fixture de desenvolvimento (`RACKY_SCREEN=overlay-demo`): liga ações que abrem overlays e toasts de exemplo (o composer é o real).
    public static let overlayDemoFixture = "overlay-demo"

    /// Liga o roteador de overlays ao registro (Esc dispara o Cancel) e à árvore de UI (origem da animação).
    private func wireOverlays() {
        overlays.performAction = { [registry] id in
            guard registry.availability(of: id).isEnabled else { return false }
            Task { _ = try? await registry.perform(id, .press) }
            return true
        }
        overlays.frameOf = { [elements] id in elements.frame(of: id) }
    }

    /// Ações de exemplo do overlay (só no fixture): `session.new` abre a amostra do composer a partir do botão da sidebar,
    /// `pane.close` abre "Close this terminal?" e `app.checkProblems` mostra toasts. Os handlers de `composer.*`
    /// e `dialog.closeTerminal.*` gravam nos modelos da amostra.
    private func registerOverlayDemo() {
        let confirmation = ConfirmationModel.closeTerminal(
            message: String(localized: "Claude Code is still working. Closing ends the process; you can resume the conversation later.", bundle: .module))
        let router = overlays, toasts = toasts
        func add(_ id: ActionID, _ handler: @escaping @MainActor (ActionArgument) async throws -> String?) {
            try? registry.register(id, handler: handler)
        }
        add(.paneClose) { _ in
            router.present(.confirmation(confirmation), from: nil) ? "opened" : "stack full"
        }
        add(.dialogCloseTerminalCancel) { _ in
            router.dismiss(.action)
            return nil
        }
        add(.dialogCloseTerminalConfirm) { _ in
            router.dismiss(.action)
            return nil
        }
        add(.dialogCloseTerminalDontAsk) { arg in
            confirmation.state.dontAsk = arg.value == "on"
            return nil
        }
        add(.appCheckProblems) { _ in
            toasts.show(kind: .error, title: String(localized: "Couldn't save setting.", bundle: .module),
                        detail: String(localized: "The file is read-only.", bundle: .module), duration: 6)
            toasts.show(kind: .success, title: String(localized: "Session archived.", bundle: .module),
                        action: ToastAction(.appCheckProblems, title: String(localized: "Undo", bundle: .module)), undo: true)
            return nil
        }
        if let script = scriptSteps { runDemoScript(script) }
    }

    /// Fixture `RACKY_SCREEN=sidebar-demo`: controles cujo fluxo é de outra tarefa (composer, adicionar projeto, Settings,
    /// páginas) ganham handlers de exemplo para a evidência visual mostrar a sidebar completa. Nada disso roda em uso normal.
    private func registerSidebarDemo() {
        for id in [ActionID.appSettings, .projectNewSession, .pageInbox, .pageComputers, .pageDatasets, .pageLibrary] where attention == nil || id != .pageInbox {
            try? registry.register(id) { _ in "demo" }
        }
    }

    /// Abre o Store (em `RACKY_HOME` se definido) e liga a sidebar a ele (T1-05). Sem Store a sidebar fica vazia, nunca trava a UI.
    private func startStore() async {
        guard store == nil else { return }
        do {
            let opened = try await RackyStore.open(paths: .default(environment: environmentVariables))
            store = opened
            await diagnostics.attach(store: opened)
            subagentComputers.attach(store: opened)
            await startOrchestrator(store: opened)
            if fixture == Self.workspaceDemoFixture { try await seedWorkspaceDemo(into: opened) }
            if fixture == SidebarFixtures.screenID {
                let cast = SidebarFixtures.full()
                try await SidebarFixtures.seed(cast, into: opened)
                if try await opened.uiState(SidebarModel.uiStateKey, as: SidebarPersistedState.self) == nil {
                    try await opened.setUIState(SidebarModel.uiStateKey, SidebarPersistedState(selectedSession: cast.selectedSessionID))
                }
                if sidebar.pending.isEmpty, let pid = cast.pendingProjectID {
                    sidebar.beginPending(PendingLaunch(name: String(localized: "Add retry logic", bundle: .module), projectID: pid, phase: .fetching))
                }
            }
            await rightPanel.attach(store: opened)
            await library.attach(store: opened)
            await datasets.attach(store: opened)
            await dataHub?.attach(store: opened)
            await startCatalog(store: opened)
            await statusBar.attach(store: opened)
            await insights.service?.attach(
                agents: StoreAgentSource(store: opened), proxies: StoreProxySource(store: opened),
                computers: Self.computerSource(environment: environmentVariables))
            if !headless, fixture == nil { statusBar.start() }
            await files.attach(store: opened)
            launcher?.attach(store: opened)
            cleanSessions?.attach(store: opened)
            openIn?.attach(store: opened)
            await restoreSessions(store: opened)
            await composer?.attach(store: opened)
            // A evidência de atenção semeia depois do restore: os terminais "running" de mentira não viram `interrupted`.
            if fixture == AttentionFixtures.screenID, attention != nil {
                try await AttentionFixtures.seed(into: opened, home: NSHomeDirectory())
            }
            await workspace.attach(store: opened)
            await sidebar.attach(store: opened)
            await settings.attach(store: opened)
            workspace.autoResumeEnabled = { [weak self] in self?.settings.settings.general.resumeAgentsOnOpen ?? true }
            Task { await resumeAfterRestore() }
            await startActivity(store: opened)
            if autoOnboarding { await onboarding.attach(store: opened, forceVisible: fixture == Self.setupDemoFixture) }
            projects.attach(store: opened)
        } catch {
            log.error("store failed to open: \(error)")
        }
    }

    /// P25: com "Resume agents automatically when Racky opens" ligado (padrão), relança em silêncio os agentes que morreram
    /// com o app fechado ou no reinício do Mac, e avisa com um toast. Desligado: o banner da sessão oferece "Resume All".
    private func resumeAfterRestore() async {
        guard let report = restoreReport else { return }
        restoreReport = nil
        guard settings.settings.general.resumeAgentsOnOpen else { return }
        let count = await workspace.autoResume(report: report)
        if count > 0 {
            toasts.show(
                kind: .info, title: count == 1 ? String(localized: "Resumed 1 agent", bundle: .module) : String(localized: "Resumed \(count) agents", bundle: .module))
        }
    }

    /// Reabertura (T1-23): ver `WorkspaceModel.restoreSessions`. Avisa uma vez quantos terminais voltaram vivos.
    private func restoreSessions(store: RackyStore) async {
        guard let report = await workspace.restoreSessions(store: store) else { return }
        restoreReport = report
        log.info("restore: \(report.alive.count) alive, \(report.exited.count) exited, \(report.interrupted.count) interrupted")
        if !report.alive.isEmpty {
            toasts.show(kind: .info, title: String(localized: "Reconnected to \(report.alive.count) running terminals.", bundle: .module))
        }
    }

    /// `RACKY_DEMO_SCRIPT=composer;agent;...` (só no fixture, para evidência e testes): abre o composer e comboboxes/menus
    /// em sequência, sem cliques. Passos: `composer`, `project`, `agent`, `profile`, `appmenu`.
    var scriptSteps: [String]? {
        guard let raw = ProcessInfo.processInfo.environment["RACKY_DEMO_SCRIPT"], !raw.isEmpty else { return nil }
        return raw.split(separator: ";").map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    private func runDemoScript(_ steps: [String]) {
        let router = overlays, registry = registry, elements = elements
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            for step in steps {
                switch step {
                case "composer":
                    _ = try? await registry.perform(.sessionNew, .press)
                case "project", "agent", "profile":
                    guard let model = self?.composer?.model else { break }
                    let (id, selection, entries, action, hint): (A11yID, String, [DSMenuEntry], ActionID, String) =
                        switch step {
                        case "project": (.overlayComposerProject, model.draft.projectID?.uuidString ?? "none", model.projectEntries, .composerSetProject, "Search projects…")
                        case "agent": (.overlayComposerAgent, model.draft.provider.rawValue, model.agentEntries, .composerSetAgent, "Search agents…")
                        default: (.overlayComposerProfile, model.draft.profileID?.uuidString ?? "", model.profileEntries, .composerSetProfile, "Search profiles…")
                        }
                    if let anchor = elements.frame(of: id) {
                        router.presentPopover(
                            DSCombobox.popoverSpec(
                                id: id, selection: selection, entries: entries, action: action, searchPlaceholder: hint, anchor: anchor,
                                registry: registry))
                    }
                case "appmenu":
                    if let anchor = elements.frame(of: .windowAppName) {
                        DSMenuPanel.present(router: router, registry: registry, name: "appMenu", anchor: anchor, entries: AppMenuEntries.entries)
                    }
                default: break
                }
                try? await Task.sleep(for: .seconds(0.8))
            }
        }
    }


    /// Sobe o servidor `ctl` se a automação estiver ligada. Chamado uma vez, no primeiro `.task` da janela.
    /// O app real vai restaurar as sessões (o `AppDelegate` marca antes de criar a janela): a tela inicial espera, senão
    /// ela pisca por meio segundo antes de a sessão selecionada voltar.
    @ObservationIgnored public var restorePending = false
    @ObservationIgnored var onRestored: () -> Void = {}
    /// O AppDelegate pegou o lock da instância: vale esperar a anterior soltar `app.sock`. Ambientes de teste (sem o lock) desistem na
    /// hora, como antes, em vez de esperar 30 s pelo app do dono.
    @ObservationIgnored public var ownsInstanceLock = false

    /// O app já tem o lock da instância (AppDelegate), então quem ainda escuta em `app.sock` é a instância anterior saindo (relançar
    /// logo após o quit/SIGTERM). Espera ela soltar o socket em vez de ficar sem hub: sem ele os agentes perdem os computadores
    /// ("Racky is not running"), F41.
    static func startRetryingWhileAnotherInstanceExits(
        socketPath: String, start: () async throws -> Void, log: LogFacade, timeout: Duration = .seconds(30), interval: Duration = .milliseconds(250)
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while true {
            do {
                try await start()
                return true
            } catch AppSockError.alreadyRunning where ContinuousClock.now < deadline {
                try? await Task.sleep(for: interval)
            } catch {
                log.error("app.sock hub failed to start: \(error)")
                return false
            }
        }
    }

    public func start() async {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1.0 (dev)"
        // Log em disco, sentinela de crash e (só no produto) MetricKit; depois do lock da instância (AppDelegate).
        diagnostics.start(build: build, systemHooks: Bundle.main.bundleURL.pathExtension == "app" && !headless && !automationEnabled && fixture == nil)
        await startStore()
        restorePending = false
        onRestored()
        computers.startRefreshing()
        datasets.startRefreshing()
        computers.startDemo(environment: environmentVariables)
        // Fatia 2: `app.sock` é de um hub só (ctl + hook); os hooks chegam mesmo com a automação desligada.
        if let activity, hub == nil {
            let enabled = automationEnabled
            var providers: [any AppSockServiceProvider] = [
                CtlServiceProvider(dispatcher: registry, isEnabled: { enabled }), HookServiceProvider(activity: activity),
            ]
            if let orchestrator = orchestratorHolder.value { providers.append(orchestrator.mcpProvider) }
            let server = AppSockHub(socketPath: socketPath, providers: providers)
            if await Self.startRetryingWhileAnotherInstanceExits(
                socketPath: socketPath, start: { try await server.start() }, log: log, timeout: ownsInstanceLock ? .seconds(30) : .zero) {
                hub = server
            }
            return
        }
        guard automationEnabled, ctl == nil, hub == nil else { return }
        let server = CtlServer(socketPath: socketPath, dispatcher: registry)
        do {
            try await server.start()
            ctl = server
        } catch {
            log.error("ctl failed to start: \(error)")
        }
    }

    /// Encerra o daemon filho se esta execução o possui (automação, testes, `RACKY_STOP_DAEMON_ON_QUIT=1`).
    public func shutdownSync() {
        workspace.runtime.shutdown()
    }

    /// Saída limpa (T1-23): a próxima abertura distingue "parou com o app fechado" de "parou sem aviso".
    public func markCleanExit() async {
        // As VMs do runtime sem Docker morrem com este processo de qualquer jeito: para-as antes, para as pastas não sobrarem.
        await orchestratorHolder.value?.provisioning.shutdownNative()
        // VMs na nuvem: encerradas agora (não ficam cobrando até a chave morta agir).
        await settings.cloudShutdown?()
        await diagnostics.stop()
        if let store { await SessionReconciler.markCleanExit(store: store) }
    }

    public func stop() async {
        sidebar.detach()
        projects.detach()
        computers.stopRefreshing()
        datasets.stopRefreshing()
        await computers.tearDownDemo()
        computerSweeper?.cancel()
        catalogWatch?.cancel()
        statusBar.stop()
        dataHub?.notebooks.stop()
        await ctl?.stop()
        ctl = nil
        await hub?.stop()
        hub = nil
        attention?.stop()
        await activity?.stop()
        activity = nil
    }
}

extension AppEnvironment {
    /// Uma linha do menu de saída: `Direct` ou o proxy salvo (o nome do provedor quando o host o revela, o host ao lado).
    func exitMenuEntry(computer: String, proxy: String, current: String) -> DSMenuEntry {
        let direct = proxy == "direct"
        let host = traffic.proxies[proxy]?.host ?? ""
        let title = direct ? String(localized: "Direct", bundle: .module) : DSProxyBrand.detect(proxy, host)?.title ?? proxy
        return .item(DSMenuItem(
            proxy, title, icon: .symbol("network"), detail: direct ? nil : host, checked: proxy == current,
            action: .computerSetProxy, argument: .select("\(computer)|\(proxy)")))
    }
}
