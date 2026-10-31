import RackyProtocol
import Darwin
import Foundation
import Testing

@testable import RackyCore

@Suite struct PromptDeliveryTests {
    private func plan(_ provider: TerminalProvider, prompt: String) throws -> LaunchPlan {
        try LaunchSamples.plan(LaunchSpec(provider: provider, initialPrompt: prompt), capabilities: LaunchSamples.helpCapabilities(provider))
    }

    /// AC-308: 16 KiB vai no argv; 16 KiB + 1, 40 KB e curto com `-` vão para arquivo.
    @Test(arguments: [TerminalProvider.claude, .codex, .opencode])
    func thresholds(provider: TerminalProvider) throws {
        let promptPath = LaunchSamples.launchDirectory.appendingPathComponent("prompt.md").path

        let exact = String(repeating: "x", count: 16 * 1024)
        let p1 = try plan(provider, prompt: exact)
        #expect(p1.argv.prompt.last == exact)
        #expect(p1.files.isEmpty)

        for prompt in [String(repeating: "x", count: 16 * 1024 + 1), String(repeating: "y", count: 40_000), "-rf please", "--some-flag"] {
            let p = try plan(provider, prompt: prompt)
            #expect(p.argv.prompt.last == "Read and follow the task in \(promptPath)")
            let file = try #require(p.files.first)
            #expect(file.name == "prompt.md")
            #expect(file.posixMode == 0o600)
            #expect(file.contents == Data(prompt.utf8)) // sem truncar
            #expect(!p.flattenedArgv.contains(prompt))
        }
    }

    @Test func thresholdCountsUTF8BytesNotCharacters() throws {
        let emoji = String(repeating: "👩🏽‍💻", count: 1200) // poucos caracteres, muitos bytes
        #expect(emoji.utf8.count > 16 * 1024)
        let p = try plan(.claude, prompt: emoji)
        #expect(p.files.count == 1)
    }

    @Test(arguments: [TerminalProvider.claude, .codex, .opencode])
    func specialCharactersArriveLiterally(provider: TerminalProvider) throws {
        let prompts = [
            "He said \"hi\" and 'bye'", "multi\nline\r\nprompt\twith tab", "$(rm -rf ~) `id` ${HOME} $HOME",
            "a; b | c > d & e", "emoji 👩🏽‍💻 日本語 ñ", "back\\slash \\n literal", "*.swift ~ ! # %", "  leading and trailing  ",
        ]
        for prompt in prompts {
            let p = try plan(provider, prompt: prompt)
            #expect(p.argv.prompt.last == prompt, "prompt must be a single literal argument: \(prompt)")
            #expect(p.files.isEmpty)
        }
    }

    @Test func nulByteForcesFile() throws {
        let p = try plan(.codex, prompt: "a\u{0}b")
        #expect(p.files.count == 1)
        #expect(!p.flattenedArgv.contains { $0.utf8.contains(0) })
    }

    @Test func emptyPromptAddsNothing() throws {
        let p = try plan(.claude, prompt: "")
        #expect(p.argv.prompt.isEmpty)
        #expect(p.files.isEmpty)
    }

    @Test func resumeNeverRepeatsThePrompt() throws {
        for provider in [TerminalProvider.claude, .codex, .opencode] {
            let spec = LaunchSpec(provider: provider, initialPrompt: "do the thing", resumeOf: "abc-123")
            let p = try LaunchSamples.plan(spec, capabilities: LaunchSamples.helpCapabilities(provider))
            #expect(p.argv.prompt.isEmpty)
            #expect(!p.flattenedArgv.contains("do the thing"))
        }
    }

    @Test func promptFileFromSpecIsReferencedNotCopied() throws {
        var spec = LaunchSpec(provider: .claude)
        spec.initialPromptFile = "/Users/example/briefs/task.md"
        let p = try LaunchSamples.plan(spec)
        #expect(p.argv.prompt == ["Read and follow the task in /Users/example/briefs/task.md"])
        #expect(p.files.isEmpty)
    }

    @Test func writerCreatesPrivateFilesAndCleansUp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ab-launch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var input = LaunchSamples.input(LaunchSpec(provider: .claude, initialPrompt: String(repeating: "z", count: 40_000)))
        input.launchDirectory = root.appendingPathComponent("run/launch/\(LaunchSamples.runID.uuidString.lowercased())")
        let plan = try LaunchPlanner.plan(input, newUUID: { LaunchSamples.fixedID })
        try LaunchFileWriter.materialize(plan)
        let file = plan.launchDirectory.appendingPathComponent("prompt.md")
        func mode(_ url: URL) -> Int {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1
        }
        #expect(mode(plan.launchDirectory) == 0o700)
        #expect(mode(file) == 0o600)
        #expect(try Data(contentsOf: file).count == 40_000)
        LaunchFileWriter.cleanup(launchDirectory: plan.launchDirectory)
        #expect(!FileManager.default.fileExists(atPath: plan.launchDirectory.path))
    }
}

@Suite struct ProfileAndEnvTests {
    @Test func resolutionOrderTerminalProjectGlobalBuiltin() throws {
        let projectID = UUID()
        let global = LaunchProfile(name: "Global Claude", provider: .claude, model: "sonnet", isDefault: true)
        let project = LaunchProfile(name: "Project Claude", provider: .claude, model: "haiku", scope: .project, projectID: projectID, isDefault: true)
        let chosen = LaunchProfile(name: "Chosen", provider: .claude, model: "opus")
        let catalog = ProfileCatalog(userProfiles: [global, project, chosen])

        #expect(catalog.resolve(provider: .claude, explicitID: chosen.id, projectID: projectID)?.name == "Chosen")
        #expect(catalog.resolve(provider: .claude, explicitID: nil, projectID: projectID)?.name == "Project Claude")
        #expect(catalog.resolve(provider: .claude, explicitID: nil, projectID: UUID())?.name == "Global Claude")
        #expect(ProfileCatalog().resolve(provider: .claude, explicitID: nil, projectID: nil)?.name == "Claude · Default")
        // Perfil de outro provider é ignorado.
        #expect(catalog.resolve(provider: .codex, explicitID: chosen.id, projectID: nil)?.name == "Codex · Default")

        let plan = try LaunchSamples.plan(LaunchSpec(provider: .claude, initialPrompt: "hi"), catalog: catalog, projectID: projectID)
        #expect(plan.argv.profile == ["--model", "haiku"])
        #expect(plan.profile?.name == "Project Claude")
        #expect(plan.skipsPermissions == nil) // perfil do projeto não pula permissões
    }

    @Test func specFieldsOverrideProfileAndExtraArgsAdd() throws {
        let profile = LaunchProfile(name: "P", provider: .claude, model: "sonnet", effort: "low", extraArgs: ["--verbose"], env: ["A": "profile", "B": "profile"], isDefault: true)
        let spec = LaunchSpec(provider: .claude, model: "opus", extraArgs: ["--debug"], envOverrides: ["B": "spec"], initialPrompt: "hi")
        let plan = try LaunchSamples.plan(spec, capabilities: LaunchSamples.helpCapabilities(.claude), catalog: ProfileCatalog(userProfiles: [profile]))
        #expect(plan.argv.profile == ["--model", "opus", "--effort", "low", "--verbose", "--debug"])
        #expect(plan.environment["A"] == "profile")
        #expect(plan.environment["B"] == "spec")
    }

    @Test func relaunchWithKeepsIdentityAndChangesModel() throws {
        let first = try LaunchSamples.plan(LaunchSpec(provider: .claude, model: "sonnet", initialPrompt: "hi"))
        let id = try #require(first.nativeConversationID)
        var relaunch = first.spec
        relaunch.model = "opus"
        relaunch.initialPrompt = nil
        let second = try LaunchSamples.plan(relaunch, mode: .resume(nativeID: id))
        #expect(second.argv.identity == ["--resume", id])
        #expect(second.argv.profile.contains("opus"))
    }

    @Test func bypassDefaultsAreAlwaysFlagged() throws {
        for (provider, flag) in [(TerminalProvider.claude, "--dangerously-skip-permissions"), (.codex, "--dangerously-bypass-approvals-and-sandbox")] {
            let plan = try LaunchSamples.plan(LaunchSpec(provider: provider, initialPrompt: "x"))
            #expect(plan.skipsPermissions?.flag == flag)
            #expect(plan.flattenedArgv.contains(flag))
        }
        // Inclusive quando o bypass vem de extraArgs de um perfil importado/manual.
        let profile = LaunchProfile(name: "manual", provider: .claude, extraArgs: ["--dangerously-skip-permissions"], isDefault: true)
        let plan = try LaunchSamples.plan(LaunchSpec(provider: .claude), catalog: ProfileCatalog(userProfiles: [profile]))
        #expect(plan.skipsPermissions != nil)
        #expect(plan.flattenedArgv.filter { $0 == "--dangerously-skip-permissions" }.count == 1)
        // Perfis sem bypass não mostram o indicador.
        let planMode = try LaunchSamples.plan(LaunchSpec(provider: .claude, profileID: BuiltinProfiles.claudePlan.id))
        #expect(planMode.skipsPermissions == nil)
        #expect(BuiltinProfiles.skipPermissionsNotice == "Agents run without permission prompts. You can change this per profile.")
    }

    @Test func skipPermissionProfilesAreBuiltin() {
        #expect(BuiltinProfiles.claudeSkipPermissions.source == .manual)
        #expect(BuiltinProfiles.codexBypassApprovals.source == .manual)
        #expect(BuiltinProfiles.all.map(\.name).contains("Claude · Plan"))
    }

    @Test func extraArgsRepeatingStructuredFieldsWarnAndStructuredWins() throws {
        let spec = LaunchSpec(provider: .claude, model: "opus", extraArgs: ["--model", "haiku", "--effort=max", "--verbose"], initialPrompt: "hi")
        let plan = try LaunchSamples.plan(spec, capabilities: LaunchSamples.helpCapabilities(.claude))
        #expect(plan.argv.profile == ["--model", "opus", "--dangerously-skip-permissions", "--effort=max", "--verbose"])
        #expect(plan.warnings.filter { $0.code == .duplicateStructuredArg }.count == 1) // --effort sem campo estruturado passa
    }

    @Test func hookKillingFlagsWarn() throws {
        for flag in ["--bare", "--safe-mode"] {
            let plan = try LaunchSamples.plan(LaunchSpec(provider: .claude, extraArgs: [flag]))
            #expect(plan.warnings.contains { $0.code == .hooksDisabledByFlag && $0.message == "Activity status is unavailable with \(flag)" })
        }
    }

    @Test func invalidPermissionModesThrow() {
        #expect(throws: LaunchPlanError.invalidPermissionMode(provider: .claude, mode: "yolo")) {
            try LaunchSamples.plan(LaunchSpec(provider: .claude, permissionMode: "yolo"))
        }
        #expect(throws: LaunchPlanError.invalidPermissionMode(provider: .codex, mode: "plan")) {
            try LaunchSamples.plan(LaunchSpec(provider: .codex, permissionMode: "plan"))
        }
        #expect(throws: LaunchPlanError.missingCustomArgv) { try LaunchSamples.plan(LaunchSpec(provider: .custom)) }
    }

    @Test func environmentCompositionFollowsSpec() throws {
        let profile = LaunchProfile(name: "env", provider: .shell, env: ["MY_FLAG": "1", "RACKY_RUN_ID": "spoof2", "RACKY_PANE_ID": "spoof"], isDefault: true)
        let plan = try LaunchSamples.plan(LaunchSpec(provider: .shell), catalog: ProfileCatalog(userProfiles: [profile]))
        let env = plan.environment
        // 2. denylist
        for gone in ["KITTY_PANE_KEY", "CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION", "PWD"] { #expect(env[gone] == nil, "\(gone) must not reach the terminal") }
        // allowlist e o resto do shell de login passam
        #expect(env["SSH_AUTH_SOCK"] == "/private/tmp/agent.sock")
        #expect(env["HTTPS_PROXY"] == "http://proxy:3128")
        #expect(env["PATH"] == LaunchSamples.loginEnvironment["PATH"])
        // 3. variáveis do app
        #expect(env["TERM"] == "xterm-256color")
        #expect(env["COLORTERM"] == "truecolor")
        #expect(env["TERM_PROGRAM"] == "Racky")
        #expect(env["TERM_PROGRAM_VERSION"] == "1.0.0")
        #expect(env["LANG"] == "pt_BR.UTF-8")
        #expect(env["RACKY_PANE_ID"] == LaunchSamples.terminalID.uuidString.lowercased())
        #expect(env["RACKY_RUN_ID"] == LaunchSamples.runID.uuidString.lowercased())
        #expect(env["RACKY_APP_SOCK"] == "/tmp/ab/run/app.sock")
        #expect(Set(env.keys.filter { $0.hasPrefix("RACKY_") }) == ["RACKY_PANE_ID", "RACKY_RUN_ID", "RACKY_APP_SOCK"])
        // 4. perfil, sem RACKY_* (reservado)
        #expect(env["MY_FLAG"] == "1")
        #expect(plan.warnings.filter { $0.code == .reservedEnvDropped }.count == 2)
        #expect(plan.envKeys == env.keys.sorted())
    }

    @Test func langDefaultsWhenAbsent() throws {
        var input = LaunchSamples.input(LaunchSpec(provider: .shell))
        input.loginEnvironment["LANG"] = nil
        let plan = try LaunchPlanner.plan(input)
        #expect(plan.environment["LANG"] == "en_US.UTF-8")
    }

    @Test func shellUsesLoginShellFromEnvironment() throws {
        var input = LaunchSamples.input(LaunchSpec(provider: .shell))
        input.loginEnvironment["SHELL"] = "/opt/homebrew/bin/fish"
        input.executablePath = "/opt/homebrew/bin/fish"
        let plan = try LaunchPlanner.plan(input)
        #expect(plan.flattenedArgv == ["/opt/homebrew/bin/fish", "-l"])
        #expect(plan.capture == .none)
        #expect(plan.nativeConversationID == nil)
    }

    @Test func slicePolicyRejectsInjectionsInSlice1() {
        let dir = LaunchSamples.launchDirectory
        #expect(!InjectionValidator.violations(injected: ["--settings", "\(dir.path)/settings.json"], launchDirectory: dir, slice: .slice1).isEmpty)
        #expect(InjectionValidator.violations(injected: ["--settings", "\(dir.path)/settings.json", "--mcp-config", "\(dir.path)/mcp.json"], launchDirectory: dir, slice: .slice2).isEmpty)
        #expect(!InjectionValidator.violations(injected: ["--settings", "/Users/example/.claude/settings.json"], launchDirectory: dir, slice: .slice2).isEmpty)
        #expect(!InjectionValidator.violations(injected: ["--strict-mcp-config"], launchDirectory: dir, slice: .slice2).isEmpty)
    }

    @Test func planNeverTouchesGlobalConfigOrInjects() throws {
        // T10/P18: nenhum adapter da Fatia 1 emite --settings/--mcp-config/hooks/trust.
        for provider in [TerminalProvider.claude, .codex, .opencode, .shell] {
            let plan = try LaunchSamples.plan(LaunchSpec(provider: provider, initialPrompt: "hi"))
            let joined = plan.flattenedArgv.joined(separator: " ")
            for forbidden in ["--settings", "--mcp-config", "--plugin-dir", "--agents", "hooks", "trust", "--strict-mcp-config", "--dangerously-bypass-hook-trust"] {
                #expect(!joined.contains(forbidden), "\(provider) must not emit \(forbidden) in slice 1")
            }
        }
    }

    @Test func launchSpecPersistsNativeIDsForResume() throws {
        let first = try LaunchSamples.plan(LaunchSpec(provider: .claude, initialPrompt: "hi"))
        #expect(first.spec.nativeSessionID == first.nativeConversationID)
        let resumed = try LaunchSamples.plan(LaunchSpec(provider: .codex, resumeOf: "abc"))
        #expect(resumed.spec.resumeOf == "abc")
        #expect(resumed.nativeConversationID == "abc")
        // Sem ID, `Continue Last` avisa.
        let last = try LaunchSamples.plan(LaunchSpec(provider: .opencode), mode: .continueLast)
        #expect(last.warnings.contains { $0.code == .resumeWithoutID })
    }
}
