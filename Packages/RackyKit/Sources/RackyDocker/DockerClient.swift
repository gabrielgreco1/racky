import Foundation

/// Cliente da Engine API sobre o socket Unix do contexto ativo (08 AR-114). Não usa o CLI nem depende do PATH.
/// Valor `Sendable` sem estado mutável: cada chamada abre a própria conexão. Toda operação tem prazo e é cancelável (CS-106).
public struct DockerClient: Sendable {
    public static let defaultAPIVersion = "v1.43"

    public let socketPath: String
    public let apiVersion: String
    public let defaultTimeout: Duration
    let transport: DockerTransport

    public init(socketPath: String, apiVersion: String = DockerClient.defaultAPIVersion, defaultTimeout: Duration = .seconds(30)) {
        self.socketPath = socketPath
        self.apiVersion = apiVersion
        self.defaultTimeout = defaultTimeout
        transport = DockerTransport(socketPath: socketPath, apiVersion: apiVersion)
    }

    public init(runtime: DockerRuntime, defaultTimeout: Duration = .seconds(30)) {
        self.init(socketPath: runtime.socketPath, defaultTimeout: defaultTimeout)
    }

    // MARK: Helpers

    private func json(_ value: JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, _ context: String) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch {
            throw DockerError.malformedResponse("\(context): \(error)")
        }
    }

    private func get<T: Decodable>(_ type: T.Type, _ path: String, query: [URLQueryItem] = [], operation: String, timeout: Duration? = nil) async throws -> T {
        let response = try await transport.send(HTTPRequest(method: "GET", path: path, query: query), timeout: timeout ?? defaultTimeout, operation: operation)
        return try decode(type, from: response.body, operation)
    }

    @discardableResult
    private func post(_ path: String, query: [URLQueryItem] = [], body: JSONValue? = nil, operation: String, accept: Set<Int> = [],
                      timeout: Duration? = nil) async throws -> DockerResponse {
        var request = HTTPRequest(method: "POST", path: path, query: query)
        if let body {
            request.body = try json(body)
            request.headers["Content-Type"] = "application/json"
        }
        return try await transport.send(request, timeout: timeout ?? defaultTimeout, operation: operation, accept: accept)
    }

    static func filtersItem(_ filters: [String: [String]]) -> URLQueryItem? {
        guard !filters.isEmpty else { return nil }
        let object = filters.mapValues { JSONValue.strings($0) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(JSONValue.object(object)) else { return nil }
        return URLQueryItem(name: "filters", value: String(decoding: data, as: UTF8.self))
    }

    // MARK: Daemon

    /// `GET /_ping`. Falha com `.runtimeUnavailable` quando o socket não responde.
    public func ping() async throws {
        let response = try await transport.send(HTTPRequest(method: "GET", path: "/_ping"), timeout: .seconds(5), operation: "ping")
        guard String(decoding: response.body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "OK" else {
            throw DockerError.malformedResponse("ping: resposta inesperada")
        }
    }

    public func version() async throws -> DockerVersion {
        try await get(DockerVersion.self, "/version", operation: "version")
    }

    public func info() async throws -> DockerInfo {
        try await get(DockerInfo.self, "/info", operation: "info")
    }

    // MARK: Imagens

    public func inspectImage(_ reference: String) async throws -> ImageInspect {
        try await get(ImageInspect.self, "/images/\(reference)/json", operation: "image inspect")
    }

    /// `nil` quando a imagem não existe localmente.
    public func imageIfPresent(_ reference: String) async throws -> ImageInspect? {
        do { return try await inspectImage(reference) } catch let error as DockerError where error.isNotFound { return nil }
    }

    public func listImages(filters: [String: [String]] = [:]) async throws -> [ImageSummary] {
        try await get([ImageSummary].self, "/images/json", query: Self.filtersItem(filters).map { [$0] } ?? [], operation: "image list")
    }

    public func tagImage(_ reference: String, repository: String, tag: String) async throws {
        try await post("/images/\(reference)/tag", query: [.init(name: "repo", value: repository), .init(name: "tag", value: tag)], operation: "image tag")
    }

    public func removeImage(_ reference: String, force: Bool = false) async throws {
        _ = try await transport.send(
            HTTPRequest(method: "DELETE", path: "/images/\(reference)", query: [.init(name: "force", value: force ? "1" : "0")]),
            timeout: defaultTimeout, operation: "image remove")
    }

    /// `POST /images/create`. `reference` é `repo@sha256:...` (por digest) ou `repo:tag`. Progresso por linha;
    /// o stream termina com erro `.imagePullFailed` se o daemon relatar falha no meio do pull.
    public func pullImage(_ reference: String, registryAuth: String? = nil) async throws -> AsyncThrowingStream<PullProgress, any Error> {
        var request = HTTPRequest(method: "POST", path: "/images/create", query: [.init(name: "fromImage", value: reference)])
        if let registryAuth { request.headers["X-Registry-Auth"] = registryAuth }
        let (_, body) = try await transport.stream(request, headTimeout: .seconds(60), operation: "image pull")
        return Self.decodeLines(body, as: PullProgress.self) { event in
            if let message = event.error { throw DockerError.imagePullFailed(message) }
        }
    }

    /// Conveniência: executa o pull até o fim e devolve o último status.
    @discardableResult
    public func pullImageToCompletion(_ reference: String, onProgress: (@Sendable (PullProgress) -> Void)? = nil) async throws -> String? {
        var last: String?
        for try await event in try await pullImage(reference) {
            onProgress?(event)
            if let status = event.status { last = status }
        }
        return last
    }

    /// `POST /build` com o contexto como tar (builder clássico). `dockerfile` é o caminho dentro do contexto.
    public func buildImage(
        context: Data, tag: String, dockerfile: String = "Dockerfile", labels: [String: String] = [:],
        buildArgs: [String: String] = [:], noCache: Bool = false, pull: Bool = false
    ) async throws -> AsyncThrowingStream<BuildEvent, any Error> {
        var query: [URLQueryItem] = [
            .init(name: "t", value: tag), .init(name: "dockerfile", value: dockerfile), .init(name: "rm", value: "1"),
            .init(name: "forcerm", value: "1"), .init(name: "version", value: "1"),
        ]
        if noCache { query.append(.init(name: "nocache", value: "1")) }
        if pull { query.append(.init(name: "pull", value: "1")) }
        if !labels.isEmpty { query.append(.init(name: "labels", value: String(decoding: try json(.map(labels)), as: UTF8.self))) }
        if !buildArgs.isEmpty { query.append(.init(name: "buildargs", value: String(decoding: try json(.map(buildArgs)), as: UTF8.self))) }
        var request = HTTPRequest(method: "POST", path: "/build", query: query)
        request.body = context
        request.headers["Content-Type"] = "application/x-tar"
        let (_, body) = try await transport.stream(request, headTimeout: .seconds(300), operation: "image build")
        return Self.decodeLines(body, as: BuildEvent.self) { event in
            if let message = event.error { throw DockerError.imageBuildFailed(message) }
        }
    }

    // MARK: Containers

    /// Cria o container e devolve o id. Prazo ou cancelamento durante o `create` é seguido de `rm -f` pelo nome
    /// determinístico, para não deixar órfão (07 CS-106, audit/09 N19). 409 (nome em uso) é `.conflict`.
    public func createContainer(_ spec: ContainerSpec, timeout: Duration? = nil) async throws -> String {
        struct Created: Decodable { let Id: String }
        do {
            let response = try await post(
                "/containers/create", query: [.init(name: "name", value: spec.name)], body: spec.body(), operation: "container create",
                timeout: timeout)
            return try decode(Created.self, from: response.body, "container create").Id
        } catch let error as DockerError where error.isInterruption {
            await reconcileAfterInterruptedCreate(name: spec.name)
            throw error
        } catch is CancellationError {
            await reconcileAfterInterruptedCreate(name: spec.name)
            throw DockerError.cancelled
        }
    }

    /// O `create` interrompido pode ainda estar a caminho no daemon (a requisição já foi escrita no socket): tenta
    /// `rm -f` pelo nome em intervalos crescentes e só desiste depois de ~2,5 s sem achar o container.
    private func reconcileAfterInterruptedCreate(name: String) async {
        let client = self
        // DETACHED: a reconciliação precisa terminar mesmo com a task do chamador cancelada.
        await Task.detached {
            for delay in [Duration.zero, .milliseconds(250), .milliseconds(500), .milliseconds(750), .milliseconds(1000)] {
                if delay > .zero { try? await Task.sleep(for: delay) }
                if (try? await client.removeContainerIfPresent(name, force: true, removeVolumes: true, timeout: .seconds(15))) == true {
                    return
                }
            }
        }.value
    }

    /// `304` (já iniciado) conta como sucesso.
    public func startContainer(_ id: String) async throws {
        try await post("/containers/\(id)/start", operation: "container start", accept: [304])
    }

    /// `304` (já parado) conta como sucesso. `timeout` é o tempo até o SIGKILL, em segundos.
    public func stopContainer(_ id: String, signal: String? = nil, graceSeconds: Int = 10) async throws {
        var query: [URLQueryItem] = [.init(name: "t", value: String(graceSeconds))]
        if let signal { query.append(.init(name: "signal", value: signal)) }
        try await post("/containers/\(id)/stop", query: query, operation: "container stop", accept: [304],
                       timeout: .seconds(Int64(graceSeconds) + 30))
    }

    public func killContainer(_ id: String, signal: String = "SIGKILL") async throws {
        try await post("/containers/\(id)/kill", query: [.init(name: "signal", value: signal)], operation: "container kill")
    }

    /// Remove o container. Inexistente (404) é sucesso: a remoção é idempotente.
    public func removeContainer(_ id: String, force: Bool = false, removeVolumes: Bool = false, timeout: Duration? = nil) async throws {
        _ = try await removeContainerIfPresent(id, force: force, removeVolumes: removeVolumes, timeout: timeout)
    }

    /// `true` se o container existia e foi removido; `false` se já não existia.
    @discardableResult
    func removeContainerIfPresent(_ id: String, force: Bool, removeVolumes: Bool, timeout: Duration?) async throws -> Bool {
        do {
            _ = try await transport.send(
                HTTPRequest(method: "DELETE", path: "/containers/\(id)", query: [
                    .init(name: "force", value: force ? "1" : "0"), .init(name: "v", value: removeVolumes ? "1" : "0"),
                ]),
                timeout: timeout ?? .seconds(60), operation: "container remove")
            return true
        } catch let error as DockerError where error.isNotFound {
            return false
        }
    }

    public func inspectContainer(_ id: String) async throws -> ContainerInspect {
        try await get(ContainerInspect.self, "/containers/\(id)/json", operation: "container inspect")
    }

    public func listContainers(all: Bool = true, filters: [String: [String]] = [:]) async throws -> [ContainerSummary] {
        var query = [URLQueryItem(name: "all", value: all ? "1" : "0")]
        if let item = Self.filtersItem(filters) { query.append(item) }
        return try await get([ContainerSummary].self, "/containers/json", query: query, operation: "container list")
    }

    /// Espera o container sair e devolve o `StatusCode`. Sem prazo por padrão: o chamador cancela a `Task`.
    public func waitContainer(_ id: String, condition: String = "not-running", timeout: Duration? = nil) async throws -> Int {
        struct Result: Decodable { let StatusCode: Int }
        var request = HTTPRequest(method: "POST", path: "/containers/\(id)/wait", query: [.init(name: "condition", value: condition)])
        request.body = nil
        let response = try await transport.send(request, timeout: timeout, operation: "container wait")
        return try decode(Result.self, from: response.body, "container wait").StatusCode
    }

    /// Logs de um container sem TTY (stdout/stderr demultiplexados). `follow: true` fica aberto até o container sair.
    public func logs(_ id: String, follow: Bool = false, stdout: Bool = true, stderr: Bool = true, tail: Int? = nil,
                     since: Int? = nil, timestamps: Bool = false) async throws -> AsyncThrowingStream<DockerStreamFrame, any Error> {
        var query: [URLQueryItem] = [
            .init(name: "follow", value: follow ? "1" : "0"), .init(name: "stdout", value: stdout ? "1" : "0"),
            .init(name: "stderr", value: stderr ? "1" : "0"), .init(name: "timestamps", value: timestamps ? "1" : "0"),
        ]
        if let tail { query.append(.init(name: "tail", value: String(tail))) }
        if let since { query.append(.init(name: "since", value: String(since))) }
        let (head, body) = try await transport.stream(
            HTTPRequest(method: "GET", path: "/containers/\(id)/logs", query: query), headTimeout: defaultTimeout, operation: "container logs")
        let multiplexed = !(head.contentType?.contains("raw-stream") ?? false)
        return Self.frames(from: body, multiplexed: multiplexed)
    }

    /// Todos os logs até agora, como texto por fluxo.
    public func collectedLogs(_ id: String, tail: Int? = nil) async throws -> (stdout: String, stderr: String) {
        var out = Data(), err = Data()
        for try await frame in try await logs(id, follow: false, tail: tail) {
            if frame.kind == .stderr { err.append(frame.data) } else { out.append(frame.data) }
        }
        return (String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
    }

    /// Uma amostra de `stats` (sem stream), para a média móvel de estimativas de memória (07 CS-130).
    public func statsSnapshot(_ id: String) async throws -> ContainerStatsSnapshot {
        struct Stats: Decodable {
            struct Memory: Decodable { let usage: Int64?; let limit: Int64? }
            struct CPU: Decodable { struct Usage: Decodable { let total_usage: Int64? }; let cpu_usage: Usage? }
            struct Pids: Decodable { let current: Int? }
            let memory_stats: Memory?
            let cpu_stats: CPU?
            let pids_stats: Pids?
        }
        let stats = try await get(Stats.self, "/containers/\(id)/stats", query: [.init(name: "stream", value: "0"), .init(name: "one-shot", value: "1")], operation: "container stats")
        return ContainerStatsSnapshot(
            memoryUsageBytes: stats.memory_stats?.usage ?? 0, memoryLimitBytes: stats.memory_stats?.limit ?? 0,
            cpuTotalUsageNanos: stats.cpu_stats?.cpu_usage?.total_usage ?? 0, pids: stats.pids_stats?.current ?? 0)
    }

    // MARK: Exec

    /// Cria o exec e o inicia sobre conexão hijacked (07 CS-102, S9).
    public func startExec(in container: String, spec: ExecSpec) async throws -> ExecSession {
        var command = spec.command
        var pidFile: String?
        if spec.killableGroup {
            let file = "/tmp/.abx-exec-\(UUID().uuidString.lowercased())"
            pidFile = file
            // O processo do exec é líder de sessão e de grupo (pid == pgid), então `kill -- -pid` alcança os filhos.
            command = ["/bin/sh", "-c", "echo $$ > \"$0\"; exec \"$@\"", file] + spec.command
        }
        var body: [String: JSONValue] = [
            "AttachStdin": .bool(spec.attachStdin), "AttachStdout": .bool(true), "AttachStderr": .bool(true), "Tty": .bool(false),
            "Cmd": .strings(command),
        ]
        if !spec.environment.isEmpty { body["Env"] = .strings(spec.environment) }
        if let user = spec.user { body["User"] = .string(user) }
        if let dir = spec.workingDirectory { body["WorkingDir"] = .string(dir) }
        struct Created: Decodable { let Id: String }
        let created = try await post("/containers/\(container)/exec", body: .object(body), operation: "exec create")
        let execID = try decode(Created.self, from: created.body, "exec create").Id

        var request = HTTPRequest(method: "POST", path: "/exec/\(execID)/start")
        request.body = try json(.object(["Detach": .bool(false), "Tty": .bool(false)]))
        request.headers["Content-Type"] = "application/json"
        let (head, connection) = try await transport.hijack(request, timeout: defaultTimeout, operation: "exec start")
        let multiplexed = !(head.contentType?.contains("raw-stream") ?? false)
        return ExecSession(client: self, containerID: container, execID: execID, connection: connection, pidFile: pidFile, multiplexed: multiplexed,
                           upgradeStatus: head.status, streamContentType: head.contentType)
    }

    public func inspectExec(_ id: String) async throws -> ExecInspect {
        try await get(ExecInspect.self, "/exec/\(id)/json", operation: "exec inspect")
    }

    /// Executa um comando curto até o fim e devolve stdout, stderr e o código de saída.
    public func run(in container: String, command: [String], stdin: Data? = nil, user: String? = nil, timeout: Duration = .seconds(60),
                    killableGroup: Bool = true) async throws -> ExecResult {
        let session = try await startExec(in: container, spec: ExecSpec(command: command, attachStdin: stdin != nil, killableGroup: killableGroup, user: user))
        if let stdin {
            try await session.writeStdin(stdin)
            session.closeStdin()
        }
        return try await session.collect(timeout: timeout)
    }

    // MARK: Redes

    /// Cria a rede. `internal: true` = sem rota para fora (07 CS-110). Devolve o id.
    public func createNetwork(name: String, isInternal: Bool, labels: [String: String] = [:], driver: String = "bridge") async throws -> String {
        struct Created: Decodable { let Id: String }
        let response = try await post("/networks/create", body: .object([
            "Name": .string(name), "Driver": .string(driver), "Internal": .bool(isInternal), "CheckDuplicate": .bool(true),
            "Labels": .map(labels),
        ]), operation: "network create")
        return try decode(Created.self, from: response.body, "network create").Id
    }

    public func inspectNetwork(_ id: String) async throws -> NetworkInspect {
        try await get(NetworkInspect.self, "/networks/\(id)", operation: "network inspect")
    }

    public func listNetworks(filters: [String: [String]] = [:]) async throws -> [NetworkInspect] {
        try await get([NetworkInspect].self, "/networks", query: Self.filtersItem(filters).map { [$0] } ?? [], operation: "network list")
    }

    public func connectNetwork(_ network: String, container: String, aliases: [String] = []) async throws {
        var endpoint: [String: JSONValue] = [:]
        if !aliases.isEmpty { endpoint["Aliases"] = .strings(aliases) }
        try await post("/networks/\(network)/connect", body: .object(["Container": .string(container), "EndpointConfig": .object(endpoint)]), operation: "network connect")
    }

    /// Remove a rede; inexistente é sucesso.
    public func removeNetwork(_ id: String) async throws {
        do {
            _ = try await transport.send(HTTPRequest(method: "DELETE", path: "/networks/\(id)"), timeout: defaultTimeout, operation: "network remove")
        } catch let error as DockerError where error.isNotFound {
            return
        }
    }

    // MARK: Volumes

    public func createVolume(name: String, labels: [String: String] = [:]) async throws -> VolumeInspect {
        let response = try await post("/volumes/create", body: .object(["Name": .string(name), "Labels": .map(labels)]), operation: "volume create")
        return try decode(VolumeInspect.self, from: response.body, "volume create")
    }

    public func inspectVolume(_ name: String) async throws -> VolumeInspect {
        try await get(VolumeInspect.self, "/volumes/\(name)", operation: "volume inspect")
    }

    public func listVolumes(filters: [String: [String]] = [:]) async throws -> [VolumeInspect] {
        struct Listing: Decodable { let Volumes: [VolumeInspect]? }
        return try await get(Listing.self, "/volumes", query: Self.filtersItem(filters).map { [$0] } ?? [], operation: "volume list").Volumes ?? []
    }

    public func removeVolume(_ name: String, force: Bool = false) async throws {
        do {
            _ = try await transport.send(
                HTTPRequest(method: "DELETE", path: "/volumes/\(name)", query: [.init(name: "force", value: force ? "1" : "0")]),
                timeout: defaultTimeout, operation: "volume remove")
        } catch let error as DockerError where error.isNotFound {
            return
        }
    }

    // MARK: Eventos

    /// Stream de `/events` (CS-103). Sem `until`, fica aberto até cancelar. Use `EventMonitor` para reconexão.
    public func events(filters: [String: [String]] = [:], since: Int64? = nil, until: Int64? = nil) async throws -> AsyncThrowingStream<DockerEvent, any Error> {
        var query: [URLQueryItem] = []
        if let item = Self.filtersItem(filters) { query.append(item) }
        if let since { query.append(.init(name: "since", value: String(since))) }
        if let until { query.append(.init(name: "until", value: String(until))) }
        let (_, body) = try await transport.stream(HTTPRequest(method: "GET", path: "/events", query: query), headTimeout: defaultTimeout, operation: "events")
        return Self.decodeLines(body, as: DockerEvent.self) { _ in }
    }

    // MARK: Decodificação de streams

    static func decodeLines<T: Decodable & Sendable>(
        _ body: AsyncThrowingStream<Data, any Error>, as type: T.Type, inspect: @escaping @Sendable (T) throws -> Void
    ) -> AsyncThrowingStream<T, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var splitter = LineSplitter()
                let decoder = JSONDecoder()
                do {
                    for try await chunk in body {
                        for line in splitter.feed(chunk) {
                            guard let value = try? decoder.decode(T.self, from: line) else { continue }
                            try inspect(value)
                            continuation.yield(value)
                        }
                    }
                    if let tail = splitter.flush(), let value = try? decoder.decode(T.self, from: tail) {
                        try inspect(value)
                        continuation.yield(value)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func frames(from body: AsyncThrowingStream<Data, any Error>, multiplexed: Bool) -> AsyncThrowingStream<DockerStreamFrame, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var demuxer = MultiplexDemuxer()
                do {
                    for try await chunk in body {
                        if multiplexed {
                            for frame in try demuxer.feed(chunk) { continuation.yield(frame) }
                        } else {
                            continuation.yield(DockerStreamFrame(kind: .stdout, data: chunk))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
