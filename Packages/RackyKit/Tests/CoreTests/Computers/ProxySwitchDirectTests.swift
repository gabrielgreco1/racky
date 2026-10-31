import Foundation
import RackyDocker
import Testing

@testable import RackyCore

/// Regressão: `proxy_set {"proxy": "direct"}` pedia ao resolver um proxy salvo chamado "direct" e falhava (`unknownProxy`), então um
/// computador que foi para a Zyte não voltava para o IP próprio. "direct" é a config do computador sem upstream, como na reserva.
struct ProxySwitchDirectTests {
    actor Recorder: ComputerExecTransport {
        var configs: [EgressConfigFile] = []
        nonisolated func startExec(_ spec: ExecSpec) async throws -> any ComputerExecSession { throw ToolError(.notSupported, "no exec") }
        func rewriteConfig(_ config: EgressConfigFile, proxyCA: String?) async throws { configs.append(config) }
    }

    actor Calls { var names: [String] = []; func add(_ n: String) { names.append(n) } }

    @Test func directNeverAsksTheResolverAndDropsTheUpstream() async throws {
        let transport = Recorder()
        let calls = Calls()
        var base = EgressConfigFile.make(profile: nil, secret: nil, allowCIDRs: ["10.0.0.0/8"])
        base.github = EgressGitHub(token: "t", repos: ["o/r"])
        let computer = ProvisionedComputer(
            labels: ComputerLabels(owner: "o", computerID: "cid", computerName: "n"), display: .headless, containerID: "abc", containerName: "ab-1",
            adminPort: 1, profileVolume: nil, workDirectory: URL(fileURLWithPath: "/tmp/w"), logsDirectory: URL(fileURLWithPath: "/tmp/l"),
            admin: EgressAdminClient(port: 1, token: "t"))
        let backend = DockerComputerBackend(
            transport: transport, computer: computer, secrets: BoxSecretFiles(root: URL(fileURLWithPath: "/tmp/s")), baseConfig: base,
            resolver: { name, _ in await calls.add(name); throw ProxyServiceError.unknownProxy(name) })

        // O reload vai a uma admin API que não existe neste teste: o erro esperado é o da confirmação, depois de a config ser escrita.
        await #expect(throws: ToolError.self) { _ = try await backend.switchProxy(to: "direct", country: nil) }
        #expect(await calls.names.isEmpty, "direct não é um proxy salvo")
        let written = try #require(await transport.configs.last)
        #expect(written.upstream == nil)
        #expect(written.github?.repos == ["o/r"], "voltar ao direto não tira o acesso ao GitHub")

        await #expect(throws: ProxyServiceError.self) { _ = try await backend.switchProxy(to: "zyte", country: nil) }
        #expect(await calls.names == ["zyte"])
    }
}
