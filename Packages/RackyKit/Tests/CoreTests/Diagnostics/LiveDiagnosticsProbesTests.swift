import RackyDocker
import Foundation
import Testing

@testable import RackyCore

/// Sondas de produção com executores e sistema de arquivos falsos: nunca rodam `gh`, `docker` nem CLIs de verdade.
@Suite struct LiveDiagnosticsProbesTests {
    private struct FakeGH: GitHubCommandRunning {
        var version: GitCommandResult?
        var status: GitCommandResult?
        func run(_ arguments: [String], in directory: URL?, timeout: Duration) async throws -> GitCommandResult {
            switch arguments.first {
            case "--version": if let version { return version }
            case "auth": if let status { return status }
            default: break
            }
            throw GitHubError.ghNotInstalled
        }
    }

    @Test func ghMissingWhenTheRunnerCannotLaunchIt() async {
        let result = await LiveDiagnosticsProbes.gh(runner: FakeGH())
        #expect(!result.installed)
    }

    @Test func ghParsesVersionUserAndScopes() async {
        let status = """
        github.com
          ✓ Logged in to github.com account octocat (keyring)
          - Active account: true
          - Git operations protocol: https
          - Token: gho_************************************
          - Token scopes: 'repo', 'workflow'
        """
        let runner = FakeGH(version: GitCommandResult(exitCode: 0, stdout: "gh version 2.60.1 (2024-10-22)\nhttps://github.com/cli/cli\n", stderr: ""),
                            status: GitCommandResult(exitCode: 0, stdout: status, stderr: ""))
        let result = await LiveDiagnosticsProbes.gh(runner: runner)
        #expect(result.installed && result.version == "2.60.1")
        #expect(result.auth?.user == "octocat" && result.auth?.scopes == ["repo", "workflow"])
        #expect(DiagnosticsEvaluator.gh(result).detail == "2.60.1 · Logged in as octocat · repo, workflow")
    }

    @Test func ghLoggedOut() async {
        let runner = FakeGH(version: GitCommandResult(exitCode: 0, stdout: "gh version 2.60.1 (2024-10-22)\n", stderr: ""),
                            status: GitCommandResult(exitCode: 1, stdout: "", stderr: "You are not logged into any GitHub hosts. To log in, run: gh auth login\n"))
        let result = await LiveDiagnosticsProbes.gh(runner: runner)
        #expect(result.installed && result.auth?.state == .notLoggedIn)
    }

    private func detector(home: URL, existing: Set<String>) -> RuntimeDetector {
        RuntimeDetector(environment: [:], homeDirectory: home, fileExists: { existing.contains($0) }, readFile: { _ in nil }, listDirectory: { _ in [] })
    }

    @Test func dockerNotInstalledWhenNothingIsThere() async {
        let home = URL(fileURLWithPath: "/nonexistent-home")
        let result = await LiveDiagnosticsProbes.docker(detector: detector(home: home, existing: []), applicationExists: { _ in false })
        #expect(result == .notInstalled)
    }

    @Test func dockerInstalledButNotRunningWhenTheAppExistsWithoutASocket() async {
        let home = URL(fileURLWithPath: "/nonexistent-home")
        let result = await LiveDiagnosticsProbes.docker(
            detector: detector(home: home, existing: []), applicationExists: { $0 == "/Applications/Docker.app" })
        #expect(result == .installedNotRunning(kind: .desktop))
    }

    @Test func dockerWithAStaleSocketIsNotRunning() async {
        let home = URL(fileURLWithPath: "/nonexistent-home")
        let socket = "/nonexistent-home/.orbstack/run/docker.sock"
        let result = await LiveDiagnosticsProbes.docker(detector: detector(home: home, existing: [socket]), applicationExists: { _ in false })
        #expect(result == .installedNotRunning(kind: .orbstack))
    }
}
