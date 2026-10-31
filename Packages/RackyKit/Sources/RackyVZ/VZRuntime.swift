import Foundation
import RackyCore
import RackyDocker
import Security

/// O runtime de computadores sem Docker, como o app o vê (`NativeComputerRuntime`): prepara os arquivos (download verificado, uma vez),
/// faz o sweep das VMs/pastas que sobraram de uma execução anterior e entrega o provisionador de VMs.
///
/// Dono das VMs: este processo (o app). O Virtualization.framework não deixa a VM sobreviver ao processo que a criou, então
/// não há readoção: os computadores param quando o app fecha e o scheduler os dá como removidos no próximo início
/// (`liveComputers() == []`). Hospedar no `rackyd` (que sobrevive ao app) está descrito em docs/rebuild/vz-runtime.md.
public actor VZRuntime: NativeComputerRuntime {
    public struct Config: Sendable {
        public var appDataRoot: URL
        public var secretsRoot: URL
        public var owner: String
        /// Raiz de `runtime/` (onde mora `vz-manifest.json`); `nil` = só `RACKY_VZ_MANIFEST`.
        public var runtimeRoot: URL?
        public var environment: [String: String]
        public var allowCIDRs: [String] = []
        public var isTest = false
        public var resolver: ProxyConfigResolver?
        /// Fração da memória física que a admissão pode usar (o resto é do Mac): ver `vmCapacity`.
        public var memoryShare = 0.6

        public init(appDataRoot: URL, secretsRoot: URL, owner: String, runtimeRoot: URL?, environment: [String: String] = ProcessInfo.processInfo.environment) {
            self.appDataRoot = appDataRoot; self.secretsRoot = secretsRoot; self.owner = owner; self.runtimeRoot = runtimeRoot; self.environment = environment
        }
    }

    /// Cria o backend de VMs depois que os arquivos estão prontos (os testes injetam um falso).
    public typealias BackendFactory = @Sendable (VZPaths, VZReadyAssets) async throws -> any VZBackend

    public static let entitlement = "com.apple.security.virtualization"

    private let config: Config
    public nonisolated let paths: VZPaths
    public nonisolated let registry: VZRegistry
    private let store: VZAssetStore
    private let entitled: Bool
    private let makeBackend: BackendFactory
    private var backend: (any VZBackend)?
    private var image: VZBootImage?
    private var preparing: Task<Void, any Error>?
    private var swept = false

    public init(config: Config, entitled: Bool = VZRuntime.processHasVirtualizationEntitlement(), backendFactory: BackendFactory? = nil) {
        self.config = config
        paths = VZPaths(appDataRoot: config.appDataRoot)
        registry = VZRegistry(url: paths.registryFile)
        store = VZAssetStore(paths: paths)
        self.entitled = entitled
        makeBackend = backendFactory ?? { paths, assets in
            guard #available(macOS 26, *) else { throw VZError.unavailable("macOS 26 or later is required") }
            return try ContainerizationBackend(paths: paths, assets: assets)
        }
    }

    // MARK: Disponibilidade

    public nonisolated var unavailableReason: String? {
        if let reason = RuntimeSelector.nativeUnavailableReason() { return reason }
        if !entitled { return "This build of Racky isn't signed to run virtual machines (missing \(Self.entitlement))." }
        return nil
    }

    /// O binário em execução tem o entitlement de virtualização? Sem ele o framework recusa criar VMs.
    public static func processHasVirtualizationEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil)
        return (value as? Bool) == true
    }

    // MARK: NativeComputerRuntime

    public func vmCapacity() async -> VMCapacity {
        VMCapacity(memTotalBytes: Int64(Double(ProcessInfo.processInfo.physicalMemory) * config.memoryShare), cpuCount: ProcessInfo.processInfo.activeProcessorCount)
    }

    /// Sweep de início: apaga pastas de VMs de execuções anteriores (as VMs já morreram com o processo). Seguro antes de qualquer boot.
    @discardableResult
    public func startupSweep() async -> VZSweepReport {
        swept = true
        let backend = backend
        return await registry.sweep(containersDirectory: paths.containers, stopOwn: { _ in await backend?.stopAll() })
    }

    public func manifest() async throws -> VZManifest {
        guard let location = VZManifest.location(environment: config.environment, runtimeRoot: config.runtimeRoot) else {
            throw VZManifestError.unreadable("no vz-manifest.json (set \(VZManifest.environmentKey) to a local manifest)")
        }
        return try await VZManifest.load(from: location)
    }

    public func ensureReady(progress: @escaping @Sendable (ComputerSetupState) -> Void) async throws {
        if backend != nil, image != nil { return }
        if let reason = unavailableReason { throw VZError.unavailable(reason) }
        if let preparing { return try await preparing.value }
        let task = Task { try await self.prepare(progress: progress) }
        preparing = task
        defer { preparing = nil }
        try await task.value
    }

    private func prepare(progress: @escaping @Sendable (ComputerSetupState) -> Void) async throws {
        if !swept { await startupSweep() }
        let manifest = try await manifest()
        let assets = try await store.ensureReady(manifest: manifest) { event in
            switch event {
            case .downloading(let done, let total): progress(.downloading(done: done, total: total))
            case .preparing: progress(.preparing)
            }
        }
        backend = try await makeBackend(paths, assets)
        image = assets.bootImage
    }

    public func provision(_ spec: ComputerSpec) async throws -> ProvisionedHandle {
        let provisioning = VZComputerProvisioning(
            registry: registry, secrets: BoxSecretFiles(root: config.secretsRoot), owner: config.owner, allowCIDRs: config.allowCIDRs,
            isTest: config.isTest, resolver: config.resolver) { [self] in try await readyContext() }
        return try await provisioning.provision(spec)
    }

    /// O backend e a imagem prontos (prepara se preciso). Para o autoteste e para quem sobe uma VM sem o provisionador.
    public func readyContext() async throws -> (backend: any VZBackend, image: VZBootImage) {
        if backend == nil || image == nil { try await ensureReady { _ in } }
        guard let backend, let image else { throw VZError.notReady("the computer runtime isn't ready") }
        return (backend, image)
    }

    public func shutdown() async {
        await backend?.stopAll()
    }
}
