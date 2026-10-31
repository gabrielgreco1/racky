import RackyProtocol
import Foundation
import Testing

@testable import RackyCore

/// Edição de perfis de lançamento e configuração do app (T1-26): flags permitidas, bypass sinalizado, padrão por agente.
@Suite struct ProfileEditingTests {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)

    @Test func builtinSkipProfilesAreFlaggedAndOthersAreNot() {
        #expect(BuiltinProfiles.claudeDefault.skipsPermissions?.flag == "--dangerously-skip-permissions")
        #expect(BuiltinProfiles.codexDefault.skipsPermissions?.flag == "--dangerously-bypass-approvals-and-sandbox")
        #expect(BuiltinProfiles.claudeSkipPermissions.skipsPermissions != nil)
        #expect(BuiltinProfiles.claudePlan.skipsPermissions == nil)
        #expect(BuiltinProfiles.openCodeDefault.skipsPermissions == nil)
        #expect(BuiltinProfiles.shell.skipsPermissions == nil)
    }

    @Test func bypassInExtraArgsIsFlaggedToo() {
        let profile = LaunchProfile(name: "Sneaky", provider: .claude, extraArgs: ["--dangerously-skip-permissions"])
        #expect(profile.skipsPermissions?.tooltip == "Skip permissions (--dangerously-skip-permissions)")
    }

    @Test func permissionChoicesMarkEveryBypassMode() {
        for provider in [TerminalProvider.claude, .codex, .opencode] {
            let choices = ProfileOptions.permissionChoices(for: provider)
            #expect(choices.first?.id == "default")
            #expect(choices.contains { $0.skips }, "\(provider) needs a flagged bypass choice")
            for choice in choices where choice.skips {
                var profile = LaunchProfile(name: "p", provider: provider, permissionMode: choice.id)
                #expect(profile.skipsPermissions != nil)
                profile.permissionMode = "default"
                #expect(profile.skipsPermissions == nil)
            }
        }
        #expect(ProfileOptions.permissionChoices(for: .shell).isEmpty)
    }

    @Test func allowedFlagsExcludeIdentityAndStructuredFields() {
        let claude = Set(ProfileOptions.allowedExtraFlags(for: .claude).map(\.flag))
        #expect(claude.contains("--add-dir"))
        #expect(claude.contains("--dangerously-skip-permissions"))
        for blocked in ["--session-id", "--resume", "--continue", "--model", "--effort", "--permission-mode"] {
            #expect(!claude.contains(blocked))
        }
        let codex = Set(ProfileOptions.allowedExtraFlags(for: .codex).map(\.flag))
        #expect(codex.contains("--sandbox"))
        #expect(!codex.contains("--no-daemon"))
        #expect(!codex.contains("--last"))
    }

    @Test func extraArgsValidation() {
        #expect(ProfileOptions.validateExtraArgs("", for: .claude) == .valid([]))
        #expect(ProfileOptions.validateExtraArgs("--add-dir ../shared", for: .claude) == .valid(["--add-dir", "../shared"]))
        #expect(ProfileOptions.validateExtraArgs("--add-dir '/tmp/with space'", for: .claude) == .valid(["--add-dir", "/tmp/with space"]))
        #expect(ProfileOptions.validateExtraArgs("--bare", for: .claude) == .invalid("--bare isn't an allowed flag for Claude Code."))
        #expect(ProfileOptions.validateExtraArgs("--model=opus", for: .claude) == .invalid("--model isn't an allowed flag for Claude Code."))
        #expect(ProfileOptions.validateExtraArgs("--add-dir 'oops", for: .claude) == .invalid("Close the quotation mark."))
        #expect(ProfileOptions.validateExtraArgs("--dangerously-bypass-hook-trust", for: .codex) == .invalid("--dangerously-bypass-hook-trust isn't an allowed flag for Codex CLI."))
    }

    @Test func duplicateIsAnEditableUserCopy() {
        let copy = BuiltinProfiles.claudeSkipPermissions.duplicated(id: UUID(), now: now)
        #expect(copy.name == "Claude · Skip permissions copy")
        #expect(!copy.isDefault)
        #expect(copy.source == .manual)
        #expect(!copy.isBuiltin)
        #expect(copy.skipsPermissions != nil, "a copy keeps the bypass and the flag")
        #expect(BuiltinProfiles.claudeDefault.isBuiltin)
    }

    @Test func settingTheDefaultTurnsOffOthersAndCopiesBuiltins() {
        let mine = LaunchProfile(name: "Mine", provider: .claude, permissionMode: "plan", isDefault: true)
        // 1. Um perfil pronto vira o padrão: grava uma cópia com o mesmo ID e desliga o seu.
        let writes = ProfileDefaults.assigning(profileID: BuiltinProfiles.claudePlan.id, saved: [mine], now: now)
        #expect(writes.count == 2)
        #expect(writes.first { $0.id == mine.id }?.isDefault == false)
        #expect(writes.first { $0.id == BuiltinProfiles.claudePlan.id }?.isDefault == true)
        let catalog = ProfileCatalog(userProfiles: writes)
        #expect(catalog.resolve(provider: .claude, explicitID: nil, projectID: nil)?.id == BuiltinProfiles.claudePlan.id)
        // 2. Voltar para o pronto original: o catálogo cai no pronto quando nenhum salvo é padrão.
        let back = ProfileDefaults.assigning(profileID: BuiltinProfiles.claudeDefault.id, saved: writes, now: now)
        #expect(ProfileCatalog(userProfiles: back).resolve(provider: .claude, explicitID: nil, projectID: nil)?.id == BuiltinProfiles.claudeDefault.id)
        // Outro provider não é tocado.
        #expect(ProfileCatalog(userProfiles: back).resolve(provider: .codex, explicitID: nil, projectID: nil)?.id == BuiltinProfiles.codexDefault.id)
        #expect(ProfileDefaults.assigning(profileID: UUID(), saved: [], now: now).isEmpty)
    }

    // MARK: Configuração

    @Test func settingsDecodeToleratesMissingAndFutureKeys() throws {
        let empty = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(empty == AppSettings())
        let partial = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"terminal":{"fontSize":99},"general":{"askBeforeQuit":false},"future":1}"#.utf8))
        #expect(partial.terminal.fontSize == 32, "size is clamped on load")
        #expect(partial.general.askBeforeQuit == false)
        #expect(partial.general.keepAgentsRunning == true)
        #expect(AppSettings().general.worktreeFolder == "~/Racky/worktrees")
        #expect(AppSettings().general.cleanSessionFolder == "~/Racky/sessions")
    }

    @Test func settingsRoundTrip() throws {
        var s = AppSettings()
        s.terminal.cursor = .bar
        s.terminal.fontFamily = "Menlo"
        s.agents.defaultAgent = .codex
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }

    @Test func validation() {
        #expect(SettingsValidation.folder("~/Racky/worktrees/") == .success("~/Racky/worktrees"))
        #expect(SettingsValidation.folder("/tmp/x") == .success("/tmp/x"))
        #expect(SettingsValidation.folder("relative/path") == .failure(.init("Use an absolute path, starting with / or ~.")))
        #expect(SettingsValidation.folder("  ") == .failure(.init("Enter a folder path.")))
        #expect(SettingsValidation.fontSize("14") == .success(14))
        #expect(SettingsValidation.fontSize("7") == .failure(.init("Size must be between 8 and 32.")))
        #expect(SettingsValidation.fontSize("abc") == .failure(.init("Enter a number from 8 to 32.")))
        #expect(SettingsValidation.branchPrefix("alex/") == .success("alex/"))
        #expect(SettingsValidation.branchPrefix("a b") != .success("a b"))
    }
}
