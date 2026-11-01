import Foundation
import Testing
@testable import RackyPlatform

@Suite struct LoginShellEnvEvidence {
    /// Gera a evidência de T1-08 quando `AB_EVIDENCE_OUT` aponta para um arquivo. Só nomes e presença; nenhum valor.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AB_EVIDENCE_OUT"] != nil))
    func writeEvidence() async throws {
        let out = try #require(ProcessInfo.processInfo.environment["AB_EVIDENCE_OUT"])
        let home = NSHomeDirectory()
        let base = [
            "HOME": home, "USER": NSUserName(), "LOGNAME": NSUserName(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": NSTemporaryDirectory(), "LANG": "en_US.UTF-8",
            "KITTY_PANE_KEY": "synthetic-pane", "KITTY_AGENT_HOOK_PORT": "0", "CLAUDECODE": "1",
        ]
        let runDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("abenv-evidence-\(UUID().uuidString)")
        let provider = LoginShellEnvProvider(config: LoginShellEnvConfig(baseEnvironment: base, runDirectory: runDir))
        var timings: [Double] = []
        var last: LoginShellEnvResult?
        for _ in 0..<5 {
            let started = ContinuousClock.now
            last = await provider.reload()
            let d = ContinuousClock.now - started
            timings.append(Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
        }
        let result = try #require(last)
        let path = (result.variables["PATH"] ?? "").split(separator: ":").map(String.init)
        var which: [String: String] = [:]
        for tool in ["claude", "codex", "gh", "node"] {
            let dir = path.first { FileManager.default.isExecutableFile(atPath: "\($0)/\(tool)") }
            which[tool] = dir.map { $0.hasPrefix(home) ? "~" + $0.dropFirst(home.count) : $0 } ?? "NOT FOUND"
        }
        let keys = result.diagnostics.keys
        let report: [String: Any] = [
            "task": "T1-08",
            "source": result.diagnostics.source.rawValue,
            "shell": result.diagnostics.shell ?? "",
            "runs": timings.count,
            "durations_s": timings.map { ($0 * 1000).rounded() / 1000 },
            "key_count": keys.count,
            "keys": keys,
            "secret_like_key_names_only": result.diagnostics.secretLikeKeys,
            "ssh_auth_sock_present": result.variables["SSH_AUTH_SOCK"] != nil,
            "proxy_keys_present": keys.filter { $0.lowercased().hasSuffix("_proxy") },
            "foreign_keys_in_result": keys.filter { $0.hasPrefix("KITTY_") },
            "claudecode_in_result": result.variables["CLAUDECODE"] != nil,
            "input_env_had_foreign_and_claudecode": true,
            "which_in_captured_path": which,
            "path_entry_count": path.count,
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: out))
    }
}
