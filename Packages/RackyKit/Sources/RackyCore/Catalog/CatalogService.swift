import RackyPlatform
import RackyStore
import Foundation

/// Mantém o índice SQLite do catálogo em dia (06 §4.1; TA-401). A varredura roda no `BlockingIOBridge` (AR-404); o
/// watch usa kqueue por diretório com debounce de 1 s e reconstrói a lista de diretórios a cada refresh, porque
/// pastas de skill novas precisam ser observadas também. Não escreve em nenhuma pasta nativa.
public actor CatalogService {
    private let store: RackyStore
    private var roots: CatalogRoots
    private let debounce: Duration
    private let clock: @Sendable () -> Date
    private var watchers: [String: Task<Void, Never>] = [:]
    private var pendingRefresh: Task<Void, Never>?
    private var continuation: AsyncStream<CatalogDiff>.Continuation?
    private var watching = false

    public private(set) var lastScan: CatalogScan?

    public init(store: RackyStore, roots: CatalogRoots = .current(), debounce: Duration = .seconds(1),
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.roots = roots; self.debounce = debounce; self.clock = clock
    }

    /// Varredura sem tocar no banco (dry-run do catálogo): relatório do que seria indexado.
    public static func dryRun(roots: CatalogRoots) async -> CatalogScan {
        await BlockingIOBridge.run { CatalogScanner.scan(roots) }
    }

    @discardableResult
    public func refresh() async throws -> CatalogDiff {
        let current = roots, now = clock()
        let scan = await BlockingIOBridge.run { CatalogScanner.scan(current, now: now) }
        lastScan = scan
        let diff = try await store.reconcileCatalog(scan.items, at: now)
        if watching { rewatch(scan) }
        return diff
    }

    public func setProjectRoots(_ urls: [URL]) async throws {
        roots.projectRoots = urls
        try await refresh()
    }

    public func items(includeMissing: Bool = false) async throws -> [CatalogRow] {
        try await store.catalogItems(includeMissing: includeMissing)
    }

    // MARK: Watch

    /// Diffs não vazios produzidos pelo watch. Um único consumidor por vez.
    public func startWatching() async throws -> AsyncStream<CatalogDiff> {
        stopWatching()
        let (stream, cont) = AsyncStream.makeStream(of: CatalogDiff.self, bufferingPolicy: .bufferingNewest(16))
        continuation = cont
        watching = true
        try await refresh()
        return stream
    }

    public func stopWatching() {
        watching = false
        for task in watchers.values { task.cancel() }
        watchers = [:]
        pendingRefresh?.cancel(); pendingRefresh = nil
        continuation?.finish(); continuation = nil
    }

    private func targets(_ scan: CatalogScan) -> Set<String> {
        var dirs = Set<String>()
        let fm = FileManager.default
        func existingAncestor(_ url: URL) -> String? {
            var u = url
            for _ in 0..<12 {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue { return u.path }
                u = u.deletingLastPathComponent()
            }
            return nil
        }
        for d in roots.watchedDirectories { if let p = existingAncestor(d) { dirs.insert(p) } }
        for item in scan.items { dirs.insert(URL(fileURLWithPath: item.path).deletingLastPathComponent().path) }
        for plugin in CatalogScanner.installedPlugins(home: roots.home) {
            for sub in ["agents", "skills"] { if let p = existingAncestor(plugin.path.appendingPathComponent(sub)) { dirs.insert(p) } }
        }
        return dirs
    }

    private func rewatch(_ scan: CatalogScan) {
        let wanted = targets(scan)
        for (path, task) in watchers where !wanted.contains(path) { task.cancel(); watchers[path] = nil }
        for path in wanted where watchers[path] == nil {
            guard let stream = try? DirectoryWatcher.changes(of: URL(fileURLWithPath: path, isDirectory: true)) else { continue }
            watchers[path] = Task { [weak self] in
                for await _ in stream { await self?.markDirty() }
            }
        }
    }

    private func markDirty() {
        guard watching, pendingRefresh == nil else { return }
        let wait = debounce
        pendingRefresh = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            await self?.runScheduledRefresh()
        }
    }

    private func runScheduledRefresh() async {
        pendingRefresh = nil
        guard watching else { return }
        if let diff = try? await refresh(), !diff.isEmpty { continuation?.yield(diff) }
    }
}
