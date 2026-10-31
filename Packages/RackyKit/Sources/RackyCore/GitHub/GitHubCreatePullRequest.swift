import Foundation

/// Quanto push o "Create Pull Request" precisa fazer antes do `gh pr create` (06 §5.6).
public enum PullRequestPushNeed: Sendable, Equatable {
    /// Upstream existe e nada à frente.
    case none
    /// Sem upstream ou commits à frente: `git push -u origin <branch>`.
    case push

    /// Decide a partir do status local do checkout.
    public static func from(upstream: String?, ahead: Int?) -> PullRequestPushNeed {
        if upstream == nil { return .push }
        return (ahead ?? 0) > 0 ? .push : .none
    }
}

public struct CreatePullRequestRequest: Sendable, Equatable {
    public var repoDirectory: URL
    public var repo: GitHubRepoRef?
    public var head: String
    public var base: String
    public var title: String
    public var body: String
    public var draft: Bool
    public var push: PullRequestPushNeed

    public init(repoDirectory: URL, repo: GitHubRepoRef? = nil, head: String, base: String, title: String,
                body: String = "", draft: Bool = false, push: PullRequestPushNeed = .push) {
        self.repoDirectory = repoDirectory
        self.repo = repo
        self.head = head
        self.base = base
        self.title = title
        self.body = body
        self.draft = draft
        self.push = push
    }
}

public struct PlannedCommand: Sendable, Equatable {
    public enum Tool: String, Sendable, Equatable { case git, gh }
    public let tool: Tool
    public let arguments: [String]

    /// Linha de comando para a prévia (aspas de shell só para leitura; a execução usa argv, nunca shell).
    public var display: String {
        ([tool.rawValue] + arguments.map(Self.shellQuote)).joined(separator: " ")
    }

    static func shellQuote(_ argument: String) -> String {
        if !argument.isEmpty, argument.allSatisfy({ $0.isLetter || $0.isNumber || "-_./:=@%+,".contains($0) }) {
            return argument
        }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public enum CreatePullRequestPlanError: Error, Sendable, Equatable {
    case emptyTitle
    case invalidBranch(String)
}

public struct CreatePullRequestResult: Sendable, Equatable {
    public let url: String?
    public let output: String
}

/// Plano de "Create Pull Request": o que vai rodar, na ordem, com prévia. Construir o plano não executa nada.
public struct CreatePullRequestPlan: Sendable, Equatable {
    public let request: CreatePullRequestRequest
    /// Caminho do arquivo que recebe o corpo (`--body-file`), escolhido por quem monta o plano.
    public let bodyFilePath: String
    public let steps: [PlannedCommand]
    /// "Open Compare on GitHub": `gh pr create --web`.
    public let webAlternative: PlannedCommand

    public var preview: String { steps.map(\.display).joined(separator: "\n") }

    public static func make(_ request: CreatePullRequestRequest, bodyFilePath: String) throws -> CreatePullRequestPlan {
        let title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw CreatePullRequestPlanError.emptyTitle }
        for branch in [request.head, request.base] {
            guard !branch.isEmpty, !branch.hasPrefix("-"), !branch.contains(where: \.isWhitespace) else {
                throw CreatePullRequestPlanError.invalidBranch(branch)
            }
        }
        var steps: [PlannedCommand] = []
        if request.push == .push {
            steps.append(PlannedCommand(tool: .git, arguments: ["push", "-u", "origin", request.head]))
        }
        var create = ["pr", "create", "--base", request.base, "--head", request.head, "--title", title,
                      "--body-file", bodyFilePath]
        if request.draft { create.append("--draft") }
        if let repo = request.repo { create += ["--repo", repo.slug] }
        steps.append(PlannedCommand(tool: .gh, arguments: create))
        var web = ["pr", "create", "--web", "--base", request.base, "--head", request.head, "--title", title]
        if let repo = request.repo { web += ["--repo", repo.slug] }
        return CreatePullRequestPlan(request: request, bodyFilePath: bodyFilePath, steps: steps,
                                     webAlternative: PlannedCommand(tool: .gh, arguments: web))
    }

    /// Executa os passos na ordem, parando no primeiro erro (a UI mantém o overlay com o texto e [Try Again]).
    /// O corpo é gravado em `bodyFilePath` e removido ao final. Chamado só pela UI, depois da confirmação.
    public func execute(git: any GitCommandRunning, gh: any GitHubCommandRunning,
                        timeout: Duration = .seconds(60)) async throws -> CreatePullRequestResult {
        let bodyURL = URL(fileURLWithPath: bodyFilePath)
        try request.body.write(to: bodyURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        var lastOutput = ""
        for step in steps {
            let result: GitCommandResult
            switch step.tool {
            case .git:
                result = try await git.run(step.arguments, in: request.repoDirectory, kind: .write, timeout: timeout)
            case .gh:
                result = try await gh.run(step.arguments, in: request.repoDirectory, timeout: timeout)
            }
            guard result.succeeded else {
                let text = GitHubRedaction.redact(result.stderr.isEmpty ? result.stdout : result.stderr)
                throw GitHubError.commandFailed(command: step.display, exitCode: result.exitCode,
                                                stderr: String(text.prefix(2000)))
            }
            lastOutput = result.stdout
        }
        let url = lastOutput.split(whereSeparator: \.isNewline).map(String.init)
            .last(where: { $0.hasPrefix("https://") })
        return CreatePullRequestResult(url: url, output: lastOutput.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
