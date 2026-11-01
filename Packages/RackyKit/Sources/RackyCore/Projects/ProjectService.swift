import RackyProtocol
import RackyStore
import Foundation

/// O que a detecção descobre sobre uma pasta antes de ela virar projeto (01 §5.2).
public struct ProjectCandidate: Sendable, Equatable {
    public let kind: ProjectKind
    /// Raiz canônica: para `git`, o checkout principal (mesmo que a pasta escolhida seja subpasta ou worktree adicional).
    public let rootPath: String
    public let name: String
    public let remoteURL: String?
    /// Branch padrão (`main`); nil quando o repo ainda não tem commits nem `origin`.
    public let defaultBranch: String?
    public let branchPrefix: String?
}

public enum AddProjectOutcome: Sendable, Equatable {
    /// Projeto novo.
    case added
    /// A pasta já era um projeto visível: nada muda.
    case alreadyAdded
    /// O projeto tinha sido removido da lista e voltou (as sessões arquivadas continuam arquivadas).
    case restored
}

public struct AddProjectResult: Sendable, Equatable {
    public let project: Project
    public let outcome: AddProjectOutcome
    public let sync: ProjectSyncReport
}

/// Resultado de uma sincronização de worktrees.
public struct ProjectSyncReport: Sendable, Equatable {
    public var added = 0
    public var updated = 0
    public var removed = 0
    public init(added: Int = 0, updated: Int = 0, removed: Int = 0) {
        self.added = added; self.updated = updated; self.removed = removed
    }
}

public enum ProjectError: Error, Sendable, Equatable {
    case notADirectory(String)
    case projectNotFound(UUID)
    case git(GitError)
}

/// Projetos (T1-19): detecta pasta/repositório, grava no Store, sincroniza worktrees como sessões "não iniciadas"
/// (sem terminal) e arquiva ao remover. Nunca escreve nem apaga arquivos do usuário. Todo trabalho de Git roda fora
/// da main thread (ProcessRunner), então a UI nunca espera por ele.
public struct ProjectService: Sendable {
    private let store: RackyStore
    private let git: GitService
    private let worktreeBase: URL
    private let clock: @Sendable () -> Date

    public init(store: RackyStore, git: GitService = GitService(),
                worktreeBase: URL = GitNaming.defaultWorktreeRoot(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.git = git
        self.worktreeBase = worktreeBase
        self.clock = clock
    }

    // MARK: - Detecção

    /// Lê a pasta: repositório Git (raiz, remote, branch padrão, prefixo) ou pasta comum. Não grava nada.
    public func inspect(folder: URL) async throws -> ProjectCandidate {
        let dir = folder.canonicalPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProjectError.notADirectory(dir.path)
        }
        let repo: GitRepositoryInfo?
        do { repo = try await git.detectRepository(at: dir) } catch let error as GitError { throw ProjectError.git(error) }
        guard let repo else {
            return ProjectCandidate(kind: .folder, rootPath: dir.path, name: dir.lastPathComponent, remoteURL: nil,
                                    defaultBranch: nil, branchPrefix: nil)
        }
        let root = repo.mainRootURL
        // Detalhes opcionais: falhar aqui não impede o projeto (repo vazio, sem remote, sem user.name).
        let remote = try? await git.remoteURL(in: root)
        let base = try? await git.defaultBranch(in: root)
        let prefix = (try? await git.gitUsernamePrefix(in: root))?.value
        return ProjectCandidate(kind: .git, rootPath: root.path, name: repo.name, remoteURL: remote ?? nil,
                                defaultBranch: base, branchPrefix: prefix)
    }

    // MARK: - Adicionar

    public func addProject(folder: URL) async throws -> AddProjectResult {
        let candidate = try await inspect(folder: folder)
        let all = try await store.projects(includeArchived: true)
        if var existing = all.first(where: { $0.rootPath == candidate.rootPath }) {
            let outcome: AddProjectOutcome
            if existing.archivedAt != nil {
                existing.archivedAt = nil
                try await store.save(existing)
                outcome = .restored
            } else {
                outcome = .alreadyAdded
            }
            let sync = existing.kind == .git ? try await syncWorktrees(projectID: existing.id) : ProjectSyncReport()
            return AddProjectResult(project: existing, outcome: outcome, sync: sync)
        }
        let project = Project(
            name: candidate.name, kind: candidate.kind, rootPath: candidate.rootPath, gitRemoteURL: candidate.remoteURL,
            defaultBranch: candidate.defaultBranch,
            worktreeRoot: candidate.kind == .git
                ? worktreeBase.appendingPathComponent(candidate.name, isDirectory: true).path : nil,
            branchPrefix: candidate.branchPrefix, source: .manual,
            sortIndex: (all.map(\.sortIndex).max() ?? -1) + 1, createdAt: clock())
        try await store.save(project)
        let sync = project.kind == .git ? try await syncWorktrees(projectID: project.id) : ProjectSyncReport()
        return AddProjectResult(project: project, outcome: .added, sync: sync)
    }

    // MARK: - Worktrees

    /// Alinha worktrees do Store com `git worktree list`. Worktree novo vira linha `Worktree` mais uma sessão `worktree`
    /// (o checkout principal, `checkout`) sem tabs nem terminais: "não iniciada". Worktree que sumiu do disco perde o
    /// registro só se a sessão não tem tabs; com tabs, o registro fica (o usuário decide). Sessões já existentes nunca
    /// são recriadas nem renomeadas.
    @discardableResult
    public func syncWorktrees(projectID: UUID) async throws -> ProjectSyncReport {
        guard let project = try await store.project(id: projectID) else { throw ProjectError.projectNotFound(projectID) }
        guard project.kind == .git else { return ProjectSyncReport() }
        let listed: [GitWorktreeInfo]
        do { listed = try await git.listWorktrees(in: URL(fileURLWithPath: project.rootPath, isDirectory: true)) }
        catch let error as GitError { throw ProjectError.git(error) }

        let live = listed.filter { !$0.isBare && !$0.isPrunable }
            .map { (info: $0, path: URL(fileURLWithPath: $0.path, isDirectory: true).canonicalPath.path) }
        let existing = try await store.worktrees(projectID: projectID)
        let sessions = try await store.sessions(includeArchived: true).filter { $0.projectID == projectID }
        var report = ProjectSyncReport()
        let now = clock()
        var nextSort = (sessions.map(\.sortIndex).max() ?? -1) + 1

        for entry in live {
            let branch = entry.info.branch ?? ""
            if var wt = existing.first(where: { $0.path == entry.path }) {
                if wt.branch != branch || wt.isMain != entry.info.isMain {
                    wt.branch = branch
                    wt.isMain = entry.info.isMain
                    wt.lastSeenAt = now
                    try await store.save(wt)
                    report.updated += 1
                }
                continue
            }
            let wt = Worktree(projectID: projectID, path: entry.path, branch: branch, isMain: entry.info.isMain,
                              createdByApp: false, source: .manual, createdAt: now, lastSeenAt: now)
            try await store.save(wt)
            let title = branch.isEmpty ? URL(fileURLWithPath: entry.path).lastPathComponent : branch
            let session = Session(kind: entry.info.isMain ? .checkout : .worktree, projectID: projectID, worktreeID: wt.id,
                                  folderPath: entry.path, managedFolder: false, title: title, lifecycle: .active,
                                  sortIndex: nextSort, createdAt: now)
            nextSort += 1
            try await store.save(session)
            report.added += 1
        }

        let livePaths = Set(live.map(\.path))
        for wt in existing where !livePaths.contains(wt.path) {
            let owned = sessions.filter { $0.worktreeID == wt.id }
            // Sessão arquivada cujo checkout saiu do disco (Settings › Storage): o registro guarda pasta e branch para o Restore.
            if owned.contains(where: { $0.lifecycle == .archived }) { continue }
            var hasTabs = false
            for s in owned where try await !store.tabs(sessionID: s.id, includeClosed: true).isEmpty { hasTabs = true }
            if hasTabs { continue }
            for s in owned { try await store.deleteSession(id: s.id) }
            try await store.deleteWorktree(id: wt.id)
            report.removed += 1
        }
        return report
    }

    /// Sincroniza todos os projetos Git visíveis; falha de um (pasta movida, git ausente) não impede os outros.
    public func syncAll() async -> [UUID: ProjectSyncReport] {
        var result: [UUID: ProjectSyncReport] = [:]
        guard let projects = try? await store.projects() else { return result }
        for p in projects where p.kind == .git {
            if let report = try? await syncWorktrees(projectID: p.id) { result[p.id] = report }
        }
        return result
    }

    /// Grava o branch visto pelo `status` no registro do worktree (o usuário trocou de branch no terminal).
    /// Devolve `true` se mudou algo.
    @discardableResult
    public func applyBranch(_ status: GitStatus, toWorktreeAt path: String) async throws -> Bool {
        let branch = status.branch ?? ""
        for project in try await store.projects() {
            guard var wt = try await store.worktrees(projectID: project.id).first(where: { $0.path == path }) else { continue }
            guard wt.branch != branch else { return false }
            wt.branch = branch
            try await store.save(wt)
            return true
        }
        return false
    }

    // MARK: - Renomear e remover

    /// Nome vazio volta ao nome da pasta. Não renomeia nada em disco.
    public func renameProject(id: UUID, to text: String) async throws {
        guard var project = try await store.project(id: id) else { throw ProjectError.projectNotFound(id) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? URL(fileURLWithPath: project.rootPath).lastPathComponent : trimmed
        guard name != project.name else { return }
        project.name = name
        try await store.save(project)
    }

    /// Tira o projeto da lista: arquiva as sessões e o projeto. Arquivos, worktrees e branches ficam intactos.
    /// Devolve quantas sessões foram arquivadas.
    @discardableResult
    public func removeProject(id: UUID) async throws -> Int {
        guard (try await store.project(id: id)) != nil else { throw ProjectError.projectNotFound(id) }
        let now = clock()
        var count = 0
        for var s in try await store.sessions().filter({ $0.projectID == id }) {
            s.lifecycle = .archived
            s.archivedAt = now
            try await store.save(s)
            count += 1
        }
        try await store.archiveProject(id: id, at: now)
        return count
    }
}
