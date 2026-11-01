import Darwin
import Foundation

/// Configuração da captura do env do shell de login (06 §1.7).
public struct LoginShellEnvConfig: Sendable {
    /// Shell a usar. `nil` = `pw_shell` do usuário (`getpwuid`), nunca `zsh` fixo.
    public var shellPath: String?
    /// Env entregue ao shell (o do app lançado pelo Finder = env mínimo do launchd).
    public var baseEnvironment: [String: String]
    /// Diretório do arquivo temporário do env (`AB/run/`); criado com 0700, arquivo 0600 e apagado em seguida.
    public var runDirectory: URL
    public var interactiveTimeout: Duration
    public var nonInteractiveTimeout: Duration
    public var filter: EnvFilter
    /// Idade máxima do cache; `nil` = só invalida por `invalidate()`/`reload()`.
    public var maxAge: Duration?

    public init(
        shellPath: String? = nil,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        runDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("racky-run", isDirectory: true),
        interactiveTimeout: Duration = .seconds(5),
        nonInteractiveTimeout: Duration = .seconds(3),
        filter: EnvFilter = .default,
        maxAge: Duration? = nil
    ) {
        self.shellPath = shellPath
        self.baseEnvironment = baseEnvironment
        self.runDirectory = runDirectory
        self.interactiveTimeout = interactiveTimeout
        self.nonInteractiveTimeout = nonInteractiveTimeout
        self.filter = filter
        self.maxAge = maxAge
    }
}

/// Captura, filtra e guarda em memória o env do shell de login. Cache com coalescência de chamadas concorrentes.
/// Falhas totais não ficam em cache (a próxima chamada tenta de novo). Nunca registra valores.
public actor LoginShellEnvProvider {
    private let config: LoginShellEnvConfig
    private let log = LogFacade(.app, category: "login-shell-env")
    private var cached: (result: LoginShellEnvResult, at: ContinuousClock.Instant)?
    private var inflight: Task<LoginShellEnvResult, Never>?

    public init(config: LoginShellEnvConfig = LoginShellEnvConfig()) {
        self.config = config
    }

    /// Env do cache ou uma captura nova (uma só por vez, mesmo com chamadas concorrentes).
    public func environment() async -> LoginShellEnvResult {
        if let cached, !isExpired(cached.at) { return cached.result }
        if let inflight { return await inflight.value }
        let config = self.config
        let task = Task { await Self.capture(config: config) }
        inflight = task
        let result = await task.value
        if inflight == task { // não foi invalidada durante a captura
            inflight = nil
            if case .failed = result {} else { cached = (result, ContinuousClock.now) }
            report(result)
        }
        return result
    }

    /// "Reload Shell Environment": descarta o cache (e mata uma captura em curso) e captura de novo.
    public func reload() async -> LoginShellEnvResult {
        invalidate()
        return await environment()
    }

    public func invalidate() {
        cached = nil
        inflight?.cancel()
        inflight = nil
    }

    /// Último resultado em cache, sem capturar.
    public func cachedResult() -> LoginShellEnvResult? {
        guard let cached, !isExpired(cached.at) else { return nil }
        return cached.result
    }

    private func isExpired(_ at: ContinuousClock.Instant) -> Bool {
        guard let maxAge = config.maxAge else { return false }
        return ContinuousClock.now - at > maxAge
    }

    private func report(_ result: LoginShellEnvResult) {
        let d = result.diagnostics
        log.info("login env source=\(d.source.rawValue) keys=\(d.keys.count) secretLike=\(d.secretLikeKeys.count) duration=\(d.duration)")
    }

    // MARK: - Captura (sem estado do actor)

    static func capture(config: LoginShellEnvConfig) async -> LoginShellEnvResult {
        let clock = ContinuousClock()
        let start = clock.now
        let shell = config.shellPath ?? currentUserShell()
        guard let shell else {
            return failed(config, shell: nil, start: start, interactive: .noShell, nonInteractive: .noShell)
        }

        let first = await attempt(config: config, shell: shell, interactive: true)
        switch first {
        case .success(let vars):
            return .interactive(build(config, vars, .interactive, shell, clock.now - start, nil, nil))
        case .failure(let interactiveFailure):
            if interactiveFailure == .cancelled {
                return failed(config, shell: shell, start: start, interactive: .cancelled, nonInteractive: .cancelled)
            }
            let second = await attempt(config: config, shell: shell, interactive: false)
            switch second {
            case .success(let vars):
                return .nonInteractive(build(config, vars, .nonInteractive, shell, clock.now - start, interactiveFailure, nil))
            case .failure(let nonInteractiveFailure):
                return failed(config, shell: shell, start: start, interactive: interactiveFailure, nonInteractive: nonInteractiveFailure)
            }
        }
    }

    private static func attempt(config: LoginShellEnvConfig, shell: String, interactive: Bool) async -> Result<[String: String], LoginShellEnvFailure> {
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let beginMarker = "__AB_ENV_\(nonce)__"
        let endMarker = "__AB_ENV_END_\(nonce)__"
        let outURL: URL
        do { outURL = try makeOutputFile(in: config.runDirectory, nonce: nonce) }
        catch { return .failure(.outputUnreadable("cannot create output file")) }
        defer { unlink(outURL.path) }

        var mutableEnv = config.baseEnvironment
        let passwd = getpwuid(getuid())
        if mutableEnv["HOME"] == nil, let dir = passwd?.pointee.pw_dir { mutableEnv["HOME"] = String(cString: dir) }
        if mutableEnv["USER"] == nil, let name = passwd?.pointee.pw_name { mutableEnv["USER"] = String(cString: name) }
        mutableEnv["LOGNAME"] = mutableEnv["LOGNAME"] ?? mutableEnv["USER"]
        mutableEnv["SHELL"] = shell
        mutableEnv["TERM"] = "dumb"
        mutableEnv["AB_ENV_OUT"] = outURL.path
        let env = mutableEnv

        // O env sai por arquivo (o PTY troca \n por \r\n); o marcador final só sinaliza o fim.
        let command = "printf '\\n\(beginMarker)\\n'; /usr/bin/env -0 > \"$AB_ENV_OUT\"; printf '\\n\(endMarker)\\n'"
        let arguments = interactive ? ["-l", "-i", "-c", command] : ["-l", "-c", command]
        let timeout = interactive ? config.interactiveTimeout : config.nonInteractiveTimeout
        let timeoutMillis = Int(timeout.components.seconds) * 1000 + Int(timeout.components.attoseconds / 1_000_000_000_000_000)

        var wake: [Int32] = [0, 0]
        guard pipe(&wake) == 0 else { return .failure(.spawnFailed(errno: errno)) }
        let wakeRead = wake[0], wakeWrite = wake[1]
        let markerBytes = Array(endMarker.utf8)
        let outcome = await withTaskCancellationHandler {
            await BlockingIOBridge.run {
                ShellProbe.run(
                    shellPath: shell, arguments: arguments, environment: env, usePTY: interactive,
                    endMarker: markerBytes, timeoutMillis: timeoutMillis, wakeFD: wakeRead
                )
            }
        } onCancel: {
            var byte: UInt8 = 1
            _ = write(wakeWrite, &byte, 1)
        }
        close(wakeRead)
        close(wakeWrite)

        switch outcome {
        case .cancelled: return .failure(.cancelled)
        case .timedOut: return .failure(.timedOut(milliseconds: timeoutMillis))
        case .spawnFailed(let code): return .failure(.spawnFailed(errno: code))
        case .exitedWithoutMarker(let status): return .failure(.exitedWithoutMarker(status: status))
        case .markerSeen:
            guard let data = try? Data(contentsOf: outURL) else { return .failure(.outputUnreadable("file missing")) }
            let vars = LoginShellEnvParser.parse(data)
            return vars.isEmpty ? .failure(.emptyEnvironment) : .success(vars)
        }
    }

    private static func makeOutputFile(in directory: URL, nonce: String) throws -> URL {
        try makeDirectories(directory.path)
        let url = directory.appendingPathComponent("login-env-\(nonce).out")
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        close(fd)
        return url
    }

    /// `mkdir -p` com 0700 (POSIX direto: a lint de UI proíbe FileManager por engano em Platform, ver relatório T1-08).
    private static func makeDirectories(_ path: String) throws {
        var current = ""
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            current += "/" + component
            if mkdir(current, 0o700) != 0 && errno != EEXIST { throw CocoaError(.fileWriteUnknown) }
        }
    }

    private static func directoryEntries(_ path: String) -> [String] {
        guard let dir = opendir(path) else { return [] }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    private static func currentUserShell() -> String? {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return nil }
        let path = String(cString: shell)
        return path.isEmpty ? nil : path
    }

    // MARK: - Construção de resultados

    private static func build(
        _ config: LoginShellEnvConfig, _ raw: [String: String], _ source: LoginShellEnvSource, _ shell: String?,
        _ duration: Duration, _ interactiveFailure: LoginShellEnvFailure?, _ nonInteractiveFailure: LoginShellEnvFailure?
    ) -> CapturedLoginEnv {
        let variables = config.filter.apply(to: raw)
        let keys = variables.keys.sorted()
        return CapturedLoginEnv(
            variables: variables,
            diagnostics: LoginShellEnvDiagnostics(
                source: source, duration: duration, shell: shell, keys: keys,
                secretLikeKeys: keys.filter(SecretNames.isSecretLike),
                interactiveFailure: interactiveFailure, nonInteractiveFailure: nonInteractiveFailure
            )
        )
    }

    private static func failed(
        _ config: LoginShellEnvConfig, shell: String?, start: ContinuousClock.Instant,
        interactive: LoginShellEnvFailure, nonInteractive: LoginShellEnvFailure
    ) -> LoginShellEnvResult {
        let fallback = build(
            config, launchdFallback(config.baseEnvironment), .launchdFallback, shell,
            ContinuousClock.now - start, interactive, nonInteractive
        )
        return .failed(interactive: interactive, nonInteractive: nonInteractive, fallback: fallback)
    }

    /// Passo 4 de 06 §1.7: env do launchd + diretórios conhecidos no PATH.
    static func launchdFallback(_ base: [String: String]) -> [String: String] {
        var env = base
        let home = base["HOME"] ?? NSHomeDirectory()
        var extra = ["\(home)/.local/bin", "\(home)/.bun/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        if let nvm = base["NVM_BIN"], !nvm.isEmpty { extra.append(nvm) }
        let versions = "\(home)/.nvm/versions/node"
        if let newest = directoryEntries(versions).sorted().last {
            extra.append("\(versions)/\(newest)/bin")
        }
        var seen = Set<String>()
        let current = (base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        env["PATH"] = (current + extra).filter { seen.insert($0).inserted }.joined(separator: ":")
        return env
    }
}
