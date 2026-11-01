import RackyPlatform
import RackyProtocol
import Foundation

/// Claude Code (06 §2.2, conferido no `--help` da 2.1.302).
/// Ordem do argv: `executable`, `identity` (`--session-id <uuid>` | `--resume <id>` | `-c`), `profile`
/// (modelo, esforço, permissão, `--add-dir`, `extraArgs`), `injected` (vazio na Fatia 1; `--settings`/`--mcp-config`/`--plugin-dir` na Fatia 2), `prompt` (posicional).
public struct ClaudeAdapter: ProviderAdapter {
    public init() {}

    public let provider = TerminalProvider.claude
    public let displayName = "Claude Code"
    public let executableName: String? = "claude"

    /// `since` = menor versão em que a flag foi vista no `--help` real (2.1.302). Sem piso = antiga e estável.
    public let flagRules: [FlagRule] = [
        FlagRule("--session-id", label: "Session ID"),
        FlagRule("--resume", label: "Resume"),
        FlagRule("--continue", label: "Continue last"),
        FlagRule("--model", label: "Model"),
        FlagRule("--effort", since: CLIVersion(2, 1, 302), label: "Effort"),
        FlagRule("--permission-mode", label: "Permission mode"),
        FlagRule("--dangerously-skip-permissions", label: "Skip permissions"),
        FlagRule("--add-dir", label: "Extra directories"),
    ]

    public let loginStatusArguments: [String]? = ["auth", "status", "--json"]

    /// `{"loggedIn": true, ...}`. Só o booleano é lido; e-mail, organização e plano nunca saem daqui.
    public func interpretLoginStatus(_ output: ProcessOutput) -> CLILoginState {
        struct Status: Decodable { var loggedIn: Bool }
        if let status = try? JSONDecoder().decode(Status.self, from: output.stdout) {
            return status.loggedIn ? .loggedIn : .loggedOut
        }
        return .unknown("unexpected output from `claude auth status` (exit \(output.exitCode))")
    }

    static let permissionModes: Set<String> = ["acceptEdits", "auto", "bypassPermissions", "manual", "dontAsk", "plan"]
    static let hookKillers: Set<String> = ["--bare", "--safe-mode"]

    public func build(_ launch: EffectiveLaunch, context: AdapterContext, capabilities: CLICapabilities) throws -> AdapterOutput {
        var warnings: [LaunchWarning] = []
        var identity: [String] = []
        var nativeID: String?
        var capture = NativeIDCaptureStrategy.none
        var resuming = false

        switch context.mode {
        case .resume(let id):
            resuming = true
            if capabilities.supports("--resume") { identity = ["--resume", id]; nativeID = id }
            else { warnings.append(AdapterKit.unsupported("--resume", adapter: self, field: "Resume")) }
        case .continueLast:
            resuming = true
            warnings.append(LaunchWarning(.resumeWithoutID, "No conversation ID was captured; continuing the last conversation in this folder"))
            if capabilities.supports("--continue") { identity = ["-c"] }
        case .automatic:
            if let existing = launch.nativeSessionID, context.conversationExists(existing), capabilities.supports("--resume") {
                // Relançamento (Restart/Resume/reabertura) de uma conversa que já existe: retoma em vez de recriar o ID.
                resuming = true
                identity = ["--resume", existing]
                nativeID = existing
            } else if capabilities.supports("--session-id") {
                let id = launch.nativeSessionID ?? context.newUUID().uuidString.lowercased()
                identity = ["--session-id", id]
                nativeID = id
                capture = .assigned(id)
            } else {
                warnings.append(AdapterKit.unsupported("--session-id", adapter: self, field: "Conversation ID"))
            }
        }

        var profile: [String] = []
        AdapterKit.pairOrWarn("--model", launch.model, field: "Model", adapter: self, capabilities: capabilities, into: &profile, warnings: &warnings)
        AdapterKit.pairOrWarn("--effort", launch.effort, field: "Effort", adapter: self, capabilities: capabilities, into: &profile, warnings: &warnings)

        switch launch.permissionMode {
        case nil, "", "default": break
        case "bypassPermissions":
            if capabilities.supports("--dangerously-skip-permissions") { profile.append("--dangerously-skip-permissions") }
            else { warnings.append(AdapterKit.unsupported("--dangerously-skip-permissions", adapter: self, field: "Skip permissions")) }
        case let mode? where Self.permissionModes.contains(mode):
            if capabilities.supports("--permission-mode") { profile += ["--permission-mode", mode] }
            else { warnings.append(AdapterKit.unsupported("--permission-mode", adapter: self, field: "Permission mode")) }
        case let mode?:
            throw LaunchPlanError.invalidPermissionMode(provider: .claude, mode: mode)
        }

        if capabilities.supports("--add-dir") {
            for dir in launch.addDirs { profile += ["--add-dir", dir] }
        } else if !launch.addDirs.isEmpty {
            warnings.append(AdapterKit.unsupported("--add-dir", adapter: self, field: "Extra directories"))
        }

        let structured: [String: Bool] = ["--model": true, "--effort": true, "--permission-mode": true, "--session-id": true]
        let filter = ExtraArgsFilter(structured: structured)
        let filtered = filter.apply(launch.extraArgs, adapterName: displayName) { name in
            switch name {
            case "--model": launch.model?.isEmpty == false
            case "--effort": launch.effort?.isEmpty == false
            case "--permission-mode": profile.contains("--permission-mode") || profile.contains("--dangerously-skip-permissions")
            case "--session-id": identity.first == "--session-id"
            default: false
            }
        }
        warnings += filtered.warnings
        profile += filtered.kept.filter { !($0 == "--dangerously-skip-permissions" && profile.contains($0)) }
        for token in filtered.kept where Self.hookKillers.contains(token) {
            warnings.append(LaunchWarning(.hooksDisabledByFlag, "Activity status is unavailable with \(token)"))
        }

        // Prompt só no primeiro start (resume nunca repete).
        // Injeções por lançamento (Fatia 2): regeneradas idênticas em start e resume; nunca em `~/.claude`.
        var injected: [String] = []
        var files: [LaunchFile] = []
        if let injection = context.injection {
            let built = try injection.claudeInjection(launchDirectory: context.launchDirectory)
            injected = built.injected
            files += built.files
        }

        var prompt: [String] = []
        if !resuming {
            let delivery = PromptDelivery.resolve(prompt: launch.initialPrompt, promptFile: launch.initialPromptFile, launchDirectory: context.launchDirectory)
            if let text = delivery.argumentText {
                // `--add-dir`, `--allowedTools`, `--mcp-config` etc. são variádicos no Claude: sem `--` engoliriam o prompt.
                if !launch.addDirs.isEmpty || !filtered.kept.isEmpty || injected.contains("--mcp-config") || injected.contains("--plugin-dir") { prompt.append("--") }
                prompt.append(text)
            }
            files += delivery.files
        }

        let argv = ResolvedArgv(executable: [context.executablePath], identity: identity, profile: profile, injected: injected, prompt: prompt)
        return AdapterOutput(
            argv: argv, nativeConversationID: nativeID, capture: capture,
            skipsPermissions: AdapterKit.skipIndicator(in: profile), warnings: warnings, files: files
        )
    }
}
