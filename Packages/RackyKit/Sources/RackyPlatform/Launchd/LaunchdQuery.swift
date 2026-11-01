import Darwin
import Foundation

/// Consultas ao launchd do usuário: caminho do socket publicado e estado do job.
public protocol LaunchdQuerying: Sendable {
    /// `launchctl getenv <key>`: o caminho que o launchd publicou para o `SecureSocketWithKey` (vazio = `nil`).
    func socketPath(forKey key: String) async -> String?
    /// Estado do job no domínio do usuário (`launchctl print gui/<uid>/<label>`).
    func jobState(label: String) async -> LaunchdJobState
}

/// Estado de um job do launchd, como o app precisa dele.
public enum LaunchdJobState: Sendable, Equatable {
    /// O launchd não conhece o job (nunca registrado, ou `unregister` já concluído).
    case notLoaded
    /// Carregado e esperando a próxima conexão ao socket (ou ainda não subiu).
    case idle
    case running
    /// `spawn failed` / `needs LWCR update` / `OS_REASON_CODESIGNING`: o binário não bate com o registro (S-01).
    case failed
}

extension LaunchdQuerying {
    func isJobRunning(label: String) async -> Bool { await jobState(label: label) == .running }
}

public struct SystemLaunchd: LaunchdQuerying {
    private let launchctl = URL(fileURLWithPath: "/bin/launchctl")

    public init() {}

    public func socketPath(forKey key: String) async -> String? {
        guard let output = try? await ProcessRunner.run(
            ProcessRequest(executable: launchctl, arguments: ["getenv", key], timeout: .seconds(5))),
            output.exitCode == 0
        else { return nil }
        let path = output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    public func jobState(label: String) async -> LaunchdJobState {
        guard let output = try? await ProcessRunner.run(
            ProcessRequest(executable: launchctl, arguments: ["print", "gui/\(getuid())/\(label)"], timeout: .seconds(5))),
            output.exitCode == 0
        else { return .notLoaded }
        return Self.state(printOutput: output.stdoutString)
    }

    static func state(printOutput: String) -> LaunchdJobState {
        if printOutput.contains("needs LWCR update") || printOutput.contains("job state = spawn failed") { return .failed }
        return isRunning(printOutput: printOutput) ? .running : .idle
    }

    /// Só a linha do próprio job (um tab de indentação): `state = running` aninhado pertence aos sockets.
    static func isRunning(printOutput: String) -> Bool {
        printOutput.split(separator: "\n", omittingEmptySubsequences: true).contains { $0 == "\tstate = running" }
    }
}
