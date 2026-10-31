import Foundation
import Testing
@testable import RackyCore

@Suite struct CheckFailureFormatterTests {
    private func pullRequest() throws -> PullRequestStatus {
        let response = try GitHubPullRequestQuery.parse(GitHubFixtures.data("pr-status-contexts.json"), branchCount: 1,
                                                        repoSlug: "acme/widgets")
        return try #require(response.pullRequestsByIndex[0]?.first)
    }

    @Test func failureSelectionCoversConclusions() throws {
        let names = CheckFailureFormatter.failures(in: try pullRequest()).map(\.name)
        #expect(names.contains("build") && names.contains("e2e") && names.contains("deploy-preview")
            && names.contains("approval-gate") && names.contains("ci/external"))
        #expect(!names.contains("lint") && !names.contains("docs") && !names.contains("windows"))
    }

    @Test func defaultTemplateShape() throws {
        let pr = try pullRequest()
        let failures = CheckFailureFormatter.failures(in: pr)
        let entries = [
            CheckFailureEntry(check: failures[0], logExcerpt: "build\tTest\t2026-10-17T10:00:00Z boom\n"),
            CheckFailureEntry(check: failures.first { $0.name == "ci/external" }!, logExcerpt: "ignored for external"),
        ]
        let text = CheckFailureFormatter.format(pullRequest: pr, entries: entries)
        #expect(text == """
        CI checks failed on PR #412 (https://github.com/acme/widgets/pull/412):
        - build (GitHub Actions): https://github.com/acme/widgets/actions/runs/7100000001/job/8100000001
          boom
        - ci/external (external check): https://ci.example.com/builds/9
        Please investigate and fix.
        """)
    }

    @Test func customTemplateAndMissingLink() throws {
        let pr = try pullRequest()
        let legacy = try #require(pr.checks.items.first { $0.name == "ci/legacy" })
        let text = CheckFailureFormatter.format(pullRequest: pr, entries: [CheckFailureEntry(check: legacy)],
                                                template: "PR {number} {title}\n{failures}\nfix")
        #expect(text == "PR 412 Anonymized PR title mixed checks\n- ci/legacy (external check): no link\nfix")
    }

    @Test func cleanLogStripsAnsiTimestampsAndKeepsLastLines() {
        let raw = "\u{1B}[1;31merror\u{1B}[0m: bad\n2026-10-17T10:00:00.123Z plain line\njob\tstep\t2026-10-17T10:00:01Z \u{1B}[32mok\u{1B}[0m\n\n   \n"
        #expect(CheckFailureFormatter.cleanLog(raw) == "error: bad\nplain line\nok")
        let many = (1...300).map { "line \($0)" }.joined(separator: "\n")
        let cleaned = CheckFailureFormatter.cleanLog(many)
        let lines = cleaned.split(separator: "\n")
        #expect(lines.count == 120 && lines.first == "line 181" && lines.last == "line 300")
    }

    @Test func totalLogBudgetIs12KiB() throws {
        let pr = try pullRequest()
        let actions = CheckFailureFormatter.failures(in: pr).filter { $0.workflowRunId != nil }
        #expect(actions.count == 3 || actions.count == 4)
        let longLog = (1...120).map { "line \($0) " + String(repeating: "x", count: 80) }.joined(separator: "\n")
        let entries = actions.map { CheckFailureEntry(check: $0, logExcerpt: longLog) }
        let text = CheckFailureFormatter.format(pullRequest: pr, entries: entries)
        let logBytes = text.split(separator: "\n").filter { $0.hasPrefix("  ") }.joined(separator: "\n").utf8.count
        // Cada linha de log ganha 2 espaços de indentação; o orçamento vale para o texto do log em si.
        let lineCount = text.split(separator: "\n").filter { $0.hasPrefix("  ") }.count
        #expect(logBytes - 2 * lineCount <= CheckFailureFormatter.maxTotalLogBytes)
        #expect(text.contains("[... truncated ...]"))
        #expect(text.contains("line 120"))  // o fim do log (onde está o erro) é o que fica
    }

    @Test func fitKeepsTailAndMarksCut() {
        let text = (1...50).map { "row \($0)" }.joined(separator: "\n")
        let fitted = CheckFailureFormatter.fit(text, bytes: 60)
        #expect(fitted.utf8.count <= 60 && fitted.hasPrefix("[... truncated ...]") && fitted.hasSuffix("row 50"))
        #expect(CheckFailureFormatter.fit("short", bytes: 60) == "short")
    }
}
