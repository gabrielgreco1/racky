import RackyPlatform
import RackyStore
import Foundation

// Vault de segredos do usuário (08 AR-510..513; 01 §5.13). A chave mestra mora num único item do Keychain
// (`VaultKeyring`, backend injetável); os valores ficam cifrados com AES-GCM em `secret.ciphertext`.
// Nenhum valor passa por log, descrição, evento ou erro.

public enum SecretKind: String, Sendable, CaseIterable {
    case proxyCredential, envVar, claudeSetupToken, codexBoxIdentity, githubPAT, boxMasterKey
}
public enum SecretScope: String, Sendable { case global, project }
/// `sidecarOnly`: nunca chega ao terminal do agente. `profileEnv`: injetável no env por opt-in.
/// `boxFileReadOnly`: arquivo `0400` para a box (v1.1).
public enum SecretDelivery: String, Sendable { case sidecarOnly, profileEnv, boxFileReadOnly }

public enum SecretError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidName
    case invalidEnvName(String)
    case valueTooLarge
    case duplicateName
    case notFound
    case expired
    case wrongDelivery(SecretDelivery)

    public var description: String {
        switch self {
        case .invalidName: "A secret needs a name of 1 to 128 characters"
        case .invalidEnvName: "Use a valid environment variable name"
        case .valueTooLarge: "A secret value is limited to 64 KiB"
        case .duplicateName: "A secret with this name already exists"
        case .notFound: "The secret does not exist"
        case .expired: "The secret has expired"
        case .wrongDelivery(let d): "This secret is delivered as \(d.rawValue) and cannot be used this way"
        }
    }
}

/// Valor decifrado. Nunca aparece em `print`, interpolação ou dump.
public struct SecretValue: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let storage: String
    public init(_ value: String) { storage = value }
    public var text: String { storage }
    public var description: String { "<redacted secret>" }
    public var debugDescription: String { "<redacted secret>" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Metadados públicos de um segredo: tudo menos o valor.
public struct SecretInfo: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var defaultEnvName: String?
    public var kind: String
    public var scope: String
    public var delivery: String
    public var note: String?
    public var keyVersion: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var lastUsedAt: Date?
    public var expiresAt: Date?
    public var importedFrom: String?

    init(_ s: StoredSecret) {
        id = s.id; name = s.name; defaultEnvName = s.defaultEnvName; kind = s.kind; scope = s.scope
        delivery = s.delivery; note = s.note; keyVersion = s.keyVersion; createdAt = s.createdAt
        updatedAt = s.updatedAt; lastUsedAt = s.lastUsedAt; expiresAt = s.expiresAt; importedFrom = s.importedFrom
    }
}

public struct NewSecret: Sendable {
    public var name: String
    public var value: String
    public var defaultEnvName: String?
    public var kind: SecretKind
    public var scope: SecretScope
    public var delivery: SecretDelivery
    public var note: String?
    public var expiresAt: Date?
    public var importedFrom: String?
    public init(name: String, value: String, defaultEnvName: String? = nil, kind: SecretKind = .envVar,
                scope: SecretScope = .global, delivery: SecretDelivery = .profileEnv, note: String? = nil,
                expiresAt: Date? = nil, importedFrom: String? = nil) {
        self.name = name; self.value = value; self.defaultEnvName = defaultEnvName; self.kind = kind
        self.scope = scope; self.delivery = delivery; self.note = note; self.expiresAt = expiresAt
        self.importedFrom = importedFrom
    }
}

public actor SecretVault {
    public static let maxValueBytes = 64 * 1024
    static let keyVersionSetting = "vault.key_version"

    private let store: RackyStore
    private let keyring: VaultKeyring
    private let clock: @Sendable () -> Date

    public init(store: RackyStore, keyring: VaultKeyring, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.keyring = keyring; self.clock = clock
    }

    static func isValidEnvName(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
    }

    private func currentKeyVersion() async throws -> Int {
        max(1, try await store.setting(Self.keyVersionSetting, as: Int.self) ?? 1)
    }

    // MARK: CRUD

    @discardableResult
    public func create(_ new: NewSecret) async throws -> SecretInfo {
        let name = new.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...128).contains(name.count) else { throw SecretError.invalidName }
        if let env = new.defaultEnvName, !Self.isValidEnvName(env) { throw SecretError.invalidEnvName(env) }
        let plaintext = Data(new.value.utf8)
        guard plaintext.count <= Self.maxValueBytes else { throw SecretError.valueTooLarge }
        if try await store.secret(named: name) != nil { throw SecretError.duplicateName }
        let id = UUID(), version = try await currentKeyVersion(), now = clock()
        let sealed = try await keyring.seal(plaintext, secretID: id.uuidString, version: version)
        let row = StoredSecret(
            id: id, name: name, defaultEnvName: new.defaultEnvName, ciphertext: sealed.ciphertext, nonce: sealed.nonce,
            keyVersion: version, note: new.note, kind: new.kind.rawValue, scope: new.scope.rawValue,
            delivery: new.delivery.rawValue, createdAt: now, updatedAt: now, expiresAt: new.expiresAt,
            importedFrom: new.importedFrom)
        do { try await store.insertSecret(row) } catch StoreError.invalidModel { throw SecretError.duplicateName }
        return SecretInfo(row)
    }

    public func list() async throws -> [SecretInfo] { try await store.secrets().map(SecretInfo.init) }

    public func info(id: UUID) async throws -> SecretInfo {
        guard let s = try await store.secret(id: id) else { throw SecretError.notFound }
        return SecretInfo(s)
    }

    /// Decifra o valor e marca `last_used_at`. Segredo expirado não é lido.
    public func reveal(id: UUID) async throws -> SecretValue {
        let value = try await decrypt(id: id, enforceExpiry: true)
        try await store.touchSecrets(ids: [id], at: clock())
        return value
    }

    private func decrypt(id: UUID, enforceExpiry: Bool) async throws -> SecretValue {
        guard let s = try await store.secret(id: id) else { throw SecretError.notFound }
        if enforceExpiry, let exp = s.expiresAt, exp <= clock() { throw SecretError.expired }
        let data = try await keyring.open(.init(ciphertext: s.ciphertext, nonce: s.nonce), secretID: id.uuidString, version: s.keyVersion)
        return SecretValue(String(decoding: data, as: UTF8.self))
    }

    /// Troca o valor do segredo (rotação de valor), na versão de chave atual.
    public func rotate(id: UUID, newValue: String) async throws {
        let plaintext = Data(newValue.utf8)
        guard plaintext.count <= Self.maxValueBytes else { throw SecretError.valueTooLarge }
        guard try await store.secret(id: id) != nil else { throw SecretError.notFound }
        let version = try await currentKeyVersion()
        let sealed = try await keyring.seal(plaintext, secretID: id.uuidString, version: version)
        try await store.updateSecretCipher(id: id, ciphertext: sealed.ciphertext, nonce: sealed.nonce, keyVersion: version, at: clock())
    }

    /// Rotação de chave (AR-511): recifra todos os segredos numa nova `key_version` (derivação HKDF nova a partir da mesma
    /// mestra), numa única transação. Falha em qualquer decifração aborta sem alterar nada.
    @discardableResult
    public func rotateKeyVersion() async throws -> Int {
        let next = try await currentKeyVersion() + 1
        var items: [ReencryptedSecret] = []
        for s in try await store.secrets() {
            let plain = try await keyring.open(.init(ciphertext: s.ciphertext, nonce: s.nonce), secretID: s.id.uuidString, version: s.keyVersion)
            let sealed = try await keyring.seal(plain, secretID: s.id.uuidString, version: next)
            items.append(ReencryptedSecret(id: s.id, ciphertext: sealed.ciphertext, nonce: sealed.nonce, keyVersion: next))
        }
        try await store.replaceSecretCiphers(items)
        try await store.setSetting(Self.keyVersionSetting, next)
        return next
    }

    public func updateMetadata(id: UUID, defaultEnvName: String?, note: String?, expiresAt: Date?) async throws {
        if let env = defaultEnvName, !Self.isValidEnvName(env) { throw SecretError.invalidEnvName(env) }
        guard try await store.secret(id: id) != nil else { throw SecretError.notFound }
        try await store.updateSecretMetadata(id: id, defaultEnvName: defaultEnvName, note: note, expiresAt: expiresAt, at: clock())
    }

    public func delete(id: UUID) async throws { try await store.deleteSecret(id: id) }

    // MARK: Bindings (opt-in explícito, AR-513)

    public func bind(secretID: UUID, targetKind: String, targetID: String, envName: String? = nil) async throws {
        guard let s = try await store.secret(id: secretID) else { throw SecretError.notFound }
        let env = envName ?? s.defaultEnvName ?? s.name
        guard Self.isValidEnvName(env) else { throw SecretError.invalidEnvName(env) }
        try await store.addSecretBinding(SecretBinding(secretID: secretID, targetKind: targetKind, targetID: targetID, envName: env))
    }

    public func unbind(_ binding: SecretBinding) async throws { try await store.removeSecretBinding(binding) }

    public func bindings(targetKind: String, targetID: String) async throws -> [SecretBinding] {
        try await store.secretBindings(targetKind: targetKind, targetID: targetID)
    }

    // MARK: Injeção no env do terminal

    /// Resolve as seleções explícitas em variáveis de ambiente. Só segredos `profileEnv`, não expirados e com nome
    /// de variável válido e não reservado entram; o resto vira `skipped` (só nome/motivo, nunca valor).
    public func injection(for selections: [SecretSelection]) async throws -> SecretInjection {
        var environment: [String: String] = [:]
        var skipped: [SecretInjection.Skipped] = []
        var used: [UUID] = []
        for sel in selections {
            guard let s = try await store.secret(id: sel.secretID) else {
                skipped.append(.init(envName: sel.envName ?? "?", reason: .missing)); continue
            }
            let env = sel.envName ?? s.defaultEnvName ?? s.name
            guard Self.isValidEnvName(env) else { skipped.append(.init(envName: env, reason: .invalidName)); continue }
            if env.hasPrefix("RACKY_") { skipped.append(.init(envName: env, reason: .reserved)); continue }
            guard s.delivery == SecretDelivery.profileEnv.rawValue else { skipped.append(.init(envName: env, reason: .notEnvDelivery)); continue }
            if let exp = s.expiresAt, exp <= clock() { skipped.append(.init(envName: env, reason: .expired)); continue }
            let data = try await keyring.open(.init(ciphertext: s.ciphertext, nonce: s.nonce), secretID: s.id.uuidString, version: s.keyVersion)
            environment[env] = String(decoding: data, as: UTF8.self)
            used.append(s.id)
        }
        if !used.isEmpty { try await store.touchSecrets(ids: used, at: clock()) }
        return SecretInjection(environment: environment, skipped: skipped)
    }

    /// Bindings de perfil e de sessão do lançamento; em conflito de nome, o da sessão vence.
    public func injection(profileID: UUID?, sessionID: UUID?) async throws -> SecretInjection {
        var selections: [String: SecretSelection] = [:]
        if let profileID {
            for b in try await store.secretBindings(targetKind: "profile", targetID: profileID.uuidString) {
                selections[b.envName] = SecretSelection(secretID: b.secretID, envName: b.envName)
            }
        }
        if let sessionID {
            for b in try await store.secretBindings(targetKind: "session", targetID: sessionID.uuidString) {
                selections[b.envName] = SecretSelection(secretID: b.secretID, envName: b.envName)
            }
        }
        return try await injection(for: selections.keys.sorted().compactMap { selections[$0] })
    }

    // MARK: Arquivo read-only para boxes (AR-512)

    /// Grava o valor num arquivo `0400` (criação exclusiva + rename atômico). Só para `sidecarOnly` e `boxFileReadOnly`:
    /// um segredo `profileEnv` não vira arquivo de box.
    public func writeReadOnlyFile(id: UUID, to url: URL) async throws {
        guard let s = try await store.secret(id: id) else { throw SecretError.notFound }
        let delivery = SecretDelivery(rawValue: s.delivery) ?? .profileEnv
        guard delivery != .profileEnv else { throw SecretError.wrongDelivery(delivery) }
        let value = try await reveal(id: id)
        try Self.writeSecretFile(Data(value.text.utf8), to: url)
    }

    static func writeSecretFile(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o400)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        var failed = false
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n <= 0 { failed = true; break }
                offset += n
            }
        }
        close(fd)
        if failed { try? fm.removeItem(at: temp); throw CocoaError(.fileWriteUnknown) }
        guard rename(temp.path, url.path) == 0 else {
            try? fm.removeItem(at: temp)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

public struct SecretSelection: Sendable, Equatable {
    public var secretID: UUID
    public var envName: String?
    public init(secretID: UUID, envName: String? = nil) { self.secretID = secretID; self.envName = envName }
}

/// Resultado da resolução: variáveis a injetar no PTY. A descrição mostra só os nomes.
public struct SecretInjection: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public struct Skipped: Sendable, Equatable {
        public enum Reason: String, Sendable { case missing, invalidName, reserved, notEnvDelivery, expired }
        public var envName: String
        public var reason: Reason
    }
    /// Valores sensíveis: entregues só ao daemon, na requisição de `create` (AR-513).
    public let environment: [String: String]
    public let skipped: [Skipped]
    public var names: [String] { environment.keys.sorted() }

    public init(environment: [String: String], skipped: [Skipped] = []) {
        self.environment = environment; self.skipped = skipped
    }
    public var description: String { "SecretInjection(env: \(names.joined(separator: ", ")), skipped: \(skipped.count))" }
    public var debugDescription: String { description }
}

extension LaunchPlan {
    /// Aplica o env de segredos (opt-in) ao plano. Segredo vence o env do perfil; só os nomes vão para `envKeys`;
    /// nada vai para argv.
    public func injectingSecrets(_ injection: SecretInjection) -> LaunchPlan {
        var plan = self
        for (name, value) in injection.environment { plan.environment[name] = value }
        plan.envKeys = Array(Set(plan.envKeys).union(injection.names)).sorted()
        return plan
    }
}
