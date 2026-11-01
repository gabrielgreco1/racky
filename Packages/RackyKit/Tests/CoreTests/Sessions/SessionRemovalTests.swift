import Foundation
import Testing

@testable import RackyCore

/// Remoção de worktree por sessão (T1-27, 06 §5.2): repositórios temporários, nunca os do usuário.
@Suite struct SessionRemovalTests {
    private func makeWorktree(_ sandbox: GitSandbox, _ repo: URL, _ slug: String = "wt") async throws -> GitWorktreeCreation {
        try await sandbox.service.createWorktree(GitWorktreeRequest(
            repositoryURL: repo, source: .newBranch(slug: slug, prefix: .gitUsername("me"), baseRef: nil),
            worktreeRoot: sandbox.root.appendingPathComponent("workspaces")))
    }

    @Test func dirtyWorktreePreviewListsWhatWouldBeLostAndBlocksWithoutConfirmation() async throws {
        let sandbox = try GitSandbox()
        let (repo, _) = try await sandbox.makeRepoWithOrigin()
        let wt = try await makeWorktree(sandbox, repo)
        try sandbox.write("README.md", "dirty\n", in: wt.path)
        try sandbox.write("scratch.txt", "s\n", in: wt.path)
        try sandbox.write("work.txt", "w\n", in: wt.path)
        try await sandbox.git(["add", "work.txt"], in: wt.path)
        try await sandbox.git(["commit", "-q", "-m", "work"], in: wt.path)
        try sandbox.write("more.txt", "m\n", in: wt.path)

        let removal = SessionRemovalService(service: sandbox.service)
        let preview = try await removal.preview(repositoryURL: repo, worktreePath: wt.path)
        #expect(preview.changedFiles == 1 && preview.untrackedFiles == 2)
        #expect(preview.unpublishedCommits == 1)
        #expect(preview.losesData)
        #expect(preview.lossSummary == "3 uncommitted files and 1 unpushed commit will be lost.")
        #expect(Set(preview.samplePaths) == ["README.md", "scratch.txt", "more.txt"])

        // Sem a confirmação (force) o serviço recusa e nada é removido.
        await #expect(throws: GitError.self) {
            _ = try await removal.remove(repositoryURL: repo, worktreePath: wt.path, deleteBranch: true, force: false)
        }
        #expect(FileManager.default.fileExists(atPath: wt.path.path))
        #expect(try await sandbox.service.listWorktrees(in: repo).count == 2)
        #expect(try await sandbox.git(["branch", "--list", "me/wt"], in: repo).contains("me/wt"))
        #expect(try String(contentsOf: wt.path.appendingPathComponent("README.md"), encoding: .utf8) == "dirty\n")

        // Com a confirmação explícita, remove (a branch tem commit não mesclado: fica, e o resultado diz isso).
        let outcome = try await removal.remove(repositoryURL: repo, worktreePath: wt.path, deleteBranch: true, force: true)
        #expect(!FileManager.default.fileExists(atPath: wt.path.path))
        #expect(!outcome.branchDeleted && outcome.branchNotMerged)
    }

    @Test func archivingRemovesOnlyACleanCheckoutAndRestoreBringsTheBranchBack() async throws {
        let sandbox = try GitSandbox()
        let (repo, _) = try await sandbox.makeRepoWithOrigin()
        let removal = SessionRemovalService(service: sandbox.service)
        let dirty = try await makeWorktree(sandbox, repo, "dirty")
        try sandbox.write("scratch.txt", "s\n", in: dirty.path)
        #expect(await !removal.removeIfClean(repositoryURL: repo, worktreePath: dirty.path), "uncommitted work keeps the folder")
        #expect(FileManager.default.fileExists(atPath: dirty.path.appendingPathComponent("scratch.txt").path))

        let clean = try await makeWorktree(sandbox, repo, "clean")
        #expect(await removal.removeIfClean(repositoryURL: repo, worktreePath: clean.path))
        #expect(!FileManager.default.fileExists(atPath: clean.path.path))
        #expect(try await sandbox.git(["branch", "--list", clean.branch], in: repo).contains(clean.branch), "the branch stays")
        try await removal.restoreIfMissing(repositoryURL: repo, worktreePath: clean.path, branch: clean.branch)
        #expect(try await sandbox.service.currentBranch(at: clean.path) == clean.branch)
    }

    @Test func cleanWorktreeIsRemovedAndTheBranchDeletedOnRequest() async throws {
        let sandbox = try GitSandbox()
        let (repo, _) = try await sandbox.makeRepoWithOrigin()
        let wt = try await makeWorktree(sandbox, repo)
        let removal = SessionRemovalService(service: sandbox.service)
        let preview = try await removal.preview(repositoryURL: repo, worktreePath: wt.path)
        #expect(!preview.losesData && preview.lossSummary == nil && preview.branch == "me/wt")
        let outcome = try await removal.remove(repositoryURL: repo, worktreePath: wt.path, deleteBranch: true, force: false)
        #expect(outcome.branchDeleted && !outcome.wasMissing)
        #expect(!FileManager.default.fileExists(atPath: wt.path.path))
        #expect(try await sandbox.git(["branch", "--list", "me/wt"], in: repo).isEmpty)
    }

    @Test func keepTheBranchLeavesItInPlace() async throws {
        let sandbox = try GitSandbox()
        let (repo, _) = try await sandbox.makeRepoWithOrigin()
        let wt = try await makeWorktree(sandbox, repo)
        let removal = SessionRemovalService(service: sandbox.service)
        let outcome = try await removal.remove(repositoryURL: repo, worktreePath: wt.path, deleteBranch: false, force: false)
        #expect(!outcome.branchDeleted)
        #expect(try await sandbox.git(["branch", "--list", "me/wt"], in: repo).contains("me/wt"))
    }

    @Test func aWorktreeAlreadyGoneFromDiskIsReportedAndPruned() async throws {
        let sandbox = try GitSandbox()
        let (repo, _) = try await sandbox.makeRepoWithOrigin()
        let wt = try await makeWorktree(sandbox, repo)
        try FileManager.default.removeItem(at: wt.path)
        let removal = SessionRemovalService(service: sandbox.service)
        let preview = try await removal.preview(repositoryURL: repo, worktreePath: wt.path)
        #expect(preview.missingOnDisk && !preview.losesData)
        let outcome = try await removal.remove(repositoryURL: repo, worktreePath: wt.path, deleteBranch: false, force: false)
        #expect(outcome.wasMissing)
        #expect(try await sandbox.service.listWorktrees(in: repo).count == 1)
    }

    @Test func mainCheckoutIsNeverRemoved() async throws {
        let sandbox = try GitSandbox()
        let (repo, _) = try await sandbox.makeRepoWithOrigin()
        let removal = SessionRemovalService(service: sandbox.service)
        await #expect(throws: GitError.self) {
            _ = try await removal.remove(repositoryURL: repo, worktreePath: repo, deleteBranch: true, force: true)
        }
        #expect(FileManager.default.fileExists(atPath: repo.path))
    }

    @Test func lossSummaryWording() {
        #expect(SessionRemovalPreview(worktreePath: "/x", branch: nil, changedFiles: 1).lossSummary == "1 uncommitted file will be lost.")
        #expect(SessionRemovalPreview(worktreePath: "/x", branch: nil, unpublishedCommits: 2).lossSummary == "2 unpushed commits will be lost.")
        #expect(SessionRemovalPreview(worktreePath: "/x", branch: nil, unpublishedCommits: nil).lossSummary == nil)
    }
}
