import Foundation

/// Espera injetável (segundos). Produção usa o relógio real; testes usam `ManualScheduler`, sem sleeps reais.
public typealias DSSleep = @MainActor @Sendable (TimeInterval) async -> Void

/// Espera real, cancelável: quem chama confere `Task.isCancelled` depois.
public let dsSystemSleep: DSSleep = { seconds in
    try? await Task.sleep(for: .seconds(seconds))
}

/// Agendador manual para testes determinísticos: o tempo só avança com `advance(by:)`.
/// O tempo virtual (`now`) também serve de relógio para as políticas que medem intervalos.
@MainActor
public final class ManualScheduler {
    private struct Waiter {
        let id: Int
        let due: TimeInterval
        let continuation: CheckedContinuation<Void, Never>
    }

    public private(set) var now: TimeInterval = 0
    private var waiters: [Waiter] = []
    private var nextID = 0

    public init() {}

    /// Quantas esperas estão pendentes.
    public var pendingCount: Int { waiters.count }

    public var sleep: DSSleep {
        { [self] seconds in await wait(seconds) }
    }

    private func wait(_ seconds: TimeInterval) async {
        let id = nextID
        nextID += 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append(Waiter(id: id, due: now + seconds, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor [self] in cancel(id) }
        }
    }

    private func cancel(_ id: Int) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: i).continuation.resume()
    }

    /// Cede a thread até haver `count` esperas registradas (as Tasks criadas pelo código testado ainda precisam rodar).
    public func waitForSleepers(_ count: Int = 1) async {
        var spins = 0
        while waiters.count < count, spins < 10_000 {
            await Task.yield()
            spins += 1
        }
    }

    /// Avança o tempo virtual e acorda, em ordem, as esperas vencidas.
    public func advance(by seconds: TimeInterval) async {
        now += seconds
        let due = waiters.filter { $0.due <= now }.sorted { $0.due < $1.due }
        waiters.removeAll { $0.due <= now }
        for waiter in due { waiter.continuation.resume() }
        for _ in 0..<20 { await Task.yield() }
    }
}
