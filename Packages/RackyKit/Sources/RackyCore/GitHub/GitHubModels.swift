import Foundation

/// Repositório no GitHub (host, dono, nome) resolvido do remote `origin` (06 §5.4/§5.5).
public struct GitHubRepoRef: Sendable, Hashable {
    public let host: String
    public let owner: String
    public let name: String

    public init(host: String = "github.com", owner: String, name: String) {
        self.host = host
        self.owner = owner
        self.name = name
    }

    public var slug: String { "\(owner)/\(name)" }
    public var webURL: String { "https://\(host)/\(owner)/\(name)" }
}

/// Resultado de `gh auth status`: nunca carrega o token (a linha `Token:` é descartada no parse).
public struct GitHubAuthStatus: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case ghNotInstalled
        case notLoggedIn
        case connected
    }

    public let state: State
    public let host: String
    public let user: String?
    public let scopes: [String]
    /// De onde vem a credencial: "keyring", "GH_TOKEN", "GITHUB_TOKEN", arquivo de config…
    public let tokenSource: String?
    public let gitProtocol: String?

    public var isConnected: Bool { state == .connected }
    public func hasScope(_ scope: String) -> Bool { scopes.contains(scope) }
    /// Escopo suficiente para ler PRs/checks de repositórios privados e criar PRs.
    public var canReadPrivateRepos: Bool { hasScope("repo") }

    public init(state: State, host: String, user: String? = nil, scopes: [String] = [], tokenSource: String? = nil,
                gitProtocol: String? = nil) {
        self.state = state
        self.host = host
        self.user = user
        self.scopes = scopes
        self.tokenSource = tokenSource
        self.gitProtocol = gitProtocol
    }
}

public enum PullRequestState: String, Sendable, Equatable {
    case open = "OPEN"
    case closed = "CLOSED"
    case merged = "MERGED"
}

public enum PullRequestReviewDecision: String, Sendable, Equatable {
    case approved = "APPROVED"
    case changesRequested = "CHANGES_REQUESTED"
    case reviewRequired = "REVIEW_REQUIRED"
}

public enum PullRequestMergeable: String, Sendable, Equatable {
    case mergeable = "MERGEABLE"
    case conflicting = "CONFLICTING"
    case unknown = "UNKNOWN"
}

/// Estado do chip de PR no card (03 §2.6): none / draft / open / merged / closed.
public enum PullRequestChip: Sendable, Equatable {
    case none
    case draft
    case open
    case merged
    case closed
}

/// Resumo agregado dos checks para o ícone do card: pendente, sucesso, falha (com contagem).
public enum ChecksSummaryState: String, Sendable, Equatable {
    case none
    case pending
    case success
    case failure
}

public enum CheckKind: String, Sendable, Equatable {
    case checkRun
    case statusContext
}

/// Classificação de um check individual.
public enum CheckOutcome: String, Sendable, Equatable {
    case success
    case failure
    case pending
    /// `SKIPPED`, `NEUTRAL`, `STALE`: não conta como sucesso nem como falha.
    case skipped
}

public struct CheckItem: Sendable, Equatable, Identifiable {
    public let kind: CheckKind
    public let name: String
    /// `status` do CheckRun (`COMPLETED`, `IN_PROGRESS`, `QUEUED`…) ou `state` do StatusContext.
    public let status: String
    /// `conclusion` do CheckRun (`SUCCESS`, `FAILURE`, `TIMED_OUT`…); nil para StatusContext ou ainda pendente.
    public let conclusion: String?
    public let url: String?
    /// `databaseId` do CheckRun (usado como job no `gh run view --job`).
    public let databaseId: Int?
    /// Run do GitHub Actions a que o check pertence (`gh run view <id> --log-failed`).
    public let workflowRunId: Int?
    public let outcome: CheckOutcome

    public var id: String { "\(kind.rawValue):\(databaseId.map(String.init) ?? name)" }

    /// Falha que entra no texto "Send Failures to {Agent}" (06 §5.7).
    public var isFailure: Bool { outcome == .failure }

    public init(kind: CheckKind, name: String, status: String, conclusion: String?, url: String?, databaseId: Int?,
                workflowRunId: Int?) {
        self.kind = kind
        self.name = name
        self.status = status
        self.conclusion = conclusion
        self.url = url
        self.databaseId = databaseId
        self.workflowRunId = workflowRunId
        self.outcome = Self.classify(kind: kind, status: status, conclusion: conclusion)
    }

    static func classify(kind: CheckKind, status: String, conclusion: String?) -> CheckOutcome {
        switch kind {
        case .statusContext:
            switch status {
            case "SUCCESS": return .success
            case "FAILURE", "ERROR": return .failure
            default: return .pending // PENDING, EXPECTED
            }
        case .checkRun:
            guard status == "COMPLETED" else { return .pending }
            switch conclusion {
            case "SUCCESS": return .success
            case "FAILURE", "TIMED_OUT", "ACTION_REQUIRED", "CANCELLED", "STARTUP_FAILURE": return .failure
            case "SKIPPED", "NEUTRAL", "STALE": return .skipped
            default: return .pending
            }
        }
    }
}

public struct CheckCounts: Sendable, Equatable {
    public var success = 0
    public var failure = 0
    public var pending = 0
    public var skipped = 0
    public var total: Int { success + failure + pending + skipped }
    public init(success: Int = 0, failure: Int = 0, pending: Int = 0, skipped: Int = 0) {
        self.success = success
        self.failure = failure
        self.pending = pending
        self.skipped = skipped
    }
}

public struct ChecksRollup: Sendable, Equatable {
    /// `state` do `statusCheckRollup` (`SUCCESS`, `FAILURE`, `PENDING`, `ERROR`, `EXPECTED`).
    public let rollupState: String?
    public let counts: CheckCounts
    public let items: [CheckItem]
    /// Total informado pelo GitHub (pode passar de `items.count`: a consulta lê 100 contextos).
    public let totalCount: Int

    public var summary: ChecksSummaryState {
        if items.isEmpty { return .none }
        if counts.failure > 0 { return .failure }
        if counts.pending > 0 { return .pending }
        return .success
    }

    public var failures: [CheckItem] { items.filter(\.isFailure) }
    public var isTruncated: Bool { totalCount > items.count }

    public static let empty = ChecksRollup(rollupState: nil, counts: CheckCounts(), items: [], totalCount: 0)

    public init(rollupState: String?, counts: CheckCounts, items: [CheckItem], totalCount: Int) {
        self.rollupState = rollupState
        self.counts = counts
        self.items = items
        self.totalCount = totalCount
    }
}

/// Modelo de PR para a UI (chip no card, painel Checks).
public struct PullRequestStatus: Sendable, Equatable {
    public let number: Int
    public let title: String
    public let url: String
    public let state: PullRequestState
    public let isDraft: Bool
    public let reviewDecision: PullRequestReviewDecision?
    public let mergeable: PullRequestMergeable
    public let mergeStateStatus: String?
    public let headRefName: String
    public let headRefOid: String
    public let baseRefName: String?
    public let checks: ChecksRollup

    public var chip: PullRequestChip {
        switch state {
        case .merged: return .merged
        case .closed: return .closed
        case .open: return isDraft ? .draft : .open
        }
    }

    public init(number: Int, title: String, url: String, state: PullRequestState, isDraft: Bool,
                reviewDecision: PullRequestReviewDecision?, mergeable: PullRequestMergeable, mergeStateStatus: String?,
                headRefName: String, headRefOid: String, baseRefName: String?, checks: ChecksRollup) {
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.isDraft = isDraft
        self.reviewDecision = reviewDecision
        self.mergeable = mergeable
        self.mergeStateStatus = mergeStateStatus
        self.headRefName = headRefName
        self.headRefOid = headRefOid
        self.baseRefName = baseRefName
        self.checks = checks
    }
}

/// Informação de uma branch de sessão: PR (ou ausência dele), frescor e se o HEAD local casa com o do PR.
public struct BranchPullRequestInfo: Sendable, Equatable {
    public let repo: GitHubRepoRef
    public let branch: String
    /// Nil: branch sem PR (consulta feita e nada encontrado).
    public let pullRequest: PullRequestStatus?
    public let fetchedAt: Date
    /// Último estado conhecido, mantido durante backoff ou erro (06 §5.5: "stale").
    public let isStale: Bool
    /// Nil quando o HEAD local não foi informado.
    public let headMatchesLocal: Bool?

    public var chip: PullRequestChip { pullRequest?.chip ?? .none }
}

/// Branch de uma sessão a consultar. `localHeadOID` ajuda a escolher o PR certo e a sinalizar divergência.
public struct SessionBranchQuery: Sendable, Hashable {
    public let repo: GitHubRepoRef
    public let branch: String
    public let localHeadOID: String?

    public init(repo: GitHubRepoRef, branch: String, localHeadOID: String? = nil) {
        self.repo = repo
        self.branch = branch
        self.localHeadOID = localHeadOID
    }
}

public struct GitHubRateLimit: Sendable, Equatable {
    public let cost: Int
    public let remaining: Int
    public let resetAt: Date?
}

public enum GitHubError: Error, Sendable, Equatable {
    case ghNotInstalled
    case notAuthenticated(host: String)
    case launchFailed(String)
    case timedOut
    case cancelled
    case rateLimited(retryAfter: TimeInterval?)
    /// SSO/permissão por repositório: o texto traz o link de autorização devolvido pela API quando existe.
    case forbidden(repo: String, message: String, authorizationURL: String?)
    case repositoryNotFound(String)
    case notAGitHubRemote(String?)
    case invalidResponse(String)
    case commandFailed(command: String, exitCode: Int32, stderr: String)
}
