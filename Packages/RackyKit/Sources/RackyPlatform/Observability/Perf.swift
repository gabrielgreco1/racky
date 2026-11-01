import Foundation
import os
import Synchronization

/// Uma medida local da tabela `metric` (08 AR-605).
public struct MetricSample: Sendable, Equatable {
    public var name: String
    public var value: Double
    public var unit: String
    public var tags: [String: String]
    public var at: Date

    public init(name: String, value: Double, unit: String = "ms", tags: [String: String] = [:], at: Date = Date()) {
        self.name = name
        self.value = value
        self.unit = unit
        self.tags = tags
        self.at = at
    }
}

/// Facilidade `metric`: um destino por processo (o app grava no Store; o daemon, no log em disco).
public final class MetricRecorder: Sendable {
    public typealias Sink = @Sendable (MetricSample) -> Void
    public static let shared = MetricRecorder()
    private struct State {
        var sink: Sink?
        /// Amostras de antes do destino existir (o boot acontece antes de o Store abrir); limitado.
        var pending: [MetricSample] = []
    }
    private let state = Mutex(State())

    public init() {}

    public func install(_ newSink: Sink?) {
        let backlog = state.withLock { state -> [MetricSample] in
            state.sink = newSink
            guard newSink != nil else { return [] }
            defer { state.pending.removeAll() }
            return state.pending
        }
        if let newSink { for sample in backlog { newSink(sample) } }
    }

    public func record(_ sample: MetricSample) {
        let sink = state.withLock { state -> Sink? in
            if state.sink == nil {
                state.pending.append(sample)
                if state.pending.count > 200 { state.pending.removeFirst(state.pending.count - 200) }
            }
            return state.sink
        }
        sink?(sample)
    }

    /// Atalho: registra uma duração em milissegundos.
    public func record(_ name: String, milliseconds: Double, tags: [String: String] = [:]) {
        record(MetricSample(name: name, value: milliseconds, tags: tags))
    }
}

/// Pontos quentes com signpost e métrica (08 AR-605). Nomes estáveis: viram `metric.name` e o nome do intervalo no Instruments.
public enum PerfPoint: String, CaseIterable, Sendable {
    case boot = "boot.first_window"
    case launch = "launch.agent"
    case attach = "attach.replay"
    case firstByte = "terminal.first_byte"
    case resize = "terminal.resize"
    case computerProvision = "computer.provision"
    case vncConnect = "vnc.connect"

    fileprivate var signpostName: StaticString {
        switch self {
        case .boot: "boot.first_window"
        case .launch: "launch.agent"
        case .attach: "attach.replay"
        case .firstByte: "terminal.first_byte"
        case .resize: "terminal.resize"
        case .computerProvision: "computer.provision"
        case .vncConnect: "vnc.connect"
        }
    }
}

/// Intervalo em andamento. `end()` fecha o signpost e grava a duração; chamar duas vezes grava uma só.
public final class PerfInterval: Sendable {
    private let point: PerfPoint
    private let state: OSSignpostIntervalState
    private let start: ContinuousClock.Instant
    private let tags: [String: String]
    private let recorder: MetricRecorder
    private let ended = Mutex(false)

    fileprivate init(point: PerfPoint, state: OSSignpostIntervalState, tags: [String: String], recorder: MetricRecorder) {
        self.point = point
        self.state = state
        self.start = .now
        self.tags = tags
        self.recorder = recorder
    }

    /// Devolve a duração em milissegundos.
    @discardableResult
    public func end(tags extra: [String: String] = [:]) -> Double {
        let milliseconds = Perf.milliseconds(from: start)
        guard ended.withLock({ let was = $0; $0 = true; return !was }) else { return milliseconds }
        Perf.signposter.endInterval(point.signpostName, state)
        recorder.record(MetricSample(name: point.rawValue, value: milliseconds, tags: tags.merging(extra) { _, new in new }))
        return milliseconds
    }
}

public enum Perf {
    static let signposter = OSSignposter(subsystem: LogFacade.Subsystem.app.rawValue, category: "perf")

    public static func begin(_ point: PerfPoint, tags: [String: String] = [:], recorder: MetricRecorder = .shared) -> PerfInterval {
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval(point.signpostName, id: id)
        return PerfInterval(point: point, state: state, tags: tags, recorder: recorder)
    }

    public static func measure<T>(_ point: PerfPoint, tags: [String: String] = [:], recorder: MetricRecorder = .shared, _ body: () async throws -> T) async rethrows -> T {
        let interval = begin(point, tags: tags, recorder: recorder)
        defer { interval.end() }
        return try await body()
    }

    static func milliseconds(from start: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - start
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }
}
