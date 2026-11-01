import RackyProtocol
import Foundation

/// Plano de um start, regerado a cada start ou resume a partir do `LaunchSpec` (06 §2.1). Nunca é comparado com o
/// `resolvedArgv` antigo (que só serve de diagnóstico).
public struct LaunchPlan: Sendable, Equatable {
    public var provider: TerminalProvider
    public var argv: ResolvedArgv
    /// `argv.flattened`: o que o daemon executa (`executable + identity + profile + injected + prompt`).
    public var flattenedArgv: [String] { argv.flattened }
    public var environment: [String: String]
    /// Só os nomes (vai para `terminal.env_keys`; nunca valores).
    public var envKeys: [String]
    public var cwd: String
    /// ID nativo a gravar em `terminal.native_conversation_id` ANTES do spawn (Claude `--session-id`, ou o ID retomado).
    public var nativeConversationID: String?
    public var capture: NativeIDCaptureStrategy
    /// `ShieldOff` no pane e na tab sempre que não for `nil`.
    public var skipsPermissions: SkipPermissionsIndicator?
    public var warnings: [LaunchWarning]
    /// Arquivos a criar em `launchDirectory` (prompt longo), via `LaunchFileWriter`.
    public var files: [LaunchFile]
    public var launchDirectory: URL
    /// Perfil efetivo (snapshot para `LaunchRequest`).
    public var profile: LaunchProfile?
    /// O `LaunchSpec` com o ID nativo preenchido, para persistir no `launch_spec_json`.
    public var spec: LaunchSpec
}

public struct LaunchPlanInput: Sendable {
    public var spec: LaunchSpec
    public var terminalID: UUID
    public var runID: UUID
    public var cwd: String
    public var projectID: UUID?
    /// `Terminal.addDirs`, somados aos do perfil.
    public var terminalAddDirs: [String]
    public var catalog: ProfileCatalog
    /// Executável resolvido (`CLIProber`/`CLIExecutableResolver`).
    public var executablePath: String
    public var capabilities: CLICapabilities?
    /// Env do `LoginShellEnvProvider` (`captured.variables`), antes da composição.
    public var loginEnvironment: [String: String]
    /// `AB/run/launch/<runID>/`.
    public var launchDirectory: URL
    public var mode: LaunchMode
    public var slice: LaunchSlice
    public var appVersion: String
    public var appSocketPath: String
    /// Conteúdo das injeções por lançamento. Só vale quando `slice >= .slice2` (feature flag de fatia).
    public var injection: LaunchInjection?

    public init(
        spec: LaunchSpec, terminalID: UUID, runID: UUID, cwd: String, projectID: UUID? = nil, terminalAddDirs: [String] = [],
        catalog: ProfileCatalog = ProfileCatalog(), executablePath: String, capabilities: CLICapabilities? = nil,
        loginEnvironment: [String: String], launchDirectory: URL, mode: LaunchMode = .automatic, slice: LaunchSlice = .slice1,
        appVersion: String = "0.0.0", appSocketPath: String, injection: LaunchInjection? = nil
    ) {
        self.injection = injection
        self.spec = spec; self.terminalID = terminalID; self.runID = runID; self.cwd = cwd; self.projectID = projectID
        self.terminalAddDirs = terminalAddDirs; self.catalog = catalog; self.executablePath = executablePath
        self.capabilities = capabilities; self.loginEnvironment = loginEnvironment; self.launchDirectory = launchDirectory
        self.mode = mode; self.slice = slice; self.appVersion = appVersion; self.appSocketPath = appSocketPath
    }
}

/// `LaunchSpec` + perfil + env de login → `LaunchPlan` (argv por segmentos, env, arquivos de apoio). Puro e síncrono:
/// não toca disco nem processo, e jamais escreve no PTY (T11).
public enum LaunchPlanner {
    public static func plan(_ input: LaunchPlanInput, newUUID: @escaping @Sendable () -> UUID = { UUID() }) throws -> LaunchPlan {
        let spec = input.spec
        let adapter = ProviderAdapters.adapter(for: spec.provider)
        let profile = input.catalog.resolve(provider: spec.provider, explicitID: spec.profileID, projectID: input.projectID)
        let launch = merge(spec: spec, profile: profile, terminalAddDirs: input.terminalAddDirs)

        var mode = input.mode
        if mode == .automatic, let resumeOf = spec.resumeOf, !resumeOf.isEmpty { mode = .resume(nativeID: resumeOf) }

        let context = AdapterContext(
            executablePath: input.executablePath, cwd: input.cwd, runID: input.runID, terminalID: input.terminalID,
            launchDirectory: input.launchDirectory, mode: mode, environment: input.loginEnvironment, newUUID: newUUID,
            injection: input.slice >= .slice2 ? input.injection : nil
        )
        let capabilities = input.capabilities ?? CLICapabilities.baseline(for: adapter)
        let output = try adapter.build(launch, context: context, capabilities: capabilities)
        let violations = InjectionValidator.violations(injected: output.argv.injected, launchDirectory: input.launchDirectory, slice: input.slice)
        if let first = violations.first { throw LaunchPlanError.injectionViolation(first) }

        let composer = LaunchEnvironmentComposer(appVersion: input.appVersion, appSocketPath: input.appSocketPath)
        // Env por lançamento do Claude (CS-325: limite de subagentes; CS-310: agent teams desligado, sem a variável do shell de login).
        let claudeInjection = (spec.provider == .claude && input.slice >= .slice2) ? input.injection : nil
        var captured = input.loginEnvironment
        for name in claudeInjection?.claudeUnsetEnvironment ?? [] { captured[name] = nil }
        let composed = composer.compose(
            captured: captured, terminalID: input.terminalID, runID: input.runID,
            profileEnv: launch.env, overrides: (claudeInjection?.claudeEnvironment ?? [:]).merging(output.environment) { _, new in new }
        )

        var updated = spec
        updated.profileID = profile?.id ?? spec.profileID
        if let id = output.nativeConversationID, spec.provider == .claude || spec.provider == .codex || spec.provider == .opencode {
            if case .resume = mode { updated.resumeOf = id } else { updated.nativeSessionID = id }
        }

        return LaunchPlan(
            provider: spec.provider, argv: output.argv, environment: composed.env,
            envKeys: composed.env.keys.sorted(), cwd: input.cwd, nativeConversationID: output.nativeConversationID,
            capture: output.capture, skipsPermissions: output.skipsPermissions,
            warnings: output.warnings + composed.warnings, files: output.files,
            launchDirectory: input.launchDirectory, profile: profile, spec: updated
        )
    }

    /// Campos do spec vencem os do perfil; `extraArgs` somam (perfil primeiro); env: perfil, depois `envOverrides`.
    static func merge(spec: LaunchSpec, profile: LaunchProfile?, terminalAddDirs: [String]) -> EffectiveLaunch {
        var addDirs: [String] = []
        for dir in (profile?.addDirs ?? []) + terminalAddDirs where !addDirs.contains(dir) { addDirs.append(dir) }
        var env = profile?.env ?? [:]
        for (name, value) in spec.envOverrides { env[name] = value }
        return EffectiveLaunch(
            provider: spec.provider,
            model: nonEmpty(spec.model) ?? nonEmpty(profile?.model),
            effort: nonEmpty(spec.effort) ?? nonEmpty(profile?.effort),
            permissionMode: nonEmpty(spec.permissionMode) ?? nonEmpty(profile?.permissionMode),
            addDirs: addDirs,
            extraArgs: (profile?.extraArgs ?? []) + spec.extraArgs,
            env: env, customArgv: spec.customArgv,
            initialPrompt: spec.initialPrompt, initialPromptFile: spec.initialPromptFile,
            nativeSessionID: spec.nativeSessionID, profile: profile
        )
    }

    private static func nonEmpty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
}
