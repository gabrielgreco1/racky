import RackyPlatform
import RackyProtocol
import Foundation

/// Limiar único do prompt inicial no argv (01 §5.7, 06 §2.4, AC-308): bytes UTF-8.
public let launchPromptArgvLimitBytes = 16 * 1024

/// Fatia do roadmap. Define quais injeções por lançamento (06 §2.8) podem aparecer no segmento `injected`.
public enum LaunchSlice: Int, Sendable, Comparable, CaseIterable {
    case slice1 = 1, slice2

    public static func < (lhs: LaunchSlice, rhs: LaunchSlice) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Flags permitidas no segmento `injected`. Fatia 1: nenhuma (sem hooks, MCP, plugin nem agentes).
    public var allowedInjectionFlags: Set<String> {
        switch self {
        case .slice1: []
        case .slice2: ["--settings", "--mcp-config", "--plugin-dir", "--agents", "-c"]
        }
    }
}

/// Verificação do segmento `injected` à parte (06 §2.4.1 regra 2).
public enum InjectionValidator {
    public static func violations(injected: [String], launchDirectory: URL, slice: LaunchSlice) -> [String] {
        var problems: [String] = []
        let allowed = slice.allowedInjectionFlags
        let root = launchDirectory.standardizedFileURL.path
        for token in injected {
            if token.hasPrefix("-") {
                if !allowed.contains(token) { problems.append("flag outside allowlist: \(token)") }
            } else if token.hasPrefix("/"), !(token == root || token.hasPrefix(root + "/")) {
                problems.append("path outside launch directory: \(token)")
            }
        }
        return problems
    }
}

public enum LaunchMode: Sendable, Equatable {
    /// Novo lançamento, ou retomada quando `LaunchSpec.resumeOf` está preenchido.
    case automatic
    /// Retomar o ID nativo dado.
    case resume(nativeID: String)
    /// "Continue Last": `-c` / `resume --last` / `-c`, quando não há ID capturado (06 §2.5).
    case continueLast
}

public struct LaunchWarning: Sendable, Equatable {
    public enum Code: String, Sendable {
        case duplicateStructuredArg, unsupportedFlag, hooksDisabledByFlag, resumeWithoutID, promptIgnored
        case unknownPermissionMode, reservedEnvDropped, daemonFlagUnavailable
    }
    public let code: Code
    public let message: String
    public init(_ code: Code, _ message: String) { self.code = code; self.message = message }
}

/// Indicador permanente `ShieldOff` (06 §2.3): sempre que o lançamento efetivo pula permissões.
public struct SkipPermissionsIndicator: Sendable, Equatable {
    public let flag: String
    public var tooltip: String { "Skip permissions (\(flag))" }
}

/// Arquivo de apoio do lançamento, dentro de `AB/run/launch/<runID>/`.
public struct LaunchFile: Sendable, Equatable {
    public let name: String
    public let contents: Data
    /// 0600 por padrão.
    public let posixMode: UInt16
    public init(name: String, contents: Data, posixMode: UInt16 = 0o600) {
        self.name = name; self.contents = contents; self.posixMode = posixMode
    }
}

public enum LaunchPlanError: Error, Equatable, Sendable {
    case missingCustomArgv
    case invalidPermissionMode(provider: TerminalProvider, mode: String)
    case noShellAvailable
    case promptFileUnreadable(String)
    /// O segmento `injected` saiu da allowlist da fatia ou apontou para fora de `run/launch/<runID>/` (06 §2.4.1).
    case injectionViolation(String)
}

/// LaunchSpec + perfil já fundidos (campos do spec vencem os do perfil).
public struct EffectiveLaunch: Sendable, Equatable {
    public var provider: TerminalProvider
    public var model: String?
    public var effort: String?
    public var permissionMode: String?
    public var addDirs: [String]
    public var extraArgs: [String]
    public var env: [String: String]
    public var customArgv: [String]?
    public var initialPrompt: String?
    public var initialPromptFile: String?
    public var nativeSessionID: String?
    public var profile: LaunchProfile?
}

public enum PromptDelivery: Sendable, Equatable {
    case none
    /// Texto literal como um único argumento.
    case argument(String)
    /// Vai para `prompt.md`; o argumento aponta o caminho.
    case file(LaunchFile?, argument: String)

    public var argumentText: String? {
        switch self {
        case .none: nil
        case .argument(let text): text
        case .file(_, let argument): argument
        }
    }

    public var files: [LaunchFile] {
        if case .file(let file?, _) = self { [file] } else { [] }
    }

    /// Regra de 06 §2.4: mais de 16 KiB (UTF-8), começa com `-` (o CLI leria como flag) ou tem NUL (argv não carrega NUL).
    public static func resolve(prompt: String?, promptFile: String?, launchDirectory: URL) -> PromptDelivery {
        if let promptFile, !promptFile.isEmpty {
            return .file(nil, argument: "Read and follow the task in \(promptFile)")
        }
        guard let prompt, !prompt.isEmpty else { return .none }
        let needsFile = prompt.utf8.count > launchPromptArgvLimitBytes || prompt.hasPrefix("-") || prompt.utf8.contains(0)
        guard needsFile else { return .argument(prompt) }
        let path = launchDirectory.appendingPathComponent("prompt.md").path
        return .file(LaunchFile(name: "prompt.md", contents: Data(prompt.utf8)), argument: "Read and follow the task in \(path)")
    }
}

/// Aridade das flags que o app também controla como campo estruturado; `extraArgs` repetidos geram aviso
/// e o campo estruturado vence (06 §2.3).
struct ExtraArgsFilter {
    /// flag -> recebe valor
    let structured: [String: Bool]

    func apply(_ args: [String], adapterName: String, isSet: (String) -> Bool) -> (kept: [String], warnings: [LaunchWarning]) {
        var kept: [String] = []
        var warnings: [LaunchWarning] = []
        var index = 0
        while index < args.count {
            let token = args[index]
            let name = token.split(separator: "=", maxSplits: 1).first.map(String.init) ?? token
            if let takesValue = structured[name], isSet(name) {
                warnings.append(LaunchWarning(.duplicateStructuredArg, "\(name) in extra arguments is ignored: the profile field wins (\(adapterName))"))
                index += (takesValue && !token.contains("=")) ? 2 : 1
                continue
            }
            kept.append(token)
            index += 1
        }
        return (kept, warnings)
    }
}

/// Composição do env de cada terminal (06 §1.7), nesta ordem, a última vence:
/// 1. env capturado; 2. denylist; 3. variáveis do app; 4. env do perfil e overrides do spec.
public struct LaunchEnvironmentComposer: Sendable {
    public var appVersion: String
    public var appSocketPath: String
    public var filter: EnvFilter

    public init(appVersion: String, appSocketPath: String, filter: EnvFilter = .default) {
        self.appVersion = appVersion; self.appSocketPath = appSocketPath; self.filter = filter
    }

    public func compose(
        captured: [String: String], terminalID: UUID, runID: UUID,
        profileEnv: [String: String], overrides: [String: String]
    ) -> (env: [String: String], warnings: [LaunchWarning]) {
        var env = filter.apply(to: captured)
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Racky"
        env["TERM_PROGRAM_VERSION"] = appVersion
        if (env["LANG"] ?? "").isEmpty { env["LANG"] = "en_US.UTF-8" }
        env["RACKY_PANE_ID"] = terminalID.uuidString.lowercased()
        env["RACKY_RUN_ID"] = runID.uuidString.lowercased()
        env["RACKY_APP_SOCK"] = appSocketPath
        var warnings: [LaunchWarning] = []
        for layer in [profileEnv, overrides] {
            for (name, value) in layer.sorted(by: { $0.key < $1.key }) {
                // Só o app define RACKY_*.
                if name.hasPrefix("RACKY_") {
                    warnings.append(LaunchWarning(.reservedEnvDropped, "\(name) is reserved and was not passed to the terminal"))
                    continue
                }
                env[name] = value
            }
        }
        return (env, warnings)
    }
}
