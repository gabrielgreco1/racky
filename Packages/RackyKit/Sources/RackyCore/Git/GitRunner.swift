import RackyPlatform
import Foundation

public struct GitCommandResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public var succeeded: Bool { exitCode == 0 }

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Como o comando afeta o repositório: leituras rodam com `GIT_OPTIONAL_LOCKS=0` (06 §5.3), para não
/// disputar o `index.lock` com os agentes.
public enum GitCommandKind: Sendable {
    case read
    case write
}

public protocol GitCommandRunning: Sendable {
    /// Executa `git <arguments>` em `directory`. Lança `GitError` (`gitNotInstalled`, `timedOut`, `cancelled`,
    /// `launchFailed`); saída de erro do git volta como resultado com `exitCode != 0`.
    func run(_ arguments: [String], in directory: URL?, kind: GitCommandKind,
             timeout: Duration) async throws -> GitCommandResult
}

/// Executa o git instalado via `ProcessRunner` (fora do pool cooperativo), sem shell.
public struct GitProcessRunner: GitCommandRunning {
    public let executableURL: URL?
    private let extraEnvironment: [String: String]

    /// - Parameter extraEnvironment: variáveis extras (testes isolam HOME e a config global).
    public init(executableURL: URL? = GitProcessRunner.findExecutable(), extraEnvironment: [String: String] = [:]) {
        self.executableURL = executableURL
        self.extraEnvironment = extraEnvironment
    }

    public static func findExecutable() -> URL? {
        let extra = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for directory in ["/usr/bin", "/opt/homebrew/bin", "/usr/local/bin"] + extra {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("git")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    public func run(_ arguments: [String], in directory: URL?, kind: GitCommandKind,
                    timeout: Duration) async throws -> GitCommandResult {
        guard let executableURL else { throw GitError.gitNotInstalled }
        var environment = extraEnvironment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        environment["GIT_ASKPASS"] = environment["GIT_ASKPASS"] ?? "/usr/bin/true"
        if kind == .read { environment["GIT_OPTIONAL_LOCKS"] = "0" }
        let request = ProcessRequest(executable: executableURL, arguments: arguments, environment: environment,
                                     currentDirectory: directory, timeout: timeout)
        do {
            let output = try await ProcessRunner.run(request)
            return GitCommandResult(exitCode: output.exitCode, stdout: output.stdoutString,
                                    stderr: output.stderrString)
        } catch let error as ProcessRunnerError {
            switch error {
            case .timedOut: throw GitError.timedOut(operation: Self.operationName(arguments))
            case .cancelled: throw GitError.cancelled
            case .launchFailed(let detail): throw GitError.launchFailed(detail)
            }
        }
    }

    static func operationName(_ arguments: [String]) -> String {
        var index = 0
        while index < arguments.count {
            if arguments[index] == "-C" { index += 2; continue }
            if arguments[index].hasPrefix("-") { index += 1; continue }
            return arguments[index]
        }
        return "git"
    }
}
