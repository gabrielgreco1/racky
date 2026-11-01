import RackyPlatform
import RackyStore
import Foundation

/// Leva as amostras de `MetricRecorder` para a tabela `metric` em lotes (um flush a cada poucos segundos), sem tocar o main thread.
/// Mantém 7 dias (AR-605). Sem Store aberto as amostras ficam só no buffer (limitado) e nos signposts.
public actor MetricWriter {
    public static let retention: TimeInterval = 7 * 24 * 3600

    private let store: RackyStore
    private let interval: Duration
    private let limit: Int
    private var buffer: [MetricSample] = []
    private var flusher: Task<Void, Never>?

    public init(store: RackyStore, interval: Duration = .seconds(5), limit: Int = 2000) {
        self.store = store
        self.interval = interval
        self.limit = limit
    }

    /// Liga o recorder compartilhado a este escritor e agenda o flush periódico.
    public func start(recorder: MetricRecorder = .shared) {
        recorder.install { [weak self] sample in
            guard let self else { return }
            Task { await self.add(sample) }
        }
        guard flusher == nil else { return }
        flusher = Task { [weak self, interval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await self?.flush()
            }
        }
        Task { [store] in _ = try? await store.pruneMetrics(olderThan: Date().addingTimeInterval(-Self.retention)) }
    }

    public func stop(recorder: MetricRecorder = .shared) async {
        recorder.install(nil)
        flusher?.cancel()
        flusher = nil
        await flush()
    }

    func add(_ sample: MetricSample) {
        buffer.append(sample)
        if buffer.count > limit { buffer.removeFirst(buffer.count - limit) }
    }

    public func flush() async {
        guard !buffer.isEmpty else { return }
        let batch = buffer
        buffer.removeAll(keepingCapacity: true)
        do { try await store.recordMetrics(batch) } catch {
            buffer.insert(contentsOf: batch.prefix(limit / 2), at: 0)  // volta uma parte; nunca cresce sem limite
        }
    }
}
