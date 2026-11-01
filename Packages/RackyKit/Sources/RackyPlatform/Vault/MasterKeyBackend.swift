import RackyProtocol
import Foundation
import Security

/// Onde mora a chave mestra de 256 bits (08 AR-510). Injetável: produção usa `SystemKeychainBackend`; testes usam
/// `InMemoryMasterKeyBackend`, que nunca toca o Keychain do usuário.
public protocol MasterKeyBackend: Sendable {
    /// `nil` quando ainda não existe item.
    func loadMasterKey() async throws -> Data?
    func storeMasterKey(_ key: Data) async throws
    func deleteMasterKey() async throws
}

public enum VaultError: Error, Equatable, Sendable, CustomStringConvertible {
    case keychain(status: Int32)
    case masterKeyMissing
    case masterKeyCorrupt
    case decryptionFailed
    case invalidKeyVersion(Int)

    public var description: String {
        switch self {
        case .keychain(let status): "Keychain error \(status)"
        case .masterKeyMissing: "The vault master key is missing from the Keychain"
        case .masterKeyCorrupt: "The vault master key in the Keychain is malformed"
        case .decryptionFailed: "A secret could not be decrypted"
        case .invalidKeyVersion(let v): "Invalid vault key version \(v)"
        }
    }
}

/// Item único `kSecClassGenericPassword` (serviço `app.racky.vault`, conta `master-v1`), `AfterFirstUnlockThisDeviceOnly`,
/// não sincronizável, ACL padrão do criador (AR-510). `SecItem*` pode esperar um prompt do Keychain, então roda no
/// `BlockingIOBridge` e nunca no pool cooperativo.
public struct SystemKeychainBackend: MasterKeyBackend {
    public static let service = "app.racky.vault"
    public static let account = "master-v1"
    /// Serviço do item.
    public let serviceName: String

    public init(service: String = SystemKeychainBackend.service) { serviceName = service }

    /// Produção: o serviço do produto.
    public static func system() -> SystemKeychainBackend { SystemKeychainBackend() }

    private static func identity(service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
    }

    public func loadMasterKey() async throws -> Data? {
        let service = serviceName
        let result: Result<Data?, VaultError> = await BlockingIOBridge.run {
            var query = Self.identity(service: service)
            query[kSecReturnData as String] = kCFBooleanTrue
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            switch status {
            case errSecSuccess: return .success(item as? Data)
            case errSecItemNotFound: return .success(nil)
            default: return .failure(.keychain(status: status))
            }
        }
        return try result.get()
    }

    public func storeMasterKey(_ key: Data) async throws {
        let service = serviceName
        let status: OSStatus = await BlockingIOBridge.run {
            var attributes = Self.identity(service: service)
            attributes[kSecValueData as String] = key
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(attributes as CFDictionary, nil)
            if added == errSecDuplicateItem {
                return SecItemUpdate(Self.identity(service: service) as CFDictionary, [kSecValueData as String: key] as CFDictionary)
            }
            return added
        }
        guard status == errSecSuccess else { throw VaultError.keychain(status: status) }
    }

    public func deleteMasterKey() async throws {
        let service = serviceName
        let status: OSStatus = await BlockingIOBridge.run { SecItemDelete(Self.identity(service: service) as CFDictionary) }
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError.keychain(status: status) }
    }
}

/// Backend de teste e de ambientes sem Keychain: a chave vive só na memória do processo.
public actor InMemoryMasterKeyBackend: MasterKeyBackend {
    private var key: Data?
    public private(set) var loadCount = 0
    public private(set) var storeCount = 0

    public init(key: Data? = nil) { self.key = key }

    public func loadMasterKey() async throws -> Data? { loadCount += 1; return key }
    public func storeMasterKey(_ key: Data) async throws { storeCount += 1; self.key = key }
    public func deleteMasterKey() async throws { key = nil }
}
