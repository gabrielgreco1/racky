import Foundation

/// Extrai host/dono/repo de URLs de remote (https, ssh://, scp-like). Nunca guarda credenciais embutidas.
public enum GitHubRemoteParser {
    public static func parse(_ remote: String) -> GitHubRepoRef? {
        let raw = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        var host: String?
        var path: String?
        if let schemeEnd = raw.range(of: "://") {
            let rest = String(raw[schemeEnd.upperBound...])
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            var authority = String(rest[..<slash])
            if let at = authority.lastIndex(of: "@") { authority = String(authority[authority.index(after: at)...]) }
            if let colon = authority.firstIndex(of: ":") { authority = String(authority[..<colon]) } // porta
            host = authority
            path = String(rest[rest.index(after: slash)...])
        } else if let colon = raw.firstIndex(of: ":"), !raw[..<colon].contains("/") {
            // scp-like: git@github.com:owner/repo.git
            var authority = String(raw[..<colon])
            if let at = authority.lastIndex(of: "@") { authority = String(authority[authority.index(after: at)...]) }
            host = authority
            path = String(raw[raw.index(after: colon)...])
        }
        guard let host, !host.isEmpty, var path else { return nil }
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix(".git") { path.removeLast(4) }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return GitHubRepoRef(host: host.lowercased(), owner: parts[0], name: parts[1])
    }
}
