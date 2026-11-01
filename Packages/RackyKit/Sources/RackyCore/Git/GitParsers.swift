import Foundation

/// Parsers puros da saída do git (testáveis sem processo).
enum GitParsers {
    /// `git status --porcelain=v2 --branch -z`.
    static func parseStatus(_ output: String) -> GitStatus {
        var branch: String?
        var oid: String?
        var upstream: String?
        var ahead: Int?
        var behind: Int?
        var changed = 0, untracked = 0, conflicted = 0
        var skipNext = false
        for record in output.split(separator: "\0", omittingEmptySubsequences: true) {
            if skipNext { skipNext = false; continue } // caminho de origem de renomeação/cópia
            let line = String(record)
            if line.hasPrefix("# ") {
                let parts = line.dropFirst(2).split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "branch.oid": oid = parts[1] == "(initial)" ? nil : parts[1]
                case "branch.head": branch = parts[1] == "(detached)" ? nil : parts[1]
                case "branch.upstream": upstream = parts[1]
                case "branch.ab":
                    let counts = parts[1].split(separator: " ")
                    if counts.count == 2, let a = Int(counts[0].dropFirst()), let b = Int(counts[1].dropFirst()) {
                        ahead = a
                        behind = b
                    }
                default: break
                }
                continue
            }
            switch line.first {
            case "1": changed += 1
            case "2": changed += 1; skipNext = true
            case "u": conflicted += 1
            case "?": untracked += 1
            default: break
            }
        }
        return GitStatus(branch: branch, headOID: oid, upstream: upstream, ahead: ahead, behind: behind,
                         changedFiles: changed, untrackedFiles: untracked, conflictedFiles: conflicted)
    }

    /// `git worktree list --porcelain -z`. O primeiro bloco é o checkout principal.
    static func parseWorktrees(_ output: String) -> [GitWorktreeInfo] {
        var result: [GitWorktreeInfo] = []
        var fields: [String] = []
        func flush() {
            defer { fields.removeAll() }
            guard let first = fields.first, first.hasPrefix("worktree ") else { return }
            let path = String(first.dropFirst("worktree ".count))
            var head: String?, branch: String?
            var bare = false, detached = false, locked = false, prunable = false
            for field in fields.dropFirst() {
                if field.hasPrefix("HEAD ") { head = String(field.dropFirst(5)) }
                else if field.hasPrefix("branch ") {
                    let ref = String(field.dropFirst(7))
                    branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
                } else if field == "bare" { bare = true }
                else if field == "detached" { detached = true }
                else if field == "locked" || field.hasPrefix("locked ") { locked = true }
                else if field == "prunable" || field.hasPrefix("prunable ") { prunable = true }
            }
            if let value = head, value.allSatisfy({ $0 == "0" }) { head = nil }
            result.append(GitWorktreeInfo(path: path, headOID: head, branch: branch, isMain: result.isEmpty,
                                          isBare: bare, isDetached: detached, isLocked: locked, isPrunable: prunable))
        }
        for token in output.split(separator: "\0", omittingEmptySubsequences: false) {
            if token.isEmpty { flush() } else { fields.append(String(token)) }
        }
        flush()
        return result
    }
}
