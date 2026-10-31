import Foundation

/// Item de uma pasta listada pela árvore de arquivos.
public struct FileEntry: Sendable, Equatable, Identifiable {
    public let path: String
    public let name: String
    public let isDirectory: Bool
    /// Link simbólico: nunca é expandido (evita ciclos); abrir lê o destino.
    public let isSymlink: Bool
    /// Ignorado pelas regras (só aparece quando "mostrar ignorados" está ligado).
    public let isIgnored: Bool
    public let size: Int64?

    public var id: String { path }

    public init(path: String, name: String? = nil, isDirectory: Bool, isSymlink: Bool = false, isIgnored: Bool = false, size: Int64? = nil) {
        self.path = path
        self.name = name ?? (path as NSString).lastPathComponent
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.isIgnored = isIgnored
        self.size = size
    }

    public var fileExtension: String { (name as NSString).pathExtension.lowercased() }
}

public struct FileTreeOptions: Sendable, Equatable {
    /// Ligado: mostra `.git`, `node_modules` e o que o `.gitignore` ignora (esmaecidos).
    public var showIgnored: Bool

    public init(showIgnored: Bool = false) { self.showIgnored = showIgnored }
}

/// Resultado da listagem de uma pasta.
public struct FileListing: Sendable, Equatable {
    public var entries: [FileEntry]
    /// Mais itens do que o limite por pasta: o resto não é mostrado.
    public var truncated: Bool
}

/// Lista pastas respeitando `.git`, `node_modules` e `.gitignore` (10-right-panel §2). Síncrono e sem estado: o chamador roda fora do main.
public enum FileTreeLoader {
    /// Itens que nunca aparecem com os ignorados escondidos, independentemente do `.gitignore`.
    public static let builtinHidden: Set<String> = [".git", "node_modules", ".DS_Store"]
    public static let entryLimit = 4000

    /// Caminho real (`~` expandido, `..` resolvido, symlinks seguidos com `realpath`): a árvore, o git e o FSEvents precisam falar
    /// do mesmo caminho (`/tmp` e `/var` são links para `/private/...`). Caminho que não existe volta só normalizado.
    public static func canonical(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        guard let resolved = realpath(standardized, nil) else { return standardized }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Raiz do repositório que contém `path` (sobe até achar `.git` pasta ou arquivo de worktree), se houver.
    public static func repositoryRoot(containing path: String) -> String? {
        var current = path
        let fm = FileManager.default
        while true {
            if fm.fileExists(atPath: (current as NSString).appendingPathComponent(".git")) { return current }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { return nil }
            current = parent
        }
    }

    /// Pilha de `.gitignore` válida para listar `directory`: do repositório (ou de `root` fora de um) até a pasta.
    public static func ignoreStack(for directory: String, root: String) -> GitIgnoreStack {
        let top = repositoryRoot(containing: directory) ?? root
        var chain: [String] = []
        var current = directory
        // Do `directory` subindo até `top` (ou até `root` quando `top` está acima de um caminho que não é filho).
        while true {
            chain.append(current)
            if current == top || current == "/" { break }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }
        var stack = GitIgnoreStack()
        if let excludeText = try? String(contentsOfFile: (top as NSString).appendingPathComponent(".git/info/exclude"), encoding: .utf8) {
            stack.push(GitIgnoreFile(directory: top, contents: excludeText))
        }
        for dir in chain.reversed() {
            let file = (dir as NSString).appendingPathComponent(".gitignore")
            if let text = try? String(contentsOfFile: file, encoding: .utf8) {
                stack.push(GitIgnoreFile(directory: dir, contents: text))
            }
        }
        return stack
    }

    /// Lista `directory` (já canônico). Pastas primeiro, depois nomes em ordem "Finder" sem diferenciar maiúsculas.
    public static func list(directory: String, root: String, options: FileTreeOptions, ancestorIgnored: Bool = false) -> FileListing {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: []) else {
            return FileListing(entries: [], truncated: false)
        }
        let stack = ignoreStack(for: directory, root: root)
        var entries: [FileEntry] = []
        entries.reserveCapacity(min(urls.count, entryLimit))
        for item in urls {
            let name = item.lastPathComponent
            let values = try? item.resourceValues(forKeys: Set(keys))
            let isSymlink = values?.isSymbolicLink ?? false
            let isDir = (values?.isDirectory ?? false) && !isSymlink
            let path = (directory as NSString).appendingPathComponent(name)
            let ignored = ancestorIgnored || builtinHidden.contains(name) || stack.isIgnored(path, isDirectory: isDir)
            if ignored, !options.showIgnored { continue }
            entries.append(
                FileEntry(
                    path: path, name: name, isDirectory: isDir, isSymlink: isSymlink, isIgnored: ignored,
                    size: values?.fileSize.map(Int64.init)))
        }
        entries.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        let truncated = entries.count > entryLimit
        if truncated { entries = Array(entries.prefix(entryLimit)) }
        return FileListing(entries: entries, truncated: truncated)
    }
}

/// Linha achatada da árvore para a lista da UI.
public struct FileTreeRow: Sendable, Equatable, Identifiable {
    public let entry: FileEntry
    public let depth: Int
    public let isExpanded: Bool
    /// Pasta expandida cujo conteúdo ainda não foi lido.
    public let isLoading: Bool

    public var id: String { entry.path }
}

/// Estado puro da árvore: raiz, pastas expandidas e conteúdo já lido. A leitura em si (I/O) fica fora, em quem usa.
public struct FileTreeState: Sendable, Equatable {
    public private(set) var root: String
    public private(set) var expanded: Set<String>
    public private(set) var listings: [String: FileListing]

    public init(root: String, expanded: Set<String> = []) {
        self.root = root
        self.expanded = expanded
        self.listings = [:]
    }

    public func isExpanded(_ path: String) -> Bool { expanded.contains(path) }
    public func isLoaded(_ path: String) -> Bool { listings[path] != nil }

    public mutating func setListing(_ listing: FileListing, for directory: String) { listings[directory] = listing }

    /// Esquece o que foi lido (mudança de opção ou eventos do disco); as pastas expandidas continuam.
    public mutating func invalidate() { listings.removeAll() }

    public mutating func invalidate(directory: String) { listings[directory] = nil }

    public mutating func toggle(_ path: String) {
        if expanded.contains(path) { expanded.remove(path) } else { expanded.insert(path) }
    }

    public mutating func expand(_ path: String) { expanded.insert(path) }
    public mutating func collapse(_ path: String) { expanded.remove(path) }

    /// Expande todas as pastas entre a raiz e `path` (para mostrar um arquivo na árvore). Devolve as que precisam ser lidas.
    @discardableResult
    public mutating func reveal(_ path: String) -> [String] {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return [] }
        var directory = root
        var needed: [String] = []
        let parts = String(path.dropFirst(prefix.count)).split(separator: "/").dropLast()
        for part in parts {
            if !isLoaded(directory) { needed.append(directory) }
            directory = (directory as NSString).appendingPathComponent(String(part))
            expanded.insert(directory)
        }
        if !isLoaded(directory) { needed.append(directory) }
        return needed
    }

    /// Pastas expandidas (e a raiz) cujo conteúdo ainda não foi lido.
    public var pendingDirectories: [String] {
        ([root] + expanded.sorted()).filter { listings[$0] == nil }
    }

    /// Raiz mais as pastas expandidas já lidas: o que precisa ser relido quando o disco muda.
    public var visibleDirectories: [String] {
        ([root] + expanded.sorted()).filter { listings[$0] != nil }
    }

    /// Árvore achatada em profundidade, só com o que está expandido.
    public var rows: [FileTreeRow] {
        var result: [FileTreeRow] = []
        func walk(_ directory: String, depth: Int) {
            guard let listing = listings[directory] else { return }
            for entry in listing.entries {
                let open = entry.isDirectory && expanded.contains(entry.path)
                result.append(FileTreeRow(entry: entry, depth: depth, isExpanded: open, isLoading: open && listings[entry.path] == nil))
                if open { walk(entry.path, depth: depth + 1) }
            }
        }
        walk(root, depth: 0)
        return result
    }

    /// A raiz foi lida e está vazia (para o estado vazio da UI).
    public var isRootEmpty: Bool { listings[root].map { $0.entries.isEmpty } ?? false }
}
