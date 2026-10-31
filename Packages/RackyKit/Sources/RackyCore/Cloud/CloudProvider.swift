import Foundation

// BK-12 (P27.8): a interface de provedor é central desde o MVP. AWS é o primeiro adaptador; cada outro provedor entra como adaptador
// depois do PRÓPRIO spike. O app só fala com `CloudProvider`; nada fora do adaptador conhece EC2, Hetzner etc.

public struct CloudProviderID: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public static let aws: CloudProviderID = "aws"
    public static let fake: CloudProviderID = "fake"
}

public enum CloudError: Error, Sendable, Equatable {
    /// Adaptador ainda sem implementação (ex.: `AWSProvider` até o spike da Fase 0).
    case notImplemented(String)
    case notFound(String)
    case quotaExceeded(region: String, needed: Int, available: Int)
    case spendCapExceeded(SpendDenial)
    case acceptableUseNotAccepted(provider: CloudProviderID, version: String)
    case provider(String)
}

/// Tamanho da VM host. `id` é o nome do provedor (`c7g.4xlarge`).
public struct HostShape: Sendable, Equatable, Hashable, Codable {
    public var id: String
    public var vcpus: Int
    public var memoryGiB: Double
    public var architecture: String
    public init(id: String, vcpus: Int, memoryGiB: Double, architecture: String = "arm64") {
        self.id = id; self.vcpus = vcpus; self.memoryGiB = memoryGiB; self.architecture = architecture
    }
}

public struct CloudRegion: Sendable, Equatable, Identifiable, Codable {
    public var id: String
    public var name: String
    /// Cidade/país para a UI.
    public var location: String
    /// Medida do app até a região (ms); `nil` até medir. A medição é do app (TCP ao endpoint público), não do provedor.
    public var latencyMS: Int?
    /// Endpoint leve para medir latência sem criar nada.
    public var probeHost: String?
    public init(id: String, name: String, location: String, latencyMS: Int? = nil, probeHost: String? = nil) {
        self.id = id; self.name = name; self.location = location; self.latencyMS = latencyMS; self.probeHost = probeHost
    }
}

public struct CloudQuota: Sendable, Equatable {
    public var region: String
    public var vcpuLimit: Int
    public var vcpuInUse: Int
    public var vcpuAvailable: Int { max(0, vcpuLimit - vcpuInUse) }
    public init(region: String, vcpuLimit: Int, vcpuInUse: Int) { self.region = region; self.vcpuLimit = vcpuLimit; self.vcpuInUse = vcpuInUse }
}

/// Estimativa de custo por hora (sempre rotulada "estimativa" na UI, 6.5 do estudo): VM + IPv4 público + disco. Tráfego fica fora.
public struct CostEstimate: Sendable, Equatable {
    public var instanceHourlyUSD: Double
    public var addressHourlyUSD: Double
    public var storageHourlyUSD: Double
    public var hourlyUSD: Double { instanceHourlyUSD + addressHourlyUSD + storageHourlyUSD }
    public init(instanceHourlyUSD: Double, addressHourlyUSD: Double = 0, storageHourlyUSD: Double = 0) {
        self.instanceHourlyUSD = instanceHourlyUSD; self.addressHourlyUSD = addressHourlyUSD; self.storageHourlyUSD = storageHourlyUSD
    }
}

/// Uso aceitável (P27.7): confirmação completa na primeira conexão de cada conta/provedor e reconfirmação quando `version` mudar.
public struct AcceptableUsePolicy: Sendable, Equatable {
    public var provider: CloudProviderID
    /// Identificador da revisão do AUP do provedor (data ou hash); mudar exige nova confirmação.
    public var version: String
    public var url: URL
    /// Linha curta sempre visível no card de aprovação e no viewer.
    public var shortNotice: String
    public init(provider: CloudProviderID, version: String, url: URL, shortNotice: String) {
        self.provider = provider; self.version = version; self.url = url; self.shortNotice = shortNotice
    }
}

public enum CloudHostState: String, Sendable, Equatable, Codable {
    case pending, running, terminating, terminated
    public var isLive: Bool { self == .pending || self == .running }
}

public struct CloudHost: Sendable, Equatable, Identifiable {
    public var id: String
    public var provider: CloudProviderID
    public var region: String
    public var shape: HostShape
    public var state: CloudHostState
    /// IP/DNS público quando a VM já tem (SSH é a única porta de entrada).
    public var address: String?
    public var launchedAt: Date
    public var tags: [String: String]
    public var hourlyUSD: Double
    public init(id: String, provider: CloudProviderID, region: String, shape: HostShape, state: CloudHostState = .pending, address: String? = nil,
                launchedAt: Date, tags: [String: String], hourlyUSD: Double) {
        self.id = id; self.provider = provider; self.region = region; self.shape = shape; self.state = state; self.address = address
        self.launchedAt = launchedAt; self.tags = tags; self.hourlyUSD = hourlyUSD
    }
}

/// Pedido de uma VM host. `userData` é o cloud-init (`CloudInit`), que já traz a chave de acesso, a chave do host e a chave morta.
public struct HostRequest: Sendable, Equatable {
    public var region: String
    public var shape: HostShape
    public var tags: RackyTags
    public var userData: String
    public var maxLifetime: Duration
    public init(region: String, shape: HostShape, tags: RackyTags, userData: String, maxLifetime: Duration) {
        self.region = region; self.shape = shape; self.tags = tags; self.userData = userData; self.maxLifetime = maxLifetime
    }
}

/// O que o app precisa de um provedor (08 AR-114). Tudo `async throws`, cancelável, sem estado compartilhado no app.
public protocol CloudProvider: Sendable {
    var id: CloudProviderID { get }
    func acceptableUsePolicy() async throws -> AcceptableUsePolicy
    func regions() async throws -> [CloudRegion]
    func quota(region: String) async throws -> CloudQuota
    /// Formatos oferecidos (o app escolhe pelo `ComputerDisplay` e pela quantidade).
    func shapes(region: String) async throws -> [HostShape]
    func estimate(shape: HostShape, region: String) async throws -> CostEstimate
    func provisionHost(_ request: HostRequest) async throws -> CloudHost
    /// Só recursos que carregam TODAS as `tags` pedidas (o adaptador filtra no provedor, nunca varre a conta).
    func listHosts(tags: [String: String], regions: [String]) async throws -> [CloudHost]
    func terminateHost(id: String, region: String) async throws
}
