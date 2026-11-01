import Foundation

/// Esquema de tags de TODO recurso na nuvem (estudo 6.1, camada 4). O papel IAM do usuário só enxerga/altera recursos com
/// `racky:managed=true`, e o reaper só toca nos do próprio `racky:owner`.
public struct RackyTags: Sendable, Equatable {
    public static let managedKey = "racky:managed"
    public static let ownerKey = "racky:owner"
    public static let hostKey = "racky:host"
    public static let runKey = "racky:run"
    public static let createdKey = "racky:created"
    public static let expiresKey = "racky:expires"
    public static let providerKey = "racky:provider"

    /// `installId` do app (um por instalação).
    public var owner: String
    /// Id do host do ponto de vista do app (estável antes de a VM ter id).
    public var host: String
    public var run: String?
    public var created: Date
    /// Fim da vida máxima (a VM se encerra sozinha nesse instante).
    public var expires: Date
    public var provider: CloudProviderID

    public init(owner: String, host: String, run: String? = nil, created: Date, expires: Date, provider: CloudProviderID) {
        self.owner = owner; self.host = host; self.run = run; self.created = created; self.expires = expires; self.provider = provider
    }

    public var dictionary: [String: String] {
        var result = [
            Self.managedKey: "true", Self.ownerKey: owner, Self.hostKey: host, Self.providerKey: provider.rawValue,
            Self.createdKey: String(Int(created.timeIntervalSince1970)), Self.expiresKey: String(Int(expires.timeIntervalSince1970)),
        ]
        if let run { result[Self.runKey] = run }
        return result
    }

    /// Filtro de listagem: tudo que é do Racky e deste dono.
    public static func filter(owner: String) -> [String: String] { [managedKey: "true", ownerKey: owner] }

    /// Lê as tags de um recurso; `nil` se não for do Racky.
    public init?(_ tags: [String: String]) {
        guard tags[Self.managedKey] == "true", let owner = tags[Self.ownerKey], let host = tags[Self.hostKey],
              let created = tags[Self.createdKey].flatMap(Double.init), let expires = tags[Self.expiresKey].flatMap(Double.init) else { return nil }
        self.init(owner: owner, host: host, run: tags[Self.runKey], created: Date(timeIntervalSince1970: created),
                  expires: Date(timeIntervalSince1970: expires), provider: CloudProviderID(rawValue: tags[Self.providerKey] ?? "unknown"))
    }
}
