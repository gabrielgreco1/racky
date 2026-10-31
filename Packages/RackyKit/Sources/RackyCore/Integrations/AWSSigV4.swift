import CryptoKit
import Foundation

/// Assinatura AWS Signature Version 4 (só o que o S3 e os testes do conjunto oficial precisam). Função pura: dado o pedido e a hora,
/// devolve os cabeçalhos a acrescentar (`Authorization`, `x-amz-date`, …). Nada aqui toca a rede nem o disco.
public struct AWSSigV4: Sendable {
    public let accessKeyID: String
    public let secretAccessKey: String
    public let sessionToken: String?
    public let region: String
    public let service: String
    /// O S3 exige `x-amz-content-sha256` assinado; os outros serviços (e o conjunto de testes da AWS) não.
    public let signsContentSHA: Bool

    public init(accessKeyID: String, secretAccessKey: String, sessionToken: String? = nil, region: String, service: String = "s3", signsContentSHA: Bool = true) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
        self.region = region
        self.service = service
        self.signsContentSHA = signsContentSHA
    }

    /// SHA-256 de um corpo vazio (GET/HEAD).
    public static let emptyPayloadHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    /// Os cabeçalhos que o pedido precisa levar. `path` já vem codificado como será enviado; `query` vem decodificado.
    public func authorize(
        method: String, host: String, path: String, query: [(String, String)] = [], headers: [String: String] = [:],
        payloadHash: String = AWSSigV4.emptyPayloadHash, date: Date
    ) -> [String: String] {
        let amzDate = Self.amzDate(date)
        let dateStamp = String(amzDate.prefix(8))
        var signed: [String: String] = ["host": host, "x-amz-date": amzDate]
        for (name, value) in headers { signed[name.lowercased()] = value }
        if signsContentSHA { signed["x-amz-content-sha256"] = payloadHash }
        if let sessionToken, !sessionToken.isEmpty { signed["x-amz-security-token"] = sessionToken }

        let names = signed.keys.sorted()
        let canonicalHeaders = names.map { "\($0):\(Self.trim(signed[$0] ?? ""))\n" }.joined()
        let signedHeaders = names.joined(separator: ";")
        var pairs: [[String]] = []
        for (name, value) in query { pairs.append([Self.encode(name), Self.encode(value)]) }
        // Ordena pelo nome codificado (e pelo valor, se o nome repete).
        pairs.sort { $0[0] == $1[0] ? $0[1] < $1[1] : $0[0] < $1[0] }
        let canonicalQuery = pairs.map { $0[0] + "=" + $0[1] }.joined(separator: "&")
        let canonical = [method, path, canonicalQuery, canonicalHeaders, signedHeaders, payloadHash].joined(separator: "\n")

        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, Self.hex(SHA256.hash(data: Data(canonical.utf8)))].joined(separator: "\n")
        let kDate = Self.hmac(Data("AWS4\(secretAccessKey)".utf8), dateStamp)
        let kRegion = Self.hmac(kDate, region)
        let kService = Self.hmac(kRegion, service)
        let kSigning = Self.hmac(kService, "aws4_request")
        let signature = Self.hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: SymmetricKey(data: kSigning)))

        var out = ["x-amz-date": amzDate]
        if signsContentSHA { out["x-amz-content-sha256"] = payloadHash }
        if let sessionToken, !sessionToken.isEmpty { out["x-amz-security-token"] = sessionToken }
        out["Authorization"] = "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        return out
    }

    // MARK: Auxiliares

    /// `20150830T123600Z`.
    static func amzDate(_ date: Date) -> String {
        let t = Int(date.timeIntervalSince1970.rounded(.down))
        let days = Int((Double(t) / 86_400).rounded(.down))
        let secs = t - days * 86_400
        // Data civil a partir de dias (algoritmo de Howard Hinnant), sem DateFormatter (não é Sendable).
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
        func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        return "\(year)\(two(month))\(two(day))T\(two(secs / 3_600))\(two(secs % 3_600 / 60))\(two(secs % 60))Z"
    }

    /// Codificação de URI da AWS: só `A-Za-z0-9-._~` ficam como estão (a barra também, quando `keepSlash`).
    public static func encode(_ text: String, keepSlash: Bool = false) -> String {
        var out = ""
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "A") ... UInt8(ascii: "Z"), UInt8(ascii: "a") ... UInt8(ascii: "z"), UInt8(ascii: "0") ... UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
                out.append(Character(UnicodeScalar(byte)))
            case UInt8(ascii: "/") where keepSlash:
                out.append("/")
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    private static func trim(_ value: String) -> String {
        value.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    private static func hmac(_ key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }

    static func hex(_ bytes: some Sequence<UInt8>) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
}
