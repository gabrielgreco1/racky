import RackyDocker
import RackyProtocol
import Foundation
import Testing

@testable import RackyCore

/// Config do egress para o modo render (07 CS-146, P13): a chave só vai para o arquivo 0400 do egress.
@Suite struct EgressRenderConfigTests {
    func json(_ config: EgressConfigFile) throws -> JSON { try JSON.parse(try config.jsonData()) }

    @Test func zyteApiProfileDeclaresRenderWithTheSameKey() throws {
        var profile = ProxyProfile.zytePreset(name: "zyte-us", secretID: nil)
        profile.apiMode = true
        let config = EgressConfigFile.make(profile: profile, secret: "zyte-key-123456", allowCIDRs: ["10.0.0.0/8"])
        #expect(config.render == EgressRender(adapter: "zyte", endpoint: "https://api.zyte.com/v1/extract", apiKey: "zyte-key-123456"))
        let out = try json(config)
        #expect(out["render"]?["adapter"] == "zyte" && out["render"]?["endpoint"] == "https://api.zyte.com/v1/extract" && out["render"]?["api_key"] == "zyte-key-123456")
        #expect(out["via"] == "zyte-us" && out["upstream"]?["host"] == "proxy.zyte.com")
    }

    @Test func profilesWithoutApiModeOrDirectHaveNoRender() throws {
        let zyte = ProxyProfile.zytePreset(name: "zyte", secretID: nil)
        #expect(EgressConfigFile.make(profile: zyte, secret: "k-123456").render == nil)  // proxy sem render: `not_supported`
        #expect(try json(EgressConfigFile.make(profile: zyte, secret: "k-123456"))["render"] == nil)
        #expect(EgressConfigFile.make(profile: nil, secret: nil).render == nil)
        var custom = ProxyProfile(name: "custom", scheme: .http, host: "p.example", port: 8080, apiMode: true)
        #expect(EgressConfigFile.make(profile: custom, secret: "secret-1").render == nil)  // modo API sem endpoint não inventa um
        custom.renderEndpoint = "https://render.example/v1/extract"
        #expect(EgressConfigFile.make(profile: custom, secret: "secret-1").render?.endpoint == "https://render.example/v1/extract")
        #expect(EgressConfigFile.make(profile: custom, secret: nil).render == nil)  // sem chave não há render
    }

    @Test func theKeyNeverLeavesTheEgressFile() throws {
        var profile = ProxyProfile.zytePreset(name: "zyte", secretID: nil)
        profile.apiMode = true
        let config = EgressConfigFile.make(profile: profile, secret: "very-secret-key")
        // `via`/nome é o único que o agente enxerga; a chave só existe no JSON do arquivo 0400 do egress
        #expect(config.via == "zyte" && !config.via.contains("very-secret"))
        #expect(try String(decoding: config.jsonData(), as: UTF8.self).contains("very-secret-key"))
    }

    /// Git de dentro do computador: o bloco `github` vai para o egress.json (o token só existe ali, 0400 do egress).
    @Test func githubAccessGoesToTheEgressFile() throws {
        var config = EgressConfigFile.make(profile: nil, secret: nil)
        #expect(try json(config)["github"] == nil)
        config.github = EgressGitHub(token: "ghp_token123", repos: ["acme/acme-platform"])
        let out = try json(config)
        #expect(out["github"]?["token"] == "ghp_token123")
        #expect(out["github"]?["repos"] == ["acme/acme-platform"])
        #expect(out["github"]?["push_prefixes"] == ["refs/heads/feat/"])
    }
}
