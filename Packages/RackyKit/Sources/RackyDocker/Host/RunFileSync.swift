import Foundation

/// Traz o que o agente escreveu no host remoto para a MESMA pasta do run do Mac (07 §2.8: `work/` e `logs/`), antes de a VM sumir.
/// Usa a API de arquivo do Docker (tar) pelo mesmo transporte da Engine API; nada de rsync/scp nem segunda porta.
/// Aditivo: arquivos locais que o remoto não tem ficam; os que existem nos dois lados são sobrescritos pela versão do computador.
public struct RunFileSync: Sendable {
    public static let remoteWork = "/work"
    public static let remoteLogs = "/run/racky/logs"

    public let client: DockerClient
    public let maxBytes: Int64

    public init(client: DockerClient, maxBytes: Int64 = 4 << 30) { self.client = client; self.maxBytes = maxBytes }

    public struct Result: Sendable, Equatable {
        public var work: TarExtractionReport
        public var logs: TarExtractionReport
    }

    /// `remotePath` dentro do container, para `directory` no Mac (criada se faltar).
    @discardableResult
    public func pull(container: String, remotePath: String, into directory: URL) async throws -> TarExtractionReport {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stream = try await client.archive(container, path: remotePath.hasSuffix("/.") ? remotePath : remotePath + "/.")
        var extractor = TarExtractor(destination: directory, maxBytes: maxBytes)
        for try await chunk in stream { try extractor.feed(chunk) }
        return try extractor.finish()
    }

    public func pullRun(container: String, workDirectory: URL, logsDirectory: URL) async throws -> Result {
        let work = try await pull(container: container, remotePath: Self.remoteWork, into: workDirectory)
        let logs = try await pull(container: container, remotePath: Self.remoteLogs, into: logsDirectory)
        return Result(work: work, logs: logs)
    }
}
