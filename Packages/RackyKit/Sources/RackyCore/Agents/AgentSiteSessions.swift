import Foundation

/// Sites logados de um agente (backlog 25 d, g): depois do Take over, os cookies do site vão cifrados para o cofre
/// (item `sidecarOnly`: nunca vira variável de ambiente) e são carregados no computador antes de o agente começar.
public enum AgentSiteSessions {
    public struct Cookie: Codable, Sendable, Equatable {
        public var name: String
        public var value: String
        public var domain: String
        public var path: String
        /// Segundos desde 1970; `nil` = cookie de sessão.
        public var expires: Double?
        public var secure: Bool
        public var httpOnly: Bool
        public var sameSite: String?

        public init(name: String, value: String, domain: String, path: String = "/", expires: Double? = nil, secure: Bool = false, httpOnly: Bool = false, sameSite: String? = nil) {
            self.name = name; self.value = value; self.domain = domain; self.path = path; self.expires = expires
            self.secure = secure; self.httpOnly = httpOnly; self.sameSite = sameSite
        }

        /// Lê um cookie no formato que o runtime do navegador devolve (`browser_cookies get`).
        public init?(json: [String: Any]) {
            guard let name = json["name"] as? String, let value = json["value"] as? String, let domain = json["domain"] as? String else { return nil }
            let exp = (json["expires"] as? Double) ?? (json["expires"] as? Int).map(Double.init)
            self.init(
                name: name, value: value, domain: domain, path: (json["path"] as? String) ?? "/", expires: (exp ?? -1) > 0 ? exp : nil,
                secure: (json["secure"] as? Bool) ?? false, httpOnly: (json["httpOnly"] as? Bool) ?? false, sameSite: json["sameSite"] as? String)
        }

        /// Formato aceito por `browser_cookies set`.
        public var runtimeObject: [String: Any] {
            var o: [String: Any] = ["name": name, "value": value, "domain": domain, "path": path, "secure": secure, "httpOnly": httpOnly]
            if let expires { o["expires"] = expires }
            if let sameSite { o["sameSite"] = sameSite }
            return o
        }
    }

    public static func secretName(agent: String, host: String) -> String { "site:\(agent):\(host)" }

    /// O cookie vale para o host (`.github.com` serve `api.github.com`; `github.com` não serve `evilgithub.com`).
    public static func matches(_ cookie: Cookie, host: String) -> Bool {
        let d = cookie.domain.lowercased().drop(while: { $0 == "." }), h = host.lowercased()
        return h == d || h.hasSuffix("." + d)
    }

    public static func cookies(forHost host: String, in all: [Cookie]) -> [Cookie] { all.filter { matches($0, host: host) } }

    /// A sessão vale até o último cookie com validade expirar; só cookies de sessão = sem data.
    public static func expiry(of cookies: [Cookie]) -> Date? {
        cookies.compactMap(\.expires).max().map { Date(timeIntervalSince1970: $0) }
    }

    public static func encode(_ cookies: [Cookie]) throws -> String {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return String(decoding: try e.encode(cookies), as: UTF8.self)
    }

    public static func decode(_ text: String) -> [Cookie] { (try? JSONDecoder().decode([Cookie].self, from: Data(text.utf8))) ?? [] }

    /// Guarda (ou troca) os cookies do site no cofre. Devolve quando a sessão vence.
    @discardableResult
    public static func save(vault: SecretVault, agent: String, host: String, cookies all: [Cookie]) async throws -> Date? {
        let mine = cookies(forHost: host, in: all)
        let value = try encode(mine)
        let name = secretName(agent: agent, host: host)
        if let existing = try await vault.list().first(where: { $0.name == name }) {
            try await vault.rotate(id: existing.id, newValue: value)
        } else {
            try await vault.create(NewSecret(name: name, value: value, delivery: .sidecarOnly, note: "Logged-in session for \(host)"))
        }
        return expiry(of: mine)
    }

    /// Cookies guardados para o site, ainda dentro da validade (cookies vencidos não voltam ao navegador).
    public static func load(vault: SecretVault, agent: String, host: String, now: Date = Date()) async throws -> [Cookie] {
        let name = secretName(agent: agent, host: host)
        guard let info = try await vault.list().first(where: { $0.name == name }) else { return [] }
        let value = try await vault.reveal(id: info.id)
        return decode(value.text).filter { ($0.expires ?? .infinity) > now.timeIntervalSince1970 }
    }
}

// MARK: Computador (runtime `cookies`)

extension AgentSiteSessions {
    /// Cookies como o runtime do navegador os devolve (`{"cookies": [...]}`).
    public static func cookies(fromRuntime json: JSON?) -> [Cookie] {
        guard let array = json?["cookies"]?.array,
              let objects = (try? JSONSerialization.jsonObject(with: JSON.array(array).data(pretty: false))) as? [[String: Any]] else { return [] }
        return objects.compactMap(Cookie.init(json:))
    }

    /// Argumentos de `runtime("cookies")` para pôr os cookies no navegador do computador.
    public static func runtimeSetArguments(_ cookies: [Cookie]) -> JSON {
        let data = (try? JSONSerialization.data(withJSONObject: cookies.map(\.runtimeObject))) ?? Data("[]".utf8)
        let list = (try? JSON.parse(data)) ?? .array([])
        return .object(["action": .string("set"), "cookies": list])
    }

    /// Lê os cookies do site no navegador do computador (depois do Take over, com o login feito).
    public static func capture(from backend: any ComputerBackend, host: String) async throws -> [Cookie] {
        let out = try await backend.runtime("cookies", ["action": "get"], timeout: 15)
        return cookies(forHost: host, in: cookies(fromRuntime: out))
    }

    /// Carrega os cookies guardados no navegador do computador, antes de o agente começar.
    public static func restore(_ cookies: [Cookie], into backend: any ComputerBackend) async throws {
        guard !cookies.isEmpty else { return }
        _ = try await backend.runtime("cookies", runtimeSetArguments(cookies), timeout: 15)
    }
}
