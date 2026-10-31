import RackyCore
import RackyDocker
import RackyProtocol
import RackyStore
import Foundation
import Synchronization
import Testing

@testable import RackyStore
@testable import RackyUI

/// Checklist de diagnóstico do onboarding (T2-09, AC-102…104, 112…115): sondas falsas, nada de `gh`, Docker nem configs reais.
@MainActor
@Suite(.serialized, .offscreenAppKit) struct OnboardingDiagnosticsTests {
    nonisolated final class Pasted: Sendable {
        private let state = Mutex<[String]>([])
        func add(_ s: String) { state.withLock { $0.append(s) } }
        var all: [String] { state.withLock { $0 } }
    }

    nonisolated final class Counter: Sendable {
        private let state = Mutex(0)
        func bump() { state.withLock { $0 += 1 } }
        var value: Int { state.withLock { $0 } }
    }

    private func probes(
        gh: GitHubProbeResult = GitHubProbeResult(installed: true, version: "2.60.1", auth: GitHubAuthStatus(state: .notLoggedIn, host: "github.com")),
        docker: DockerProbeResult = .installedNotRunning(kind: .desktop), findings: [ConflictFinding] = [],
        choice: ConflictChoiceBox = ConflictChoiceBox(), hasBackup: @escaping @Sendable () -> Bool = { false },
        ghCalls: Counter? = nil
    ) -> DiagnosticsProbes {
        DiagnosticsProbes(
            gh: { ghCalls?.bump(); return gh }, docker: { docker }, image: { _ in .missing },
            conflicts: { ConflictScan(findings: findings, choice: choice.value, hasBackup: hasBackup()) })
    }

    private let skill = ConflictFinding(kind: .globalSkill, provider: .claude, path: "~/.claude/skills/racky", message: "A global \"racky\" skill is installed and may compete with Racky tools.")
    private let notify = ConflictFinding(kind: .notify, provider: .codex, path: "~/.codex/config.toml", message: "Codex notify is used by another app (left untouched).")

    private func make(
        _ probes: DiagnosticsProbes, slice: ReleaseSlice = .slice3, choice: ConflictChoiceBox = ConflictChoiceBox(), backup: GlobalSkillBackup? = nil
    ) throws -> (OnboardingModel, ActionRegistry, Pasted) {
        let flags = SliceFlags(current: slice)
        let settings = SettingsModel(flags: flags, probe: SettingsModelTests.stub())
        let model = OnboardingModel(settings: settings, diagnostics: DiagnosticsEngine(probes: probes), conflictChoice: choice, backup: backup)
        let pasted = Pasted()
        model.copyToPasteboard = { pasted.add($0) }
        let registry = ActionRegistry(flags: flags, surface: FakeSurface())
        try settings.registerActions(in: registry)
        try model.registerActions(in: registry)
        return (model, registry, pasted)
    }

    @Test func everyRowHasStateReasonAndAtMostOnePrimaryAction() async throws {
        let (model, _, _) = try make(probes(findings: [skill, notify]))
        await model.runDiagnostics(force: false)
        #expect(model.diagnosticItems.map(\.key) == [.gh, .docker, .image, .conflicts])
        for item in model.diagnosticItems {
            #expect(!item.detail.isEmpty && item.state != .checking, "\(item.key): estado e motivo")
            #expect(!item.detail.contains("\n"), "\(item.key): uma linha")
        }
        #expect(model.diagnostics[.gh]?.fix == .logIn(["gh", "auth", "login"]))
        #expect(model.diagnostics[.docker]?.fix == .startDocker)
        #expect(model.diagnostics[.image]?.state == .neutral, "a imagem espera o Docker")
    }

    @Test func slice1HidesWhatLaterSlicesAdd() async throws {
        let (model, _, _) = try make(probes(findings: [notify]), slice: .slice1)
        await model.runDiagnostics(force: false)
        #expect(model.diagnosticItems.map(\.key) == [.conflicts], "gh desde a Fatia 2, Docker e imagem desde a 3; conflitos sempre que houver")
        let (slice2, _, _) = try make(probes(), slice: .slice2)
        await slice2.runDiagnostics(force: false)
        #expect(slice2.diagnosticItems.map(\.key) == [.gh])
    }

    @Test func withoutAnEngineTheChecklistIsJustTheAgents() async {
        let model = OnboardingModel(settings: SettingsModel(flags: SliceFlags(current: .slice3), probe: SettingsModelTests.stub()))
        await model.runDiagnostics(force: true)
        #expect(model.diagnosticItems.isEmpty)
    }

    @Test func logInFallsBackToCopyCommandWithoutATerminalPane() async throws {
        let (model, registry, pasted) = try make(probes())
        await model.runDiagnostics(force: false)
        #expect(model.effective(.logIn(["gh", "auth", "login"])) == .copyCommand("gh auth login"))
        _ = try await registry.perform(.onboardingCopyCommand, .select("gh"))
        #expect(pasted.all == ["gh auth login"])
    }

    @Test func logInRunsGhAuthLoginInTheInlineTerminalAndRechecks() async throws {
        let calls = Counter()
        let loggedIn = Mutex(false)
        let live = DiagnosticsProbes(
            gh: {
                calls.bump()
                let auth = loggedIn.withLock { $0 }
                    ? GitHubAuthStatus(state: .connected, host: "github.com", user: "me", scopes: ["repo"])
                    : GitHubAuthStatus(state: .notLoggedIn, host: "github.com")
                return GitHubProbeResult(installed: true, version: "2.60.1", auth: auth)
            },
            docker: { .notInstalled }, image: { _ in nil }, conflicts: { ConflictScan() })
        let (model, registry, _) = try make(live)
        let ran = Pasted()
        model.loginLauncher = { provider, command in
            ran.add("\(provider.rawValue):" + command.joined(separator: " "))
            loggedIn.withLock { $0 = true }
        }
        await model.runDiagnostics(force: false)
        #expect(model.effective(.logIn(["gh", "auth", "login"])) == .logIn(["gh", "auth", "login"]))
        _ = try await registry.perform(.accountLogIn, .select("gh"))
        #expect(ran.all == ["shell:gh auth login"])
        #expect(model.diagnostics[.gh]?.state == .ok, "ao fim do login o item vira Logged in sem reiniciar o onboarding (AC-104)")
        #expect(calls.value == 2)
    }

    @Test func retryRerunsOnlyThatItemIgnoringTheCache() async throws {
        let ghCalls = Counter()
        let (model, registry, _) = try make(probes(ghCalls: ghCalls))
        await model.runDiagnostics(force: false)
        await model.runDiagnostics(force: false)
        #expect(ghCalls.value == 1, "cache")
        _ = try await registry.perform(.onboardingRetry, .select("gh"))
        #expect(ghCalls.value == 2)
        await #expect(throws: ActionError.self) { try await registry.perform(.onboardingRetry, .select("nope")) }
    }

    @Test func checkAgainRefreshesAgentsAndDiagnosticsTogether() async throws {
        let ghCalls = Counter()
        let (model, registry, _) = try make(probes(ghCalls: ghCalls))
        await model.runDiagnostics(force: false)
        _ = try await registry.perform(.agentDetect, .press)
        #expect(ghCalls.value == 2)
    }

    @Test func installHelpOpensTheGhAndDockerPages() async throws {
        let opened = Pasted()
        let flags = SliceFlags(current: .slice3)
        let system = SettingsSystemActions(openURL: { opened.add($0.absoluteString) })
        let settings = SettingsModel(flags: flags, probe: SettingsModelTests.stub(), system: system)
        let registry = ActionRegistry(flags: flags, surface: FakeSurface())
        try settings.registerActions(in: registry)
        _ = try await registry.perform(.agentInstallHelp, .select("gh"))
        _ = try await registry.perform(.agentInstallHelp, .select("docker"))
        #expect(opened.all == ["https://cli.github.com", "https://www.docker.com/products/docker-desktop/"])
    }

    // MARK: Conflitos (AC-113, AC-114)

    @Test func informationOnlyConflictsOfferNoAction() async throws {
        let hooks = ConflictFinding(kind: .hooks, provider: .claude, path: "~/.claude/settings.json", message: "Hooks from Orca in ~/.claude/settings.json run alongside Racky's (left untouched).")
        let (model, _, _) = try make(probes(findings: [hooks, notify]))
        await model.runDiagnostics(force: false)
        let item = try #require(model.diagnostics[.conflicts])
        #expect(item.fix == nil && item.secondaryFixes.isEmpty)
        #expect(item.notes.count == 2)
    }

    @Test func blockAndKeepArePersistedAndNeverTouchTheGlobalFolder() async throws {
        let home = try SettingsModelTests.tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = try await SettingsModelTests.openStore(home)
        let choice = ConflictChoiceBox()
        let (model, registry, _) = try make(probes(findings: [skill], choice: choice), choice: choice)
        await model.attach(store: store)
        await model.runDiagnostics(force: false)
        #expect(model.diagnostics[.conflicts]?.fix == .blockSkill)
        _ = try await registry.perform(.conflictBlock, .press)
        #expect(choice.value == .block && model.diagnostics[.conflicts]?.state == .ok)
        _ = try await registry.perform(.conflictKeep, .press)
        #expect(choice.value == .keep && model.diagnostics[.conflicts]?.state == .neutral)
        try await store.close()

        let again = try await SettingsModelTests.openStore(home)
        let reopened = ConflictChoiceBox()
        let (second, _, _) = try make(probes(findings: [skill], choice: reopened), choice: reopened)
        await second.attach(store: again)
        #expect(reopened.value == .keep, "a escolha sobrevive ao reinício")
        try await again.close()
    }

    @Test func disableGloballyAsksFirstThenMovesToBackupAndRestoreUndoes() async throws {
        let home = try SettingsModelTests.tempHome()
        let support = try SettingsModelTests.tempHome()
        defer { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: support) }
        let skillDir = home.appendingPathComponent(".claude/skills/racky", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try "# skill".write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let backup = GlobalSkillBackup(home: home, backupRoot: support)
        let scanner = GlobalConfigScanner(home: home)
        let live = DiagnosticsProbes(
            gh: { GitHubProbeResult(installed: false) }, docker: { .notInstalled }, image: { _ in nil },
            conflicts: { ConflictScan(findings: scanner.scan(), hasBackup: backup.hasBackup) })
        let (model, registry, _) = try make(live, backup: backup)
        await model.runDiagnostics(force: false)

        _ = try await registry.perform(.conflictDisableGlobal, .press)
        #expect(model.confirmingDisable && FileManager.default.fileExists(atPath: skillDir.path), "o primeiro clique só pergunta")
        _ = try await registry.perform(.conflictDisableGlobal, .select("cancel"))
        #expect(!model.confirmingDisable && FileManager.default.fileExists(atPath: skillDir.path))

        _ = try await registry.perform(.conflictDisableGlobal, .press)
        _ = try await registry.perform(.conflictDisableGlobal, .select("confirm"))
        #expect(!FileManager.default.fileExists(atPath: skillDir.path) && backup.hasBackup)
        #expect(model.diagnostics[.conflicts]?.fix == .restoreSkill)

        _ = try await registry.perform(.conflictRestore, .press)
        #expect(FileManager.default.fileExists(atPath: skillDir.appendingPathComponent("SKILL.md").path) && !backup.hasBackup)
        #expect(model.diagnostics[.conflicts]?.fix == .blockSkill)
    }

    @Test func restoreIsDisabledWithAReasonWhenThereIsNoBackup() async throws {
        let support = try SettingsModelTests.tempHome()
        defer { try? FileManager.default.removeItem(at: support) }
        let (model, registry, _) = try make(probes(), backup: GlobalSkillBackup(home: support, backupRoot: support))
        #expect(registry.availability(of: .conflictRestore) == .disabled(reason: "There's no backup to restore."))
        withExtendedLifetime(model) {}
    }

    // MARK: Runtime nativo: sem Docker na checklist

    private func nativeProbes(_ mode: ComputerRuntimeMode, dockerCalls: Counter) -> DiagnosticsProbes {
        DiagnosticsProbes(
            gh: { GitHubProbeResult(installed: true, version: "2.60.1", auth: GitHubAuthStatus(state: .connected, host: "github.com", user: "me", scopes: ["repo"])) },
            docker: { dockerCalls.bump(); return .installedNotRunning(kind: .desktop) }, image: { _ in dockerCalls.bump(); return .missing },
            conflicts: { ConflictScan() }, runtime: { mode })
    }

    @Test func withTheNativeRuntimeTheChecklistNeverMentionsDocker() async throws {
        let dockerCalls = Counter()
        let (model, _, _) = try make(nativeProbes(.native(assetsInstalled: false), dockerCalls: dockerCalls))
        await model.runDiagnostics(force: false)
        #expect(model.diagnosticItems.map(\.key) == [.gh, .runtime])
        #expect(dockerCalls.value == 0)
        #expect(model.diagnostics[.runtime]?.detail == "Downloads automatically on first use (~470 MB)")
        for item in model.diagnosticItems {
            #expect(!"\(item.title) \(item.detail)".localizedCaseInsensitiveContains("docker"))
            if let fix = item.fix { #expect(fix != .startDocker) }
        }
    }

    @Test func aMacThatCannotRunNativelyExplainsTheRequirement() async throws {
        let mode = ComputerRuntimeMode.dockerOnly(reason: "The built-in computer runtime needs macOS 26 or later.")
        let (model, _, _) = try make(DiagnosticsProbes(
            gh: { GitHubProbeResult(installed: false) }, docker: { .notInstalled }, image: { _ in nil }, conflicts: { ConflictScan() }, runtime: { mode }))
        await model.runDiagnostics(force: false)
        #expect(model.diagnosticItems.map(\.key) == [.gh, .docker, .image])
        #expect(model.diagnostics[.docker]?.detail == "Racky needs macOS 26 on Apple silicon, or Docker.")
    }

    @Test func forcedDockerShowsDockerAndImage() async throws {
        let (model, _, _) = try make(nativeProbes(.dockerForced, dockerCalls: Counter()))
        await model.runDiagnostics(force: false)
        #expect(model.diagnosticItems.map(\.key) == [.gh, .docker, .image])
    }

    // MARK: ComputerRuntimeProbe (a decisão real, com Mac e ambiente injetados)

    private let tahoe = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
    private let sequoia = OperatingSystemVersion(majorVersion: 15, minorVersion: 6, patchVersion: 0)
    private let root = URL(fileURLWithPath: "/tmp/racky-runtime-probe-test")

    @Test func runtimeProbeChoosesNativeOnASupportedMacAndReportsTheDownloadState() {
        func mode(installed: Bool, force: Bool = false, env: [String: String] = [:]) -> ComputerRuntimeMode {
            ComputerRuntimeProbe.mode(
                environment: env, supportRoot: root, forceDocker: force, entitled: true, osVersion: tahoe, appleSilicon: true,
                assetsInstalled: { $0.readyFile.path == root.appendingPathComponent("vz/assets/ready.json").path && installed })
        }
        #expect(mode(installed: false) == .native(assetsInstalled: false))
        #expect(mode(installed: true) == .native(assetsInstalled: true))
        #expect(mode(installed: true, force: true) == .dockerForced)
        #expect(mode(installed: true, env: ["RACKY_COMPUTER_RUNTIME": "docker"]) == .dockerForced)
    }

    @Test func runtimeProbeFallsBackToDockerOnlyWhenTheMacCannotRunNatively() {
        let old = ComputerRuntimeProbe.mode(environment: [:], supportRoot: root, forceDocker: false, entitled: true, osVersion: sequoia, appleSilicon: true, assetsInstalled: { _ in false })
        let intel = ComputerRuntimeProbe.mode(environment: [:], supportRoot: root, forceDocker: false, entitled: true, osVersion: tahoe, appleSilicon: false, assetsInstalled: { _ in false })
        let unsigned = ComputerRuntimeProbe.mode(environment: [:], supportRoot: root, forceDocker: false, entitled: false, osVersion: tahoe, appleSilicon: true, assetsInstalled: { _ in false })
        for mode in [old, intel, unsigned] {
            guard case .dockerOnly = mode else { Issue.record("esperava dockerOnly, veio \(mode)"); continue }
        }
    }
}
