import RackyProtocol
import RackyPlatform
import Darwin
import Foundation

/// Sentinela `run/app.alive` (08 AR-604): criada no boot, apagada na saída limpa. No boot seguinte, sentinela presente com pid morto
/// = encerramento inesperado; o monitor procura relatórios `.ips` mais novos que a sentinela e prepara os detalhes (redigidos).
public struct AliveSentinel: Codable, Sendable, Equatable {
    public var pid: Int32
    public var build: String
    public var startedAt: Date
}

public struct CrashReportInfo: Codable, Sendable, Equatable {
    public var fileName: String
    public var process: String
    public var modifiedAt: Date
    /// Resumo do `.ips` (tipo da exceção, sinal, motivo), já redigido; vazio se o arquivo não pôde ser lido.
    public var summary: String
}

/// O que o boot achou: serve ao aviso (uma vez) e à linha "Recent crash" do Diagnostics.
public struct PreviousRunCrash: Codable, Sendable, Equatable {
    public var sentinel: AliveSentinel
    public var reports: [CrashReportInfo]
    public var detectedAt: Date
    /// O aviso já foi mostrado (não repete no boot seguinte).
    public var surfaced: Bool

    /// Texto para "Copy Details": versão, quando começou, relatórios; sem segredos nem caminhos pessoais.
    public var details: String {
        var lines = [
            "Racky quit unexpectedly.", "Build: \(sentinel.build)", "Started: \(Self.format(sentinel.startedAt))",
            "Detected: \(Self.format(detectedAt))", "Process id: \(sentinel.pid)",
        ]
        if reports.isEmpty { lines.append("No system crash report was found.") } else {
            lines.append("Crash reports:")
            for report in reports {
                lines.append("- \(report.fileName) (\(report.process), \(Self.format(report.modifiedAt)))")
                if !report.summary.isEmpty { lines.append("  \(report.summary)") }
            }
        }
        return LogRedactor.redact(lines.joined(separator: "\n"))
    }

    private static func format(_ date: Date) -> String { date.formatted(.iso8601) }
}

public struct CrashMonitor: Sendable {
    public static let processNames = ["Racky", "rackyd", "racky"]

    public let runDirectory: URL
    public let reportsDirectory: URL
    private let isAlive: @Sendable (Int32) -> Bool
    private let now: @Sendable () -> Date

    public init(
        runDirectory: URL,
        reportsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true),
        isAlive: @escaping @Sendable (Int32) -> Bool = CrashMonitor.processIsAlive, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.runDirectory = runDirectory
        self.reportsDirectory = reportsDirectory
        self.isAlive = isAlive
        self.now = now
    }

    public static func processIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    private var sentinelURL: URL { runDirectory.appendingPathComponent("app.alive") }
    private var lastCrashURL: URL { runDirectory.appendingPathComponent("last-crash.json") }

    /// No boot (depois do lock da instância): detecta o encerramento anterior e grava a sentinela desta execução.
    /// Devolve o crash só na PRIMEIRA vez em que o encontra.
    @discardableResult
    public func begin(build: String, pid: Int32 = getpid()) -> PreviousRunCrash? {
        let fm = FileManager.default
        try? fm.createDirectory(at: runDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var found: PreviousRunCrash?
        if let data = try? Data(contentsOf: sentinelURL), let old = try? Self.decoder.decode(AliveSentinel.self, from: data), old.pid != pid, !isAlive(old.pid) {
            let crash = PreviousRunCrash(sentinel: old, reports: reports(since: old.startedAt), detectedAt: now(), surfaced: false)
            save(crash)
            found = crash
        }
        let sentinel = AliveSentinel(pid: pid, build: build, startedAt: now())
        if let data = try? Self.encoder.encode(sentinel) { try? data.write(to: sentinelURL, options: .atomic) }
        return found
    }

    /// Saída limpa (⌘Q, fechar com "Stop all", sinal de término tratado): apaga a sentinela.
    public func endCleanly() {
        try? FileManager.default.removeItem(at: sentinelURL)
    }

    public func lastCrash() -> PreviousRunCrash? {
        (try? Data(contentsOf: lastCrashURL)).flatMap { try? Self.decoder.decode(PreviousRunCrash.self, from: $0) }
    }

    /// O aviso foi mostrado: não aparece de novo, mas a linha do Diagnostics continua até `dismiss`.
    public func markSurfaced() {
        guard var crash = lastCrash() else { return }
        crash.surfaced = true
        save(crash)
    }

    public func dismiss() {
        try? FileManager.default.removeItem(at: lastCrashURL)
    }

    private func save(_ crash: PreviousRunCrash) {
        if let data = try? Self.encoder.encode(crash) { try? data.write(to: lastCrashURL, options: .atomic) }
    }

    /// Relatórios do sistema do app e do daemon mais novos que `date` (5 no máximo, do mais novo ao mais antigo).
    func reports(since date: Date) -> [CrashReportInfo] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: reportsDirectory.path) else { return [] }
        var out: [CrashReportInfo] = []
        for name in names where name.hasSuffix(".ips") || name.hasSuffix(".crash") {
            guard let process = Self.processNames.first(where: { name.hasPrefix($0 + "-") || name.hasPrefix($0 + "_") }) else { continue }
            let url = reportsDirectory.appendingPathComponent(name)
            guard let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date, modified >= date else { continue }
            out.append(CrashReportInfo(fileName: name, process: process, modifiedAt: modified, summary: Self.summary(of: url)))
        }
        return Array(out.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(5))
    }

    /// `.ips` = uma linha de cabeçalho JSON e o corpo JSON; pega só tipo da exceção, sinal e motivo de término.
    static func summary(of url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url), let data = try? handle.read(upToCount: 2 << 20) else { return "" }
        try? handle.close()
        let text = String(decoding: data, as: UTF8.self)
        let body = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).dropFirst().first.map(String.init) ?? text
        guard let json = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else { return "" }
        var parts: [String] = []
        if let exception = json["exception"] as? [String: Any] {
            let type = exception["type"] as? String, signal = exception["signal"] as? String, subtype = exception["subtype"] as? String
            parts.append([type, signal.map { "(\($0))" }, subtype].compactMap { $0 }.joined(separator: " "))
        }
        if let termination = json["termination"] as? [String: Any], let indicator = termination["indicator"] as? String {
            parts.append("termination: \(indicator)")
        }
        return LogRedactor.redact(parts.filter { !$0.isEmpty }.joined(separator: "; "))
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
