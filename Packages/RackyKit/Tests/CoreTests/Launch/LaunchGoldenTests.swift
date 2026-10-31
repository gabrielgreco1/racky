import RackyProtocol
import Foundation
import Testing

@testable import RackyCore

/// Golden files de argv por adapter, perfil e fatia (AC-307, AC-308, AC-309; 06 §2.4.1).
/// Fatia 1: o segmento `injected` é sempre vazio, então o argv real é literalmente o esperado.
@Suite struct LaunchGoldenTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let spec: LaunchSpec
        var mode: LaunchMode = .automatic
        var capabilities: CLICapabilities?
        var profileCatalog = ProfileCatalog()
        var testDescription: String { name }
    }

    static let long40K = String(repeating: "0123456789abcdef", count: 2560) // 40 960 bytes
    static let tricky = "He said \"hi\" & 'bye'\nline2 $(rm -rf ~) `id` \\n ; | > emoji 👩🏽‍💻 日本語 *.swift"

    static var cases: [Case] {
        let claudeFull = LaunchSamples.helpCapabilities(.claude)
        let codexFull = LaunchSamples.helpCapabilities(.codex)
        let ocFull = LaunchSamples.helpCapabilities(.opencode)
        return [
            // Claude
            Case(name: "claude/default-bypass-hello", spec: LaunchSpec(provider: .claude, initialPrompt: "hello"), capabilities: claudeFull),
            Case(name: "claude/default-bypass-hello-baseline", spec: LaunchSpec(provider: .claude, initialPrompt: "hello")),
            Case(name: "claude/plan-profile-hello", spec: LaunchSpec(provider: .claude, profileID: BuiltinProfiles.claudePlan.id, initialPrompt: "hello"), capabilities: claudeFull),
            Case(name: "claude/no-prompt", spec: LaunchSpec(provider: .claude), capabilities: claudeFull),
            Case(name: "claude/model-effort-adddir-extra", spec: LaunchSpec(
                provider: .claude, model: "opus", permissionMode: "acceptEdits", effort: "high",
                extraArgs: ["--name", "work session"], initialPrompt: "hello"
            ), capabilities: claudeFull, profileCatalog: ProfileCatalog(userProfiles: [
                LaunchProfile(name: "Claude · Extra", provider: .claude, addDirs: ["/Users/example/shared", "/Users/example/docs dir"], isDefault: true)
            ])),
            Case(name: "claude/effort-unsupported", spec: LaunchSpec(provider: .claude, effort: "high", initialPrompt: "hello"),
                 capabilities: LaunchSamples.helpCapabilities(.claude, removing: ["--effort"])),
            Case(name: "claude/prompt-16kib-exact", spec: LaunchSpec(provider: .claude, initialPrompt: String(repeating: "a", count: 16 * 1024)), capabilities: claudeFull),
            Case(name: "claude/prompt-16kib-plus1", spec: LaunchSpec(provider: .claude, initialPrompt: String(repeating: "a", count: 16 * 1024 + 1)), capabilities: claudeFull),
            Case(name: "claude/prompt-40kb", spec: LaunchSpec(provider: .claude, initialPrompt: long40K), capabilities: claudeFull),
            Case(name: "claude/prompt-starts-with-dash", spec: LaunchSpec(provider: .claude, initialPrompt: "--help me"), capabilities: claudeFull),
            Case(name: "claude/prompt-special-chars", spec: LaunchSpec(provider: .claude, initialPrompt: tricky), capabilities: claudeFull),
            Case(name: "claude/resume-id", spec: LaunchSpec(provider: .claude, initialPrompt: "ignored on resume", resumeOf: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"), capabilities: claudeFull),
            Case(name: "claude/continue-last", spec: LaunchSpec(provider: .claude), mode: .continueLast, capabilities: claudeFull),
            Case(name: "claude/bare-extra-arg", spec: LaunchSpec(provider: .claude, extraArgs: ["--bare"], initialPrompt: "hello"), capabilities: claudeFull),
            // Codex
            Case(name: "codex/default-bypass-hello", spec: LaunchSpec(provider: .codex, initialPrompt: "hello"), capabilities: codexFull),
            Case(name: "codex/default-bypass-hello-baseline", spec: LaunchSpec(provider: .codex, initialPrompt: "hello")),
            Case(name: "codex/model-effort-sandbox", spec: LaunchSpec(provider: .codex, model: "gpt-5.6-luna", permissionMode: "workspace-write", effort: "low", initialPrompt: "hello"), capabilities: codexFull),
            Case(name: "codex/approval-never-adddir", spec: LaunchSpec(provider: .codex, model: "gpt-5.6-luna", permissionMode: "never", initialPrompt: "hello"), capabilities: codexFull,
                 profileCatalog: ProfileCatalog(userProfiles: [LaunchProfile(name: "Codex · Dirs", provider: .codex, addDirs: ["/Users/example/shared"], isDefault: true)])),
            Case(name: "codex/no-daemon-unavailable", spec: LaunchSpec(provider: .codex, initialPrompt: "hello"),
                 capabilities: LaunchSamples.helpCapabilities(.codex, removing: ["--no-daemon"])),
            Case(name: "codex/forbidden-extra-args", spec: LaunchSpec(provider: .codex, extraArgs: ["--dangerously-bypass-hook-trust", "--no-alt-screen", "--worktree"], initialPrompt: "hello"), capabilities: codexFull),
            Case(name: "codex/prompt-40kb", spec: LaunchSpec(provider: .codex, initialPrompt: long40K), capabilities: codexFull),
            Case(name: "codex/prompt-special-chars", spec: LaunchSpec(provider: .codex, initialPrompt: tricky), capabilities: codexFull),
            Case(name: "codex/resume-id", spec: LaunchSpec(provider: .codex, resumeOf: "01a147e5-72b7-7c52-a686-6e002673cc8b"), capabilities: codexFull),
            Case(name: "codex/resume-last", spec: LaunchSpec(provider: .codex), mode: .continueLast, capabilities: codexFull),
            // OpenCode
            Case(name: "opencode/default-hello", spec: LaunchSpec(provider: .opencode, initialPrompt: "hello"), capabilities: ocFull),
            Case(name: "opencode/model-auto", spec: LaunchSpec(provider: .opencode, model: "openai/gpt-5", permissionMode: "auto", effort: "high", initialPrompt: "hello"), capabilities: ocFull),
            Case(name: "opencode/prompt-40kb", spec: LaunchSpec(provider: .opencode, initialPrompt: long40K), capabilities: ocFull),
            Case(name: "opencode/prompt-special-chars", spec: LaunchSpec(provider: .opencode, initialPrompt: tricky), capabilities: ocFull),
            Case(name: "opencode/resume-id", spec: LaunchSpec(provider: .opencode, resumeOf: "ses_bbbbbbbbbbbbbbbbbbbbbbbb02"), capabilities: ocFull),
            Case(name: "opencode/continue-last", spec: LaunchSpec(provider: .opencode), mode: .continueLast, capabilities: ocFull),
            // Shell e comando livre
            Case(name: "shell/login", spec: LaunchSpec(provider: .shell, initialPrompt: "ignored")),
            Case(name: "custom/npm-run-dev", spec: LaunchSpec(provider: .custom, customArgv: ["npm", "run", "dev", "--", "--port=3000"])),
        ]
    }

    @Test(arguments: cases)
    func argvMatchesGolden(_ c: Case) throws {
        let plan = try LaunchSamples.plan(c.spec, mode: c.mode, capabilities: c.capabilities, catalog: c.profileCatalog)
        LaunchFixtures.assertGolden("slice1/\(c.name).golden", LaunchSamples.render(c.name, plan))
        // Regras do segmento injected à parte (06 §2.4.1 regra 2-3): Fatia 1 não injeta nada.
        #expect(plan.argv.injected.isEmpty)
        #expect(InjectionValidator.violations(injected: plan.argv.injected, launchDirectory: LaunchSamples.launchDirectory, slice: .slice1).isEmpty)
    }

    /// AC-307 literal: `claude --session-id <uuid> --dangerously-skip-permissions hello`.
    @Test func ac307ClaudeArgvExact() throws {
        let plan = try LaunchSamples.plan(LaunchSpec(provider: .claude, initialPrompt: "hello"))
        let id = LaunchSamples.fixedID.uuidString.lowercased()
        #expect(plan.flattenedArgv == ["/usr/local/bin/claude", "--session-id", id, "--dangerously-skip-permissions", "hello"])
        #expect(plan.nativeConversationID == id) // gravado antes do spawn
        #expect(plan.spec.nativeSessionID == id)
        #expect(plan.cwd == LaunchSamples.cwd)
        #expect(plan.skipsPermissions?.tooltip == "Skip permissions (--dangerously-skip-permissions)")
    }

    /// AC-309: `codex [flags do perfil] "<prompt>"` e `opencode [flags] --prompt "<prompt>"`.
    @Test func ac309CodexAndOpenCode() throws {
        let codex = try LaunchSamples.plan(LaunchSpec(provider: .codex, initialPrompt: "hello"), capabilities: LaunchSamples.helpCapabilities(.codex))
        #expect(codex.flattenedArgv == ["/usr/local/bin/codex", "--no-daemon", "--dangerously-bypass-approvals-and-sandbox", "hello"])
        let oc = try LaunchSamples.plan(LaunchSpec(provider: .opencode, initialPrompt: "hello"), capabilities: LaunchSamples.helpCapabilities(.opencode))
        #expect(oc.flattenedArgv == ["/usr/local/bin/opencode", "--prompt", "hello"])
        #expect(oc.skipsPermissions == nil)
    }
}
