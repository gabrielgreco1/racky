import RackyPlatform
import RackyStore
import Foundation
import Testing
@testable import RackyCore

/// AC-T17: o pacote de diagnóstico não leva segredo, token nem caminho pessoal (08 AR-602/603).
@Suite struct DiagnosticsBundleTests {
    private static let secrets = [
        "sk-ant-api03-AbCdEfGhIjKlMnOp1234", "ghp_abcdefghijklmnopqrstuvwxyz0123456789", "github_pat_11ABCDEFG0abcdefghijklmnop_qrstuvwxyz",
        "s3cr3tProxyPass", "0123456789abcdef0123456789abcdef", "hunter2-password", "bearer-token-value-12345",
    ]
    private static let leaks = secrets + ["/Users/me", "alex/code"]

    private func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("abbundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func unzip(_ zip: URL, into dir: URL) async throws {
        let out = try await ProcessRunner.run(ProcessRequest(executable: URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-q", zip.path, "-d", dir.path]))
        #expect(out.exitCode == 0, "\(out.stderrString)")
    }

    private func allText(under root: URL) -> [String: String] {
        var result: [String: String] = [:]
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = walker?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            result[url.path.replacingOccurrences(of: root.path, with: "")] = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        return result
    }

    /// Planta cada segredo em todos os cantos que o pacote lê: log, relatório de crash, versões, configurações, Docker, sessões, métricas.
    @Test func zipHasNoSecretAndNoPrivatePathAnywhere() async throws {
        let work = try temp(); defer { try? FileManager.default.removeItem(at: work) }
        let logs = work.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        // log "cru": simula um arquivo gravado por uma versão antiga, sem redação na escrita; a exportação redige de novo
        let raw = """
        {"level":"error","msg":"docker failed with \(Self.secrets[0]) for /Users/me/code/racky","category":"docker"}
        {"level":"info","msg":"git remote https://alex:\(Self.secrets[3])@github.com/x/y.git \(Self.secrets[1])"}
        {"level":"error","msg":"Authorization: Bearer \(Self.secrets[6]) proxy http://\(Self.secrets[4]):@api.zyte.com:8011"}
        """
        try raw.write(to: logs.appendingPathComponent("app.jsonl"), atomically: true, encoding: .utf8)
        let crash = work.appendingPathComponent("Racky-1.ips")
        try "{\"x\":\"\(Self.secrets[2]) /Users/me/crash\"}".write(to: crash, atomically: true, encoding: .utf8)

        let input = DiagnosticsBundleInput(
            logFiles: [logs.appendingPathComponent("app.jsonl")],
            versions: ["claude": "2.1.302 (token=\(Self.secrets[5]))", "app": "1.0"],
            settingsJSON: "{\"worktreeFolder\":\"/Users/me/code/worktrees\",\"password\":\"\(Self.secrets[5])\"}",
            dockerSummary: ["state": "running", "socket": "/Users/me/.docker/run/docker.sock"],
            tableCounts: ["project": 2, "session": 5],
            metrics: [StoredMetric(name: "launch.agent", value: 812, unit: "ms", tags: ["cwd": "/Users/me/code"], at: Date())],
            crashReports: [crash],
            daemonSessions: [.init(id: "S-1", state: "running", ageSeconds: 30, endSeq: 4096)],
            checks: ["gh": "problem: not logged in (\(Self.secrets[1]))"],
            recentErrors: ["boom \(Self.secrets[0])"])
        let bundle = try DiagnosticsBundleBuilder.build(input, stagingRoot: work.appendingPathComponent("staging"))

        // a lista que a UI mostra antes de salvar
        let names = bundle.entries.map(\.path)
        #expect(names.contains("logs/app.jsonl") && names.contains("versions.json") && names.contains("docker.json") && names.contains("metrics.json"))
        #expect(names.contains("tables.json") && names.contains("settings.json") && names.contains("daemon-sessions.json") && names.contains("crashes/Racky-1.ips"))

        let zip = try await bundle.writeZip(to: work.appendingPathComponent("out/bundle.zip"))
        let extracted = work.appendingPathComponent("extracted")
        try await unzip(zip, into: extracted)
        let files = allText(under: extracted)
        #expect(files.count == bundle.entries.count)
        for (path, text) in files {
            for leak in Self.leaks { #expect(!text.contains(leak), "\(path) contém \(leak)") }
            #expect(LogRedactor.isClean(text), "\(path) ainda tem algo que a redação pegaria")
        }
        // o conteúdo útil sobrevive à redação
        let log = try #require(files.first { $0.key.hasSuffix("app.jsonl") }?.value)
        #expect(log.contains("docker failed") && log.contains("~/code/racky") && log.contains(LogRedactor.marker))
        #expect(files.first { $0.key.hasSuffix("versions.json") }?.value.contains("2.1.302") == true)
    }

    @Test func bigLogsAreTrimmedToTheMostRecentBytes() throws {
        let work = try temp(); defer { try? FileManager.default.removeItem(at: work) }
        let big = work.appendingPathComponent("app.jsonl")
        let line = String(repeating: "a", count: 99) + "\n"
        try String(repeating: line, count: 40_000).appending("LAST-LINE\n").write(to: big, atomically: true, encoding: .utf8)
        let bundle = try DiagnosticsBundleBuilder.build(DiagnosticsBundleInput(logFiles: [big]), stagingRoot: work.appendingPathComponent("s"))
        let entry = try #require(bundle.entries.first { $0.path == "logs/app.jsonl" })
        #expect(entry.bytes <= DiagnosticsBundleBuilder.maxFileBytes)
        let text = try String(contentsOf: bundle.staging.appendingPathComponent("logs/app.jsonl"), encoding: .utf8)
        #expect(text.hasSuffix("LAST-LINE\n"))
    }

    @Test func recentErrorsReadsOnlyErrorLevelNewestFirst() throws {
        let work = try temp(); defer { try? FileManager.default.removeItem(at: work) }
        let url = work.appendingPathComponent("app.jsonl")
        try """
        {"t":"2026-10-20T10:00:00.000Z","level":"error","process":"app","category":"docker","msg":"first"}
        {"t":"2026-10-20T10:00:01.000Z","level":"info","process":"app","category":"ui","msg":"noise"}
        {"t":"2026-10-20T10:00:02.000Z","level":"error","process":"ptyd","category":"session","msg":"second"}
        not json
        """.write(to: url, atomically: true, encoding: .utf8)
        let errors = RecentErrors.read(logFiles: [url], limit: 10)
        #expect(errors.map(\.message) == ["second", "first"] && errors.first?.process == "ptyd")
        #expect(RecentErrors.read(logFiles: [url], limit: 1).count == 1)
    }

    /// O pacote de verdade a partir de um Store aberto e um DiskLog real: tudo passa pelo `DiagnosticsExporter`.
    @Test func exporterBuildsFromRealStoreAndDiskLogAndSavesUnderDiagnostics() async throws {
        let work = try temp(); defer { try? FileManager.default.removeItem(at: work) }
        let paths = StorePaths(root: work)
        let store = try await RackyStore.open(paths: paths)
        try await store.recordMetrics([MetricSample(name: "launch.agent", value: 700)])
        let log = DiskLog(.init(directory: paths.logsDirectory, process: "app"))
        DiskLog.install(log)
        defer { DiskLog.install(nil) }
        LogFacade(.app, category: "launch").error("launch failed \(Self.secrets[0]) in /Users/me/x")
        let context = DiagnosticsExportContext(
            paths: paths, store: store, versions: ["app": "1.0"], settingsJSON: "{}", daemonSessions: [], checks: [:],
            reportsDirectory: work.appendingPathComponent("none"), dockerSummary: { ["state": "fake"] })
        let bundle = try await DiagnosticsExporter.prepare(context)
        let names = bundle.entries.map(\.path)
        #expect(names.contains("logs/app.jsonl") && names.contains("metrics.json") && names.contains("tables.json"))
        let tables = try String(contentsOf: bundle.staging.appendingPathComponent("tables.json"), encoding: .utf8)
        #expect(tables.contains("\"metric\" : 1"))
        let versions = try String(contentsOf: bundle.staging.appendingPathComponent("versions.json"), encoding: .utf8)
        #expect(versions.contains("v11_subagent_harness") && versions.contains("\"protocol\""))
        let zip = try await DiagnosticsExporter.save(bundle, paths: paths)
        #expect(zip.deletingLastPathComponent().lastPathComponent == "diagnostics" && FileManager.default.fileExists(atPath: zip.path))
        #expect(!FileManager.default.fileExists(atPath: bundle.staging.path), "preparo apagado depois de salvar")
        try await store.close()
    }
}
