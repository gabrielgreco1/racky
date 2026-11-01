import Foundation
import Testing
@testable import RackyCore

/// Leitura real opcional: `RACKY_REAL_GH=1` com `gh` autenticado. Só consultas de leitura (`gh auth status` e
/// uma consulta GraphQL) contra um repositório público pequeno; nada é criado nem alterado. Com
/// `RACKY_EVIDENCE_DIR`, grava o resumo (sem token) em `<dir>/T2-05/real-gh-read.json`.
@Suite struct GitHubRealReadTests {
    static let enabled = ProcessInfo.processInfo.environment["RACKY_REAL_GH"] == "1"

    @Test(.enabled(if: GitHubRealReadTests.enabled))
    func realReadAgainstPublicRepo() async throws {
        let service = GitHubService()
        let auth = await service.authStatus()
        try #require(auth.isConnected, "gh não está autenticado")
        let repo = GitHubRepoRef(owner: "octocat", name: "Hello-World")
        let queries = ["master", "no-such-branch-racky-t2-05"].map { SessionBranchQuery(repo: repo, branch: $0) }
        let report = await service.refresh(queries, force: true)
        #expect(report.errors.isEmpty, "erros: \(report.errors)")
        #expect(report.requestCount == 1)
        #expect(report.branches.count == 2)
        #expect(report.branches[queries[1]]?.pullRequest == nil)
        #expect(report.rateLimits[repo].map { $0.remaining > 0 } == true)

        if let dir = ProcessInfo.processInfo.environment["RACKY_EVIDENCE_DIR"] {
            let master = report.branches[queries[0]]?.pullRequest
            let summary: [String: Any] = [
                "auth": ["state": "connected", "user": auth.user ?? "", "scopes": auth.scopes, "tokenSource": auth.tokenSource ?? ""],
                "repo": repo.slug,
                "requests": report.requestCount,
                "rateLimit": ["cost": report.rateLimits[repo]?.cost ?? 0, "remaining": report.rateLimits[repo]?.remaining ?? 0],
                "masterPR": master.map { ["number": $0.number, "state": $0.state.rawValue, "chip": String(describing: $0.chip),
                                          "checks": String(describing: $0.checks.summary), "totalChecks": $0.checks.totalCount] } as Any,
                "missingBranchHasPR": report.branches[queries[1]]?.pullRequest != nil,
            ]
            let url = URL(fileURLWithPath: dir).appendingPathComponent("T2-05", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
                .write(to: url.appendingPathComponent("real-gh-read.json"))
        }
    }
}
