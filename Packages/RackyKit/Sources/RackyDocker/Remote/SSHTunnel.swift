import Foundation

public enum TunnelState: Sendable, Equatable {
    case stopped
    case connecting
    case connected
    /// Mestre caiu; religando (tentativa N).
    case reconnecting(attempt: Int)
    /// Desistiu (limite de tentativas ou erro de configuração).
    case failed(String)
}

public enum SSHTunnelError: Error, Sendable, Equatable {
    case notConnected
    case connectTimeout(String)
    case masterExited(Int32)
    case forwardFailed(String)
    case socketPathTooLong(String)
}

/// Espera entre religações: exponencial até `max`.
public struct TunnelBackoff: Sendable, Equatable {
    public var initial: Duration
    public var max: Duration
    /// `nil` = tenta para sempre (o app decide quando desistir do host).
    public var maxAttempts: Int?

    public init(initial: Duration = .seconds(1), max: Duration = .seconds(30), maxAttempts: Int? = nil) {
        self.initial = initial; self.max = max; self.maxAttempts = maxAttempts
    }

    public func delay(forAttempt attempt: Int) -> Duration {
        var delay = initial
        for _ in 1 ..< Swift.max(attempt, 1) {
            delay = delay * 2
            if delay >= max { return max }
        }
        return Swift.min(delay, max)
    }
}

/// Túnel SSH gerenciado até uma VM: um processo mestre `ssh -N -L <socket local>:/var/run/docker.sock` mantido vivo (religa com espera
/// exponencial) e, por computador, encaminhamentos `-L 127.0.0.1:<porta local>:127.0.0.1:<porta da VM>` para a admin API e o VNC,
/// reaplicados com as MESMAS portas locais depois de uma religação (os clientes da admin API não notam).
/// O executor do `ssh` é injetado (`TunnelRunner`): os testes não precisam de sshd.
public actor SSHTunnel {
    public nonisolated let endpoint: SSHEndpoint
    public nonisolated let localSocketPath: String
    public nonisolated let controlPath: String
    /// Cliente Docker sobre o socket encaminhado: o mesmo `DockerClient` de sempre (exec com hijack, eventos, archive).
    public nonisolated let client: DockerClient
    public nonisolated let states: AsyncStream<TunnelState>

    private let runner: any TunnelRunner
    private let backoff: TunnelBackoff
    private let readyTimeout: Duration
    private let pause: @Sendable (Duration) async throws -> Void
    private let continuation: AsyncStream<TunnelState>.Continuation
    private var supervisor: Task<Void, Never>?
    private var process: (any TunnelProcess)?
    private var stopping = false
    private(set) public var state = TunnelState.stopped
    private(set) public var reconnectCount = 0
    private var forwards: [String: [Int: Int]] = [:]  // key -> [porta remota: porta local]

    /// `directory`: pasta 0700 curta (caminho de socket Unix tem teto de ~104 bytes) com o socket local e o de controle.
    public init(
        endpoint: SSHEndpoint, directory: URL, runner: any TunnelRunner, backoff: TunnelBackoff = TunnelBackoff(),
        readyTimeout: Duration = .seconds(30), sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) throws {
        try endpoint.validate()
        self.endpoint = endpoint
        localSocketPath = directory.appendingPathComponent("docker.sock").path
        controlPath = directory.appendingPathComponent("ctl").path
        for path in [localSocketPath, controlPath] where path.utf8.count > 100 { throw SSHTunnelError.socketPathTooLong(path) }
        client = DockerClient(socketPath: localSocketPath, defaultTimeout: .seconds(30))
        self.runner = runner
        self.backoff = backoff
        self.readyTimeout = readyTimeout
        self.pause = sleep
        (states, continuation) = AsyncStream.makeStream(of: TunnelState.self, bufferingPolicy: .bufferingNewest(16))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        continuation.yield(.stopped)
    }

    private func set(_ new: TunnelState) {
        state = new
        continuation.yield(new)
    }

    // MARK: Ciclo de vida

    /// Sobe o mestre e espera o Docker responder pelo socket encaminhado. Depois disso o `supervise` o mantém vivo.
    public func start() async throws {
        guard supervisor == nil else { return }
        try endpoint.validateFiles()
        stopping = false
        set(.connecting)
        supervisor = Task { await supervise() }
        try await waitConnected(timeout: readyTimeout + .seconds(5))
    }

    /// Espera o estado `.connected` (uso após uma queda).
    public func waitConnected(timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            switch state {
            case .connected: return
            case .failed(let reason): throw SSHTunnelError.connectTimeout(reason)
            default: try await Task.sleep(for: .milliseconds(20))
            }
        }
        throw SSHTunnelError.connectTimeout("o túnel não conectou em \(timeout)")
    }

    public func stop() async {
        stopping = true
        supervisor?.cancel()
        _ = try? await runner.run(SSHCommand.control(endpoint, operation: "exit", control: controlPath), timeout: .seconds(3))
        process?.terminate()
        process = nil
        supervisor = nil
        forwards = [:]
        try? FileManager.default.removeItem(atPath: localSocketPath)
        try? FileManager.default.removeItem(atPath: controlPath)
        set(.stopped)
    }

    private func removeStaleSockets() {
        try? FileManager.default.removeItem(atPath: localSocketPath)
        try? FileManager.default.removeItem(atPath: controlPath)
    }

    private func supervise() async {
        var attempt = 0
        while !stopping, !Task.isCancelled {
            do {
                removeStaleSockets()
                let launched = try await runner.launch(SSHCommand.master(endpoint, localSocket: localSocketPath, control: controlPath))
                process = launched
                try await Self.waitReady(launched, client: client, timeout: readyTimeout)
                if attempt > 0 { reconnectCount += 1 }
                attempt = 0
                set(.connected)
                await reapplyForwards()
                _ = await launched.waitUntilExit()
            } catch {
                process?.terminate()
            }
            process = nil
            if stopping || Task.isCancelled { break }
            attempt += 1
            if let limit = backoff.maxAttempts, attempt > limit {
                set(.failed("o túnel caiu e não voltou depois de \(limit) tentativas"))
                return
            }
            set(.reconnecting(attempt: attempt))
            try? await pause(backoff.delay(forAttempt: attempt))
        }
    }

    /// Pronto = o socket local responde ao `_ping` do Docker, ou o mestre saiu (erro).
    @concurrent private static func waitReady(_ launched: any TunnelProcess, client: DockerClient, timeout: Duration) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while true {
                    if (try? await client.ping()) != nil { return }
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
            group.addTask {
                let code = await launched.waitUntilExit()
                try Task.checkCancellation()  // cancelado = o ping venceu; `waitUntilExit` devolve na hora
                throw SSHTunnelError.masterExited(code)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw SSHTunnelError.connectTimeout("o Docker da VM não respondeu em \(timeout)")
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    // MARK: Encaminhamentos por computador

    /// `127.0.0.1:<local>` no Mac -> `127.0.0.1:<remotePort>` na VM. Idempotente por (`key`, porta).
    public func forward(remotePort: Int, key: String) async throws -> Int {
        guard case .connected = state else { throw SSHTunnelError.notConnected }
        if let existing = forwards[key]?[remotePort] { return existing }
        var lastError = ""
        for _ in 0 ..< 5 {
            let local = try freeLoopbackPort()
            let result = try await runner.run(
                SSHCommand.forward(endpoint, localPort: local, remotePort: remotePort, control: controlPath), timeout: .seconds(15))
            if result.status == 0 {
                forwards[key, default: [:]][remotePort] = local
                return local
            }
            lastError = result.stderr
        }
        throw SSHTunnelError.forwardFailed(lastError)
    }

    public func cancelForwards(key: String) async {
        guard let owned = forwards.removeValue(forKey: key) else { return }
        for (remote, local) in owned {
            _ = try? await runner.run(SSHCommand.forward(endpoint, localPort: local, remotePort: remote, control: controlPath, cancel: true), timeout: .seconds(5))
        }
    }

    public func activeForwardCount() -> Int { forwards.values.reduce(0) { $0 + $1.count } }

    private func reapplyForwards() async {
        for (_, owned) in forwards {
            for (remote, local) in owned {
                _ = try? await runner.run(SSHCommand.forward(endpoint, localPort: local, remotePort: remote, control: controlPath), timeout: .seconds(15))
            }
        }
    }

    // MARK: Heartbeat

    /// Executa `command` (fixo, do app) na VM pelo mestre. É o sinal de vida da chave morta (`touch` do arquivo de lease).
    public func runRemote(_ command: String, timeout: Duration = .seconds(15)) async throws -> TunnelCommandResult {
        guard case .connected = state else { throw SSHTunnelError.notConnected }
        return try await runner.run(SSHCommand.remote(endpoint, control: controlPath, command: command), timeout: timeout)
    }
}
