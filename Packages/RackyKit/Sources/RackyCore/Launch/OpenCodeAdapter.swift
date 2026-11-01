import RackyPlatform
import RackyProtocol
import Foundation

/// OpenCode (06 §2.2; `--help` conferido na 1.18.34). Cidadão de segunda classe: abre, retoma e recebe prompt.
/// Ordem do argv: `executable`, `identity` (`-s <id>` | `-c`), `profile` (`-m`, `--auto`, `extraArgs`), `prompt` (`--prompt <texto>`).
/// O diretório é o cwd do processo: o app não passa o posicional `[project]`.
public struct OpenCodeAdapter: ProviderAdapter {
    public init() {}

    public let provider = TerminalProvider.opencode
    public let displayName = "OpenCode"
    public let executableName: String? = "opencode"

    public let flagRules: [FlagRule] = [
        FlagRule("--prompt", label: "Initial prompt"),
        FlagRule("--session", label: "Resume"),
        FlagRule("--continue", label: "Continue last"),
        FlagRule("--model", label: "Model"),
        FlagRule("--agent", label: "Agent"),
        FlagRule("--auto", since: CLIVersion(1, 18, 34), label: "Auto-approve permissions"),
    ]
    public let subcommandRules: [FlagRule] = [FlagRule("session", label: "Sessions"), FlagRule("providers", label: "Providers")]

    /// `opencode providers list`: não há comando "status"; "N credentials" diz se há alguma conta.
    public let loginStatusArguments: [String]? = ["providers", "list"]

    public func interpretLoginStatus(_ output: ProcessOutput) -> CLILoginState {
        let text = (output.stdoutString + output.stderrString).replacing(/\u{1B}\[[0-9;]*m/, with: "")
        guard let match = text.firstMatch(of: /(\d+)\s+credentials?/), let count = Int(match.1) else {
            return .unknown("unexpected output from `opencode providers list` (exit \(output.exitCode))")
        }
        return count > 0 ? .loggedIn : .loggedOut
    }

    static let autoModes: Set<String> = ["auto", "bypass", "bypassPermissions"]

    public func build(_ launch: EffectiveLaunch, context: AdapterContext, capabilities: CLICapabilities) throws -> AdapterOutput {
        var warnings: [LaunchWarning] = []
        var identity: [String] = []
        var nativeID: String?
        var resuming = false

        switch context.mode {
        case .resume(let id):
            resuming = true
            if capabilities.supports("--session") { identity = ["-s", id]; nativeID = id }
            else { warnings.append(AdapterKit.unsupported("--session", adapter: self, field: "Resume")) }
        case .continueLast:
            resuming = true
            warnings.append(LaunchWarning(.resumeWithoutID, "No conversation ID was captured; continuing the last conversation in this folder"))
            if capabilities.supports("--continue") { identity = ["-c"] }
        case .automatic:
            break
        }

        var profile: [String] = []
        if let model = launch.model, !model.isEmpty {
            if capabilities.supports("--model") { profile += ["-m", model] }
            else { warnings.append(AdapterKit.unsupported("--model", adapter: self, field: "Model")) }
        }
        if let effort = launch.effort, !effort.isEmpty {
            warnings.append(LaunchWarning(.unsupportedFlag, "Effort not applied: OpenCode has no effort flag"))
        }
        switch launch.permissionMode {
        case nil, "", "default": break
        case let mode? where Self.autoModes.contains(mode):
            if capabilities.supports("--auto") { profile.append("--auto") }
            else { warnings.append(AdapterKit.unsupported("--auto", adapter: self, field: "Auto-approve permissions")) }
        case let mode?:
            throw LaunchPlanError.invalidPermissionMode(provider: .opencode, mode: mode)
        }
        if !launch.addDirs.isEmpty {
            warnings.append(LaunchWarning(.unsupportedFlag, "Extra directories not applied: OpenCode has no --add-dir"))
        }

        let filtered = ExtraArgsFilter(structured: ["--model": true, "-m": true]).apply(launch.extraArgs, adapterName: displayName) { _ in
            launch.model?.isEmpty == false
        }
        warnings += filtered.warnings
        profile += filtered.kept.filter { !($0 == "--auto" && profile.contains($0)) }

        // Subagent computers: a config inline vai por env (`OPENCODE_CONFIG_CONTENT`), o texto de instruções por arquivo do lançamento.
        let injection = try context.injection?.openCodeInjection(launchDirectory: context.launchDirectory) ?? (environment: [:], files: [])
        var prompt: [String] = []
        var files: [LaunchFile] = injection.files
        if !resuming {
            let delivery = PromptDelivery.resolve(prompt: launch.initialPrompt, promptFile: launch.initialPromptFile, launchDirectory: context.launchDirectory)
            if let text = delivery.argumentText {
                if capabilities.supports("--prompt") { prompt = ["--prompt", text] }
                else { warnings.append(AdapterKit.unsupported("--prompt", adapter: self, field: "Initial prompt")) }
            }
            files += delivery.files
        }

        let capture: NativeIDCaptureStrategy = nativeID.map { .assigned($0) } ?? .openCodeSessionList(cwd: context.cwd)
        let argv = ResolvedArgv(executable: [context.executablePath], identity: identity, profile: profile, injected: [], prompt: prompt)
        return AdapterOutput(
            argv: argv, nativeConversationID: nativeID, capture: capture,
            skipsPermissions: AdapterKit.skipIndicator(in: profile, extra: ["--auto"]), warnings: warnings, files: files, environment: injection.environment
        )
    }
}
