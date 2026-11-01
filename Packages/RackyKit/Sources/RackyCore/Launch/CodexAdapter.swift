import RackyPlatform
import RackyProtocol
import Foundation

/// Codex CLI (06 §2.2 e §3.3.1; `--help` conferido na 0.163.0, spike S-05 na 0.160.0).
/// Ordem do argv: `executable`, `identity` (`resume <id>` | `resume --last`), `profile` (`--no-daemon` primeiro, depois
/// modelo, esforço por `-c`, permissão, `--add-dir`, `extraArgs`), `injected` (vazio na Fatia 1; `-c hooks…` e `-c hooks.state=…` na Fatia 2), `prompt` (posicional).
/// Fatia 1 não passa `-c hooks…` nem `-c hooks.state=…`; a Fatia 2 passa (trust inline de P18).
public struct CodexAdapter: ProviderAdapter {
    public init() {}

    public let provider = TerminalProvider.codex
    public let displayName = "Codex CLI"
    public let executableName: String? = "codex"

    public let flagRules: [FlagRule] = [
        FlagRule("--model", label: "Model"),
        FlagRule("-m", label: "Model"),
        FlagRule("--config", label: "Config override"),
        FlagRule("-c", label: "Config override"),
        FlagRule("--sandbox", label: "Sandbox"),
        FlagRule("-s", label: "Sandbox"),
        FlagRule("--ask-for-approval", label: "Approval policy"),
        FlagRule("-a", label: "Approval policy"),
        FlagRule("--dangerously-bypass-approvals-and-sandbox", label: "Bypass approvals"),
        FlagRule("--add-dir", label: "Extra directories"),
        FlagRule("--no-alt-screen", label: "Native scrollback"),
        // S-05(c): visto em 0.160.0; antes disso não há evidência.
        FlagRule("--no-daemon", since: CLIVersion(0, 160, 0), label: "Run without shared server"),
        FlagRule("--last", label: "Continue last"),
    ]
    public let subcommandRules: [FlagRule] = [FlagRule("resume", label: "Resume"), FlagRule("fork", label: "Fork")]

    public let loginStatusArguments: [String]? = ["login", "status"]

    /// `Logged in using ChatGPT` / `Not logged in`. A saída vai para stdout ou stderr conforme a versão.
    public func interpretLoginStatus(_ output: ProcessOutput) -> CLILoginState {
        let text = (output.stdoutString + "\n" + output.stderrString).lowercased()
        if text.contains("not logged in") || text.contains("logged out") { return .loggedOut }
        if text.contains("logged in") { return .loggedIn }
        return .unknown("unexpected output from `codex login status` (exit \(output.exitCode))")
    }

    static let sandboxModes: Set<String> = ["read-only", "workspace-write", "danger-full-access"]
    static let approvalPolicies: Set<String> = ["on-request", "never"]
    static let bypassModes: Set<String> = ["bypass", "bypassPermissions", "dangerously-bypass-approvals-and-sandbox"]
    /// "Nunca usar" (06 §2.2): não entram nem por `extraArgs`.
    static let forbidden: Set<String> = ["--dangerously-bypass-hook-trust", "--worktree", "--remote"]

    public func build(_ launch: EffectiveLaunch, context: AdapterContext, capabilities: CLICapabilities) throws -> AdapterOutput {
        var warnings: [LaunchWarning] = []
        var identity: [String] = []
        var nativeID: String?
        var resuming = false

        switch context.mode {
        case .resume(let id):
            resuming = true
            if capabilities.supports(subcommand: "resume") { identity = ["resume", id]; nativeID = id }
            else { warnings.append(AdapterKit.unsupported("resume", adapter: self, field: "Resume")) }
        case .continueLast:
            resuming = true
            warnings.append(LaunchWarning(.resumeWithoutID, "No conversation ID was captured; continuing the last conversation in this folder"))
            if capabilities.supports(subcommand: "resume") { identity = ["resume", "--last"] }
        case .automatic:
            break
        }

        var profile: [String] = []
        if capabilities.supports("--no-daemon") {
            profile.append("--no-daemon")
        } else {
            warnings.append(LaunchWarning(.daemonFlagUnavailable, "This Codex version has no --no-daemon; launching without it (the shared server may hold the session)"))
        }
        AdapterKit.pairOrWarn("--model", launch.model, field: "Model", adapter: self, capabilities: capabilities, into: &profile, warnings: &warnings)
        if let effort = launch.effort, !effort.isEmpty {
            if capabilities.supports("-c") { profile += ["-c", "model_reasoning_effort=\(Self.tomlString(effort))"] }
            else { warnings.append(AdapterKit.unsupported("-c", adapter: self, field: "Effort")) }
        }

        switch launch.permissionMode {
        case nil, "", "default": break
        case let mode? where Self.bypassModes.contains(mode):
            if capabilities.supports("--dangerously-bypass-approvals-and-sandbox") { profile.append("--dangerously-bypass-approvals-and-sandbox") }
            else { warnings.append(AdapterKit.unsupported("--dangerously-bypass-approvals-and-sandbox", adapter: self, field: "Bypass approvals")) }
        case let mode? where Self.sandboxModes.contains(mode):
            AdapterKit.pairOrWarn("--sandbox", mode, field: "Sandbox", adapter: self, capabilities: capabilities, into: &profile, warnings: &warnings)
        case let mode? where Self.approvalPolicies.contains(mode):
            AdapterKit.pairOrWarn("--ask-for-approval", mode, field: "Approval policy", adapter: self, capabilities: capabilities, into: &profile, warnings: &warnings)
        case let mode?:
            throw LaunchPlanError.invalidPermissionMode(provider: .codex, mode: mode)
        }

        if capabilities.supports("--add-dir") {
            for dir in launch.addDirs { profile += ["--add-dir", dir] }
        } else if !launch.addDirs.isEmpty {
            warnings.append(AdapterKit.unsupported("--add-dir", adapter: self, field: "Extra directories"))
        }

        var extras: [String] = []
        for token in launch.extraArgs {
            let name = token.split(separator: "=", maxSplits: 1).first.map(String.init) ?? token
            if Self.forbidden.contains(name) {
                warnings.append(LaunchWarning(.unsupportedFlag, "\(name) is never used by Racky and was removed from the extra arguments"))
            } else { extras.append(token) }
        }
        let structured: [String: Bool] = [
            "--model": true, "-m": true, "--sandbox": true, "-s": true, "--ask-for-approval": true, "-a": true,
        ]
        let filtered = ExtraArgsFilter(structured: structured).apply(extras, adapterName: displayName) { name in
            switch name {
            case "--model", "-m": launch.model?.isEmpty == false
            case "--sandbox", "-s": profile.contains("--sandbox")
            case "--ask-for-approval", "-a": profile.contains("--ask-for-approval")
            default: false
            }
        }
        warnings += filtered.warnings
        profile += filtered.kept.filter { !($0 == "--dangerously-bypass-approvals-and-sandbox" && profile.contains($0)) }

        // Fatia 2 (P18): hooks por `-c` com trust inline; nada gravado em `~/.codex`. `--no-daemon` já está em `profile`.
        let injection = try context.injection?.codexInjection(launchDirectory: context.launchDirectory) ?? (injected: [], files: [])
        let injected = injection.injected

        var prompt: [String] = []
        var files: [LaunchFile] = injection.files
        if !resuming {
            let delivery = PromptDelivery.resolve(prompt: launch.initialPrompt, promptFile: launch.initialPromptFile, launchDirectory: context.launchDirectory)
            if let text = delivery.argumentText {
                // `-i <FILE>...` é variádico: se o usuário o pôs em extraArgs, o `--` protege o prompt.
                if !filtered.kept.isEmpty { prompt.append("--") }
                prompt.append(text)
            }
            files += delivery.files
        }

        let capture: NativeIDCaptureStrategy = resuming && nativeID != nil ? .assigned(nativeID ?? "") : .codexRollout(cwd: context.cwd)
        let argv = ResolvedArgv(executable: [context.executablePath], identity: identity, profile: profile, injected: injected, prompt: prompt)
        return AdapterOutput(
            argv: argv, nativeConversationID: nativeID, capture: capture,
            skipsPermissions: AdapterKit.skipIndicator(in: profile), warnings: warnings, files: files
        )
    }

    /// String TOML básica (valor de `-c chave=valor`).
    static func tomlString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04X", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }
}
