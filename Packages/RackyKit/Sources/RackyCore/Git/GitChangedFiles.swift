import Foundation

public enum GitFileChangeKind: String, Sendable, Equatable {
    case added, modified, deleted, untracked

    /// Letra da lista de mudanças (03 §10.2): A/M/D/U.
    public var letter: String {
        switch self {
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        case .untracked: "U"
        }
    }
}

/// Arquivo alterado da worktree contra a base da branch (Source Control, 03 §10.2). Só leitura.
public struct GitFileChange: Sendable, Equatable, Identifiable {
    public let path: String
    public let kind: GitFileChangeKind
    /// Nil em binários e em arquivos não rastreados (sem contagem barata).
    public let additions: Int?
    public let deletions: Int?

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
    /// Pasta relativa ("" na raiz).
    public var directory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir == "." ? "" : dir
    }

    public init(path: String, kind: GitFileChangeKind, additions: Int? = nil, deletions: Int? = nil) {
        self.path = path
        self.kind = kind
        self.additions = additions
        self.deletions = deletions
    }
}

public enum GitChangedFilesParser {
    /// Máximo de linhas na lista; o resto vira "e mais N" na UI.
    public static let limit = 500

    /// `diff --name-status -z`, `diff --numstat -z` (ambos com `--no-renames`) e `ls-files --others -z`.
    public static func parse(nameStatus: String, numstat: String, untracked: String) -> [GitFileChange] {
        var stats: [String: (Int?, Int?)] = [:]
        for record in numstat.split(separator: "\0", omittingEmptySubsequences: true) {
            let parts = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            stats[String(parts[2])] = (Int(parts[0]), Int(parts[1]))  // "-" (binário) vira nil
        }
        var changes: [GitFileChange] = []
        let fields = nameStatus.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var index = 0
        while index + 1 < fields.count {
            let code = fields[index], path = fields[index + 1]
            index += 2
            let kind: GitFileChangeKind
            switch code.first {
            case "A": kind = .added
            case "D": kind = .deleted
            default: kind = .modified
            }
            let stat = stats[path]
            changes.append(GitFileChange(path: path, kind: kind, additions: stat?.0, deletions: stat?.1))
        }
        let known = Set(changes.map(\.path))
        for path in untracked.split(separator: "\0", omittingEmptySubsequences: true).map(String.init) where !known.contains(path) {
            changes.append(GitFileChange(path: path, kind: .untracked))
        }
        changes.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return changes
    }
}

extension GitService {
    /// Arquivos alterados da worktree em relação ao ponto onde a branch saiu de `baseRef` (merge-base) — commits locais,
    /// alterações no disco e arquivos novos. Sem `baseRef` (ou sem merge-base), só o que difere do HEAD. Somente leitura.
    public func changedFiles(at checkoutURL: URL, baseRef: String?) async throws -> [GitFileChange] {
        var reference = "HEAD"
        if let baseRef, !baseRef.isEmpty, !baseRef.hasPrefix("-") {
            let raw = try await readOutput(["merge-base", "HEAD", baseRef], in: checkoutURL)
            let mergeBase = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !mergeBase.isEmpty { reference = mergeBase }
        }
        let common = ["-c", "core.quotepath=false", "diff", "--no-renames", "--no-color"]
        let nameStatus = try await readOutput(common + ["--name-status", "-z", reference], in: checkoutURL)
        let numstat = try await readOutput(common + ["--numstat", "-z", reference], in: checkoutURL)
        let untracked = try await readOutput(["ls-files", "--others", "--exclude-standard", "-z"], in: checkoutURL)
        let parsed = GitChangedFilesParser.parse(nameStatus: nameStatus ?? "", numstat: numstat ?? "", untracked: untracked ?? "")
        return Array(parsed.prefix(GitChangedFilesParser.limit))
    }
}
