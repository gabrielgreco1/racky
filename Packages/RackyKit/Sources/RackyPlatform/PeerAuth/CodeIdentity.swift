import CommonCrypto
import Foundation
import Security

/// Identidade de assinatura de código de um processo (identificador, ad-hoc ou não, SHA-1 da folha do certificado).
public struct CodeIdentity: Sendable, Hashable {
    public var identifier: String?
    /// Assinatura ad-hoc (`CS_ADHOC`) ou ausente: não há certificado a que um requisito possa se prender.
    public var isAdhoc: Bool
    /// SHA-1 (hex minúsculo) do certificado folha; `nil` em ad-hoc.
    public var leafSHA1: String?

    public init(identifier: String?, isAdhoc: Bool, leafSHA1: String?) {
        self.identifier = identifier
        self.isAdhoc = isAdhoc
        self.leafSHA1 = leafSHA1
    }

    /// Identidade do processo atual (o daemon lê a própria assinatura para derivar o requisito, 06 §1.4).
    public static func ofCurrentProcess() -> CodeIdentity? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        return of(code)
    }

    static func of(_ code: SecCode) -> CodeIdentity? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
            let dictionary = info as? [String: Any]
        else { return nil }
        let flags = (dictionary[kSecCodeInfoFlags as String] as? UInt32) ?? 0
        var leaf: String?
        if let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate], let first = certificates.first {
            leaf = sha1Hex(SecCertificateCopyData(first) as Data)
        }
        return CodeIdentity(identifier: dictionary[kSecCodeInfoIdentifier as String] as? String, isAdhoc: flags & 0x2 != 0 || leaf == nil, leafSHA1: leaf)
    }

    private static func sha1Hex(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA1($0.baseAddress, CC_LONG(data.count), &digest) }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
