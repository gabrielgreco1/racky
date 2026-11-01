import RackyPlatform
import Foundation

/// Executa `gh <arguments>`. Lança `GitHubError` (`ghNotInstalled`, `timedOut`, `cancelled`, `launchFailed`);
/// saída de erro do `gh` volta como resultado com `exitCode != 0`.
public protocol GitHubCommandRunning: Sendable {
    func run(_ arguments: [String], in directory: URL?, timeout: Duration) async throws -> GitCommandResult
}

/// Executa o `gh` instalado via `ProcessRunner` (fora do pool cooperativo), sem shell. O token nunca é lido nem
/// passado pelo app: o `gh` resolve a credencial sozinho (`GH_TOKEN` do ambiente herdado ou keyring).
public struct GitHubProcessRunner: GitHubCommandRunning {
    public let executableURL: URL?
    private let extraEnvironment: [String: String]

    public init(executableURL: URL? = GitHubProcessRunner.findExecutable(), extraEnvironment: [String: String] = [:]) {
        self.executableURL = executableURL
        self.extraEnvironment = extraEnvironment
    }

    public static func findExecutable() -> URL? {
        let extra = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for directory in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] + extra {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("gh")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    public func run(_ arguments: [String], in directory: URL?, timeout: Duration) async throws -> GitCommandResult {
        guard let executableURL else { throw GitHubError.ghNotInstalled }
        var environment = extraEnvironment
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        environment["GH_SPINNER_DISABLED"] = "1"
        environment["NO_COLOR"] = "1"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        let request = ProcessRequest(executable: executableURL, arguments: arguments, environment: environment,
                                     currentDirectory: directory, timeout: timeout)
        do {
            let output = try await ProcessRunner.run(request)
            return GitCommandResult(exitCode: output.exitCode, stdout: output.stdoutString,
                                    stderr: GitHubRedaction.redact(output.stderrString))
        } catch let error as ProcessRunnerError {
            switch error {
            case .timedOut: throw GitHubError.timedOut
            case .cancelled: throw GitHubError.cancelled
            case .launchFailed(let detail): throw GitHubError.launchFailed(detail)
            }
        }
    }
}

/// Remove qualquer coisa com cara de token de textos que podem ir para log ou UI.
public enum GitHubRedaction {
    public static func redact(_ text: String) -> String {
        var result = text
        let replacements: [(String, String)] = [
            (#"gh[pousr]_[A-Za-z0-9]{16,}"#, "[redacted]"),
            (#"github_pat_[A-Za-z0-9_]{20,}"#, "[redacted]"),
            (#"(?i)(authorization:\s*(?:bearer|token)\s+)\S+"#, "$1[redacted]"),
        ]
        for (pattern, template) in replacements {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return result
    }
}
