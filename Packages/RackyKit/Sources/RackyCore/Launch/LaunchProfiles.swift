import RackyProtocol
import Foundation

/// Perfis prontos (06 §2.3). IDs fixos para que golden files e snapshots de `LaunchSpec.profileID` sejam estáveis.
///
/// Padrões: Claude `--dangerously-skip-permissions` e Codex
/// `--dangerously-bypass-approvals-and-sandbox`. Por isso "Claude · Default" e "Codex · Default" PULAM permissões, e todo
/// lançamento efetivo assim carrega o indicador `ShieldOff` (ver `LaunchPlan.skipsPermissions`). O onboarding mostra
/// `BuiltinProfiles.skipPermissionsNotice` e pede escolha explícita; trocar de perfil remove o bypass.
public enum BuiltinProfiles {
    public static let skipPermissionsNotice = "Agents run without permission prompts. You can change this per profile."

    private static let epoch = Date(timeIntervalSince1970: 0)

    private static func make(
        _ id: String, _ name: String, _ provider: TerminalProvider, permission: String? = nil,
        isDefault: Bool = false, source: RecordSource = .manual
    ) -> LaunchProfile {
        LaunchProfile(
            id: UUID(uuidString: id) ?? UUID(), name: name, provider: provider, permissionMode: permission,
            scope: .global, isDefault: isDefault, source: source, createdAt: epoch, updatedAt: epoch
        )
    }

    public static let claudeDefault = make("A0000000-0000-4000-8000-000000000001", "Claude · Default", .claude, permission: "bypassPermissions", isDefault: true)
    public static let claudePlan = make("A0000000-0000-4000-8000-000000000002", "Claude · Plan", .claude, permission: "plan")
    public static let codexDefault = make("A0000000-0000-4000-8000-000000000003", "Codex · Default", .codex, permission: "bypass", isDefault: true)
    public static let openCodeDefault = make("A0000000-0000-4000-8000-000000000004", "OpenCode · Default", .opencode, isDefault: true)
    public static let shell = make("A0000000-0000-4000-8000-000000000005", "Shell", .shell, isDefault: true)
    /// Variantes explícitas que pulam permissões (mesmos flags dos perfis padrão de Claude e Codex).
    public static let claudeSkipPermissions = make("A0000000-0000-4000-8000-000000000006", "Claude · Skip permissions", .claude, permission: "bypassPermissions")
    public static let codexBypassApprovals = make("A0000000-0000-4000-8000-000000000007", "Codex · Bypass approvals", .codex, permission: "bypass")

    public static let all: [LaunchProfile] = [
        claudeDefault, claudePlan, codexDefault, openCodeDefault, shell, claudeSkipPermissions, codexBypassApprovals,
    ]

    public static func defaultProfile(for provider: TerminalProvider) -> LaunchProfile? {
        all.first { $0.provider == provider && $0.isDefault }
    }
}

/// Perfis salvos pelo usuário + os prontos. Resolução: terminal → projeto → global (01 §5.8).
public struct ProfileCatalog: Sendable {
    public var profiles: [LaunchProfile]

    public init(userProfiles: [LaunchProfile] = []) {
        let userIDs = Set(userProfiles.map(\.id))
        profiles = userProfiles + BuiltinProfiles.all.filter { !userIDs.contains($0.id) }
    }

    /// 1. perfil escolhido no terminal (`explicitID`, inclui "Relaunch With…"); 2. padrão do projeto; 3. padrão global do
    /// usuário; 4. padrão pronto. Perfil de outro provider é ignorado.
    public func resolve(provider: TerminalProvider, explicitID: UUID?, projectID: UUID?) -> LaunchProfile? {
        if let explicitID, let hit = profiles.first(where: { $0.id == explicitID && $0.provider == provider }) { return hit }
        if let projectID, let hit = profiles.first(where: {
            $0.provider == provider && $0.scope == .project && $0.projectID == projectID && $0.isDefault
        }) { return hit }
        if let hit = profiles.first(where: { $0.provider == provider && $0.scope == .global && $0.isDefault }) { return hit }
        return nil
    }
}
