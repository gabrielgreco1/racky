import Foundation

/// Atualiza o status Git de worktrees em segundo plano (06 §5.3): leituras com `GIT_OPTIONAL_LOCKS=0`, debounce por
/// caminho e no máximo um `status` a cada `minInterval` por worktree. Pedidos durante a espera se juntam ao já agendado
/// (o status é lido na hora de rodar, então o resultado nunca fica velho). Nada aqui roda na main thread.
public actor GitStatusRefresher {
    public typealias Update = @Sendable (_ path: String, _ status: GitStatus) async -> Void

    private struct Entry {
        var task: Task<Void, Never>?
        var lastRun: ContinuousClock.Instant?
        var rerun = false
    }

    private let git: GitService
    private let debounce: Duration
    private let minInterval: Duration
    private let onUpdate: Update
    private var entries: [String: Entry] = [:]
    private var stopped = false
    /// Quantos `git status` já rodaram (testes).
    public private(set) var runCount = 0

    public init(git: GitService, debounce: Duration = .seconds(1), minInterval: Duration = .seconds(2),
                onUpdate: @escaping Update) {
        self.git = git
        self.debounce = debounce
        self.minInterval = minInterval
        self.onUpdate = onUpdate
    }

    /// Pede um refresh. `immediate` (botão Refresh Git, foco da sessão) ignora o debounce, mas não corre em paralelo
    /// com um `status` já em andamento no mesmo worktree.
    public func request(_ path: String, immediate: Bool = false) {
        guard !stopped else { return }
        var entry = entries[path] ?? Entry()
        if entry.task != nil {
            entry.rerun = entry.rerun || immediate
            entries[path] = entry
            return
        }
        entry.task = schedule(path, immediate: immediate, lastRun: entry.lastRun)
        entries[path] = entry
    }

    public func forget(_ path: String) {
        entries[path]?.task?.cancel()
        entries[path] = nil
    }

    public func stop() {
        stopped = true
        for e in entries.values { e.task?.cancel() }
        entries.removeAll()
    }

    private func schedule(_ path: String, immediate: Bool, lastRun: ContinuousClock.Instant?) -> Task<Void, Never> {
        var wait: Duration = immediate ? .zero : debounce
        if let lastRun, !immediate {
            let sinceLast = ContinuousClock.now - lastRun
            if minInterval - sinceLast > wait { wait = minInterval - sinceLast }
        }
        return Task { [wait] in
            if wait > .zero { try? await Task.sleep(for: wait) }
            guard !Task.isCancelled else { return }
            await self.run(path)
        }
    }

    private func run(_ path: String) async {
        runCount += 1
        let status = try? await git.status(at: URL(fileURLWithPath: path, isDirectory: true))
        guard !stopped, entries[path] != nil else { return }
        var entry = entries[path] ?? Entry()
        entry.lastRun = .now
        entry.task = nil
        let again = entry.rerun
        entry.rerun = false
        entries[path] = entry
        if let status { await onUpdate(path, status) }
        if again { request(path, immediate: false) }
    }
}
