import Foundation

/// Marca de alteração de um arquivo (letras de 03 §10.2: M, A, D, U, R; `!` = conflito).
public enum FileChange: String, Sendable, Equatable {
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case untracked = "U"
    case conflicted = "!"
}

/// Arquivos alterados segundo `git status` (porcelain v1), indexados por caminho absoluto.
public struct GitChangeMap: Sendable, Equatable {
    public private(set) var files: [String: FileChange]
    /// Pastas inteiras não rastreadas (`?? dir/`): tudo dentro conta como untracked.
    public private(set) var untrackedDirectories: [String]
    /// Pastas que contêm pelo menos uma alteração (para o ponto na linha da pasta).
    public private(set) var directoriesWithChanges: Set<String>

    public static let empty = GitChangeMap(files: [:], untrackedDirectories: [], directoriesWithChanges: [])

    public init(files: [String: FileChange], untrackedDirectories: [String], directoriesWithChanges: Set<String>) {
        self.files = files
        self.untrackedDirectories = untrackedDirectories
        self.directoriesWithChanges = directoriesWithChanges
    }

    public var isEmpty: Bool { files.isEmpty && untrackedDirectories.isEmpty }
    public var count: Int { files.count }

    public func change(for path: String) -> FileChange? {
        if let direct = files[path] { return direct }
        for directory in untrackedDirectories where path.hasPrefix(directory) { return .untracked }
        return nil
    }

    public func directoryHasChanges(_ path: String) -> Bool {
        directoriesWithChanges.contains(path) || untrackedDirectories.contains { $0.hasPrefix(path.hasSuffix("/") ? path : path + "/") || $0 == path + "/" }
    }

    /// `git status --porcelain=v1 -z`: registros `XY caminho\0`; renomeação e cópia trazem o caminho de origem no registro seguinte.
    public static func parse(porcelainV1 output: String, repositoryRoot: String) -> GitChangeMap {
        var files: [String: FileChange] = [:]
        var untrackedDirs: [String] = []
        var parents: Set<String> = []
        let base = repositoryRoot.hasSuffix("/") ? String(repositoryRoot.dropLast()) : repositoryRoot
        var skipNext = false
        for record in output.split(separator: "\0", omittingEmptySubsequences: true) {
            if skipNext {
                skipNext = false
                continue
            }
            let line = String(record)
            guard line.count > 3 else { continue }
            let x = line[line.startIndex]
            let y = line[line.index(after: line.startIndex)]
            let relative = String(line.dropFirst(3))
            if x == "R" || x == "C" || y == "R" || y == "C" { skipNext = true }
            if x == "!" { continue }
            let change: FileChange
            switch (x, y) {
            case ("?", "?"): change = .untracked
            case ("U", _), (_, "U"), ("A", "A"), ("D", "D"): change = .conflicted
            case ("D", _), (_, "D"): change = .deleted
            case ("R", _), (_, "R"), ("C", _), (_, "C"): change = .renamed
            case ("A", _): change = .added
            default: change = .modified
            }
            if change == .untracked, relative.hasSuffix("/") {
                untrackedDirs.append(base + "/" + relative)
                addParents(of: base + "/" + String(relative.dropLast()), base: base, into: &parents)
                continue
            }
            let absolute = base + "/" + relative
            files[absolute] = change
            addParents(of: absolute, base: base, into: &parents)
        }
        return GitChangeMap(files: files, untrackedDirectories: untrackedDirs, directoriesWithChanges: parents)
    }

    private static func addParents(of path: String, base: String, into parents: inout Set<String>) {
        var current = (path as NSString).deletingLastPathComponent
        while current.count >= base.count, current.hasPrefix(base) {
            parents.insert(current)
            if current == base { break }
            current = (current as NSString).deletingLastPathComponent
        }
    }
}

/// Linhas alteradas de um arquivo (para a calha do visualizador): `git diff HEAD --unified=0`.
public struct LineChangeMarks: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case added, modified, deleted }
    public struct Mark: Sendable, Equatable {
        public var kind: Kind
        /// Linha 1-based. Para `deleted`, a linha depois da qual o texto foi removido (0 = antes da primeira).
        public var line: Int
        public var count: Int
    }

    public var marks: [Mark]

    public static let none = LineChangeMarks(marks: [])

    /// Arquivo novo: tudo é adição.
    public static func allAdded(lineCount: Int) -> LineChangeMarks {
        lineCount > 0 ? LineChangeMarks(marks: [Mark(kind: .added, line: 1, count: lineCount)]) : .none
    }

    public func kind(forLine line: Int) -> Kind? {
        for mark in marks {
            switch mark.kind {
            case .deleted: if line == max(mark.line, 1) { return .deleted }
            default: if line >= mark.line, line < mark.line + mark.count { return mark.kind }
            }
        }
        return nil
    }

    /// Cabeçalhos `@@ -a,b +c,d @@` de um diff com `--unified=0`.
    public static func parse(unifiedDiff: String) -> LineChangeMarks {
        var marks: [Mark] = []
        for line in unifiedDiff.split(separator: "\n", omittingEmptySubsequences: true) where line.hasPrefix("@@") {
            // @@ -12,3 +14,5 @@ ...
            let parts = line.split(separator: " ")
            guard parts.count >= 3, parts[1].hasPrefix("-"), parts[2].hasPrefix("+") else { continue }
            let old = range(parts[1].dropFirst())
            let new = range(parts[2].dropFirst())
            if new.count == 0 {
                marks.append(Mark(kind: .deleted, line: new.start, count: 1))
            } else if old.count == 0 {
                marks.append(Mark(kind: .added, line: new.start, count: new.count))
            } else {
                marks.append(Mark(kind: .modified, line: new.start, count: new.count))
            }
        }
        return LineChangeMarks(marks: marks)
    }

    private static func range(_ text: Substring) -> (start: Int, count: Int) {
        let pieces = text.split(separator: ",", omittingEmptySubsequences: false)
        let start = Int(pieces.first ?? "") ?? 0
        let count = pieces.count > 1 ? (Int(pieces[1]) ?? 1) : 1
        return (start, count)
    }
}

/// Consulta o git para a árvore e o visualizador. Falha (sem git, fora de repositório, timeout) devolve vazio: a árvore nunca depende disto.
public struct FilesGitService: Sendable {
    private let runner: any GitCommandRunning
    private let timeout: Duration

    public init(runner: any GitCommandRunning = GitProcessRunner(), timeout: Duration = .seconds(8)) {
        self.runner = runner
        self.timeout = timeout
    }

    public struct Snapshot: Sendable, Equatable {
        public var repositoryRoot: String?
        public var changes: GitChangeMap
        public var branch: String?
    }

    public func snapshot(at directory: String) async -> Snapshot {
        guard let top = await repositoryRoot(at: directory) else { return Snapshot(repositoryRoot: nil, changes: .empty, branch: nil) }
        let url = URL(fileURLWithPath: top, isDirectory: true)
        let status = try? await runner.run(
            ["status", "--porcelain=v1", "-z", "--untracked-files=normal"], in: url, kind: .read, timeout: timeout)
        let changes = status.flatMap { $0.succeeded ? GitChangeMap.parse(porcelainV1: $0.stdout, repositoryRoot: top) : nil } ?? .empty
        let head = try? await runner.run(["rev-parse", "--abbrev-ref", "HEAD"], in: url, kind: .read, timeout: timeout)
        let branch = head.flatMap { $0.succeeded ? $0.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil }
        return Snapshot(repositoryRoot: top, changes: changes, branch: branch?.isEmpty == false ? branch : nil)
    }

    public func repositoryRoot(at directory: String) async -> String? {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        guard let result = try? await runner.run(["rev-parse", "--show-toplevel"], in: url, kind: .read, timeout: timeout), result.succeeded else {
            return nil
        }
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : FileTreeLoader.canonical(text)
    }

    /// Marcas de linhas alteradas de um arquivo rastreado.
    public func lineMarks(forFile path: String, repositoryRoot: String) async -> LineChangeMarks {
        let url = URL(fileURLWithPath: repositoryRoot, isDirectory: true)
        let prefix = repositoryRoot.hasSuffix("/") ? repositoryRoot : repositoryRoot + "/"
        guard path.hasPrefix(prefix) else { return .none }
        let relative = String(path.dropFirst(prefix.count))
        guard let result = try? await runner.run(
            ["diff", "HEAD", "--no-color", "--no-ext-diff", "--unified=0", "--", relative], in: url, kind: .read, timeout: timeout),
            result.succeeded
        else { return .none }
        return LineChangeMarks.parse(unifiedDiff: result.stdout)
    }
}
