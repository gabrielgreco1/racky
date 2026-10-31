import RackyDocker
import RackyProtocol
import Foundation

/// Fábrica real de computadores para o `ComputerScheduler`: um container por computador (P24, `ComputerProvisioner`) e o
/// `DockerComputerBackend` que as ferramentas MCP usam. Só toca recursos com os labels do computador.
public struct DockerComputerProvisioning: ComputerProvisioning {
    public let client: DockerClient
    /// Onde os computadores rodam: Docker local (padrão) ou VM remota por túnel (BK-12). `client` é sempre `host.client`.
    public let host: any ComputerHostAccess
    /// Tag de `racky-computer`.
    public let image: String
    public let secrets: BoxSecretFiles
    public let owner: String
    public var network: String
    /// Exceção explícita ao filtro SSRF (rede de teste); vazio em produção.
    public var allowCIDRs: [String]
    public var extraLabels: [String: String]
    public var isTest: Bool
    public var resolver: ProxyConfigResolver?

    public init(
        client: DockerClient, image: String, secrets: BoxSecretFiles, owner: String,
        network: String = ComputerProvisioner.defaultNetwork, allowCIDRs: [String] = [], extraLabels: [String: String] = [:],
        isTest: Bool = false, resolver: ProxyConfigResolver? = nil, host: (any ComputerHostAccess)? = nil
    ) {
        let host = host ?? LocalHostAccess(client: client)
        self.host = host
        self.client = host.client; self.image = image; self.secrets = secrets; self.owner = owner
        self.network = network; self.allowCIDRs = allowCIDRs; self.extraLabels = extraLabels; self.isTest = isTest; self.resolver = resolver
    }

    public func preflight() async throws { try await client.ping() }

    /// `M` da VM e CPUs, lidos de `/info` (a admissão usa isto).
    public func vmCapacity() async -> VMCapacity {
        if let info = try? await client.info() { return VMCapacity(memTotalBytes: info.memTotal, cpuCount: info.cpuCount) }
        return VMCapacity(memTotalBytes: 8 << 30, cpuCount: 4)
    }

    public func provision(_ spec: ComputerSpec) async throws -> ProvisionedHandle {
        let computerID = spec.computerID.uuidString.lowercased()
        let labels = ComputerLabels(owner: owner, computerID: computerID, computerName: spec.name, batch: spec.batch, ephemeral: true, isTest: isTest)
        let token = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        var config = EgressConfigFile.make(profile: nil, secret: nil, allowCIDRs: allowCIDRs, allowHosts: spec.allowHosts)
        var proxyCA: String?
        if spec.proxy != "direct", let resolver {
            let resolved = try await resolver(spec.proxy, nil)
            var merged = resolved.config
            merged.allowCIDRs = config.allowCIDRs
            merged.allowHosts = config.allowHosts
            config = merged
            proxyCA = resolved.caPEM
        }
        config.github = spec.github
        let provisioner = ComputerProvisioner(host: host)
        let provisioned = try await provisioner.provision(ComputerProvisionRequest(
            labels: labels, image: image, display: spec.display, token: token, config: config, proxyCA: proxyCA,
            secrets: secrets, runDirectory: spec.run.root, network: network, extraLabels: extraLabels))
        let backend = DockerComputerBackend(client: client, computer: provisioned, secrets: secrets, baseConfig: config, resolver: resolver)
        let secrets = secrets
        return ProvisionedHandle(backend: backend) { _ = try? await provisioner.teardown(provisioned, secrets: secrets) }
    }

    // MARK: Adoção

    /// Containers de computador (P24) do owner, vivos ou parados. Só lê; `nil` sem Docker.
    public func liveComputers() async -> [LiveComputer]? {
        guard (try? await client.ping()) != nil else { return nil }
        let current = ["\(RackyLabel.owner)=\(owner)", RackyLabel.computer]
        guard let list = try? await client.listContainers(all: true, filters: ["label": current]) else { return nil }
        var seen = Set<String>()
        return list.compactMap { item in
            guard seen.insert(item.id).inserted, RackyLabel.isOwned(by: owner, labels: item.labels),
                  let id = RackyLabel.value(RackyLabel.computer, in: item.labels), let name = RackyLabel.value(RackyLabel.computerName, in: item.labels),
                  RackyLabel.value(RackyLabel.role, in: item.labels).map({ $0 == ComputerRole.computer.rawValue }) ?? true else { return nil }
            return LiveComputer(
                computerID: id, name: name, containerID: item.id, running: item.state == "running", created: item.created,
                batch: RackyLabel.value(RackyLabel.batch, in: item.labels))
        }
    }

    /// Refaz o `ProvisionedComputer` de um container vivo: a porta publicada vem do inspect, o token e a política do egress são relidos
    /// de `/run/racky` por `docker exec -u egress` (o mesmo usuário que os gravou). O token nunca é logado nem vai para o disco.
    public func adopt(_ live: LiveComputer, spec: ComputerSpec) async throws -> AdoptedComputer {
        let user = ComputerProvisioner.egressUser
        let runDirectory = "/run/racky"
        let tokenResult = try await client.run(in: live.containerID, command: ["cat", "\(runDirectory)/token"], user: user, timeout: .seconds(15))
        let token = tokenResult.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard tokenResult.exitCode == 0, !token.isEmpty else { throw ComputerProvisionerError.provisioningFailed("the computer's token is not readable") }
        let configResult = try await client.run(in: live.containerID, command: ["cat", "\(runDirectory)/egress.json"], user: user, timeout: .seconds(15))
        let parsed = configResult.exitCode == 0 ? Self.parseEgressConfig(configResult.stdout) : nil
        let config = parsed ?? EgressConfigFile.make(profile: nil, secret: nil, allowCIDRs: allowCIDRs, allowHosts: [])
        let inspect = try await client.inspectContainer(live.containerID)
        guard let hostPort = inspect.publishedHostPort(for: "\(config.adminPort)/tcp") else { throw ComputerProvisionerError.noPublishedPort }
        let port = try await host.reach(publishedPort: hostPort, computerID: live.computerID)
        let labels = ComputerLabels(
            owner: owner, computerID: live.computerID, computerName: live.name, batch: live.batch ?? spec.batch, ephemeral: true, isTest: isTest)
        let computer = ProvisionedComputer(
            labels: labels, display: spec.display, containerID: live.containerID, containerName: inspect.name, adminPort: port,
            profileVolume: spec.display == .http ? nil : "ab-prof-\(live.computerID)", workDirectory: spec.run.work, logsDirectory: spec.run.logs,
            admin: EgressAdminClient(port: port, token: token), host: host.host, remoteAdminPort: host.host.isRemote ? hostPort : nil)
        try await computer.admin.waitUntilHealthy(timeout: .seconds(8))
        let backend = DockerComputerBackend(client: client, computer: computer, secrets: secrets, baseConfig: config, resolver: resolver)
        let provisioner = ComputerProvisioner(host: host)
        let secrets = secrets
        let handle = ProvisionedHandle(backend: backend) { _ = try? await provisioner.teardown(computer, secrets: secrets) }
        return AdoptedComputer(handle: handle, proxy: config.via, allowHosts: config.allowHosts)
    }

    /// `egress.json` -> política (o upstream com credenciais não é relido: a troca de proxy o resolve de novo pelo `resolver`).
    static func parseEgressConfig(_ data: Data) -> EgressConfigFile? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let subnet = root["internal_subnet"] as? String else { return nil }
        return EgressConfigFile(
            via: root["via"] as? String ?? "direct", internalSubnet: subnet, proxyPort: root["proxy_port"] as? Int ?? EgressConfigFile.defaultProxyPort,
            adminPort: root["admin_port"] as? Int ?? EgressConfigFile.defaultAdminPort, allowCIDRs: root["allow_cidrs"] as? [String] ?? [],
            allowHosts: root["allow_hosts"] as? [String] ?? [])
    }
}
