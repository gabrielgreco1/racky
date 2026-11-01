import Foundation

/// Provedor falso em memória: o mesmo contrato do real, sem rede e sem custo. Usado nos testes e como demonstração da UI.
/// Respeita o filtro de tags de `listHosts` como a API real (só devolve o que carrega todas as tags pedidas).
public actor FakeCloudProvider: CloudProvider {
    public nonisolated let id: CloudProviderID
    public var clock: @Sendable () -> Date
    public var hourlyPrice: [String: Double]
    public var quotaVCPUs: Int
    public var addressHourly = 0.005
    public var storageHourly = 0.0033
    public var aupVersion = "2026-10-01"
    /// Falhas injetáveis.
    public var failProvision: CloudError?
    public var failTerminate: Set<String> = []
    /// Regiões cuja listagem falha (SCP negando, throttling).
    public var failListRegions: Set<String> = []
    public private(set) var calls: [String] = []
    private var hosts: [String: CloudHost] = [:]
    private var counter = 0

    public static let shapes = [
        HostShape(id: "c7g.large", vcpus: 2, memoryGiB: 4),
        HostShape(id: "c7g.4xlarge", vcpus: 16, memoryGiB: 32),
    ]

    public init(id: CloudProviderID = .fake, clock: @escaping @Sendable () -> Date = { Date() }, quotaVCPUs: Int = 32,
                hourlyPrice: [String: Double] = ["c7g.large": 0.0725, "c7g.4xlarge": 0.58]) {
        self.id = id; self.clock = clock; self.quotaVCPUs = quotaVCPUs; self.hourlyPrice = hourlyPrice
    }

    public func setClock(_ clock: @escaping @Sendable () -> Date) { self.clock = clock }
    public func setFailProvision(_ error: CloudError?) { failProvision = error }
    public func setFailTerminate(_ ids: Set<String>) { failTerminate = ids }
    public func setFailListRegions(_ regions: Set<String>) { failListRegions = regions }

    public func acceptableUsePolicy() async throws -> AcceptableUsePolicy {
        calls.append("aup")
        return AcceptableUsePolicy(provider: id, version: aupVersion, url: URL(string: "https://example.invalid/aup")!,
                                   shortNotice: "Fake cloud: uso aceitável do provedor se aplica.")
    }

    public func regions() async throws -> [CloudRegion] {
        calls.append("regions")
        return [CloudRegion(id: "us-east-1", name: "US East", location: "Virginia, US", probeHost: "ec2.us-east-1.example.invalid"),
                CloudRegion(id: "sa-east-1", name: "South America", location: "São Paulo, BR", probeHost: "ec2.sa-east-1.example.invalid")]
    }

    public func quota(region: String) async throws -> CloudQuota {
        calls.append("quota:\(region)")
        let used = hosts.values.filter { $0.region == region && $0.state.isLive }.reduce(0) { $0 + $1.shape.vcpus }
        return CloudQuota(region: region, vcpuLimit: quotaVCPUs, vcpuInUse: used)
    }

    public func shapes(region: String) async throws -> [HostShape] { calls.append("shapes:\(region)"); return Self.shapes }

    public func estimate(shape: HostShape, region: String) async throws -> CostEstimate {
        calls.append("estimate:\(shape.id)")
        guard let price = hourlyPrice[shape.id] else { throw CloudError.notFound("shape \(shape.id)") }
        return CostEstimate(instanceHourlyUSD: price, addressHourlyUSD: addressHourly, storageHourlyUSD: storageHourly)
    }

    public func provisionHost(_ request: HostRequest) async throws -> CloudHost {
        calls.append("provision:\(request.shape.id)")
        if let failProvision { throw failProvision }
        let estimate = try await estimate(shape: request.shape, region: request.region)
        counter += 1
        let host = CloudHost(
            id: "fake-\(counter)", provider: id, region: request.region, shape: request.shape, state: .running, address: "203.0.113.\(counter)",
            launchedAt: clock(), tags: request.tags.dictionary, hourlyUSD: estimate.hourlyUSD)
        hosts[host.id] = host
        return host
    }

    public func listHosts(tags: [String: String], regions: [String]) async throws -> [CloudHost] {
        calls.append("list")
        if let bad = regions.first(where: { failListRegions.contains($0) }) { throw CloudError.provider("list negado em \(bad)") }
        return hosts.values.filter { host in
            regions.contains(host.region) && tags.allSatisfy { host.tags[$0.key] == $0.value }
        }.sorted { $0.id < $1.id }
    }

    public func terminateHost(id: String, region: String) async throws {
        calls.append("terminate:\(id)")
        if failTerminate.contains(id) { throw CloudError.provider("terminate recusado") }
        guard var host = hosts[id], host.region == region else { throw CloudError.notFound(id) }
        host.state = .terminated
        hosts[id] = host
    }

    // MARK: Apoio dos testes

    /// Injeta um recurso qualquer (ex.: de outro dono, sem tags) para provar que o reaper não o toca.
    public func inject(_ host: CloudHost) { hosts[host.id] = host }
    public func host(_ id: String) -> CloudHost? { hosts[id] }
    public var liveHostIDs: [String] { hosts.values.filter { $0.state.isLive }.map(\.id).sorted() }
    /// Contagem de chamadas que criam recursos (um teste de "nada foi criado" confere que é 0).
    public var provisionCalls: Int { calls.filter { $0.hasPrefix("provision:") }.count }
}
