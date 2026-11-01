import Foundation

// Gatilho de segurança de "Subagent computers" (F12): um hook PreToolUse na ferramenta que cria subagentes (`Agent`, antes `Task`) confere o
// pedido. Se o subagente vai mexer com sites, portais, URLs, scraping ou APIs e NÃO é um `racky-worker-N`, o app não depende de o
// modelo seguir a skill: no Full o hook bloqueia com a instrução de reservar um computador; no Ask o app pergunta ao usuário.
// Funções puras (o helper `racky hook-guard` e os testes usam as mesmas).

public enum SubagentSpawnGuard {
    /// Nomes da ferramenta de spawn nos payloads reais (S-05/S-08: `Agent`; versões antigas: `Task`).
    public static let toolNames: Set<String> = ["Agent", "Task"]
    /// `matcher` do hook em `--settings`.
    public static let matcher = "Agent|Task"
    /// Prazo do hook em `--settings` (o Claude espera isto); o helper responde antes, e o app decide antes do helper.
    public static let hookTimeoutSeconds = 30
    public static let helperBudgetSeconds = 24
    public static let appBudgetSeconds = 20

    public struct Input: Sendable, Equatable {
        public var subagentType: String?
        public var prompt: String
        public var description: String
        public init(subagentType: String?, prompt: String, description: String = "") {
            self.subagentType = subagentType; self.prompt = prompt; self.description = description
        }

        /// `tool_input` do payload do hook.
        public init(toolInput: [String: Any]) {
            self.init(
                subagentType: toolInput["subagent_type"] as? String, prompt: toolInput["prompt"] as? String ?? "",
                description: toolInput["description"] as? String ?? "")
        }

        public var text: String { description + "\n" + prompt }
    }

    public enum Decision: Sendable, Equatable {
        case allow
        case block(reason: String)
        /// Só no Ask: o app mostra o card "Give this subagent a computer?".
        case askUser
    }

    /// `racky-worker-3`: os slots que o app gera por lançamento já levam computador.
    public static func isWorker(_ subagentType: String?) -> Bool {
        (subagentType ?? "").lowercased().hasPrefix("racky-worker")
    }

    private static let keywords: [String] = [
        "site", "sites", "website", "websites", "web site", "web page", "webpage", "portal", "portals", "scrape", "scraping", "scraper",
        "crawl", "crawler", "crawling", "endpoint", "endpoints", "browse", "browsing", "browser", "api", "apis",
        "navegar", "navegue", "raspar", "raspagem", "rastrear", "estudar o site", "estude o site", "estudar o portal", "página web", "pagina web",
        "portais", "sítio", "sitio",
    ]

    private static let webPatterns: [NSRegularExpression] = [
        #"(https?://|www\.)[^\s"'<>)]+"#,
        #"\b[a-z0-9][a-z0-9-]*(\.[a-z0-9][a-z0-9-]*)*\.(com|org|net|gov|edu|io|dev|app|ai|info|us|br|uk|de|fr|es|co|ca|au|local|test|example)\b"#,
        #"\b(localhost|\d{1,3}(\.\d{1,3}){3})(:\d+)?\b"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    private static func folded(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }

    /// O pedido mexe com web: URL ou domínio no texto, ou uma palavra-chave (site, portal, scrape, endpoint, browse, navegar, raspar...).
    public static func involvesWeb(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        for regex in webPatterns where regex.firstMatch(in: text, range: range) != nil { return true }
        let words = folded(text)
        for keyword in keywords {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: folded(keyword)) + "(?![\\p{L}\\p{N}])"
            if words.range(of: pattern, options: .regularExpression) != nil { return true }
        }
        return false
    }

    public static let blockReason = """
        Racky: Subagent computers is on for this session, and this subagent will work on a website, portal, URL or API. Do not spawn a plain \
        subagent for it (it would fetch from the Mac). First call boxes_reserve(names: ["<short target name>"]) to get a computer, then spawn the \
        subagent again with subagent_type set to the `worker` returned for that computer (racky-worker-N), and put the computer name and your \
        brief in its prompt. If boxes_reserve says the user denied it, spawn the plain subagent again.
        """

    /// Full bloqueia; Ask pede ao usuário; fora do escopo (worker, sem web) passa.
    public static func decide(mode: SubagentComputersMode, _ input: Input) -> Decision {
        guard mode.isOn, !isWorker(input.subagentType), involvesWeb(input.text) else { return .allow }
        return mode == .full ? .block(reason: blockReason) : .askUser
    }

    /// Saída do hook para bloquear a chamada (vale também com `--dangerously-skip-permissions`).
    public static func denyOutput(reason: String) -> String {
        let object: [String: Any] = [
            "hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": reason]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
