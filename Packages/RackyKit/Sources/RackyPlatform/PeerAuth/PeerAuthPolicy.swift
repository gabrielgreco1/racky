import Foundation

/// Política de autenticação do peer do socket do daemon (06 §1.4, 08 AR-503, spike S-03).
///
/// O uid do peer tem de ser o do daemon em todos os modos. O resto depende de como o próprio daemon está assinado:
/// - `signed`: daemon assinado com certificado. O requisito prende o identificador do app e a MESMA folha de
///   certificado do daemon (identidade local, AR-530). Outro certificado, ad-hoc ou outro identificador: recusado.
/// - `adhocDevelopment`: daemon ad-hoc **e** build com `RACKY_ALLOW_ADHOC_PEERS` (flag de compilação, nunca
///   variável de ambiente). Só o uid vale. É o modo de quem ainda não rodou `scripts/make-dev-cert.sh`.
/// - `denyAll`: daemon ad-hoc num build sem a flag (ou sem como ler a própria assinatura). Nada é aceito.
public enum PeerAuthPolicy: Sendable, Hashable {
    case signed(requirement: String)
    case adhocDevelopment
    case denyAll(reason: String)

    /// Identificador de assinatura do único cliente do daemon (08 §0.1).
    public static let appIdentifier = "app.racky.mac"

    /// Requisito: identificador do app + folha do certificado do daemon (hex SHA-1; `H"..."` em minúsculas).
    public static func requirement(clientIdentifier: String, leafSHA1: String) -> String {
        "identifier \"\(clientIdentifier)\" and certificate leaf = H\"\(leafSHA1.lowercased())\""
    }

    /// Deriva a política da identidade do próprio daemon.
    public static func resolve(
        daemon: CodeIdentity?, clientIdentifier: String = appIdentifier, allowAdhocDevelopment: Bool
    ) -> PeerAuthPolicy {
        guard let daemon else {
            return .denyAll(reason: "cannot read the daemon's own code signature")
        }
        if !daemon.isAdhoc, let leaf = daemon.leafSHA1 {
            return .signed(requirement: requirement(clientIdentifier: clientIdentifier, leafSHA1: leaf))
        }
        if allowAdhocDevelopment { return .adhocDevelopment }
        return .denyAll(reason: "daemon is ad-hoc signed and this build does not allow ad-hoc peers (sign with scripts/make-dev-cert.sh)")
    }

    /// Texto curto para log de inicialização (sem dados sensíveis).
    public var modeName: String {
        switch self {
        case .signed: "signed"
        case .adhocDevelopment: "adhoc-development"
        case .denyAll: "deny-all"
        }
    }
}
