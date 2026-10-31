import RackyPlatform
import Foundation

// MARK: - Fonte exata dos limites do Claude
//
// O comando `/usage` do Claude Code lê `GET https://api.anthropic.com/api/oauth/usage` (descoberto no pacote instalado,
// `~/.local/share/claude/versions/*`: constante `BASE_API_URL` + `/api/oauth/usage`; beta `oauth-2025-04-20`), autenticado com o
// access token OAuth do próprio Claude Code. A resposta traz `five_hour` e `seven_day` com `utilization` (percentual inteiro
// 0…100, pode passar de 100) e `resets_at` (ISO 8601). Este cliente faz só essa leitura; nunca renova token nem faz login.
//
// P23: o Keychain só é lido depois do clique explícito do usuário em "Show exact limits". O app guarda apenas a decisão (nunca o
// token) e relê o item a cada chamada.

/// Janela devolvida pelo endpoint, já normalizada para 0…1.
public struct ClaudeExactWindow: Sendable, Equatable {
    public var usedFraction: Double
    public var resetsAt: Date?
    public init(usedFraction: Double, resetsAt: Date?) { self.usedFraction = usedFraction; self.resetsAt = resetsAt }
}

public struct ClaudeExactLimits: Sendable, Equatable {
    public var fetchedAt: Date
    public var fiveHour: ClaudeExactWindow?
    public var sevenDay: ClaudeExactWindow?
    public init(fetchedAt: Date, fiveHour: ClaudeExactWindow?, sevenDay: ClaudeExactWindow?) {
        self.fetchedAt = fetchedAt; self.fiveHour = fiveHour; self.sevenDay = sevenDay
    }

    /// Normaliza para o agregador. Janela cujo `resetsAt` já passou virou outra janela: não vale mais.
    public func reported(now: Date) -> ReportedLimits {
        func convert(_ w: ClaudeExactWindow?) -> ReportedLimit? {
            guard let w else { return nil }
            if let r = w.resetsAt, r <= now { return nil }
            return ReportedLimit(usedFraction: w.usedFraction, resetsAt: w.resetsAt)
        }
        return ReportedLimits(fiveHour: convert(fiveHour), sevenDay: convert(sevenDay))
    }
}

public enum ClaudeLimitsResult: Sendable, Equatable {
    case success(ClaudeExactLimits)
    /// Token expirado (pelo `expiresAt` da credencial) ou recusado (401/403): abrir o Claude Code o renova.
    case needsClaudeRefresh
    /// Sem credencial, Keychain negado, sem rede, 429 ou resposta inesperada.
    case unavailable
}

/// Access token da credencial do Claude Code. Nunca é persistido nem logado.
public struct ClaudeOAuthCredential: Sendable, Equatable {
    public var accessToken: String
    public var expiresAt: Date?
    public init(accessToken: String, expiresAt: Date?) { self.accessToken = accessToken; self.expiresAt = expiresAt }
}

public enum ClaudeCredentialError: Error, Sendable, Equatable {
    case notFound
    case denied
    case malformed
}

public protocol ClaudeCredentialSource: Sendable {
    /// Lê a credencial agora (a cada chamada; o chamador não guarda o resultado).
    func read() async throws -> ClaudeOAuthCredential
}

/// Item "Claude Code-credentials" do Keychain do usuário (JSON `{"claudeAiOauth": {"accessToken", "expiresAt" (ms), ...}}`).
/// Lido por `/usr/bin/security`, o mesmo programa com que o Claude Code grava o item: ele já está na lista de acesso do item,
/// então o macOS não pede senha (ler pelo Security framework do app abria o diálogo do Keychain a cada build). O dono pediu
/// que funcione sem nenhum pedido, (P26).
public struct KeychainClaudeCredentialSource: ClaudeCredentialSource {
    public static let service = "Claude Code-credentials"

    public init() {}

    public func read() async throws -> ClaudeOAuthCredential {
        let request = ProcessRequest(executable: URL(fileURLWithPath: "/usr/bin/security"),
                                     arguments: ["find-generic-password", "-s", Self.service, "-w"], timeout: .seconds(10))
        guard let out = try? await ProcessRunner.run(request) else { throw ClaudeCredentialError.denied }
        switch out.exitCode {
        case 0: return try Self.parse(out.stdout)
        case 44: throw ClaudeCredentialError.notFound  // errSecItemNotFound
        default: throw ClaudeCredentialError.denied
        }
    }

    /// Lê só `accessToken` e `expiresAt`; ignora o resto (refresh token, escopos, e-mail).
    public static func parse(_ data: Data) throws -> ClaudeOAuthCredential {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { throw ClaudeCredentialError.malformed }
        var expires: Date?
        if let ms = (oauth["expiresAt"] as? NSNumber)?.doubleValue {
            expires = Date(timeIntervalSince1970: ms > 1e11 ? ms / 1000 : ms)
        }
        return ClaudeOAuthCredential(accessToken: token, expiresAt: expires)
    }
}

/// Transporte HTTP injetável: os testes usam respostas fixture, sem rede.
public protocol ClaudeLimitsTransport: Sendable {
    func get(_ url: URL, headers: [String: String]) async throws -> (status: Int, body: Data)
}

public struct URLSessionClaudeLimitsTransport: ClaudeLimitsTransport {
    public init() {}

    public func get(_ url: URL, headers: [String: String]) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.httpMethod = "GET"
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.waitsForConnectivity = false
        let (data, response) = try await URLSession(configuration: config).data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

public struct ClaudeLimitsClient: Sendable {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let betaHeader = "oauth-2025-04-20"

    private let credentials: any ClaudeCredentialSource
    private let transport: any ClaudeLimitsTransport
    private let clock: @Sendable () -> Date
    private let endpoint: URL

    public init(credentials: any ClaudeCredentialSource = KeychainClaudeCredentialSource(),
                transport: any ClaudeLimitsTransport = URLSessionClaudeLimitsTransport(),
                endpoint: URL = ClaudeLimitsClient.endpoint, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.credentials = credentials; self.transport = transport; self.endpoint = endpoint; self.clock = clock
    }

    /// Uma leitura: relê a credencial, confere a validade, chama o endpoint. Nunca renova o token.
    public func fetch() async -> ClaudeLimitsResult {
        let now = clock()
        let credential: ClaudeOAuthCredential
        do { credential = try await credentials.read() } catch { return .unavailable }
        if let expires = credential.expiresAt, expires <= now { return .needsClaudeRefresh }
        let headers = [
            "Authorization": "Bearer \(credential.accessToken)",
            "anthropic-beta": Self.betaHeader,
            "Accept": "application/json",
            "User-Agent": "racky",
        ]
        guard let response = try? await transport.get(endpoint, headers: headers) else { return .unavailable }
        switch response.status {
        case 200:
            guard let limits = Self.parse(response.body, now: now) else { return .unavailable }
            return .success(limits)
        case 401, 403: return .needsClaudeRefresh
        default: return .unavailable
        }
    }

    /// `{"five_hour": {"utilization": 67.0, "resets_at": "2026-10-17T14:00:00.123456+00:00"}, "seven_day": {...}, ...}`.
    /// `utilization` é percentual (0…100+); `resets_at` aceita ISO 8601 ou epoch (s ou ms). `nil` se não houver nenhuma janela.
    public static func parse(_ data: Data, now: Date) -> ClaudeExactLimits? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func window(_ key: String) -> ClaudeExactWindow? {
            guard let w = obj[key] as? [String: Any], let used = (w["utilization"] as? NSNumber)?.doubleValue, used.isFinite else { return nil }
            var resets: Date?
            if let s = w["resets_at"] as? String { resets = ISOTimestamp.parse(s) }
            else if let n = (w["resets_at"] as? NSNumber)?.doubleValue { resets = Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n) }
            return ClaudeExactWindow(usedFraction: max(0, used / 100), resetsAt: resets)
        }
        let five = window("five_hour")
        let seven = window("seven_day")
        guard five != nil || seven != nil else { return nil }
        return ClaudeExactLimits(fetchedAt: now, fiveHour: five, sevenDay: seven)
    }
}

// MARK: - Decisão do usuário

/// Guarda só a decisão ("mostrar limites exatos"), em arquivo próprio do app. Nunca o token.
public struct ExactLimitsConsentStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    private struct Record: Codable { var enabled: Bool }

    /// Ligado por padrão (P26): só um `false` gravado desliga.
    public func load() -> Bool {
        guard let data = try? Data(contentsOf: url) else { return true }
        return (try? JSONDecoder().decode(Record.self, from: data))?.enabled ?? true
    }

    public func save(_ enabled: Bool) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(Record(enabled: enabled)).write(to: url, options: .atomic)
    }
}

/// Sem credencial: para testes e ambientes que não devem tocar o Keychain nem a rede.
public struct NoClaudeCredentials: ClaudeCredentialSource {
    public init() {}
    public func read() async throws -> ClaudeOAuthCredential { throw ClaudeCredentialError.notFound }
}

extension ClaudeLimitsClient {
    public static let offline = ClaudeLimitsClient(credentials: NoClaudeCredentials())
}

/// Último resultado bom dos limites exatos (só percentuais e horários de reset; nada da credencial).
public struct ExactLimitsCache: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    private struct Window: Codable { var used: Double; var resetsAt: Date? }
    private struct Record: Codable { var fetchedAt: Date; var fiveHour: Window?; var sevenDay: Window? }

    public func load() -> ClaudeExactLimits? {
        guard let data = try? Data(contentsOf: url), let r = try? JSONDecoder().decode(Record.self, from: data) else { return nil }
        func w(_ x: Window?) -> ClaudeExactWindow? { x.map { ClaudeExactWindow(usedFraction: $0.used, resetsAt: $0.resetsAt) } }
        return ClaudeExactLimits(fetchedAt: r.fetchedAt, fiveHour: w(r.fiveHour), sevenDay: w(r.sevenDay))
    }

    public func save(_ limits: ClaudeExactLimits) {
        func w(_ x: ClaudeExactWindow?) -> Window? { x.map { Window(used: $0.usedFraction, resetsAt: $0.resetsAt) } }
        let record = Record(fetchedAt: limits.fetchedAt, fiveHour: w(limits.fiveHour), sevenDay: w(limits.sevenDay))
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(record).write(to: url, options: .atomic)
    }
}
