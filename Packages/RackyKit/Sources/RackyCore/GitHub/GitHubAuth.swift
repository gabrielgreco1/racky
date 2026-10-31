import Foundation

/// Interpreta a saída de texto do `gh auth status` (stdout + stderr). A linha `Token:` é descartada sem ser
/// guardada: nenhum valor de token entra no modelo nem em log (06 §5.4, P7).
public enum GitHubAuthParser {
    public static func parse(output: String, exitCode: Int32, host: String) -> GitHubAuthStatus {
        struct Account {
            var user: String?
            var source: String?
            var active = false
            var failed = false
            var proto: String?
            var scopes: [String] = []
        }
        var accounts: [Account] = []
        var inHost = false
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if !rawLine.hasPrefix(" "), !line.isEmpty {
                inHost = line.lowercased() == host.lowercased()
                continue
            }
            guard inHost else { continue }
            let text = line.drop(while: { $0 == "✓" || $0 == "X" || $0 == "-" || $0 == " " })
            if text.hasPrefix("Logged in to"), let account = accountName(String(text)) {
                var entry = Account()
                entry.user = account.user
                entry.source = account.source
                accounts.append(entry)
            } else if text.hasPrefix("Failed to log in to") {
                var entry = Account()
                entry.failed = true
                let parsed = accountName(String(text))
                entry.user = parsed?.user
                entry.source = parsed?.source
                accounts.append(entry)
            } else if !accounts.isEmpty {
                if text.hasPrefix("Active account:") { accounts[accounts.count - 1].active = text.hasSuffix("true") }
                else if text.hasPrefix("Git operations protocol:") {
                    accounts[accounts.count - 1].proto = String(text.dropFirst("Git operations protocol:".count))
                        .trimmingCharacters(in: .whitespaces)
                } else if text.hasPrefix("Token scopes:") {
                    accounts[accounts.count - 1].scopes = String(text.dropFirst("Token scopes:".count))
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " '\"")) }
                        .filter { !$0.isEmpty }
                }
                // "Token: …" é ignorada de propósito.
            }
        }
        let chosen = accounts.first(where: { $0.active && !$0.failed }) ?? accounts.first(where: { !$0.failed })
        guard let chosen else {
            return GitHubAuthStatus(state: .notLoggedIn, host: host)
        }
        return GitHubAuthStatus(state: .connected, host: host, user: chosen.user, scopes: chosen.scopes,
                                tokenSource: chosen.source, gitProtocol: chosen.proto)
    }

    /// "Logged in to github.com account octocat (keyring)" → ("octocat", "keyring").
    private static func accountName(_ text: String) -> (user: String, source: String?)? {
        guard let accountRange = text.range(of: " account ") else { return nil }
        let rest = text[accountRange.upperBound...]
        let user = rest.prefix(while: { $0 != " " })
        guard !user.isEmpty else { return nil }
        var source: String?
        if let open = rest.firstIndex(of: "("), let close = rest.lastIndex(of: ")"), open < close {
            source = String(rest[rest.index(after: open)..<close])
        }
        return (String(user), source)
    }
}
