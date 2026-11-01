import RackyCore
import RackyDesignSystem
import RackyPlatform
import RackyProtocol
import Foundation
import Observation

/// Sessão como o `GitHubController` a enxerga: pasta, branch e o último status Git conhecido.
struct GitHubSessionRef: Equatable, Sendable {
    var id: UUID
    var title: String
    var folderPath: String
    var branch: String?
    var status: GitStatus?
}

/// De onde o controlador lê as sessões (a sidebar em produção; um fake nos testes).
struct GitHubSource {
    var selected: @MainActor () -> GitHubSessionRef?
    var sessions: @MainActor () -> [GitHubSessionRef]
}

/// GitHub na UI (T2-05): chips de PR da sidebar, módulos Source Control e Checks do painel direito e "Create Pull Request".
/// Toda rede passa pelo `GitHubService` (cache, ETag-equivalente por TTL, backoff, rate limit); este tipo só decide *quando*
/// perguntar: a sidebar a cada ciclo curto (o serviço só vai à rede quando o cache venceu: 45 s com a janela ativa, 5 min em
/// segundo plano) e os módulos só enquanto estão em cena. Testes injetam runners falsos: nenhum `gh` nem `git` real.
@MainActor @Observable
final class GitHubController {
    enum Load: Equatable { case idle, loading, loaded, failed }
    enum Access: Equatable { case unknown, ready, loggedOut, ghMissing }

    // MARK: Estado observado pelas views

    private(set) var chips: [UUID: PullRequestChipModel] = [:]
    private(set) var changes: [GitFileChange] = []
    private(set) var changesSession: UUID?
    private(set) var changesLoad: Load = .idle
    private(set) var baseRef: String?
    private(set) var access: Access = .unknown
    /// Pastas sem remote GitHub (sem consulta possível): o módulo mostra a nota em vez de um PR ausente.
    private(set) var notOnGitHub: Set<String> = []
    private(set) var refreshing = false
    private(set) var updatedAt: Date?

    // MARK: Dependências

    let source: GitHubSource
    @ObservationIgnored let service: GitHubService
    @ObservationIgnored let git: GitService
    @ObservationIgnored let gitRunner: any GitCommandRunning
    @ObservationIgnored let ghRunner: any GitHubCommandRunning
    @ObservationIgnored let overlays: OverlayRouter
    @ObservationIgnored let toasts: ToastCenter
    @ObservationIgnored var openURL: @MainActor (URL) -> Void
    @ObservationIgnored var copyText: @MainActor (String) -> Void = { _ in }
    @ObservationIgnored var openFile: @MainActor (URL) async throws -> Void = { _ in }
    @ObservationIgnored var isAppActive: @MainActor () -> Bool = { true }
    @ObservationIgnored var showModule: @MainActor (PanelModuleID) -> Void = { _ in }
    @ObservationIgnored var onChips: @MainActor ([UUID: PullRequestChipModel]) -> Void = { _ in }
    @ObservationIgnored var clock: @MainActor () -> Date = { Date() }
    /// Onde o corpo do PR é gravado para o `--body-file` (apagado ao final).
    @ObservationIgnored var temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    /// Espera entre ciclos da sidebar: curta com a janela ativa (o serviço decide se vai à rede), longa em segundo plano.
    @ObservationIgnored var activeLoop: Duration = .seconds(15)
    @ObservationIgnored var backgroundLoop: Duration = .seconds(300)

    // MARK: Internos

    @ObservationIgnored private var repoCache: [String: (repo: GitHubRepoRef?, at: Date)] = [:]
    @ObservationIgnored private var auth: (state: GitHubAuthStatus.State, at: Date)?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var changesTask: Task<Void, Never>?
    @ObservationIgnored private var pushTask: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastStatus: [String: GitStatus] = [:]
    @ObservationIgnored private var defaultBranches: [String: String] = [:]
    @ObservationIgnored private(set) var visibleViews = 0
    @ObservationIgnored var createModel: CreatePRModel?
    private let log = LogFacade(.app, category: "github")

    init(
        service: GitHubService = GitHubService(), git: GitService = GitService(), gitRunner: any GitCommandRunning = GitProcessRunner(),
        ghRunner: any GitHubCommandRunning = GitHubProcessRunner(), source: GitHubSource, overlays: OverlayRouter, toasts: ToastCenter,
        openURL: @escaping @MainActor (URL) -> Void
    ) {
        self.service = service
        self.git = git
        self.gitRunner = gitRunner
        self.ghRunner = ghRunner
        self.source = source
        self.overlays = overlays
        self.toasts = toasts
        self.openURL = openURL
    }

    // MARK: Sidebar: chips de PR

    /// Liga o ciclo da sidebar. Idempotente; `stopPolling` desliga.
    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(for: self.isAppActive() ? self.activeLoop : self.backgroundLoop)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Um ciclo: resolve o repositório de cada sessão com branch, consulta (uma query GraphQL por repositório, em lote) e atualiza
    /// os chips. Sem sessão num repositório GitHub, ou sem `gh` logado, não faz nenhuma chamada de rede.
    func tick(force: Bool = false) async {
        var pairs: [(GitHubSessionRef, SessionBranchQuery)] = []
        for session in source.sessions() {
            guard let branch = session.branch, !branch.isEmpty, let repo = await resolveRepo(session.folderPath) else { continue }
            pairs.append((session, SessionBranchQuery(repo: repo, branch: branch, localHeadOID: session.status?.headOID)))
        }
        guard !pairs.isEmpty else {
            publish([:])
            return
        }
        guard await ensureAuth() else { return }
        let report = await service.refresh(pairs.map(\.1), mode: isAppActive() ? .active : .background, force: force)
        var next: [UUID: PullRequestChipModel] = [:]
        for (session, query) in pairs {
            let paused = Self.pausedText(report.errors[query.repo])
            if let chip = PullRequestChipModel(report.branches[query], pausedReason: paused) {
                next[session.id] = chip
            } else if report.branches[query] == nil, let old = chips[session.id] {
                // Sem resposta nova nem cache (erro de rede): mantém o último estado, marcado como antigo.
                var kept = old
                kept.pausedReason = paused
                next[session.id] = kept
            }
        }
        if let first = report.errors.values.first { log.error("github refresh: \(String(describing: first))") }
        updatedAt = clock()
        publish(next)
    }

    private func publish(_ next: [UUID: PullRequestChipModel]) {
        if next != chips { chips = next }
        onChips(next)
    }

    static func pausedText(_ error: GitHubError?) -> String? {
        if case .rateLimited = error { return String(localized: "Paused · rate limit", bundle: .module) }
        return nil
    }

    private func ensureAuth() async -> Bool {
        if let auth, clock().timeIntervalSince(auth.at) < 300, auth.state == .connected { return true }
        let status = await service.authStatus()
        auth = (status.state, clock())
        switch status.state {
        case .connected: access = .ready
        case .notLoggedIn: access = .loggedOut
        case .ghNotInstalled: access = .ghMissing
        }
        return status.state == .connected
    }

    /// owner/repo do `origin` da pasta; resultado em cache (positivo por 10 min, negativo por 60 s para pegar um remote novo).
    func resolveRepo(_ folder: String) async -> GitHubRepoRef? {
        if let hit = repoCache[folder], clock().timeIntervalSince(hit.at) < (hit.repo == nil ? 60 : 600) { return hit.repo }
        let repo = try? await service.resolveRepo(at: URL(fileURLWithPath: folder))
        repoCache[folder] = (repo, clock())
        if repo == nil { notOnGitHub.insert(folder) } else { notOnGitHub.remove(folder) }
        return repo
    }

    // MARK: Painel: enquanto os módulos estão em cena

    func viewAppeared() {
        visibleViews += 1
        Task { await refreshPanel(force: false) }
    }

    func viewDisappeared() {
        visibleViews = max(0, visibleViews - 1)
        if visibleViews == 0 {
            changesTask?.cancel()
            changesTask = nil
        }
    }

    /// Lista de mudanças da sessão selecionada (local, barata) e, se pedido, nova consulta ao GitHub.
    func refreshPanel(force: Bool) async {
        guard let session = source.selected() else {
            changes = []
            changesSession = nil
            changesLoad = .idle
            return
        }
        if force { refreshing = true }
        defer { if force { refreshing = false } }
        async let github: Void = tick(force: force)
        await loadChanges(for: session)
        await github
    }

    /// `git diff` contra o merge-base com a base da branch. Descarta a resposta de uma sessão que já deixou de ser a selecionada.
    func loadChanges(for session: GitHubSessionRef) async {
        guard session.branch != nil || session.status != nil else {
            changes = []
            changesSession = session.id
            changesLoad = .loaded
            return
        }
        if changesSession != session.id { changes = [] }
        changesSession = session.id
        if changes.isEmpty { changesLoad = .loading }
        let folder = URL(fileURLWithPath: session.folderPath)
        let base = await baseReference(for: session, folder: folder)
        do {
            let list = try await git.changedFiles(at: folder, baseRef: base)
            guard source.selected()?.id == session.id else { return }
            baseRef = base
            changes = list
            changesLoad = .loaded
        } catch {
            guard source.selected()?.id == session.id else { return }
            log.error("changed files: \(String(describing: error))")
            changesLoad = .failed
        }
    }

    private func baseReference(for session: GitHubSessionRef, folder: URL) async -> String? {
        if let base = chips[session.id]?.baseRefName { return "origin/\(base)" }
        if let cached = defaultBranches[session.folderPath] { return cached }
        guard let name = try? await git.defaultBranch(in: folder) else { return nil }
        // Repo só local (sem `origin`): a base é o branch local; "origin/main" não existe e o diff falhava ("Based on origin/main").
        let hasOrigin = ((try? await git.remoteURL(in: folder)) ?? nil) != nil
        let ref = hasOrigin ? "origin/\(name)" : name
        defaultBranches[session.folderPath] = ref
        return ref
    }

    /// Chamado pela sidebar a cada status novo: detecta push (upstream apareceu ou os commits à frente zeraram) e agenda a
    /// consulta do PR para 5 s depois (06 §5.5); com o painel em cena, refaz a lista de mudanças da sessão selecionada.
    func gitStatusChanged(_ status: GitStatus, at path: String) {
        let previous = lastStatus[path]
        lastStatus[path] = status
        if let previous, Self.looksLikePush(from: previous, to: status),
            let session = source.sessions().first(where: { $0.folderPath == path }) {
            schedulePushRefresh(for: session)
        }
        guard visibleViews > 0, let selected = source.selected(), selected.folderPath == path else { return }
        changesTask?.cancel()
        changesTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            var fresh = selected
            fresh.status = status
            await self.loadChanges(for: fresh)
        }
    }

    static func looksLikePush(from old: GitStatus, to new: GitStatus) -> Bool {
        if old.upstream == nil, new.upstream != nil { return true }
        return (old.ahead ?? 0) > 0 && (new.ahead ?? 0) == 0 && new.headOID == old.headOID
    }

    private func schedulePushRefresh(for session: GitHubSessionRef) {
        pushTask[session.folderPath]?.cancel()
        let delay = GitHubPollingPolicy().afterPushDelay
        pushTask[session.folderPath] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, let branch = session.branch, let repo = await self.resolveRepo(session.folderPath) else { return }
            _ = await self.service.branchDidChange(SessionBranchQuery(repo: repo, branch: branch, localHeadOID: session.status?.headOID))
            await self.tick()
        }
    }

    // MARK: Consultas usadas pelas views e pelas ações

    func session(_ id: UUID?) -> GitHubSessionRef? {
        guard let id else { return source.selected() }
        return source.sessions().first { $0.id == id } ?? source.selected().flatMap { $0.id == id ? $0 : nil }
    }

    /// PR da sessão que ainda pode receber trabalho: aberto ou rascunho. Mergeado/fechado não bloqueia um PR novo.
    func hasActivePullRequest(_ id: UUID) -> Bool {
        guard let chip = chips[id] else { return false }
        return chip.state == .open || chip.state == .draft
    }

    func resolvedArgument(_ arg: ActionArgument) -> UUID? {
        arg.kind == .select ? arg.value.flatMap(UUID.init(uuidString:)) : nil
    }

    func chip(for arg: ActionArgument, action: ActionID) throws -> PullRequestChipModel {
        let id = resolvedArgument(arg) ?? source.selected()?.id
        guard let id, let chip = chips[id] else { throw ActionError.failed(action, message: String(localized: "This branch has no pull request.", bundle: .module)) }
        return chip
    }

    // MARK: Ações

    func register(in registry: ActionRegistry) throws {
        try registry.register(.panelSourceControl) { [unowned self] _ in
            showModule(.sourceControl)
            return "open"
        }
        try registry.register(.panelChecks) { [unowned self] _ in
            showModule(.checks)
            return "open"
        }
        try registry.register(
            .panelRefresh,
            enablement: { [unowned self] in source.selected() == nil ? .disabled(reason: String(localized: "Select a session first.", bundle: .module)) : .enabled }
        ) { [unowned self] _ in
            await refreshPanel(force: true)
            return "refreshed"
        }
        let hasPR: ActionRegistry.Enablement = { [unowned self] in
            guard let id = source.selected()?.id, chips[id] != nil else {
                return .disabled(reason: String(localized: "This branch has no pull request.", bundle: .module))
            }
            return .enabled
        }
        try registry.register(.gitOpenPR) { [unowned self] arg in
            let chip = try chip(for: arg, action: .gitOpenPR)
            guard let url = URL(string: chip.url), url.scheme == "https" else {
                throw ActionError.failed(.gitOpenPR, message: String(localized: "Couldn't open the pull request.", bundle: .module))
            }
            openURL(url)
            return chip.url
        }
        try registry.register(.gitCopyPRURL, enablement: hasPR) { [unowned self] arg in
            let chip = try chip(for: arg, action: .gitCopyPRURL)
            copyText(chip.url)
            return chip.url
        }
        try registry.register(.gitOpenChange) { [unowned self] arg in
            guard arg.kind == .select, let path = arg.value, !path.isEmpty, let session = source.selected() else {
                throw ActionError.failed(.gitOpenChange, message: "expected select(<path>)")
            }
            // Só caminhos da lista de mudanças (nada de `..` nem de caminho absoluto vindo de fora).
            guard let change = changes.first(where: { $0.path == path }) else {
                throw ActionError.failed(.gitOpenChange, message: String(localized: "That file isn't in the changes list.", bundle: .module))
            }
            if change.kind == .deleted {
                throw ActionError.failed(.gitOpenChange, message: String(localized: "This file was deleted.", bundle: .module))
            }
            let url = URL(fileURLWithPath: session.folderPath).appendingPathComponent(path)
            try await openFile(url)
            return url.path
        }
        try registry.register(.gitOpenCheck) { [unowned self] arg in
            guard arg.kind == .select, let name = arg.value, let chip = source.selected().flatMap({ chips[$0.id] }),
                let check = chip.items.first(where: { $0.name == name })
            else { throw ActionError.failed(.gitOpenCheck, message: "expected select(<check name>)") }
            guard let raw = check.url, let url = URL(string: raw), url.scheme == "https" else {
                throw ActionError.failed(.gitOpenCheck, message: String(localized: "This check has no page.", bundle: .module))
            }
            openURL(url)
            return raw
        }
        try registerCreatePR(in: registry)
    }
}
