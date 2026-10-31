import Foundation
import Testing
@testable import RackyCore

@Suite struct GitHubAuthParserTests {
    @Test func connectedPicksActiveAccountAndScopes() throws {
        let text = try GitHubFixtures.text("auth-status-connected.txt")
        let status = GitHubAuthParser.parse(output: text, exitCode: 0, host: "github.com")
        #expect(status.state == .connected)
        #expect(status.user == "octocat")
        #expect(status.scopes == ["gist", "read:org", "repo", "workflow"])
        #expect(status.tokenSource == "keyring")
        #expect(status.gitProtocol == "https")
        #expect(status.canReadPrivateRepos)
    }

    @Test func modelNeverCarriesTheToken() {
        let secret = "gho_" + String(repeating: "A1b2", count: 9)
        let text = "github.com\n  ✓ Logged in to github.com account me (GH_TOKEN)\n  - Active account: true\n"
            + "  - Token: \(secret)\n  - Token scopes: 'repo'\n"
        let status = GitHubAuthParser.parse(output: text, exitCode: 0, host: "github.com")
        #expect(status.tokenSource == "GH_TOKEN")
        #expect(!String(describing: status).contains(secret))
        #expect(!GitHubRedaction.redact("remote said \(secret) here").contains(secret))
        #expect(GitHubRedaction.redact("Authorization: Bearer abcdef123456").contains("[redacted]"))
    }

    @Test func loggedOutAndFailedAccounts() throws {
        let out = try GitHubFixtures.text("auth-status-logged-out.txt")
        #expect(GitHubAuthParser.parse(output: out, exitCode: 1, host: "github.com").state == .notLoggedIn)
        let failed = "github.com\n  X Failed to log in to github.com account me (keyring)\n"
            + "  - Active account: true\n  - The token in keyring is invalid.\n"
        let status = GitHubAuthParser.parse(output: failed, exitCode: 1, host: "github.com")
        #expect(status.state == .notLoggedIn && !status.isConnected)
    }

    @Test func otherHostIsIgnored() throws {
        let text = try GitHubFixtures.text("auth-status-connected.txt")
        #expect(GitHubAuthParser.parse(output: text, exitCode: 0, host: "ghe.example.com").state == .notLoggedIn)
    }
}

@Suite struct GitHubRemoteParserTests {
    @Test(arguments: [
        ("https://github.com/acme/widgets.git", "github.com", "acme", "widgets"),
        ("https://github.com/acme/widgets", "github.com", "acme", "widgets"),
        ("https://user:secret@github.com/acme/widgets.git/", "github.com", "acme", "widgets"),
        ("git@github.com:acme/widgets.git", "github.com", "acme", "widgets"),
        ("ssh://git@github.com:22/acme/widgets.git", "github.com", "acme", "widgets"),
        ("https://GHE.Example.com/team/repo.name.git", "ghe.example.com", "team", "repo.name"),
    ])
    func parses(remote: String, host: String, owner: String, name: String) throws {
        let repo = try #require(GitHubRemoteParser.parse(remote))
        #expect(repo == GitHubRepoRef(host: host, owner: owner, name: name))
    }

    @Test(arguments: ["", "/local/path/repo", "https://github.com/onlyowner", "https://github.com/a/b/c", "file:///x"])
    func rejects(remote: String) {
        #expect(GitHubRemoteParser.parse(remote) == nil)
    }
}

@Suite struct GitHubQueryTests {
    @Test func textHasAliasesVariablesAndNoBranchNames() {
        let text = GitHubPullRequestQuery.text(branchCount: 3)
        #expect(text.contains("$b0: String!") && text.contains("$b2: String!"))
        #expect(!text.contains("$b3"))
        #expect(text.contains("b1: pullRequests(headRefName: $b1, first: 3"))
        #expect(text.contains("statusCheckRollup") && text.contains("rateLimit { cost remaining resetAt }"))
        #expect(text.contains("workflowRun { databaseId }"))
    }

    @Test func argumentsPassBranchesAsVariablesEvenWithQuotes() {
        let repo = GitHubRepoRef(owner: "acme", name: "widgets")
        let branches = ["me/fix \"quoted\"", "me/other\\slash"]
        let args = GitHubPullRequestQuery.arguments(repo: repo, branches: branches)
        #expect(args.prefix(2) == ["api", "graphql"])
        #expect(args.contains("owner=acme") && args.contains("name=widgets"))
        #expect(args.contains("b0=me/fix \"quoted\"") && args.contains("b1=me/other\\slash"))
        let query = args.last { $0.hasPrefix("query=") } ?? ""
        #expect(!query.contains("quoted") && !query.contains("slash"))
        #expect(!args.contains("--hostname"))
        let enterprise = GitHubPullRequestQuery.arguments(repo: GitHubRepoRef(host: "ghe.example.com", owner: "a", name: "b"),
                                                          branches: ["x"])
        #expect(enterprise.contains("--hostname") && enterprise.contains("ghe.example.com"))
    }

    @Test func parsesRealAnonymizedBatch() throws {
        let response = try GitHubPullRequestQuery.parse(GitHubFixtures.data("pr-batch.json"), branchCount: 6,
                                                        repoSlug: "acme/widgets")
        #expect(response.rateLimit?.remaining == 4997 && response.rateLimit?.cost == 1)
        #expect(response.rateLimit?.resetAt != nil)
        #expect(response.pullRequestsByIndex.count == 6)
        let failing = try #require(response.pullRequestsByIndex[0]?.first)
        #expect(failing.state == .open && !failing.isDraft && failing.chip == .open)
        #expect(failing.reviewDecision == .reviewRequired && failing.mergeable == .mergeable)
        #expect(failing.mergeStateStatus == "BLOCKED" && failing.baseRefName == "main")
        #expect(failing.checks.summary == .failure && failing.checks.rollupState == "FAILURE")
        #expect(failing.checks.counts == CheckCounts(success: 11, failure: 1, pending: 0, skipped: 6))
        #expect(failing.checks.totalCount == 18 && !failing.checks.isTruncated)
        let failure = try #require(failing.checks.failures.first)
        #expect(failure.name == "govulncheck" && failure.workflowRunId != nil && failure.databaseId != nil)
        #expect(failure.url?.hasPrefix("https://github.com/acme/widgets/actions/runs/") == true)

        let draft = try #require(response.pullRequestsByIndex[1]?.first)
        #expect(draft.isDraft && draft.chip == .draft && draft.checks.summary == .success)
        #expect(response.pullRequestsByIndex[2]?.first?.chip == .merged)
        #expect(response.pullRequestsByIndex[3]?.first?.reviewDecision == .approved)
        let noChecks = try #require(response.pullRequestsByIndex[4]?.first)
        #expect(noChecks.checks == .empty && noChecks.checks.summary == .none)
        #expect(response.pullRequestsByIndex[5]?.first?.chip == .closed)
        #expect(!String(describing: response).contains("babakks") && !String(describing: response).contains("cli/cli"))
    }

    @Test func parsesStatusContextsAndOutcomes() throws {
        let response = try GitHubPullRequestQuery.parse(GitHubFixtures.data("pr-status-contexts.json"), branchCount: 1,
                                                        repoSlug: "acme/widgets")
        let pr = try #require(response.pullRequestsByIndex[0]?.first)
        #expect(pr.number == 412 && pr.reviewDecision == .changesRequested && pr.mergeable == .conflicting)
        #expect(pr.checks.counts == CheckCounts(success: 2, failure: 6, pending: 4, skipped: 1))
        #expect(pr.checks.totalCount == 130 && pr.checks.isTruncated)
        #expect(pr.checks.summary == .failure)
        let names = pr.checks.failures.map(\.name)
        #expect(names == ["build", "e2e", "deploy-preview", "approval-gate", "ci/external", "ci/legacy"])
        let external = try #require(pr.checks.items.first { $0.name == "ci/external" })
        #expect(external.kind == .statusContext && external.url == "https://ci.example.com/builds/9")
        #expect(external.workflowRunId == nil && external.databaseId == nil)
        // Conclusão desconhecida não conta como sucesso nem como falha.
        #expect(pr.checks.items.first { $0.name == "weird" }?.outcome == .pending)
        #expect(pr.checks.items.first { $0.name == "docs" }?.outcome == .skipped)
    }

    @Test func errorsAreClassified() throws {
        let limited = try GitHubFixtures.data("rate-limited.json")
        #expect(throws: GitHubError.rateLimited(retryAfter: nil)) {
            try GitHubPullRequestQuery.parse(limited, branchCount: 1, repoSlug: "a/b")
        }
        let notFound = Data(#"{"data":{"repository":null},"errors":[{"type":"NOT_FOUND","message":"Could not resolve to a Repository with the name 'a/b'."}]}"#.utf8)
        #expect(throws: GitHubError.repositoryNotFound("a/b")) {
            try GitHubPullRequestQuery.parse(notFound, branchCount: 1, repoSlug: "a/b")
        }
        let saml = Data(#"{"errors":[{"type":"FORBIDDEN","message":"Resource protected by organization SAML enforcement. You must grant your token access: https://github.com/orgs/acme/sso?authorization_request=XYZ"}]}"#.utf8)
        do {
            _ = try GitHubPullRequestQuery.parse(saml, branchCount: 1, repoSlug: "acme/widgets")
            Issue.record("expected failure")
        } catch GitHubError.forbidden(let repo, _, let url) {
            #expect(repo == "acme/widgets" && url?.hasPrefix("https://github.com/orgs/acme/sso") == true)
        }
        #expect(throws: GitHubError.self) { try GitHubPullRequestQuery.parse(Data("[]".utf8), branchCount: 1, repoSlug: "a/b") }
    }

    @Test func commandFailureClassification() {
        func classify(_ stderr: String, code: Int32 = 1, stdout: String = "") -> GitHubError {
            GitHubErrorClassifier.classify(.fail(stderr, code: code, stdout: stdout), repoSlug: "a/b")
        }
        #expect(classify("gh: You have exceeded a secondary rate limit. Retry-After: 120") == .rateLimited(retryAfter: 120))
        #expect(classify("HTTP 401: Bad credentials") == .notAuthenticated(host: "github.com"))
        #expect(classify("To get started with GitHub CLI, please run: gh auth login", code: 4) == .notAuthenticated(host: "github.com"))
        #expect(classify("gh: Could not resolve to a Repository with the name 'a/b'. (HTTP 404)") == .repositoryNotFound("a/b"))
        if case .forbidden(_, _, let url) = classify("HTTP 403: Resource protected by organization SAML enforcement. https://github.com/orgs/x/sso?authorization_request=1") {
            #expect(url?.contains("/sso") == true)
        } else { Issue.record("expected forbidden") }
        if case .commandFailed(_, let code, _) = classify("boom", code: 2) { #expect(code == 2) } else { Issue.record("expected commandFailed") }
    }

    @Test func selectPrefersMatchingHeadThenOpen() throws {
        let response = try GitHubPullRequestQuery.parse(GitHubFixtures.data("pr-status-contexts.json"), branchCount: 1,
                                                        repoSlug: "a/b")
        let base = try #require(response.pullRequestsByIndex[0]?.first)
        func pr(_ number: Int, _ state: PullRequestState, oid: String) -> PullRequestStatus {
            PullRequestStatus(number: number, title: "t", url: "u", state: state, isDraft: false, reviewDecision: nil,
                              mergeable: .unknown, mergeStateStatus: nil, headRefName: base.headRefName, headRefOid: oid,
                              baseRefName: "main", checks: .empty)
        }
        let list = [pr(3, .closed, oid: "aaa"), pr(2, .open, oid: "bbb"), pr(1, .merged, oid: "ccc")]
        #expect(GitHubPullRequestQuery.select(from: list, localHeadOID: nil)?.number == 2)
        #expect(GitHubPullRequestQuery.select(from: list, localHeadOID: "ccc")?.number == 1)
        #expect(GitHubPullRequestQuery.select(from: list, localHeadOID: "zzz")?.number == 2)
        #expect(GitHubPullRequestQuery.select(from: [pr(9, .closed, oid: "x")], localHeadOID: nil)?.number == 9)
        #expect(GitHubPullRequestQuery.select(from: [], localHeadOID: "x") == nil)
    }
}
