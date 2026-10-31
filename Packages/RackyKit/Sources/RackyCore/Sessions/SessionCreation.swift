import RackyProtocol
import RackyStore
import Foundation

/// Nova worktree pedida pelo composer.
public struct NewWorktreeSpec: Sendable, Equatable {
    public var projectID: UUID
    public var source: GitWorktreeSource
    public var worktreeRoot: URL
    public var fetch: GitFetchPolicy

    public init(projectID: UUID, source: GitWorktreeSource, worktreeRoot: URL, fetch: GitFetchPolicy = .fetchFirst) {
        self.projectID = projectID; self.source = source; self.worktreeRoot = worktreeRoot; self.fetch = fetch
    }
}

/// Onde a sessão nova roda (03 §6.1 campo 2).
public enum SessionPlacement: Sendable, Equatable {
    case newWorktree(NewWorktreeSpec)
    /// Worktree que já existe no projeto, inclusive o checkout principal.
    case existingCheckout(worktreeID: UUID)
    /// Projeto do tipo pasta: a sessão roda na raiz dele.
    case projectFolder(projectID: UUID)
    /// Sessão limpa. `managed`: pasta criada pelo app (nome único garantido); senão a pasta escolhida, que o app não toca.
    case cleanFolder(path: String, managed: Bool)
}

public struct SessionCreationRequest: Sendable, Equatable {
    public var sessionID: UUID
    public var tabID: UUID
    public var terminalID: UUID
    public var title: String
    public var target: SessionPlacement
    public var spec: LaunchSpec
    /// "Subagent computers" da sessão nova (F12).
    public var subagentComputers: SubagentComputersMode
    /// Quem roda os subagentes da sessão nova (spec subagent-harness).
    public var subagentHarness: SubagentHarness

    public init(
        sessionID: UUID = .v7(), tabID: UUID = .v7(), terminalID: UUID = .v7(), title: String, target: SessionPlacement, spec: LaunchSpec,
        subagentComputers: SubagentComputersMode = .off, subagentHarness: SubagentHarness = .claude
    ) {
        self.subagentComputers = subagentComputers
        self.subagentHarness = subagentHarness
        self.sessionID = sessionID; self.tabID = tabID; self.terminalID = terminalID
        self.title = title; self.target = target; self.spec = spec
    }
}

public enum SessionCreationPhase: Sendable, Equatable { case preparing, fetching, creatingWorktree }

/// Ações alternativas que a UI oferece junto do erro (03 §6.4).
public enum SessionRecovery: Sendable, Equatable {
    case tryAgain
    case useExistingBranch(String)
    case createWithoutFetching
}

/// Falha de criação com o que a UI precisa: mensagem curta da linha pendente, detalhe do centro e as saídas.
public struct SessionCreationFailure: Error, Sendable, Equatable {
    public var message: String
    public var detail: String
    public var recoveries: [SessionRecovery]

    public init(message: String, detail: String, recoveries: [SessionRecovery]) {
        self.message = message; self.detail = detail; self.recoveries = recoveries
    }

    static func worktree(_ error: GitError) -> SessionCreationFailure {
        let short = "Couldn't create worktree"
        switch error {
        case .fetchFailed(let stderr):
            let text = stderr.isEmpty ? "Couldn't reach origin." : stderr
            return .init(message: "Couldn't fetch origin", detail: text, recoveries: [.tryAgain, .createWithoutFetching])
        case .timedOut(operation: "fetch"):
            return .init(message: "Couldn't fetch origin", detail: "The fetch took too long.", recoveries: [.tryAgain, .createWithoutFetching])
        case .branchAlreadyExists(let name):
            return .init(message: short, detail: "Branch \"\(name)\" already exists.", recoveries: [.tryAgain, .useExistingBranch(name)])
        case .branchInUse(let branch, let path):
            return .init(message: short, detail: "Branch \"\(branch)\" is already checked out in \(path).", recoveries: [.tryAgain])
        case .branchNotFound(let name):
            return .init(message: short, detail: "No branch named \"\(name)\".", recoveries: [.tryAgain])
        case .invalidBranchName(let name):
            return .init(message: short, detail: "\"\(name)\" isn't a valid branch name.", recoveries: [.tryAgain])
        case .baseRefMissing(let ref):
            return .init(message: short, detail: "The base \"\(ref)\" doesn't exist in this repository.", recoveries: [.tryAgain])
        case .destinationOccupied(let path):
            return .init(message: short, detail: "\(path) is already in use.", recoveries: [.tryAgain])
        case .invalidDestination(let text):
            return .init(message: short, detail: text, recoveries: [.tryAgain])
        case .gitNotInstalled:
            return .init(message: short, detail: "Git isn't installed.", recoveries: [.tryAgain])
        case .notARepository(let path):
            return .init(message: short, detail: "\(path) isn't a Git repository anymore.", recoveries: [.tryAgain])
        case .creationFailed(let text, let incomplete):
            let note = incomplete ? " Some files may be left behind; nothing else was changed." : ""
            return .init(message: short, detail: text + note, recoveries: [.tryAgain])
        case .commandFailed(_, _, let stderr):
            return .init(message: short, detail: stderr.isEmpty ? "Git failed." : stderr, recoveries: [.tryAgain])
        default:
            return .init(message: short, detail: "\(error)", recoveries: [.tryAgain])
        }
    }
}

public struct SessionCreationOutput: Sendable, Equatable {
    public var session: Session
    public var tab: Tab
    public var terminal: Terminal
    public var worktree: Worktree?
    /// A sessão já existia sem tabs ("não iniciada") e ganhou a tab; não é uma sessão nova.
    public var adoptedExisting: Bool
}

/// Cria sessão, tab e terminal no Store a partir de um pedido do composer (T1-20): worktree nova (fetch + `worktree add`),
/// worktree existente, checkout principal, pasta de projeto, pasta nova gerenciada ou pasta escolhida. Não lança o processo:
/// o terminal nasce `not_started` e o workspace o lança quando o pane tem tamanho (P9). Todo trabalho de Git roda fora da main.
public struct SessionCreationService: Sendable {
    private let store: RackyStore
    private let git: GitService
    private let clock: @Sendable () -> Date

    public init(store: RackyStore, git: GitService = GitService(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.git = git
        self.clock = clock
    }

    /// `onSession` recebe o ID final da sessão ANTES da gravação, para a sidebar esconder o card enquanto a linha pendente existe.
    public func create(
        _ request: SessionCreationRequest, progress: @escaping @Sendable (SessionCreationPhase) -> Void = { _ in },
        onSession: @escaping @Sendable (UUID) -> Void = { _ in }
    ) async throws -> SessionCreationOutput {
        progress(.preparing)
        var session: Session
        var worktree: Worktree?
        var adopted = false
        let now = clock()

        switch request.target {
        case .cleanFolder(let path, let managed):
            var folder = URL(fileURLWithPath: path, isDirectory: true)
            if managed {
                let parent = folder.deletingLastPathComponent()
                let name = SessionNaming.uniqueFolderName(folder.lastPathComponent, in: parent)
                folder = parent.appendingPathComponent(name, isDirectory: true)
                do { try LaunchFolder.ensure(folder) } catch {
                    throw SessionCreationFailure(message: "Couldn't create the folder", detail: "\(error.localizedDescription)", recoveries: [.tryAgain])
                }
            } else if !FileManager.default.fileExists(atPath: folder.path) {
                throw SessionCreationFailure(message: "Couldn't open the folder", detail: "\(folder.path) doesn't exist anymore.", recoveries: [.tryAgain])
            }
            session = Session(
                id: request.sessionID, kind: .clean, folderPath: folder.path, managedFolder: managed, title: request.title,
                sortIndex: try await nextSortIndex(projectID: nil), createdAt: now)

        case .projectFolder(let projectID):
            let project = try await requireProject(projectID)
            guard FileManager.default.fileExists(atPath: project.rootPath) else {
                throw SessionCreationFailure(message: "Couldn't open the folder", detail: "\(project.rootPath) doesn't exist anymore.", recoveries: [.tryAgain])
            }
            session = Session(
                id: request.sessionID, kind: .folder, projectID: projectID, folderPath: project.rootPath, title: request.title,
                sortIndex: try await nextSortIndex(projectID: projectID), createdAt: now)

        case .existingCheckout(let worktreeID):
            let (project, found) = try await findWorktree(worktreeID)
            guard FileManager.default.fileExists(atPath: found.path) else {
                throw SessionCreationFailure(message: "Couldn't open the worktree", detail: "\(found.path) doesn't exist anymore.", recoveries: [.tryAgain])
            }
            worktree = found
            (session, adopted) = try await sessionFor(worktree: found, project: project, request: request, now: now)

        case .newWorktree(let spec):
            let project = try await requireProject(spec.projectID)
            let created: GitWorktreeCreation
            do {
                created = try await git.createWorktree(
                    GitWorktreeRequest(
                        repositoryURL: URL(fileURLWithPath: project.rootPath, isDirectory: true), source: spec.source,
                        worktreeRoot: spec.worktreeRoot, fetch: spec.fetch),
                    progress: { phase in progress(phase == .fetching ? .fetching : .creatingWorktree) })
            } catch let error as GitError {
                throw SessionCreationFailure.worktree(error)
            } catch {
                throw SessionCreationFailure(message: "Couldn't create worktree", detail: "\(error)", recoveries: [.tryAgain])
            }
            let existing = try await store.worktrees(projectID: project.id)
            if var row = existing.first(where: { $0.path == created.path.path }) {
                row.branch = created.branch
                row.baseRef = created.baseRef ?? row.baseRef
                row.createdByApp = true
                try await store.save(row)
                worktree = row
            } else {
                let row = Worktree(
                    projectID: project.id, path: created.path.path, branch: created.branch, baseRef: created.baseRef,
                    isMain: false, createdByApp: true, source: .manual, createdAt: now, lastSeenAt: now)
                try await store.save(row)
                worktree = row
            }
            guard let row = worktree else { throw SessionCreationFailure(message: "Couldn't create worktree", detail: "No record.", recoveries: [.tryAgain]) }
            (session, adopted) = try await sessionFor(worktree: row, project: project, request: request, now: now)
            if adopted { session.title = request.title }
        }

        session.subagentComputers = request.subagentComputers
        session.subagentHarness = request.subagentHarness
        onSession(session.id)
        let adapter = ProviderAdapters.adapter(for: request.spec.provider)
        let title = request.spec.provider.isAgent ? adapter.displayName : URL(fileURLWithPath: session.folderPath).lastPathComponent
        // Perfis embutidos não estão na tabela `launch_profile` (FK): só o `launchSpec` guarda o ID deles.
        let stored: UUID? = if let id = request.spec.profileID, try await store.profiles().contains(where: { $0.id == id }) { id } else { nil }
        let terminal = Terminal(
            id: request.terminalID, tabID: request.tabID, provider: request.spec.provider, profileID: stored, title: title,
            cwd: session.folderPath, launchSpec: request.spec)
        let tab = Tab(
            id: request.tabID, sessionID: session.id, title: title, sortIndex: 0,
            layout: .leaf(Pane(content: .terminal(terminal.id))), focusedTerminalID: terminal.id)
        do {
            try await store.saveBundle(session: session, tabs: [tab], terminals: [terminal])
        } catch {
            throw SessionCreationFailure(
                message: "Couldn't save the session", detail: "\(error)", recoveries: [.tryAgain])
        }
        return SessionCreationOutput(session: session, tab: tab, terminal: terminal, worktree: worktree, adoptedExisting: adopted)
    }

    // MARK: Internos

    private func requireProject(_ id: UUID) async throws -> Project {
        guard let project = try await store.project(id: id) else {
            throw SessionCreationFailure(message: "Couldn't find the project", detail: "It was removed from the list.", recoveries: [.tryAgain])
        }
        return project
    }

    private func findWorktree(_ id: UUID) async throws -> (Project, Worktree) {
        for project in try await store.projects() {
            if let found = try await store.worktrees(projectID: project.id).first(where: { $0.id == id }) { return (project, found) }
        }
        throw SessionCreationFailure(message: "Couldn't find the worktree", detail: "It was removed from the project.", recoveries: [.tryAgain])
    }

    private func nextSortIndex(projectID: UUID?) async throws -> Int {
        let all = try await store.sessions(includeArchived: true).filter { $0.projectID == projectID }
        return (all.map(\.sortIndex).max() ?? -1) + 1
    }

    /// Sessão "não iniciada" do worktree (sem tabs) é reaproveitada; senão nasce uma nova sobre o mesmo worktree.
    private func sessionFor(worktree: Worktree, project: Project, request: SessionCreationRequest, now: Date) async throws -> (Session, Bool) {
        let owned = try await store.sessions().filter { $0.worktreeID == worktree.id }
        for candidate in owned.sorted(by: { $0.sortIndex < $1.sortIndex }) {
            if try await store.tabs(sessionID: candidate.id, includeClosed: true).isEmpty { return (candidate, true) }
        }
        let session = Session(
            id: request.sessionID, kind: worktree.isMain ? .checkout : .worktree, projectID: project.id, worktreeID: worktree.id,
            folderPath: worktree.path, managedFolder: false, title: request.title,
            sortIndex: try await nextSortIndex(projectID: project.id), createdAt: now)
        return (session, false)
    }
}
