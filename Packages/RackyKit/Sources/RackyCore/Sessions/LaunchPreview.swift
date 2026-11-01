import RackyProtocol
import Foundation

/// Linha de resumo do composer (03 §6.3): o comando que vai rodar, sem lançar nada. Usa o mesmo planejador do lançamento
/// (perfil + adapter), então o resumo e o argv real nunca divergem nas flags do perfil e no prompt.
public enum LaunchPreview {
    /// `claude --dangerously-skip-permissions "Fix the search pagination…"` (sem ID de conversa nem injeções).
    public static func command(spec: LaunchSpec, catalog: ProfileCatalog, projectID: UUID?, promptLimit: Int = 36) -> String {
        let adapter = ProviderAdapters.adapter(for: spec.provider)
        var forPreview = spec
        forPreview.initialPrompt = nil
        let name = adapter.executableName ?? (spec.provider == .shell ? "zsh" : (spec.customArgv?.first ?? "command"))
        let input = LaunchPlanInput(
            spec: forPreview, terminalID: UUID(), runID: UUID(), cwd: "/", projectID: projectID, catalog: catalog,
            executablePath: name, loginEnvironment: ["SHELL": "/bin/zsh"], launchDirectory: URL(fileURLWithPath: "/tmp/preview"),
            appSocketPath: "/tmp/preview.sock")
        var parts: [String]
        if let plan = try? LaunchPlanner.plan(input) {
            parts = plan.argv.executable + plan.argv.profile
        } else {
            parts = [name]
        }
        if spec.provider == .shell { parts = ["zsh", "-l"] }
        if let prompt = spec.initialPrompt, !prompt.isEmpty, spec.provider.isAgent {
            let flat = prompt.split(whereSeparator: \.isNewline).joined(separator: " ")
            let shown = flat.count > promptLimit ? String(flat.prefix(promptLimit)).trimmingCharacters(in: .whitespaces) + "…" : flat
            let escaped = shown.replacingOccurrences(of: "\"", with: "\\\"")
            parts.append("\"\(escaped)\"")
        }
        return parts.joined(separator: " ")
    }
}
