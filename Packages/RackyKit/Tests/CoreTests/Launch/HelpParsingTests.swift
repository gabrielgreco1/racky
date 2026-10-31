import RackyProtocol
import Foundation
import Testing

@testable import RackyCore

/// Parse de `--version` e `--help` reais (fixtures gravados em 2026-10-17 das versões instaladas) e capabilities por versão.
@Suite struct HelpParsingTests {
    @Test(arguments: [
        ("2.1.302 (Claude Code)", CLIVersion(2, 1, 302)),
        ("codex-cli 0.163.0", CLIVersion(0, 163, 0)),
        ("1.18.34", CLIVersion(1, 18, 34)),
        ("v3.4", CLIVersion(3, 4, 0)),
        ("opencode 1.2.3-beta.1", CLIVersion(1, 2, 3)),
    ])
    func parsesVersions(text: String, expected: CLIVersion) {
        #expect(CLIVersion.parse(text) == expected)
    }

    @Test func rejectsTextWithoutVersion() {
        #expect(CLIVersion.parse("command not found") == nil)
        #expect(CLIVersion.parse("") == nil)
    }

    @Test func versionOrdering() {
        #expect(CLIVersion(2, 1, 302) > CLIVersion(2, 1, 99))
        #expect(CLIVersion(0, 163, 0) > CLIVersion(0, 160, 0))
        #expect(CLIVersion(1, 0, 0) > CLIVersion(0, 999, 999))
    }

    @Test func versionFixturesMatchInstalledVersions() {
        #expect(CLIVersion.parse(LaunchFixtures.text("claude-2.1.302.version.txt")) == CLIVersion(2, 1, 302))
        #expect(CLIVersion.parse(LaunchFixtures.text("codex-0.163.0.version.txt")) == CLIVersion(0, 163, 0))
        #expect(CLIVersion.parse(LaunchFixtures.text("opencode-1.18.34.version.txt")) == CLIVersion(1, 18, 34))
    }

    @Test func claudeHelp() {
        let help = HelpParser.parse(LaunchFixtures.text("claude-2.1.302.help.txt"))
        #expect(help.isUsable)
        for flag in ["--session-id", "--resume", "-r", "--continue", "-c", "--model", "--effort", "--permission-mode",
                     "--dangerously-skip-permissions", "--add-dir", "--settings", "--mcp-config", "--plugin-dir", "--agents", "--agent",
                     "--allowedTools", "--allowed-tools", "-n", "--name", "--bare", "--safe-mode", "--fallback-model"] {
            #expect(help.flags.contains(flag), "claude help should list \(flag)")
        }
        #expect(!help.flags.contains("--no-daemon"))
    }

    @Test func codexHelpAndResumeHelp() {
        let help = HelpParser.parse(LaunchFixtures.text("codex-0.163.0.help.txt"))
        #expect(help.isUsable)
        for flag in ["-c", "--config", "-m", "--model", "-s", "--sandbox", "-a", "--ask-for-approval", "--add-dir", "--no-alt-screen",
                     "--no-daemon", "--dangerously-bypass-approvals-and-sandbox", "--dangerously-bypass-hook-trust", "--worktree", "--remote"] {
            #expect(help.flags.contains(flag), "codex help should list \(flag)")
        }
        #expect(help.subcommands.isSuperset(of: ["resume", "fork", "exec", "login"]))
        let resume = HelpParser.parse(LaunchFixtures.text("codex-0.163.0.resume.help.txt"))
        // O subcomando `resume` aceita as mesmas flags do adapter: por isso `identity` vem antes de `profile`.
        #expect(resume.flags.isSuperset(of: ["--no-daemon", "--add-dir", "-m", "-c", "-s", "-a", "--last",
                                             "--dangerously-bypass-approvals-and-sandbox", "--no-alt-screen"]))
    }

    @Test func openCodeHelp() {
        let help = HelpParser.parse(LaunchFixtures.text("opencode-1.18.34.help.txt"))
        #expect(help.isUsable)
        #expect(help.flags.isSuperset(of: ["--prompt", "-s", "--session", "-c", "--continue", "-m", "--model", "--agent", "--auto", "--fork"]))
        #expect(help.subcommands.isSuperset(of: ["session", "providers", "run", "serve"]))
    }

    @Test func descriptionTextDoesNotLeakFlags() {
        // `--print` só é citado em descrições recuadas do Claude (ex.: "(only works with --print)"), não é opção própria da linha.
        let help = HelpParser.parse("Usage: x\n\nOptions:\n  --alpha <v>        Use with --beta only\n      continued --gamma text\n  -h, --help   help\n")
        #expect(help.flags == ["--alpha", "-h", "--help"])
    }

    @Test func garbageHelpIsNotUsable() {
        #expect(!HelpParser.parse("error: unknown option '--help'").isUsable)
        #expect(!HelpParser.parse("").isUsable)
    }

    // MARK: capabilities

    @Test func helpWinsOverTable() {
        let adapter = ClaudeAdapter()
        let caps = LaunchSamples.helpCapabilities(.claude)
        #expect(caps.source == .help)
        #expect(caps.supports("--effort"))
        let without = LaunchSamples.helpCapabilities(.claude, removing: ["--effort"])
        #expect(!without.supports("--effort"))
        #expect(CLICapabilities.unsupportedReason(flag: "--effort", adapter: adapter) == "Requires Claude Code ≥ 2.1.302")
        #expect(CLICapabilities.unsupportedReason(flag: "--model", adapter: adapter) == "Not supported by this version of Claude Code")
    }

    @Test func tableByVersionWhenHelpUnusable() {
        let adapter = CodexAdapter()
        let old = CLICapabilities.resolve(version: CLIVersion(0, 150, 0), help: nil, adapter: adapter)
        #expect(old.source == .versionTable)
        #expect(!old.supports("--no-daemon")) // piso 0.160.0 (S-05)
        #expect(old.supports("--add-dir"))
        #expect(old.supports(subcommand: "resume"))
        let current = CLICapabilities.resolve(version: CLIVersion(0, 163, 0), help: ParsedHelp(flags: ["--x"], subcommands: []), adapter: adapter)
        #expect(current.supports("--no-daemon"))
        let unknown = CLICapabilities.resolve(version: nil, help: nil, adapter: adapter)
        #expect(unknown.flags.isEmpty)
    }

    @Test func oldClaudeWithoutEffortDisablesTheOption() throws {
        let caps = CLICapabilities.resolve(version: CLIVersion(2, 0, 10), help: nil, adapter: ClaudeAdapter())
        let plan = try LaunchSamples.plan(LaunchSpec(provider: .claude, effort: "high", initialPrompt: "hello"), capabilities: caps)
        #expect(!plan.flattenedArgv.contains("--effort"))
        #expect(plan.warnings.contains { $0.code == .unsupportedFlag && $0.message.contains("Requires Claude Code") })
    }

    @Test func shellWordsTokenizer() throws {
        #expect(try ShellWords.split(#"npm run "my script" 'a b' c\ d"#) == ["npm", "run", "my script", "a b", "c d"])
        #expect(try ShellWords.split(#"echo $(rm -rf ~) `id`"#) == ["echo", "$(rm", "-rf", "~)", "`id`"]) // sem interpolação
        #expect(try ShellWords.split("") == [])
        #expect(try ShellWords.split(#"a "" b"#) == ["a", "", "b"])
        #expect(throws: ShellWords.Failure.unterminatedQuote) { try ShellWords.split(#"echo "oops"#) }
        #expect(throws: ShellWords.Failure.danglingEscape) { try ShellWords.split(#"echo oops\"#) }
    }
}
