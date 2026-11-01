import Foundation
import Testing
@testable import RackyCore

@Suite struct GitParsersTests {
    @Test func statusClean() {
        let out = "# branch.oid abc123\0# branch.head main\0# branch.upstream origin/main\0# branch.ab +0 -0\0"
        let status = GitParsers.parseStatus(out)
        #expect(status.branch == "main")
        #expect(status.headOID == "abc123")
        #expect(status.upstream == "origin/main")
        #expect(status.ahead == 0 && status.behind == 0)
        #expect(!status.isDirty)
    }

    @Test func statusAheadBehindAndEntries() {
        let out = "# branch.oid abc\0# branch.head feat\0# branch.upstream origin/feat\0# branch.ab +2 -3\0"
            + "1 .M N... 100644 100644 100644 aaa bbb file.txt\0"
            + "2 R. N... 100644 100644 100644 aaa bbb R100 new name.txt\0old name.txt\0"
            + "u UU N... 100644 100644 100644 100644 a b c conflict.txt\0"
            + "? untracked.txt\0! ignored.txt\0"
        let status = GitParsers.parseStatus(out)
        #expect(status.ahead == 2 && status.behind == 3)
        #expect(status.changedFiles == 2)
        #expect(status.conflictedFiles == 1)
        #expect(status.untrackedFiles == 1)
        #expect(status.hasConflicts && status.isDirty)
    }

    @Test func statusDetachedAndUnborn() {
        let detached = GitParsers.parseStatus("# branch.oid abc\0# branch.head (detached)\0")
        #expect(detached.isDetached && detached.branch == nil && detached.upstream == nil && detached.ahead == nil)
        let unborn = GitParsers.parseStatus("# branch.oid (initial)\0# branch.head main\0")
        #expect(unborn.branch == "main" && unborn.headOID == nil)
    }

    @Test func worktreeList() {
        let out = "worktree /r/main\0HEAD aaa\0branch refs/heads/main\0\0"
            + "worktree /w/feat\0HEAD bbb\0branch refs/heads/user/feat\0locked reason here\0\0"
            + "worktree /w/det\0HEAD ccc\0detached\0prunable gitdir file points to non-existent location\0\0"
        let list = GitParsers.parseWorktrees(out)
        #expect(list.count == 3)
        #expect(list[0].isMain && list[0].branch == "main")
        #expect(list[1].branch == "user/feat" && list[1].isLocked && !list[1].isMain)
        #expect(list[2].isDetached && list[2].branch == nil && list[2].isPrunable)
    }
}

@Suite struct GitNamingTests {
    @Test func slugRules() {
        #expect(GitNaming.slug(from: "Fix search pagination") == "fix-search-pagination")
        #expect(GitNaming.slug(from: "  Ação  rápida!! ") == "acao-rapida")
        #expect(GitNaming.slug(from: "???") == "worktree")
        let long = GitNaming.slug(from: String(repeating: "abc ", count: 30))
        #expect(long.count <= 40 && !long.hasSuffix("-"))
    }

    @Test func prefixNormalization() {
        #expect(GitNaming.normalizePrefix("Alex Doe") == "alex-doe")
        #expect(GitNaming.normalizePrefix("octocat") == "octocat")
        #expect(GitBranchPrefix.none.value == nil)
        #expect(GitBranchPrefix.custom("  ").value == nil)
        #expect(GitBranchPrefix.gitUsername("João Silva").value == "joao-silva")
    }

    @Test func candidateSuffix() {
        #expect(GitNaming.candidate("a", attempt: 1) == "a")
        #expect(GitNaming.candidate("a", attempt: 2) == "a-2")
    }

    @Test func defaultRootIsRackyWorktrees() {
        let root = GitNaming.defaultWorktreeRoot(home: URL(fileURLWithPath: "/Users/x"))
        #expect(root.path == "/Users/x/Racky/worktrees")
    }
}

@Suite struct GitErrorTests {
    @Test func recoveryMapping() {
        #expect(GitError.branchAlreadyExists("a/b").recovery == .useExistingBranch("a/b"))
        #expect(GitError.fetchFailed("x").recovery == .createWithoutFetching)
        #expect(GitError.timedOut(operation: "fetch").recovery == .createWithoutFetching)
        #expect(GitError.timedOut(operation: "status").recovery == nil)
        #expect(GitError.creationFailed("x", cleanupIncomplete: false).recovery == .tryAgain)
        #expect(GitError.invalidBranchName("x").recovery == nil)
    }
}

private actor Recorder {
    var calls: [(args: [String], kind: GitCommandKind, timeout: Duration)] = []
    func add(_ args: [String], _ kind: GitCommandKind, _ timeout: Duration) { calls.append((args, kind, timeout)) }
}

private struct FakeRunner: GitCommandRunning {
    let recorder = Recorder()
    let handler: @Sendable ([String]) throws -> GitCommandResult
    func run(_ arguments: [String], in directory: URL?, kind: GitCommandKind,
             timeout: Duration) async throws -> GitCommandResult {
        await recorder.add(arguments, kind, timeout)
        return try handler(arguments)
    }
}

@Suite struct GitRunnerEnvironmentTests {
    @Test func readCommandsDisableOptionalLocks() async throws {
        let env = GitProcessRunner(executableURL: URL(fileURLWithPath: "/usr/bin/env"))
        let read = try await env.run([], in: nil, kind: .read, timeout: .seconds(5))
        #expect(read.stdout.contains("GIT_OPTIONAL_LOCKS=0"))
        #expect(read.stdout.contains("GIT_TERMINAL_PROMPT=0"))
        let write = try await env.run([], in: nil, kind: .write, timeout: .seconds(5))
        #expect(!write.stdout.contains("GIT_OPTIONAL_LOCKS=0"))
    }

    @Test func missingGitIsTyped() async {
        let runner = GitProcessRunner(executableURL: nil)
        await #expect(throws: GitError.gitNotInstalled) {
            _ = try await runner.run(["status"], in: nil, kind: .read, timeout: .seconds(1))
        }
    }

    @Test func timeoutIsTypedWithOperation() async {
        let runner = GitProcessRunner(executableURL: URL(fileURLWithPath: "/bin/sleep"))
        await #expect(throws: GitError.timedOut(operation: "30")) {
            _ = try await runner.run(["30"], in: nil, kind: .read, timeout: .milliseconds(200))
        }
    }

    @Test func statusUsesReadKindAndFetchUsesWrite() async throws {
        let fake = FakeRunner { args in
            if args.first == "status" {
                return GitCommandResult(exitCode: 0, stdout: "# branch.head main\0", stderr: "")
            }
            return GitCommandResult(exitCode: 1, stdout: "", stderr: "boom")
        }
        let service = GitService(runner: fake)
        _ = try await service.status(at: URL(fileURLWithPath: "/tmp"))
        let calls = await fake.recorder.calls
        #expect(calls.count == 1 && calls[0].kind == .read)
        #expect(calls[0].args.starts(with: ["status", "--porcelain=v2", "--branch", "-z"]))
    }

    @Test func fetchTimeoutBecomesFetchFailed() async throws {
        let sandbox = try GitSandbox()
        let (repo, _) = try await sandbox.makeRepoWithOrigin()
        // Runner real para tudo, exceto fetch, que estoura o tempo.
        struct FetchTimeoutRunner: GitCommandRunning {
            let real: GitProcessRunner
            func run(_ arguments: [String], in directory: URL?, kind: GitCommandKind,
                     timeout: Duration) async throws -> GitCommandResult {
                if arguments.first == "fetch" { throw GitError.timedOut(operation: "fetch") }
                return try await real.run(arguments, in: directory, kind: kind, timeout: timeout)
            }
        }
        let service = GitService(runner: FetchTimeoutRunner(real: sandbox.runner))
        let request = GitWorktreeRequest(repositoryURL: repo,
                                         source: .newBranch(slug: "x", prefix: .none, baseRef: nil),
                                         worktreeRoot: sandbox.root.appendingPathComponent("wt"))
        await #expect(throws: GitError.fetchFailed("O fetch excedeu o tempo limite.")) {
            _ = try await service.createWorktree(request)
        }
    }
}
