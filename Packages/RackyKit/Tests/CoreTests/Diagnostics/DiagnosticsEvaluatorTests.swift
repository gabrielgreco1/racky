import RackyDocker
import Foundation
import Testing

@testable import RackyCore

/// Estados da checklist (03 §15, AC-103, AC-113, AC-114, AC-115): estado, motivo em uma linha e no máximo uma ação primária.
@Suite struct DiagnosticsEvaluatorTests {
    private func connected(user: String = "octocat", scopes: [String]) -> GitHubAuthStatus {
        GitHubAuthStatus(state: .connected, host: "github.com", user: user, scopes: scopes)
    }

    @Test func ghMissingOffersInstallPageAndCopyCommand() {
        let item = DiagnosticsEvaluator.gh(GitHubProbeResult(installed: false))
        #expect(item.state == .warning)
        #expect(item.fix == .openURL(title: "Install…", DiagnosticsEvaluator.ghInstallURL))
        #expect(item.secondaryFixes == [.copyCommand("brew install gh")])
    }

    @Test func ghLoggedInShowsVersionUserAndScopes() {
        let item = DiagnosticsEvaluator.gh(GitHubProbeResult(installed: true, version: "2.60.1", auth: connected(scopes: ["repo", "workflow"])))
        #expect(item.state == .ok && item.fix == nil)
        #expect(item.detail == "2.60.1 · Logged in as octocat · repo, workflow")
    }

    @Test func ghLoggedOutOffersLogIn() {
        let item = DiagnosticsEvaluator.gh(GitHubProbeResult(installed: true, version: "2.60.1", auth: GitHubAuthStatus(state: .notLoggedIn, host: "github.com")))
        #expect(item.state == .warning && item.detail == "2.60.1 · Not logged in")
        #expect(item.fix == .logIn(["gh", "auth", "login"]))
    }

    @Test func ghWithoutRepoScopeAsksToRefresh() {
        let item = DiagnosticsEvaluator.gh(GitHubProbeResult(installed: true, version: nil, auth: connected(scopes: ["gist"])))
        #expect(item.state == .warning && item.detail.contains("missing the repo scope"))
        #expect(item.fix == .copyCommand("gh auth refresh -s repo"))
    }

    @Test func dockerStates() {
        #expect(DiagnosticsEvaluator.docker(.notInstalled).fix == .openURL(title: "Install…", DiagnosticsEvaluator.dockerInstallURL))
        let stopped = DiagnosticsEvaluator.docker(.installedNotRunning(kind: .desktop))
        #expect(stopped.detail == "Docker Desktop is installed but not running" && stopped.fix == .startDocker)
        let runtime = DockerRuntime(kind: .desktop, socketPath: "/tmp/x.sock", source: .knownSocket)
        let running = DiagnosticsEvaluator.docker(.running(DockerRunning(runtime: runtime, version: "27.0", memoryGB: 16, headlessCapacity: 11)))
        #expect(running.state == .ok && running.detail == "Running · 16 GB · ≈ 11 headless computers")
        let amd = DiagnosticsEvaluator.docker(.running(DockerRunning(runtime: runtime, version: "27.0", memoryGB: 8, headlessCapacity: 5, isVerifiedArchitecture: false)))
        #expect(amd.state == .warning)
    }

    @Test func imageDependsOnDocker() {
        let runtime = DockerRuntime(kind: .desktop, socketPath: "/tmp/x.sock", source: .knownSocket)
        let up = DockerProbeResult.running(DockerRunning(runtime: runtime, version: "27", memoryGB: 8, headlessCapacity: 4))
        #expect(DiagnosticsEvaluator.image(.ready, docker: up).detail == "Ready")
        #expect(DiagnosticsEvaluator.image(.missing, docker: up).fix == .openSettings(section: "computers"))
        #expect(DiagnosticsEvaluator.image(nil, docker: up).fix == .retry)
        let waiting = DiagnosticsEvaluator.image(nil, docker: .notInstalled)
        #expect(waiting.state == .neutral && waiting.fix == nil)
    }

    private func skillFinding() -> ConflictFinding {
        ConflictFinding(kind: .globalSkill, provider: .claude, path: "~/.claude/skills/racky", message: "A global \"racky\" skill is installed and may compete with Racky tools.")
    }

    private func notifyFinding() -> ConflictFinding {
        ConflictFinding(kind: .notify, provider: .codex, path: "~/.codex/config.toml", message: "Codex notify is used by another app (left untouched).")
    }

    @Test func conflictsHiddenWhenThereIsNothing() {
        #expect(DiagnosticsEvaluator.conflicts(ConflictScan()) == nil)
    }

    @Test func globalSkillOffersBlockDisableAndKeep() throws {
        let item = try #require(DiagnosticsEvaluator.conflicts(ConflictScan(findings: [skillFinding(), notifyFinding()])))
        #expect(item.state == .warning)
        #expect(item.fix == .blockSkill, "Block in Racky é o padrão")
        #expect(item.secondaryFixes == [.disableSkill, .keepSkill])
        #expect(item.notes == ["Codex notify is used by another app (left untouched)."])
    }

    @Test func foreignHooksAndNotifyAreInformationOnly() throws {
        let hooks = ConflictFinding(kind: .hooks, provider: .claude, path: "~/.claude/settings.json", message: "Hooks from Orca …")
        let item = try #require(DiagnosticsEvaluator.conflicts(ConflictScan(findings: [hooks, notifyFinding()])))
        #expect(item.fix == nil && item.secondaryFixes.isEmpty, "AC-114: nenhum botão que altere esses arquivos")
        #expect(item.notes.count == 2)
    }

    @Test func choicesAndBackupChangeTheItem() throws {
        let blocked = try #require(DiagnosticsEvaluator.conflicts(ConflictScan(findings: [skillFinding()], choice: .block)))
        #expect(blocked.state == .ok && blocked.fix == nil)
        let kept = try #require(DiagnosticsEvaluator.conflicts(ConflictScan(findings: [skillFinding()], choice: .keep)))
        #expect(kept.state == .neutral && kept.fix == .blockSkill)
        let disabled = try #require(DiagnosticsEvaluator.conflicts(ConflictScan(findings: [], hasBackup: true)))
        #expect(disabled.fix == .restoreSkill)
    }
}
