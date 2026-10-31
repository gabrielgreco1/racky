import Foundation
import Testing
@testable import RackyCore

@Suite struct GitHubCreatePullRequestTests {
    private let dir = URL(fileURLWithPath: "/tmp/racky-no-such-checkout")
    private let repo = GitHubRepoRef(owner: "acme", name: "widgets")

    private func request(push: PullRequestPushNeed = .push, draft: Bool = false, body: String = "Body text") -> CreatePullRequestRequest {
        CreatePullRequestRequest(repoDirectory: dir, repo: repo, head: "dev/fix-it", base: "main",
                                 title: "Fix it", body: body, draft: draft, push: push)
    }

    @Test func planListsPushThenCreateWithPreview() throws {
        let plan = try CreatePullRequestPlan.make(request(), bodyFilePath: "/tmp/body.md")
        #expect(plan.steps.map(\.tool) == [.git, .gh])
        #expect(plan.steps[0].arguments == ["push", "-u", "origin", "dev/fix-it"])
        #expect(plan.steps[1].arguments == ["pr", "create", "--base", "main", "--head", "dev/fix-it", "--title", "Fix it",
                                            "--body-file", "/tmp/body.md", "--repo", "acme/widgets"])
        #expect(plan.preview == "git push -u origin dev/fix-it\n"
            + "gh pr create --base main --head dev/fix-it --title 'Fix it' --body-file /tmp/body.md --repo acme/widgets")
        #expect(plan.webAlternative.display == "gh pr create --web --base main --head dev/fix-it --title 'Fix it' --repo acme/widgets")
    }

    @Test func draftAndNoPush() throws {
        let plan = try CreatePullRequestPlan.make(request(push: .none, draft: true), bodyFilePath: "/tmp/b.md")
        #expect(plan.steps.count == 1 && plan.steps[0].tool == .gh)
        #expect(plan.steps[0].arguments.contains("--draft"))
    }

    @Test func pushNeedFromStatus() {
        #expect(PullRequestPushNeed.from(upstream: nil, ahead: nil) == .push)
        #expect(PullRequestPushNeed.from(upstream: "origin/x", ahead: 2) == .push)
        #expect(PullRequestPushNeed.from(upstream: "origin/x", ahead: 0) == .none)
    }

    @Test func titleWithQuotesIsQuotedInPreviewOnly() throws {
        var r = request()
        r.title = "Don't break $HOME; \"ok\""
        let plan = try CreatePullRequestPlan.make(r, bodyFilePath: "/tmp/b.md")
        #expect(plan.steps[1].arguments.contains("Don't break $HOME; \"ok\""))
        #expect(plan.preview.contains("'Don'\\''t break $HOME; \"ok\"'"))
    }

    @Test func validation() {
        var r = request()
        r.title = "   "
        #expect(throws: CreatePullRequestPlanError.emptyTitle) { try CreatePullRequestPlan.make(r, bodyFilePath: "/tmp/b") }
        r = request()
        r.head = "--upload-pack=evil"
        #expect(throws: CreatePullRequestPlanError.invalidBranch("--upload-pack=evil")) {
            try CreatePullRequestPlan.make(r, bodyFilePath: "/tmp/b")
        }
        r = request()
        r.base = "has space"
        #expect(throws: CreatePullRequestPlanError.invalidBranch("has space")) { try CreatePullRequestPlan.make(r, bodyFilePath: "/tmp/b") }
    }

    @Test func buildingThePlanRunsNothing() throws {
        // `make` é puro: não toca em arquivo nem processo (o corpo só é gravado em `execute`).
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("plan-\(UUID().uuidString).md").path
        _ = try CreatePullRequestPlan.make(request(), bodyFilePath: path)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func executeWithFakeRunnersWritesBodyThenCleansUp() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("plan-\(UUID().uuidString).md").path
        let plan = try CreatePullRequestPlan.make(request(), bodyFilePath: path)
        let git = FakeGitRunner()
        let seenBody = BodyBox()
        let gh = FakeGitHubRunner { args in
            seenBody.value = try? String(contentsOfFile: args[args.firstIndex(of: "--body-file")! + 1], encoding: .utf8)
            return .ok("Creating pull request for dev/fix-it into main in acme/widgets\n\nhttps://github.com/acme/widgets/pull/77\n")
        }
        let result = try await plan.execute(git: git, gh: gh)
        #expect(git.calls == [["push", "-u", "origin", "dev/fix-it"]])
        #expect(gh.calls.count == 1 && gh.calls[0].prefix(2) == ["pr", "create"])
        #expect(seenBody.value == "Body text")
        #expect(result.url == "https://github.com/acme/widgets/pull/77")
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func pushFailureStopsBeforeCreateAndKeepsText() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("plan-\(UUID().uuidString).md").path
        let plan = try CreatePullRequestPlan.make(request(), bodyFilePath: path)
        let git = FakeGitRunner(result: .fail("remote: Permission to acme/widgets.git denied\nfatal: unable to access"))
        let gh = FakeGitHubRunner { _ in .ok("should not run") }
        do {
            _ = try await plan.execute(git: git, gh: gh)
            Issue.record("expected failure")
        } catch GitHubError.commandFailed(let command, let code, let stderr) {
            #expect(command == "git push -u origin dev/fix-it" && code == 1)
            #expect(stderr.contains("Permission to acme/widgets.git denied"))
        }
        #expect(gh.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}

private final class BodyBox: @unchecked Sendable { // SAFETY: escrito/lido em sequência dentro de um único teste.
    var value: String?
}
