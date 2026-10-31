import Foundation

/// Provedores que a tela Computers mostra (BK-12, P27): nome, logo, preço de referência, regiões e links. Só a AWS está no plano da
/// Fase 1; os outros aparecem como "em breve" (portabilidade é decisão do dono: o usuário escolhe o provedor).
public struct CloudProviderInfo: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// Nome do PNG em `AgentLogos` (template, tingido com `brandHex`).
    public var logo: String
    public var brandHex: UInt32
    public var available: Bool
    /// Preço de referência de um computador (2 vCPU/4 GB) por hora, em US$ (estudo §3); `nil` quando não se aplica.
    public var referenceHourlyUSD: Double?
    public var regions: [CloudRegionInfo]
    public var links: [CloudProviderLink]
}

public struct CloudRegionInfo: Sendable, Equatable, Identifiable {
    public var id: String
    public var city: String
    public var flag: String
}

public struct CloudProviderLink: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case console, pricing, setup }
    public var kind: Kind
    public var url: URL
    public var id: String { kind.rawValue }
}

public enum CloudProviderCatalog {
    public static let aws = CloudProviderInfo(
        id: "aws", name: "AWS", logo: "aws", brandHex: 0xFF9900, available: true,
        // `c7g.large` US$ 0,0725/h + IPv4 público US$ 0,005/h (estudo §3, us-east-1).
        referenceHourlyUSD: 0.08,
        regions: [
            CloudRegionInfo(id: "us-east-1", city: "N. Virginia", flag: "🇺🇸"),
            CloudRegionInfo(id: "us-east-2", city: "Ohio", flag: "🇺🇸"),
            CloudRegionInfo(id: "us-west-2", city: "Oregon", flag: "🇺🇸"),
            CloudRegionInfo(id: "sa-east-1", city: "São Paulo", flag: "🇧🇷"),
            CloudRegionInfo(id: "eu-west-1", city: "Ireland", flag: "🇮🇪"),
            CloudRegionInfo(id: "eu-central-1", city: "Frankfurt", flag: "🇩🇪"),
            CloudRegionInfo(id: "ap-northeast-1", city: "Tokyo", flag: "🇯🇵"),
        ],
        links: [
            CloudProviderLink(kind: .console, url: URL(string: "https://console.aws.amazon.com/ec2/")!),
            CloudProviderLink(kind: .pricing, url: URL(string: "https://aws.amazon.com/ec2/pricing/on-demand/")!),
            CloudProviderLink(kind: .setup, url: URL(string: "https://docs.aws.amazon.com/singlesignon/latest/userguide/getting-started.html")!),
        ])

    public static let all: [CloudProviderInfo] = [
        aws,
        CloudProviderInfo(
            id: "hetzner", name: "Hetzner", logo: "hetzner", brandHex: 0xD50C2D, available: false, referenceHourlyUSD: 0.02, regions: [],
            links: [CloudProviderLink(kind: .pricing, url: URL(string: "https://www.hetzner.com/cloud/")!)]),
        CloudProviderInfo(
            id: "digitalocean", name: "DigitalOcean", logo: "digitalocean", brandHex: 0x0080FF, available: false, referenceHourlyUSD: 0.04, regions: [],
            links: [CloudProviderLink(kind: .pricing, url: URL(string: "https://www.digitalocean.com/pricing/droplets")!)]),
        CloudProviderInfo(
            id: "gcp", name: "Google Cloud", logo: "gcp", brandHex: 0x4285F4, available: false, referenceHourlyUSD: nil, regions: [],
            links: [CloudProviderLink(kind: .pricing, url: URL(string: "https://cloud.google.com/compute/vm-instance-pricing")!)]),
        CloudProviderInfo(
            id: "cloudflare", name: "Cloudflare", logo: "cloudflare", brandHex: 0xF38020, available: false, referenceHourlyUSD: nil, regions: [],
            links: [CloudProviderLink(kind: .pricing, url: URL(string: "https://developers.cloudflare.com/containers/")!)]),
    ]

    public static func provider(_ id: String) -> CloudProviderInfo? { all.first { $0.id == id } }

    /// Gasto máximo de um dia cheio com o teto de computadores ligado o tempo todo (ajuda a escolher o teto diário).
    public static func fullDayUSD(provider: CloudProviderInfo, computers: Int) -> Double? {
        provider.referenceHourlyUSD.map { $0 * 24 * Double(computers) }
    }
}
