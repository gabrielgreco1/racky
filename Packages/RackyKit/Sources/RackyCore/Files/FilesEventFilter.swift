import Foundation

/// Para que serve um evento do FSEvents da raiz da árvore.
public enum FilesEventKind: Sendable, Equatable {
    /// Ruído: `.git` interno, objetos, `node_modules` (com ignorados escondidos), arquivos de lock.
    case ignored
    /// Só o status do git pode ter mudado (HEAD, índice, refs).
    case gitOnly
    /// Arquivo ou pasta do projeto: relê a árvore e o status.
    case tree
}

/// Filtro puro dos eventos de arquivo (10-right-panel §2: FSEvents ignora `.git`, `node_modules` e `.gitignore`). Roda para cada
/// evento antes de qualquer trabalho, então precisa ser barato.
public enum FilesEventFilter {
    public static func classify(_ path: String, root: String, showIgnored: Bool) -> FilesEventKind {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path == root || path.hasPrefix(prefix) else { return .ignored }
        if path.hasSuffix(".lock") { return .ignored }
        let relative = path == root ? "" : String(path.dropFirst(prefix.count))
        if relative == ".git" || relative.hasPrefix(".git/") {
            let inner = relative.dropFirst(relative.hasPrefix(".git/") ? 5 : 4)
            if inner == "HEAD" || inner == "index" || inner == "packed-refs" || inner.hasPrefix("refs/") { return .gitOnly }
            return .ignored
        }
        if !showIgnored {
            if relative == "node_modules" || relative.hasPrefix("node_modules/") || relative.contains("/node_modules/") { return .ignored }
            if relative.hasSuffix("/.DS_Store") || relative == ".DS_Store" { return .ignored }
        }
        return .tree
    }

    /// Resume um lote de eventos: o que precisa ser relido.
    public static func summarize(_ paths: [String], root: String, showIgnored: Bool) -> (tree: Bool, git: Bool, paths: [String]) {
        var tree = false, git = false
        var touched: [String] = []
        for path in paths {
            switch classify(path, root: root, showIgnored: showIgnored) {
            case .ignored: continue
            case .gitOnly: git = true
            case .tree:
                tree = true
                git = true
                touched.append(path)
            }
        }
        return (tree, git, touched)
    }
}
