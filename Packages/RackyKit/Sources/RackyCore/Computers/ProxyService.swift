import RackyDocker
import RackyProtocol
import RackyStore
import Foundation

public enum ProxyServiceError: Error, Sendable, Equatable {
    case nameInUse(String)
    case secretMissing(proxy: String)
    case importNotConfirmed
    case cliEnvNotFound(String)
    case cliKeyNotFound
    case unknownProxy(String)
}

/// Resultado de `importZyteFromCLI`. Nunca carrega o valor da chave.
public struct ZyteImportResult: Sendable, Equatable {
    public var proxy: ProxyProfile
    /// `true` se já existia um proxy de mesmo nome e ele foi atualizado (a chave é regravada, o resto é preservado).
    public var updatedExisting: Bool
}

/// Proxies configurados pelo usuário (T3-02, 07 §2.6, P13): cadastro, segredo no Vault (T2-10), montagem
/// da config do egress e o importador `Import from racky CLI…`. Sem teto de orçamento em nenhum ponto.
public struct ProxyService: Sendable {
    public let store: RackyStore
    public let vault: SecretVault

    public init(store: RackyStore, vault: SecretVault) {
        self.store = store
        self.vault = vault
    }

    /// Cria ou atualiza um proxy. `secret` (senha, ou a chave no preset Zyte) vai para o Vault, nunca para o SQLite.
    /// `secret == nil` mantém o segredo atual.
    @discardableResult
    public func save(_ profile: ProxyProfile, secret: String? = nil) async throws -> ProxyProfile {
        var profile = profile
        if let other = try await store.proxy(named: profile.name), other.id != profile.id { throw ProxyServiceError.nameInUse(profile.name) }
        if let secret, !secret.isEmpty {
            if let existing = profile.secretID.flatMap(UUID.init(uuidString:)), (try? await vault.info(id: existing)) != nil {
                try await vault.rotate(id: existing, newValue: secret)
            } else {
                // Vault (T2-10): cifrado, `sidecarOnly` = nunca chega ao terminal do agente; vai só para o egress, por arquivo 0400.
                let created = try await vault.create(NewSecret(
                    name: "proxy:\(profile.name)", value: secret, kind: .proxyCredential, scope: .global, delivery: .sidecarOnly,
                    note: "Proxy credential for \(profile.name)"))
                profile.secretID = created.id.uuidString
            }
            profile.secretStorage = .vault
        }
        profile.updatedAt = Date()
        try await store.save(profile)
        return profile
    }

    public func delete(id: UUID) async throws {
        if let profile = try await store.proxy(id: id), let secretID = profile.secretID.flatMap(UUID.init(uuidString:)) {
            try? await vault.delete(id: secretID)
        }
        try await store.deleteProxy(id: id)
    }

    /// Config do egress para o proxy escolhido (`nil` = `direct`). O segredo é lido aqui e só vai para o arquivo 0400 do egress.
    public func egressConfig(for proxyID: UUID?, allowCIDRs: [String] = [], allowHosts: [String] = []) async throws -> (config: EgressConfigFile, caPEM: String?) {
        guard let proxyID, let profile = try await store.proxy(id: proxyID) else {
            return (EgressConfigFile.make(profile: nil, secret: nil, allowCIDRs: allowCIDRs, allowHosts: allowHosts), nil)
        }
        var secret: String?
        if let secretID = profile.secretID {
            guard let id = UUID(uuidString: secretID), let value = try? await vault.reveal(id: id) else {
                throw ProxyServiceError.secretMissing(proxy: profile.name)
            }
            secret = value.text
        }
        return (EgressConfigFile.make(profile: profile, secret: secret, allowCIDRs: allowCIDRs, allowHosts: allowHosts), profile.caPEM)
    }

    // MARK: Import from racky CLI…

    /// Caminho padrão do `.env` do CLI: `~/.racky/.env`.
    public static func defaultCLIEnvFile(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".racky/.env")
    }

    /// `Import from racky CLI…` (08 AR-343, 07 CS-160): lê SÓ `ZYTE_API_KEY` (e os preços informativos) do `.env` do CLI antigo,
    /// somente leitura, e cria/atualiza o proxy com preset `zyte`. Exige confirmação explícita. Nunca loga a chave. Os demais
    /// valores do arquivo (token do Claude, `ZYTE_BUDGET_USD`...) são ignorados: não há teto de orçamento (P13).
    @discardableResult
    public func importZyteFromCLI(envFile: URL = ProxyService.defaultCLIEnvFile(), confirmed: Bool, name: String = "zyte") async throws -> ZyteImportResult {
        guard confirmed else { throw ProxyServiceError.importNotConfirmed }
        guard FileManager.default.isReadableFile(atPath: envFile.path) else { throw ProxyServiceError.cliEnvNotFound(envFile.lastPathComponent) }
        let wanted: Set<String> = ["ZYTE_API_KEY", "ZYTE_USD_PER_REQUEST", "ZYTE_USD_PER_RENDER"]
        let values = DotEnv.read(try Data(contentsOf: envFile), keys: wanted)
        guard let key = values["ZYTE_API_KEY"], !key.isEmpty else { throw ProxyServiceError.cliKeyNotFound }

        let existing = try await store.proxy(named: name)
        var profile = existing ?? ProxyProfile.zytePreset(name: name, secretID: nil)
        profile.preset = .zyte
        if existing == nil {
            profile.pricePerRequestMicros = DotEnv.micros(values["ZYTE_USD_PER_REQUEST"])
            profile.pricePerRenderMicros = DotEnv.micros(values["ZYTE_USD_PER_RENDER"])
        }
        let saved = try await save(profile, secret: key)
        return ZyteImportResult(proxy: saved, updatedExisting: existing != nil)
    }
}

/// Leitor mínimo de `.env` que devolve SÓ as chaves pedidas (o resto do arquivo nunca sai desta função).
enum DotEnv {
    static func read(_ data: Data, keys: Set<String>) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            guard keys.contains(key) else { continue }
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if let quote = value.first, quote == "\"" || quote == "'", let close = value.dropFirst().firstIndex(of: quote) {
                value = String(value[value.index(after: value.startIndex)..<close])  // o que vem depois da aspa de fechamento é comentário
            } else if let hash = value.range(of: " #") {  // comentário no fim da linha (só sem aspas)
                value = String(value[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            result[key] = value
        }
        return result
    }

    /// `0.00013` (USD) -> `130` (micro-USD). Inválido/negativo -> `nil`.
    static func micros(_ usd: String?) -> Int64? {
        guard let usd, let value = Decimal(string: usd), value >= 0 else { return nil }
        let micros = NSDecimalNumber(decimal: value * 1_000_000).rounding(accordingToBehavior: nil)
        return micros.int64Value
    }
}
