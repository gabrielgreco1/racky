import Foundation

public enum ProxyPreset: String, Codable, Sendable, CaseIterable {
    case custom, zyte
}

public enum ProxyScheme: String, Codable, Sendable, CaseIterable {
    case http, https, socks5
}

/// Como o país entra na conexão com o upstream (07 CS-160): sufixo no usuário, header ou host por país.
public enum ProxyGeoMode: String, Codable, Sendable, CaseIterable {
    case suffix, header, host
}

public struct ProxyGeo: Codable, Hashable, Sendable {
    /// Código do país (`us`). `nil` = sem geo.
    public var country: String?
    public var mode: ProxyGeoMode
    /// `-country-{cc}` (sufixo), `{cc}.proxy.example` (host: também aceita `{host}`).
    public var template: String
    public var header: String

    public init(country: String? = nil, mode: ProxyGeoMode = .suffix, template: String = "-country-{cc}", header: String = "X-Country") {
        self.country = country; self.mode = mode; self.template = template; self.header = header
    }
}

/// Onde mora o segredo do proxy (senha ou chave). `vault` é o Vault do app (T2-10, ainda não existe);
/// `file` é o arquivo 0600 em App Support da T3-02, até o Vault entrar.
public enum ProxySecretStorage: String, Codable, Sendable, CaseIterable {
    case vault, file
}

/// Proxy de saída cadastrado pelo usuário (07 §2.6, P13). Genérico: Zyte é só um preset. **Não há teto de orçamento**: o app
/// configura, registra e mostra uso. A senha nunca fica neste modelo nem no SQLite: `secretID` aponta para o armazenamento.
public struct ProxyProfile: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var preset: ProxyPreset
    public var scheme: ProxyScheme
    public var host: String
    public var port: Int
    public var username: String?
    public var secretID: String?
    public var secretStorage: ProxySecretStorage
    public var geo: ProxyGeo?
    /// Modo API/render do provedor (CS-146). O adaptador entra na T3-03.
    public var apiMode: Bool
    public var renderEndpoint: String?
    /// CA extra (PEM) para proxies HTTPS que assinam o próprio certificado (Zyte).
    public var caPEM: String?
    /// Preço informativo (micro-USD); só para mostrar custo "estimated". Nada corta por valor.
    public var pricePerRequestMicros: Int64?
    public var pricePerRenderMicros: Int64?
    public var isDefault: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = .v7(), name: String, preset: ProxyPreset = .custom, scheme: ProxyScheme, host: String, port: Int,
        username: String? = nil, secretID: String? = nil, secretStorage: ProxySecretStorage = .vault, geo: ProxyGeo? = nil,
        apiMode: Bool = false, renderEndpoint: String? = nil, caPEM: String? = nil, pricePerRequestMicros: Int64? = nil,
        pricePerRenderMicros: Int64? = nil, isDefault: Bool = false, createdAt: Date = Date(), updatedAt: Date? = nil
    ) {
        self.id = id; self.name = name; self.preset = preset; self.scheme = scheme; self.host = host; self.port = port
        self.username = username; self.secretID = secretID; self.secretStorage = secretStorage; self.geo = geo
        self.apiMode = apiMode; self.renderEndpoint = renderEndpoint; self.caPEM = caPEM
        self.pricePerRequestMicros = pricePerRequestMicros; self.pricePerRenderMicros = pricePerRenderMicros
        self.isDefault = isDefault; self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt
    }

    /// Preset `Zyte (proxy)` (07 CS-160): `proxy.zyte.com:8011`, a chave vai como usuário e a senha fica vazia.
    public static func zytePreset(name: String = "zyte", secretID: String?, createdAt: Date = Date()) -> ProxyProfile {
        ProxyProfile(name: name, preset: .zyte, scheme: .http, host: "proxy.zyte.com", port: 8011, username: nil, secretID: secretID,
                     createdAt: createdAt)
    }
}

/// Uso de um proxy por período (08 §3: `proxy_usage`). Só exibição.
public struct ProxyUsageRow: Codable, Hashable, Sendable {
    public var proxyID: UUID
    public var computerID: UUID?
    public var periodStart: Date
    public var requests: Int
    public var bytes: Int
    public var costMicros: Int64?

    public init(proxyID: UUID, computerID: UUID?, periodStart: Date, requests: Int, bytes: Int, costMicros: Int64? = nil) {
        self.proxyID = proxyID; self.computerID = computerID; self.periodStart = periodStart
        self.requests = requests; self.bytes = bytes; self.costMicros = costMicros
    }
}
