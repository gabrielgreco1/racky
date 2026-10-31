import RackyDocker
import RackyPlatform
import Foundation

/// Sondas de produção da checklist. Cada uma é só leitura e barata: `gh --version` + `gh auth status`, o ping do socket do
/// Docker (sem chamar o CLI `docker`), a lista de imagens por referência e a leitura de arquivos de config.
public enum LiveDiagnosticsProbes {
    public static let computerImageRepository = "racky-computer"

    public static func make(
        githubRunner: any GitHubCommandRunning = GitHubProcessRunner(),
        docker: RuntimeDetector = RuntimeDetector(),
        applicationExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        scanner: GlobalConfigScanner = GlobalConfigScanner(),
        backup: GlobalSkillBackup? = nil,
        choice: @escaping @Sendable () async -> ConflictChoice? = { nil }
    ) -> DiagnosticsProbes {
        DiagnosticsProbes(
            gh: { await gh(runner: githubRunner) },
            docker: { await self.docker(detector: docker, applicationExists: applicationExists) },
            image: { await image(runtime: $0) },
            conflicts: { ConflictScan(findings: scanner.scan(), choice: await choice(), hasBackup: backup?.hasBackup ?? false) })
    }

    public static func gh(runner: any GitHubCommandRunning) async -> GitHubProbeResult {
        let timeout = Duration.seconds(5)
        guard let version = try? await runner.run(["--version"], in: nil, timeout: timeout), version.exitCode == 0 else {
            return GitHubProbeResult(installed: false)
        }
        // "gh version 2.60.1 (2024-10-22)" -> "2.60.1"
        let number = version.stdout.split(whereSeparator: \.isNewline).first
            .flatMap { $0.split(separator: " ").dropFirst(2).first }.map(String.init)
        guard let status = try? await runner.run(["auth", "status"], in: nil, timeout: timeout) else {
            return GitHubProbeResult(installed: true, version: number, auth: GitHubAuthStatus(state: .notLoggedIn, host: "github.com"))
        }
        let auth = GitHubAuthParser.parse(output: status.stdout + "\n" + status.stderr, exitCode: status.exitCode, host: "github.com")
        return GitHubProbeResult(installed: true, version: number, auth: auth)
    }

    public static func docker(detector: RuntimeDetector, applicationExists: @Sendable (String) -> Bool) async -> DockerProbeResult {
        if let detected = try? await detector.detect() {
            let planner = CapacityPlanner(vm: detected.capacity)
            return .running(DockerRunning(
                runtime: detected.runtime, version: detected.version.version, memoryGB: detected.capacity.configuredGB,
                headlessCapacity: planner.maxConcurrent(.headless), isVerifiedArchitecture: detected.isVerifiedArchitecture))
        }
        let home = detector.homeDirectory.path
        if let known = detector.candidates().first { return .installedNotRunning(kind: known.kind) }
        for (path, kind) in [("/Applications/Docker.app", DockerRuntimeKind.desktop), (home + "/Applications/Docker.app", .desktop),
                             ("/Applications/OrbStack.app", .orbstack)] where applicationExists(path) {
            return .installedNotRunning(kind: kind)
        }
        return .notInstalled
    }

    public static func image(runtime: DockerRuntime) async -> ImageProbeResult? {
        let client = DockerClient(runtime: runtime, defaultTimeout: .seconds(5))
        guard let images = try? await client.listImages(filters: ["reference": [computerImageRepository]]) else { return nil }
        return images.isEmpty ? .missing : .ready
    }
}
