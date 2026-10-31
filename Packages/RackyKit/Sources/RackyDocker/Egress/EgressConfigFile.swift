import Foundation

/// Proxy upstream já resolvido (com credenciais). Só existe em memória e no arquivo 0400 montado no egress (07 CS-145).
public struct EgressUpstream: Sendable, Equatable {
    public var scheme: String  // http | https | socks5
    public var host: String
    public var port: Int
    public var username: String?
    public var password: String?
    /// Caminho DENTRO do container do egress (`/run/racky/proxy-ca.pem`).
    public var caFile: String?
    public var geoCountry: String?
    public var geoMode: String
    public var geoTemplate: String
    public var geoHeader: String

    public init(scheme: String, host: String, port: Int, username: String? = nil, password: String? = nil, caFile: String? = nil,
                geoCountry: String? = nil, geoMode: String = "suffix", geoTemplate: String = "-country-{cc}", geoHeader: String = "X-Country") {
        self.scheme = scheme; self.host = host; self.port = port; self.username = username; self.password = password
        self.caFile = caFile; self.geoCountry = geoCountry; self.geoMode = geoMode; self.geoTemplate = geoTemplate; self.geoHeader = geoHeader
    }
}

/// Modo API/render do provedor (07 CS-146). A chave só existe no arquivo 0400 do egress.
public struct EgressRender: Sendable, Equatable {
    public var adapter: String  // zyte
    public var endpoint: String
    public var apiKey: String
    public init(adapter: String = "zyte", endpoint: String, apiKey: String) {
        self.adapter = adapter; self.endpoint = endpoint; self.apiKey = apiKey
    }
}

/// Acesso do computador ao GitHub pelo gateway do egress (`racky_egress/github_gateway.py`): o token do dono e a política. O agente
/// faz git e PR por `http://github.racky` / `http://api.github.racky` e nunca vê o token (só existe no arquivo 0400 do egress).
public struct EgressGitHub: Sendable, Equatable {
    public var token: String
    /// `dono/repo` permitidos (o repositório do projeto da sessão).
    public var repos: [String]
    /// Refs que o push pode atualizar (padrão `refs/heads/feat/`); `main` e apagar ref nunca passam.
    public var pushPrefixes: [String]
    public init(token: String, repos: [String], pushPrefixes: [String] = ["refs/heads/feat/"]) {
        self.token = token; self.repos = repos; self.pushPrefixes = pushPrefixes
    }
}

/// Conteúdo de `egress.json` (lido pelo `racky_egress.config`). Política, mais o upstream com credenciais quando há.
public struct EgressConfigFile: Sendable, Equatable {
    /// `direct` ou o nome do `ProxyProfile` (vai para `via` no reqlog).
    public var via: String
    public var upstream: EgressUpstream?
    /// Só quando o proxy escolhido declara o modo render (CS-146); sem isso o egress responde `not_supported`.
    public var render: EgressRender?
    public var internalSubnet: String
    public var proxyPort: Int
    public var adminPort: Int
    /// Exceção explícita e registrada ao filtro SSRF (07 CS-143, "Allow Local Network for This Computer").
    public var allowCIDRs: [String]
    public var allowHosts: [String]
    public var noise: [String]?
    public var bodyQuotaBytes: Int?
    /// Git e PR pelo gateway do egress; `nil` = desligado neste computador.
    public var github: EgressGitHub?

    public static let defaultProxyPort = 3128
    public static let defaultAdminPort = 8790

    public init(via: String = "direct", upstream: EgressUpstream? = nil, render: EgressRender? = nil, internalSubnet: String, proxyPort: Int = defaultProxyPort,
                adminPort: Int = defaultAdminPort, allowCIDRs: [String] = [], allowHosts: [String] = [], noise: [String]? = nil,
                bodyQuotaBytes: Int? = nil) {
        self.via = via; self.upstream = upstream; self.render = render; self.internalSubnet = internalSubnet; self.proxyPort = proxyPort
        self.adminPort = adminPort; self.allowCIDRs = allowCIDRs; self.allowHosts = allowHosts; self.noise = noise
        self.bodyQuotaBytes = bodyQuotaBytes
    }

    /// JSON estável (chaves ordenadas). Contém a senha do proxy: só vai para o arquivo 0400 do egress.
    public func jsonData() throws -> Data {
        var root: [String: Any] = [
            "via": via, "internal_subnet": internalSubnet, "proxy_port": proxyPort, "admin_port": adminPort,
            "allow_cidrs": allowCIDRs, "allow_hosts": allowHosts,
        ]
        if let noise { root["noise"] = noise }
        if let bodyQuotaBytes { root["body_quota_bytes"] = bodyQuotaBytes }
        if let up = upstream {
            var u: [String: Any] = ["scheme": up.scheme, "host": up.host, "port": up.port]
            if let name = up.username { u["username"] = name }
            if let password = up.password { u["password"] = password }
            if let caFile = up.caFile { u["ca_file"] = caFile }
            if let country = up.geoCountry {
                u["geo"] = ["country": country, "mode": up.geoMode, "template": up.geoTemplate, "header": up.geoHeader]
            }
            root["upstream"] = u
        }
        if let render {
            root["render"] = ["adapter": render.adapter, "endpoint": render.endpoint, "api_key": render.apiKey]
        }
        if let github {
            root["github"] = ["token": github.token, "repos": github.repos, "push_prefixes": github.pushPrefixes]
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .prettyPrinted])
    }
}
