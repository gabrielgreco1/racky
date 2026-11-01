import Foundation
import Synchronization

/// Decide quando o tamanho do PTY muda (06 §1.8, 08 AR-710, 04 M-202): o emulador da UI acompanha o layout a cada
/// quadro, mas o `TIOCSWINSZ` só sai (a) uma vez por rajada, `debounce` depois da última mudança, (b) nunca igual ao
/// último tamanho aplicado e (c) nunca durante uma transição de layout (`beginTransition`/`endTransition`): a
/// transição produz exatamente um resize, quando termina.
public final class PTYResizeCoordinator: Sendable {
    public struct Size: Sendable, Equatable {
        public var cols: UInt16
        public var rows: UInt16
        public init(cols: UInt16, rows: UInt16) {
            self.cols = cols
            self.rows = rows
        }
    }

    private struct State {
        var applied: Size
        var pending: Size?
        var inTransition = false
        var generation = 0
        var closed = false
    }

    public static let defaultDebounce: Duration = .milliseconds(50)

    private let state: Mutex<State>
    private let debounce: Duration
    private let apply: @Sendable (Size) async -> Void

    /// - Parameters:
    ///   - initial: tamanho já aplicado (o do `attach`).
    ///   - apply: escreve o tamanho no daemon (`PTYClient.resize`).
    public init(initial: Size, debounce: Duration = PTYResizeCoordinator.defaultDebounce, apply: @escaping @Sendable (Size) async -> Void) {
        state = Mutex(State(applied: initial))
        self.debounce = debounce
        self.apply = apply
    }

    /// O layout passou a medir `size` (chamado a cada mudança, no máximo uma por quadro).
    public func request(_ size: Size) {
        let generation: Int? = state.withLock { s in
            guard !s.closed else { return nil }
            s.pending = size == s.applied ? nil : size
            guard s.pending != nil, !s.inTransition else { return nil }
            s.generation += 1
            return s.generation
        }
        if let generation { startTimer(generation: generation) }
    }

    /// Começa uma transição de layout (animação de painel, arrasto de divisor): nada é aplicado até `endTransition`.
    public func beginTransition() {
        state.withLock { s in
            s.inTransition = true
            s.generation += 1
        }
    }

    /// Termina a transição e aplica o último tamanho pedido (se diferir do aplicado), uma única vez.
    public func endTransition() {
        let toApply: Size? = state.withLock { s in
            s.inTransition = false
            s.generation += 1
            guard !s.closed, let pending = s.pending, pending != s.applied else { return nil }
            s.applied = pending
            s.pending = nil
            return pending
        }
        if let toApply { Task { await apply(toApply) } }
    }

    /// Para de aplicar (pane fechado).
    public func close() {
        state.withLock { s in
            s.closed = true
            s.generation += 1
        }
    }

    public var appliedSize: Size { state.withLock { $0.applied } }

    private func startTimer(generation: Int) {
        let delay = debounce
        Task { [self] in
            try? await Task.sleep(for: delay)
            let toApply: Size? = state.withLock { s in
                guard s.generation == generation, !s.closed, !s.inTransition, let pending = s.pending, pending != s.applied else { return nil }
                s.applied = pending
                s.pending = nil
                return pending
            }
            if let toApply { await apply(toApply) }
        }
    }
}
