import RackyCore
import RackyDesignSystem
import RackyProtocol
import RackyStore
import RackyPlatform
import AppKit
import Foundation

/// Pedido de `session.launch` (automação e testes; o composer de T1-20 monta o mesmo pedido).
struct SessionLaunchRequest: Codable, Equatable {
    var provider: String?
    var prompt: String?
    var model: String?
    var name: String?
    var cwd: String?
    var args: [String]?
    /// `provider: custom`: comando livre (argv sem interpolação). Para testes e evidência com CLI falso.
    var argv: [String]?
    /// Origem do chip (centro do botão "Create Session"), em pontos da janela com y do topo. Padrão: base da janela.
    var origin: [Double]?
    /// `off`, `ask` ou `full` (F12); sem o campo vale o padrão de Settings › Computers.
    var subagentComputers: String?
    var subagentHarness: String?
}

/// Cria uma sessão limpa com o agente escolhido já rodando (P9, M-501): linha pendente na sidebar, chip voando até ela,
/// tab com o terminal em ignição e, quando o terminal existe, o card pronto no lugar da linha pendente. O lançamento em si
/// é do `LaunchCoordinator` (via `WorkspaceModel`); aqui só orquestra a UI em volta dele.
@MainActor
final class SessionLauncher {
    private let sidebar: SidebarModel
    private let workspace: WorkspaceModel
    private let elements: UIElementStore
    /// Raiz das pastas de sessões limpas (Settings › General › Clean session folder; padrão `~/Racky/sessions`).
    private let sessionsRoot: () -> URL
    private var store: RackyStore?
    private var service: SessionCreationService?
    private let git: GitService
    /// Configuração (agente e perfil padrão, pastas de sessão); ligada pelo `AppEnvironment`.
    weak var settings: SettingsModel?
    /// Pedido de cada linha pendente do composer, para Try Again e as ações alternativas.
    private var jobs: [UUID: CreationJob] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var submitTimes: [UUID: ContinuousClock.Instant] = [:]
    /// Último tempo medido do submit até o primeiro byte do agente, em ms (log e testes).
    private(set) var lastSubmitToOutputMs: Int?
    private let log = LogFacade(.app, category: "launcher")
    /// Terminal -> linha pendente que acompanha o lançamento.
    private var pendingByTerminal: [UUID: UUID] = [:]
    private var pendingStart: [UUID: Date] = [:]
    private var agentNames: [UUID: String] = [:]
    /// Tempo mínimo da linha pendente (o chip precisa pousar nela, M-501).
    static let minimumPendingDuration: TimeInterval = 0.62

    /// Pedido de criação pendente de uma linha da sidebar.
    struct CreationJob {
        var request: SessionCreationRequest
        var projectID: UUID?
        var origin: [Double]?
    }

    init(sidebar: SidebarModel, workspace: WorkspaceModel, elements: UIElementStore, sessionsRoot: @escaping () -> URL, git: GitService = GitService()) {
        self.git = git
        self.sidebar = sidebar
        self.workspace = workspace
        self.elements = elements
        self.sessionsRoot = sessionsRoot
        workspace.onLaunchEvent = { [weak self] terminalID, event in self?.follow(event, terminalID: terminalID) }
    }

    func attach(store: RackyStore) {
        self.store = store
        service = SessionCreationService(store: store, git: git)
    }

    func register(in registry: ActionRegistry) throws {
        for (action, mode) in [(ActionID.sessionRetryLaunch, RetryMode.tryAgain), (.sessionUseExistingBranch, .useExistingBranch), (.sessionCreateWithoutFetch, .createWithoutFetching)] {
            try registry.register(action) { [unowned self] arg in
                guard arg.kind == .select, let raw = arg.value, let id = UUID(uuidString: raw) else {
                    throw ActionError.failed(action, message: "expected select(<pending id>)")
                }
                guard retry(id, mode: mode) else { throw ActionError.failed(action, message: "Nothing to retry") }
                return "retrying"
            }
        }
        sidebar.onCancelPending = { [weak self] id in self?.cancelPending(id) }
        sidebar.onDiscardPending = { [weak self] id in self?.discardPending(id) }
        try registry.register(.sessionLaunch) { [unowned self] arg in
            guard arg.kind == .set, let raw = arg.value, let data = raw.data(using: .utf8),
                  let request = try? JSONDecoder().decode(SessionLaunchRequest.self, from: data) else {
                throw ActionError.failed(.sessionLaunch, message: "expected set(<json>) with provider, prompt, model, name, cwd, args, argv")
            }
            return try await launch(request)
        }
    }

    /// Devolve um JSON com `sessionID`, `tabID` e `terminalID`.
    func launch(_ request: SessionLaunchRequest) async throws -> String {
        guard let store else { throw ActionError.failed(.sessionLaunch, message: "The store isn't open yet") }
        let provider = TerminalProvider(rawValue: request.provider ?? "claude") ?? .claude
        let prompt = request.prompt.flatMap { $0.isEmpty ? nil : $0 }
        let sessionID = UUID.v7(), tabID = UUID.v7(), terminalID = UUID.v7(), pendingID = UUID.v7()
        // Pasta: sem `cwd` o app cria `<raiz>/<nome-automático>` (nunca reaproveita uma pasta existente, AC-1102); com `cwd` usa a pasta
        // escolhida e não cria nem apaga nada nela (AC-1105).
        let folder: URL
        let managed: Bool
        if let cwd = request.cwd, !cwd.isEmpty {
            folder = URL(fileURLWithPath: cwd, isDirectory: true)
            guard CleanSessionFolders.isDirectory(folder.path) else {
                throw ActionError.failed(.sessionLaunch, message: "\(folder.path) isn't a folder")
            }
            managed = false
        } else {
            do { folder = try CleanSessionFolders.createManaged(root: sessionsRoot()) } catch {
                throw ActionError.failed(.sessionLaunch, message: "Couldn't create the session folder: \(error.localizedDescription)")
            }
            managed = true
        }
        let title = Self.title(name: request.name, prompt: prompt, provider: provider, folder: folder)

        // 1. Linha pendente (M-501): a sessão fica escondida da lista até o terminal existir.
        let agent = ProviderAdapters.name(provider)
        sidebar.beginPending(PendingLaunch(id: pendingID, name: title, projectID: nil, phase: .preparing, sessionID: sessionID))
        pendingByTerminal[terminalID] = pendingID
        pendingStart[pendingID] = Date()
        agentNames[pendingID] = agent
        flyChip(provider: provider, title: title, origin: request.origin, pendingID: pendingID)

        // 2. Sessão, tab e terminal no Store; o terminal é lançado quando o pane tem tamanho.
        let spec = LaunchSpec(provider: provider, profileID: provider.isAgent ? settings?.defaultProfile(for: provider)?.id : nil, model: request.model, extraArgs: request.args ?? [], customArgv: request.argv, initialPrompt: prompt)
        var session = Session(id: sessionID, kind: .clean, folderPath: folder.path, title: title)
        session.managedFolder = managed
        if provider.supportsSubagentComputers {
            session.subagentComputers = request.subagentComputers.flatMap(SubagentComputersMode.init(rawValue:))
                ?? settings?.settings.computers.defaultSubagentMode ?? .ask
            session.subagentHarness = request.subagentHarness.flatMap(SubagentHarness.init(rawValue:))
                ?? settings?.settings.computers.defaultSubagentHarness ?? .claude
        }
        let terminal = Terminal(id: terminalID, tabID: tabID, provider: provider, title: title, cwd: folder.path, launchSpec: spec)
        let tab = Tab(id: tabID, sessionID: sessionID, title: title, layout: .leaf(Pane(content: .terminal(terminalID))), focusedTerminalID: terminalID)
        do {
            try await store.saveBundle(session: session, tabs: [tab], terminals: [terminal])
        } catch {
            sidebar.finish(pending: pendingID)
            throw ActionError.failed(.sessionLaunch, message: "\(error)")
        }
        // 3. Seleciona assim que o snapshot do Store traz a sessão; o workspace carrega as tabs e lança o terminal.
        for _ in 0 ..< 500 where !sidebar.select(sessionID) { try? await Task.sleep(for: .milliseconds(20)) }
        let payload: [String: String] = ["sessionID": sessionID.uuidString, "tabID": tabID.uuidString, "terminalID": terminalID.uuidString, "pendingID": pendingID.uuidString]
        let json = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) }
        return json ?? sessionID.uuidString
    }

    private func flyChip(provider: TerminalProvider, title: String, origin: [Double]?, pendingID: UUID) {
        guard let window = elements.window else { return }
        let bounds = window.contentView?.bounds ?? .zero
        let from: CGRect
        if let origin, origin.count == 2 {
            from = CGRect(x: origin[0], y: origin[1], width: 0, height: 0)
        } else {
            from = CGRect(x: bounds.midX, y: bounds.height - DS.Space.s10 * 2, width: 0, height: 0)
        }
        Task { @MainActor in
            // A linha pendente precisa ter sido desenhada (e registrada) para o chip saber onde pousar.
            var target: CGRect?
            for _ in 0 ..< 40 {
                target = elements.frame(of: .sidebarPending(pendingID.uuidString))
                if let target, target.width > 0 { break }
                try? await Task.sleep(for: .milliseconds(25))
            }
            guard let target else { return }
            LaunchChipFlight.play(in: window, from: from, to: target, provider: provider, title: title)
        }
    }

    /// Eventos reais do coordenador movem a fase da linha pendente; ao criar o PTY, ela vira o card (M-501 `T_ready`).
    private func follow(_ event: LaunchEvent, terminalID: UUID) {
        guard let pendingID = pendingByTerminal[terminalID] else { return }
        if case .firstOutput = event, let start = submitTimes.removeValue(forKey: pendingID) {
            let elapsed = ContinuousClock.now - start
            let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            lastSubmitToOutputMs = ms
            log.info("composer submit to first output: \(ms) ms")
        }
        guard case .step(let progress) = event else { return }
        let agent = agentNames[pendingID] ?? ""
        switch (progress.step, progress.status) {
        case (.gitFetch, .running): sidebar.advance(pending: pendingID, to: .fetching)
        case (.gitWorktree, .running): sidebar.advance(pending: pendingID, to: .creatingWorktree)
        case (.ptySpawn, .running), (.cliExec, .running): sidebar.advance(pending: pendingID, to: .startingAgent(agent))
        case (.ptySpawn, .done): ready(pendingID, terminalID: terminalID)
        case (_, .failed): ready(pendingID, terminalID: terminalID)  // o pane mostra "Couldn't start"; a sessão existe
        default: break
        }
    }

    private func ready(_ pendingID: UUID, terminalID: UUID) {
        guard pendingStart[pendingID] != nil else { return }
        let elapsed = Date().timeIntervalSince(pendingStart[pendingID] ?? Date())
        let wait = MotionPolicy.shared.reduceMotion ? 0 : max(0, Self.minimumPendingDuration - elapsed)
        pendingStart[pendingID] = nil
        pendingByTerminal[terminalID] = nil
        Task { @MainActor in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            sidebar.finish(pending: pendingID)
            agentNames[pendingID] = nil
            jobs[pendingID] = nil
            tasks[pendingID] = nil
        }
    }

    // MARK: Criação pelo composer (T1-20)

    enum RetryMode { case tryAgain, useExistingBranch, createWithoutFetching }

    /// Cria a linha pendente na hora (P9), voa o chip e continua em segundo plano: worktree (fetch + add), gravação no Store,
    /// seleção da sessão. O workspace lança o agente quando o pane tem tamanho e o `follow` fecha a linha pendente.
    @discardableResult
    func begin(_ request: SessionCreationRequest, projectID: UUID?, origin: [Double]? = nil) -> UUID {
        let pendingID = UUID.v7()
        let provider = request.spec.provider
        let pending = PendingLaunch(id: pendingID, name: request.title, projectID: projectID, phase: .preparing, sessionID: request.sessionID, provider: provider)
        sidebar.beginPending(pending)
        sidebar.focus(pending: pendingID)
        pendingByTerminal[request.terminalID] = pendingID
        pendingStart[pendingID] = Date()
        submitTimes[pendingID] = ContinuousClock.now
        agentNames[pendingID] = provider.isAgent ? ProviderAdapters.name(provider) : String(localized: "Terminal", bundle: .module)
        jobs[pendingID] = CreationJob(request: request, projectID: projectID, origin: origin)
        flyChip(provider: provider, title: request.title, origin: origin, pendingID: pendingID)
        run(pendingID)
        return pendingID
    }

    private func run(_ pendingID: UUID) {
        guard let job = jobs[pendingID], let service else { return }
        tasks[pendingID]?.cancel()
        tasks[pendingID] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let output = try await service.create(
                    job.request,
                    progress: { phase in
                        Task { @MainActor in
                            switch phase {
                            case .preparing: self.sidebar.advance(pending: pendingID, to: .preparing)
                            case .fetching: self.sidebar.advance(pending: pendingID, to: .fetching)
                            case .creatingWorktree: self.sidebar.advance(pending: pendingID, to: .creatingWorktree)
                            }
                        }
                    },
                    onSession: { id in Task { @MainActor in self.sidebar.hide(session: id, behind: pendingID) } })
                guard !Task.isCancelled, self.sidebar.pending(pendingID) != nil else { return }
                self.sidebar.hide(session: output.session.id, behind: pendingID)
                // O snapshot do Store chega por observação; seleciona assim que a sessão aparece (o centro troca da PhaseList para o pane).
                for _ in 0 ..< 500 where !self.sidebar.select(output.session.id) { try? await Task.sleep(for: .milliseconds(20)) }
                self.tasks[pendingID] = nil
            } catch is CancellationError {
                return
            } catch let failure as SessionCreationFailure {
                self.fail(pendingID, failure)
            } catch {
                self.fail(pendingID, SessionCreationFailure(message: "Couldn't create the session", detail: "\(error)", recoveries: [.tryAgain]))
            }
        }
    }

    private func fail(_ pendingID: UUID, _ failure: SessionCreationFailure) {
        guard sidebar.pending(pendingID) != nil else { return }
        log.error("session creation failed: \(failure.message)")
        sidebar.fail(pending: pendingID, message: failure.message, detail: failure.detail, recoveries: failure.recoveries)
        sidebar.focus(pending: pendingID)
        tasks[pendingID] = nil
    }

    /// Try Again, Use Existing Branch e Create Without Fetching (03 §6.4).
    @discardableResult
    func retry(_ pendingID: UUID, mode: RetryMode) -> Bool {
        guard var job = jobs[pendingID], let pending = sidebar.pending(pendingID), pending.failure != nil else { return false }
        if case .newWorktree(var spec) = job.request.target {
            switch mode {
            case .tryAgain: break
            case .useExistingBranch:
                guard let name = pending.recoveries.compactMap({ if case .useExistingBranch(let n) = $0 { n } else { nil } }).first else { return false }
                spec.source = .existingBranch(name)
            case .createWithoutFetching:
                spec.fetch = .skipFetch
            }
            job.request.target = .newWorktree(spec)
        }
        jobs[pendingID] = job
        sidebar.restart(pending: pendingID)
        submitTimes[pendingID] = ContinuousClock.now
        run(pendingID)
        return true
    }

    /// Cancel da linha pendente: aborta o que ainda não aconteceu e, se o terminal já existe, a ignição dele.
    private func cancelPending(_ pendingID: UUID) {
        tasks[pendingID]?.cancel()
        tasks[pendingID] = nil
        if let terminal = pendingByTerminal.first(where: { $0.value == pendingID })?.key { workspace.cancelLaunch(terminal) }
        forget(pendingID)
    }

    private func discardPending(_ pendingID: UUID) {
        tasks[pendingID]?.cancel()
        forget(pendingID)
    }

    private func forget(_ pendingID: UUID) {
        jobs[pendingID] = nil
        pendingStart[pendingID] = nil
        submitTimes[pendingID] = nil
        agentNames[pendingID] = nil
        for (terminal, id) in pendingByTerminal where id == pendingID { pendingByTerminal[terminal] = nil }
    }

    // MARK: Nomes

    /// Com prompt, o título são as primeiras palavras como digitadas (AC-303); sem prompt, o nome do agente.
    static func title(name: String?, prompt: String?, provider: TerminalProvider, folder: URL? = nil) -> String {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        if let prompt {
            let words = prompt.split(whereSeparator: \.isWhitespace).prefix(5).joined(separator: " ")
            if !words.isEmpty { return words }
        }
        // Sem prompt, a sessão limpa tem o nome da pasta (o automático `quiet-harbor`, P15).
        if let folder, !folder.lastPathComponent.isEmpty { return folder.lastPathComponent }
        return ProviderAdapters.name(provider)
    }

    static func slug(_ title: String) -> String {
        let mapped = title.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let parts = mapped.split(separator: "-", omittingEmptySubsequences: true).prefix(5)
        return parts.isEmpty ? "session" : parts.joined(separator: "-")
    }
}
