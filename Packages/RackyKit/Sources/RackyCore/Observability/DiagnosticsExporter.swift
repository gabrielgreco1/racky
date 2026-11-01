import RackyDocker
import RackyPlatform
import RackyProtocol
import RackyStore
import Foundation

/// Reúne as fontes do pacote de diagnóstico (08 AR-603) e o salva em `diagnostics/`. O que a UI sabe (versões dos CLIs, configurações,
/// estado do daemon, resultado da checklist) chega pronto em `Context`; o resto é lido aqui do disco e do Store.
public struct DiagnosticsExportContext: Sendable {
    public var paths: StorePaths
    public var store: RackyStore?
    public var versions: [String: String]
    public var settingsJSON: String
    public var daemonSessions: [DiagnosticsBundleInput.DaemonSession]
    public var checks: [String: String]
    public var crashReports: [String]
    public var reportsDirectory: URL
    public var dockerSummary: @Sendable () async -> [String: String]

    public init(
        paths: StorePaths, store: RackyStore?, versions: [String: String], settingsJSON: String,
        daemonSessions: [DiagnosticsBundleInput.DaemonSession], checks: [String: String], crashReports: [String] = [],
        reportsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true),
        dockerSummary: @escaping @Sendable () async -> [String: String] = { await DiagnosticsExporter.liveDockerSummary() }
    ) {
        self.paths = paths; self.store = store; self.versions = versions; self.settingsJSON = settingsJSON
        self.daemonSessions = daemonSessions; self.checks = checks; self.crashReports = crashReports
        self.reportsDirectory = reportsDirectory; self.dockerSummary = dockerSummary
    }
}

public enum DiagnosticsExporter {
    public static let metricWindow: TimeInterval = 7 * 24 * 3600

    /// Monta o pacote numa pasta de preparo e devolve a lista de arquivos (a UI a mostra ANTES de salvar).
    public static func prepare(_ context: DiagnosticsExportContext, now: Date = Date()) async throws -> DiagnosticsBundle {
        DiskLog.current?.flush()
        let fm = FileManager.default
        let logFiles = RecentErrors.logFiles(in: context.paths.logsDirectory)
        var versions = context.versions
        versions["protocol"] = ProtocolVersion.current.description
        var counts: [String: Int] = [:]
        var metrics: [StoredMetric] = []
        if let store = context.store {
            counts = (try? await store.tableCounts()) ?? [:]
            metrics = (try? await store.metrics(since: now.addingTimeInterval(-metricWindow))) ?? []
            versions["schema"] = (try? await store.appliedMigrations())?.last ?? "unknown"
        }
        let input = DiagnosticsBundleInput(
            logFiles: logFiles, versions: versions, settingsJSON: context.settingsJSON, dockerSummary: await context.dockerSummary(),
            tableCounts: counts, metrics: metrics, crashReports: context.crashReports.map { context.reportsDirectory.appendingPathComponent($0) },
            daemonSessions: context.daemonSessions, checks: context.checks,
            recentErrors: RecentErrors.read(logFiles: logFiles, limit: 50).map(\.line))
        let staging = context.paths.diagnosticsDirectory.appendingPathComponent(".staging", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return try DiagnosticsBundleBuilder.build(input, stagingRoot: staging, now: now)
    }

    /// Apaga preparos não salvos de uma execução anterior (o app saiu com a lista aberta).
    public static func clearStaging(paths: StorePaths) {
        try? FileManager.default.removeItem(at: paths.diagnosticsDirectory.appendingPathComponent(".staging", isDirectory: true))
    }

    /// Salva o zip em `diagnostics/<nome>.zip` e apaga a pasta de preparo.
    public static func save(_ bundle: DiagnosticsBundle, paths: StorePaths) async throws -> URL {
        defer { bundle.discard() }
        return try await bundle.writeZip(to: paths.diagnosticsDirectory.appendingPathComponent("\(bundle.name).zip"))
    }

    /// `docker info` resumido (runtime, versão, memória, capacidade) pela Engine API; nunca chama o CLI `docker`.
    public static func liveDockerSummary() async -> [String: String] {
        switch await LiveDiagnosticsProbes.docker(detector: RuntimeDetector(), applicationExists: { FileManager.default.fileExists(atPath: $0) }) {
        case .notInstalled: return ["state": "not installed"]
        case .installedNotRunning(let kind): return ["state": "not running", "runtime": "\(kind)"]
        case .running(let info):
            return [
                "state": "running", "runtime": "\(info.runtime.kind)", "version": info.version, "memoryGB": "\(info.memoryGB)",
                "headlessCapacity": "\(info.headlessCapacity)", "verifiedArchitecture": "\(info.isVerifiedArchitecture)",
                "architecture": ProcessInfo.processInfo.machineArchitecture,
            ]
        }
    }

    /// Versões de `git`, `gh` e `docker` (procura nos diretórios comuns; o app aberto pelo Finder tem PATH mínimo).
    public static func cliVersions(names: [String] = ["git", "gh", "docker"], directories: [String] = ["/usr/bin", "/opt/homebrew/bin", "/usr/local/bin"]) async -> [String: String] {
        await withTaskGroup(of: (String, String).self) { group in
            for name in names {
                group.addTask {
                    guard let path = directories.map({ "\($0)/\(name)" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
                          let out = try? await ProcessRunner.run(ProcessRequest(executable: URL(fileURLWithPath: path), arguments: ["--version"], timeout: .seconds(4))),
                          out.exitCode == 0 else { return (name, "not found") }
                    return (name, out.stdoutString.split(whereSeparator: \.isNewline).first.map(String.init) ?? "unknown")
                }
            }
            var result: [String: String] = [:]
            for await (name, version) in group { result[name] = version }
            return result
        }
    }
}

extension ProcessInfo {
    fileprivate var machineArchitecture: String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
    }
}
