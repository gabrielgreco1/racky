import Foundation

/// O que o usuário quer clonar: URL https, SSH (scp-like ou `ssh://`) ou `owner/repo` (que vira https do GitHub).
public struct RepoReference: Sendable, Equatable, Hashable {
    /// URL que vai para `git clone`.
    public let cloneURL: String
    public let host: String?
    public let owner: String?
    /// Nome do repositório sem `.git`: é o nome da pasta de destino.
    public let name: String
    /// Veio como `owner/repo`.
    public let isShorthand: Bool

    public init(cloneURL: String, host: String?, owner: String?, name: String, isShorthand: Bool) {
        self.cloneURL = cloneURL
        self.host = host
        self.owner = owner
        self.name = name
        self.isShorthand = isShorthand
    }

    public var isGitHub: Bool { host == "github.com" }
    public var usesHTTPS: Bool { cloneURL.hasPrefix("https://") }
    /// `owner/repo` quando se sabe o dono; senão só o nome.
    public var displayName: String { owner.map { "\($0)/\(name)" } ?? name }
}

/// Lê o texto digitado no campo "Paste a repository URL or owner/repo". Nunca aceita o que o `git` trataria como opção
/// (`-c...`), protocolos locais (`file:`, `ext::`) nem caminhos com `..`.
public enum RepoReferenceParser {
    public static func parse(_ text: String) -> RepoReference? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !raw.hasPrefix("-"), !raw.contains(where: { $0.isWhitespace || $0.isNewline }),
              raw.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F })
        else { return nil }

        if let schemeRange = raw.range(of: "://") {
            let scheme = raw[..<schemeRange.lowerBound].lowercased()
            guard scheme == "https" || scheme == "ssh" else { return nil }
            let rest = String(raw[schemeRange.upperBound...])
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            let authority = String(rest[..<slash])
            guard let host = hostname(fromAuthority: authority) else { return nil }
            return build(host: host, path: String(rest[rest.index(after: slash)...]), scheme: String(scheme),
                         authority: scheme == "https" ? host : authority, original: raw)
        }
        // scp-like: git@github.com:owner/repo.git
        if let colon = raw.firstIndex(of: ":"), !raw[..<colon].contains("/") {
            let authority = String(raw[..<colon])
            guard authority.contains("@"), let host = hostname(fromAuthority: authority) else { return nil }
            let path = String(raw[raw.index(after: colon)...])
            guard let ref = build(host: host, path: path, scheme: "scp", authority: authority, original: raw) else { return nil }
            return ref
        }
        // github.com/owner/repo (sem esquema)
        let parts = raw.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.count >= 3, parts[0].lowercased() == "github.com" {
            return build(host: "github.com", path: parts.dropFirst().joined(separator: "/"), scheme: "https", authority: "github.com",
                         original: raw)
        }
        // owner/repo
        if parts.count == 2, !raw.hasPrefix("/"), !raw.hasSuffix("/"), validOwner(parts[0]), validName(stripGit(parts[1])) {
            let name = stripGit(parts[1])
            return RepoReference(cloneURL: "https://github.com/\(parts[0])/\(name).git", host: "github.com", owner: parts[0], name: name,
                                 isShorthand: true)
        }
        return nil
    }

    private static func build(host: String, path: String, scheme: String, authority: String, original: String) -> RepoReference? {
        var components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        // `?query` e `#fragment` não fazem parte do caminho do repositório.
        components = components.map { $0.split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? "" }
        guard components.count >= 2, !components.contains(where: { $0.isEmpty || $0 == ".." || $0 == "." }) else { return nil }
        let isGitHub = host == "github.com"
        // No GitHub o repositório são os dois primeiros trechos (`/tree/main`, `/pull/1` ficam de fora).
        let repoParts = isGitHub ? Array(components.prefix(2)) : components
        let name = stripGit(repoParts[repoParts.count - 1])
        guard validName(name), repoParts.dropLast().allSatisfy({ validOwner($0) || !isGitHub }) else { return nil }
        let owner = repoParts.count >= 2 ? repoParts[repoParts.count - 2] : nil
        let cleanPath = (repoParts.dropLast() + [name]).joined(separator: "/")
        let url: String
        switch scheme {
        case "https": url = "https://\(authority)/\(cleanPath).git"
        case "ssh": url = "ssh://\(authority)/\(cleanPath).git"
        default: url = "\(authority):\(cleanPath).git"
        }
        return RepoReference(cloneURL: url, host: host, owner: owner, name: name, isShorthand: false)
    }

    /// `user:pass@host:22` → `host`. Credenciais embutidas na URL não entram no nome do host e são recusadas em https.
    private static func hostname(fromAuthority authority: String) -> String? {
        var host = authority
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }
        host = host.lowercased()
        guard !host.isEmpty, host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }), !host.hasPrefix("-") else { return nil }
        return host
    }

    private static func stripGit(_ name: String) -> String { name.hasSuffix(".git") ? String(name.dropLast(4)) : name }

    private static func validOwner(_ text: String) -> Bool {
        !text.isEmpty && !text.hasPrefix("-") && text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
    }

    private static func validName(_ text: String) -> Bool {
        !text.isEmpty && text != "." && text != ".." && !text.hasPrefix("-") && !text.contains("..")
            && text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
    }
}
