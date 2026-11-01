import Foundation

public struct ExecResult: Sendable, Equatable {
    public var exitCode: Int
    public var stdout: Data
    public var stderr: Data
    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

/// Exec com conexão hijacked: stdin, stdout e stderr independentes, half-close do stdin e encerramento do grupo
/// de processos (07 CS-102, spike S9). `output` só pode ser consumido uma vez.
public final class ExecSession: Sendable {
    public let id: String
    public let containerID: String
    /// Frames de stdout/stderr, na ordem de chegada. Termina no EOF da conexão (o processo fechou os dois fluxos).
    public let output: AsyncThrowingStream<DockerStreamFrame, any Error>
    /// Status HTTP do upgrade (`101` esperado) e `Content-Type` do stream, para diagnóstico entre runtimes (S9).
    public let upgradeStatus: Int
    public let streamContentType: String?

    private let client: DockerClient
    private let connection: HijackedConnection
    private let pidFile: String?

    init(client: DockerClient, containerID: String, execID: String, connection: HijackedConnection, pidFile: String?, multiplexed: Bool,
         upgradeStatus: Int = 101, streamContentType: String? = nil) {
        self.upgradeStatus = upgradeStatus
        self.streamContentType = streamContentType
        self.client = client
        self.containerID = containerID
        id = execID
        self.connection = connection
        self.pidFile = pidFile
        output = AsyncThrowingStream { continuation in
            let task = Task {
                var demuxer = MultiplexDemuxer()
                do {
                    while let chunk = try await connection.receive() {
                        if multiplexed {
                            for frame in try demuxer.feed(chunk) { continuation.yield(frame) }
                        } else {
                            continuation.yield(DockerStreamFrame(kind: .stdout, data: chunk))
                        }
                    }
                    if Task.isCancelled { continuation.finish(throwing: DockerError.cancelled) } else { continuation.finish() }
                } catch {
                    continuation.finish(throwing: error)
                }
                connection.close()
            }
            continuation.onTermination = { _ in
                task.cancel()
                connection.close()
            }
        }
    }

    public func writeStdin(_ data: Data) async throws {
        do { try await connection.send(data) } catch {
            throw DockerError.transport("escrita no stdin falhou: \(error)")
        }
    }

    /// Half-close do stdin: o processo recebe EOF e a leitura continua aberta.
    public func closeStdin() { connection.finishWriting() }

    public func close() { connection.close() }

    /// Código de saída. Espera o processo terminar (`Running == false`) consultando o exec; cancelável.
    public func exitCode(pollEvery interval: Duration = .milliseconds(25)) async throws -> Int {
        while true {
            let inspect = try await client.inspectExec(id)
            if !inspect.running, let code = inspect.exitCode { return code }
            try await Task.sleep(for: interval)
        }
    }

    /// Consome `output` até o fim e devolve tudo com o código de saída. No prazo, termina o grupo e lança `.timeout`.
    public func collect(timeout: Duration? = nil) async throws -> ExecResult {
        do {
            return try await withDeadline(timeout, operation: "exec") { [self] in
                var out = Data(), err = Data()
                for try await frame in output {
                    if frame.kind == .stderr { err.append(frame.data) } else { out.append(frame.data) }
                }
                return ExecResult(exitCode: try await exitCode(), stdout: out, stderr: err)
            }
        } catch let error as DockerError where error.isInterruption {
            await terminateDetached()
            throw error
        } catch is CancellationError {
            await terminateDetached()
            throw DockerError.cancelled
        }
    }

    /// Envia `signal` (`TERM`, `KILL`, `INT`...) ao grupo de processos do exec. Exige `ExecSpec.killableGroup`.
    public func signalGroup(_ signal: String) async throws {
        guard let pidFile else { throw DockerError.execNotKillable }
        let script = "p=$(cat \"$0\" 2>/dev/null) || exit 0; kill -s \"$1\" -- \"-$p\" 2>/dev/null || kill -s \"$1\" \"$p\" 2>/dev/null; exit 0"
        let control = try await client.startExec(in: containerID, spec: ExecSpec(command: ["/bin/sh", "-c", script, pidFile, signal]))
        _ = try await control.collect(timeout: .seconds(10))
    }

    /// SIGTERM no grupo; se o exec ainda estiver rodando depois de `grace`, SIGKILL (S9).
    public func terminate(grace: Duration = .seconds(3)) async throws {
        try await signalGroup("TERM")
        let deadline = ContinuousClock.now + grace
        while ContinuousClock.now < deadline {
            if !(try await client.inspectExec(id)).running { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        try await signalGroup("KILL")
    }

    private func terminateDetached() async {
        let session = self
        // DETACHED: o encerramento do grupo precisa rodar mesmo quando a task do chamador já foi cancelada.
        await Task.detached { try? await session.terminate(grace: .seconds(2)) }.value
        connection.close()
    }
}
