import RackyCore
import RackyProtocol
import Foundation

/// Formulário do proxy aberto em Settings › Computers › Proxies (03 §14.2). Só vive enquanto o formulário está aberto; a senha
/// nunca volta do Vault para cá: vazia na edição significa "manter a salva".
struct ProxyDraft: Equatable {
    var id: UUID?
    var name = ""
    var preset: ProxyPreset = .custom
    var scheme: ProxyScheme = .http
    var host = ""
    var port = ""
    var username = ""
    var password = ""
    var country = ""
    /// Perfil salvo de origem: o que o formulário não mostra (CA, preços, modo de geo) é preservado.
    var base: ProxyProfile?
    var error: String?

    var isNew: Bool { id == nil }

    init() {}

    init(_ profile: ProxyProfile) {
        id = profile.id
        name = profile.name
        preset = profile.preset
        scheme = profile.scheme
        host = profile.host
        port = String(profile.port)
        username = profile.username ?? ""
        country = profile.geo?.country ?? ""
        base = profile
    }

    /// O preset só preenche campos (03 §14.2): Zyte = `proxy.zyte.com:8011` por HTTP, a chave no lugar da senha.
    mutating func apply(preset: ProxyPreset) {
        self.preset = preset
        guard preset == .zyte else { return }
        scheme = .http
        host = "proxy.zyte.com"
        port = "8011"
        username = ""
        if name.isEmpty { name = "zyte" }
    }
}

enum ProxyTestState: Equatable {
    case idle
    case running
    case result(ProxyTestResult)
}

extension SettingsModel {
    static let proxyNotConfigured = "Proxies need the Computers feature."

    func reloadProxies() async {
        guard let store else { return }
        do {
            proxies = try await store.proxies()
            defaultProxyID = try await store.defaultProxy()?.id
        } catch { log.error("could not load proxies: \(error)") }
        zyteImportAvailable = Self.cliHasZyteKey(at: cliEnvFile)
    }

    /// `Import from racky CLI…` só aparece se o `.env` do CLI antigo tem chave Zyte (lê só a chave pedida; nunca a mostra).
    nonisolated static func cliHasZyteKey(at file: URL) -> Bool {
        guard let data = try? Data(contentsOf: file) else { return false }
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "export ", with: "")
            guard trimmed.hasPrefix("ZYTE_API_KEY=") else { return false }
            let value = trimmed.dropFirst("ZYTE_API_KEY=".count).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            return !value.isEmpty
        }
    }

    func proxy(id: UUID) -> ProxyProfile? { proxies.first { $0.id == id } }

    // MARK: Formulário

    func newProxy() {
        proxyDeleteArmed = nil
        proxyTest = .idle
        proxyDraft = ProxyDraft()
    }

    func editProxy(id: UUID) throws {
        guard let profile = proxy(id: id) else { throw SettingsError.invalid("Proxy not found.") }
        if proxyDraft?.id == id {
            proxyDraft = nil
        } else {
            proxyDeleteArmed = nil
            proxyTest = .idle
            proxyDraft = ProxyDraft(profile)
        }
    }

    func cancelProxyEdit() {
        proxyDraft = nil
        proxyTest = .idle
    }

    func setProxyError(_ message: String) { proxyDraft?.error = message }

    func updateProxyDraft(_ change: (inout ProxyDraft) -> Void) {
        guard var draft = proxyDraft else { return }
        change(&draft)
        draft.error = nil
        proxyDraft = draft
    }

    /// Valida o formulário e devolve o perfil a gravar (sem a senha).
    func validatedProxy(_ draft: ProxyDraft) throws -> ProxyProfile {
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw SettingsError.invalid("Enter a name.") }
        let host = draft.host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, !host.contains(" "), !host.contains("/") else { throw SettingsError.invalid("Enter a host, like proxy.example.com.") }
        guard let port = Int(draft.port.trimmingCharacters(in: .whitespaces)), (1 ... 65535).contains(port) else {
            throw SettingsError.invalid("Port must be 1–65535.")
        }
        let country = draft.country.trimmingCharacters(in: .whitespaces).lowercased()
        guard country.isEmpty || (country.count == 2 && country.allSatisfy(\.isLetter)) else {
            throw SettingsError.invalid("Country is a two-letter code, like us.")
        }
        var profile = draft.base ?? ProxyProfile(name: name, preset: draft.preset, scheme: draft.scheme, host: host, port: port)
        profile.name = name
        profile.preset = draft.preset
        profile.scheme = draft.scheme
        profile.host = host
        profile.port = port
        profile.username = draft.preset == .zyte || draft.username.trimmingCharacters(in: .whitespaces).isEmpty ? nil : draft.username.trimmingCharacters(in: .whitespaces)
        if country.isEmpty {
            profile.geo = nil
        } else {
            var geo = profile.geo ?? ProxyGeo()
            geo.country = country
            profile.geo = geo
        }
        return profile
    }

    func saveProxy() async throws {
        guard let service = proxyService else { throw SettingsError.noStore }
        guard let draft = proxyDraft else { throw SettingsError.invalid("Open a proxy first.") }
        do {
            let profile = try validatedProxy(draft)
            let secret = draft.password.isEmpty ? nil : draft.password
            if draft.preset == .zyte, draft.isNew, secret == nil { throw SettingsError.invalid("Enter the Zyte API key.") }
            try await service.save(profile, secret: secret)
            proxyDraft = nil
            proxyTest = .idle
            await reloadProxies()
        } catch let error as ProxyServiceError {
            let message: String
            switch error {
            case .nameInUse(let name): message = "A proxy named \(name) already exists."
            default: message = "Couldn't save the proxy."
            }
            setProxyError(message)
            throw SettingsError.invalid(message)
        } catch let error as SettingsError {
            if case .invalid(let message) = error { setProxyError(message) }
            throw error
        }
    }

    // MARK: Lista

    /// Primeiro `proxy.delete select(<id>)` arma a confirmação; `select(<id>:confirm)` apaga (e o segredo sai do Vault).
    func deleteProxy(argument: String) async throws -> String {
        let confirmed = argument.hasSuffix(":confirm")
        guard let id = UUID(uuidString: confirmed ? String(argument.dropLast(":confirm".count)) : argument), let profile = proxy(id: id) else {
            throw SettingsError.invalid("Proxy not found.")
        }
        guard confirmed else {
            proxyDeleteArmed = id
            return "confirm"
        }
        guard let service = proxyService else { throw SettingsError.noStore }
        try await service.delete(id: profile.id)
        proxyDeleteArmed = nil
        if proxyDraft?.id == id { proxyDraft = nil }
        await reloadProxies()
        return "deleted"
    }

    func setDefaultProxy(argument: String) async throws {
        guard let store else { throw SettingsError.noStore }
        if argument == "none" {
            try await store.setDefaultProxy(id: nil)
        } else {
            guard let id = UUID(uuidString: argument), proxy(id: id) != nil else { throw SettingsError.invalid("Proxy not found.") }
            try await store.setDefaultProxy(id: id)
        }
        await reloadProxies()
    }

    // MARK: Teste

    /// Testa o formulário aberto (com a senha digitada, ou a salva se o campo está vazio) ou o proxy salvo pedido.
    func testProxy(id: UUID?) async throws -> ProxyTestResult {
        let profile: ProxyProfile
        var secret: String?
        if let id, let saved = proxy(id: id) {
            profile = saved
            secret = try await savedSecret(of: saved)
        } else if let draft = proxyDraft {
            // Testar não precisa de nome (só host e porta); o nome é exigido ao salvar.
            var named = draft
            if named.name.trimmingCharacters(in: .whitespaces).isEmpty { named.name = "Test" }
            profile = try validatedProxy(named)
            if !draft.password.isEmpty {
                secret = draft.password
            } else if let base = draft.base {
                secret = try await savedSecret(of: base)
            }
        } else {
            throw SettingsError.invalid("Open a proxy to test it.")
        }
        proxyTest = .running
        let result = await proxyTester(profile, secret)
        proxyTest = .result(result)
        return result
    }

    private func savedSecret(of profile: ProxyProfile) async throws -> String? {
        guard let service = proxyService, let raw = profile.secretID, let secretID = UUID(uuidString: raw) else { return nil }
        return try? await service.vault.reveal(id: secretID).text
    }

    // MARK: Importar do CLI

    /// Sem confirmação arma o aviso inline; `confirm` lê SÓ `ZYTE_API_KEY` do `.env` do CLI antigo e cria/atualiza o proxy `zyte`.
    func importZyteFromCLI(confirm: Bool) async throws -> String {
        guard zyteImportAvailable else { throw SettingsError.invalid("No Zyte key found in the racky CLI settings.") }
        guard confirm else {
            zyteImportArmed = true
            return "confirm"
        }
        guard let service = proxyService else { throw SettingsError.noStore }
        do {
            let result = try await service.importZyteFromCLI(envFile: cliEnvFile, confirmed: true)
            zyteImportArmed = false
            await reloadProxies()
            return result.proxy.name
        } catch ProxyServiceError.cliEnvNotFound, ProxyServiceError.cliKeyNotFound {
            zyteImportArmed = false
            zyteImportAvailable = false
            throw SettingsError.invalid("No Zyte key found in the racky CLI settings.")
        }
    }

    func registerProxyActions(in registry: ActionRegistry) throws {
        func guarded(_ id: ActionID, _ body: () async throws -> String?) async throws -> String? {
            do { return try await body() } catch let error as SettingsError {
                switch error {
                case .invalid(let message): throw ActionError.failed(id, message: message)
                case .noStore: throw ActionError.failed(id, message: "The database isn't available.")
                }
            }
        }
        func value(_ arg: ActionArgument, _ id: ActionID) throws -> String {
            guard let v = arg.value else { throw ActionError.failed(id, message: "expected a value") }
            return v
        }
        try registry.register(.proxyAdd) { [unowned self] _ in
            newProxy()
            return "new"
        }
        try registry.register(.proxyEdit) { [unowned self] arg in
            let raw = try value(arg, .proxyEdit)
            guard let id = UUID(uuidString: raw) else { throw ActionError.failed(.proxyEdit, message: "expected a proxy id") }
            return try await guarded(.proxyEdit) {
                try editProxy(id: id)
                return proxyDraft?.id?.uuidString ?? "closed"
            }
        }
        try registry.register(.proxyCancel, enablement: { [unowned self] in proxyDraft == nil ? .disabled(reason: "No proxy is open.") : .enabled }) {
            [unowned self] _ in
            cancelProxyEdit()
            return nil
        }
        try registry.register(.proxySave, enablement: { [unowned self] in proxyDraft == nil ? .disabled(reason: "Open a proxy first.") : .enabled }) {
            [unowned self] _ in
            try await guarded(.proxySave) {
                try await saveProxy()
                return "saved"
            }
        }
        try registry.register(.proxyPreset, enablement: { [unowned self] in proxyDraft == nil ? .disabled(reason: "Open a proxy first.") : .enabled }) {
            [unowned self] arg in
            guard let raw = arg.value, let preset = ProxyPreset(rawValue: raw) else { throw ActionError.failed(.proxyPreset, message: "expected custom or zyte") }
            updateProxyDraft { $0.apply(preset: preset) }
            return raw
        }
        try registry.register(.proxyScheme, enablement: { [unowned self] in proxyDraft == nil ? .disabled(reason: "Open a proxy first.") : .enabled }) {
            [unowned self] arg in
            guard let raw = arg.value, let scheme = ProxyScheme(rawValue: raw) else { throw ActionError.failed(.proxyScheme, message: "expected http, https or socks5") }
            updateProxyDraft { $0.scheme = scheme }
            return raw
        }
        try registry.register(.proxyDelete) { [unowned self] arg in
            let raw = try value(arg, .proxyDelete)
            return try await guarded(.proxyDelete) { try await deleteProxy(argument: raw) }
        }
        try registry.register(.proxySetDefault) { [unowned self] arg in
            let raw = try value(arg, .proxySetDefault)
            return try await guarded(.proxySetDefault) {
                try await setDefaultProxy(argument: raw)
                return raw
            }
        }
        try registry.register(.proxyTest) { [unowned self] arg in
            try await guarded(.proxyTest) {
                let result = try await testProxy(id: arg.value.flatMap(UUID.init(uuidString:)))
                return result.summary
            }
        }
        try registry.register(.proxyImportFromCLI, enablement: { [unowned self] in
            zyteImportAvailable ? .enabled : .disabled(reason: "No Zyte key found in the racky CLI settings.")
        }) { [unowned self] arg in
            try await guarded(.proxyImportFromCLI) { try await importZyteFromCLI(confirm: arg.value == "confirm") }
        }
    }
}
