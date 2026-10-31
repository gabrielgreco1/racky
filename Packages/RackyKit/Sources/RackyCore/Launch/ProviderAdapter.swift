import RackyPlatform
import RackyProtocol
import Foundation

public enum CLILoginState: Sendable, Equatable {
    case loggedIn
    case loggedOut
    /// Não deu para saber sem rodar login (ex.: autenticação por variável de ambiente, saída inesperada).
    case unknown(String)
}

/// Como o app obtém o ID nativo da conversa (06 §2.5). Só descreve a estratégia; a execução está em `NativeIDCapture`.
public enum NativeIDCaptureStrategy: Sendable, Equatable {
    /// Claude: o app gera o UUID e passa em `--session-id`; já está no banco antes do spawn.
    case assigned(String)
    /// Codex: (1) hook `SessionStart` (Fatia 2); (2) fallback da Fatia 1: primeiro `rollout-*.jsonl` novo cujo
    /// `session_meta.cwd` é o do terminal e `timestamp >= spawn − 2 s`.
    case codexRollout(cwd: String)
    /// OpenCode: `opencode session list --format json` antes do spawn e 5 s depois; a sessão nova no mesmo diretório.
    case openCodeSessionList(cwd: String)
    case none
}

/// Entrada comum a todos os adapters, já com perfil e spec fundidos.
public struct AdapterContext: Sendable {
    public var executablePath: String
    public var cwd: String
    public var runID: UUID
    public var terminalID: UUID
    public var launchDirectory: URL
    public var mode: LaunchMode
    /// Env capturado (para o shell resolver `$SHELL`).
    public var environment: [String: String]
    public var newUUID: @Sendable () -> UUID
    /// Injeções por lançamento (Fatia 2+). `nil` na Fatia 1: o segmento `injected` fica vazio.
    public var injection: LaunchInjection?
    /// Diz se uma conversa nativa com esse ID já existe em disco (Claude: transcript em `~/.claude/projects/*/<id>.jsonl`).
    /// Relançar com `--session-id` de um ID que já existe falha com "Session ID … is already in use"; nesse caso usa `--resume`.
    public var conversationExists: @Sendable (String) -> Bool = { ClaudeTranscripts.exists(id: $0) }

    public init(
        executablePath: String, cwd: String, runID: UUID, terminalID: UUID, launchDirectory: URL,
        mode: LaunchMode = .automatic, environment: [String: String] = [:], newUUID: @escaping @Sendable () -> UUID = { UUID() },
        injection: LaunchInjection? = nil
    ) {
        self.injection = injection
        self.executablePath = executablePath; self.cwd = cwd; self.runID = runID; self.terminalID = terminalID
        self.launchDirectory = launchDirectory; self.mode = mode; self.environment = environment; self.newUUID = newUUID
    }
}

public struct AdapterOutput: Sendable, Equatable {
    public var argv: ResolvedArgv
    public var nativeConversationID: String?
    public var capture: NativeIDCaptureStrategy
    public var skipsPermissions: SkipPermissionsIndicator?
    public var warnings: [LaunchWarning]
    public var files: [LaunchFile]
    /// Variáveis de ambiente do lançamento (OpenCode: config inline). Vazio na maioria dos adapters.
    public var environment: [String: String] = [:]
}

/// Um adapter por CLI (06 §2.2). Puro: não lê disco nem roda processo; o argv sai de `EffectiveLaunch` + capabilities.
public protocol ProviderAdapter: Sendable {
    var provider: TerminalProvider { get }
    /// Nome na UI ("Claude Code").
    var displayName: String { get }
    /// Nome do binário no PATH (`claude`); `nil` para shell e comando livre.
    var executableName: String? { get }
    var flagRules: [FlagRule] { get }
    var subcommandRules: [FlagRule] { get }
    /// Argumentos extras do login (somente leitura: status). `nil` = não há como saber sem login.
    var loginStatusArguments: [String]? { get }
    func interpretLoginStatus(_ output: ProcessOutput) -> CLILoginState
    func build(_ launch: EffectiveLaunch, context: AdapterContext, capabilities: CLICapabilities) throws -> AdapterOutput
}

extension ProviderAdapter {
    public var subcommandRules: [FlagRule] { [] }
    public var loginStatusArguments: [String]? { nil }
    public func interpretLoginStatus(_ output: ProcessOutput) -> CLILoginState { .unknown("no status command") }
}

/// Registro dos adapters.
public enum ProviderAdapters {
    public static func adapter(for provider: TerminalProvider) -> any ProviderAdapter {
        switch provider {
        case .claude: ClaudeAdapter()
        case .codex: CodexAdapter()
        case .opencode: OpenCodeAdapter()
        case .shell: ShellAdapter()
        case .custom: CustomCommandAdapter()
        }
    }

    public static let agents: [any ProviderAdapter] = [ClaudeAdapter(), CodexAdapter(), OpenCodeAdapter()]
}

/// Utilidades comuns aos três CLIs de agente.
enum AdapterKit {
    static let skipFlags: Set<String> = [
        "--dangerously-skip-permissions", "--dangerously-bypass-approvals-and-sandbox", "--yolo",
    ]

    /// Primeira flag "sem permissões" que sobra no argv do perfil (estruturada ou vinda de `extraArgs`).
    static func skipIndicator(in profileArgs: [String], extra: Set<String> = []) -> SkipPermissionsIndicator? {
        for token in profileArgs {
            let name = token.split(separator: "=", maxSplits: 1).first.map(String.init) ?? token
            if skipFlags.contains(name) || extra.contains(name) { return SkipPermissionsIndicator(flag: token) }
        }
        return nil
    }

    static func unsupported(_ flag: String, adapter: any ProviderAdapter, field: String) -> LaunchWarning {
        LaunchWarning(.unsupportedFlag, "\(field) not applied: \(CLICapabilities.unsupportedReason(flag: flag, adapter: adapter))")
    }

    static func pairOrWarn(
        _ flag: String, _ value: String?, field: String, adapter: any ProviderAdapter,
        capabilities: CLICapabilities, into args: inout [String], warnings: inout [LaunchWarning]
    ) {
        guard let value, !value.isEmpty else { return }
        if capabilities.supports(flag) { args += [flag, value] } else { warnings.append(unsupported(flag, adapter: adapter, field: field)) }
    }
}

/// Transcripts do Claude Code por ID de sessão.
public enum ClaudeTranscripts {
    public static func exists(id: String, home: String = NSHomeDirectory()) -> Bool {
        guard !id.isEmpty, !id.contains("/") else { return false }
        let root = (home as NSString).appendingPathComponent(".claude/projects")
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: root) else { return false }
        for dir in dirs where FileManager.default.fileExists(atPath: "\(root)/\(dir)/\(id).jsonl") { return true }
        return false
    }
}
