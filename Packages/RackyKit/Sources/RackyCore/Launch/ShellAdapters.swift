import RackyPlatform
import RackyProtocol
import Darwin
import Foundation

/// Shell do usuário: `$SHELL -l` (login interativo no PTY). Sem prompt, sem ID nativo, sem estado de agente.
public struct ShellAdapter: ProviderAdapter {
    public init() {}

    public let provider = TerminalProvider.shell
    public let displayName = "Shell"
    public let executableName: String? = nil
    public let flagRules: [FlagRule] = []

    public func build(_ launch: EffectiveLaunch, context: AdapterContext, capabilities: CLICapabilities) throws -> AdapterOutput {
        let shell = context.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? Self.passwdShell()
        guard let shell else { throw LaunchPlanError.noShellAvailable }
        var warnings: [LaunchWarning] = []
        if launch.initialPrompt?.isEmpty == false || launch.initialPromptFile != nil {
            warnings.append(LaunchWarning(.promptIgnored, "A shell terminal has no initial prompt"))
        }
        var profile = ["-l"]
        profile += launch.extraArgs
        return AdapterOutput(
            argv: ResolvedArgv(executable: [shell], identity: [], profile: profile, injected: [], prompt: []),
            nativeConversationID: nil, capture: .none, skipsPermissions: nil, warnings: warnings, files: []
        )
    }

    static func passwdShell() -> String? {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return nil }
        let path = String(cString: shell)
        return path.isEmpty ? nil : path
    }
}

/// "Custom Command": argv livre tokenizado (06 §2.2), sem interpolação; o argv é mostrado antes de lançar.
public struct CustomCommandAdapter: ProviderAdapter {
    public init() {}

    public let provider = TerminalProvider.custom
    public let displayName = "Custom Command"
    public let executableName: String? = nil
    public let flagRules: [FlagRule] = []

    public func build(_ launch: EffectiveLaunch, context: AdapterContext, capabilities: CLICapabilities) throws -> AdapterOutput {
        guard let argv = launch.customArgv, let first = argv.first, !first.isEmpty else { throw LaunchPlanError.missingCustomArgv }
        var warnings: [LaunchWarning] = []
        if launch.initialPrompt?.isEmpty == false || launch.initialPromptFile != nil {
            warnings.append(LaunchWarning(.promptIgnored, "A custom command has no initial prompt"))
        }
        // Primeiro elemento: nome simples usa o caminho que o chamador resolveu pelo PATH do login; senão fica como digitado.
        let resolved = URL(fileURLWithPath: context.executablePath).lastPathComponent == first ? context.executablePath : first
        let executable = first.contains("/") ? first : resolved
        return AdapterOutput(
            argv: ResolvedArgv(executable: [executable], identity: [], profile: Array(argv.dropFirst()) + launch.extraArgs, injected: [], prompt: []),
            nativeConversationID: nil, capture: .none, skipsPermissions: nil, warnings: warnings, files: []
        )
    }
}
