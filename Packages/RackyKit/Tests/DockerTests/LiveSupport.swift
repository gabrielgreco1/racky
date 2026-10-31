import RackyPlatform
import Foundation
import Testing

@testable import RackyDocker

/// Integração com o Docker real: só roda com `RACKY_TEST_DOCKER=1`.
/// Regra de segurança: todo recurso criado leva `racky.test=1` e `racky.test_run=<id desta execução>`; a limpeza só
/// remove recursos com os DOIS labels, então nunca toca em containers, volumes, redes ou imagens que não sejam destes testes.
enum Live {
    static let enabled = ProcessInfo.processInfo.environment["RACKY_TEST_DOCKER"] == "1"
    static let evidenceRoot: URL? = ProcessInfo.processInfo.environment["RACKY_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0) }

    /// Base mínima fixada por digest (alpine 3.20, índice multi-arquitetura).
    static let alpineDigest = "sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc"
    static let alpine = "alpine@\(alpineDigest)"

    static func detect() async throws -> DetectedRuntime {
        try await RuntimeDetector().detect()
    }

    /// Roda `body` com um ambiente isolado e SEMPRE limpa os recursos criados, inclusive quando `body` lança.
    static func with(_ body: @Sendable (LiveEnv) async throws -> Void) async throws {
        let detected = try await detect()
        let env = LiveEnv(client: DockerClient(runtime: detected.runtime, defaultTimeout: .seconds(60)), runtime: detected,
                          runID: String(UUID().uuidString.lowercased().prefix(8)))
        _ = try await env.ensureBase()
        do {
            try await body(env)
        } catch {
            await env.cleanup()
            throw error
        }
        await env.cleanup()
        let leftovers = (try? await env.inventory()) ?? []
        #expect(leftovers.isEmpty, "a limpeza deixou recursos: \(leftovers.map(\.name))")
    }
}

struct LiveEnv: Sendable {
    let client: DockerClient
    let runtime: DetectedRuntime
    let runID: String

    var labelFilter: [String] { ["\(RackyLabel.test)=1", "racky.test_run=\(runID)"] }
    var baseLabels: [String: String] {
        [RackyLabel.test: "1", "racky.test_run": runID, RackyLabel.owner: "test-\(runID)", RackyLabel.computer: "c-\(runID)",
         RackyLabel.ephemeral: "true"]
    }

    func name(_ suffix: String) -> String { "abx-t-\(runID)-\(suffix)" }

    func ensureBase() async throws -> ImageInspect {
        if let image = try await client.imageIfPresent(Live.alpine) { return image }
        let layers = LayerCounter()
        let status = try await client.pullImageToCompletion(Live.alpine) { progress in
            if let id = progress.id, progress.status == "Pull complete" { layers.add(id) }
        }
        await Evidence.shared.record("slice3/T3-01/live-images.json", "pull_by_digest_from_registry", "\(Live.alpine): \(status ?? "?"); camadas baixadas: \(layers.count)")
        return try await client.inspectImage(Live.alpine)
    }

    func spec(_ suffix: String, command: [String] = ["sleep", "600"], role: ComputerRole = .work) -> ContainerSpec {
        var spec = ContainerSpec(name: name(suffix), image: Live.alpine, command: command)
        spec.labels = baseLabels.merging([RackyLabel.role: role.rawValue]) { $1 }
        spec.resources = ContainerResources(memoryBytes: 96 << 20, cpus: 0.5, pidsLimit: 128)
        spec.tmpfs = ["/tmp": "rw,exec,nosuid,size=16m"]
        spec.hostname = suffix
        return spec
    }

    /// Cria e inicia.
    func run(_ spec: ContainerSpec) async throws -> String {
        let id = try await client.createContainer(spec)
        try await client.startContainer(id)
        return id
    }

    func inventory() async throws -> [ManagedResource] {
        try await GarbageCollector(client: client).inventory(labels: labelFilter)
    }

    func cleanup() async {
        let gc = GarbageCollector(client: client)
        if let items = try? await gc.inventory(labels: labelFilter) { await gc.remove(items) }
        if let images = try? await client.listImages(filters: ["label": labelFilter]) {
            for image in images { try? await client.removeImage(image.id, force: true) }
        }
    }
}

/// Evidência dos spikes e da tarefa: JSON legível em `RACKY_EVIDENCE_DIR/<caminho>`.
actor Evidence {
    static let shared = Evidence()
    private var tables: [String: [String: String]] = [:]

    func record(_ file: String, _ key: String, _ value: String) {
        guard let root = Live.evidenceRoot else { return }
        let url = root.appendingPathComponent(file)
        if tables[file] == nil {  // acumula com execuções anteriores (o teste lento do build real roda à parte)
            let old = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
            tables[file] = old ?? [:]
        }
        tables[file, default: [:]][key] = value
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try? JSONSerialization.data(withJSONObject: tables[file] ?? [:], options: [.prettyPrinted, .sortedKeys])
        try? data?.write(to: url)
    }
}

final class LayerCounter: @unchecked Sendable {  // SAFETY: acesso serializado por NSLock; só testes.
    private let lock = NSLock()  // LOCK: sem I/O sob o lock; só testes.
    private var ids = Set<String>()
    func add(_ id: String) {
        lock.lock()
        ids.insert(id)
        lock.unlock()
    }
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return ids.count
    }
}
