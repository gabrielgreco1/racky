import Foundation

/// Consulta GraphQL `statusCheckRollup` de PRs por repositório (06 §5.5) e seu parser puro.
public enum GitHubPullRequestQuery {
    /// Máximo de branches por consulta (06 §5.5).
    public static let maxBranchesPerQuery = 20

    /// Texto da consulta para `count` branches. Os nomes das branches vão como variáveis (`$b0…`), nunca
    /// interpolados no texto, para que nomes com aspas ou barras não quebrem nem injetem GraphQL.
    public static func text(branchCount count: Int) -> String {
        let variables = (0..<count).map { ", $b\($0): String!" }.joined()
        let aliases = (0..<count).map {
            "    b\($0): pullRequests(headRefName: $b\($0), first: 3, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { ...PR } }"
        }.joined(separator: "\n")
        return """
        query($owner: String!, $name: String!\(variables)) {
          rateLimit { cost remaining resetAt }
          repository(owner: $owner, name: $name) {
        \(aliases)
          }
        }
        fragment PR on PullRequest {
          number title url state isDraft reviewDecision mergeable mergeStateStatus headRefName headRefOid baseRefName
          commits(last: 1) { nodes { commit { statusCheckRollup {
            state
            contexts(first: 100) { totalCount nodes {
              __typename
              ... on CheckRun { name status conclusion detailsUrl databaseId checkSuite { workflowRun { databaseId } } }
              ... on StatusContext { context state targetUrl }
            } }
          } } } }
        }
        """
    }

    /// Argumentos de `gh api graphql` para um lote de branches (já limitado a `maxBranchesPerQuery`).
    public static func arguments(repo: GitHubRepoRef, branches: [String]) -> [String] {
        var args = ["api", "graphql"]
        if repo.host != "github.com" { args += ["--hostname", repo.host] }
        args += ["-F", "owner=\(repo.owner)", "-F", "name=\(repo.name)"]
        for (index, branch) in branches.enumerated() { args += ["-f", "b\(index)=\(branch)"] }
        args += ["-f", "query=\(text(branchCount: branches.count))"]
        return args
    }

    public struct Response: Sendable, Equatable {
        /// PRs por índice do alias (`b0` → 0), mais recentes primeiro. Vazio: branch sem PR.
        public let pullRequestsByIndex: [Int: [PullRequestStatus]]
        public let rateLimit: GitHubRateLimit?
    }

    public static func parse(_ data: Data, branchCount: Int, repoSlug: String) throws -> Response {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GitHubError.invalidResponse("not a JSON object")
        }
        if let errors = root["errors"] as? [[String: Any]], !errors.isEmpty {
            throw classify(errors: errors, repoSlug: repoSlug)
        }
        guard let payload = root["data"] as? [String: Any] else { throw GitHubError.invalidResponse("missing data") }
        let rate = (payload["rateLimit"] as? [String: Any]).map(parseRateLimit)
        guard let repository = payload["repository"] as? [String: Any] else {
            throw GitHubError.repositoryNotFound(repoSlug)
        }
        var result: [Int: [PullRequestStatus]] = [:]
        for index in 0..<branchCount {
            guard let alias = repository["b\(index)"] as? [String: Any],
                  let nodes = alias["nodes"] as? [[String: Any]] else {
                throw GitHubError.invalidResponse("missing alias b\(index)")
            }
            result[index] = nodes.compactMap(parsePullRequest)
        }
        return Response(pullRequestsByIndex: result, rateLimit: rate)
    }

    static func parseRateLimit(_ object: [String: Any]) -> GitHubRateLimit {
        let reset = (object["resetAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return GitHubRateLimit(cost: object["cost"] as? Int ?? 0, remaining: object["remaining"] as? Int ?? 0,
                               resetAt: reset)
    }

    static func parsePullRequest(_ node: [String: Any]) -> PullRequestStatus? {
        guard let number = node["number"] as? Int,
              let url = node["url"] as? String,
              let stateRaw = node["state"] as? String, let state = PullRequestState(rawValue: stateRaw) else { return nil }
        let rollupNode = ((node["commits"] as? [String: Any])?["nodes"] as? [[String: Any]])?
            .first.flatMap { ($0["commit"] as? [String: Any])?["statusCheckRollup"] as? [String: Any] }
        return PullRequestStatus(
            number: number,
            title: node["title"] as? String ?? "",
            url: url,
            state: state,
            isDraft: node["isDraft"] as? Bool ?? false,
            reviewDecision: (node["reviewDecision"] as? String).flatMap(PullRequestReviewDecision.init(rawValue:)),
            mergeable: (node["mergeable"] as? String).flatMap(PullRequestMergeable.init(rawValue:)) ?? .unknown,
            mergeStateStatus: node["mergeStateStatus"] as? String,
            headRefName: node["headRefName"] as? String ?? "",
            headRefOid: node["headRefOid"] as? String ?? "",
            baseRefName: node["baseRefName"] as? String,
            checks: parseRollup(rollupNode))
    }

    static func parseRollup(_ rollup: [String: Any]?) -> ChecksRollup {
        guard let rollup else { return .empty }
        let contexts = rollup["contexts"] as? [String: Any]
        let nodes = contexts?["nodes"] as? [[String: Any]] ?? []
        var items: [CheckItem] = []
        var counts = CheckCounts()
        for node in nodes {
            let item: CheckItem
            switch node["__typename"] as? String {
            case "CheckRun":
                let run = (node["checkSuite"] as? [String: Any]).flatMap { $0["workflowRun"] as? [String: Any] }
                item = CheckItem(kind: .checkRun, name: node["name"] as? String ?? "check",
                                 status: node["status"] as? String ?? "", conclusion: node["conclusion"] as? String,
                                 url: node["detailsUrl"] as? String, databaseId: node["databaseId"] as? Int,
                                 workflowRunId: run?["databaseId"] as? Int)
            case "StatusContext":
                item = CheckItem(kind: .statusContext, name: node["context"] as? String ?? "status",
                                 status: node["state"] as? String ?? "", conclusion: nil,
                                 url: node["targetUrl"] as? String, databaseId: nil, workflowRunId: nil)
            default:
                continue
            }
            switch item.outcome {
            case .success: counts.success += 1
            case .failure: counts.failure += 1
            case .pending: counts.pending += 1
            case .skipped: counts.skipped += 1
            }
            items.append(item)
        }
        return ChecksRollup(rollupState: rollup["state"] as? String, counts: counts, items: items,
                            totalCount: contexts?["totalCount"] as? Int ?? items.count)
    }

    static func classify(errors: [[String: Any]], repoSlug: String) -> GitHubError {
        let messages = errors.compactMap { $0["message"] as? String }.joined(separator: "; ")
        let types = errors.compactMap { $0["type"] as? String }
        if types.contains("RATE_LIMITED") || messages.localizedCaseInsensitiveContains("rate limit") {
            return .rateLimited(retryAfter: nil)
        }
        if types.contains("NOT_FOUND") || messages.contains("Could not resolve to a Repository") {
            return .repositoryNotFound(repoSlug)
        }
        if types.contains("FORBIDDEN") || messages.localizedCaseInsensitiveContains("SAML") {
            return .forbidden(repo: repoSlug, message: messages, authorizationURL: GitHubErrorClassifier.firstURL(in: messages))
        }
        return .invalidResponse(String(messages.prefix(300)))
    }
}

/// Classifica falhas do `gh api` (saída de erro + corpo) em `GitHubError`.
public enum GitHubErrorClassifier {
    public static func classify(_ result: GitCommandResult, repoSlug: String) -> GitHubError {
        let text = result.stderr + "\n" + result.stdout
        if let data = result.stdout.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errors = root["errors"] as? [[String: Any]], !errors.isEmpty {
            return GitHubPullRequestQuery.classify(errors: errors, repoSlug: repoSlug)
        }
        let lower = text.lowercased()
        if lower.contains("rate limit") || lower.contains("abuse detection") || lower.contains("secondary rate") {
            return .rateLimited(retryAfter: retryAfter(in: text))
        }
        if lower.contains("saml") || lower.contains("sso") {
            return .forbidden(repo: repoSlug, message: summary(text), authorizationURL: firstURL(in: text, containing: "sso"))
        }
        if result.exitCode == 4 || lower.contains("http 401") || lower.contains("gh auth login")
            || lower.contains("bad credentials") {
            return .notAuthenticated(host: "github.com")
        }
        if lower.contains("could not resolve to a repository") || lower.contains("http 404") {
            return .repositoryNotFound(repoSlug)
        }
        if lower.contains("http 403") { return .forbidden(repo: repoSlug, message: summary(text), authorizationURL: nil) }
        return .commandFailed(command: "gh api graphql", exitCode: result.exitCode, stderr: summary(text))
    }

    static func summary(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
    }

    static func retryAfter(in text: String) -> TimeInterval? {
        guard let regex = try? NSRegularExpression(pattern: #"(?i)retry[- ]after:?\s*(\d+)"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return TimeInterval(text[range])
    }

    static func firstURL(in text: String, containing needle: String? = nil) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"https://[^\s"')\]]+"#) else { return nil }
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let url = String(text[range])
            if needle == nil || url.contains(needle!) { return url }
        }
        return nil
    }
}

extension GitHubPullRequestQuery {
    /// Escolhe o PR da sessão entre os candidatos de uma branch (já em ordem de atualização recente):
    /// com `localHeadOID`, o PR cujo head casa; senão o mais recente aberto; senão o mais recente.
    public static func select(from candidates: [PullRequestStatus], localHeadOID: String?) -> PullRequestStatus? {
        if let localHeadOID, let match = candidates.first(where: { $0.headRefOid == localHeadOID && $0.state == .open })
            ?? candidates.first(where: { $0.headRefOid == localHeadOID }) {
            return match
        }
        return candidates.first(where: { $0.state == .open }) ?? candidates.first
    }
}
