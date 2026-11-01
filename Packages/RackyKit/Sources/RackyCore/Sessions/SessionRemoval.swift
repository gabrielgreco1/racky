import Foundation

/// O que apagar uma sessão de worktree vai perder (03 §16.5, 06 §5.2): lido antes de qualquer ação.
public struct SessionRemovalPreview: Sendable, Equatable {
    public let worktreePath: String
    public let branch: String?
    public let changedFiles: Int
    public let untrackedFiles: Int
    public let conflictedFiles: Int
    /// `nil` = desconhecido (sem upstream nem base).
    public let unpublishedCommits: Int?
    /// Primeiros caminhos alterados ou não rastreados (para a lista do diálogo).
    public let samplePaths: [String]
    /// O worktree já não existe no disco: só o registro some.
    public let missingOnDisk: Bool

    public init(worktreePath: String, branch: String?, changedFiles: Int = 0, untrackedFiles: Int = 0, conflictedFiles: Int = 0,
                unpublishedCommits: Int? = nil, samplePaths: [String] = [], missingOnDisk: Bool = false) {
        self.worktreePath = worktreePath
        self.branch = branch
        self.changedFiles = changedFiles
        self.untrackedFiles = untrackedFiles
        self.conflictedFiles = conflictedFiles
        self.unpublishedCommits = unpublishedCommits
        self.samplePaths = samplePaths
        self.missingOnDisk = missingOnDisk
    }

    public var uncommittedFiles: Int { changedFiles + untrackedFiles + conflictedFiles }
    public var hasUncommittedChanges: Bool { uncommittedFiles > 0 }
    public var unpublished: Int { unpublishedCommits ?? 0 }
    /// Há trabalho que só existe neste worktree: o diálogo mostra o aviso `destructive` e não oferece "Don't ask again".
    public var losesData: Bool { hasUncommittedChanges || unpublished > 0 }

    /// `3 uncommitted files and 2 unpushed commits will be lost.` (03 §16.5); `nil` sem perda.
    public var lossSummary: String? {
        var parts: [String] = []
        if uncommittedFiles > 0 { parts.append(uncommittedFiles == 1 ? "1 uncommitted file" : "\(uncommittedFiles) uncommitted files") }
        if unpublished > 0 { parts.append(unpublished == 1 ? "1 unpushed commit" : "\(unpublished) unpushed commits") }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " and ") + " will be lost."
    }
}

/// Consultas ao disco para a UI (que não usa `FileManager`, AR-210).
public enum SessionFolderProbe {
    public static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

/// Resultado de remover o worktree de uma sessão.
public struct SessionRemovalOutcome: Sendable, Equatable {
    public let removedPath: String
    public let branch: String?
    public let branchDeleted: Bool
    /// O Git recusou apagar a branch por não estar mesclada; a branch ficou (apagar à força é decisão do usuário, fora daqui).
    public let branchNotMerged: Bool
    public let wasMissing: Bool
}

/// Remoção de worktree por sessão (T1-27): checagem prévia (`inspectRemoval`) e remoção pelo `GitService`. Sem `force`, um worktree com
/// mudanças não commitadas é recusado (`GitError.worktreeHasChanges`); o `force` só vem do botão de confirmação do diálogo que listou o que
/// se perde. Nunca stash, reset nem clean.
public struct SessionRemovalService: Sendable {
    private let service: GitService

    public init(service: GitService = GitService()) { self.service = service }

    public func preview(repositoryURL: URL, worktreePath: URL, sampleLimit: Int = 6) async throws -> SessionRemovalPreview {
        guard FileManager.default.fileExists(atPath: worktreePath.path) else {
            return SessionRemovalPreview(worktreePath: worktreePath.path, branch: nil, missingOnDisk: true)
        }
        let report = try await service.inspectRemoval(repositoryURL: repositoryURL, worktreePath: worktreePath)
        let sample = report.hasUncommittedChanges ? ((try? await service.changedPaths(at: worktreePath, limit: sampleLimit)) ?? []) : []
        return SessionRemovalPreview(
            worktreePath: report.path, branch: report.branch, changedFiles: report.changedFiles, untrackedFiles: report.untrackedFiles,
            conflictedFiles: report.conflictedFiles, unpublishedCommits: report.unpublishedCommits, samplePaths: sample)
    }

    /// Settings › Storage › Worktrees of archived sessions: tira o checkout do disco só quando nada se perde (sem mudanças, nada sem
    /// publicar e upstream conhecido); a branch fica para o Restore. `false` quando o worktree ficou.
    public func removeIfClean(repositoryURL: URL, worktreePath: URL) async -> Bool {
        guard let preview = try? await preview(repositoryURL: repositoryURL, worktreePath: worktreePath, sampleLimit: 0), !preview.missingOnDisk,
              !preview.hasUncommittedChanges, preview.unpublishedCommits == 0 else { return false }
        return (try? await remove(repositoryURL: repositoryURL, worktreePath: worktreePath, deleteBranch: false, force: false)) != nil
    }

    /// Restore de uma sessão arquivada cujo checkout saiu: volta a branch na mesma pasta. Pasta já existente fica como está.
    public func restoreIfMissing(repositoryURL: URL, worktreePath: URL, branch: String) async throws {
        guard !FileManager.default.fileExists(atPath: worktreePath.path) else { return }
        try await service.checkoutWorktree(repositoryURL: repositoryURL, path: worktreePath, branch: branch)
    }

    public func remove(repositoryURL: URL, worktreePath: URL, deleteBranch: Bool, force: Bool) async throws -> SessionRemovalOutcome {
        guard FileManager.default.fileExists(atPath: worktreePath.path) else {
            // Já sumiu do disco: limpa a referência do Git e segue (o registro é removido por quem chama).
            try? await service.pruneWorktrees(in: repositoryURL)
            return SessionRemovalOutcome(removedPath: worktreePath.path, branch: nil, branchDeleted: false, branchNotMerged: false, wasMissing: true)
        }
        let result = try await service.removeWorktree(
            repositoryURL: repositoryURL, worktreePath: worktreePath, options: .init(force: force, deleteBranch: deleteBranch))
        return SessionRemovalOutcome(
            removedPath: result.removedPath, branch: result.branch, branchDeleted: result.branchDeleted,
            branchNotMerged: result.branchNotMerged, wasMissing: false)
    }
}
