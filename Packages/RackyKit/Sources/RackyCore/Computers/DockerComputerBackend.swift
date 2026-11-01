import RackyDocker
import Foundation

/// `proxy_set`: devolve a config do egress (política e upstream) e a CA extra do proxy escolhido (`"direct"` = sem upstream).
/// O app monta a partir do `ProxyService` (T3-02); o egress é o único que recebe as credenciais, por arquivo 0400.
public typealias ProxyConfigResolver = @Sendable (_ proxy: String, _ country: String?) async throws -> (config: EgressConfigFile, caPEM: String?)

/// Uma sessão de exec em andamento, venha do Docker (`ExecSession`) ou de uma VM (`RackyVZ`): o que o `ExecJobs` precisa para
/// juntar a saída, esperar o código de saída e encerrar o grupo de processos.
public protocol ComputerExecSession: Sendable {
    var frames: AsyncThrowingStream<DockerStreamFrame, any Error> { get }
    func writeInput(_ data: Data) async throws
    func closeInput() async
    func finalExitCode() async throws -> Int
    /// SIGTERM no grupo e, depois de `grace`, SIGKILL.
    func terminateGroup(grace: Duration) async throws
}

/// O que o backend do computador pede ao runtime (Docker ou VM): iniciar um exec como o usuário do `spec` e regravar a config do
/// egress dentro do computador (troca de proxy). É a única parte do backend que muda entre os runtimes; a admin API, o reqlog e o
/// viewer passam pela porta `computer.adminPort` nos dois.
public protocol ComputerExecTransport: Sendable {
    func startExec(_ spec: ExecSpec) async throws -> any ComputerExecSession
    func rewriteConfig(_ config: EgressConfigFile, proxyCA: String?) async throws
}

extension ExecSession: ComputerExecSession {
    public var frames: AsyncThrowingStream<DockerStreamFrame, any Error> { output }
    public func writeInput(_ data: Data) async throws { try await writeStdin(data) }
    public func closeInput() async { closeStdin() }
    public func finalExitCode() async throws -> Int { try await exitCode() }
    public func terminateGroup(grace: Duration) async throws { try await terminate(grace: grace) }
}

/// Transporte do Docker: Engine API (`docker exec -u agent`) e `abx-provision` por exec no container.
public struct DockerExecTransport: ComputerExecTransport {
    public let client: DockerClient
    public let computer: ProvisionedComputer

    public init(client: DockerClient, computer: ProvisionedComputer) {
        self.client = client
        self.computer = computer
    }

    public func startExec(_ spec: ExecSpec) async throws -> any ComputerExecSession {
        try await client.startExec(in: computer.containerID, spec: spec)
    }

    public func rewriteConfig(_ config: EgressConfigFile, proxyCA: String?) async throws {
        try await ComputerProvisioner(client: client).rewriteConfig(config, proxyCA: proxyCA, computer: computer)
    }
}

/// Backend real (P24, um computador): exec como `agent` por um `ComputerExecTransport` (Docker ou VM), reverse proxy da admin API
/// para o navegador, ingest e render no proxy do mesmo computador.
public struct DockerComputerBackend: ComputerBackend {
    public let transport: any ComputerExecTransport
    public let computer: ProvisionedComputer
    public let secrets: BoxSecretFiles
    public let baseConfig: EgressConfigFile
    private let resolver: ProxyConfigResolver?
    private let jobs = ExecJobs()

    public init(client: DockerClient, computer: ProvisionedComputer, secrets: BoxSecretFiles, baseConfig: EgressConfigFile, resolver: ProxyConfigResolver? = nil) {
        self.init(transport: DockerExecTransport(client: client, computer: computer), computer: computer, secrets: secrets, baseConfig: baseConfig, resolver: resolver)
    }

    public init(transport: any ComputerExecTransport, computer: ProvisionedComputer, secrets: BoxSecretFiles, baseConfig: EgressConfigFile, resolver: ProxyConfigResolver? = nil) {
        self.transport = transport
        self.computer = computer
        self.secrets = secrets
        self.baseConfig = baseConfig
        self.resolver = resolver
    }

    // MARK: Runtime (browser)

    public func runtime(_ operation: String, _ args: JSON, timeout: TimeInterval) async throws -> JSON {
        let status: Int, body: Data
        do {
            (status, body) = try await computer.admin.runtimeCall(operation, body: args.data(), timeout: timeout)
        } catch let error as URLError where error.code == .timedOut {
            throw ToolError(.timeout, "the runtime did not answer in time")
        } catch let error as EgressAdminError {
            throw ToolError(.boxRestarted, "the computer's egress is not reachable (\(error))", retryAfterS: 5)
        } catch is URLError {
            throw ToolError(.boxRestarted, "the computer's runtime is not reachable", retryAfterS: 5)
        }
        let json = (try? JSON.parse(body)) ?? .null
        guard status == 200 else { throw RuntimeErrorMapper.map(status: status, body: json) }
        return json
    }

    public func vncEndpoint() async throws -> URL {
        guard computer.display != .http else { throw ToolError(.notSupported, "this computer is in HTTP mode and has no screen") }
        let out = try await runtime("vnc_ticket", [:], timeout: 10)
        guard let ticket = out["ticket"]?.string, let url = URL(string: "ws://127.0.0.1:\(computer.adminPort)/vnc?ticket=\(ticket)") else {
            throw ToolError(.boxRestarted, "the runtime did not issue a viewer ticket", retryAfterS: 5)
        }
        return url
    }

    // MARK: Exec como `agent` no container do computador

    public static func command(for request: BackendExec) -> [String] {
        let base: [String] = request.shell.map { ["bash", "-lc", $0] } ?? request.argv ?? []
        guard !request.secretEnv.isEmpty else { return base }
        // O valor do segredo vem de arquivo montado só leitura (`/run/abx-secrets`, legível pelo `agent`) e só existe neste processo (§3.3).
        let script = "names=\"$1\"; shift; for n in $names; do f=\"/run/abx-secrets/$n\"; "
            + "[ -r \"$f\" ] || { echo \"secret $n is not available\" >&2; exit 126; }; export \"$n=$(cat \"$f\")\"; done; exec \"$@\""
        return ["/bin/sh", "-c", script, "sh", request.secretEnv.joined(separator: " ")] + base
    }

    public func spec(_ request: BackendExec) -> ExecSpec {
        var spec = ExecSpec(command: Self.command(for: request), attachStdin: request.stdin != nil, killableGroup: true)
        spec.user = ComputerProvisioner.agentUser
        spec.workingDirectory = request.cwd
        spec.environment = request.env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        return spec
    }

    private func start(_ request: BackendExec) async throws -> String {
        let session = try await transport.startExec(spec(request))
        if let stdin = request.stdin {
            try await session.writeInput(stdin)
            await session.closeInput()
        }
        return await jobs.add(session)
    }

    public func execRun(_ request: BackendExec, timeout: Duration) async throws -> BackendExecOutcome {
        let id = try await start(request)
        var outcome = await jobs.poll(id, wait: timeout)
        if outcome.running {
            // Passou do prazo: SIGTERM no grupo e, 2 s depois, SIGKILL. A saída parcial volta com `timedOut`.
            outcome = await jobs.cancel(id, grace: .seconds(2))
            outcome.timedOut = true
        }
        await jobs.forget(id)
        return outcome
    }

    public func execStart(_ request: BackendExec) async throws -> String { try await start(request) }

    public func execPoll(jobID: String, wait: Duration) async throws -> BackendExecOutcome {
        guard await jobs.contains(jobID) else { throw ToolError(.notFound, "no job \(jobID)") }
        return await jobs.poll(jobID, wait: wait)
    }

    public func execCancel(jobID: String) async throws -> BackendExecOutcome {
        guard await jobs.contains(jobID) else { throw ToolError(.notFound, "no job \(jobID)") }
        return await jobs.cancel(jobID, grace: .seconds(5))
    }

    // MARK: Egress

    public func ingest(_ payload: JSON) async throws -> String {
        do { return try await computer.admin.ingest(payload.data()) } catch {
            throw ToolError(.boxRestarted, "could not record the request in the egress log: \(error)", retryAfterS: 5)
        }
    }

    public func switchProxy(to proxy: String, country: String?) async throws -> Int {
        var config: EgressConfigFile
        var caPEM: String?
        if proxy == "direct" {
            // "direct" não é um proxy salvo: é a config do computador sem upstream (como na reserva)
            config = baseConfig
            config.upstream = nil
        } else {
            guard let resolver else { throw ToolError(.notSupported, "this app build has no proxy resolver") }
            let resolved = try await resolver(proxy, country)
            config = resolved.config
            caPEM = resolved.caPEM
        }
        config.proxyPort = baseConfig.proxyPort
        config.adminPort = baseConfig.adminPort
        config.allowCIDRs = baseConfig.allowCIDRs
        config.allowHosts = baseConfig.allowHosts
        config.github = baseConfig.github  // trocar de proxy não tira o acesso ao GitHub
        try await transport.rewriteConfig(config, proxyCA: caPEM)
        do { return try await computer.admin.reloadProxy() } catch {
            throw ToolError(.proxyError, "the egress did not confirm the proxy switch: \(error)")
        }
    }

    public func adminTunnel(port: Int) async throws -> AdminTunnelTarget {
        AdminTunnelTarget(adminPort: computer.adminPort, request: computer.admin.tunnelRequest(port: port))
    }

    public func proxyInfo() async throws -> JSON { try JSON.parse(try await computer.admin.get("/v1/proxy")) }

    public func usage() async throws -> JSON {
        let body = try JSON.parse(try await computer.admin.get("/v1/usage"))
        let total = body["total"] ?? [:]
        func n(_ key: String) -> Int { total[key]?.int ?? 0 }
        return ["requests": .int(n("requests")), "tunnels": .int(n("tunnels")), "bytes": .int(n("bytes_up") + n("bytes_down")), "renders": .int(n("renders"))]
    }

    public func render(_ payload: JSON) async throws -> JSON {
        let (status, body) = try await computer.admin.render(payload.data())
        let json = (try? JSON.parse(body)) ?? .null
        if status == 200 { return json }
        throw RuntimeErrorMapper.map(status: status, body: json)
    }
}

/// Jobs de exec em andamento: consome a saída de cada `ExecSession` e guarda stdout, stderr e código de saída.
actor ExecJobs {
    private struct Job {
        var session: any ComputerExecSession
        var stdout = Data()
        var stderr = Data()
        var exitCode: Int?
        var finished = false
        var started = ContinuousClock.now
        var duration: Duration = .zero
    }

    private var jobs: [String: Job] = [:]

    func contains(_ id: String) -> Bool { jobs[id] != nil }
    func forget(_ id: String) { jobs[id] = nil }

    func add(_ session: any ComputerExecSession) -> String {
        let id = ULID.generate()
        jobs[id] = Job(session: session)
        Task { [weak self] in await self?.consume(id, session) }
        return id
    }

    private func consume(_ id: String, _ session: any ComputerExecSession) async {
        do {
            for try await frame in session.frames {
                if frame.kind == .stderr { jobs[id]?.stderr.append(frame.data) } else { jobs[id]?.stdout.append(frame.data) }
            }
            jobs[id]?.exitCode = try? await session.finalExitCode()
        } catch {
            jobs[id]?.exitCode = nil
        }
        jobs[id]?.finished = true
        if let started = jobs[id]?.started { jobs[id]?.duration = started.duration(to: .now) }
    }

    private func outcome(_ id: String) -> BackendExecOutcome {
        guard let job = jobs[id] else { return BackendExecOutcome() }
        let elapsed = job.finished ? job.duration : job.started.duration(to: .now)
        let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        return BackendExecOutcome(running: !job.finished, exitCode: job.exitCode, stdout: job.stdout, stderr: job.stderr, durationMs: ms)
    }

    func poll(_ id: String, wait: Duration) async -> BackendExecOutcome {
        let deadline = ContinuousClock.now + wait
        while jobs[id]?.finished == false, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        return outcome(id)
    }

    func cancel(_ id: String, grace: Duration) async -> BackendExecOutcome {
        guard let job = jobs[id], !job.finished else { return outcome(id) }
        try? await job.session.terminateGroup(grace: grace)
        return await poll(id, wait: .seconds(5))
    }
}
