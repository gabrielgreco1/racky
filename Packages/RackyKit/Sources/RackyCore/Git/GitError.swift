import Foundation

/// Ação alternativa que a UI oferece junto do erro (06 §5.2, T1-18).
public enum GitRecovery: Sendable, Equatable {
    case useExistingBranch(String)
    case createWithoutFetching
    case tryAgain
}

/// Erros tipados do `GitService`. Textos para o usuário ficam na UI; aqui só dados.
public enum GitError: Error, Sendable, Equatable {
    case gitNotInstalled
    case launchFailed(String)
    case timedOut(operation: String)
    case cancelled
    case invalidDirectory(String)
    case notARepository(String)
    case unexpectedOutput(String)
    case commandFailed(operation: String, exitCode: Int32, stderr: String)
    case invalidBranchName(String)
    case baseRefMissing(String)
    /// Branch digitada que já existe: oferecer "Use Existing Branch".
    case branchAlreadyExists(String)
    case branchNotFound(String)
    case branchInUse(branch: String, worktreePath: String)
    /// `git fetch` falhou (rede, credencial, timeout): oferecer "Create Without Fetching".
    case fetchFailed(String)
    case invalidDestination(String)
    case destinationOccupied(String)
    case worktreeNotFound(String)
    case cannotRemoveMainWorktree
    case worktreeLocked(String)
    /// Remoção bloqueada: há mudanças que seriam perdidas (checagem prévia).
    case worktreeHasChanges(WorktreeRemovalReport)
    case branchNotMerged(String)
    /// A criação falhou e o rollback não limpou tudo.
    case creationFailed(String, cleanupIncomplete: Bool)

    public var recovery: GitRecovery? {
        switch self {
        case .branchAlreadyExists(let name): return .useExistingBranch(name)
        case .fetchFailed, .timedOut(operation: "fetch"): return .createWithoutFetching
        case .creationFailed, .commandFailed: return .tryAgain
        default: return nil
        }
    }
}

/// O que se perderia ao remover um worktree (06 §5.2: arquivos alterados, não rastreados, commits não publicados).
public struct WorktreeRemovalReport: Sendable, Equatable {
    public let path: String
    public let branch: String?
    public let changedFiles: Int
    public let untrackedFiles: Int
    public let conflictedFiles: Int
    /// Commits que não existem no upstream (sem upstream: nil, desconhecido).
    public let unpublishedCommits: Int?

    public var hasUncommittedChanges: Bool { changedFiles + untrackedFiles + conflictedFiles > 0 }
}
