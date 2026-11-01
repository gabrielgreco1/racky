import Foundation
import Security

/// Motivo da recusa de um peer. `kind` é estável (log e mensagem do `error{peerRejected}`); `detail` vai só para o log.
public struct PeerRejection: Error, Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case noCredentials = "no peer credentials"
        case uidMismatch = "uid mismatch"
        case noAuditToken = "no audit token"
        case codeNotFound = "peer code not found"
        case requirementInvalid = "invalid requirement"
        case requirementNotSatisfied = "signature requirement not satisfied"
        case policyDenied = "policy denies all peers"
    }

    public var kind: Kind
    public var detail: String

    public init(_ kind: Kind, _ detail: String = "") {
        self.kind = kind
        self.detail = detail
    }
}

public enum PeerAuthDecision: Sendable, Hashable {
    case accepted
    case rejected(PeerRejection)
}

/// Autentica o peer de uma conexão (uid sempre; requisito de assinatura quando a política é `signed`).
/// As chamadas do Security.framework são síncronas: rode `authenticate` fora do pool cooperativo (`BlockingIOBridge`).
public struct PeerAuthenticator: Sendable {
    public let policy: PeerAuthPolicy
    public let expectedUID: uid_t

    public init(policy: PeerAuthPolicy, expectedUID: uid_t = geteuid()) {
        self.policy = policy
        self.expectedUID = expectedUID
    }

    public func authenticate(_ credentials: PeerCredentials?) -> PeerAuthDecision {
        if case .denyAll(let reason) = policy { return .rejected(PeerRejection(.policyDenied, reason)) }
        guard let credentials else { return .rejected(PeerRejection(.noCredentials)) }
        guard credentials.uid == expectedUID else {
            return .rejected(PeerRejection(.uidMismatch, "peer uid \(credentials.uid), expected \(expectedUID)"))
        }
        switch policy {
        case .denyAll, .adhocDevelopment:
            return .accepted
        case .signed(let requirementText):
            return verifySignature(credentials, requirementText: requirementText)
        }
    }

    private func verifySignature(_ credentials: PeerCredentials, requirementText: String) -> PeerAuthDecision {
        guard let token = credentials.auditToken else { return .rejected(PeerRejection(.noAuditToken)) }
        var requirement: SecRequirement?
        let compiled = SecRequirementCreateWithString(requirementText as CFString, [], &requirement)
        guard compiled == errSecSuccess, let requirement else {
            return .rejected(PeerRejection(.requirementInvalid, "OSStatus \(compiled)"))
        }
        var guest: SecCode?
        let attributes = [kSecGuestAttributeAudit: token] as CFDictionary
        let found = SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest)
        guard found == errSecSuccess, let guest else {
            return .rejected(PeerRejection(.codeNotFound, "OSStatus \(found)"))
        }
        let status = SecCodeCheckValidity(guest, SecCSFlags(rawValue: kSecCSStrictValidate), requirement)
        guard status == errSecSuccess else {
            let who = CodeIdentity.of(guest)
            let detail = "OSStatus \(status), peer identifier \(who?.identifier ?? "?"), adhoc \(who?.isAdhoc ?? true), leaf \(who?.leafSHA1 ?? "none")"
            return .rejected(PeerRejection(.requirementNotSatisfied, detail))
        }
        return .accepted
    }
}
