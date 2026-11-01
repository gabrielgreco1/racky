import RackyDocker
import AppKit
import Foundation

/// "Open Docker" (07 CS-104): abre o app do runtime do usuário (Docker Desktop ou OrbStack) em segundo plano. O app nunca instala nada.
@MainActor
enum DockerLauncher {
    static func open(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let kind = RuntimeDetector(environment: environment).candidates().first?.kind ?? .desktop
        let bundleID = kind == .orbstack ? "dev.kdrag0n.MacVirt" : "com.docker.docker"
        let fallback = URL(fileURLWithPath: kind == .orbstack ? "/Applications/OrbStack.app" : "/Applications/Docker.app")
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) ?? fallback
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}
