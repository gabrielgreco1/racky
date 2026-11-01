import Foundation
import RackyCore
import RackyDocker
import RackyProtocol

/// `ComputerProvisioning` do runtime sem Docker: um computador = uma VM (apple/containerization) com a MESMA imagem lógica, o mesmo
/// supervisor, o mesmo `egress` e o mesmo `abx-provision` do caminho Docker. Muda o transporte: exec por vsock, `/work` e logs por
/// virtiofs, e a admin API chega ao Mac por uma ponte TCP-loopback -> vsock (`VZPortBridge`).
public struct VZComputerProvisioning: ComputerProvisioning {
    /// Porta vsock do encaminhador dentro da VM (`racky_supervisor.vsock`), que repassa para a admin API em 127.0.0.1.
    public static let vsockPort: UInt32 = 8791

    public typealias Context = @Sendable () async throws -> (backend: any VZBackend, image: VZBootImage)

    public let context: Context
    public let registry: VZRegistry
    public let secrets: BoxSecretFiles
    public let owner: String
    public var allowCIDRs: [String]
    public var isTest: Bool
    public var resolver: ProxyConfigResolver?
    public var runtimeReadyTimeout: Duration

    public init(
        registry: VZRegistry, secrets: BoxSecretFiles, owner: String, allowCIDRs: [String] = [], isTest: Bool = false,
        resolver: ProxyConfigResolver? = nil, runtimeReadyTimeout: Duration = .seconds(90), context: @escaping Context
    ) {
        self.registry = registry; self.secrets = secrets; self.owner = owner; self.allowCIDRs = allowCIDRs; self.isTest = isTest
        self.resolver = resolver; self.runtimeReadyTimeout = runtimeReadyTimeout; self.context = context
    }

    /// A VM é um filho do app: não existe o que readotar depois de um reinício (a lista é sempre vazia, o scheduler baixa as linhas).
    public func liveComputers() async -> [LiveComputer]? { [] }

    /// Especificação da VM de um computador: a MESMA `ContainerSpec` do Docker (hardening, tmpfs, binds, capacidades) mais as duas
    /// variáveis que só existem na VM: admin API só no loopback e o encaminhador vsock.
    public static func containerSpec(_ request: ComputerProvisionRequest, work: URL, logs: URL, taskSecrets: URL) -> ContainerSpec {
        var spec = ComputerProvisioner.containerSpec(request, work: work, logs: logs, taskSecrets: taskSecrets, volume: nil)
        spec.environment += ["RACKY_ADMIN_BIND=127.0.0.1", "RACKY_VSOCK_PORT=\(vsockPort)"]
        return spec
    }

    public func provision(_ spec: ComputerSpec) async throws -> ProvisionedHandle {
        let (backend, image) = try await context()
        let computerID = spec.computerID.uuidString.lowercased()
        let labels = ComputerLabels(owner: owner, computerID: computerID, computerName: spec.name, batch: spec.batch, ephemeral: true, isTest: isTest)
        let token = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        let subnet = await backend.internalSubnet
        var config = EgressConfigFile.make(profile: nil, secret: nil, allowCIDRs: allowCIDRs, allowHosts: spec.allowHosts, internalSubnet: subnet)
        var proxyCA: String?
        if spec.proxy != "direct", let resolver {
            let resolved = try await resolver(spec.proxy, nil)
            var merged = resolved.config
            merged.allowCIDRs = config.allowCIDRs
            merged.allowHosts = config.allowHosts
            merged.internalSubnet = subnet
            config = merged
            proxyCA = resolved.caPEM
        }
        config.github = spec.github
        let request = ComputerProvisionRequest(
            labels: labels, image: "racky-computer", display: spec.display, token: token, config: config, proxyCA: proxyCA, secrets: secrets,
            runDirectory: spec.run.root)
        let fm = FileManager.default
        let work = spec.run.work, logs = spec.run.logs
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)

        let vmID = "\(labels.containerName)-\(String(UUID().uuidString.prefix(4)).lowercased())"
        let taskSecrets = try secrets.ensureRoleDirectory(computerID, role: .work)
        let containerSpec = Self.containerSpec(request, work: work, logs: logs, taskSecrets: taskSecrets)
        let plan = try VZVMPlan(spec: containerSpec, vmID: vmID)

        let registry = registry
        let secrets = secrets
        try await registry.add(VZRegistryEntry(vmID: vmID, computerID: computerID, name: spec.name, owner: owner, hostPID: getpid()))
        var vm: (any RunningVM)?
        var bridge: VZPortBridge?
        let cleanup: @Sendable ((any RunningVM)?, VZPortBridge?) async -> Void = { vm, bridge in
            bridge?.stop()
            await vm?.stop()
            try? await registry.remove(vmID: vmID)
            try? secrets.removeAll(computerID: computerID)
        }
        do {
            let started = try await backend.boot(plan, image: image)
            vm = started
            let dial = try VZPortBridge(dial: { try await started.dialVsock(port: Self.vsockPort) })
            bridge = dial
            let port = try await dial.start()
            try await VZProvisionPayload.deliver(config: config, proxyCA: proxyCA, token: token, to: started)
            let admin = EgressAdminClient(port: port, token: token)
            try await admin.waitUntilHealthy()
            if spec.display != .http { try await Self.waitRuntimeReady(admin, timeout: runtimeReadyTimeout) }
            let provisioned = ProvisionedComputer(
                labels: labels, display: spec.display, containerID: vmID, containerName: containerSpec.name, adminPort: port, profileVolume: nil,
                workDirectory: work, logsDirectory: logs, admin: admin, host: .local)
            let backendForTools = DockerComputerBackend(
                transport: VZExecTransport(vm: started), computer: provisioned, secrets: secrets, baseConfig: config, resolver: resolver)
            let stopBridge = dial
            return ProvisionedHandle(backend: backendForTools) {
                stopBridge.stop()
                await started.stop()
                try? await registry.remove(vmID: vmID)
                try? secrets.removeAll(computerID: computerID)
            }
        } catch {
            await cleanup(vm, bridge)
            throw error
        }
    }

    /// Espera o Chromium headed do runtime ficar pronto.
    static func waitRuntimeReady(_ admin: EgressAdminClient, timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await admin.runtimeReady() { return }
            try await Task.sleep(for: .milliseconds(300))
        }
        throw ComputerProvisionerError.runtimeNotReady("o browser do runtime não ficou pronto em \(timeout)")
    }
}
