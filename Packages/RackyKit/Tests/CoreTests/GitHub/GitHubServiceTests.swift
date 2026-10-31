import Foundation
import Testing
@testable import RackyCore

@Suite struct GitHubServiceTests {
    private let repoA = GitHubRepoRef(owner: "acme", name: "widgets")
    private let repoB = GitHubRepoRef(owner: "acme", name: "gadgets")
    private let repoC = GitHubRepoRef(owner: "acme", name: "gizmos")

    private func makeService(_ clock: TestClock, remaining: Int = 4900,
                             policy: GitHubPollingPolicy = GitHubPollingPolicy()) -> (GitHubService, FakeGitHubRunner) {
        let runner = FakeGitHubRunner { args in
            .ok(try GitHubFixtures.response(branchCount: GitHubFixtures.branchCount(in: args), remaining: remaining))
        }
        return (GitHubService(runner: runner, policy: policy, now: { clock.now }), runner)
    }

    private func sessions(_ repo: GitHubRepoRef, _ count: Int, prefix: String = "dev/s") -> [SessionBranchQuery] {
        (0..<count).map { SessionBranchQuery(repo: repo, branch: "\(prefix)\($0)") }
    }

    @Test func tenSessionsInThreeReposMakeThreeRequests() async throws {
        let clock = TestClock()
        let (service, runner) = makeService(clock)
        let queries = sessions(repoA, 4) + sessions(repoB, 3) + sessions(repoC, 3)
        let report = await service.refresh(queries)
        #expect(report.requestCount == 3 && runner.graphQLCalls.count == 3)
        #expect(report.errors.isEmpty && report.branches.count == 10)
        #expect(report.branches[queries[0]]?.isStale == false)
        #expect(report.branches[queries[0]]?.chip == .open)
        #expect(report.rateLimits[repoA]?.remaining == 4900)
        #expect(Set(runner.graphQLCalls.compactMap { $0.first { $0.hasPrefix("name=") } }) == ["name=widgets", "name=gadgets", "name=gizmos"])
    }

    @Test func duplicateBranchesAreQueriedOnce() async {
        let clock = TestClock()
        let (service, runner) = makeService(clock)
        let q = SessionBranchQuery(repo: repoA, branch: "dev/x")
        _ = await service.refresh([q, q, SessionBranchQuery(repo: repoA, branch: "dev/x", localHeadOID: "abc")])
        #expect(GitHubFixtures.branchCount(in: runner.graphQLCalls[0]) == 1)
    }

    @Test func moreThanTwentyBranchesAreChunked() async {
        let clock = TestClock()
        let (service, runner) = makeService(clock)
        let report = await service.refresh(sessions(repoA, 45))
        #expect(report.requestCount == 3)
        #expect(runner.graphQLCalls.map(GitHubFixtures.branchCount(in:)) == [20, 20, 5])
        #expect(report.branches.count == 45)
    }

    @Test func cacheTTLActiveAndBackground() async {
        let clock = TestClock()
        let (service, runner) = makeService(clock)
        let queries = sessions(repoA, 2)
        _ = await service.refresh(queries)
        clock.advance(30)
        let fresh = await service.refresh(queries)
        #expect(fresh.requestCount == 0 && runner.graphQLCalls.count == 1)
        #expect(fresh.branches[queries[0]]?.isStale == false)
        clock.advance(31) // 61 s: vence o TTL ativo
        let refreshed = await service.refresh(queries)
        #expect(refreshed.requestCount == 1)
        clock.advance(120) // vencido no ativo, mas ainda fresco no segundo plano (300 s)
        #expect(await service.refresh(queries, mode: .background).requestCount == 0)
        clock.advance(200)
        #expect(await service.refresh(queries, mode: .background).requestCount == 1)
        #expect(await service.refresh(queries, force: true).requestCount == 1)
    }

    @Test func lowRemainingSlowsPollingToFiveMinutes() async {
        let clock = TestClock()
        let (service, _) = makeService(clock, remaining: 150)
        let queries = sessions(repoA, 1)
        _ = await service.refresh(queries)
        clock.advance(90)
        #expect(await service.refresh(queries).requestCount == 0)
        clock.advance(220)
        #expect(await service.refresh(queries).requestCount == 1)
    }

    @Test func rateLimitBacksOffExponentiallyKeepingStaleState() async throws {
        let clock = TestClock()
        let (service, runner) = makeService(clock)
        let queries = sessions(repoA, 1)
        _ = await service.refresh(queries)
        runner.setHandler { _ in .fail("gh: You have exceeded a secondary rate limit. (HTTP 403)") }
        clock.advance(61)
        let first = await service.refresh(queries)
        #expect(first.requestCount == 1)
        #expect(first.errors[repoA] == .rateLimited(retryAfter: nil))
        #expect(first.branches[queries[0]]?.isStale == true && first.branches[queries[0]]?.pullRequest != nil)
        let firstAllowed = try #require(await service.nextAllowedRequest(for: repoA))
        #expect(firstAllowed.timeIntervalSince(clock.now) == 60)

        clock.advance(30) // dentro do backoff: nenhuma chamada
        let during = await service.refresh(queries)
        #expect(during.requestCount == 0 && during.branches[queries[0]]?.isStale == true)
        #expect(runner.graphQLCalls.count == 2)

        clock.advance(31)
        let second = await service.refresh(queries)
        #expect(second.requestCount == 1)
        let secondAllowed = try #require(await service.nextAllowedRequest(for: repoA))
        #expect(secondAllowed.timeIntervalSince(clock.now) == 120)

        for _ in 0..<8 { // sobe até o teto de 15 min
            clock.advance(1000)
            _ = await service.refresh(queries)
        }
        let capped = try #require(await service.nextAllowedRequest(for: repoA))
        #expect(capped.timeIntervalSince(clock.now) == 900)

        // Recupera: sucesso zera o backoff.
        runner.setHandler { args in .ok(try GitHubFixtures.response(branchCount: GitHubFixtures.branchCount(in: args))) }
        clock.advance(1000)
        let ok = await service.refresh(queries)
        #expect(ok.errors.isEmpty && ok.branches[queries[0]]?.isStale == false)
        #expect(await service.nextAllowedRequest(for: repoA) == nil)
    }

    @Test func errorInOneRepoDoesNotAffectOthers() async {
        let clock = TestClock()
        let runner = FakeGitHubRunner { args in
            if args.contains("name=gadgets") { return .fail("gh: Could not resolve to a Repository (HTTP 404)") }
            return .ok(try GitHubFixtures.response(branchCount: GitHubFixtures.branchCount(in: args)))
        }
        let service = GitHubService(runner: runner, now: { clock.now })
        let report = await service.refresh(sessions(repoA, 1) + sessions(repoB, 1))
        #expect(report.errors[repoB] == .repositoryNotFound("acme/gadgets") && report.errors[repoA] == nil)
        #expect(report.branches.count == 1)
    }

    @Test func branchDidChangeRefreshesImmediately() async {
        let clock = TestClock()
        let (service, runner) = makeService(clock)
        let q = SessionBranchQuery(repo: repoA, branch: "dev/s0")
        _ = await service.refresh([q])
        clock.advance(5)
        #expect(await service.refresh([q]).requestCount == 0)
        let changed = await service.branchDidChange(q)
        #expect(changed.requestCount == 1 && runner.graphQLCalls.count == 2)
        #expect(changed.branches[q]?.isStale == false)
        // Branch nova no mesmo repo: o cache antigo não vaza.
        let other = SessionBranchQuery(repo: repoA, branch: "dev/other")
        #expect(await service.cached(other) == nil)
        #expect(await service.cached(q)?.chip == .open)
    }

    @Test func localHeadSelectsPullRequestAndFlagsMismatch() async throws {
        let clock = TestClock()
        let (service, _) = makeService(clock)
        let plain = SessionBranchQuery(repo: repoA, branch: "dev/s0")
        let report = await service.refresh([plain])
        let oid = try #require(report.branches[plain]?.pullRequest?.headRefOid)
        let matching = SessionBranchQuery(repo: repoA, branch: "dev/s0", localHeadOID: oid)
        let diverged = SessionBranchQuery(repo: repoA, branch: "dev/s0", localHeadOID: "deadbeef")
        let both = await service.refresh([matching, diverged])
        #expect(both.requestCount == 0) // mesmo cache
        #expect(both.branches[matching]?.headMatchesLocal == true)
        #expect(both.branches[diverged]?.headMatchesLocal == false)
        #expect(both.branches[plain]?.headMatchesLocal == nil)
    }

    @Test func authStatusStates() async throws {
        let connectedText = try GitHubFixtures.text("auth-status-connected.txt")
        let runner = FakeGitHubRunner { _ in .ok(connectedText) }
        let service = GitHubService(runner: runner)
        let status = await service.authStatus()
        #expect(status.isConnected && status.user == "octocat")
        #expect(runner.calls == [["auth", "status", "--hostname", "github.com"]])

        let out = FakeGitHubRunner { _ in .fail("You are not logged into any GitHub hosts. To log in, run: gh auth login") }
        #expect(await GitHubService(runner: out).authStatus().state == .notLoggedIn)
        let missing = FakeGitHubRunner { _ in throw GitHubError.ghNotInstalled }
        #expect(await GitHubService(runner: missing).authStatus().state == .ghNotInstalled)
    }

    @Test func fakeRunnerReceivesNoMutatingCommands() async {
        let clock = TestClock()
        let (service, runner) = makeService(clock)
        _ = await service.refresh(sessions(repoA, 2))
        #expect(runner.calls.allSatisfy { $0.prefix(2) == ["api", "graphql"] })
        #expect(runner.calls.allSatisfy { !$0.contains("create") && !$0.contains("--method") })
    }

    @Test func failureReportCollectsLogsForActionsChecksOnly() async throws {
        let response = try GitHubPullRequestQuery.parse(GitHubFixtures.data("pr-status-contexts.json"), branchCount: 1,
                                                        repoSlug: "acme/widgets")
        let pr = try #require(response.pullRequestsByIndex[0]?.first)
        let runner = FakeGitHubRunner { args in
            guard args.prefix(2) == ["run", "view"] else { return .fail("unexpected") }
            if args.contains("8100000002") { return .fail("log not available") }
            return .ok("build\tTest\t2026-10-17T10:00:00.1234567Z \u{1B}[31mFAIL: TestFoo\u{1B}[0m\nbuild\tTest\t2026-10-17T10:00:01.0Z exit status 1\n")
        }
        let service = GitHubService(runner: runner)
        let text = await service.failureReport(for: pr, repo: repoA)
        #expect(text.hasPrefix("CI checks failed on PR #412 (https://github.com/acme/widgets/pull/412):"))
        #expect(text.contains("- build (GitHub Actions): https://github.com/acme/widgets/actions/runs/7100000001/job/8100000001"))
        #expect(text.contains("  FAIL: TestFoo\n  exit status 1"))
        #expect(text.contains("- ci/external (external check): https://ci.example.com/builds/9"))
        #expect(!text.contains("\u{1B}") && !text.contains("2026-10-17T"))
        // `gh run view <run> --repo owner/name --log-failed --job <id>`; StatusContext não chama o gh.
        let runCalls = runner.calls
        #expect(runCalls.count == 4)
        #expect(runCalls[0] == ["run", "view", "7100000001", "--repo", "acme/widgets", "--log-failed", "--job", "8100000001"])
    }

    @Test func resolveRepoFromOrigin() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepo()
        try await sandbox.git(["remote", "add", "origin", "https://user:tok@github.com/acme/widgets.git"], in: repo)
        let service = GitHubService(runner: FakeGitHubRunner { _ in .ok("") }, git: sandbox.service)
        #expect(try await service.resolveRepo(at: repo) == repoA)
        try await sandbox.git(["remote", "set-url", "origin", "git@gitlab.com:acme/widgets.git"], in: repo)
        // Remote de outro host ainda tem forma owner/repo; quem consulta decide pelo host.
        #expect(try await service.resolveRepo(at: repo).host == "gitlab.com")
        try await sandbox.git(["remote", "set-url", "origin", "/tmp/local-bare"], in: repo)
        await #expect(throws: GitHubError.notAGitHubRemote("/tmp/local-bare")) { try await service.resolveRepo(at: repo) }
        try await sandbox.git(["remote", "remove", "origin"], in: repo)
        await #expect(throws: GitHubError.notAGitHubRemote(nil)) { try await service.resolveRepo(at: repo) }
    }
}
