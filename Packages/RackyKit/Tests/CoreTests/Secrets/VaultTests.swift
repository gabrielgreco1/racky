import RackyPlatform
import RackyProtocol
import RackyStore
import Foundation
import Testing

@testable import RackyCore

/// Store real em pasta temporária + Keychain falso em memória (nunca toca o Keychain do usuário).
struct VaultHarness {
    let root: URL
    let store: RackyStore
    let backend: InMemoryMasterKeyBackend
    let vault: SecretVault
    let clock: ClockBox

    final class ClockBox: @unchecked Sendable { // SAFETY: só os testes leem/escrevem, sempre de um fluxo sequencial.
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    init(backend: InMemoryMasterKeyBackend = InMemoryMasterKeyBackend()) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("racky-vault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try await RackyStore.open(paths: StorePaths(root: root))
        self.backend = backend
        let box = ClockBox()
        clock = box
        vault = SecretVault(store: store, keyring: VaultKeyring(backend: backend), clock: { box.now })
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite struct VaultTests {
    @Test func createRevealRoundTripKeepsPlaintextOutOfTheDatabase() async throws {
        let h = try await VaultHarness(); defer { h.remove() }
        let value = "sk-live-VERY-SECRET-0123456789"
        let info = try await h.vault.create(NewSecret(name: "ZYTE_API_KEY", value: value, defaultEnvName: "ZYTE_API_KEY"))
        #expect(info.keyVersion == 1)
        let revealed = try await h.vault.reveal(id: info.id)
        #expect(revealed.text == value)

        let row = try #require(try await h.store.secret(id: info.id))
        #expect(row.ciphertext.count == value.utf8.count + VaultKeyring.tagLength)
        #expect(row.nonce.count == 12)
        #expect(row.ciphertext.range(of: Data(value.utf8)) == nil)

        // O arquivo SQLite (inclusive WAL) não contém o valor em claro.
        try await h.store.close()
        let files = try FileManager.default.contentsOfDirectory(at: h.store.paths.dbDirectory, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "sqlite" || file.lastPathComponent.hasSuffix("-wal") {
            #expect(try Data(contentsOf: file).range(of: Data(value.utf8)) == nil)
        }
    }

    @Test func masterKeyIsOneItemLoadedOncePerProcess() async throws {
        let h = try await VaultHarness(); defer { h.remove() }
        let a = try await h.vault.create(NewSecret(name: "A", value: "1"))
        let b = try await h.vault.create(NewSecret(name: "B", value: "2"))
        _ = try await h.vault.reveal(id: a.id)
        _ = try await h.vault.reveal(id: b.id)
        #expect(await h.backend.storeCount == 1, "um único item de chave mestra, nunca um por segredo")
        #expect(await h.backend.loadCount == 1, "Keychain lido uma vez por boot")
        let key = try #require(try await h.backend.loadMasterKey())
        #expect(key.count == 32)
    }

    @Test func secondProcessWithSameKeychainReadsExistingSecrets() async throws {
        let h = try await VaultHarness(); defer { h.remove() }
        let info = try await h.vault.create(NewSecret(name: "TOKEN", value: "abc"))
        let reopened = SecretVault(store: h.store, keyring: VaultKeyring(backend: h.backend))
        #expect(try await reopened.reveal(id: info.id).text == "abc")
    }

    @Test func missingMasterKeyNeverSilentlyCreatesANewOne() async throws {
        let h = try await VaultHarness(); defer { h.remove() }
        let info = try await h.vault.create(NewSecret(name: "TOKEN", value: "abc"))
        let lost = InMemoryMasterKeyBackend()
        let other = SecretVault(store: h.store, keyring: VaultKeyring(backend: lost))
        await #expect(throws: VaultError.masterKeyMissing) { try await other.reveal(id: info.id) }
        #expect(await lost.storeCount == 0)
    }

    @Test func wrongMasterKeyFailsAuthentication() async throws {
        let h = try await VaultHarness(); defer { h.remove() }
        let info = try await h.vault.create(NewSecret(name: "TOKEN", value: "abc"))
        let impostor = SecretVault(store: h.store, keyring: VaultKeyring(backend: InMemoryMasterKeyBackend(key: Data(repeating: 7, count: 32))))
        await #expect(throws: VaultError.decryptionFailed) { try await impostor.reveal(id: info.id) }
    }

    @Test func malformedMasterKeyIsRejected() async throws {
        let h = try await VaultHarness(backend: InMemoryMasterKeyBackend(key: Data(repeating: 1, count: 5))); defer { h.remove() }
        await #expect(throws: VaultError.masterKeyCorrupt) { try await h.vault.create(NewSecret(name: "A", value: "x")) }
    }

    @Test func ciphertextSwappedBetweenRowsFailsBecauseIDIsAuthenticated() async throws {
        let h = try await VaultHarness(); defer { h.remove() }
        let a = try await h.vault.create(NewSecret(name: "A", value: "alpha"))
        let b = try await h.vault.create(NewSecret(name: "B", value: "bravo"))
        let rowA = try #require(try await h.store.secret(id: a.id))
        try await h.store.updateSecretCipher(id: b.id, ciphertext: rowA.ciphertext, nonce: rowA.nonce, keyVersion: rowA.keyVersion, at: Date())
        await #expect(throws: VaultError.decryptionFailed) { try await h.vault.reveal(id: b.id) }
    }

    @Test func namesAreValidatedAndUnique() async throws {
        let h = try await VaultHarness(); defer { h.remove() }
        try await h.vault.create(NewSecret(name: "A", value: "1"))
        await #expect(throws: SecretError.duplicateName) { try await h.vault.create(NewSecret(name: "A", value: "2")) }
        await #expect(throws: SecretError.invalidName) { try await h.vault.create(NewSecret(name: "  ", value: "2")) }
        await #expect(throws: SecretError.invalidEnvName("1BAD")) { try await h.vault.create(NewSecret(name: "B", value: "2", defaultEnvName: "1BAD")) }
        await #expect(throws: SecretError.valueTooLarge) {
            try await h.vault.create(NewSecret(name: "C", value: String(repeating: "x", count: SecretVault.maxValueBytes + 1)))
        }
    }

    @Test func rotateValueReplacesTheSecretAndStampsUpdatedAt() async throws {
        let h = try await VaultHarness(); defer { h.remove() }
        let info = try await h.vault.create(NewSecret(name: "TOKEN", value: "old"))
        let before = try #require(try await h.store.secret(id: info.id))
        h.clock.now = h.clock.now.addingTimeInterval(60)
        try await h.vault.rotate(id: info.id, newValue: "new")
        let after = try #require(try await h.store.secret(id: info.id))
        #expect(try await h.vault.reveal(id: info.id).text == "new")
        #expect(after.ciphertext != before.ciphertext && after.nonce != before.nonce)
        #expect(after.updatedAt > before.updatedAt)
    }

    @Test func rotateKeyVersionReencryptsEverythingAtomically() async throws {
        let h = try await VaultHarness(); defer { h.remove() }
        let a = try await h.vault.create(NewSecret(name: "A", value: "alpha"))
        let b = try await h.vault.create(NewSecret(name: "B", value: "bravo"))
        let old = try #require(try await h.store.secret(id: a.id))
        #expect(try await h.vault.rotateKeyVersion() == 2)
        let new = try #require(try await h.store.secret(id: a.id))
        #expect(new.keyVersion == 2 && new.ciphertext != old.ciphertext)
        #expect(try await h.vault.reveal(id: a.id).text == "alpha")
        #expect(try await h.vault.reveal(id: b.id).text == "bravo")
        let c = try await h.vault.create(NewSecret(name: "C", value: "charlie"))
        #expect(c.keyVersion == 2, "novos segredos usam a versão atual")
        #expect(await h.backend.storeCount == 1, "a rotação de versão não troca o item do Keychain")
        #expect(try await h.vault.rotateKeyVersion() == 3)
        #expect(try await h.vault.reveal(id: c.id).text == "charlie")
    }

    @Test func rotateKeyVersionLeavesRowsUntouchedWhenOneCannotBeDecrypted() async throws {
        let h = try await VaultHarness(); defer { h.remove() }
        let a = try await h.vault.create(NewSecret(name: "A", value: "alpha"))
        let b = try await h.vault.create(NewSecret(name: "B", value: "bravo"))
        let rowB = try #require(try await h.store.secret(id: b.id))
        var broken = rowB.ciphertext; broken[0] ^= 0xFF
        try await h.store.updateSecretCipher(id: b.id, ciphertext: broken, nonce: rowB.nonce, keyVersion: 1, at: Date())
        let before = try #require(try await h.store.secret(id: a.id))
        await #expect(throws: VaultError.decryptionFailed) { try await h.vault.rotateKeyVersion() }
        let after = try #require(try await h.store.secret(id: a.id))
        #expect(after.ciphertext == before.ciphertext && after.keyVersion == 1)
    }

    @Test func deleteRemovesSecretAndItsBindings() async throws {
        let h = try await VaultHarness(); defer { h.remove() }
        let info = try await h.vault.create(NewSecret(name: "TOKEN", value: "abc"))
        try await h.vault.bind(secretID: info.id, targetKind: "profile", targetID: "p1")
        try await h.vault.delete(id: info.id)
        #expect(try await h.vault.list().isEmpty)
        #expect(try await h.vault.bindings(targetKind: "profile", targetID: "p1").isEmpty)
        await #expect(throws: SecretError.notFound) { try await h.vault.reveal(id: info.id) }
    }

    @Test func expiredSecretsCannotBeRevealed() async throws {
        let h = try await VaultHarness(); defer { h.remove() }
        let info = try await h.vault.create(NewSecret(name: "TOKEN", value: "abc", expiresAt: h.clock.now.addingTimeInterval(60)))
        #expect(try await h.vault.reveal(id: info.id).text == "abc")
        h.clock.now = h.clock.now.addingTimeInterval(61)
        await #expect(throws: SecretError.expired) { try await h.vault.reveal(id: info.id) }
    }

    @Test func revealTouchesLastUsedAt() async throws {
        let h = try await VaultHarness(); defer { h.remove() }
        let info = try await h.vault.create(NewSecret(name: "TOKEN", value: "abc"))
        #expect(info.lastUsedAt == nil)
        h.clock.now = h.clock.now.addingTimeInterval(5)
        _ = try await h.vault.reveal(id: info.id)
        #expect(try await h.vault.info(id: info.id).lastUsedAt != nil)
    }

    @Test func boxTokenIsDerivedFromTheMasterKeyAndGeneration() async throws {
        let h = try await VaultHarness(); defer { h.remove() }
        let ring = VaultKeyring(backend: h.backend)
        let t1 = try await ring.boxToken(computerID: "c1", generation: 0)
        #expect(t1.count == 64)
        #expect(try await ring.boxToken(computerID: "c1", generation: 0) == t1)
        #expect(try await ring.boxToken(computerID: "c1", generation: 1) != t1)
        #expect(try await ring.boxToken(computerID: "c2", generation: 0) != t1)
    }

    @Test func secretValueNeverPrintsItself() {
        let v = SecretValue("hunter2-hunter2")
        #expect(!"\(v)".contains("hunter2") && !String(reflecting: v).contains("hunter2") && !String(describing: v).contains("hunter2"))
        var dump = ""
        Swift.dump(v, to: &dump)
        #expect(!dump.contains("hunter2"))
    }
}

@Suite struct SecretInjectionTests {
    @Test func injectsOnlySelectedSecretsIntoTheTerminalEnvironmentWithoutArgv() async throws {
        let h = try await VaultHarness(); defer { h.remove() }
        let chosen = try await h.vault.create(NewSecret(name: "OPENAI", value: "sk-chosen-123", defaultEnvName: "OPENAI_API_KEY"))
        _ = try await h.vault.create(NewSecret(name: "OTHER", value: "sk-other-456", defaultEnvName: "OTHER_KEY"))

        let injection = try await h.vault.injection(for: [SecretSelection(secretID: chosen.id)])
        #expect(injection.environment == ["OPENAI_API_KEY": "sk-chosen-123"])
        #expect(!"\(injection)".contains("sk-chosen") && !String(reflecting: injection).contains("sk-chosen"))

        let base = try LaunchSamples.plan(LaunchSpec(provider: .claude))
        let plan = base.injectingSecrets(injection)
        #expect(plan.environment["OPENAI_API_KEY"] == "sk-chosen-123")
        #expect(plan.environment["OTHER_KEY"] == nil, "só os segredos escolhidos")
        #expect(plan.envKeys.contains("OPENAI_API_KEY"))
        #expect(plan.argv == base.argv, "segredo nunca vai em argv")
        #expect(!plan.flattenedArgv.joined(separator: " ").contains("sk-chosen"))
        #expect(plan.files.allSatisfy { !String(decoding: $0.contents, as: UTF8.self).contains("sk-chosen") }, "nem em arquivo de lançamento")
        #expect(plan.envKeys == plan.envKeys.sorted() && Set(plan.envKeys) == Set(plan.environment.keys))
        // Nada do plano base mudou além do novo nome.
        #expect(Set(plan.envKeys).subtracting(base.envKeys) == ["OPENAI_API_KEY"])
        // Última linha de defesa: o valor não aparece em nenhum campo "só nomes".
        #expect(!plan.envKeys.joined().contains("sk-chosen"))
    }

    @Test func skipsSidecarOnlyReservedExpiredAndInvalidNamesWithoutLeaking() async throws {
        let h = try await VaultHarness(); defer { h.remove() }
        let proxy = try await h.vault.create(NewSecret(name: "PROXY_PASS", value: "p-1", kind: .proxyCredential, delivery: .sidecarOnly))
        let reserved = try await h.vault.create(NewSecret(name: "R", value: "r-1", defaultEnvName: "RACKY_TOKEN"))
        let expired = try await h.vault.create(NewSecret(name: "E", value: "e-1", defaultEnvName: "E_KEY", expiresAt: h.clock.now.addingTimeInterval(10)))
        let ok = try await h.vault.create(NewSecret(name: "OK", value: "ok-1", defaultEnvName: "OK_KEY"))
        h.clock.now = h.clock.now.addingTimeInterval(20)

        let injection = try await h.vault.injection(for: [
            SecretSelection(secretID: proxy.id, envName: "PROXY_PASS"), SecretSelection(secretID: reserved.id),
            SecretSelection(secretID: expired.id), SecretSelection(secretID: ok.id),
            SecretSelection(secretID: ok.id, envName: "bad name"), SecretSelection(secretID: UUID()),
        ])
        #expect(injection.environment == ["OK_KEY": "ok-1"])
        let reasons = Dictionary(uniqueKeysWithValues: injection.skipped.map { ($0.envName, $0.reason) })
        #expect(reasons["PROXY_PASS"] == .notEnvDelivery)
        #expect(reasons["RACKY_TOKEN"] == .reserved)
        #expect(reasons["E_KEY"] == .expired)
        #expect(reasons["bad name"] == .invalidName)
        #expect(injection.skipped.contains { $0.reason == .missing })
    }

    @Test func bindingsOfProfileAndSessionResolveWithSessionWinning() async throws {
        let h = try await VaultHarness(); defer { h.remove() }
        let profileKey = try await h.vault.create(NewSecret(name: "P", value: "from-profile"))
        let sessionKey = try await h.vault.create(NewSecret(name: "S", value: "from-session"))
        let only = try await h.vault.create(NewSecret(name: "O", value: "only-profile"))
        let profileID = UUID(), sessionID = UUID()
        try await h.vault.bind(secretID: profileKey.id, targetKind: "profile", targetID: profileID.uuidString, envName: "API_KEY")
        try await h.vault.bind(secretID: only.id, targetKind: "profile", targetID: profileID.uuidString, envName: "ONLY")
        try await h.vault.bind(secretID: sessionKey.id, targetKind: "session", targetID: sessionID.uuidString, envName: "API_KEY")
        let injection = try await h.vault.injection(profileID: profileID, sessionID: sessionID)
        #expect(injection.environment == ["API_KEY": "from-session", "ONLY": "only-profile"])

        let none = try await h.vault.injection(profileID: nil, sessionID: nil)
        #expect(none.environment.isEmpty, "sem opt-in explícito nada é injetado")
    }

    @Test func eachSecretOnlyBindsUnderAValidEnvName() async throws {
        let h = try await VaultHarness(); defer { h.remove() }
        let info = try await h.vault.create(NewSecret(name: "has space", value: "v"))
        await #expect(throws: SecretError.invalidEnvName("has space")) {
            try await h.vault.bind(secretID: info.id, targetKind: "profile", targetID: "p")
        }
        await #expect(throws: SecretError.notFound) { try await h.vault.bind(secretID: UUID(), targetKind: "profile", targetID: "p") }
    }
}

@Suite struct SecretFileTests {
    @Test func boxFileIsReadOnly0400AndOnlyForNonEnvDelivery() async throws {
        let h = try await VaultHarness(); defer { h.remove() }
        let box = try await h.vault.create(NewSecret(name: "BOX", value: "file-secret", kind: .proxyCredential, delivery: .boxFileReadOnly))
        let env = try await h.vault.create(NewSecret(name: "ENV", value: "env-secret"))
        let target = h.root.appendingPathComponent("boxes/c1/proxy-credential")

        try await h.vault.writeReadOnlyFile(id: box.id, to: target)
        let attrs = try FileManager.default.attributesOfItem(atPath: target.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o400)
        #expect(try String(contentsOf: target, encoding: .utf8) == "file-secret")
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: target.deletingLastPathComponent().path)
        #expect((dirAttrs[.posixPermissions] as? Int) == 0o700)

        // Reescrever (rotação) substitui o arquivo, mesmo read-only.
        try await h.vault.rotate(id: box.id, newValue: "rotated")
        try await h.vault.writeReadOnlyFile(id: box.id, to: target)
        #expect(try String(contentsOf: target, encoding: .utf8) == "rotated")
        #expect(((try FileManager.default.attributesOfItem(atPath: target.path))[.posixPermissions] as? Int) == 0o400)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)
        #expect(leftovers == ["proxy-credential"], "sem temporários esquecidos")

        await #expect(throws: SecretError.wrongDelivery(.profileEnv)) {
            try await h.vault.writeReadOnlyFile(id: env.id, to: h.root.appendingPathComponent("never"))
        }
        #expect(!FileManager.default.fileExists(atPath: h.root.appendingPathComponent("never").path))
    }
}
