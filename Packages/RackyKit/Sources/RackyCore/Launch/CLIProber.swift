import RackyPlatform
import RackyProtocol
import Foundation

/// Executa um comando de sonda. Em produção é o `ProcessRunner`; os testes injetam um falso (nunca roda agente).
public protocol CommandRunning: Sendable {
    func run(_ request: ProcessRequest) async throws -> ProcessOutput
}

public struct SystemCommandRunner: CommandRunning {
    public init() {}
    public func run(_ request: ProcessRequest) async throws -> ProcessOutput { try await ProcessRunner.run(request) }
}

/// Resolve o executável de um CLI (06 §2.2): override por CLI, depois o PATH do shell de login, depois os diretórios
/// conhecidos (06 §1.7 passo 4).
public enum CLIExecutableResolver {
    public static func knownDirectories(home: String) -> [String] {
        ["\(home)/.local/bin", "\(home)/.bun/bin", "\(home)/.opencode/bin", "/opt/homebrew/bin", "/usr/local/bin"]
    }

    public static func resolve(name: String, searchPath: String?, override: String? = nil, home: String = NSHomeDirectory()) -> String? {
        let fm = FileManager.default
        if let override, !override.isEmpty {
            return fm.isExecutableFile(atPath: override) ? override : nil
        }
        let fromPath = (searchPath ?? "").split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        for directory in fromPath + knownDirectories(home: home) {
            let candidate = (directory as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate, isDirectory: &isDir), !isDir.boolValue, fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}

public struct CLIProbeResult: Sendable, Equatable {
    public var provider: TerminalProvider
    public var executable: String?
    public var version: CLIVersion?
    public var versionText: String?
    public var capabilities: CLICapabilities?
    public var login: CLILoginState
    /// Motivos legíveis de degradação (versão ilegível, `--help` sem uso, status inesperado).
    public var issues: [String]

    public var isInstalled: Bool { executable != nil }

    public init(
        provider: TerminalProvider, executable: String?, version: CLIVersion? = nil, versionText: String? = nil,
        capabilities: CLICapabilities? = nil, login: CLILoginState, issues: [String] = []
    ) {
        self.provider = provider; self.executable = executable; self.version = version; self.versionText = versionText
        self.capabilities = capabilities; self.login = login; self.issues = issues
    }
}

/// Detecta CLI instalado, versão, flags (`--help`) e login (comando de status, somente leitura). NUNCA roda `login`.
/// O cache é por `(caminho, mtime)`: troca de binário ou "Check Again" (`force`) refaz `--version` e `--help`.
public actor CLIProber {
    private struct CacheKey: Hashable { var path: String; var stamp: Date? }
    private struct CacheEntry { var version: CLIVersion?; var versionText: String?; var capabilities: CLICapabilities; var issues: [String] }

    private let runner: any CommandRunning
    private let environment: @Sendable () async -> [String: String]
    private let overrides: [TerminalProvider: String]
    private let timeout: Duration
    private let stamp: @Sendable (String) -> Date?
    private var cache: [CacheKey: CacheEntry] = [:]

    public private(set) var probeRuns = 0

    /// - Parameter environment: normalmente `{ await loginShellEnv.environment().captured.variables }`.
    public init(
        runner: any CommandRunning = SystemCommandRunner(),
        environment: @escaping @Sendable () async -> [String: String],
        overrides: [TerminalProvider: String] = [:],
        timeout: Duration = .seconds(5),
        stamp: @escaping @Sendable (String) -> Date? = { path in
            (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        }
    ) {
        self.runner = runner; self.environment = environment; self.overrides = overrides
        self.timeout = timeout; self.stamp = stamp
    }

    public func invalidate() { cache.removeAll() }

    public func probe(_ adapter: any ProviderAdapter, checkLogin: Bool = true, force: Bool = false) async -> CLIProbeResult {
        let env = await environment()
        guard let name = adapter.executableName else {
            return CLIProbeResult(provider: adapter.provider, executable: nil, version: nil, versionText: nil, capabilities: nil,
                                  login: .unknown("not an agent CLI"), issues: [])
        }
        guard let path = CLIExecutableResolver.resolve(name: name, searchPath: env["PATH"], override: overrides[adapter.provider]) else {
            return CLIProbeResult(provider: adapter.provider, executable: nil, version: nil, versionText: nil, capabilities: nil,
                                  login: .unknown("\(adapter.displayName) is not installed"), issues: ["\(name) not found in PATH"])
        }
        let key = CacheKey(path: path, stamp: stamp(path))
        let entry: CacheEntry
        if !force, let hit = cache[key] {
            entry = hit
        } else {
            entry = await detect(adapter, path: path, environment: env)
            cache[key] = entry
        }
        var issues = entry.issues
        var login = CLILoginState.unknown("not checked")
        if checkLogin { login = await loginState(adapter, path: path, environment: env, issues: &issues) }
        return CLIProbeResult(
            provider: adapter.provider, executable: path, version: entry.version, versionText: entry.versionText,
            capabilities: entry.capabilities, login: login, issues: issues
        )
    }

    private func request(_ path: String, _ arguments: [String], _ env: [String: String]) -> ProcessRequest {
        // Diretório neutro: o `--help` não deve depender do cwd do app.
        ProcessRequest(
            executable: URL(fileURLWithPath: path), arguments: arguments, environment: env,
            currentDirectory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            timeout: timeout, maxOutputBytes: 1024 * 1024
        )
    }

    private func detect(_ adapter: any ProviderAdapter, path: String, environment env: [String: String]) async -> CacheEntry {
        probeRuns += 1
        var issues: [String] = []
        let runner = self.runner
        let versionRequest = request(path, ["--version"], env)
        let helpRequest = request(path, ["--help"], env)
        async let versionOutput = Self.capture(runner, versionRequest)
        async let helpOutput = Self.capture(runner, helpRequest)
        let (versionResult, helpResult) = await (versionOutput, helpOutput)

        var version: CLIVersion?
        var versionText: String?
        switch versionResult {
        case .success(let output):
            let text = (output.stdoutString + output.stderrString).trimmingCharacters(in: .whitespacesAndNewlines)
            versionText = text.split(separator: "\n").first.map(String.init)
            version = CLIVersion.parse(text)
            if version == nil { issues.append("could not read a version from `--version`") }
        case .failure(let reason):
            issues.append("`--version` failed: \(reason)")
        }
        var help: ParsedHelp?
        switch helpResult {
        case .success(let output):
            let parsed = HelpParser.parse(output.stdoutString.isEmpty ? output.stderrString : output.stdoutString)
            if parsed.isUsable { help = parsed } else { issues.append("`--help` output was not recognised; using the version table") }
        case .failure(let reason):
            issues.append("`--help` failed: \(reason)")
        }
        return CacheEntry(
            version: version, versionText: versionText,
            capabilities: CLICapabilities.resolve(version: version, help: help, adapter: adapter), issues: issues
        )
    }

    private enum Captured { case success(ProcessOutput), failure(String) }

    private static func capture(_ runner: any CommandRunning, _ request: ProcessRequest) async -> Captured {
        do { return .success(try await runner.run(request)) }
        catch ProcessRunnerError.timedOut { return .failure("timed out") }
        catch ProcessRunnerError.launchFailed(let message) { return .failure(message) }
        catch { return .failure("\(error)") }
    }

    private func loginState(_ adapter: any ProviderAdapter, path: String, environment env: [String: String], issues: inout [String]) async -> CLILoginState {
        guard let arguments = adapter.loginStatusArguments else { return .unknown("no status command for \(adapter.displayName)") }
        // Somente leitura: nenhum subcomando de login/logout interativo pode sair daqui.
        if arguments.last == "login" || arguments.contains("logout") { return .unknown("refused to run a login command") }
        switch await Self.capture(runner, request(path, arguments, env)) {
        case .success(let output): return adapter.interpretLoginStatus(output)
        case .failure(let reason):
            issues.append("login status check failed: \(reason)")
            return .unknown(reason)
        }
    }
}
