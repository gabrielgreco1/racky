import Foundation

/// Repositório detectado a partir de uma pasta qualquer dentro dele.
public struct GitRepositoryInfo: Sendable, Equatable {
    /// Raiz do checkout que contém a pasta (`rev-parse --show-toplevel`), com symlinks resolvidos.
    public let rootURL: URL
    /// Raiz do checkout principal (igual a `rootURL` fora de worktrees adicionais).
    public let mainRootURL: URL
    public var isLinkedWorktree: Bool { rootURL.path != mainRootURL.path }
    /// Nome do repositório (pasta do checkout principal), usado em `<raiz>/<repo>/<slug>`.
    public var name: String { mainRootURL.lastPathComponent }
}

/// Estado local de um checkout (`status --porcelain=v2 --branch -z`).
public struct GitStatus: Sendable, Equatable {
    /// Nil com HEAD destacado.
    public let branch: String?
    /// Nil em branch recém-criado sem commits.
    public let headOID: String?
    public let upstream: String?
    /// Nil sem upstream.
    public let ahead: Int?
    public let behind: Int?
    public let changedFiles: Int
    public let untrackedFiles: Int
    public let conflictedFiles: Int

    public init(branch: String?, headOID: String?, upstream: String?, ahead: Int?, behind: Int?, changedFiles: Int, untrackedFiles: Int,
                conflictedFiles: Int) {
        self.branch = branch
        self.headOID = headOID
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.changedFiles = changedFiles
        self.untrackedFiles = untrackedFiles
        self.conflictedFiles = conflictedFiles
    }

    public var isDetached: Bool { branch == nil }
    public var hasConflicts: Bool { conflictedFiles > 0 }
    /// Sujo: qualquer alteração rastreada, conflito ou arquivo não rastreado (ignorados não contam).
    public var isDirty: Bool { changedFiles + untrackedFiles + conflictedFiles > 0 }
}

public struct GitWorktreeInfo: Sendable, Equatable {
    public let path: String
    public let headOID: String?
    /// Nome curto do branch; nil se destacado ou bare.
    public let branch: String?
    public let isMain: Bool
    public let isBare: Bool
    public let isDetached: Bool
    public let isLocked: Bool
    public let isPrunable: Bool
}

/// Prefixo de branch (06 §5.2): login/`git config user.name` normalizado, valor custom ou nenhum.
public enum GitBranchPrefix: Sendable, Equatable {
    case gitUsername(String)
    case custom(String)
    case none

    public var value: String? {
        switch self {
        case .none: return nil
        case .gitUsername(let name), .custom(let name):
            let normalized = GitNaming.normalizePrefix(name)
            return normalized.isEmpty ? nil : normalized
        }
    }
}

public enum GitWorktreeSource: Sendable, Equatable {
    /// Branch já existente (local, ou remoto em `origin/<nome>` com tracking).
    case existingBranch(String)
    /// Branch nova a partir de `origin/<default>` (ou `baseRef`).
    case newBranch(slug: String, prefix: GitBranchPrefix, baseRef: String?)
    /// Branch nova com nome exato; se existir, falha com `branchAlreadyExists`.
    case newBranchExact(name: String, baseRef: String?)
}

/// Onde um branch existe (`GitService.lookupBranch`).
public enum GitBranchLookup: Sendable, Equatable { case none, local, remote }

/// Fase da criação de worktree, para a linha pendente da sidebar (03 §2.9).
public enum GitWorktreePhase: Sendable, Equatable { case fetching, creating }

public enum GitFetchPolicy: Sendable, Equatable {
    /// `git fetch origin <default>` (timeout 30 s); falha vira `GitError.fetchFailed`.
    case fetchFirst
    /// "Create Without Fetching": usa a ref local de `origin/<default>` como está.
    case skipFetch
}

public struct GitWorktreeRequest: Sendable, Equatable {
    public var repositoryURL: URL
    public var source: GitWorktreeSource
    /// Raiz das worktrees (P21: `~/Racky/worktrees`); a pasta final é `<raiz>/<repo>/<slug>`.
    public var worktreeRoot: URL
    public var fetch: GitFetchPolicy

    public init(repositoryURL: URL, source: GitWorktreeSource, worktreeRoot: URL,
                fetch: GitFetchPolicy = .fetchFirst) {
        self.repositoryURL = repositoryURL
        self.source = source
        self.worktreeRoot = worktreeRoot
        self.fetch = fetch
    }
}

public struct GitWorktreeCreation: Sendable, Equatable {
    public let path: URL
    public let branch: String
    /// Ref base usada (ex.: `origin/main`); nil ao usar branch existente.
    public let baseRef: String?
    public let fetched: Bool
}

public struct GitWorktreeRemovalOptions: Sendable, Equatable {
    /// Só com confirmação explícita do usuário listando o que será perdido (06 §5.2).
    public var force: Bool
    /// `git branch -d` depois da remoção (nunca `-D`).
    public var deleteBranch: Bool

    public init(force: Bool = false, deleteBranch: Bool = false) {
        self.force = force
        self.deleteBranch = deleteBranch
    }
}

/// Convenções de caminho e nome (P15, 06 §5.2).
public enum GitNaming {
    /// `~/Racky/worktrees` (P21).
    public static func defaultWorktreeRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Racky", isDirectory: true).appendingPathComponent("worktrees", isDirectory: true)
    }

    /// Minúsculas ASCII, hífens, até 40 caracteres; vazio vira "worktree".
    public static func slug(from text: String, maxLength: Int = 40) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        var result = ""
        var pendingHyphen = false
        for scalar in folded.unicodeScalars {
            let isAlnum = (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57)
            if isAlnum {
                if pendingHyphen && !result.isEmpty { result.append("-") }
                pendingHyphen = false
                result.unicodeScalars.append(scalar)
            } else {
                pendingHyphen = true
            }
        }
        if result.count > maxLength {
            result = String(result.prefix(maxLength))
            while result.hasSuffix("-") { result.removeLast() }
        }
        return result.isEmpty ? "worktree" : result
    }

    /// Prefixo seguro como componente de ref: minúsculas ASCII, dígitos, `-`, `_`, `.`; espaços viram hífen.
    public static func normalizePrefix(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var result = ""
        for scalar in folded.unicodeScalars {
            let ok = (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57)
                || scalar == "-" || scalar == "_" || scalar == "."
            if ok { result.unicodeScalars.append(scalar) } else if !result.hasSuffix("-") { result.append("-") }
        }
        var trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        while trimmed.contains("..") { trimmed = trimmed.replacingOccurrences(of: "..", with: ".") }
        if trimmed.hasSuffix(".lock") { trimmed.removeLast(5) }
        return trimmed
    }

    /// Remove `user:password@` de URLs com esquema (`https://`, `ssh://`); formas scp (`git@host:x/y`) ficam como estão.
    public static func stripCredentials(_ url: String) -> String {
        guard let schemeEnd = url.range(of: "://") else { return url }
        let rest = url[schemeEnd.upperBound...]
        let authorityEnd = rest.firstIndex(of: "/") ?? rest.endIndex
        let authority = rest[..<authorityEnd]
        guard let at = authority.lastIndex(of: "@") else { return url }
        // `ssh://git@host/x` não tem segredo (sem senha): só tira o que tem ":" antes do "@".
        let userInfo = authority[..<at]
        guard userInfo.contains(":") || !url.hasPrefix("ssh://") else { return url }
        return String(url[..<schemeEnd.upperBound]) + String(rest[authority.index(after: at)...])
    }

    /// `slug` na primeira tentativa; `slug-2`, `slug-3`… depois.
    public static func candidate(_ slug: String, attempt: Int) -> String {
        attempt <= 1 ? slug : "\(slug)-\(attempt)"
    }
}

extension URL {
    /// Caminho canônico via `realpath` (resolve `/var` para `/private/var`, como o git informa), ou o caminho
    /// padronizado quando ele ainda não existe. `resolvingSymlinksInPath` do Foundation não faz isso.
    var canonicalPath: URL {
        let standardized = standardizedFileURL
        var existing = standardized
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            tail.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        guard let resolved = realpath(existing.path, nil) else { return standardized }
        defer { free(resolved) }
        var result = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        for part in tail { result.appendPathComponent(part, isDirectory: true) }
        return result
    }
}
