import Foundation

/// Filtro do env capturado (06 §1.7, passo 2 da composição). Valores nunca passam por aqui em logs.
/// Regra: o que casa com `allow*` sempre fica (vence a denylist); o que casa com `deny*` sai; o resto fica.
public struct EnvFilter: Sendable, Equatable {
    public var denyNames: Set<String>
    public var denyPrefixes: [String]
    public var allowNames: Set<String>
    public var allowPrefixes: [String]

    public init(
        denyNames: Set<String> = [],
        denyPrefixes: [String] = [],
        allowNames: Set<String> = [],
        allowPrefixes: [String] = []
    ) {
        self.denyNames = denyNames
        self.denyPrefixes = denyPrefixes
        self.allowNames = allowNames
        self.allowPrefixes = allowPrefixes
    }

    /// Denylist canônica de 06 §1.7 (revisada a cada versão de CLI) e allowlist do que deve passar como está.
    public static let `default` = EnvFilter(
        denyNames: [
            "PWD", "OLDPWD", "SHLVL", "_", "TERM_SESSION_ID",
            "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT",
            "CODEX_THREAD_ID", "CODEX_SANDBOX", "CODEX_SANDBOX_NETWORK_DISABLED", "CODEX_CI",
            // Artefatos da própria captura: o app define TERM/COLORTERM na composição (passo 3).
            "AB_ENV_OUT", "TERM", "COLORTERM",
        ],
        denyPrefixes: [
            "TERM_PROGRAM", "ITERM_", "WEZTERM_", "KITTY_", "GHOSTTY_", "VSCODE_", "RACKY_",
            // Terminal do Orca: com ORCA_AGENT_HOOK_* os hooks do Orca no Claude mandam os eventos (e as notificações) para o Orca.
            "ORCA_",
            // Marcadores de uma sessão pai do Claude Code (CLAUDE_CODE_CHILD_SESSION desliga o transcript do filho).
            "CLAUDE_CODE_", "CLAUDECODE", "CLAUDE_AGENT_",
            // Sessão/sandbox do Codex pai (CODEX_HOME e afins de configuração do usuário continuam passando).
            "CODEX_THREAD", "CODEX_SANDBOX", "CODEX_SESSION", "CODEX_INTERNAL",
        ],
        allowNames: [
            // Configuração do usuário que o prefixo CLAUDE_CODE_ pegaria sem ser marcador de sessão.
            "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
            "SSH_AUTH_SOCK", "PATH",
            "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "ALL_PROXY",
            "http_proxy", "https_proxy", "no_proxy", "all_proxy",
        ]
    )

    public func keeps(_ name: String) -> Bool {
        if allowNames.contains(name) || allowPrefixes.contains(where: { name.hasPrefix($0) }) { return true }
        if denyNames.contains(name) || denyPrefixes.contains(where: { name.hasPrefix($0) }) { return false }
        return true
    }

    public func apply(to variables: [String: String]) -> [String: String] {
        variables.filter { keeps($0.key) }
    }

    /// Cópia com regras extras (configuração por produto ou por teste).
    public func adding(
        denyNames: Set<String> = [], denyPrefixes: [String] = [],
        allowNames: Set<String> = [], allowPrefixes: [String] = []
    ) -> EnvFilter {
        var copy = self
        copy.denyNames.formUnion(denyNames)
        copy.denyPrefixes.append(contentsOf: denyPrefixes)
        copy.allowNames.formUnion(allowNames)
        copy.allowPrefixes.append(contentsOf: allowPrefixes)
        return copy
    }
}

/// Nomes que parecem segredo (KEY/TOKEN/SECRET/PASS/AUTH). Servem só para sinalizar e redigir; nunca expõem valores.
public enum SecretNames {
    public static func isSecretLike(_ name: String) -> Bool {
        let upper = name.uppercased()
        return ["KEY", "TOKEN", "SECRET", "PASS", "AUTH"].contains { upper.contains($0) }
    }
}
