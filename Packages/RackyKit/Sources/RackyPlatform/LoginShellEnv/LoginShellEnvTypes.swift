import Foundation

/// Motivo de falha de uma tentativa de captura (06 §1.7). Sem valores de variáveis.
public enum LoginShellEnvFailure: Error, Sendable, Equatable {
    case noShell
    case spawnFailed(errno: Int32)
    case timedOut(milliseconds: Int)
    case exitedWithoutMarker(status: Int32)
    case outputUnreadable(String)
    case emptyEnvironment
    case cancelled

    public var reason: String {
        switch self {
        case .noShell: "no login shell found for the current user"
        case .spawnFailed(let code): "could not start the shell (errno \(code))"
        case .timedOut(let ms): "timed out after \(ms) ms"
        case .exitedWithoutMarker(let status): "shell exited (status \(status)) before printing the end marker"
        case .outputUnreadable(let detail): "environment output unreadable: \(detail)"
        case .emptyEnvironment: "shell produced an empty environment"
        case .cancelled: "cancelled"
        }
    }
}

public enum LoginShellEnvSource: String, Sendable, Equatable {
    case interactive
    case nonInteractive = "non-interactive"
    case launchdFallback = "launchd-fallback"
}

/// Diagnóstico da captura: fonte, duração e só os NOMES das variáveis (06 §1.7 passo 5).
public struct LoginShellEnvDiagnostics: Sendable, Equatable {
    public let source: LoginShellEnvSource
    public let duration: Duration
    public let shell: String?
    public let keys: [String]
    public let secretLikeKeys: [String]
    /// Falha da captura interativa quando outra fonte foi usada.
    public let interactiveFailure: LoginShellEnvFailure?
    /// Falha do `-l -c` quando caiu no env do launchd.
    public let nonInteractiveFailure: LoginShellEnvFailure?

    /// Banner do Diagnostics (nunca silencioso quando não é a captura interativa).
    public var banner: String? {
        switch source {
        case .interactive: nil
        case .nonInteractive: "Using non-interactive shell environment"
        case .launchdFallback: "Using fallback environment"
        }
    }
}

/// Env capturado já filtrado. `description` não mostra valores.
public struct CapturedLoginEnv: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let variables: [String: String]
    public let diagnostics: LoginShellEnvDiagnostics

    public var description: String {
        "CapturedLoginEnv(source: \(diagnostics.source.rawValue), keys: \(variables.count), secretLike: \(diagnostics.secretLikeKeys.count))"
    }
    public var debugDescription: String { description }
}

/// Resultado tipado da captura (06 §1.7).
public enum LoginShellEnvResult: Sendable, Equatable {
    /// `-l -i -c` em PTY oculto funcionou.
    case interactive(CapturedLoginEnv)
    /// Só o `-l -c` funcionou: o `.zshrc` não rodou (PATH pode perder entradas).
    case nonInteractive(CapturedLoginEnv)
    /// Nenhuma captura funcionou; `fallback` é o env do launchd com diretórios conhecidos no PATH.
    case failed(interactive: LoginShellEnvFailure, nonInteractive: LoginShellEnvFailure, fallback: CapturedLoginEnv)

    /// Env a usar de qualquer forma (o do launchd no caso `failed`).
    public var captured: CapturedLoginEnv {
        switch self {
        case .interactive(let env), .nonInteractive(let env): env
        case .failed(_, _, let fallback): fallback
        }
    }
    public var variables: [String: String] { captured.variables }
    public var diagnostics: LoginShellEnvDiagnostics { captured.diagnostics }
    public var isInteractive: Bool { if case .interactive = self { true } else { false } }
}
