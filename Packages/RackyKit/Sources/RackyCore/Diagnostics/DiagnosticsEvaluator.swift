import RackyProtocol
import RackyDocker
import Foundation

/// Resultado de sonda → item da checklist. Puro: o texto e a correção de cada estado vivem aqui (03 §15, AC-103/113/114/115).
public nonisolated enum DiagnosticsEvaluator {
    public static let ghInstallURL = URL(string: "https://cli.github.com")!
    public static let dockerInstallURL = URL(string: "https://www.docker.com/products/docker-desktop/")!
    public static let ghLoginCommand = ["gh", "auth", "login"]
    public static let ghInstallCommand = "brew install gh"

    public static func timedOut(_ key: DiagnosticKey) -> DiagnosticItem {
        DiagnosticItem(key: key, state: .problem, detail: "Didn't answer in time.", fix: .retry)
    }

    // MARK: GitHub CLI

    public static func gh(_ result: GitHubProbeResult) -> DiagnosticItem {
        guard result.installed else {
            return DiagnosticItem(
                key: .gh, state: .warning, detail: "Not installed. Needed for pull requests and checks.",
                fix: .openURL(title: "Install…", ghInstallURL), secondaryFixes: [.copyCommand(ghInstallCommand)])
        }
        let prefix = result.version.map { "\($0) · " } ?? ""
        guard let auth = result.auth, auth.state == .connected else {
            return DiagnosticItem(
                key: .gh, state: .warning, detail: prefix + "Not logged in", fix: .logIn(ghLoginCommand),
                secondaryFixes: [.copyCommand(ghLoginCommand.joined(separator: " "))])
        }
        let user = auth.user.map { "Logged in as \($0)" } ?? "Logged in"
        let scopes = auth.scopes.isEmpty ? "" : " · " + auth.scopes.joined(separator: ", ")
        guard auth.canReadPrivateRepos else {
            return DiagnosticItem(
                key: .gh, state: .warning, detail: prefix + user + " · missing the repo scope",
                fix: .copyCommand("gh auth refresh -s repo"))
        }
        return DiagnosticItem(key: .gh, state: .ok, detail: prefix + user + scopes)
    }

    // MARK: Runtime nativo

    /// Tamanho aproximado do download do runtime nativo (kernel + init + imagem do computador), mostrado no onboarding.
    public static let runtimeDownloadSize = "~470 MB"
    /// Mensagem de um Mac que não roda o runtime nativo e não tem Docker.
    public static let runtimeUnsupportedMessage = "Racky needs macOS 26 on Apple silicon, or Docker."

    /// Item do runtime nativo; `nil` nos modos Docker (lá valem os itens Docker e imagem).
    public static func runtime(_ mode: ComputerRuntimeMode) -> DiagnosticItem? {
        guard case .native(let installed) = mode else { return nil }
        return DiagnosticItem(
            key: .runtime, state: .ok,
            detail: installed ? "Installed" : "Downloads automatically on first use (\(runtimeDownloadSize))")
    }

    // MARK: Docker e imagem

    public static func docker(_ result: DockerProbeResult, mode: ComputerRuntimeMode = .dockerForced) -> DiagnosticItem {
        switch result {
        case .notInstalled:
            if case .dockerOnly = mode {
                return DiagnosticItem(
                    key: .docker, state: .warning, detail: runtimeUnsupportedMessage, fix: .openURL(title: "Install…", dockerInstallURL))
            }
            return DiagnosticItem(
                key: .docker, state: .warning, detail: "Not installed. Needed for subagent computers.",
                fix: .openURL(title: "Install…", dockerInstallURL))
        case .installedNotRunning(let kind):
            return DiagnosticItem(
                key: .docker, state: .warning, detail: "\(name(of: kind)) is installed but not running", fix: .startDocker)
        case .running(let running):
            let memory = "\(running.memoryGB) GB · ≈ \(running.headlessCapacity) headless computers"
            if !running.isVerifiedArchitecture {
                return DiagnosticItem(key: .docker, state: .warning, detail: "Running · \(memory) · unverified architecture")
            }
            return DiagnosticItem(key: .docker, state: .ok, detail: "Running · \(memory)")
        }
    }

    public static func image(_ result: ImageProbeResult?, docker: DockerProbeResult) -> DiagnosticItem {
        guard case .running = docker else {
            return DiagnosticItem(key: .image, state: .neutral, detail: "Waiting for Docker.")
        }
        switch result {
        case .ready?: return DiagnosticItem(key: .image, state: .ok, detail: "Ready")
        case .missing?:
            return DiagnosticItem(
                key: .image, state: .warning, detail: "Not downloaded. It's prepared the first time a computer starts.",
                fix: .openSettings(section: "computers"))
        case nil: return DiagnosticItem(key: .image, state: .problem, detail: "Couldn't check the image.", fix: .retry)
        }
    }

    // MARK: Conflitos

    /// `nil` quando não há o que mostrar (o item "só aparece se houver", 03 §15).
    public static func conflicts(_ scan: ConflictScan) -> DiagnosticItem? {
        guard !scan.findings.isEmpty || scan.hasBackup else { return nil }
        let skill = scan.findings.first(where: \.isActionable)
        let others = scan.findings.filter { !$0.isActionable }.map(\.message)

        if let skill {
            switch scan.choice {
            case nil:
                return DiagnosticItem(
                    key: .conflicts, state: .warning, detail: skill.message, fix: .blockSkill,
                    secondaryFixes: [.disableSkill, .keepSkill], notes: others)
            case .block?:
                return DiagnosticItem(
                    key: .conflicts, state: .ok, detail: "The global \"\(GlobalConfigScanner.competingName)\" skill is blocked in Racky. Nothing global changed.",
                    secondaryFixes: [.disableSkill], notes: others)
            case .keep?:
                return DiagnosticItem(
                    key: .conflicts, state: .neutral, detail: "Kept. The global \"\(GlobalConfigScanner.competingName)\" skill may compete with Racky tools.",
                    fix: .blockSkill, notes: others)
            }
        }
        if scan.hasBackup {
            return DiagnosticItem(
                key: .conflicts, state: .ok, detail: "The global \"\(GlobalConfigScanner.competingName)\" skill is disabled. A backup is kept.",
                fix: .restoreSkill, notes: others)
        }
        return DiagnosticItem(
            key: .conflicts, state: .neutral, detail: "Other apps' settings are left untouched.", notes: others)
    }

    static func name(of kind: DockerRuntimeKind) -> String {
        switch kind {
        case .desktop: "Docker Desktop"
        case .orbstack: "OrbStack"
        case .colima: "Colima"
        case .other: "Docker"
        }
    }
}
