import Foundation

public enum GitHubRefreshMode: Sendable, Equatable {
    /// Janela ativa: 60 s.
    case active
    /// Segundo plano: 5 min.
    case background
}

public struct GitHubPollingPolicy: Sendable, Equatable {
    public var activeInterval: TimeInterval = 60
    public var backgroundInterval: TimeInterval = 300
    /// Com `rateLimit.remaining` abaixo disto o polling vai para `backgroundInterval` (06 §5.5).
    public var lowRemainingThreshold = 200
    /// Backoff exponencial para limite secundário e falhas: base, dobrando até o teto de 15 min.
    public var backoffBase: TimeInterval = 60
    public var backoffMax: TimeInterval = 900
    /// Atraso sugerido à UI para refrescar depois de detectar push (`refs/remotes` mudou).
    public var afterPushDelay: TimeInterval = 5
    /// Tempo da chamada ao `gh api graphql`.
    public var requestTimeout: Duration = .seconds(30)

    public init() {}
}

public struct GitHubRefreshReport: Sendable, Equatable {
    /// Informação por branch consultada (frescas ou stale do cache).
    public var branches: [SessionBranchQuery: BranchPullRequestInfo] = [:]
    /// Quantidade de chamadas `gh api graphql` feitas neste ciclo (1 por repositório e lote de 20).
    public var requestCount = 0
    /// Erro por repositório (não derruba os outros repositórios do ciclo).
    public var errors: [GitHubRepoRef: GitHubError] = [:]
    public var rateLimits: [GitHubRepoRef: GitHubRateLimit] = [:]
}

/// GitHub via `gh` (T2-05, 06 §5): auth herdada, uma consulta GraphQL por repositório com batching das branches
/// das sessões, cache com TTL, backoff e rate limit. Só leituras; "Create PR" é um plano separado.
public actor GitHubService {
    private struct CacheKey: Hashable {
        let repo: GitHubRepoRef
        let branch: String
    }

    private struct CacheEntry {
        var candidates: [PullRequestStatus]
        var fetchedAt: Date
    }

    private struct RepoState {
        var rateLimit: GitHubRateLimit?
        var failures = 0
        var backoffUntil: Date?
        var inFlight = false
    }

    private let runner: any GitHubCommandRunning
    private let git: GitService
    private let policy: GitHubPollingPolicy
    private let now: @Sendable () -> Date
    private var cache: [CacheKey: CacheEntry] = [:]
    private var repoStates: [GitHubRepoRef: RepoState] = [:]

    public init(runner: any GitHubCommandRunning = GitHubProcessRunner(), git: GitService = GitService(),
                policy: GitHubPollingPolicy = GitHubPollingPolicy(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.runner = runner
        self.git = git
        self.policy = policy
        self.now = now
    }

    // MARK: - Auth

    /// `gh auth status` sem expor token. Sem `gh`: `.ghNotInstalled`; sem login: `.notLoggedIn` (06 §5.4).
    public func authStatus(host: String = "github.com") async -> GitHubAuthStatus {
        do {
            let result = try await runner.run(["auth", "status", "--hostname", host], in: nil, timeout: .seconds(15))
            return GitHubAuthParser.parse(output: result.stdout + "\n" + result.stderr, exitCode: result.exitCode,
                                          host: host)
        } catch GitHubError.ghNotInstalled {
            return GitHubAuthStatus(state: .ghNotInstalled, host: host)
        } catch {
            return GitHubAuthStatus(state: .notLoggedIn, host: host)
        }
    }

    // MARK: - Repositório

    /// Resolve owner/repo do remote `origin` do checkout.
    public func resolveRepo(at checkoutURL: URL) async throws -> GitHubRepoRef {
        let remote = try await git.remoteURL(in: checkoutURL)
        guard let remote, let repo = GitHubRemoteParser.parse(remote) else {
            throw GitHubError.notAGitHubRemote(remote)
        }
        return repo
    }

    // MARK: - Pull requests

    /// Último estado conhecido de uma branch, sem rede.
    public func cached(_ query: SessionBranchQuery) -> BranchPullRequestInfo? {
        guard let entry = cache[CacheKey(repo: query.repo, branch: query.branch)] else { return nil }
        return makeInfo(query, entry: entry, stale: isStale(entry, repo: query.repo, mode: .active))
    }

    /// Atualiza as branches das sessões: agrupa por repositório (uma consulta por repo, lotes de 20), pula o que
    /// está fresco no cache, respeita backoff e rate limit e devolve o último estado (stale) quando não consulta.
    public func refresh(_ queries: [SessionBranchQuery], mode: GitHubRefreshMode = .active,
                        force: Bool = false) async -> GitHubRefreshReport {
        var report = GitHubRefreshReport()
        var byRepo: [GitHubRepoRef: [SessionBranchQuery]] = [:]
        var order: [GitHubRepoRef] = []
        for query in queries {
            if byRepo[query.repo] == nil { order.append(query.repo) }
            if !(byRepo[query.repo] ?? []).contains(where: { $0.branch == query.branch && $0.localHeadOID == query.localHeadOID }) {
                byRepo[query.repo, default: []].append(query)
            }
        }
        for repo in order {
            let sessions = byRepo[repo] ?? []
            await refreshRepo(repo, sessions: sessions, mode: mode, force: force, report: &report)
        }
        return report
    }

    /// Troca de branch (ou push): descarta o cache da branch e consulta de imediato (respeitando backoff).
    public func branchDidChange(_ query: SessionBranchQuery) async -> GitHubRefreshReport {
        cache[CacheKey(repo: query.repo, branch: query.branch)] = nil
        return await refresh([query], mode: .active, force: true)
    }

    /// Esquece o cache e o backoff (ex.: depois de `gh auth login`).
    public func reset() {
        cache = [:]
        repoStates = [:]
    }

    /// Próximo instante em que o repositório pode ser consultado (nil: já pode).
    public func nextAllowedRequest(for repo: GitHubRepoRef) -> Date? {
        guard let until = repoStates[repo]?.backoffUntil, until > now() else { return nil }
        return until
    }

    // MARK: - Falhas de check

    /// Log das falhas de um check do Actions: `gh run view <run> --log-failed [--job id]`, já limpo e limitado.
    public func failureLog(for check: CheckItem, repo: GitHubRepoRef) async throws -> String? {
        guard let runId = check.workflowRunId else { return nil }
        var args = ["run", "view", String(runId), "--repo", repo.slug, "--log-failed"]
        if let job = check.databaseId { args += ["--job", String(job)] }
        let result = try await runner.run(args, in: nil, timeout: .seconds(60))
        guard result.succeeded else { return nil }
        let cleaned = CheckFailureFormatter.cleanLog(result.stdout)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Coleta os logs das falhas do PR e monta o texto para colar no agente (sem colar nada).
    public func failureReport(for pullRequest: PullRequestStatus, repo: GitHubRepoRef,
                              template: String = CheckFailureFormatter.defaultTemplate) async -> String {
        var entries: [CheckFailureEntry] = []
        for check in CheckFailureFormatter.failures(in: pullRequest) {
            let log = try? await failureLog(for: check, repo: repo)
            entries.append(CheckFailureEntry(check: check, logExcerpt: log))
        }
        return CheckFailureFormatter.format(pullRequest: pullRequest, entries: entries, template: template)
    }

    // MARK: - Internos

    private func refreshRepo(_ repo: GitHubRepoRef, sessions: [SessionBranchQuery], mode: GitHubRefreshMode,
                             force: Bool, report: inout GitHubRefreshReport) async {
        var state = repoStates[repo] ?? RepoState()
        let branches = uniqueBranches(sessions)
        let stale = branches.filter { branch in
            force || cache[CacheKey(repo: repo, branch: branch)].map { isStale($0, repo: repo, mode: mode) } ?? true
        }
        let blocked = state.backoffUntil.map { $0 > now() } ?? false
        var fetched = Set<String>()
        if !stale.isEmpty, !blocked, !state.inFlight {
            state.inFlight = true
            repoStates[repo] = state
            for chunk in stride(from: 0, to: stale.count, by: GitHubPullRequestQuery.maxBranchesPerQuery).map({
                Array(stale[$0..<min($0 + GitHubPullRequestQuery.maxBranchesPerQuery, stale.count)])
            }) {
                report.requestCount += 1
                do {
                    let response = try await fetch(repo: repo, branches: chunk)
                    let date = now()
                    fetched.formUnion(chunk)
                    for (index, branch) in chunk.enumerated() {
                        cache[CacheKey(repo: repo, branch: branch)] =
                            CacheEntry(candidates: response.pullRequestsByIndex[index] ?? [], fetchedAt: date)
                    }
                    state = repoStates[repo] ?? state
                    if let limit = response.rateLimit {
                        state.rateLimit = limit
                        report.rateLimits[repo] = limit
                    }
                    state.failures = 0
                    state.backoffUntil = nil
                    repoStates[repo] = state
                } catch let error as GitHubError {
                    state = repoStates[repo] ?? state
                    registerFailure(error, state: &state)
                    repoStates[repo] = state
                    report.errors[repo] = error
                    break
                } catch {
                    report.errors[repo] = .launchFailed(String(describing: error))
                    break
                }
            }
            state = repoStates[repo] ?? state
            state.inFlight = false
            repoStates[repo] = state
        }
        for session in sessions {
            guard let entry = cache[CacheKey(repo: repo, branch: session.branch)] else { continue }
            // Stale: devia ser consultada neste ciclo e não foi (backoff, erro ou consulta em andamento).
            let notRefreshed = stale.contains(session.branch) && !fetched.contains(session.branch)
            report.branches[session] = makeInfo(session, entry: entry, stale: notRefreshed)
        }
    }

    private func uniqueBranches(_ sessions: [SessionBranchQuery]) -> [String] {
        var seen = Set<String>()
        return sessions.map(\.branch).filter { seen.insert($0).inserted }
    }

    private func fetch(repo: GitHubRepoRef, branches: [String]) async throws -> GitHubPullRequestQuery.Response {
        let args = GitHubPullRequestQuery.arguments(repo: repo, branches: branches)
        let result = try await runner.run(args, in: nil, timeout: policy.requestTimeout)
        guard result.succeeded else {
            var error = GitHubErrorClassifier.classify(result, repoSlug: repo.slug)
            if case .notAuthenticated = error { error = .notAuthenticated(host: repo.host) }
            throw error
        }
        guard let data = result.stdout.data(using: .utf8) else { throw GitHubError.invalidResponse("not UTF-8") }
        return try GitHubPullRequestQuery.parse(data, branchCount: branches.count, repoSlug: repo.slug)
    }

    private func registerFailure(_ error: GitHubError, state: inout RepoState) {
        state.failures += 1
        let exponential = min(policy.backoffMax, policy.backoffBase * pow(2, Double(state.failures - 1)))
        var delay = exponential
        if case .rateLimited(let retryAfter) = error, let retryAfter { delay = min(policy.backoffMax, max(retryAfter, 1)) }
        if case .repositoryNotFound = error { delay = max(delay, policy.backgroundInterval) }
        state.backoffUntil = now().addingTimeInterval(delay)
    }

    private func interval(for repo: GitHubRepoRef, mode: GitHubRefreshMode) -> TimeInterval {
        let base = mode == .active ? policy.activeInterval : policy.backgroundInterval
        if let remaining = repoStates[repo]?.rateLimit?.remaining, remaining < policy.lowRemainingThreshold {
            return max(base, policy.backgroundInterval)
        }
        return base
    }

    private func isStale(_ entry: CacheEntry, repo: GitHubRepoRef, mode: GitHubRefreshMode) -> Bool {
        now().timeIntervalSince(entry.fetchedAt) >= interval(for: repo, mode: mode)
    }

    private func makeInfo(_ query: SessionBranchQuery, entry: CacheEntry, stale: Bool) -> BranchPullRequestInfo {
        let selected = GitHubPullRequestQuery.select(from: entry.candidates, localHeadOID: query.localHeadOID)
        let matches = query.localHeadOID.flatMap { local in selected.map { $0.headRefOid == local } }
        return BranchPullRequestInfo(repo: query.repo, branch: query.branch, pullRequest: selected,
                                     fetchedAt: entry.fetchedAt, isStale: stale, headMatchesLocal: matches)
    }
}
