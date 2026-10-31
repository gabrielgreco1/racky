import RackyProtocol
import Foundation

/// Linha de comando resultante de um perfil de lançamento (03 §13.4), montada pelo próprio adapter do CLI (a mesma que o
/// lançamento usa) sobre capacidades de base: `claude --model opus --dangerously-skip-permissions`. Nada é executado.
public enum LibraryProfileLine {
    public static func commandLine(for profile: LaunchProfile) -> String {
        let adapter = ProviderAdapters.adapter(for: profile.provider)
        let executable = adapter.executableName ?? profile.provider.rawValue
        var spec = LaunchSpec(provider: profile.provider)
        spec.profileID = profile.id
        let input = LaunchPlanInput(
            spec: spec, terminalID: UUID(), runID: UUID(), cwd: "/", catalog: ProfileCatalog(userProfiles: [profile]), executablePath: executable,
            capabilities: CLICapabilities.baseline(for: adapter), loginEnvironment: [:],
            launchDirectory: URL(fileURLWithPath: "/tmp/racky-profile-preview", isDirectory: true), mode: .automatic, slice: .slice1,
            appVersion: "0", appSocketPath: "")
        guard let plan = try? LaunchPlanner.plan(input) else { return executable }
        // O segmento de identidade (`--session-id <uuid>`) é do terminal, não do perfil.
        return (plan.argv.executable + plan.argv.profile).map(quote).joined(separator: " ")
    }

    private static func quote(_ token: String) -> String {
        token.isEmpty || token.contains(where: { $0 == " " || $0 == "\"" || $0 == "'" || $0 == "$" }) ? "'" + token.replacingOccurrences(of: "'", with: "'\\''") + "'" : token
    }
}
