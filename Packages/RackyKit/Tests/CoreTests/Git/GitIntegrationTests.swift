import Foundation
import Testing
@testable import RackyCore

@Suite struct GitDetectionAndStatusTests {
    @Test func plainFolderIsNotARepository() async throws {
        let sandbox = try GitSandbox()
        let folder = try sandbox.dir("plain")
        #expect(try await sandbox.service.detectRepository(at: folder) == nil)
    }

    @Test func missingFolderIsTyped() async throws {
        let sandbox = try GitSandbox()
        await #expect(throws: GitError.self) {
            _ = try await sandbox.service.detectRepository(at: sandbox.root.appendingPathComponent("nope"))
        }
    }

    @Test func detectsRootFromSubfolderAndLinkedWorktree() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepo()
        let sub = repo.appendingPathComponent("a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let info = try #require(try await sandbox.service.detectRepository(at: sub))
        #expect(info.rootURL.path == repo.path && info.mainRootURL.path == repo.path && !info.isLinkedWorktree && info.name == "proj")

        let linked = sandbox.root.appendingPathComponent("linked")
        try await sandbox.git(["worktree", "add", "-q", "-b", "side", linked.path], in: repo)
        let linkedInfo = try #require(try await sandbox.service.detectRepository(at: linked))
        #expect(linkedInfo.rootURL.path == linked.path && linkedInfo.mainRootURL.path == repo.path && linkedInfo.isLinkedWorktree)
    }

    @Test func statusCleanDirtyUntracked() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepo()
        var status = try await sandbox.service.status(at: repo)
        #expect(status.branch == "main" && !status.isDirty && status.upstream == nil && status.ahead == nil)
        #expect(try await sandbox.service.currentBranch(at: repo) == "main")

        try sandbox.write("README.md", "changed\n", in: repo)
        status = try await sandbox.service.status(at: repo)
        #expect(status.isDirty && status.changedFiles == 1 && status.untrackedFiles == 0)

        try sandbox.write("new.txt", "n\n", in: repo)
        status = try await sandbox.service.status(at: repo)
        #expect(status.changedFiles == 1 && status.untrackedFiles == 1)
    }

    @Test func statusDetachedHead() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepo()
        try await sandbox.git(["checkout", "-q", "--detach"], in: repo)
        let status = try await sandbox.service.status(at: repo)
        #expect(status.isDetached && status.branch == nil && status.headOID != nil)
    }

    @Test func aheadBehind() async throws {
        let sandbox = try GitSandbox()
        let (repo, origin) = try await sandbox.makeRepoWithOrigin()
        try sandbox.write("local.txt", "l\n", in: repo)
        try await sandbox.git(["add", "."], in: repo)
        try await sandbox.git(["commit", "-q", "-m", "local"], in: repo)
        _ = try await sandbox.pushCommitToOrigin(origin)
        try await sandbox.git(["fetch", "-q", "origin"], in: repo)
        let status = try await sandbox.service.status(at: repo)
        #expect(status.upstream == "origin/main" && status.ahead == 1 && status.behind == 1)
    }

    @Test func statusDoesNotTakeIndexLock() async throws {
        // Com um index.lock presente, `status` (GIT_OPTIONAL_LOCKS=0) ainda funciona.
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepo()
        try sandbox.write("README.md", "changed\n", in: repo)
        try "".write(to: repo.appendingPathComponent(".git/index.lock"), atomically: true, encoding: .utf8)
        let status = try await sandbox.service.status(at: repo)
        #expect(status.isDirty)
    }

    @Test func statusOutsideRepoIsTyped() async throws {
        let sandbox = try GitSandbox()
        let folder = try sandbox.dir("plain")
        await #expect(throws: GitError.notARepository(folder.path)) {
            _ = try await sandbox.service.status(at: folder)
        }
    }

    @Test func defaultBranchAndUsernamePrefix() async throws {
        let sandbox = try GitSandbox()
        let (repo, _) = try await sandbox.makeRepoWithOrigin()
        #expect(try await sandbox.service.defaultBranch(in: repo) == "main")
        #expect(try await sandbox.service.gitUsernamePrefix(in: repo).value == "alex-doe")
    }
}

@Suite struct GitWorktreeCreateTests {
    private func request(_ sandbox: GitSandbox, _ repo: URL, _ source: GitWorktreeSource,
                         fetch: GitFetchPolicy = .fetchFirst) -> GitWorktreeRequest {
        GitWorktreeRequest(repositoryURL: repo, source: source,
                           worktreeRoot: sandbox.root.appendingPathComponent("workspaces"), fetch: fetch)
    }

    @Test func newBranchFromFreshOriginMainWithPrefix() async throws {
        let sandbox = try GitSandbox()
        let (repo, origin) = try await sandbox.makeRepoWithOrigin()
        let remoteTip = try await sandbox.pushCommitToOrigin(origin)

        let created = try await sandbox.service.createWorktree(
            request(sandbox, repo, .newBranch(slug: "Fix search pagination", prefix: .gitUsername("me"),
                                              baseRef: nil)))
        #expect(created.branch == "me/fix-search-pagination")
        #expect(created.path == sandbox.root.appendingPathComponent("workspaces/proj/fix-search-pagination"))
        #expect(created.baseRef == "origin/main" && created.fetched)
        // O fetch trouxe o commit remoto novo e a branch nasce nele, sem upstream.
        #expect(try await sandbox.git(["rev-parse", "HEAD"], in: created.path) == remoteTip)
        let status = try await sandbox.service.status(at: created.path)
        #expect(status.branch == created.branch && status.upstream == nil && !status.isDirty)
    }

    @Test func collisionAddsSuffixOnBothBranchAndFolder() async throws {
        let sandbox = try GitSandbox()
        let (repo, _) = try await sandbox.makeRepoWithOrigin()
        let source = GitWorktreeSource.newBranch(slug: "Fix thing", prefix: .gitUsername("me"), baseRef: nil)
        let first = try await sandbox.service.createWorktree(request(sandbox, repo, source))
        let second = try await sandbox.service.createWorktree(request(sandbox, repo, source))
        let third = try await sandbox.service.createWorktree(request(sandbox, repo, source))
        #expect(first.branch == "me/fix-thing" && second.branch == "me/fix-thing-2")
        #expect(third.branch == "me/fix-thing-3")
        #expect(second.path.lastPathComponent == "fix-thing-2" && third.path.lastPathComponent == "fix-thing-3")
    }

    @Test func folderOccupiedByUnrelatedFilesForcesSuffix() async throws {
        let sandbox = try GitSandbox()
        let (repo, _) = try await sandbox.makeRepoWithOrigin()
        let occupied = try sandbox.dir("workspaces/proj/job")
        try sandbox.write("keep.txt", "mine\n", in: occupied)
        let created = try await sandbox.service.createWorktree(
            request(sandbox, repo, .newBranch(slug: "job", prefix: .none, baseRef: nil)))
        #expect(created.path.lastPathComponent == "job-2" && created.branch == "job-2")
        #expect(FileManager.default.fileExists(atPath: occupied.appendingPathComponent("keep.txt").path))
    }

    @Test func emptyExistingFolderIsReused() async throws {
        let sandbox = try GitSandbox()
        let (repo, _) = try await sandbox.makeRepoWithOrigin()
        _ = try sandbox.dir("workspaces/proj/empty")
        let created = try await sandbox.service.createWorktree(
            request(sandbox, repo, .newBranch(slug: "empty", prefix: .none, baseRef: nil)))
        #expect(created.path.lastPathComponent == "empty")
    }

    @Test func explicitExistingBranchOffersUseExisting() async throws {
        let sandbox = try GitSandbox()
        let (repo, _) = try await sandbox.makeRepoWithOrigin()
        try await sandbox.git(["branch", "feature/x"], in: repo)
        do {
            _ = try await sandbox.service.createWorktree(
                request(sandbox, repo, .newBranchExact(name: "feature/x", baseRef: nil)))
            Issue.record("deveria falhar")
        } catch let error as GitError {
            #expect(error == .branchAlreadyExists("feature/x"))
            #expect(error.recovery == .useExistingBranch("feature/x"))
        }
    }

    @Test func useExistingLocalBranch() async throws {
        let sandbox = try GitSandbox()
        let (repo, _) = try await sandbox.makeRepoWithOrigin()
        try await sandbox.git(["branch", "feature/x"], in: repo)
        let created = try await sandbox.service.createWorktree(request(sandbox, repo, .existingBranch("feature/x")))
        #expect(created.branch == "feature/x" && created.baseRef == nil)
        #expect(created.path.lastPathComponent == "feature-x")
        #expect(try await sandbox.service.currentBranch(at: created.path) == "feature/x")
        // Segunda tentativa: o branch agora está em uso.
        await #expect(throws: GitError.branchInUse(branch: "feature/x", worktreePath: created.path.path)) {
            _ = try await sandbox.service.createWorktree(request(sandbox, repo, .existingBranch("feature/x")))
        }
    }

    @Test func branchCheckedOutInMainIsInUse() async throws {
        let sandbox = try GitSandbox()
        let (repo, _) = try await sandbox.makeRepoWithOrigin()
        await #expect(throws: GitError.branchInUse(branch: "main", worktreePath: repo.path)) {
            _ = try await sandbox.service.createWorktree(request(sandbox, repo, .existingBranch("main")))
        }
    }

    @Test func useExistingRemoteBranchTracksIt() async throws {
        let sandbox = try GitSandbox()
        let (repo, origin) = try await sandbox.makeRepoWithOrigin()
        try await sandbox.git(["push", "-q", "origin", "main:refs/heads/team/work"], in: repo)
        try await sandbox.git(["fetch", "-q", "origin"], in: repo)
        _ = origin
        let created = try await sandbox.service.createWorktree(request(sandbox, repo, .existingBranch("team/work")))
        let status = try await sandbox.service.status(at: created.path)
        #expect(status.branch == "team/work" && status.upstream == "origin/team/work")
    }

    @Test func unknownBranchAndInvalidNames() async throws {
        let sandbox = try GitSandbox()
        let (repo, _) = try await sandbox.makeRepoWithOrigin()
        await #expect(throws: GitError.branchNotFound("ghost")) {
            _ = try await sandbox.service.createWorktree(request(sandbox, repo, .existingBranch("ghost")))
        }
        await #expect(throws: GitError.invalidBranchName("bad..name")) {
            _ = try await sandbox.service.createWorktree(request(sandbox, repo, .newBranchExact(name: "bad..name", baseRef: nil)))
        }
        await #expect(throws: GitError.invalidBranchName("-x")) {
            _ = try await sandbox.service.createWorktree(request(sandbox, repo, .existingBranch("-x")))
        }
    }

    @Test func fetchFailureOffersCreateWithoutFetching() async throws {
        let sandbox = try GitSandbox()
        let (repo, origin) = try await sandbox.makeRepoWithOrigin()
        // Origin some: o fetch falha, mas origin/main local continua existindo.
        try FileManager.default.moveItem(at: origin, to: sandbox.root.appendingPathComponent("moved.git"))
        let source = GitWorktreeSource.newBranch(slug: "offline", prefix: .none, baseRef: nil)
        do {
            _ = try await sandbox.service.createWorktree(request(sandbox, repo, source))
            Issue.record("deveria falhar")
        } catch let error as GitError {
            guard case .fetchFailed = error else { Issue.record("erro inesperado: \(error)"); return }
            #expect(error.recovery == .createWithoutFetching)
        }
        // Nada foi criado.
        #expect(try await sandbox.service.listWorktrees(in: repo).count == 1)
        #expect(!FileManager.default.fileExists(atPath: sandbox.root.appendingPathComponent("workspaces/proj/offline").path))

        let created = try await sandbox.service.createWorktree(request(sandbox, repo, source, fetch: .skipFetch))
        #expect(created.branch == "offline" && !created.fetched && created.baseRef == "origin/main")
    }

    @Test func repositoryWithoutOriginUsesLocalDefaultBranch() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepo()
        let created = try await sandbox.service.createWorktree(
            request(sandbox, repo, .newBranch(slug: "local", prefix: .none, baseRef: nil)))
        #expect(created.baseRef == "main" && !created.fetched)
    }

    @Test func notARepositoryIsTyped() async throws {
        let sandbox = try GitSandbox()
        let folder = try sandbox.dir("plain")
        await #expect(throws: GitError.notARepository(folder.path)) {
            _ = try await sandbox.service.createWorktree(request(sandbox, folder, .existingBranch("main")))
        }
    }

    @Test func rootInsideRepositoryIsRejected() async throws {
        let sandbox = try GitSandbox()
        let (repo, _) = try await sandbox.makeRepoWithOrigin()
        let bad = GitWorktreeRequest(repositoryURL: repo, source: .newBranch(slug: "x", prefix: .none, baseRef: nil),
                                     worktreeRoot: repo.appendingPathComponent("inside"))
        await #expect(throws: GitError.self) { _ = try await sandbox.service.createWorktree(bad) }
    }

    @Test func createdFromLinkedWorktreeAnchorsOnMainRepo() async throws {
        let sandbox = try GitSandbox()
        let (repo, _) = try await sandbox.makeRepoWithOrigin()
        let first = try await sandbox.service.createWorktree(
            request(sandbox, repo, .newBranch(slug: "one", prefix: .none, baseRef: nil)))
        let second = try await sandbox.service.createWorktree(
            request(sandbox, first.path, .newBranch(slug: "two", prefix: .none, baseRef: nil)))
        #expect(second.path.deletingLastPathComponent().lastPathComponent == "proj")
        #expect(try await sandbox.service.listWorktrees(in: repo).count == 3)
    }

    @Test func listWorktreesReportsMainAndLinked() async throws {
        let sandbox = try GitSandbox()
        let (repo, _) = try await sandbox.makeRepoWithOrigin()
        let created = try await sandbox.service.createWorktree(
            request(sandbox, repo, .newBranch(slug: "listed", prefix: .custom("me"), baseRef: nil)))
        let list = try await sandbox.service.listWorktrees(in: repo)
        #expect(list.count == 2)
        #expect(list[0].isMain && list[0].path == repo.path && list[0].branch == "main")
        #expect(list[1].path == created.path.path && list[1].branch == "me/listed" && !list[1].isMain)
    }

    @Test func cancelledCreationLeavesNothingBehind() async throws {
        struct CancelOnAdd: GitCommandRunning {
            let real: GitProcessRunner
            func run(_ arguments: [String], in directory: URL?, kind: GitCommandKind,
                     timeout: Duration) async throws -> GitCommandResult {
                if arguments.starts(with: ["worktree", "add"]) { throw GitError.cancelled }
                return try await real.run(arguments, in: directory, kind: kind, timeout: timeout)
            }
        }
        let sandbox = try GitSandbox()
        let (repo, _) = try await sandbox.makeRepoWithOrigin()
        let service = GitService(runner: CancelOnAdd(real: sandbox.runner))
        await #expect(throws: GitError.cancelled) {
            _ = try await service.createWorktree(request(sandbox, repo, .newBranch(slug: "gone", prefix: .none, baseRef: nil)))
        }
        #expect(try await sandbox.service.listWorktrees(in: repo).count == 1)
        let branches = try await sandbox.git(["branch", "--list", "gone"], in: repo)
        #expect(branches.isEmpty)
    }

    @Test func failedAddRollsBackBranchAndFolder() async throws {
        // Arquivo no lugar de `<raiz>/<repo>` faz o createDirectory falhar antes do git; para provocar falha do
        // próprio git, um hook post-checkout que falha não desfaz o worktree, então usa-se base inexistente.
        let sandbox = try GitSandbox()
        let (repo, _) = try await sandbox.makeRepoWithOrigin()
        await #expect(throws: GitError.baseRefMissing("origin/nope")) {
            _ = try await sandbox.service.createWorktree(
                request(sandbox, repo, .newBranch(slug: "x", prefix: .none, baseRef: "origin/nope")))
        }
        #expect(try await sandbox.git(["branch", "--list", "x"], in: repo).isEmpty)
    }
}

@Suite struct GitWorktreeRemoveTests {
    private func makeWorktree(_ sandbox: GitSandbox, _ repo: URL, _ slug: String = "wt") async throws -> GitWorktreeCreation {
        try await sandbox.service.createWorktree(GitWorktreeRequest(
            repositoryURL: repo, source: .newBranch(slug: slug, prefix: .gitUsername("me"), baseRef: nil),
            worktreeRoot: sandbox.root.appendingPathComponent("workspaces")))
    }

    @Test func cleanWorktreeIsRemovedAndPruned() async throws {
        let sandbox = try GitSandbox()
        let (repo, _) = try await sandbox.makeRepoWithOrigin()
        let wt = try await makeWorktree(sandbox, repo)
        let report = try await sandbox.service.inspectRemoval(repositoryURL: repo, worktreePath: wt.path)
        #expect(!report.hasUncommittedChanges && report.unpublishedCommits == 0 && report.branch == "me/wt")
        let result = try await sandbox.service.removeWorktree(repositoryURL: repo, worktreePath: wt.path)
        #expect(!FileManager.default.fileExists(atPath: wt.path.path))
        #expect(result.branch == "me/wt" && !result.branchDeleted)
        #expect(try await sandbox.service.listWorktrees(in: repo).count == 1)
        // O branch continua por padrão.
        #expect(try await sandbox.git(["branch", "--list", "me/wt"], in: repo).contains("me/wt"))
    }

    @Test func uncommittedChangesBlockRemoval() async throws {
        let sandbox = try GitSandbox()
        let (repo, _) = try await sandbox.makeRepoWithOrigin()
        let wt = try await makeWorktree(sandbox, repo)
        try sandbox.write("README.md", "dirty\n", in: wt.path)
        try sandbox.write("scratch.txt", "s\n", in: wt.path)
        do {
            _ = try await sandbox.service.removeWorktree(repositoryURL: repo, worktreePath: wt.path)
            Issue.record("deveria bloquear")
        } catch let error as GitError {
            guard case .worktreeHasChanges(let report) = error else { Issue.record("erro: \(error)"); return }
            #expect(report.changedFiles == 1 && report.untrackedFiles == 1 && report.hasUncommittedChanges)
        }
        #expect(FileManager.default.fileExists(atPath: wt.path.path))
        #expect(try await sandbox.service.listWorktrees(in: repo).count == 2)
    }

    @Test func untrackedOnlyAlsoBlocks() async throws {
        let sandbox = try GitSandbox()
        let (repo, _) = try await sandbox.makeRepoWithOrigin()
        let wt = try await makeWorktree(sandbox, repo)
        try sandbox.write("only-untracked.txt", "u\n", in: wt.path)
        await #expect(throws: GitError.self) {
            _ = try await sandbox.service.removeWorktree(repositoryURL: repo, worktreePath: wt.path)
        }
    }

    @Test func forceRemovesDirtyWorktree() async throws {
        let sandbox = try GitSandbox()
        let (repo, _) = try await sandbox.makeRepoWithOrigin()
        let wt = try await makeWorktree(sandbox, repo)
        try sandbox.write("README.md", "dirty\n", in: wt.path)
        _ = try await sandbox.service.removeWorktree(repositoryURL: repo, worktreePath: wt.path,
                                                     options: .init(force: true))
        #expect(!FileManager.default.fileExists(atPath: wt.path.path))
    }

    @Test func unpublishedCommitsAreReportedButDoNotBlock() async throws {
        let sandbox = try GitSandbox()
        let (repo, _) = try await sandbox.makeRepoWithOrigin()
        let wt = try await makeWorktree(sandbox, repo)
        try sandbox.write("work.txt", "w\n", in: wt.path)
        try await sandbox.git(["add", "."], in: wt.path)
        try await sandbox.git(["commit", "-q", "-m", "work"], in: wt.path)
        let report = try await sandbox.service.inspectRemoval(repositoryURL: repo, worktreePath: wt.path)
        #expect(!report.hasUncommittedChanges && report.unpublishedCommits == 1)
    }

    @Test func deleteBranchMergedAndUnmerged() async throws {
        let sandbox = try GitSandbox()
        let (repo, _) = try await sandbox.makeRepoWithOrigin()
        let merged = try await makeWorktree(sandbox, repo, "merged")
        let result = try await sandbox.service.removeWorktree(repositoryURL: repo, worktreePath: merged.path,
                                                              options: .init(deleteBranch: true))
        #expect(result.branchDeleted && !result.branchNotMerged)
        #expect(try await sandbox.git(["branch", "--list", "me/merged"], in: repo).isEmpty)

        let unmerged = try await makeWorktree(sandbox, repo, "unmerged")
        try sandbox.write("work.txt", "w\n", in: unmerged.path)
        try await sandbox.git(["add", "."], in: unmerged.path)
        try await sandbox.git(["commit", "-q", "-m", "work"], in: unmerged.path)
        let kept = try await sandbox.service.removeWorktree(repositoryURL: repo, worktreePath: unmerged.path,
                                                            options: .init(deleteBranch: true))
        #expect(!kept.branchDeleted && kept.branchNotMerged)
        #expect(try await sandbox.git(["branch", "--list", "me/unmerged"], in: repo).contains("me/unmerged"))
    }

    @Test func mainWorktreeAndUnknownPathsAreRefused() async throws {
        let sandbox = try GitSandbox()
        let (repo, _) = try await sandbox.makeRepoWithOrigin()
        await #expect(throws: GitError.cannotRemoveMainWorktree) {
            _ = try await sandbox.service.removeWorktree(repositoryURL: repo, worktreePath: repo)
        }
        let stray = try sandbox.dir("stray")
        await #expect(throws: GitError.worktreeNotFound(stray.path)) {
            _ = try await sandbox.service.removeWorktree(repositoryURL: repo, worktreePath: stray)
        }
        #expect(FileManager.default.fileExists(atPath: stray.path))
    }

    @Test func lockedWorktreeIsRefused() async throws {
        let sandbox = try GitSandbox()
        let (repo, _) = try await sandbox.makeRepoWithOrigin()
        let wt = try await makeWorktree(sandbox, repo)
        try await sandbox.git(["worktree", "lock", wt.path.path], in: repo)
        await #expect(throws: GitError.worktreeLocked(wt.path.path)) {
            _ = try await sandbox.service.removeWorktree(repositoryURL: repo, worktreePath: wt.path)
        }
    }

    @Test func removalWorksWhenFolderWasDeletedByHand() async throws {
        let sandbox = try GitSandbox()
        let (repo, _) = try await sandbox.makeRepoWithOrigin()
        let wt = try await makeWorktree(sandbox, repo)
        try FileManager.default.removeItem(at: wt.path)
        _ = try await sandbox.service.removeWorktree(repositoryURL: repo, worktreePath: wt.path,
                                                     options: .init(force: true))
        #expect(try await sandbox.service.listWorktrees(in: repo).count == 1)
    }
}
