import RackyCore
import RackyDesignSystem
import RackyPlatform
import RackyProtocol
import Foundation
import Observation

/// O que o composer lembra entre aberturas (`ui_state`, 03 §6): último projeto, agente, perfil e o estado do Advanced.
nonisolated struct ComposerPersistedState: Codable, Equatable, Sendable {
    var lastProjectID: UUID?
    var provider: TerminalProvider?
    var profileID: UUID?
    var advancedOpen = false
}

/// Modelo do composer ⌘N (03 §6): o rascunho (`ComposerDraft`, Core) mais o que a UI acrescenta: consultas Git assíncronas,
/// listas dos comboboxes, disclosure do Advanced e a confirmação inline de descarte. Nenhuma regra de domínio mora aqui.
@MainActor @Observable
final class ComposerModel {
    static let uiStateKey = "composer"

    var draft: ComposerDraft
    var advancedOpen: Bool
    var confirmingDiscard = false
    /// Create pediu confirmação: a sessão grava num lugar protegido com um perfil que não pede permissão antes de rodar comandos.
    var confirmingRisk = false

    /// Os dois riscos juntos (pedido de todas as rodadas de testers): o primeiro Create mostra o aviso e pede "Create anyway".
    var needsRiskConfirmation: Bool {
        guard summary.contains("--dangerously-skip-permissions") else { return false }
        return dataDestinations().first { $0.key == draft.dataDestination }?.production == true
    }
    /// Recarrega o foco do Prompt (Create More limpa o campo e devolve o foco).
    private(set) var focusPromptNonce = 0

    /// Lugares para onde os agentes podem gravar (área Data); ligado pelo app.
    @ObservationIgnored var dataDestinations: () -> [ComposerDataDestination] = { [] }

    private(set) var defaultBranch: String?
    /// Sem `origin` (repo só local) a base é o branch local: o rótulo não pode prometer "origin/main".
    private(set) var hasOrigin = true
    private(set) var branchPrefix: String?
    private(set) var createFromLookup: GitBranchLookup?
    private(set) var branchNameLookup: GitBranchLookup?
    private(set) var baseBranches: [String] = []

    private let sidebar: SidebarModel
    private let settings: SettingsModel
    private let git: GitService
    private var gitTask: Task<Void, Never>?
    private var lookupTask: Task<Void, Never>?
    private var branchTask: Task<Void, Never>?

    init(sidebar: SidebarModel, settings: SettingsModel, git: GitService = GitService(), initial: ComposerPersistedState, preferredProject: UUID?) {
        self.sidebar = sidebar
        self.settings = settings
        self.git = git
        advancedOpen = initial.advancedOpen
        let projects = sidebar.snapshot.projects.filter { $0.archivedAt == nil }
        let project = preferredProject.flatMap { id in projects.first { $0.id == id } }
            ?? initial.lastProjectID.flatMap { id in projects.first { $0.id == id } }
            ?? projects.first
        var draft = ComposerDraft(projectID: project?.id)
        if let project { draft.whereChoice = ComposerDraft.defaultWhere(hasProject: true, kind: project.kind) }
        let installed = { (provider: TerminalProvider) -> Bool in
            provider == .shell || settings.agent(provider)?.isInstalled != false
        }
        let wanted = initial.provider.flatMap { installed($0) ? $0 : nil } ?? settings.settings.agents.defaultAgent
        draft.provider = wanted
        draft.subagentComputers = settings.settings.computers.defaultSubagentMode
        draft.subagentHarness = settings.settings.computers.defaultSubagentHarness
        draft.profileID = initial.profileID.flatMap { id in settings.profiles(for: wanted).contains { $0.id == id } ? id : nil }
            ?? settings.defaultProfile(for: wanted)?.id
        self.draft = draft
        refreshProject()
    }

    // MARK: Contexto

    var project: Project? { draft.projectID.flatMap { sidebar.project($0) } }

    var projects: [Project] { sidebar.snapshot.projects.filter { $0.archivedAt == nil } }

    var worktrees: [Worktree] {
        guard let id = draft.projectID else { return [] }
        return sidebar.snapshot.worktrees.filter { $0.projectID == id && $0.archivedAt == nil }
            .sorted { ($0.isMain ? 0 : 1, $0.branch) < ($1.isMain ? 0 : 1, $1.branch) }
    }

    /// Título da sessão que já usa cada worktree.
    var worktreeUsers: [UUID: String] {
        var users: [UUID: String] = [:]
        for session in sidebar.snapshot.sessions where session.archivedAt == nil {
            guard let wt = session.worktreeID else { continue }
            let hasTab = sidebar.snapshot.tabs.contains { $0.sessionID == session.id && $0.closedAt == nil }
            if hasTab { users[wt] = session.title }
        }
        return users
    }

    var context: ComposerContext {
        let general = settings.settings.general
        return ComposerContext(
            project: project, defaultBranch: defaultBranch, branchPrefix: branchPrefix,
            worktreeRoot: Self.expand(general.worktreeFolder), cleanSessionRoot: Self.expand(general.cleanSessionFolder),
            createFromLookup: createFromLookup, branchNameLookup: branchNameLookup, worktrees: worktrees, worktreeUsers: worktreeUsers,
            catalog: settings.catalog)
    }

    var settingsCatalog: ProfileCatalog { settings.catalog }
    var issues: [ComposerIssue] { draft.issues(context) }
    var canSubmit: Bool { issues.isEmpty }
    var summary: String { draft.summary(context) }
    var warning: String? { draft.warning(context) }

    static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }

    func issue(for field: ComposerField) -> ComposerIssue? { issues.first { $0.field == field } }

    /// Erro mostrado na caixa acima do footer (M-808): só o que o usuário pode corrigir digitando; faltar projeto/pasta só
    /// desabilita o botão.
    var boxIssue: ComposerIssue? {
        issues.first { [.createFrom, .branch, .name].contains($0.field) }
    }

    // MARK: Opções dos comboboxes

    var whereOptions: [ComposerWhere] {
        ComposerDraft.availableWheres(hasProject: project != nil, kind: project?.kind ?? .git)
    }

    var providerProfiles: [LaunchProfile] { settings.profiles(for: draft.provider) }
    /// Nome do perfil escolhido (o aviso de permissões diz qual é).
    var profileName: String { providerProfiles.first { $0.id == draft.profileID }?.name ?? String(localized: "selected", bundle: .module) }

    func agentInfo(_ provider: TerminalProvider) -> AgentInfo? { settings.agent(provider) }

    // MARK: Mudanças (as ações do registro chamam estes métodos)

    func setProject(_ id: UUID?) {
        guard id != draft.projectID else { return }
        draft.projectID = id
        let kind = id.flatMap { sidebar.project($0)?.kind }
        draft.whereChoice = ComposerDraft.defaultWhere(hasProject: id != nil, kind: kind ?? .git)
        draft.worktreeID = nil
        draft.createFrom = ""
        draft.baseRef = nil
        draft.folderPath = nil
        createFromLookup = nil
        branchNameLookup = nil
        refreshProject()
    }

    func setWhere(_ value: ComposerWhere) {
        guard whereOptions.contains(value) else { return }
        draft.whereChoice = value
        if value == .existingWorktree, draft.worktreeID == nil { draft.worktreeID = worktrees.first { !$0.isMain }?.id }
    }

    func setProvider(_ provider: TerminalProvider) {
        draft.provider = provider
        draft.profileID = settings.defaultProfile(for: provider)?.id
    }

    func setCreateFrom(_ text: String) {
        draft.createFrom = text
        createFromLookup = nil
        lookupTask?.cancel()
        let name = draft.createFromText
        guard !name.isEmpty, !draft.createFromIsReference, let project else { return }
        let repo = URL(fileURLWithPath: project.rootPath, isDirectory: true)
        lookupTask = Task { [git] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let result = (try? await git.lookupBranch(name, in: repo)) ?? GitBranchLookup.none
            guard !Task.isCancelled else { return }
            self.createFromLookup = result
        }
    }

    func setBranchName(_ text: String) {
        draft.branchName = text
        branchNameLookup = nil
        branchTask?.cancel()
        guard !text.isEmpty, let project else { return }
        let repo = URL(fileURLWithPath: project.rootPath, isDirectory: true)
        branchTask = Task { [git] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let result = (try? await git.lookupBranch(text, in: repo)) ?? GitBranchLookup.none
            guard !Task.isCancelled else { return }
            self.branchNameLookup = result
        }
    }

    func reuseTypedBranch() {
        draft.reuseTypedBranch()
        setCreateFrom(draft.createFrom)
        branchNameLookup = nil
    }

    func resetForNext() {
        draft.resetForNext()
        createFromLookup = nil
        branchNameLookup = nil
        confirmingDiscard = false
        focusPromptNonce += 1
    }

    var persisted: ComposerPersistedState {
        ComposerPersistedState(lastProjectID: draft.projectID, provider: draft.provider, profileID: draft.profileID, advancedOpen: advancedOpen)
    }

    // MARK: Git assíncrono

    /// Branch padrão, prefixo e branches para o seletor de base. Roda fora da main (`GitService`).
    private func refreshProject() {
        gitTask?.cancel()
        defaultBranch = project?.defaultBranch
        baseBranches = []
        let general = settings.settings.general
        // `none` e `custom` não precisam do Git: o prefixo já vale no primeiro quadro (e no ⌘↵ mais rápido possível).
        branchPrefix = switch general.branchPrefix {
        case .none, .gitUser: nil
        case .custom: GitBranchPrefix.custom(general.branchPrefixCustom).value
        }
        guard let project, project.kind == .git else { return }
        let repo = URL(fileURLWithPath: project.rootPath, isDirectory: true)
        gitTask = Task { [git] in
            let base = try? await git.defaultBranch(in: repo)
            let prefix: String? = switch general.branchPrefix {
            case .none: nil
            case .custom: GitBranchPrefix.custom(general.branchPrefixCustom).value
            case .gitUser: (try? await git.gitUsernamePrefix(in: repo))?.value
            }
            let branches = (try? await git.branches(in: repo)) ?? []
            let origin = ((try? await git.remoteURL(in: repo)) ?? nil) != nil
            guard !Task.isCancelled else { return }
            self.hasOrigin = origin
            self.defaultBranch = base ?? project.defaultBranch
            self.branchPrefix = prefix
            self.baseBranches = branches
        }
    }

    /// Espera as consultas que mudam o pedido (prefixo `git config user.name`, existência do branch digitado) antes de criar.
    func settle() async {
        await gitTask?.value
        await lookupTask?.value
        await branchTask?.value
    }
}

/// Uma opção de "Save data to": o lugar, o grupo (conexão) e o que acontece se escolher.
struct ComposerDataDestination: Equatable {
    var key: String
    var title: String
    var group: String
    var production: Bool
    var explanation: String
    /// Logo do lugar (nil = este Mac).
    var brand: DSDataBrand? = nil

    /// O padrão: um dataset da sessão neste Mac. Sempre existe, mesmo sem nenhuma conexão.
    static var thisMac: ComposerDataDestination {
        ComposerDataDestination(
            key: "racky", title: String(localized: "This Mac (a dataset of this session)", bundle: .module), group: String(localized: "This Mac", bundle: .module),
            production: false,
            explanation: String(localized: "Agents save what they collect in a dataset of this session, on this Mac. You can copy it to a connection later.", bundle: .module))
    }
}
