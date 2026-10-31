import RackyProtocol
import Foundation

/// Opção de permissão de um perfil (06 §2.3). `skips` = o lançamento efetivo pula permissões (ícone `ShieldOff`).
public struct PermissionChoice: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let skips: Bool
}

public enum ProfileOptions {
    /// Modos que cada adapter aceita (`ClaudeAdapter.permissionModes`, `CodexAdapter.sandboxModes`/`approvalPolicies`/`bypassModes`,
    /// `OpenCodeAdapter.autoModes`). `default` grava `nil`.
    public static func permissionChoices(for provider: TerminalProvider) -> [PermissionChoice] {
        switch provider {
        case .claude:
            return [
                .init(id: "default", title: "Default", skips: false), .init(id: "acceptEdits", title: "Accept edits", skips: false),
                .init(id: "plan", title: "Plan mode", skips: false), .init(id: "auto", title: "Auto", skips: false),
                .init(id: "dontAsk", title: "Don't ask", skips: false), .init(id: "bypassPermissions", title: "Skip permissions", skips: true),
            ]
        case .codex:
            return [
                .init(id: "default", title: "Default", skips: false), .init(id: "read-only", title: "Read-only sandbox", skips: false),
                .init(id: "workspace-write", title: "Workspace write", skips: false), .init(id: "on-request", title: "Ask on request", skips: false),
                .init(id: "bypass", title: "Bypass approvals", skips: true),
            ]
        case .opencode:
            return [.init(id: "default", title: "Default", skips: false), .init(id: "auto", title: "Auto-approve", skips: true)]
        case .shell, .custom:
            return []
        }
    }

    /// Flags que o usuário pode digitar em "Extra flags": as do adapter, menos as que o app controla por campo estruturado
    /// ou pelo ID da conversa. O resto o adapter nunca aplicaria com segurança.
    public static func allowedExtraFlags(for provider: TerminalProvider) -> [FlagRule] {
        let controlled: Set<String> = [
            "--session-id", "--resume", "--continue", "--last", "--model", "-m", "--effort", "--permission-mode", "--no-daemon",
        ]
        return ProviderAdapters.adapter(for: provider).flagRules.filter { !controlled.contains($0.flag) }
    }

    public enum ArgsResult: Equatable, Sendable {
        case valid([String])
        case invalid(String)
    }

    /// Valida o texto de "Extra flags": toda palavra que começa com `-` tem de estar na lista permitida do agente.
    public static func validateExtraArgs(_ text: String, for provider: TerminalProvider) -> ArgsResult {
        let tokens: [String]
        do { tokens = try ShellWords.split(text) } catch { return .invalid("Close the quotation mark.") }
        let allowed = Set(allowedExtraFlags(for: provider).map(\.flag))
        let name = ProviderAdapters.adapter(for: provider).displayName
        for token in tokens where token.hasPrefix("-") && token.count > 1 {
            let flag = token.split(separator: "=", maxSplits: 1).first.map(String.init) ?? token
            if !allowed.contains(flag) { return .invalid("\(flag) isn't an allowed flag for \(name).") }
        }
        return .valid(tokens)
    }
}

extension LaunchProfile {
    /// Pula permissões, pelo modo ou por uma flag em `extraArgs`. O indicador é permanente (06 §2.3).
    public var skipsPermissions: SkipPermissionsIndicator? {
        if let mode = permissionMode, ProfileOptions.permissionChoices(for: provider).first(where: { $0.id == mode })?.skips == true {
            switch provider {
            case .claude: return SkipPermissionsIndicator(flag: "--dangerously-skip-permissions")
            case .codex: return SkipPermissionsIndicator(flag: "--dangerously-bypass-approvals-and-sandbox")
            case .opencode: return SkipPermissionsIndicator(flag: "--auto")
            case .shell, .custom: break
            }
        }
        return AdapterKit.skipIndicator(in: extraArgs)
    }

    /// Perfis prontos e importados têm ID fixo (`BuiltinProfiles.all`); o usuário duplica em vez de editar.
    public var isBuiltin: Bool { BuiltinProfiles.all.contains { $0.id == id } }

    public func duplicated(id: UUID = .v7(), now: Date = Date()) -> LaunchProfile {
        var copy = self
        copy.id = id
        copy.name = "\(name) copy"
        copy.isDefault = false
        copy.source = .manual
        copy.createdAt = now
        copy.updatedAt = now
        return copy
    }
}

public enum ProfileDefaults {
    /// Perfis a gravar para que `profileID` passe a ser o padrão global do provider. Um perfil pronto vira uma cópia
    /// gravada com o mesmo ID (o catálogo prefere a do usuário, `ProfileCatalog`); os outros padrões gravados do provider desligam.
    public static func assigning(profileID: UUID, saved: [LaunchProfile], now: Date = Date()) -> [LaunchProfile] {
        let catalog = ProfileCatalog(userProfiles: saved)
        guard var target = catalog.profiles.first(where: { $0.id == profileID }) else { return [] }
        var writes: [LaunchProfile] = []
        for var other in saved where other.id != profileID && other.provider == target.provider && other.scope == .global && other.isDefault {
            other.isDefault = false
            other.updatedAt = now
            writes.append(other)
        }
        target.isDefault = true
        target.scope = .global
        target.updatedAt = now
        writes.append(target)
        return writes
    }
}
