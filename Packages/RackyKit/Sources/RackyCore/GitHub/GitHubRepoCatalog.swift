import Foundation

/// Repositório da conta (ou de uma organização) como o `gh repo list` informa (F24).
public struct GitHubRepository: Sendable, Equatable, Identifiable, Hashable {
    public let owner: String
    public let name: String
    public let isPrivate: Bool
    public let language: String?
    public let summary: String?
    public let pushedAt: Date?
    public let updatedAt: Date?

    public init(owner: String, name: String, isPrivate: Bool = false, language: String? = nil, summary: String? = nil,
                pushedAt: Date? = nil, updatedAt: Date? = nil) {
        self.owner = owner
        self.name = name
        self.isPrivate = isPrivate
        self.language = language
        self.summary = summary
        self.pushedAt = pushedAt
        self.updatedAt = updatedAt
    }

    public var id: String { nameWithOwner }
    public var nameWithOwner: String { "\(owner)/\(name)" }
    /// Data que ordena a lista: o último push; sem ele, a última atualização.
    public var activityDate: Date? { pushedAt ?? updatedAt }
    public var reference: RepoReference {
        RepoReference(cloneURL: "https://github.com/\(owner)/\(name).git", host: "github.com", owner: owner, name: name,
                      isShorthand: true)
    }
}

/// Interpreta as saídas JSON do `gh repo list` e a lista de organizações. Sem rede: testável com texto.
public enum GitHubRepoCatalogParser {
    /// Campos pedidos a `gh repo list --json`.
    public static let jsonFields = "name,owner,isPrivate,primaryLanguage,pushedAt,updatedAt,description"

    public static func parseRepos(json: String) throws -> [GitHubRepository] {
        guard let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { throw GitHubError.invalidResponse("repo list") }
        return root.compactMap { item in
            guard let name = item["name"] as? String, !name.isEmpty,
                  let owner = (item["owner"] as? [String: Any])?["login"] as? String, !owner.isEmpty
            else { return nil }
            let language = (item["primaryLanguage"] as? [String: Any])?["name"] as? String
            let description = (item["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return GitHubRepository(
                owner: owner, name: name, isPrivate: item["isPrivate"] as? Bool ?? false,
                language: language.flatMap { $0.isEmpty ? nil : $0 }, summary: description,
                pushedAt: date(item["pushedAt"]), updatedAt: date(item["updatedAt"]))
        }
    }

    /// Uma organização por linha (`gh api user/orgs --jq '.[].login'`).
    public static func parseOrganizations(output: String) -> [String] {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains(" ") }
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: text) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}

/// Lista os repositórios da conta logada e das organizações dela, via `gh` (a credencial é do `gh`; o app nunca vê o
/// token). Ordena por atividade recente, guarda em cache por `ttl` e oferece busca por texto.
public actor GitHubRepoCatalog {
    private struct Cache {
        var repositories: [GitHubRepository]
        var fetchedAt: Date
    }

    private let runner: any GitHubCommandRunning
    private let ttl: TimeInterval
    private let limit: Int
    private let now: @Sendable () -> Date
    private var cache: Cache?
    private var inFlight: Task<[GitHubRepository], any Error>?

    public init(runner: any GitHubCommandRunning = GitHubProcessRunner(), ttl: TimeInterval = 300, limit: Int = 100,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.runner = runner
        self.ttl = ttl
        self.limit = limit
        self.now = now
    }

    /// Lista em cache, mesmo vencida (a UI mostra na hora e atualiza por baixo).
    public func cached() -> [GitHubRepository]? { cache?.repositories }

    public func invalidate() { cache = nil }

    /// Repositórios do usuário e das organizações, mais recentes primeiro. Lança `GitHubError` (`ghNotInstalled`,
    /// `notAuthenticated`, `timedOut`...). Falha em uma organização não derruba a lista.
    public func repositories(forceRefresh: Bool = false) async throws -> [GitHubRepository] {
        if !forceRefresh, let cache, now().timeIntervalSince(cache.fetchedAt) < ttl { return cache.repositories }
        if let inFlight { return try await inFlight.value }
        let task = Task { [runner, limit] in try await Self.load(runner: runner, limit: limit) }
        inFlight = task
        defer { inFlight = nil }
        let result = try await task.value
        cache = Cache(repositories: result, fetchedAt: now())
        return result
    }

    private static func load(runner: any GitHubCommandRunning, limit: Int) async throws -> [GitHubRepository] {
        let mine = try await list(runner: runner, owner: nil, limit: limit)
        var all = mine
        // `read:org` pode faltar no token: sem organizações a lista pessoal continua valendo.
        if let orgsResult = try? await runner.run(["api", "user/orgs", "--paginate", "--jq", ".[].login"], in: nil, timeout: .seconds(20)),
           orgsResult.succeeded {
            let orgs = GitHubRepoCatalogParser.parseOrganizations(output: orgsResult.stdout)
            await withTaskGroup(of: [GitHubRepository].self) { group in
                for org in orgs {
                    group.addTask { (try? await list(runner: runner, owner: org, limit: limit)) ?? [] }
                }
                for await part in group { all.append(contentsOf: part) }
            }
        }
        try Task.checkCancellation()
        return sorted(deduplicated(all))
    }

    private static func list(runner: any GitHubCommandRunning, owner: String?, limit: Int) async throws -> [GitHubRepository] {
        var args = ["repo", "list"]
        if let owner { args.append(owner) }
        args += ["--limit", String(limit), "--json", GitHubRepoCatalogParser.jsonFields]
        let result = try await runner.run(args, in: nil, timeout: .seconds(45))
        guard result.succeeded else {
            throw GitHubErrorClassifier.classify(result, repoSlug: owner ?? "")
        }
        return try GitHubRepoCatalogParser.parseRepos(json: result.stdout)
    }

    static func deduplicated(_ repos: [GitHubRepository]) -> [GitHubRepository] {
        var seen = Set<String>()
        return repos.filter { seen.insert($0.nameWithOwner.lowercased()).inserted }
    }

    static func sorted(_ repos: [GitHubRepository]) -> [GitHubRepository] {
        repos.sorted { a, b in
            switch (a.activityDate, b.activityDate) {
            case let (x?, y?) where x != y: x > y
            case (_?, nil): true
            case (nil, _?): false
            default: a.nameWithOwner.localizedCaseInsensitiveCompare(b.nameWithOwner) == .orderedAscending
            }
        }
    }

    /// Busca por texto: cada palavra precisa aparecer no nome completo, na linguagem ou na descrição (sem diferenciar
    /// maiúsculas). Texto vazio devolve a lista como veio. Nome que começa com o texto vem primeiro; a ordem de
    /// atividade se mantém dentro de cada grupo.
    public nonisolated static func search(_ query: String, in repos: [GitHubRepository]) -> [GitHubRepository] {
        let words = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return repos }
        let matches = repos.filter { repo in
            let haystack = [repo.nameWithOwner, repo.language ?? "", repo.summary ?? ""].joined(separator: " ").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
        let first = words[0]
        let prefixed = matches.filter { $0.name.lowercased().hasPrefix(first) || $0.nameWithOwner.lowercased().hasPrefix(first) }
        let prefixedIDs = Set(prefixed.map(\.id))
        return prefixed + matches.filter { !prefixedIDs.contains($0.id) }
    }
}
