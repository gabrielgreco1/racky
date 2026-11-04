import Foundation

/// Variáveis do cofre do agente prontas para o env do computador. Só o daemon recebe os valores (como em `SecretInjection`).
public struct AgentLaunchEnvironment: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var injection: SecretInjection
    /// Variáveis cujo segredo não existe, venceu ou não é `profileEnv` (só nome e motivo).
    public var skipped: [SecretInjection.Skipped]
    public var masker: LogMasker
    public var environment: [String: String] { injection.environment }
    public var description: String { "AgentLaunchEnvironment(env: \(injection.names.joined(separator: ", ")), skipped: \(skipped.count))" }
    public var debugDescription: String { description }
}

public enum AgentEnvironment {
    /// Resolve `agent.variables` no cofre. Os valores vão só para o env do computador; o `masker` serve para limpar logs e diário.
    public static func resolve(for agent: AgentDefinition, vault: SecretVault) async throws -> AgentLaunchEnvironment {
        let infos = try await vault.list()
        var selections: [SecretSelection] = []
        var missing: [SecretInjection.Skipped] = []
        for v in agent.variables {
            if let info = infos.first(where: { $0.name == v.secretName }) {
                selections.append(SecretSelection(secretID: info.id, envName: v.envName))
            } else {
                missing.append(.init(envName: v.envName, reason: .missing))
            }
        }
        let injection = try await vault.injection(for: selections)
        return AgentLaunchEnvironment(
            injection: injection, skipped: missing + injection.skipped, masker: LogMasker(secrets: Array(injection.environment.values)))
    }
}

/// Troca valores de segredo por `•••` em qualquer texto (logs, diário, resumos). Cobre o valor cru e a forma codificada em URL.
public struct LogMasker: Sendable {
    public static let mask = "•••"
    private let needles: [String]

    public init(secrets: [String]) {
        var set = Set<String>()
        for s in secrets where s.count >= 3 {
            set.insert(s)
            if let enc = s.addingPercentEncoding(withAllowedCharacters: .alphanumerics), enc != s { set.insert(enc) }
        }
        needles = set.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
    }

    public func mask(_ text: String) -> String {
        var out = text
        for n in needles { out = out.replacingOccurrences(of: n, with: Self.mask) }
        return out
    }
}
