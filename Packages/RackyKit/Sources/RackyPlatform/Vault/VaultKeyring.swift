import CryptoKit
import Foundation
import Security

/// Chave mestra em memória + criptografia AES-GCM dos segredos (08 AR-511).
/// - A chave mestra é lida do backend uma vez por processo (AR-511) e fica só em memória.
/// - A chave de cada versão é `HKDF-SHA256(master, info: "secret-v<versão>")`; a versão 1 usa `info="secret-v1"`.
/// - O id do segredo e a versão entram como dado autenticado (AAD): trocar o ciphertext entre linhas falha.
public actor VaultKeyring {
    public static let keyLength = 32
    public static let tagLength = 16

    private let backend: any MasterKeyBackend
    private var cached: SymmetricKey?

    public init(backend: any MasterKeyBackend) { self.backend = backend }

    /// Carrega a chave mestra. `createIfMissing` só vale ao gravar o primeiro segredo; ao ler, a ausência é erro
    /// (criar outra chave tornaria os segredos existentes ilegíveis em silêncio).
    private func master(createIfMissing: Bool) async throws -> SymmetricKey {
        if let cached { return cached }
        if let data = try await backend.loadMasterKey() {
            guard data.count == Self.keyLength else { throw VaultError.masterKeyCorrupt }
            let key = SymmetricKey(data: data)
            cached = key
            return key
        }
        guard createIfMissing else { throw VaultError.masterKeyMissing }
        var bytes = [UInt8](repeating: 0, count: Self.keyLength)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw VaultError.masterKeyCorrupt
        }
        let data = Data(bytes)
        try await backend.storeMasterKey(data)
        let key = SymmetricKey(data: data)
        cached = key
        return key
    }

    /// Existe uma chave mestra no backend (sem criar)?
    public func hasMasterKey() async throws -> Bool {
        if cached != nil { return true }
        return try await backend.loadMasterKey() != nil
    }

    static func derive(_ master: SymmetricKey, version: Int) throws -> SymmetricKey {
        guard version >= 1 else { throw VaultError.invalidKeyVersion(version) }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: master, salt: Data(), info: Data("secret-v\(version)".utf8), outputByteCount: keyLength)
    }

    static func aad(secretID: String, version: Int) -> Data { Data("\(secretID)|v\(version)".utf8) }

    public struct Sealed: Sendable, Equatable {
        /// Dados cifrados seguidos da tag GCM de 16 bytes.
        public let ciphertext: Data
        public let nonce: Data
        public init(ciphertext: Data, nonce: Data) { self.ciphertext = ciphertext; self.nonce = nonce }
    }

    public func seal(_ plaintext: Data, secretID: String, version: Int) async throws -> Sealed {
        let key = try Self.derive(try await master(createIfMissing: true), version: version)
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: Self.aad(secretID: secretID, version: version))
        return Sealed(ciphertext: box.ciphertext + box.tag, nonce: Data(box.nonce))
    }

    public func open(_ sealed: Sealed, secretID: String, version: Int) async throws -> Data {
        let key = try Self.derive(try await master(createIfMissing: false), version: version)
        guard sealed.ciphertext.count >= Self.tagLength else { throw VaultError.decryptionFailed }
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: sealed.nonce),
                ciphertext: sealed.ciphertext.dropLast(Self.tagLength),
                tag: sealed.ciphertext.suffix(Self.tagLength))
            return try AES.GCM.open(box, using: key, authenticating: Self.aad(secretID: secretID, version: version))
        } catch {
            throw VaultError.decryptionFailed
        }
    }

    /// Token de computador (08 AR-512): `HMAC-SHA256(chaveMestra, "box|<computerID>|<generation>")`, em hex.
    public func boxToken(computerID: String, generation: Int) async throws -> String {
        let key = try await master(createIfMissing: true)
        let mac = HMAC<SHA256>.authenticationCode(for: Data("box|\(computerID)|\(generation)".utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}
