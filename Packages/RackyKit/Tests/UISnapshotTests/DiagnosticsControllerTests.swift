import RackyCore
import RackyDocker
import RackyPlatform
import RackyProtocol
import RackyStore
import Foundation
import Synchronization
import Testing

@testable import RackyUI

/// Settings › Diagnostics (T4-04, AC-T17): crash do encerramento anterior avisado uma vez, "Copy Details", "Run All Checks Again" e o
/// pacote exportável com a lista de arquivos antes de salvar. Tudo em pastas temporárias, sondas falsas, nada de Docker nem `gh`.
@MainActor
@Suite(.serialized, .offscreenAppKit) struct DiagnosticsControllerTests {
    nonisolated final class Box: Sendable {
        private let state = Mutex<[String]>([])
        func add(_ s: String) { state.withLock { $0.append(s) } }
        var all: [String] { state.withLock { $0 } }
    }

    struct Rig {
        let controller: DiagnosticsController
        let registry: ActionRegistry
        let toasts: ToastCenter
        let paths: StorePaths
        let copied: Box
        let revealed: Box
        let ghCalls: Box
        let root: URL
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    private func rig(alive: Set<Int32> = []) throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("abdiag-\(UUID().uuidString)", isDirectory: true)
        let reports = root.appendingPathComponent("DiagnosticReports")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        let paths = StorePaths(root: root.appendingPathComponent("home"))
        let flags = SliceFlags(current: .slice4)
        let settings = SettingsModel(flags: flags, probe: SettingsModelTests.stub())
        let ghCalls = Box()
        let probes = DiagnosticsProbes(
            gh: { ghCalls.add("gh"); return GitHubProbeResult(installed: true, version: "2.60.1", auth: GitHubAuthStatus(state: .connected, host: "github.com")) },
            docker: { .installedNotRunning(kind: .desktop) }, image: { _ in .missing }, conflicts: { ConflictScan(findings: [], choice: nil, hasBackup: false) })
        let onboarding = OnboardingModel(settings: settings, diagnostics: DiagnosticsEngine(probes: probes))
        let toasts = ToastCenter()
        let crash = CrashMonitor(runDirectory: paths.runDirectory, reportsDirectory: reports, isAlive: { alive.contains($0) })
        let controller = DiagnosticsController(paths: paths, settings: settings, onboarding: onboarding, toasts: toasts, crash: crash)
        controller.reportsDirectory = reports
        settings.diagnostics = controller
        let copied = Box(), revealed = Box()
        controller.copy = { copied.add($0) }
        controller.reveal = { revealed.add($0.lastPathComponent) }
        controller.appInfo = { [("Racky version", "1.0"), ("Modes", "slice 4")] }
        let registry = ActionRegistry(flags: flags, surface: FakeSurface())
        try settings.registerActions(in: registry)
        try controller.registerActions(in: registry)
        return Rig(controller: controller, registry: registry, toasts: toasts, paths: paths, copied: copied, revealed: revealed, ghCalls: ghCalls, root: root)
    }

    @Test func previousCrashIsSurfacedOnceWithCopyDetails() async throws {
        let r = try rig(); defer { r.cleanup() }
        // execução anterior: sentinela deixada, pid 4242 morto, com um relatório do sistema mais novo
        let old = CrashMonitor(runDirectory: r.paths.runDirectory, reportsDirectory: r.controller.reportsDirectory, isAlive: { _ in false })
        _ = old.begin(build: "1.0 (7)", pid: 4242)
        try #"{"exception":{"type":"EXC_BREAKPOINT","signal":"SIGTRAP"}}"#.write(
            to: r.controller.reportsDirectory.appendingPathComponent("Racky-2026.ips"), atomically: true, encoding: .utf8)

        r.controller.start(build: "1.0 (8)", systemHooks: false, installLog: false)
        let toast = try #require(r.toasts.items.first)
        #expect(toast.kind == .warning && toast.title == "Racky quit unexpectedly." && toast.action?.action == .appCopyDetails)
        #expect(r.controller.lastCrash?.reports.map(\.fileName) == ["Racky-2026.ips"])

        let copied = try await r.registry.perform(.appCopyDetails, .select("crash"))
        #expect(r.copied.all.count == 1 && r.copied.all[0].contains("EXC_BREAKPOINT") && copied.message?.contains("1.0 (7)") == true)

        // reabrir depois de uma saída limpa não avisa de novo
        await r.controller.stop()
        let second = try rig()
        defer { second.cleanup() }
        second.controller.start(build: "1.0 (9)", systemHooks: false, installLog: false)
        #expect(second.toasts.items.isEmpty)

        _ = try await r.registry.perform(.diagnosticsDismissCrash, .press)
        #expect(r.controller.lastCrash == nil)
        await #expect(throws: (any Error).self) { _ = try await r.registry.perform(.appCopyDetails, .select("crash")) }
    }

    @Test func runAllChecksReprobesEverythingEvenWithFreshCache() async throws {
        let r = try rig(); defer { r.cleanup() }
        await r.controller.onboarding.runDiagnostics(force: false)
        #expect(r.ghCalls.all.count == 1)
        _ = try await r.registry.perform(.appCheckProblems, .press)
        #expect(r.ghCalls.all.count == 2, "Run All Checks Again ignora o cache")
        #expect(r.controller.isChecking == false)
        #expect(r.controller.onboarding.diagnosticItems.contains { $0.key == .gh })
    }

    @Test func exportShowsTheFileListBeforeSavingAndSavesARedactedZip() async throws {
        let r = try rig(); defer { r.cleanup() }
        let log = DiskLog(.init(directory: r.paths.logsDirectory, process: "app"))
        DiskLog.install(log)
        defer { DiskLog.install(nil) }
        LogFacade(.app, category: "docker").error("docker failed sk-ant-api03-AbCdEfGhIjKlMnOp1234 in /Users/me/p")

        await #expect(throws: (any Error).self) { _ = try await r.registry.perform(.diagnosticsSaveExport, .press) }  // desabilitado sem lista
        let name = try await r.registry.perform(.helpExportDiagnostics, .press).message
        let export = try #require(r.controller.export)
        #expect(export.name == name && export.entries.map(\.path).contains("logs/app.jsonl") && export.entries.map(\.path).contains("versions.json"))
        let staged = r.paths.diagnosticsDirectory.appendingPathComponent(".staging/\(export.name)/logs/app.jsonl")
        let stagedText = try String(contentsOf: staged, encoding: .utf8)
        #expect(stagedText.contains("docker failed") && !stagedText.contains("sk-ant-api03") && !stagedText.contains("/Users/me"))

        let path = try #require(try await r.registry.perform(.diagnosticsSaveExport, .press).message)
        #expect(path.hasSuffix("\(export.name).zip") && FileManager.default.fileExists(atPath: path))
        #expect(r.revealed.all == ["\(export.name).zip"] && r.controller.export == nil)
    }

    @Test func cancelDiscardsTheStagingFolder() async throws {
        let r = try rig(); defer { r.cleanup() }
        _ = try await r.registry.perform(.helpExportDiagnostics, .press)
        let name = try #require(r.controller.export?.name)
        let staging = r.paths.diagnosticsDirectory.appendingPathComponent(".staging/\(name)")
        #expect(FileManager.default.fileExists(atPath: staging.path))
        _ = try await r.registry.perform(.diagnosticsCancelExport, .press)
        #expect(r.controller.export == nil && !FileManager.default.fileExists(atPath: staging.path))
    }

    @Test func revealLogsAndOpenDiagnosticsActions() async throws {
        let r = try rig(); defer { r.cleanup() }
        _ = try await r.registry.perform(.helpRevealLogs, .press)
        #expect(r.revealed.all == ["logs"])
        _ = try await r.registry.perform(.appOpenDiagnostics, .press)
        #expect(r.controller.versionRows.map(\.0) == ["Racky version", "Modes"])
    }

    @Test func diagnosticsIsAVisibleSettingsSection() {
        let model = SettingsModel(flags: SliceFlags(current: .slice4), probe: SettingsModelTests.stub())
        #expect(model.visibleSections.map(\.id).contains("diagnostics"))
    }
}
