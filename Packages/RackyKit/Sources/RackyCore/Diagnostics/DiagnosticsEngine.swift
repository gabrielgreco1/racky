import RackyDocker
import Foundation
import Synchronization

/// Sondas da checklist, todas injetáveis (os testes usam falsas; nunca rodam `docker`, `gh` nem CLIs de verdade).
/// Cada sonda tem que ser barata e respeitar cancelamento; o timeout do motor é a rede de proteção.
public struct DiagnosticsProbes: Sendable {
    public var gh: @Sendable () async -> GitHubProbeResult
    public var docker: @Sendable () async -> DockerProbeResult
    /// Só roda com o Docker de pé; recebe o runtime detectado. `nil` = não conseguiu verificar.
    public var image: @Sendable (DockerRuntime) async -> ImageProbeResult?
    public var conflicts: @Sendable () async -> ConflictScan
    /// Qual runtime serve os computadores. Com `.native` as sondas do Docker nem rodam. Padrão: Docker (comportamento anterior).
    public var runtime: @Sendable () async -> ComputerRuntimeMode

    public init(
        gh: @escaping @Sendable () async -> GitHubProbeResult,
        docker: @escaping @Sendable () async -> DockerProbeResult,
        image: @escaping @Sendable (DockerRuntime) async -> ImageProbeResult?,
        conflicts: @escaping @Sendable () async -> ConflictScan,
        runtime: @escaping @Sendable () async -> ComputerRuntimeMode = { .dockerForced }
    ) {
        self.gh = gh
        self.docker = docker
        self.image = image
        self.conflicts = conflicts
        self.runtime = runtime
    }
}

/// Roda a checklist de diagnóstico (R1.1): tudo em paralelo, cada item com timeout próprio (10 s, AC-102), resultado em
/// cache por um tempo curto (`force` ignora), e um item travado nunca atrasa os outros. Resultado com timeout não entra no cache.
public actor DiagnosticsEngine {
    public struct Configuration: Sendable {
        public var timeout: Duration
        public var cacheTTL: Duration
        public init(timeout: Duration = .seconds(10), cacheTTL: Duration = .seconds(60)) {
            self.timeout = timeout
            self.cacheTTL = cacheTTL
        }
    }

    /// `item == nil` significa "nada a mostrar" (conflitos ausentes).
    public typealias Update = @Sendable (_ key: DiagnosticKey, _ item: DiagnosticItem?) -> Void

    private struct Cached { var items: [DiagnosticKey: DiagnosticItem?]; var at: ContinuousClock.Instant }
    private enum Group: Hashable { case gh, docker, conflicts }

    private let probes: DiagnosticsProbes
    private let configuration: Configuration
    private let clock = ContinuousClock()
    private var cache: [Group: Cached] = [:]
    private var inflight: [Group: Task<Void, Never>] = [:]
    /// Quantas vezes cada sonda de fato rodou (testes de cache).
    public private(set) var probeRuns: [DiagnosticKey: Int] = [:]

    public init(probes: DiagnosticsProbes, configuration: Configuration = Configuration()) {
        self.probes = probes
        self.configuration = configuration
    }

    private static func group(of key: DiagnosticKey) -> Group {
        switch key {
        case .gh: .gh
        case .runtime, .docker, .image: .docker
        case .conflicts: .conflicts
        }
    }

    /// Roda as sondas dos itens pedidos (padrão: todos) e avisa cada resultado assim que chega.
    public func run(_ keys: Set<DiagnosticKey> = Set(DiagnosticKey.allCases), force: Bool, onUpdate: @escaping Update) async {
        let groups = Set(keys.map(Self.group(of:)))
        var tasks: [Task<Void, Never>] = []
        for group in groups {
            if !force, let cached = cache[group], clock.now - cached.at < configuration.cacheTTL {
                for (key, item) in cached.items where keys.contains(key) || group == .docker { onUpdate(key, item) }
                continue
            }
            if let running = inflight[group] {
                tasks.append(running)
                continue
            }
            for key in Self.keys(of: group) { onUpdate(key, .checking(key)) }
            let task = Task { [self] in
                let items = await probe(group)
                finish(group, items: items)
                for (key, item) in items { onUpdate(key, item) }
            }
            inflight[group] = task
            tasks.append(task)
        }
        for task in tasks { await task.value }
    }

    private static func keys(of group: Group) -> [DiagnosticKey] {
        switch group {
        case .gh: [.gh]
        case .docker: [.runtime, .docker, .image]
        case .conflicts: [.conflicts]
        }
    }

    private func finish(_ group: Group, items: [DiagnosticKey: DiagnosticItem?]) {
        inflight[group] = nil
        let timedOut = items.values.contains { $0?.state == .problem && $0?.fix == .retry }
        if timedOut { cache[group] = nil } else { cache[group] = Cached(items: items, at: clock.now) }
    }

    private func count(_ key: DiagnosticKey) { probeRuns[key, default: 0] += 1 }

    private func probe(_ group: Group) async -> [DiagnosticKey: DiagnosticItem?] {
        switch group {
        case .gh:
            count(.gh)
            let result = await Self.withTimeout(configuration.timeout, probes.gh)
            return [.gh: result.map(DiagnosticsEvaluator.gh) ?? DiagnosticsEvaluator.timedOut(.gh)]
        case .conflicts:
            count(.conflicts)
            guard let scan = await Self.withTimeout(configuration.timeout, probes.conflicts) else {
                return [.conflicts: DiagnosticsEvaluator.timedOut(.conflicts)]
            }
            return [.conflicts: DiagnosticsEvaluator.conflicts(scan)]
        case .docker:
            let mode = await Self.withTimeout(configuration.timeout, probes.runtime) ?? .dockerForced
            if case .native = mode {
                // Runtime nativo: nem o socket do Docker é tocado, e a checklist não menciona Docker nem imagem.
                count(.runtime)
                return [.runtime: DiagnosticsEvaluator.runtime(mode), .docker: nil, .image: nil]
            }
            count(.docker)
            guard let docker = await Self.withTimeout(configuration.timeout, probes.docker) else {
                return [.runtime: nil, .docker: DiagnosticsEvaluator.timedOut(.docker),
                        .image: DiagnosticItem(key: .image, state: .neutral, detail: "Waiting for Docker.")]
            }
            var image: ImageProbeResult?
            if case .running(let running) = docker {
                count(.image)
                let probe = probes.image
                let runtime = running.runtime
                let timeout = configuration.timeout
                guard let outcome = await Self.withTimeout(timeout, { await probe(runtime) }) else {
                    return [.runtime: nil, .docker: DiagnosticsEvaluator.docker(docker, mode: mode), .image: DiagnosticsEvaluator.timedOut(.image)]
                }
                image = outcome
            }
            return [.runtime: nil, .docker: DiagnosticsEvaluator.docker(docker, mode: mode), .image: DiagnosticsEvaluator.image(image, docker: docker)]
        }
    }

    /// Corre a operação contra um relógio. Quem perder não é esperado: uma sonda que ignora o cancelamento só vaza a tarefa.
    static func withTimeout<T: Sendable>(_ timeout: Duration, _ operation: @escaping @Sendable () async -> T) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = Once(continuation)
            let worker = Task { once.resume(await operation()) }
            Task {
                try? await Task.sleep(for: timeout)
                once.resume(nil)
                worker.cancel()
            }
        }
    }

    /// Entrega o primeiro valor e ignora os seguintes.
    private final class Once<T: Sendable>: Sendable {
        private let state: Mutex<CheckedContinuation<T?, Never>?>
        init(_ continuation: CheckedContinuation<T?, Never>) { state = Mutex(continuation) }
        func resume(_ value: T?) { state.withLock { c in let taken = c; c = nil; return taken }?.resume(returning: value) }
    }
}
