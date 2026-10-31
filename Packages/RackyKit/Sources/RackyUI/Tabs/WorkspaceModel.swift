import RackyCore
import RackyDesignSystem
import RackyPlatform
import RackyProtocol
import RackyStore
import AppKit
import Foundation
import Observation

/// Parte do workspace que sobrevive ao reinício (`ui_state`): a tab ativa de cada sessão (06 §1.8).
nonisolated struct WorkspaceUIState: Codable, Equatable, Sendable {
    var activeTabs: [String: String] = [:]
}

/// Estado de execução de um pane na UI (03 §4.6). O estado persistido do processo é `Terminal.state`; este acrescenta
/// o que só existe enquanto o app roda (fechando, erro de lançamento).
enum PaneRunState: Equatable {
    /// Ainda sem sessão no daemon (a view é criada antes do lançamento).
    case starting
    case running
    case exited(code: Int?, signal: Int?)
    case interrupted
    case failed(String)
    /// Fechando: `kill graceful` enviado; `stuck` depois de 5 s sem sair (banner "The process didn't exit.").
    case closing(stuck: Bool)
}

/// Pedido de confirmação de fechamento em andamento (03 §16.1).
struct PendingClose {
    var terminalIDs: [UUID]
    var perform: @MainActor () -> Void
}

/// Modelo da tab row e da árvore de panes da sessão selecionada (T1-14). Mantém o conjunto de trabalho em memória
/// (tabs, terminais, tab ativa, expansão) e grava no Store: estrutura na hora, proporções com debounce de 300 ms
/// (`scheduleLayout`) e no fim do gesto (`setLayout`). A UI só chama métodos daqui, via `ActionRegistry`.
@MainActor
@Observable
final class WorkspaceModel {
    struct SessionState {
        var tabs: [Tab]
        var terminals: [UUID: Terminal]
        /// Tabs da mais recente para a mais antiga (⌃⇥).
        var recent: [UUID]
    }

    static let uiStateKey = "workspace"
    static let confirmCloseSettingKey = "terminal.confirmClose"
    /// Tabs reabertas por ⇧⌘T: até 10 por sessão (03 §3.4).
    static let reopenLimit = 10

    @ObservationIgnored let runtime: TerminalRuntime
    @ObservationIgnored private(set) var store: RackyStore?
    @ObservationIgnored var sessionLookup: (UUID) -> Session? = { _ in nil }
    @ObservationIgnored private var snapshot = StoreSnapshot()
    @ObservationIgnored private var listeners: [() -> Void] = []
    @ObservationIgnored private var subagentModes: [UUID: SubagentComputersMode] = [:]
    /// Workers de app (spec subagent-harness): a identidade MCP de cada terminal de worker (a capability só vive em memória), os panes de
    /// worker de cada pai (para empilhar o próximo abaixo do último) e o aviso ao orquestrador quando o terminal do worker termina.
    @ObservationIgnored private var workerLaunches: [UUID: WorkerLaunch] = [:]
    @ObservationIgnored private var workerPanes: [UUID: [UUID]] = [:]
    @ObservationIgnored var onWorkerTerminalEnded: ((_ childID: String, _ exitCode: Int?) -> Void)?
    @ObservationIgnored private var persistTail: Task<Void, Never>?
    @ObservationIgnored private var launching: Set<UUID> = []
    /// Fechados aqui: o snapshot do Store pode ainda mostrá-los por um instante e não deve ressuscitá-los.
    @ObservationIgnored private var closedTabIDs: Set<UUID> = []
    @ObservationIgnored private var removedTerminalIDs: Set<UUID> = []
    @ObservationIgnored private var titleTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private let log = LogFacade(.app, category: "workspace")
    /// Tamanho da área de panes (medido pela view); decide o limite de 240 × 120 dos splits.
    @ObservationIgnored var contentSize: CGSize = .zero
    @ObservationIgnored var overlays: OverlayRouter?
    /// Arrasto de tabs e panes (F11): zonas de drop, reordenação e destacar pane em tab.
    @ObservationIgnored let dragController = PaneDragController()
    @ObservationIgnored var toasts: ToastCenter?
    /// Agente padrão (Settings › Agents) e se o CLI dele está instalado (`nil` = ainda não sondado): ⌥⌘T e Quick Launch.
    @ObservationIgnored var defaultAgent: () -> TerminalProvider = { .claude }
    @ObservationIgnored var agentInstalled: (TerminalProvider) -> Bool? = { _ in nil }
    @ObservationIgnored let confirmationState = ConfirmationState()
    /// ⌘W com uma página ou o viewer de computador no centro fecha a página (03 §11.6), não um terminal. Devolve `true` se tratou.
    @ObservationIgnored var pageCloser: () -> Bool = { false }
    /// Pedido explícito para mostrar um terminal (sidebar, tab, atalho): fecha a página do centro que o esconde.
    @ObservationIgnored var onShowTerminal: () -> Void = {}
    /// "Subagent computers" (F12): o modo com que cada Claude é lançado e o `Restart to apply`.
    @ObservationIgnored weak var subagent: SubagentComputersController?

    private(set) var currentSessionID: UUID?
    private(set) var states: [UUID: SessionState] = [:]
    private(set) var activeTabIDs: [UUID: UUID] = [:]
    /// Pane expandido por tab (⇧⌘↵); só em memória.
    private(set) var expandedPanes: [UUID: UUID] = [:]
    private(set) var runStates: [UUID: PaneRunState] = [:]
    /// Por que cada terminal ficou `interrupted` (frase do banner, T1-23).
    private(set) var interruptionReasons: [UUID: InterruptionReason] = [:]
    @ObservationIgnored private var coldLogShown: Set<UUID> = []
    /// Checklist da ignição por terminal (T1-16): alimentada só por eventos reais do `LaunchCoordinator`.
    private(set) var launchTimelines: [UUID: LaunchTimeline] = [:]
    /// Terminais cuja ignição já passou de `ignitionSkip` (0,3 s) sem primeiro byte: só então o placeholder aparece (M-506).
    private(set) var ignitionVisible: Set<UUID> = []
    /// Cada evento de lançamento, para quem acompanha de fora (linha pendente da sidebar, M-501).
    @ObservationIgnored var onLaunchEvent: ((UUID, LaunchEvent) -> Void)?
    @ObservationIgnored private var launchDirectories: [UUID: URL] = [:]
    @ObservationIgnored private var currentRuns: [UUID: UUID] = [:]
    @ObservationIgnored private var ignitionTimers: [UUID: Task<Void, Never>] = [:]
    var renamingTab: UUID?
    private(set) var pendingClose: PendingClose?
    /// Pane que acabou de receber foco por atalho ou ação (anel de 120 ms, M-309).
    private(set) var focusPulse: (terminalID: UUID, nonce: Int)?
    /// Tab que acabou de ser aberta (largura 0 → cheia, M-301).
    private(set) var recentlyOpenedTab: UUID?
    /// Rim flash do pane (M-309): `nonce` muda a cada pedido, mesmo para o mesmo pane.
    private(set) var rimFlash: (terminalID: UUID, nonce: Int)?
    /// Atenção (Fatia 2): estado de atividade dos agentes e não lido. `nil` na Fatia 1.
    @ObservationIgnored var attention: AttentionCoordinator?
    /// `cwd` novo de um terminal (OSC 7): o módulo Files acompanha (10-right-panel §2).
    @ObservationIgnored var onCwd: ((UUID, String) -> Void)?
    /// BEL em um terminal (06 §3.6).
    @ObservationIgnored var onBell: ((UUID) -> Void)?

    init(runtime: TerminalRuntime) {
        self.runtime = runtime
        runtime.onEvent = { [weak self] id, event in self?.handle(event, terminalID: id) }
        runtime.onFocusRequested = { [weak self] id in self?.focus(terminalID: id) }
        runtime.onDaemonRecovered = { [weak self] in self?.verifyAfterDaemonLoss() }
        dragController.model = self
    }

    // MARK: Observadores (partes AppKit)

    /// A parte AppKit (árvore de panes) é redesenhada a cada mudança; a SwiftUI observa as propriedades.
    func addListener(_ listener: @escaping () -> Void) { listeners.append(listener) }

    private func notify() { for l in listeners { l() } }

    // MARK: Store

    func attach(store: RackyStore) async {
        self.store = store
        if let saved = try? await store.uiState(Self.uiStateKey, as: WorkspaceUIState.self) {
            for (s, t) in saved.activeTabs {
                if let sid = UUID(uuidString: s), let tid = UUID(uuidString: t) { activeTabIDs[sid] = tid }
            }
        }
        interruptionReasons = await SessionReconciler.interruptions(store: store)
        ensureLoaded()
        notify()
    }

    /// Reabertura (06 §1.4): cruza os terminais `running` do banco com o que o daemon mantém vivo. Vivo reanexa (a view pede o
    /// snapshot ao aparecer); morto vira `interrupted` com o motivo. Sem daemon, não sobe um só para descobrir isso. Nada é
    /// relançado: quem decide é o usuário (Resume, Start Fresh, Close). Chamar antes de `attach(store:)`.
    func restoreSessions(store: RackyStore) async -> ReconcileReport? {
        let running = ((try? await store.terminals(in: .running)) ?? []) + ((try? await store.terminals(in: .launching)) ?? [])
        let daemonSessions = running.isEmpty ? nil : await runtime.probeDaemon()
        do {
            return try await SessionReconciler.reconcile(store: store, daemonSessions: daemonSessions)
        } catch {
            log.error("restore failed: \(error)")
            return nil
        }
    }

    /// Chamado a cada snapshot do Store: carrega a sessão selecionada quando ela chega e esquece as que sumiram.
    func ingest(_ snap: StoreSnapshot) {
        snapshot = snap
        let alive = Set(snap.sessions.map(\.id))
        for id in states.keys where !alive.contains(id) { dropSession(id) }
        mergeNewRecords(from: snap)
        ensureLoaded()
        // Modo "Subagent computers" mudou: o header do pane (ícone e "Restart to apply") lê a sessão por `sessionLookup`, fora da
        // observação; sem isso o aviso só aparecia na próxima mudança do terminal (a primeira mensagem).
        let modes = Dictionary(uniqueKeysWithValues: snap.sessions.map { ($0.id, $0.subagentComputers) })
        if modes != subagentModes {
            subagentModes = modes
            notify()
        }
    }

    /// Sessão já carregada: acrescenta tabs e terminais que outro escritor gravou depois (o Store grava a tab antes do terminal).
    private func mergeNewRecords(from snap: StoreSnapshot) {
        var changed = false
        for (sid, var state) in states {
            let known = Set(state.tabs.map(\.id))
            let newTabs = snap.tabs.filter { $0.sessionID == sid && $0.closedAt == nil && !known.contains($0.id) && !closedTabIDs.contains($0.id) }
            if !newTabs.isEmpty {
                state.tabs = (state.tabs + newTabs).sorted { ($0.sortIndex, $0.createdAt) < ($1.sortIndex, $1.createdAt) }
                if activeTabIDs[sid] == nil { activeTabIDs[sid] = state.tabs.first?.id }
                changed = true
            }
            let tabIDs = Set(state.tabs.map(\.id))
            for t in snap.terminals where tabIDs.contains(t.tabID) && state.terminals[t.id] == nil && !removedTerminalIDs.contains(t.id) {
                state.terminals[t.id] = t
                runStates[t.id] = .starting
                changed = true
            }
            states[sid] = state
        }
        if changed { notify() }
    }

    func setSession(_ id: UUID?) {
        guard currentSessionID != id else { return }
        currentSessionID = id
        ensureLoaded()
        notify()
    }

    private func dropSession(_ id: UUID) {
        guard let state = states.removeValue(forKey: id) else { return }
        for terminal in state.terminals.keys { runtime.dispose(terminal) }
        activeTabIDs[id] = nil
        notify()
    }

    private func ensureLoaded() {
        guard let sid = currentSessionID else { return }
        load(session: sid)
    }

    private func load(session sid: UUID) {
        guard states[sid] == nil, snapshot.sessions.contains(where: { $0.id == sid }) else { return }
        let tabs = snapshot.tabs.filter { $0.sessionID == sid && $0.closedAt == nil }
            .sorted { ($0.sortIndex, $0.createdAt) < ($1.sortIndex, $1.createdAt) }
        let tabIDs = Set(tabs.map(\.id))
        var terminals: [UUID: Terminal] = [:]
        for t in snapshot.terminals where tabIDs.contains(t.tabID) { terminals[t.id] = t }
        var state = SessionState(tabs: tabs, terminals: terminals, recent: [])
        let preferred = activeTabIDs[sid].flatMap { id in tabs.contains { $0.id == id } ? id : nil }
        let active = preferred ?? tabs.first?.id
        activeTabIDs[sid] = active
        if let active { state.recent = [active] }
        states[sid] = state
        for t in terminals.values {
            switch t.state {
            case .exited, .killed: runStates[t.id] = .exited(code: t.exitCode, signal: t.exitSignal)
            case .interrupted: runStates[t.id] = .interrupted
            case .failedToStart: runStates[t.id] = .failed(String(localized: "The process couldn't be started.", bundle: .module))
            default: runStates[t.id] = .starting
            }
        }
        notify()
    }

    // MARK: Consultas

    var session: Session? { currentSessionID.flatMap(sessionLookup) }
    var isLoaded: Bool { currentSessionID.flatMap { states[$0] } != nil }
    var tabs: [Tab] { currentSessionID.flatMap { states[$0]?.tabs } ?? [] }

    var activeTabID: UUID? { currentSessionID.flatMap { activeTabIDs[$0] } }
    var activeTab: Tab? { activeTabID.flatMap { id in tabs.first { $0.id == id } } }

    func terminal(_ id: UUID) -> Terminal? {
        for state in states.values { if let t = state.terminals[id] { return t } }
        return nil
    }

    func tab(_ id: UUID) -> Tab? { tabs.first { $0.id == id } }

    func isLoaded(session id: UUID) -> Bool { states[id] != nil }

    /// A sessão dona do terminal (qualquer sessão do Store, carregada ou não).
    func sessionID(of terminal: Terminal) -> UUID? {
        snapshot.tabs.first { $0.id == terminal.tabID }?.sessionID ?? locate(terminal: terminal.id)?.sid
    }

    /// Modo "Subagent computers" da sessão do terminal (Claude, Codex e OpenCode; cada CLI recebe a sua injeção).
    func subagentLaunch(for terminal: Terminal) -> SubagentLaunch? {
        // O terminal de um worker de app nunca é pai de orquestração (nem depois de reaberto o app).
        guard terminal.launchSpec.workerChildID == nil, terminal.provider.supportsSubagentComputers, let sid = sessionID(of: terminal),
              let session = sessionLookup(sid) else { return nil }
        return SubagentLaunch(sessionID: sid, sessionTitle: session.title, mode: session.subagentComputers, harness: session.subagentHarness)
    }

    /// O que o header do pane precisa do "Subagent computers" da sessão.
    func subagentHeader(for terminal: Terminal) -> (session: UUID, mode: SubagentComputersMode, restart: Bool)? {
        guard terminal.launchSpec.workerChildID == nil, terminal.provider.supportsSubagentComputers, let sid = sessionID(of: terminal),
              let session = sessionLookup(sid) else { return nil }
        return (sid, session.subagentComputers, subagent?.restartPending(session: sid) ?? false)
    }

    /// `Restart to apply`: mata o Claude com calma e o relança com Resume, para o lançamento levar o modo novo.
    func relaunchApplyingSettings(_ id: UUID) async {
        guard let t = terminal(id), t.provider.supportsSubagentComputers else { return }
        await runtime.kill(t, mode: .graceful)
        for _ in 0 ..< 80 {
            guard let current = terminal(id), current.state == .running || current.state == .launching else { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if let current = terminal(id), current.state == .running || current.state == .launching {
            await runtime.kill(current, mode: .force)
            try? await Task.sleep(for: .seconds(1))
        }
        resume(id)
    }

    /// A tab (de qualquer sessão carregada) que contém o terminal.
    func tabContaining(terminalID: UUID) -> Tab? { locate(terminal: terminalID)?.tab }

    private func locate(terminal id: UUID) -> (sid: UUID, tab: Tab)? {
        for (sid, state) in states {
            if let tab = state.tabs.first(where: { $0.layout.pane(forTerminal: id) != nil }) { return (sid, tab) }
        }
        return nil
    }

    private func locate(tab id: UUID) -> (sid: UUID, tab: Tab)? {
        for (sid, state) in states { if let tab = state.tabs.first(where: { $0.id == id }) { return (sid, tab) } }
        return nil
    }

    /// Terminal focado da tab ativa (o que as ações de teclado alvejam).
    var focusedTerminalID: UUID? {
        guard let tab = activeTab else { return nil }
        if let f = tab.focusedTerminalID, tab.layout.pane(forTerminal: f) != nil { return f }
        return tab.layout.terminalIDs.first
    }

    /// Todo terminal de sessão carregada que ainda está em algum layout (a área de panes tem uma view por um deles).
    var loadedTerminalIDs: Set<UUID> {
        Set(states.values.flatMap { $0.tabs.flatMap { $0.layout.terminalIDs } })
    }

    /// Título do cabeçalho do pane: o dinâmico do terminal (OSC 0/2) ou o nome do agente.
    func displayTitleOfPane(_ terminalID: UUID) -> String { terminal(terminalID)?.title ?? "" }

    func paneState(_ terminalID: UUID) -> PaneRunState { runStates[terminalID] ?? .starting }

    /// Todos os terminais das tabs da sessão atual (as views existem para todos, só as da tab ativa aparecem).
    var terminalsInCurrentSession: [Terminal] {
        guard let sid = currentSessionID, let state = states[sid] else { return [] }
        return state.tabs.flatMap { $0.layout.terminalIDs }.compactMap { state.terminals[$0] }
    }

    func expandedPane(in tab: Tab) -> UUID? {
        guard let p = expandedPanes[tab.id], tab.layout.contains(paneID: p) else { return nil }
        return p
    }

    /// Título mostrado: o fixado pelo usuário, senão o dinâmico do terminal focado (OSC 0/2), senão o da tab (03 §3.2).
    func displayTitle(of tab: Tab) -> String {
        // Tab só com um dataset: sempre o nome atual do dataset (renomear a tab renomeia o dataset; nada fica preso na tab).
        if let id = datasetOnly(tab) { return datasetTitle(id) ?? tab.title }
        if tab.layout.terminalIDs.isEmpty, tab.layout.leafCount == 1, case .computer(let name) = tab.layout.firstPane.content { return computerTitle(name) }
        if tab.layout.terminalIDs.isEmpty, tab.layout.leafCount == 1, case .notebook(let id) = tab.layout.firstPane.content { return notebookTitle(id) }
        if tab.layout.terminalIDs.isEmpty, tab.layout.leafCount == 1, case .traffic(let name) = tab.layout.firstPane.content { return trafficTitle(name) }
        if tab.titleLocked { return tab.title }
        if let id = tab.focusedTerminalID ?? tab.layout.terminalIDs.first, let t = terminal(id), !t.title.isEmpty { return t.title }
        return tab.title
    }

    /// Terminal que representa a tab (foco, senão o primeiro): fornece logo e estado do início da tab.
    func primaryTerminal(of tab: Tab) -> Terminal? {
        let id = tab.focusedTerminalID.flatMap { tab.layout.pane(forTerminal: $0) != nil ? $0 : nil } ?? tab.layout.terminalIDs.first
        return id.flatMap(terminal)
    }

    // MARK: Mutação com persistência ordenada

    /// Grava na ordem em que foi pedido (uma cadeia de tarefas): layout, tabs e terminais não se ultrapassam.
    private func persist(_ work: @escaping @Sendable (RackyStore) async throws -> Void) {
        guard let store else { return }
        let previous = persistTail
        persistTail = Task { [log] in
            await previous?.value
            do { try await work(store) } catch { log.error("workspace persist failed: \(error)"); }
        }
    }

    /// Espera as gravações pendentes (testes e ⇧⌘T, que lê o Store).
    func settlePersistence() async { await persistTail?.value }

    private func update(tab id: UUID, _ body: (inout Tab) -> Void) {
        guard let (sid, _) = locate(tab: id), var state = states[sid], let i = state.tabs.firstIndex(where: { $0.id == id }) else { return }
        body(&state.tabs[i])
        states[sid] = state
    }

    private func update(terminal id: UUID, _ body: (inout Terminal) -> Void) {
        for (sid, var state) in states where state.terminals[id] != nil {
            body(&state.terminals[id]!)
            states[sid] = state
            return
        }
    }

    private func save(terminal id: UUID) {
        guard let t = terminal(id) else { return }
        persist { try await $0.save(t) }
    }

    private func save(tab id: UUID) {
        guard let t = locate(tab: id)?.tab else { return }
        persist { try await $0.save(t) }
    }

    private func saveLayout(of tabID: UUID, final: Bool) {
        guard let tab = locate(tab: tabID)?.tab else { return }
        let layout = tab.layout, focus = tab.focusedTerminalID
        if final {
            persist { try await $0.setLayout(tabID: tabID, layout: layout, focusedTerminalID: focus) }
        } else {
            persist { try await $0.scheduleLayout(tabID: tabID, layout: layout, focusedTerminalID: focus) }
        }
    }

    private func saveUIState() {
        let state = WorkspaceUIState(activeTabs: Dictionary(uniqueKeysWithValues: activeTabIDs.map { ($0.key.uuidString, $0.value.uuidString) }))
        persist { try await $0.setUIState(Self.uiStateKey, state) }
    }

    // MARK: Tabs

    func selectTab(_ id: UUID) {
        guard let sid = currentSessionID, tabs.contains(where: { $0.id == id }) else { return }
        if activeTabIDs[sid] != id {
            activeTabIDs[sid] = id
            states[sid]?.recent.removeAll { $0 == id }
            states[sid]?.recent.insert(id, at: 0)
            saveUIState()
        }
        notify()
        focusTerminalOfActiveTab()
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectTab(tabs[index].id)
    }

    func selectTab(delta: Int) {
        guard let active = activeTabID, let i = tabs.firstIndex(where: { $0.id == active }), tabs.count > 1 else { return }
        let n = tabs.count
        selectTab(at: ((i + delta) % n + n) % n)
    }

    /// ⌃⇥: a tab usada antes desta; repete para voltar (alterna entre as duas últimas).
    func selectRecentTab(reverse: Bool = false) {
        guard let sid = currentSessionID, let recent = states[sid]?.recent.filter({ id in tabs.contains { $0.id == id } }), recent.count > 1 else { return }
        selectTab(reverse ? recent[recent.count - 1] : recent[1])
    }

    private func nextSortIndex(after tabID: UUID?) -> Int {
        guard let tabID, let i = tabs.firstIndex(where: { $0.id == tabID }) else { return (tabs.map(\.sortIndex).max() ?? -1) + 1 }
        return i + 1
    }

    /// Nova tab com um terminal (⌘T shell, ⌥⌘T agente, Quick Launch). Entra à direita da ativa (M-301).
    @discardableResult
    func newTab(
        provider: TerminalProvider, profileID: UUID? = nil, prompt: String? = nil, customArgv: [String]? = nil, resumeOf: String? = nil
    ) -> UUID? {
        guard let session, let sid = currentSessionID, states[sid] != nil else { return nil }
        let tabID = UUID.v7()
        var spec = LaunchSpec(provider: provider, profileID: profileID)
        spec.initialPrompt = prompt
        spec.resumeOf = resumeOf
        spec.customArgv = customArgv
        let terminal = makeTerminal(tabID: tabID, spec: spec, cwd: session.folderPath, folder: session.folderPath)
        let pane = Pane(content: .terminal(terminal.id))
        let position = nextSortIndex(after: activeTabID)
        let tab = Tab(
            id: tabID, sessionID: sid, title: terminal.title, sortIndex: position, layout: .leaf(pane), focusedTerminalID: terminal.id)
        var list = states[sid]!.tabs
        list.insert(tab, at: min(position, list.count))
        for i in list.indices { list[i].sortIndex = i }
        states[sid]!.tabs = list
        states[sid]!.terminals[terminal.id] = terminal
        runStates[terminal.id] = .starting
        recentlyOpenedTab = tabID
        selectTab(tabID)
        let saved = list, newTerminal = terminal
        persist { store in
            for t in saved { try await store.save(t) }
            try await store.save(newTerminal)
        }
        return tabID
    }

    /// Abre uma tab (ou um split à direita, ⇧↵) a partir de um pedido do Quick Launch (03 §7).
    @discardableResult
    func open(_ request: QuickLaunchRequest) -> UUID? {
        guard request.split else { return newTab(provider: request.provider, profileID: request.profileID, prompt: request.prompt) }
        var spec = LaunchSpec(provider: request.provider, profileID: request.profileID)
        spec.initialPrompt = request.prompt
        guard case .created(let id) = split(.horizontal, spec: spec) else { return nil }
        return id
    }

    private func makeTerminal(tabID: UUID, spec: LaunchSpec, cwd: String, folder: String) -> Terminal {
        let adapter = ProviderAdapters.adapter(for: spec.provider)
        let title = spec.provider.isAgent ? adapter.displayName : URL(fileURLWithPath: folder).lastPathComponent
        // Perfis embutidos não estão na tabela `launch_profile` (FK): só o `launchSpec` guarda o ID deles.
        let stored = spec.profileID.flatMap { id in snapshot.profiles.contains { $0.id == id } ? id : nil }
        return Terminal(tabID: tabID, provider: spec.provider, profileID: stored, title: title, cwd: cwd, launchSpec: spec)
    }

    // MARK: Rename, reordenar

    func beginRename(_ tabID: UUID) -> Bool {
        guard tab(tabID) != nil else { return false }
        renamingTab = tabID
        return true
    }

    func cancelRename() { renamingTab = nil }

    /// Vazio volta ao título dinâmico; texto fixa o título (03 §2.11).
    func commitRename(_ text: String, tabID: UUID? = nil) {
        guard let id = tabID ?? renamingTab, let current = tab(id) else { return }
        renamingTab = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let dataset = datasetOnly(current) {
            // A tab de um dataset é o dataset: o nome novo vai para ele (aparece em todo lugar) e a tab não fixa título.
            renameDataset(dataset, trimmed)
            update(tab: id) { $0.titleLocked = false }
            save(tab: id)
            notify()
            return
        }
        if trimmed.isEmpty { resetTitle(id) } else {
            update(tab: id) { $0.title = trimmed; $0.titleLocked = true }
            save(tab: id)
        }
        notify()
    }

    func resetTitle(_ tabID: UUID) {
        guard let t = tab(tabID), t.titleLocked else { return }
        let fallback = primaryTerminal(of: t)?.title ?? t.title
        update(tab: tabID) { $0.title = fallback; $0.titleLocked = false }
        save(tab: tabID)
        notify()
    }

    func moveTab(_ tabID: UUID, to index: Int) {
        guard let sid = currentSessionID, var list = states[sid]?.tabs, let from = list.firstIndex(where: { $0.id == tabID }) else { return }
        let target = min(max(index, 0), list.count - 1)
        guard target != from else { return }
        let moved = list.remove(at: from)
        list.insert(moved, at: target)
        for i in list.indices { list[i].sortIndex = i }
        states[sid]!.tabs = list
        let saved = list
        persist { store in for t in saved { try await store.save(t) } }
        notify()
    }

    // MARK: Foco e panes

    func focus(terminalID: UUID) {
        guard let tab = tabContaining(terminalID: terminalID) else { return }
        if tab.focusedTerminalID != terminalID {
            update(tab: tab.id) { $0.focusedTerminalID = terminalID }
            saveLayout(of: tab.id, final: false)
        }
        notify()
    }

    /// Foco por atalho ou ação: seleciona a tab, foca o pane e o terminal da AppKit (rim flash, M-309).
    func show(terminalID: UUID, flash: Bool = false) {
        guard let tab = tabContaining(terminalID: terminalID) else { return }
        onShowTerminal()
        if activeTabID != tab.id { selectTab(tab.id) }
        focus(terminalID: terminalID)
        pulse(terminalID)
        if flash { rimFlash = (terminalID, (rimFlash?.nonce ?? 0) + 1) }
        runtime.existingEntry(for: terminalID)?.host.focusTerminal()
        notify()
    }

    /// Panes na tela agora: os da tab ativa (ou só o expandido). Decide visto/não lido e a supressão de notificações.
    var visibleTerminalIDs: Set<UUID> {
        guard let tab = activeTab else { return [] }
        if let expanded = expandedPane(in: tab), case .terminal(let id)? = tab.layout.pane(withID: expanded)?.content { return [id] }
        return Set(tab.layout.terminalIDs)
    }

    /// Estado do agente do terminal para o indicador da tab e do header do pane (Fatia 2); sem hooks, o do processo.
    func status(of terminal: Terminal) -> SidebarProjector.StatusSample {
        let sample = SidebarProjector.status(for: terminal, center: attention?.center ?? AttentionCenter(), now: Date())
        // Worker de app que já entregou o resultado: concluído, mesmo com o CLI aberto esperando input.
        if terminal.state == .running, finishedWorkers().contains(terminal.id) {
            return SidebarProjector.StatusSample(glyph: .done, label: String(localized: "Done", bundle: .module), rank: sample.rank)
        }
        return sample
    }

    /// Terminais de workers de app que terminaram (ligado ao `ComputersModel`).
    @ObservationIgnored var finishedWorkers: () -> Set<UUID> = { [] }

    func isUnread(_ terminalID: UUID) -> Bool { attention?.center.unread.contains(terminalID) ?? false }

    private func pulse(_ terminalID: UUID) {
        focusPulse = (terminalID, (focusPulse?.nonce ?? 0) + 1)
    }

    /// Host do terminal do pane focado da aba ativa (watchdog de digitação).
    func focusedHost() -> TerminalHostView? {
        guard let id = focusedTerminalID else { return nil }
        return runtime.existingEntry(for: id)?.host
    }

    /// Quem pode receber foco automático (evento de lançamento, troca de tab): sem overlay, popover, Settings, página do centro
    /// nem campo de texto com o teclado. Ligado pelo `AppEnvironment`. Foco pedido pelo usuário (clique, fechar overlay) não passa por aqui.
    var autoFocusAllowed: () -> Bool = { true }
    /// Nome de um dataset (título da tab e do pane); ligado pelo `AppEnvironment`.
    @ObservationIgnored var datasetTitle: (String) -> String? = { _ in nil }
    /// Título da tab de um computador ("Codex 1 · computer"); ligado pelo `AppEnvironment`.
    @ObservationIgnored var computerTitle: (String) -> String = { $0 }
    /// Renomeia um dataset (o nome mostrado); ligado pelo `AppEnvironment`.
    @ObservationIgnored var renameDataset: (String, String) -> Void = { _, _ in }

    /// O dataset de uma tab que só tem ele (sem terminal), ou `nil`.
    func datasetOnly(_ tab: Tab) -> String? {
        guard tab.layout.terminalIDs.isEmpty, tab.layout.leafCount == 1, case .dataset(let id) = tab.layout.firstPane.content else { return nil }
        return id
    }
    /// View de um pane sem terminal (tabela do dataset), já com o ambiente do app; ligado pela janela.
    @ObservationIgnored var makePaneView: ((Pane) -> NSView)?

    func autoFocus(_ host: TerminalHostView?) {
        guard let host, autoFocusAllowed(), !(host.window?.firstResponder is NSText) else { return }
        host.focusTerminal()
    }

    func focusTerminalOfActiveTab() {
        guard let id = focusedTerminalID else { return }
        runtime.existingEntry(for: id)?.host.focusTerminal()
    }

    func focusNextPane(delta: Int) -> Bool {
        guard let tab = activeTab, let current = focusedTerminalID, let pane = tab.layout.pane(forTerminal: current),
              let next = tab.layout.pane(from: pane.id, delta: delta), case .terminal(let id) = next.content
        else { return false }
        if expandedPanes[tab.id] != nil { expandedPanes[tab.id] = nil }
        show(terminalID: id)
        return true
    }

    // MARK: Split

    enum SplitResult: Equatable { case created(UUID), noRoom, unavailable }

    @discardableResult
    func split(_ axis: SplitAxis, source: UUID? = nil, shell: Bool = false, spec explicit: LaunchSpec? = nil) -> SplitResult {
        guard let tab = activeTab, let sourceID = source ?? focusedTerminalID, let sourcePane = tab.layout.pane(forTerminal: sourceID),
              let origin = terminal(sourceID), let sid = currentSessionID
        else { return .unavailable }
        if expandedPanes[tab.id] != nil { expandedPanes[tab.id] = nil }
        let area = CGRect(origin: .zero, size: contentSize)
        if contentSize != .zero, !tab.layout.canSplit(paneID: sourcePane.id, axis: axis, in: area) {
            toasts?.show(
                kind: .info, title: String(localized: "Not enough room to split. Close a pane or widen the window.", bundle: .module))
            return .noRoom
        }
        // Mesmo agente e perfil (⌥: shell). Sem prompt e sem ID nativo: o pane novo começa uma conversa nova.
        var spec = origin.launchSpec
        if shell { spec = LaunchSpec(provider: .shell) }
        if let explicit { spec = explicit } else { spec.initialPrompt = nil; spec.initialPromptFile = nil; spec.nativeSessionID = nil; spec.resumeOf = nil }
        var terminal = makeTerminal(tabID: tab.id, spec: spec, cwd: origin.cwd, folder: origin.cwd)
        terminal.title = spec.provider.isAgent ? ProviderAdapters.adapter(for: spec.provider).displayName : URL(fileURLWithPath: origin.cwd).lastPathComponent
        let pane = Pane(content: .terminal(terminal.id))
        guard let layout = tab.layout.splitting(paneID: sourcePane.id, axis: axis, inserting: pane) else { return .unavailable }
        update(tab: tab.id) { $0.layout = layout; $0.focusedTerminalID = terminal.id }
        states[sid]?.terminals[terminal.id] = terminal
        runStates[terminal.id] = .starting
        let newTerminal = terminal, tabID = tab.id
        persist { try await $0.save(newTerminal) }
        saveLayout(of: tabID, final: true)
        pulse(terminal.id)
        notify()
        return .created(terminal.id)
    }

    func toggleExpand(_ terminalID: UUID? = nil) {
        guard let tab = activeTab, tab.layout.leafCount > 1 || expandedPanes[tab.id] != nil,
              let id = terminalID ?? focusedTerminalID, let pane = tab.layout.pane(forTerminal: id)
        else { return }
        expandedPanes[tab.id] = expandedPanes[tab.id] == pane.id ? nil : pane.id
        focus(terminalID: id)
        notify()
    }

    func equalize() {
        guard let tab = activeTab, tab.layout.leafCount > 1 else { return }
        update(tab: tab.id) { $0.layout = $0.layout.equalized() }
        saveLayout(of: tab.id, final: true)
        notify()
    }

    func equalizeDivider(at path: SplitPath) {
        guard let tab = activeTab else { return }
        update(tab: tab.id) { $0.layout = $0.layout.equalizing(at: path) }
        saveLayout(of: tab.id, final: true)
        notify()
    }

    /// Arrasto do divisor: atualiza a proporção na hora; grava com debounce, e no fim do gesto (`final`) sem espera.
    func setRatio(at path: SplitPath, ratio: Double, final: Bool) {
        guard let tab = activeTab else { return }
        let area = CGRect(origin: .zero, size: contentSize)
        let clamped = contentSize == .zero ? ratio : tab.layout.clampedRatio(ratio, at: path, in: area)
        update(tab: tab.id) { $0.layout = $0.layout.settingRatio(at: path, ratio: clamped) }
        saveLayout(of: tab.id, final: final)
        notify()
    }

    // MARK: Fechar

    private var confirmClose: Bool {
        get async { (try? await store?.setting(Self.confirmCloseSettingKey, as: Bool.self)) ?? true }
    }

    /// Fecha um pane (⌘W). O último pane fecha a tab; a última tab deixa a sessão sem tabs (nunca fecha a janela).
    func closePane(_ terminalID: UUID? = nil) {
        guard let id = terminalID ?? focusedTerminalID, terminal(id) != nil else { return }
        request(close: [id])
    }

    func closeTab(_ tabID: UUID? = nil) {
        guard let id = tabID ?? activeTabID, let t = tab(id) else { return }
        // Panes sem terminal (datasets) saem na hora; os terminais seguem o fluxo normal (confirma se há processo vivo).
        for pane in t.layout.panes where pane.content.terminalID == nil { closePane(id: pane.id) }
        request(close: t.layout.terminalIDs)
    }

    func closeOtherTabs(except tabID: UUID? = nil) {
        guard let keep = tabID ?? activeTabID else { return }
        request(close: tabs.filter { $0.id != keep }.flatMap { $0.layout.terminalIDs })
    }

    func closeTabs(toTheRightOf tabID: UUID? = nil) {
        guard let from = tabID ?? activeTabID, let i = tabs.firstIndex(where: { $0.id == from }) else { return }
        request(close: tabs[(i + 1)...].flatMap { $0.layout.terminalIDs })
    }

    func closeOtherPanes(keeping terminalID: UUID? = nil) {
        guard let tab = activeTab, let keep = terminalID ?? focusedTerminalID else { return }
        request(close: tab.layout.terminalIDs.filter { $0 != keep })
    }

    /// Fechar um conjunto de terminais: confirma só se algum tem processo vivo e não é shell ocioso (03 §16.1).
    private func request(close ids: [UUID]) {
        guard !ids.isEmpty else { return }
        Task { @MainActor in
            var busy: [Terminal] = []
            var commands: [UUID: String] = [:]
            for id in ids {
                guard let t = terminal(id), await runtime.isBusy(t) else { continue }
                busy.append(t)
                if !t.provider.isAgent, let pid = await runtime.summary(of: t)?.pid, let name = ProcessTree.firstChildName(of: pid) { commands[id] = name }
            }
            let ask = await confirmClose
            if busy.isEmpty || !ask || overlays == nil {
                perform(close: ids)
                return
            }
            presentConfirmation(for: busy, all: ids, commands: commands)
        }
    }

    private func presentConfirmation(for busy: [Terminal], all ids: [UUID], commands: [UUID: String]) {
        guard let overlays else { return perform(close: ids) }
        let message: String
        let title: String
        if busy.count == 1, let t = busy.first {
            title = String(localized: "Close this terminal?", bundle: .module)
            if t.provider.isAgent {
                message = String(
                    localized: "\(ProviderAdapters.adapter(for: t.provider).displayName) is still working. Closing ends the process; you can resume the conversation later.",
                    bundle: .module)
            } else {
                let command = commands[t.id] ?? t.title
                message = String(localized: "\"\(command)\" is still running. Closing ends it.", bundle: .module)
            }
        } else {
            title = String(localized: "Close \(busy.count) terminals?", bundle: .module)
            message = String(localized: "\(busy.count) terminals are still running. Closing ends their processes.", bundle: .module)
        }
        confirmationState.dontAsk = false
        var model = ConfirmationModel.closeTerminal(message: message)
        model.title = title
        model.state = confirmationState
        pendingClose = PendingClose(terminalIDs: ids) { [weak self] in self?.perform(close: ids) }
        if !overlays.present(.confirmation(model), from: nil) {
            pendingClose = nil
            perform(close: ids)
        }
    }

    func confirmPendingClose() {
        overlays?.dismiss(.action)
        let pending = pendingClose
        pendingClose = nil
        if confirmationState.dontAsk { persist { try await $0.setSetting(Self.confirmCloseSettingKey, false) } }
        pending?.perform()
    }

    func cancelPendingClose() {
        overlays?.dismiss(.action)
        pendingClose = nil
    }

    /// Fecha os terminais: sem processo vivo, sai na hora; com processo, `kill graceful` e o pane fica "fechando"
    /// até a saída (banner `The process didn't exit.` com Force Quit depois de 5 s, 03 §4.6).
    func perform(close ids: [UUID]) {
        for id in ids {
            guard let t = terminal(id) else { continue }
            let attached = runtime.existingEntry(for: id)?.isAttached == true
            var alive = t.state == .running && t.ptySessionID != nil
            switch paneState(id) {
            case .exited, .interrupted, .failed: alive = false
            default: break
            }
            if alive {
                Task { await runtime.kill(t, mode: .graceful) }
                if attached {
                    runStates[id] = .closing(stuck: false)
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(5))
                        guard let self, case .closing(false) = self.runStates[id] else { return }
                        self.runStates[id] = .closing(stuck: true)
                        self.notify()
                    }
                    continue
                }
            }
            finalizeRemoval(of: id)
        }
        notify()
    }

    /// Encerra o processo de todos os terminais de uma sessão (arquivar e apagar, 03 §16.2 e §16.5). Não mexe em layout nem em
    /// registros: quem chama arquiva ou apaga a sessão depois.
    func stopTerminals(ofSession sessionID: UUID) async {
        let tabIDs = Set(snapshot.tabs.filter { $0.sessionID == sessionID }.map(\.id))
        var terminals = Dictionary(uniqueKeysWithValues: snapshot.terminals.filter { tabIDs.contains($0.tabID) }.map { ($0.id, $0) })
        for (id, live) in states[sessionID]?.terminals ?? [:] { terminals[id] = live }
        for terminal in terminals.values where terminal.ptySessionID != nil && (terminal.state == .running || terminal.state == .launching) {
            await runtime.kill(terminal, mode: .graceful)
        }
    }

    func forceQuit(_ terminalID: UUID) {
        guard let t = terminal(terminalID) else { return }
        Task { await runtime.kill(t, mode: .force) }
    }

    func cancelClose(_ terminalID: UUID) {
        guard case .closing = paneState(terminalID) else { return }
        runStates[terminalID] = .running
        notify()
    }

    /// Remove o pane do layout (o irmão ocupa o espaço, M-307), apaga o terminal (soft delete) e solta a view.
    private func finalizeRemoval(of terminalID: UUID) {
        guard let t = terminal(terminalID), let (sid, tab) = locate(terminal: terminalID), let pane = tab.layout.pane(forTerminal: terminalID)
        else { return }
        noteWorkerEnded(terminalID)
        workerLaunches[terminalID] = nil
        for (parent, list) in workerPanes { workerPanes[parent] = list.filter { $0 != terminalID } }
        var removed = t
        removed.deletedAt = Date()
        let gone = removed
        persist { try await $0.save(gone) }
        states[sid]?.terminals[terminalID] = nil
        removedTerminalIDs.insert(terminalID)
        runStates[terminalID] = nil
        retire(run: terminalID)
        launchTimelines[terminalID] = nil
        ignitionVisible.remove(terminalID)
        runtime.dispose(terminalID)
        attention?.terminalClosed(terminalID)
        if let layout = tab.layout.removing(paneID: pane.id) {
            let successor = tab.layout.focusSuccessor(afterRemoving: pane.id)
            update(tab: tab.id) { tab in
                tab.layout = layout
                if tab.focusedTerminalID == terminalID {
                    if let s = successor, case .terminal(let id) = s.content { tab.focusedTerminalID = id } else { tab.focusedTerminalID = layout.terminalIDs.first }
                }
            }
            if expandedPanes[tab.id] == pane.id { expandedPanes[tab.id] = nil }
            saveLayout(of: tab.id, final: true)
            if tab.id == activeTabID { focusTerminalOfActiveTab() }
        } else {
            removeTab(tab.id, in: sid)
        }
        notify()
    }

    /// Fecha a tab (closedAt): some da tab row e fica disponível para ⇧⌘T.
    private func removeTab(_ tabID: UUID, in sid: UUID) {
        guard var state = states[sid], let i = state.tabs.firstIndex(where: { $0.id == tabID }) else { return }
        var tab = state.tabs.remove(at: i)
        closedTabIDs.insert(tabID)
        tab.closedAt = Date()
        state.recent.removeAll { $0 == tabID }
        states[sid] = state
        expandedPanes[tabID] = nil
        if activeTabIDs[sid] == tabID {
            let next = state.recent.first ?? (state.tabs.indices.contains(i) ? state.tabs[i].id : state.tabs.last?.id)
            activeTabIDs[sid] = next
            saveUIState()
        }
        let closed = tab
        persist { try await $0.save(closed) }
        if sid == currentSessionID { focusTerminalOfActiveTab() }
    }

    // MARK: Workers de app (spec subagent-harness)

    /// Abre o terminal de um worker de app na sessão `sid` (não depende da tab ativa nem da sessão atual): um pane dividido ao lado do pai
    /// (o primeiro à direita dele, os seguintes empilhados abaixo do anterior) e, sem espaço, uma tab nova da mesma sessão. Não rouba o foco.
    /// O terminal sobe já (sem esperar o pane aparecer) e leva a identidade MCP do filho. Devolve o id do terminal, `nil` se a sessão não carrega.
    @discardableResult
    func openWorkerTerminal(
        session sid: UUID, nextTo parentTerminal: UUID?, worker: WorkerLaunch, spec baseSpec: LaunchSpec, title: String
    ) -> UUID? {
        if states[sid] == nil { load(session: sid) }
        guard states[sid] != nil, let session = sessionLookup(sid) else { return nil }
        var spec = baseSpec
        spec.workerChildID = worker.childID
        spec.workerParentTerminalID = parentTerminal
        let parentTab = parentTerminal.flatMap { locate(terminal: $0) }.flatMap { $0.sid == sid ? $0.tab : nil }
        let cwd = parentTerminal.flatMap(terminal)?.cwd ?? session.folderPath
        let tabID = parentTab?.id ?? UUID.v7()
        var terminal = makeTerminal(tabID: tabID, spec: spec, cwd: cwd, folder: cwd)
        terminal.title = title
        terminal.titleSource = .user  // "<Harness> · <tarefa>": o OSC do CLI não o troca
        let pane = Pane(content: .terminal(terminal.id))
        workerLaunches[terminal.id] = worker
        let area = CGRect(origin: .zero, size: contentSize)
        var placed = false
        if let tab = parentTab, let parent = parentTerminal {
            // Candidatos em ordem: abaixo do último worker deste pai, depois à direita do pai.
            var candidates: [(UUID, PaneDropZone, SplitAxis)] = []
            if let last = workerPanes[parent]?.last(where: { tab.layout.pane(forTerminal: $0) != nil }), let p = tab.layout.pane(forTerminal: last) {
                candidates.append((p.id, .bottom, .vertical))
            }
            if let p = tab.layout.pane(forTerminal: parent) { candidates.append((p.id, .right, .horizontal)) }
            for (target, zone, axis) in candidates {
                guard contentSize == .zero || tab.layout.canSplit(paneID: target, axis: axis, in: area),
                      let layout = tab.layout.inserting(.leaf(pane), beside: target, zone: zone) else { continue }
                update(tab: tab.id) { $0.layout = layout }
                if expandedPanes[tab.id] != nil { expandedPanes[tab.id] = nil }
                saveLayout(of: tab.id, final: true)
                placed = true
                break
            }
        }
        if !placed {
            // Sem pai na sessão ou sem espaço: tab nova no fim da sessão, sem selecioná-la.
            var state = states[sid]!
            let tab = Tab(
                id: tabID == parentTab?.id ? UUID.v7() : tabID, sessionID: sid, title: title, sortIndex: state.tabs.count, layout: .leaf(pane),
                focusedTerminalID: terminal.id)
            terminal.tabID = tab.id
            state.tabs.append(tab)
            states[sid] = state
            let saved = tab
            persist { try await $0.save(saved) }
        }
        states[sid]?.terminals[terminal.id] = terminal
        runStates[terminal.id] = .starting
        if let parent = parentTerminal { workerPanes[parent, default: []].append(terminal.id) }
        let saved = terminal
        persist { try await $0.save(saved) }
        notify()
        launch(terminal)  // sem esperar a view: um worker numa tab escondida também precisa subir
        return terminal.id
    }

    /// O terminal da execução (o `runID` do lançamento é a identidade MCP do pai).
    func terminalOfRun(_ runID: UUID) -> Terminal? {
        for state in states.values { if let t = state.terminals.values.first(where: { $0.currentRunID == runID }) { return t } }
        return nil
    }

    /// Sinal ao processo do worker (`agent_stop`): SIGINT, SIGTERM do grupo ou SIGKILL.
    func signalWorker(terminal id: UUID, _ signal: WorkerSignal) async {
        guard let t = terminal(id) else { return }
        switch signal {
        case .interrupt: await runtime.sendInterrupt(t)
        case .terminate: await runtime.kill(t, mode: .graceful)
        case .kill: await runtime.kill(t, mode: .force)
        }
    }

    // MARK: Reabrir

    /// ⇧⌘T: a tab fechada mais recente da sessão (até 10). Os terminais voltam como novos (com `--resume` se havia ID).
    func reopenClosedTab() {
        guard let sid = currentSessionID, let store else { return }
        Task { @MainActor in
            await settlePersistence()
            let candidates = (try? await store.tabs(sessionID: sid, includeClosed: true).filter({ $0.closedAt != nil })
                .sorted(by: { ($0.closedAt ?? .distantPast) > ($1.closedAt ?? .distantPast) }).prefix(Self.reopenLimit)) ?? []
            // Uma tab fundida em outra por arrasto (F11) continua "fechada" no banco, mas seus terminais já vivem na tab de destino.
            var picked: (tab: Tab, terminals: [Terminal])?
            for candidate in candidates {
                let stored = (try? await store.terminals(tabID: candidate.id, includeDeleted: true)) ?? []
                if stored.contains(where: { candidate.layout.pane(forTerminal: $0.id) != nil }) {
                    picked = (candidate, stored)
                    break
                }
            }
            guard let (closed, stored) = picked else { return }
            closedTabIDs.remove(closed.id)
            var tab = closed
            tab.closedAt = nil
            tab.sortIndex = tabs.count
            var terminals: [Terminal] = []
            for var t in stored where tab.layout.pane(forTerminal: t.id) != nil {
                removedTerminalIDs.remove(t.id)
                t.deletedAt = nil
                t.state = .notStarted
                t.ptySessionID = nil
                t.exitCode = nil; t.exitSignal = nil; t.endedAt = nil; t.startedAt = nil
                if t.provider.isAgent, let native = t.nativeConversationID { t.launchSpec.resumeOf = native }
                terminals.append(t)
            }
            guard !terminals.isEmpty, states[sid] != nil else { return }
            states[sid]!.tabs.append(tab)
            for t in terminals {
                states[sid]!.terminals[t.id] = t
                runStates[t.id] = .starting
            }
            let saved = tab, savedTerminals = terminals
            persist { store in
                try await store.save(saved)
                for t in savedTerminals { try await store.save(t) }
            }
            recentlyOpenedTab = tab.id
            selectTab(tab.id)
        }
    }

    var hasClosedTabs: Bool {
        guard let sid = currentSessionID else { return false }
        return snapshot.tabs.contains { $0.sessionID == sid && $0.closedAt != nil }
    }

    // MARK: Lançar e religar

    /// A view do pane já tem tamanho (primeiro layout): lança o terminal novo ou religa o que o daemon manteve vivo.
    func paneReady(_ terminalID: UUID) {
        guard let t = terminal(terminalID), !launching.contains(terminalID) else { return }
        if let entry = runtime.existingEntry(for: terminalID), entry.isAttached { return }
        switch t.state {
        case .notStarted:
            launch(t)
        case .launching, .running:
            reattach(t)
        case .interrupted, .exited, .killed:
            showColdLog(of: t)
        default:
            break
        }
    }

    /// Último scrollback do cold log num pane sem processo (Interrupted ou encerrado), uma vez por view.
    private func showColdLog(of terminal: Terminal) {
        guard coldLogShown.insert(terminal.id).inserted else { return }
        runtime.showColdLog(of: terminal)
    }

    /// Duração máxima sem primeiro byte antes de mostrar o terminal mesmo assim (comando silencioso).
    static let silentLaunchFallback: Duration = .seconds(10)

    private func launch(_ terminal: Terminal, mode: LaunchMode = .automatic) {
        let id = terminal.id
        launching.insert(id)
        runStates[id] = .starting
        let agent = ProviderAdapters.name(terminal.provider)
        launchTimelines[id] = LaunchTimeline(agentName: terminal.provider.isAgent ? agent : String(localized: "Terminal", bundle: .module))
        ignitionVisible.remove(id)
        ignitionTimers[id]?.cancel()
        ignitionTimers[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(MotionTokens.Delay.ignitionSkip))
            guard !Task.isCancelled, let self, case .starting = self.paneState(id) else { return }
            self.ignitionVisible.insert(id)
            self.notify()
            try? await Task.sleep(for: Self.silentLaunchFallback)
            guard !Task.isCancelled, case .starting = self.paneState(id), self.launchTimelines[id]?.rows.last?.key == .cliExec,
                  self.launchTimelines[id]?.rows.last?.status == .running else { return }
            self.runStates[id] = .running
            self.notify()
        }
        update(terminal: id) { $0.state = .launching }
        save(terminal: id)
        Task { @MainActor in
            defer { launching.remove(id) }
            guard let current = self.terminal(id) else { return }
            let subagent = self.subagentLaunch(for: current)
            let sessionID = self.sessionID(of: current)
            do {
                let result = try await runtime.launch(
                    current, mode: mode, catalog: ProfileCatalog(userProfiles: self.snapshot.profiles), subagent: subagent, sessionID: sessionID,
                    workerOf: self.workerLaunches[id]) { [weak self] event in
                    Task { @MainActor in self?.apply(launchEvent: event, terminalID: id) }
                }
                guard self.terminal(id) != nil else { return }
                currentRuns[id] = result.runID
                if current.provider.supportsSubagentComputers { self.subagent?.noteLaunched(terminal: id, mode: subagent?.mode ?? .off) }
                launchDirectories[id] = result.plan.launchDirectory
                update(terminal: id) { t in
                    t.state = .running
                    t.ptySessionID = result.summary.sessionID.description
                    t.resolvedArgv = result.plan.argv
                    t.envKeys = result.plan.envKeys
                    t.launchSpec = result.plan.spec
                    t.nativeConversationID = result.plan.nativeConversationID ?? t.nativeConversationID
                    t.currentRunID = result.runID
                    t.startedAt = Date()
                    t.endedAt = nil
                    t.exitCode = nil
                    t.exitSignal = nil
                }
                // Continua `.starting` até o primeiro byte (`apply(launchEvent:)` → `.running`).
                save(terminal: id)
            } catch let failure as LaunchFailure {
                guard self.terminal(id) != nil, failure != .cancelled else { return }
                fail(launch: id, detail: failure.errorDescription ?? "\(failure)")
            } catch {
                guard self.terminal(id) != nil else { return }
                fail(launch: id, detail: "\(error)")
            }
            notify()
        }
    }

    /// O terminal de um worker de app terminou (saiu, não subiu, foi interrompido ou fechado): o orquestrador solta o computador.
    private func noteWorkerEnded(_ id: UUID, exitCode: Int? = nil) {
        guard let child = terminal(id)?.launchSpec.workerChildID ?? workerLaunches[id]?.childID else { return }
        onWorkerTerminalEnded?(child, exitCode)
    }

    private func fail(launch id: UUID, detail: String) {
        noteWorkerEnded(id)
        ignitionTimers[id]?.cancel()
        update(terminal: id) { $0.state = .failedToStart }
        runStates[id] = .failed(detail)
        save(terminal: id)
        notify()
    }

    /// Evento real do coordenador: atualiza a checklist, encerra a ignição no primeiro byte e captura o ID nativo.
    private func apply(launchEvent event: LaunchEvent, terminalID id: UUID) {
        guard terminal(id) != nil else { return }
        launchTimelines[id]?.apply(event)
        switch event {
        case .firstOutput:
            ignitionTimers[id]?.cancel()
            if case .starting = paneState(id) { runStates[id] = .running }
            if id == focusedTerminalID { autoFocus(runtime.existingEntry(for: id)?.host) }
        case .nativeID(_, let nativeID):
            update(terminal: id) { $0.nativeConversationID = nativeID }
            save(terminal: id)
        case .step:
            break
        }
        onLaunchEvent?(id, event)
        notify()
    }

    /// Cancel da ignição (`session.cancelLaunch` com o ID do terminal): aborta o que falta, mata a sessão criada e remove o pane.
    func cancelLaunch(_ terminalID: UUID) {
        guard terminal(terminalID) != nil else { return }
        Task { @MainActor in
            await runtime.coordinator.cancel(terminalID: terminalID)
            guard terminal(terminalID) != nil else { return }
            finalizeRemoval(of: terminalID)
        }
    }

    /// `true` se o pane ainda está na ignição (estado `starting`).
    func isIgniting(_ terminalID: UUID) -> Bool {
        if case .starting = paneState(terminalID) { return ignitionVisible.contains(terminalID) }
        return false
    }

    private func reattach(_ terminal: Terminal) {
        let id = terminal.id
        launching.insert(id)
        Task { @MainActor in
            defer { launching.remove(id) }
            switch await runtime.reattach(terminal) {
            case .attached:
                update(terminal: id) { $0.state = .running }
                runStates[id] = .running
                if id == focusedTerminalID { autoFocus(runtime.existingEntry(for: id)?.host) }
            case .exited(let summary):
                markExited(id, info: summary.exit)
            case .gone:
                markInterrupted(id)
            }
            notify()
        }
    }

    /// O processo sumiu sem `exit` (daemon morto, reboot): `interrupted`, com o motivo guardado e o scrollback do cold log.
    private func markInterrupted(_ id: UUID, reason: InterruptionReason? = nil) {
        guard let t = terminal(id) else { return }
        let why = reason ?? InterruptionClassifier.reason(
            startedAt: t.startedAt, bootTime: InterruptionClassifier.bootTime(), previousRunWasClean: nil)
        interruptionReasons[id] = why
        if why == .unexpected, t.provider.isAgent { daemonLossAgentCount += 1 }   // AC-810: o banner da janela
        update(terminal: id) { $0.state = .interrupted; $0.endedAt = $0.endedAt ?? Date() }
        runStates[id] = .interrupted
        save(terminal: id)
        noteWorkerEnded(id)
        if let store { Task { await SessionReconciler.recordInterruption(store: store, terminalID: id, reason: why) } }
        runtime.existingEntry(for: id)?.unbind()
        if let fresh = terminal(id) { showColdLog(of: fresh) }
        notify()
    }

    /// A conexão com o daemon voltou depois de cair: o que estava `running` e o daemon não conhece mais está `interrupted`.
    func verifyAfterDaemonLoss() {
        Task { @MainActor in
            let sessions = (try? await runtime.client.list()) ?? []
            let known = Dictionary(sessions.map { ($0.sessionID.description, $0) }, uniquingKeysWith: { a, _ in a })
            for t in states.values.flatMap({ $0.terminals.values }) where t.state == .running {
                switch paneState(t.id) {
                case .interrupted, .exited, .failed: continue
                default: break
                }
                if let raw = t.ptySessionID, let summary = known[raw] {
                    if summary.state != .running { markExited(t.id, info: summary.exit) }
                } else {
                    markInterrupted(t.id, reason: .unexpected)
                }
            }
        }
    }

    /// AC-810: o daemon morreu e levou os PTYs dos agentes. A faixa da janela fica enquanto houver agente `interrupted`.
    private(set) var daemonLossAgentCount = 0
    var showsDaemonLossBanner: Bool {
        daemonLossAgentCount > 0 && states.values.contains { $0.terminals.values.contains { $0.state == .interrupted && $0.provider.isAgent } }
    }

    /// Resume (06 §2.6): relança com o ID nativo e flags regeneradas, sem o prompt inicial. Sem ID: "Continue Last".
    func resume(_ terminalID: UUID) {
        guard let t = terminal(terminalID), t.provider.isAgent, !launching.contains(terminalID) else { return }
        let plan = RestorePlanner.resume(t)
        relaunch(terminalID, spec: plan.spec, mode: plan.mode, freshConversation: false)
    }

    // MARK: Retomada de agentes parados (P25)

    /// Agentes `interrupted` com ID de conversa na sessão atual: o banner "N agents stopped… · Resume All".
    var stoppedAgentsInCurrentSession: [Terminal] {
        terminalsInCurrentSession.filter { $0.state == .interrupted && $0.provider.isAgent && RestorePlanner.hasExactResume($0) }
    }

    /// Banner só com a retomada automática desligada (com ela ligada os agentes voltam sozinhos).
    @ObservationIgnored var autoResumeEnabled: () -> Bool = { true }
    /// Conversas vivas na máquina (F32). Os testes trocam por uma lista fixa.
    @ObservationIgnored var liveConversations: @Sendable () async -> Set<String> = { await LiveConversations.current() }
    var showsStoppedAgentsBanner: Bool { showsDaemonLossBanner || (!autoResumeEnabled() && !stoppedAgentsInCurrentSession.isEmpty) }

    /// `Resume All` do banner: todos os agentes parados da sessão atual voltam com `--resume`, escalonados.
    @discardableResult
    func resumeStoppedAgentsInCurrentSession(stagger: Duration = .milliseconds(300)) async -> Int {
        await resumeSelected(stoppedAgentsInCurrentSession.map(\.id), stagger: stagger).resumed
    }

    /// Agentes que "Resume Agents…" oferece na sessão `sid` (carrega a sessão se preciso): primeiro os interrompidos, depois
    /// os que saíram sozinhos, sempre com ID nativo.
    func resumableAgents(in sid: UUID) -> [Terminal] {
        load(session: sid)
        guard let state = states[sid] else { return [] }
        let all = state.tabs.flatMap { $0.layout.terminalIDs }.compactMap { state.terminals[$0] }
            .filter { $0.provider.isAgent && RestorePlanner.hasExactResume($0) }
        return all.filter { $0.state == .interrupted } + all.filter { $0.state == .exited }
    }

    /// Há agente interrompido com ID nativo na sessão (sem carregá-la): decide se "Resume Agents…" aparece.
    func hasInterruptedAgents(in sid: UUID?) -> Bool {
        let tabIDs: Set<UUID>? = sid.map { id in Set(snapshot.tabs.filter { $0.sessionID == id && $0.closedAt == nil }.map(\.id)) }
        return snapshot.terminals.contains { t in
            t.state == .interrupted && t.provider.isAgent && RestorePlanner.hasExactResume(t) && (tabIDs?.contains(t.tabID) ?? true)
        }
    }

    /// Sessão com agente interrompido mais recente (banner de perda do daemon, AC-810): quando a atual não tem nenhum, o
    /// "Resume Agents…" abre para a sessão do agente que parou por último.
    func mostRecentSessionWithInterruptedAgents() -> UUID? {
        let tabSession = Dictionary(snapshot.tabs.filter { $0.closedAt == nil }.map { ($0.id, $0.sessionID) }, uniquingKeysWith: { a, _ in a })
        return snapshot.terminals
            .filter { $0.state == .interrupted && $0.provider.isAgent && RestorePlanner.hasExactResume($0) && tabSession[$0.tabID] != nil }
            .max { ($0.endedAt ?? $0.startedAt ?? .distantPast) < ($1.endedAt ?? $1.startedAt ?? .distantPast) }
            .flatMap { tabSession[$0.tabID] }
    }

    /// Retoma os terminais escolhidos com `--resume`, escalonados. Nunca relança uma conversa que já roda em outro processo
    /// (F32): essas ficam de fora e voltam em `skippedLive`.
    func resumeSelected(_ ids: [UUID], stagger: Duration = .milliseconds(300)) async -> (resumed: Int, skippedLive: Int) {
        let live = await liveConversations()
        var eligible: [UUID] = []
        var skipped = 0
        for id in ids {
            guard let t = terminal(id) else { continue }
            if let native = RestorePlanner.nativeID(of: t), live.contains(native) { skipped += 1 } else { eligible.append(id) }
        }
        return (await resume(all: eligible, stagger: stagger), skipped)
    }

    /// Conversa do histórico (aba Conversations): tab nova, ou split à direita, com `--resume <id>` e o perfil padrão.
    @discardableResult
    func resumeConversation(_ conversation: ConversationSummary, split asSplit: Bool) -> UUID? {
        guard conversation.provider.isAgent else { return nil }
        if asSplit {
            var spec = LaunchSpec(provider: conversation.provider)
            spec.resumeOf = conversation.nativeID
            guard case .created(let id) = split(.horizontal, spec: spec) else { return nil }
            return id
        }
        return newTab(provider: conversation.provider, resumeOf: conversation.nativeID)
    }

    /// Retomada automática ao abrir (P25): só agentes com ID nativo que morreram sem o usuário pedir (nunca shells, nunca os
    /// parados de propósito). Carrega as sessões donas e relança cada um com `--resume`, 300 ms entre eles.
    @discardableResult
    func autoResume(report: ReconcileReport, stagger: Duration = .milliseconds(300)) async -> Int {
        let ids = report.interrupted.keys.filter { !report.stoppedByUser.contains($0) }
        // F32: uma conversa que já roda em outro processo (outra build, outro terminal) nunca é relançada.
        let live = await liveConversations()
        let eligible = snapshot.terminals.filter { ids.contains($0.id) && $0.provider.isAgent && RestorePlanner.hasExactResume($0) }
            .filter { RestorePlanner.nativeID(of: $0).map { !live.contains($0) } ?? true }
            .sorted { $0.createdAt < $1.createdAt }
        for t in eligible { if let sid = sessionID(of: t) { load(session: sid) } }
        return await resume(all: eligible.map(\.id), stagger: stagger)
    }

    private func resume(all ids: [UUID], stagger: Duration) async -> Int {
        var resumed = 0
        for id in ids {
            guard let t = terminal(id), t.state == .interrupted || t.state == .exited, !launching.contains(id) else { continue }
            if resumed > 0 { try? await Task.sleep(for: stagger) }
            resume(id)
            resumed += 1
        }
        return resumed
    }

    /// Start Fresh: mesma configuração, conversa nova.
    func startFresh(_ terminalID: UUID) {
        guard let t = terminal(terminalID), !launching.contains(terminalID) else { return }
        relaunch(terminalID, spec: RestorePlanner.startFresh(t), mode: .automatic, freshConversation: true)
    }

    private func relaunch(_ id: UUID, spec: LaunchSpec, mode: LaunchMode, freshConversation: Bool) {
        guard let old = terminal(id) else { return }
        let oldSession = old.ptySessionID.flatMap { SessionID(string: $0) }
        runtime.existingEntry(for: id)?.unbind()
        retire(run: id)
        interruptionReasons[id] = nil
        coldLogShown.remove(id)
        update(terminal: id) { t in
            t.state = .notStarted
            t.ptySessionID = nil
            t.exitCode = nil; t.exitSignal = nil; t.endedAt = nil
            t.launchSpec = spec
            if freshConversation { t.nativeConversationID = nil }
        }
        runStates[id] = .starting
        if let oldSession { Task { try? await runtime.client.forget(sessionID: oldSession) } }
        if let fresh = terminal(id) { launch(fresh, mode: mode) }
    }

    /// Reinicia o terminal no mesmo cwd e no mesmo pane (sem resume).
    func restart(_ terminalID: UUID) {
        guard let t = terminal(terminalID) else { return }
        runtime.existingEntry(for: terminalID)?.unbind()
        retire(run: terminalID)
        update(terminal: terminalID) { t in
            t.state = .notStarted
            t.ptySessionID = nil
            t.exitCode = nil; t.exitSignal = nil; t.endedAt = nil
        }
        runStates[terminalID] = .starting
        if let fresh = terminal(terminalID) { launch(fresh) } else { launch(t) }
    }

    // MARK: Títulos (aviso agrupado)

    @ObservationIgnored private var titleNotifyPending = false
    /// Últimos títulos OSC recebidos e ainda não aplicados ao estado (entram todos de uma vez no próximo tique).
    @ObservationIgnored private var pendingTitles: [UUID: String] = [:]

    /// Aplica os títulos do buffer ao estado (uma mutação por tique, não por quadro do spinner).
    func flushPendingTitles() {
        guard !pendingTitles.isEmpty else { return }
        let titles = pendingTitles
        pendingTitles = [:]
        for (id, text) in titles {
            guard let t = terminal(id), t.titleSource != .user, t.title != text || t.titleSource != .osc else { continue }
            update(terminal: id) { $0.title = text; $0.titleSource = .osc }
            debouncedSave(id)
        }
    }
    static let titleNotifyInterval: Duration = .milliseconds(500)

    /// Junta as mudanças de título de todos os terminais num aviso só a cada meio segundo.
    private func scheduleTitleNotify() {
        guard !titleNotifyPending else { return }
        titleNotifyPending = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.titleNotifyInterval)
            guard let self else { return }
            self.titleNotifyPending = false
            self.flushPendingTitles()
            self.notify()
        }
    }

    // MARK: Eventos do daemon

    private func handle(_ event: EventPayload, terminalID: UUID) {
        guard terminal(terminalID) != nil else { return }
        switch event {
        case .exit(let info):
            markExited(terminalID, info: info)
        case .title(let e):
            // O título do Claude Code anima (spinner) várias vezes por segundo. O título novo espera no buffer (fora da observação) e entra no estado junto com os outros a cada intervalo: mudar
            // `states` a cada quadro do spinner redesenhava a sidebar e os panes dezenas de vezes por segundo com vários agentes.
            guard let t = terminal(terminalID), t.titleSource != .user, !e.text.isEmpty else { return }
            let current = pendingTitles[terminalID] ?? (t.titleSource == .osc ? t.title : nil)
            guard e.text != current else { return }
            pendingTitles[terminalID] = e.text
            scheduleTitleNotify()
        case .cwd(let e):
            update(terminal: terminalID) { $0.cwd = e.path }
            debouncedSave(terminalID)
            onCwd?(terminalID, e.path)
        case .bell:
            onBell?(terminalID)
        case .stillAlive:
            if case .closing = paneState(terminalID) { runStates[terminalID] = .closing(stuck: true); notify() }
        case .sessionGone:
            if case .closing = paneState(terminalID) { finalizeRemoval(of: terminalID) }
        default:
            break
        }
    }

    private func markExited(_ id: UUID, info: ExitInfo?) {
        let closing: Bool
        if case .closing = paneState(id) { closing = true } else { closing = false }
        if closing {
            finalizeRemoval(of: id)
            return
        }
        let timeline = launchTimelines[id]
        if let t = terminal(id), case .starting = paneState(id) {
            // Saída com erro antes de qualquer byte: o processo nunca chegou a funcionar ("Couldn't start", M-505).
            let verdict = LaunchExitClassifier.classify(
                firstOutputSeen: timeline?.hasSeenFirstOutput ?? false, code: info?.code.map(Int.init), signal: info?.signal.map(Int.init),
                agent: ProviderAdapters.name(t.provider))
            if case .failedToStart(let detail) = verdict {
                retire(run: id)
                fail(launch: id, detail: detail)
                return
            }
        }
        ignitionTimers[id]?.cancel()
        retire(run: id)
        update(terminal: id) { t in
            t.state = info?.signal != nil ? .killed : .exited
            t.exitCode = info?.code.map(Int.init)
            t.exitSignal = info?.signal.map(Int.init)
            t.endedAt = info?.at ?? Date()
        }
        runStates[id] = .exited(code: info?.code.map(Int.init), signal: info?.signal.map(Int.init))
        save(terminal: id)
        noteWorkerEnded(id, exitCode: info?.code.map(Int.init))
        notify()
    }

    /// Fim de uma execução: apaga o diretório do lançamento (06 §2.8) e solta o estado do coordenador.
    private func retire(run terminalID: UUID) {
        ignitionTimers[terminalID]?.cancel()
        if let dir = launchDirectories.removeValue(forKey: terminalID) { LaunchFileWriter.cleanup(launchDirectory: dir) }
        // Terminal reconectado depois de reiniciar o app: o run deste processo não existe, vale o persistido (o pai adotado
        // também precisa do `endOrchestration`).
        if let run = currentRuns.removeValue(forKey: terminalID) ?? terminal(terminalID)?.currentRunID {
            let coordinator = runtime.coordinator
            Task { await coordinator.finish(runID: run) }
        }
    }

    /// Título e cwd vão para o banco no máximo a cada 3 s por terminal (o último valor). Cada gravação acorda a observação do store, que
    /// refaz a projeção da sidebar: com o spinner do Claude no título isso rodava sem parar.
    private func debouncedSave(_ id: UUID) {
        guard titleTasks[id] == nil else { return }
        titleTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            self.titleTasks[id] = nil
            self.save(terminal: id)
        }
    }
}

// MARK: Arrastar tab ou pane para a área de panes (F11)

/// O que está sendo arrastado: uma tab inteira (todos os panes dela) ou um pane (identificado pelo terminal).
enum PaneDragPayload: Hashable, Sendable {
    case tab(UUID)
    /// Pane de terminal (id do terminal).
    case pane(UUID)
    /// Pane sem terminal, como a tabela de um dataset (id do pane).
    case otherPane(UUID)
}

enum DropOutcome: Equatable, Sendable { case applied, noRoom, invalid }

extension WorkspaceModel {
    /// Resultado calculado de um drop, sem tocar no estado: o mesmo plano serve para a prévia (válido ou sem espaço) e para aplicar.
    struct DropPlan {
        var sid: UUID
        var targetTabID: UUID
        var targetLayout: PaneLayout
        var targetFocus: UUID?
        /// Mesma tab de destino quando o pane só muda de lugar dentro dela.
        var sourceTabID: UUID
        /// Layout restante da origem; `nil` = a tab de origem ficou sem panes e some.
        var sourceLayout: PaneLayout?
        var sourceFocus: UUID?
        /// Terminais que mudam de tab, com o novo `tabID`.
        var retargeted: [UUID: UUID]
        /// Split a conferir contra o mínimo de 240 × 120 (layout em que o pane de destino existe).
        var roomCheck: (layout: PaneLayout, paneID: UUID, axis: SplitAxis)?
    }

    /// Tab (e sessão) que contém o pane.
    /// O pane está sozinho na tab dele.
    func paneIsAlone(_ paneID: UUID) -> Bool { locate(paneID: paneID)?.tab.layout.leafCount == 1 }

    private func locate(paneID: UUID) -> (sid: UUID, tab: Tab)? {
        for (sid, state) in states {
            if let tab = state.tabs.first(where: { $0.layout.contains(paneID: paneID) }) { return (sid, tab) }
        }
        return nil
    }

    func planDrop(_ payload: PaneDragPayload, onTerminal targetTerminal: UUID, zone: PaneDropZone) -> DropPlan? {
        guard let (_, target) = locate(terminal: targetTerminal), let targetPane = target.layout.pane(forTerminal: targetTerminal) else { return nil }
        return planDrop(payload, onPane: targetPane.id, zone: zone)
    }

    /// Plano do drop sobre qualquer pane (terminal ou dataset): split do lado da zona ou troca no centro.
    func planDrop(_ payload: PaneDragPayload, onPane targetPaneID: UUID, zone: PaneDropZone) -> DropPlan? {
        guard let (sid, target) = locate(paneID: targetPaneID), let targetPane = target.layout.panes.first(where: { $0.id == targetPaneID }) else { return nil }
        var targetTerminal: UUID?
        if case .terminal(let id) = targetPane.content { targetTerminal = id }
        switch payload {
        case .tab(let sourceID):
            guard sourceID != target.id, let (sourceSID, source) = locate(tab: sourceID), sourceSID == sid else { return nil }
            let moving = source.layout.terminalIDs
            if let axis = zone.axis {
                guard let layout = target.layout.inserting(source.layout, beside: targetPane.id, zone: zone) else { return nil }
                return DropPlan(
                    sid: sid, targetTabID: target.id, targetLayout: layout, targetFocus: source.focusedTerminalID ?? moving.first ?? target.focusedTerminalID,
                    sourceTabID: source.id, sourceLayout: nil, sourceFocus: nil,
                    retargeted: Dictionary(uniqueKeysWithValues: moving.map { ($0, target.id) }),
                    roomCheck: (target.layout, targetPane.id, axis))
            }
            let movingPane = source.focusedTerminalID.flatMap { source.layout.pane(forTerminal: $0) } ?? source.layout.firstPane
            guard let newTarget = target.layout.replacingPane(targetPane.id, with: movingPane),
                  let newSource = source.layout.replacingPane(movingPane.id, with: targetPane)
            else { return nil }
            var retarget: [UUID: UUID] = [:]
            if let targetTerminal { retarget[targetTerminal] = source.id }
            var movedTerminal: UUID?
            if case .terminal(let id) = movingPane.content { retarget[id] = target.id; movedTerminal = id }
            let sourceFocus = source.focusedTerminalID == movedTerminal ? targetTerminal : source.focusedTerminalID
            return DropPlan(
                sid: sid, targetTabID: target.id, targetLayout: newTarget, targetFocus: movedTerminal ?? target.focusedTerminalID,
                sourceTabID: source.id, sourceLayout: newSource, sourceFocus: sourceFocus, retargeted: retarget, roomCheck: nil)
        case .pane, .otherPane:
            let found: (sid: UUID, tab: Tab, pane: Pane)?
            switch payload {
            case .pane(let terminalID):
                found = locate(terminal: terminalID).flatMap { hit in hit.tab.layout.pane(forTerminal: terminalID).map { (hit.sid, hit.tab, $0) } }
            case .otherPane(let paneID):
                found = locate(paneID: paneID).flatMap { hit in hit.tab.layout.panes.first { $0.id == paneID }.map { (hit.sid, hit.tab, $0) } }
            case .tab: found = nil
            }
            guard let (sourceSID, source, movingPane) = found, sourceSID == sid, movingPane.id != targetPane.id else { return nil }
            var movingTerminal: UUID?
            if case .terminal(let id) = movingPane.content { movingTerminal = id }
            let sameTab = source.id == target.id
            if let axis = zone.axis {
                if sameTab {
                    guard let base = target.layout.removing(paneID: movingPane.id),
                          let layout = base.inserting(.leaf(movingPane), beside: targetPane.id, zone: zone)
                    else { return nil }
                    return DropPlan(
                        sid: sid, targetTabID: target.id, targetLayout: layout, targetFocus: movingTerminal ?? target.focusedTerminalID,
                        sourceTabID: source.id, sourceLayout: nil, sourceFocus: nil, retargeted: [:], roomCheck: (base, targetPane.id, axis))
                }
                guard let layout = target.layout.inserting(.leaf(movingPane), beside: targetPane.id, zone: zone) else { return nil }
                let remaining = source.layout.removing(paneID: movingPane.id)
                var sourceFocus = source.focusedTerminalID
                if let movingTerminal, sourceFocus == movingTerminal, let remaining {
                    let successor = source.layout.focusSuccessor(afterRemoving: movingPane.id)
                    if case .terminal(let id)? = successor?.content { sourceFocus = id } else { sourceFocus = remaining.terminalIDs.first }
                }
                return DropPlan(
                    sid: sid, targetTabID: target.id, targetLayout: layout, targetFocus: movingTerminal ?? target.focusedTerminalID,
                    sourceTabID: source.id, sourceLayout: remaining, sourceFocus: sourceFocus,
                    retargeted: movingTerminal.map { [$0: target.id] } ?? [:], roomCheck: (target.layout, targetPane.id, axis))
            }
            if sameTab {
                guard let layout = target.layout.swappingPanes(movingPane.id, targetPane.id) else { return nil }
                return DropPlan(
                    sid: sid, targetTabID: target.id, targetLayout: layout, targetFocus: movingTerminal ?? target.focusedTerminalID,
                    sourceTabID: source.id, sourceLayout: nil, sourceFocus: nil, retargeted: [:], roomCheck: nil)
            }
            guard let newTarget = target.layout.replacingPane(targetPane.id, with: movingPane),
                  let newSource = source.layout.replacingPane(movingPane.id, with: targetPane)
            else { return nil }
            let sourceFocus = movingTerminal != nil && source.focusedTerminalID == movingTerminal ? targetTerminal : source.focusedTerminalID
            var retarget: [UUID: UUID] = [:]
            if let movingTerminal { retarget[movingTerminal] = target.id }
            if let targetTerminal { retarget[targetTerminal] = source.id }
            return DropPlan(
                sid: sid, targetTabID: target.id, targetLayout: newTarget, targetFocus: movingTerminal ?? target.focusedTerminalID,
                sourceTabID: source.id, sourceLayout: newSource, sourceFocus: sourceFocus, retargeted: retarget, roomCheck: nil)
        }
    }

    // MARK: Tab ativa arrastada sobre o próprio conteúdo

    /// Parceira do arrasto da tab ativa: a outra tab da sessão usada há menos tempo; sem histórico, a vizinha na tab row.
    func selfDropPartner(of tabID: UUID) -> Tab? {
        guard let (sid, source) = locate(tab: tabID), let state = states[sid], let i = state.tabs.firstIndex(where: { $0.id == source.id }) else { return nil }
        let others = state.recent.filter { $0 != tabID }
        for id in others { if let tab = state.tabs.first(where: { $0.id == id }) { return tab } }
        if state.tabs.indices.contains(i + 1) { return state.tabs[i + 1] }
        return i > 0 ? state.tabs[i - 1] : nil
    }

    /// Plano do drop da tab ativa sobre o próprio conteúdo: os panes dela entram no lado `zone` do layout inteiro da parceira
    /// (50/50) e a tab some. Nil sem parceira, no centro, ou se a tab arrastada não é a ativa.
    func planSelfDrop(_ tabID: UUID, zone: PaneDropZone) -> DropPlan? {
        guard tabID == activeTabID, let axis = zone.axis, let (sid, source) = locate(tab: tabID), let partner = selfDropPartner(of: tabID),
              source.layout.isValid
        else { return nil }
        let moving = source.layout.terminalIDs
        guard Set(partner.layout.panes.map(\.id)).isDisjoint(with: Set(source.layout.panes.map(\.id))),
              Set(partner.layout.terminalIDs).isDisjoint(with: Set(moving))
        else { return nil }
        let layout: PaneLayout = zone.insertsFirst
            ? .split(axis: axis, ratio: 0.5, first: source.layout, second: partner.layout)
            : .split(axis: axis, ratio: 0.5, first: partner.layout, second: source.layout)
        return DropPlan(
            sid: sid, targetTabID: partner.id, targetLayout: layout, targetFocus: source.focusedTerminalID ?? moving.first,
            sourceTabID: source.id, sourceLayout: nil, sourceFocus: nil,
            retargeted: Dictionary(uniqueKeysWithValues: moving.map { ($0, partner.id) }), roomCheck: nil)
    }

    /// Prévia do drop da tab ativa sobre o próprio conteúdo: `.invalid` esconde as zonas.
    func evaluateSelfDrop(_ tabID: UUID, zone: PaneDropZone) -> DropOutcome {
        planSelfDrop(tabID, zone: zone) == nil ? .invalid : .applied
    }

    /// Aplica pelo mesmo caminho do drop de tab em tab (`apply`): terminais e processos seguem, a parceira vira a ativa.
    @discardableResult
    func performSelfDrop(_ tabID: UUID, zone: PaneDropZone) -> DropOutcome {
        guard let plan = planSelfDrop(tabID, zone: zone) else { return .invalid }
        apply(plan)
        return .applied
    }

    private func hasRoom(_ plan: DropPlan) -> Bool {
        guard let check = plan.roomCheck, contentSize != .zero else { return true }
        return check.layout.canSplit(paneID: check.paneID, axis: check.axis, in: CGRect(origin: .zero, size: contentSize))
    }

    /// Simulação do drop (prévia): aplicável, sem espaço (240 × 120) ou inválido.
    func evaluateDrop(_ payload: PaneDragPayload, onTerminal target: UUID, zone: PaneDropZone) -> DropOutcome {
        guard let plan = planDrop(payload, onTerminal: target, zone: zone) else { return .invalid }
        return hasRoom(plan) ? .applied : .noRoom
    }

    func evaluateDrop(_ payload: PaneDragPayload, onPane target: UUID, zone: PaneDropZone) -> DropOutcome {
        guard let plan = planDrop(payload, onPane: target, zone: zone) else { return .invalid }
        return hasRoom(plan) ? .applied : .noRoom
    }

    /// Aplica o drop: split do lado escolhido com a tab ou o pane arrastado, ou troca de lugar no centro. Os terminais não são
    /// recriados (as views e as sessões do daemon seguem), há um único `notify` e a persistência sai na ordem normal.
    @discardableResult
    func performDrop(_ payload: PaneDragPayload, onTerminal target: UUID, zone: PaneDropZone) -> DropOutcome {
        guard let (_, tab) = locate(terminal: target), let pane = tab.layout.pane(forTerminal: target) else { return .invalid }
        return performDrop(payload, onPane: pane.id, zone: zone)
    }

    @discardableResult
    func performDrop(_ payload: PaneDragPayload, onPane target: UUID, zone: PaneDropZone) -> DropOutcome {
        guard let plan = planDrop(payload, onPane: target, zone: zone) else { return .invalid }
        guard hasRoom(plan) else {
            toasts?.show(kind: .info, title: String(localized: "Not enough room to split. Close a pane or widen the window.", bundle: .module))
            return .noRoom
        }
        apply(plan)
        return .applied
    }

    private func apply(_ plan: DropPlan) {
        guard var state = states[plan.sid], let ti = state.tabs.firstIndex(where: { $0.id == plan.targetTabID }) else { return }
        // Uma tab que era só de um dataset e passa a ter agentes (troca no centro) não leva o nome do dataset: volta ao automático.
        let wasDatasetOnly = Set(state.tabs.filter { datasetOnly($0) != nil }.map(\.id))
        defer {
            for id in [plan.targetTabID, plan.sourceTabID] where wasDatasetOnly.contains(id) {
                if let t = tab(id), !t.layout.terminalIDs.isEmpty, t.titleLocked { resetTitle(id) }
            }
        }
        state.tabs[ti].layout = plan.targetLayout
        state.tabs[ti].focusedTerminalID = plan.targetFocus
        var closed: Tab?
        let sameTab = plan.sourceTabID == plan.targetTabID
        if !sameTab, let si = state.tabs.firstIndex(where: { $0.id == plan.sourceTabID }) {
            if let remaining = plan.sourceLayout {
                state.tabs[si].layout = remaining
                state.tabs[si].focusedTerminalID = plan.sourceFocus
            } else {
                var gone = state.tabs.remove(at: si)
                gone.closedAt = Date()
                closedTabIDs.insert(gone.id)
                state.recent.removeAll { $0 == gone.id }
                closed = gone
            }
        }
        for (terminalID, tabID) in plan.retargeted { state.terminals[terminalID]?.tabID = tabID }
        let moved = plan.retargeted.keys.compactMap { state.terminals[$0] }
        let sourceStillThere = !sameTab && plan.sourceLayout != nil
        if activeTabIDs[plan.sid] != plan.targetTabID {
            activeTabIDs[plan.sid] = plan.targetTabID
            state.recent.removeAll { $0 == plan.targetTabID }
            state.recent.insert(plan.targetTabID, at: 0)
            saveUIState()
        }
        states[plan.sid] = state
        expandedPanes[plan.targetTabID] = nil
        expandedPanes[plan.sourceTabID] = nil
        persist { store in for t in moved { try await store.save(t) } }
        saveLayout(of: plan.targetTabID, final: true)
        if sourceStillThere { saveLayout(of: plan.sourceTabID, final: true) }
        if let closed { persist { try await $0.save(closed) } }
        if let focus = plan.targetFocus { pulse(focus) }
        notify()
        returnFocusToTerminal()
    }

    /// Arranca o pane da tab (`terminalID`) para uma tab própria, na posição `index` (padrão: logo à direita da tab de origem).
    @discardableResult
    func detachPane(_ terminalID: UUID, toIndex index: Int? = nil) -> DropOutcome {
        guard let (sid, source) = locate(terminal: terminalID), source.layout.leafCount > 1,
              let pane = source.layout.pane(forTerminal: terminalID), let remaining = source.layout.removing(paneID: pane.id),
              var state = states[sid], let si = state.tabs.firstIndex(where: { $0.id == source.id }), var terminal = state.terminals[terminalID]
        else { return .invalid }
        let position = min(max(index ?? si + 1, 0), state.tabs.count)
        let tabID = UUID.v7()
        var sourceFocus = source.focusedTerminalID
        if sourceFocus == terminalID {
            if case .terminal(let id)? = source.layout.focusSuccessor(afterRemoving: pane.id)?.content { sourceFocus = id } else { sourceFocus = remaining.terminalIDs.first }
        }
        state.tabs[si].layout = remaining
        state.tabs[si].focusedTerminalID = sourceFocus
        let tab = Tab(id: tabID, sessionID: sid, title: terminal.title, sortIndex: position, layout: .leaf(pane), focusedTerminalID: terminalID)
        state.tabs.insert(tab, at: position)
        for i in state.tabs.indices { state.tabs[i].sortIndex = i }
        terminal.tabID = tabID
        state.terminals[terminalID] = terminal
        state.recent.removeAll { $0 == tabID }
        state.recent.insert(tabID, at: 0)
        states[sid] = state
        activeTabIDs[sid] = tabID
        expandedPanes[source.id] = nil
        let saved = state.tabs, movedTerminal = terminal
        persist { store in
            for t in saved { try await store.save(t) }
            try await store.save(movedTerminal)
        }
        saveUIState()
        recentlyOpenedTab = tabID
        pulse(terminalID)
        notify()
        returnFocusToTerminal()
        return .applied
    }

    /// Arranca um pane sem terminal (dataset) para uma tab própria na posição `index`.
    @discardableResult
    func detachPane(paneID: UUID, toIndex index: Int? = nil) -> DropOutcome {
        guard let (sid, source) = locate(paneID: paneID), source.layout.leafCount > 1,
              let pane = source.layout.panes.first(where: { $0.id == paneID }), let remaining = source.layout.removing(paneID: paneID),
              var state = states[sid], let si = state.tabs.firstIndex(where: { $0.id == source.id })
        else { return .invalid }
        let position = min(max(index ?? si + 1, 0), state.tabs.count)
        state.tabs[si].layout = remaining
        let tab = Tab(sessionID: sid, title: paneTitle(pane), sortIndex: position, layout: .leaf(pane), focusedTerminalID: nil)
        state.tabs.insert(tab, at: position)
        for i in state.tabs.indices { state.tabs[i].sortIndex = i }
        state.recent.removeAll { $0 == tab.id }
        state.recent.insert(tab.id, at: 0)
        states[sid] = state
        activeTabIDs[sid] = tab.id
        expandedPanes[source.id] = nil
        let saved = state.tabs
        persist { store in for t in saved { try await store.save(t) } }
        saveUIState()
        recentlyOpenedTab = tab.id
        notify()
        return .applied
    }

    // MARK: Datasets em panes

    /// Título de um pane sem terminal (o nome do dataset).
    func paneTitle(_ pane: Pane) -> String {
        switch pane.content {
        case .dataset(let id): datasetTitle(id) ?? String(localized: "Dataset", bundle: .module)
        case .computer(let name): computerTitle(name)
        case .notebook(let id): notebookTitle(id)
        case .traffic(let name): trafficTitle(name)
        default: ""
        }
    }

    /// `Notebook · lisboa_freguesias`: a tab diz o que é.
    func notebookTitle(_ id: String) -> String { String(localized: "Notebook · \(id)", bundle: .module) }

    /// Abre o notebook na sessão atual como uma tab (ou ao lado do agente): foca a que já existe. `nil` sem sessão aberta.
    @discardableResult
    func openNotebook(_ id: String, beside: Bool = false) -> UUID? { openSingle(.notebook(id), title: notebookTitle(id), beside: beside) }

    /// `Traffic · booking-lisbon`.
    func trafficTitle(_ name: String) -> String { String(localized: "Traffic · \(name)", bundle: .module) }

    /// Abre a tela Traffic de um computador na sessão atual (ao lado do agente por padrão).
    @discardableResult
    func openTraffic(_ name: String, beside: Bool = true) -> UUID? { openSingle(.traffic(name), title: trafficTitle(name), beside: beside) }

    /// Um pane sem terminal numa tab própria (ou ao lado do agente); se já existe na sessão, foca. `nil` sem sessão aberta.
    private func openSingle(_ content: PaneContent, title: String, beside: Bool) -> UUID? {
        guard let sid = currentSessionID, var state = states[sid] else { return nil }
        for tab in state.tabs {
            if let pane = tab.layout.panes.first(where: { $0.content == content }) {
                if beside, let active = activeTab, active.id != tab.id, tab.layout.leafCount == 1, !active.layout.terminalIDs.isEmpty,
                   placeBeside(tab.id, in: active) { return pane.id }
                selectTab(tab.id)
                return pane.id
            }
        }
        let pane = Pane(content: content)
        let agents = activeTab.flatMap { $0.layout.terminalIDs.isEmpty ? nil : $0 }
        let own = Tab(sessionID: sid, title: title, sortIndex: state.tabs.count, layout: .leaf(pane), focusedTerminalID: nil)
        state.tabs.append(own)
        states[sid] = state
        let saved = own
        persist { try await $0.save(saved) }
        if beside, let agents, placeBeside(own.id, in: agents) { return pane.id }
        recentlyOpenedTab = own.id
        selectTab(own.id)
        return pane.id
    }

    /// Tab e pane que já mostram o dataset nesta sessão.
    func datasetPane(_ datasetID: String, in sid: UUID) -> (tab: Tab, pane: Pane)? {
        for tab in states[sid]?.tabs ?? [] {
            if let pane = tab.layout.pane(forDataset: datasetID) { return (tab, pane) }
        }
        return nil
    }

    /// Abre o dataset na sessão atual: foca a tab que já o mostra, senão cria uma tab própria. `beside` coloca a tabela à direita
    /// do pane focado da tab ativa (tela dividida com o agente); se ela já estava numa tab sozinha, essa tab se junta à ativa.
    @discardableResult
    func openDataset(_ datasetID: String, beside: Bool = false) -> UUID? {
        guard let sid = currentSessionID, states[sid] != nil else { return nil }
        if let (tab, pane) = datasetPane(datasetID, in: sid) {
            // Ao lado do agente: a tab ativa, ou (se a ativa é a do próprio dataset) a tab de agentes usada por último.
            let agents = activeTab.flatMap { $0.id != tab.id ? $0 : nil }
                ?? states[sid]?.recent.lazy.compactMap { id in self.states[sid]?.tabs.first { $0.id == id && !$0.layout.terminalIDs.isEmpty } }.first
                ?? states[sid]?.tabs.first { !$0.layout.terminalIDs.isEmpty }
            if beside, let active = agents, active.id != tab.id, tab.layout.leafCount == 1, placeBeside(tab.id, in: active) {
                return pane.id
            }
            selectTab(tab.id)
            return pane.id
        }
        let pane = Pane(content: .dataset(datasetID))
        if beside, let active = activeTab, !active.layout.terminalIDs.isEmpty {
            // Abre numa tab própria e leva para o lado do agente; sem espaço na tela, fica na tab própria (com o aviso).
            guard var state = states[sid] else { return nil }
            let own = Tab(sessionID: sid, title: paneTitle(pane), sortIndex: state.tabs.count, layout: .leaf(pane), focusedTerminalID: nil)
            state.tabs.append(own)
            states[sid] = state
            let saved = own
            persist { try await $0.save(saved) }
            if !placeBeside(own.id, in: active) { selectTab(own.id) }
            return pane.id
        }
        guard var state = states[sid] else { return nil }
        let tab = Tab(sessionID: sid, title: paneTitle(pane), sortIndex: state.tabs.count, layout: .leaf(pane), focusedTerminalID: nil)
        state.tabs.append(tab)
        states[sid] = state
        let saved = tab
        persist { try await $0.save(saved) }
        recentlyOpenedTab = tab.id
        selectTab(tab.id)
        return pane.id
    }

    /// Leva a tab do dataset para o lado de um pane da tab de agentes: à direita do pane focado, senão embaixo dele, senão ao lado
    /// do maior pane da tab. Só avisa "sem espaço" quando nenhum lugar cabe.
    private func placeBeside(_ datasetTab: UUID, in agents: Tab) -> Bool {
        let area = CGRect(origin: .zero, size: contentSize == .zero ? CGSize(width: 1600, height: 1000) : contentSize)
        let frames = agents.layout.arrangement(in: area).panes
        let byArea = agents.layout.panes.map(\.id).sorted { (frames[$0].map { $0.width * $0.height } ?? 0) > (frames[$1].map { $0.width * $0.height } ?? 0) }
        let candidates = (focusedPaneID(of: agents).map { [$0] } ?? []) + byArea
        for target in candidates {
            for zone in [PaneDropZone.right, .bottom] {
                guard let plan = planDrop(.tab(datasetTab), onPane: target, zone: zone), hasRoom(plan) else { continue }
                apply(plan)
                return true
            }
        }
        toasts?.show(kind: .info, title: String(localized: "Not enough room to split. Close a pane or widen the window.", bundle: .module))
        return false
    }

    /// Tab e pane que já mostram a tela de um computador nesta sessão.
    func computerPane(_ name: String, in sid: UUID) -> (tab: Tab, pane: Pane)? {
        for tab in states[sid]?.tabs ?? [] {
            if let pane = tab.layout.panes.first(where: { $0.content == .computer(name) }) { return (tab, pane) }
        }
        return nil
    }

    /// Abre a tela de um computador na sessão atual como uma tab (ou ao lado do agente): foca a que já existe.
    @discardableResult
    func openComputer(_ name: String, beside: Bool = false) -> UUID? {
        guard let sid = currentSessionID, var state = states[sid] else { return nil }
        if let (tab, pane) = computerPane(name, in: sid) {
            if beside, let active = activeTab, active.id != tab.id, tab.layout.leafCount == 1, !active.layout.terminalIDs.isEmpty,
               placeBeside(tab.id, in: active) { return pane.id }
            selectTab(tab.id)
            return pane.id
        }
        let pane = Pane(content: .computer(name))
        let agents = activeTab.flatMap { $0.layout.terminalIDs.isEmpty ? nil : $0 }
        let own = Tab(sessionID: sid, title: computerTitle(name), sortIndex: state.tabs.count, layout: .leaf(pane), focusedTerminalID: nil)
        state.tabs.append(own)
        states[sid] = state
        let saved = own
        persist { try await $0.save(saved) }
        if beside, let agents, placeBeside(own.id, in: agents) { return pane.id }
        recentlyOpenedTab = own.id
        selectTab(own.id)
        return pane.id
    }

    /// Pane focado da tab: o do terminal focado, senão o primeiro.
    private func focusedPaneID(of tab: Tab) -> UUID? {
        if let id = tab.focusedTerminalID, let pane = tab.layout.pane(forTerminal: id) { return pane.id }
        return tab.layout.firstPane.id
    }

    /// Fecha um pane sem terminal: sai do layout (o irmão ocupa o lugar); se era o único pane, a tab fecha.
    func closePane(id paneID: UUID) {
        guard let (sid, tab) = locate(paneID: paneID) else { return }
        if let layout = tab.layout.removing(paneID: paneID) {
            update(tab: tab.id) { $0.layout = layout }
            if expandedPanes[tab.id] == paneID { expandedPanes[tab.id] = nil }
            saveLayout(of: tab.id, final: true)
            if tab.id == activeTabID { focusTerminalOfActiveTab() }
        } else {
            removeTab(tab.id, in: sid)
        }
        notify()
    }

    /// Ids de todos os panes das tabs carregadas (a área de panes descarta as views dos que sumiram).
    var allPaneIDs: Set<UUID> { Set(states.values.flatMap { $0.tabs.flatMap { $0.layout.panes.map(\.id) } }) }

    /// Panes sem terminal da tab ativa, com o quadro de cada um (a área de panes desenha as views deles).
    var datasetPanesOfActiveTab: [Pane] {
        activeTab?.layout.panes.filter { if case .dataset = $0.content { true } else { false } } ?? []
    }

    /// O teclado volta ao terminal depois de qualquer arrasto (a view nova só existe depois do próximo layout).
    func returnFocusToTerminal() {
        focusTerminalOfActiveTab()
        DispatchQueue.main.async { [weak self] in self?.focusTerminalOfActiveTab() }
    }
}

extension ProcessTree {
    /// Nome do primeiro processo filho de `pid` (para "`pnpm test` is still running").
    static func firstChildName(of pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [Int32](repeating: 0, count: 16)
        let bytes = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<Int32>.size))
        guard bytes > 0 else { return nil }
        var name = [CChar](repeating: 0, count: 256)
        guard proc_name(buffer[0], &name, UInt32(name.count)) > 0 else { return nil }
        return String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
