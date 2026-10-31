import Dispatch

/// Ponte mínima para executar trabalho bloqueante (espera de processo, poll, leitura de pipe) fora do pool
/// cooperativo (08 AR-404). Usa uma fila GCD utilitária; nunca bloqueia uma thread do pool de Swift concurrency.
public enum BlockingIOBridge {
    private static let queue = DispatchQueue(label: "app.racky.platform.blocking-io", qos: .utility, attributes: .concurrent)

    public static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}
