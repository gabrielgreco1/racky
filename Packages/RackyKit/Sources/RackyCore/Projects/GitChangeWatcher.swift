import CoreServices
import Foundation

/// Observa pastas com FSEvents (gatilho de refresh do status Git, 06 §5.3). O `latency` do FSEvents já junta rajadas
/// de eventos; o `GitStatusRefresher` aplica o debounce por worktree por cima.
public final class GitChangeWatcher: @unchecked Sendable { // SAFETY: `stream` só muda dentro de `queue.sync`.
    private final class Context {
        let handler: @Sendable ([String]) -> Void
        init(_ handler: @escaping @Sendable ([String]) -> Void) { self.handler = handler }
    }

    private let paths: [String]
    private let latency: TimeInterval
    private let context: Context
    private let queue = DispatchQueue(label: "app.racky.git-watcher", qos: .utility)
    private var stream: FSEventStreamRef?

    public init(paths: [String], latency: TimeInterval = 1.0, handler: @escaping @Sendable ([String]) -> Void) {
        self.paths = paths
        self.latency = latency
        self.context = Context(handler)
    }

    deinit { stop() }

    /// `false` se não há caminhos ou o FSEvents recusou o stream.
    @discardableResult
    public func start() -> Bool { queue.sync { startLocked() } }

    private func startLocked() -> Bool {
        guard stream == nil, !paths.isEmpty else { return stream != nil }
        var streamContext = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(context).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let context = Unmanaged<Context>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(eventPaths, to: NSArray.self)
            let changed = (0..<count).compactMap { array[$0] as? String }
            context.handler(changed)
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(
            nil, callback, &streamContext, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        else { return false }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return false
        }
        stream = created
        return true
    }

    public func stop() { queue.sync { stopLocked() } }

    private func stopLocked() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}

/// Decide quais worktrees precisam de refresh para um lote de eventos de arquivo (puro, testável).
public enum GitEventRouter {
    public struct Target: Sendable, Equatable {
        public let worktreePath: String
        /// Checkout principal do projeto: o `.git` comum dele guarda HEAD/refs/index dos worktrees adicionais.
        public let mainRoot: String
        public init(worktreePath: String, mainRoot: String) {
            self.worktreePath = worktreePath
            self.mainRoot = mainRoot
        }
    }

    /// - Eventos na árvore de trabalho de um worktree o selecionam (exceto dentro de `.git`, que só conta para
    ///   `HEAD`, `index` e `refs/`; `*.lock`, objetos e logs são ruído).
    /// - Eventos relevantes no `.git` comum do principal selecionam todos os worktrees daquele projeto.
    public static func worktrees(for events: [String], targets: [Target]) -> Set<String> {
        var result = Set<String>()
        for event in events {
            if event.hasSuffix(".lock") { continue }
            for target in targets {
                let common = target.mainRoot + "/.git/"
                if event.hasPrefix(common) {
                    let rest = String(event.dropFirst(common.count))
                    if isRelevantGitPath(rest) {
                        for t in targets where t.mainRoot == target.mainRoot { result.insert(t.worktreePath) }
                    }
                } else if event == target.worktreePath || event.hasPrefix(target.worktreePath + "/") {
                    let rest = String(event.dropFirst(target.worktreePath.count))
                    if rest == "/.git" || rest.hasPrefix("/.git/") {
                        // `.git` de worktree adicional é um arquivo; o de um checkout principal já caiu no ramo acima.
                        continue
                    }
                    result.insert(target.worktreePath)
                }
            }
        }
        return result
    }

    static func isRelevantGitPath(_ rest: String) -> Bool {
        rest == "HEAD" || rest == "index" || rest == "packed-refs" || rest.hasPrefix("refs/")
            || rest.hasPrefix("worktrees/") && (rest.hasSuffix("/HEAD") || rest.hasSuffix("/index"))
    }
}
