import RackyPlatform
import RackyStore
import Foundation

/// Pacote de diagnóstico (08 AR-603): `.zip` redigido com logs, versões, resumo do Docker, contagens por tabela, configurações sem
/// segredos, métricas dos últimos 7 dias, relatórios de crash recentes e o estado das sessões do daemon. Nada sai da máquina.
public struct DiagnosticsBundleInput: Sendable {
    public struct DaemonSession: Sendable, Equatable {
        public var id: String
        public var state: String
        public var ageSeconds: Int
        public var endSeq: UInt64
        public init(id: String, state: String, ageSeconds: Int, endSeq: UInt64) {
            self.id = id; self.state = state; self.ageSeconds = ageSeconds; self.endSeq = endSeq
        }
    }

    /// Arquivos JSONL de log (`logs/*.jsonl`) dos processos; já saem redigidos, e a exportação redige de novo.
    public var logFiles: [URL]
    public var versions: [String: String]
    /// Texto JSON das configurações (nomes e valores sem segredo); o pacote ainda passa a redação.
    public var settingsJSON: String
    public var dockerSummary: [String: String]
    public var tableCounts: [String: Int]
    public var metrics: [StoredMetric]
    public var crashReports: [URL]
    public var daemonSessions: [DaemonSession]
    /// Resultado da checklist (item -> estado e detalhe).
    public var checks: [String: String]
    public var recentErrors: [String]

    public init(
        logFiles: [URL] = [], versions: [String: String] = [:], settingsJSON: String = "{}", dockerSummary: [String: String] = [:],
        tableCounts: [String: Int] = [:], metrics: [StoredMetric] = [], crashReports: [URL] = [], daemonSessions: [DaemonSession] = [],
        checks: [String: String] = [:], recentErrors: [String] = []
    ) {
        self.logFiles = logFiles; self.versions = versions; self.settingsJSON = settingsJSON; self.dockerSummary = dockerSummary
        self.tableCounts = tableCounts; self.metrics = metrics; self.crashReports = crashReports; self.daemonSessions = daemonSessions
        self.checks = checks; self.recentErrors = recentErrors
    }
}

public struct DiagnosticsBundle: Sendable, Equatable {
    public struct Entry: Sendable, Equatable, Identifiable {
        public var path: String
        public var bytes: Int
        public var id: String { path }
    }

    /// Pasta de preparo: o que está aqui é exatamente o que o zip leva.
    public let staging: URL
    public let name: String
    public let entries: [Entry]

    public var totalBytes: Int { entries.reduce(0) { $0 + $1.bytes } }

    /// Gera o `.zip` (com `ditto`, que preserva a pasta-raiz do pacote) em `destination` e devolve o arquivo.
    @discardableResult
    public func writeZip(to destination: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.removeItem(at: destination)
        let output = try await ProcessRunner.run(ProcessRequest(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-c", "-k", "--keepParent", staging.path, destination.path], timeout: .seconds(60)))
        guard output.exitCode == 0 else { throw DiagnosticsBundleError.zipFailed(output.stderrString) }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return destination
    }

    /// Apaga a pasta de preparo (depois de salvar ou cancelar).
    public func discard() { try? FileManager.default.removeItem(at: staging) }
}

public enum DiagnosticsBundleError: Error, Sendable, Equatable {
    case zipFailed(String)
    case leakDetected(String)
}

public enum DiagnosticsBundleBuilder {
    /// Limite por arquivo de log/crash no pacote: o final do arquivo (o mais recente) é o que importa.
    static let maxFileBytes = 2 << 20

    public static func build(_ input: DiagnosticsBundleInput, stagingRoot: URL, now: Date = Date()) throws -> DiagnosticsBundle {
        let fm = FileManager.default
        let name = "Racky-diagnostics-\(stamp(now))"
        let root = stagingRoot.appendingPathComponent(name, isDirectory: true)
        try? fm.removeItem(at: root)
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        var entries: [DiagnosticsBundle.Entry] = []
        func put(_ path: String, _ text: String) throws {
            let clean = LogRedactor.redact(text)
            guard LogRedactor.isClean(clean) else { throw DiagnosticsBundleError.leakDetected(path) }
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = Data(clean.utf8)
            try data.write(to: url, options: .atomic)
            entries.append(.init(path: path, bytes: data.count))
        }
        func json(_ object: Any) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        }

        for url in input.logFiles { try put("logs/\(url.lastPathComponent)", tail(of: url)) }
        for url in input.crashReports.prefix(5) { try put("crashes/\(url.lastPathComponent)", tail(of: url)) }
        try put("versions.json", try json(input.versions))
        try put("settings.json", input.settingsJSON)
        // Sem Docker em uso (runtime nativo) não há o que resumir: o arquivo nem entra na lista.
        if !input.dockerSummary.isEmpty { try put("docker.json", try json(input.dockerSummary)) }
        try put("tables.json", try json(input.tableCounts))
        try put("checks.json", try json(input.checks))
        try put("recent-errors.txt", input.recentErrors.joined(separator: "\n"))
        let rows = input.metrics.map { m in
            ["name": m.name, "value": m.value, "unit": m.unit, "tags": m.tags, "at": m.at.formatted(.iso8601)] as [String: Any]
        }
        try put("metrics.json", try json(rows))
        let sessions = input.daemonSessions.map { ["id": $0.id, "state": $0.state, "ageSeconds": $0.ageSeconds, "endSeq": $0.endSeq] as [String: Any] }
        try put("daemon-sessions.json", try json(sessions))
        try put("README.txt", readme(now: now))
        return DiagnosticsBundle(staging: root, name: name, entries: entries.sorted { $0.path < $1.path })
    }

    private static func tail(of url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(maxFileBytes) ? size - UInt64(maxFileBytes) : 0
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func readme(now: Date) -> String {
        """
        Racky diagnostics, \(now.formatted(.iso8601)).
        Logs, versions, settings summary, table counts, metrics and crash reports. Tokens, credentials and personal folders are redacted.
        Nothing here was sent anywhere: share this file only if you choose to.
        """
    }

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }
}
