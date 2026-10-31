import RackyCore
import RackyPlatform
import RackyProtocol
import RackyStore
import Foundation
import Testing

@testable import RackyUI

/// Settings › Computers › Proxies: cadastro, edição, padrão global, teste e importação do CLI antigo, pelas ações `proxy.*`.
/// Store real em pasta temporária e Vault com chave mestra em memória (nunca o Keychain do usuário).
@MainActor
@Suite(.serialized, .offscreenAppKit) struct ProxiesSettingsTests {
    struct Rig {
        let home: URL
        let store: RackyStore
        let model: SettingsModel
        let registry: ActionRegistry
        let vault: SecretVault
        let cliEnv: URL
    }

    nonisolated final class TestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        var calls: [String] { lock.withLock { _calls } }
        func add(_ s: String) { lock.withLock { _calls.append(s) } }
    }

    private func rig(cliEnvText: String? = nil, log: TestLog = TestLog()) async throws -> Rig {
        let home = try SettingsModelTests.tempHome()
        let store = try await SettingsModelTests.openStore(home)
        let flags = SliceFlags(current: .slice3)
        let model = SettingsModel(flags: flags, probe: SettingsModelTests.stub())
        let vault = SecretVault(store: store, keyring: VaultKeyring(backend: InMemoryMasterKeyBackend()))
        model.proxyService = ProxyService(store: store, vault: vault)
        model.proxyTester = { profile, secret in
            log.add("\(profile.name)|\(profile.host):\(profile.port)|\(secret ?? "-")")
            return ProxyTestResult(ok: true, summary: "Connected through \(profile.host) · 312 ms", latencyMilliseconds: 312)
        }
        let cliEnv = home.appendingPathComponent("cli.env")
        if let cliEnvText { try cliEnvText.write(to: cliEnv, atomically: true, encoding: .utf8) }
        model.cliEnvFile = cliEnv
        let registry = ActionRegistry(flags: flags, surface: FakeSurface())
        try model.registerActions(in: registry)
        await model.attach(store: store)
        return Rig(home: home, store: store, model: model, registry: registry, vault: vault, cliEnv: cliEnv)
    }

    private func cleanup(_ rig: Rig) async {
        try? await rig.store.close()
        try? FileManager.default.removeItem(at: rig.home)
    }

    private func fill(_ model: SettingsModel, name: String, host: String, port: String, user: String = "", password: String = "", country: String = "") {
        model.updateProxyDraft {
            $0.name = name; $0.host = host; $0.port = port; $0.username = user; $0.password = password; $0.country = country
        }
    }

    @Test func createEditAndDeleteKeepTheSecretInTheVaultOnly() async throws {
        let rig = try await rig()
        defer { Task { await cleanup(rig) } }
        let model = rig.model

        _ = try await rig.registry.perform(.proxyAdd, .press)
        #expect(model.proxyDraft?.isNew == true)
        fill(model, name: "", host: "proxy.example.com", port: "8080")
        await #expect(throws: ActionError.self) { _ = try await rig.registry.perform(.proxySave, .press) }
        #expect(model.proxyDraft?.error == "Enter a name.")
        fill(model, name: "office", host: "proxy.example.com", port: "99999")
        await #expect(throws: ActionError.self) { _ = try await rig.registry.perform(.proxySave, .press) }
        #expect(model.proxyDraft?.error == "Port must be 1–65535.")

        _ = try await rig.registry.perform(.proxyScheme, .select("socks5"))
        fill(model, name: "office", host: "proxy.example.com", port: "1080", user: "alex", password: "s3cret", country: "US")
        _ = try await rig.registry.perform(.proxySave, .press)
        #expect(model.proxyDraft == nil)
        let saved = try #require(model.proxies.first)
        #expect(saved.name == "office" && saved.scheme == .socks5 && saved.port == 1080 && saved.username == "alex" && saved.geo?.country == "us")
        let secretID = try #require(saved.secretID.flatMap(UUID.init(uuidString:)))
        #expect(try await rig.vault.reveal(id: secretID).text == "s3cret")
        let encoded = String(decoding: try JSONEncoder().encode(saved), as: UTF8.self)
        #expect(!encoded.contains("s3cret"), "a senha nunca fica no perfil")

        // Editar com a senha vazia mantém a salva; trocar o host não troca o segredo.
        _ = try await rig.registry.perform(.proxyEdit, .select(saved.id.uuidString))
        #expect(model.proxyDraft?.password == "" && model.proxyDraft?.host == "proxy.example.com")
        fill(model, name: "office", host: "proxy2.example.com", port: "1080", user: "alex")
        _ = try await rig.registry.perform(.proxySave, .press)
        let edited = try #require(model.proxies.first)
        #expect(edited.host == "proxy2.example.com" && edited.secretID == saved.secretID)
        #expect(try await rig.vault.reveal(id: secretID).text == "s3cret")

        // Nome repetido.
        _ = try await rig.registry.perform(.proxyAdd, .press)
        fill(model, name: "office", host: "other.example.com", port: "3128")
        await #expect(throws: ActionError.self) { _ = try await rig.registry.perform(.proxySave, .press) }
        #expect(model.proxyDraft?.error == "A proxy named office already exists.")
        _ = try await rig.registry.perform(.proxyCancel, .press)
        #expect(model.proxyDraft == nil)

        // Padrão global.
        _ = try await rig.registry.perform(.proxySetDefault, .select(edited.id.uuidString))
        #expect(model.defaultProxyID == edited.id)
        #expect(try await rig.store.defaultProxy()?.name == "office")
        _ = try await rig.registry.perform(.proxySetDefault, .select("none"))
        #expect(model.defaultProxyID == nil)

        // Apagar pede confirmação e leva o segredo junto.
        let armed = try await rig.registry.perform(.proxyDelete, .select(edited.id.uuidString))
        #expect(armed.message == "confirm" && model.proxies.count == 1 && model.proxyDeleteArmed == edited.id)
        _ = try await rig.registry.perform(.proxyDelete, .select("\(edited.id.uuidString):confirm"))
        #expect(model.proxies.isEmpty)
        #expect((try? await rig.vault.info(id: secretID)) == nil, "o segredo sai do Vault com o proxy")
    }

    @Test func zytePresetFillsTheFieldsAndTestUsesTheTypedOrSavedSecret() async throws {
        let log = TestLog()
        let rig = try await rig(log: log)
        defer { Task { await cleanup(rig) } }
        let model = rig.model

        _ = try await rig.registry.perform(.proxyAdd, .press)
        _ = try await rig.registry.perform(.proxyPreset, .select("zyte"))
        #expect(model.proxyDraft?.host == "proxy.zyte.com" && model.proxyDraft?.port == "8011" && model.proxyDraft?.name == "zyte")
        // O preset Zyte exige a chave ao criar.
        await #expect(throws: ActionError.self) { _ = try await rig.registry.perform(.proxySave, .press) }
        #expect(model.proxyDraft?.error == "Enter the Zyte API key.")
        model.updateProxyDraft { $0.password = "KEY123" }
        let summary = try await rig.registry.perform(.proxyTest, .press)
        #expect(summary.message?.contains("312 ms") == true)
        #expect(model.proxyTest == .result(ProxyTestResult(ok: true, summary: "Connected through proxy.zyte.com · 312 ms", latencyMilliseconds: 312)))
        _ = try await rig.registry.perform(.proxySave, .press)
        let saved = try #require(model.proxies.first)
        #expect(saved.preset == .zyte && saved.username == nil)

        // Testar o proxy salvo lê a chave do Vault.
        _ = try await rig.registry.perform(.proxyTest, .select(saved.id.uuidString))
        #expect(log.calls == ["zyte|proxy.zyte.com:8011|KEY123", "zyte|proxy.zyte.com:8011|KEY123"])
    }

    @Test func importFromTheOldCLIAsksFirstAndReadsOnlyTheZyteKey() async throws {
        let rig = try await rig(cliEnvText: "CLAUDE_CODE_OAUTH_TOKEN=nope\nZYTE_API_KEY=abc123\nZYTE_BUDGET_USD=1\n")
        defer { Task { await cleanup(rig) } }
        let model = rig.model
        #expect(model.zyteImportAvailable)
        let ask = try await rig.registry.perform(.proxyImportFromCLI, .press)
        #expect(ask.message == "confirm" && model.zyteImportArmed && model.proxies.isEmpty, "sem confirmação nada é lido nem criado")
        let done = try await rig.registry.perform(.proxyImportFromCLI, .select("confirm"))
        #expect(done.message == "zyte" && !model.zyteImportArmed)
        let proxy = try #require(model.proxies.first)
        #expect(proxy.preset == .zyte && proxy.host == "proxy.zyte.com" && proxy.port == 8011)
        let secretID = try #require(proxy.secretID.flatMap(UUID.init(uuidString:)))
        #expect(try await rig.vault.reveal(id: secretID).text == "abc123")
    }

    @Test func importButtonIsDisabledWithoutAZyteKey() async throws {
        let rig = try await rig(cliEnvText: "ZYTE_API_KEY=\nOTHER=1\n")
        defer { Task { await cleanup(rig) } }
        #expect(!rig.model.zyteImportAvailable)
        #expect(rig.registry.availability(of: .proxyImportFromCLI) == .disabled(reason: "No Zyte key found in the racky CLI settings."))
    }
}
