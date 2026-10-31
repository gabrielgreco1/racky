import RackyCore
import RackyPlatform
import RackyProtocol
import RackyStore
import AppKit
import Foundation
import Observation

/// Settings › Diagnostics (03 §14.2, 08 AR-603/604/605): versões e modos, p50/p95 dos pontos quentes, erros recentes, crash do
/// encerramento anterior (aviso uma vez, "Copy Details"), "Run All Checks Again" e "Export Diagnostics…" (lista de arquivos antes de salvar).
@MainActor @Observable
public final class DiagnosticsController {
    public struct DaemonStatus: Equatable, Sendable {
        public var running = false
        public var build: String?
        public var mode = ""
        public var updatePending = false
        public var sessions: [DiagnosticsBundleInput.DaemonSession] = []
        public init() {}
    }

    public struct ExportPreview: Equatable {
        public var name: String
        public var entries: [DiagnosticsBundle.Entry]
        public var totalBytes: Int
    }

    public private(set) var daemon = DaemonStatus()
    public private(set) var summaries: [MetricSummary] = []
    public private(set) var errors: [LoggedError] = []
    public private(set) var lastCrash: PreviousRunCrash?
    public private(set) var export: ExportPreview?
    public private(set) var exportError: String?
    public private(set) var isChecking = false
    public private(set) var database = ""

    public let paths: StorePaths
    @ObservationIgnored let crash: CrashMonitor
    @ObservationIgnored private let settings: SettingsModel
    @ObservationIgnored let onboarding: OnboardingModel
    @ObservationIgnored private let toasts: ToastCenter
    @ObservationIgnored private var store: RackyStore?
    @ObservationIgnored private var pendingBundle: DiagnosticsBundle?
    @ObservationIgnored private var metricWriter: MetricWriter?
    @ObservationIgnored private var metricKit: MetricKitCollector?
    @ObservationIgnored private let log = LogFacade(.app, category: "lifecycle")

    /// Estado do daemon (conexão, build, sessões) vindo do `TerminalRuntime`.
    @ObservationIgnored var daemonProbe: @MainActor () async -> DaemonStatus = { DaemonStatus() }
    /// Versão e modos do app (rótulo, valor), na ordem de exibição.
    @ObservationIgnored var appInfo: @MainActor () -> [(String, String)] = { [] }
    @ObservationIgnored var reveal: @MainActor (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    @ObservationIgnored var copy: @MainActor (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    @ObservationIgnored var reportsDirectory: URL

    public init(paths: StorePaths, settings: SettingsModel, onboarding: OnboardingModel, toasts: ToastCenter, crash: CrashMonitor? = nil) {
        self.paths = paths
        self.settings = settings
        self.onboarding = onboarding
        self.toasts = toasts
        let monitor = crash ?? CrashMonitor(runDirectory: paths.runDirectory)
        self.crash = monitor
        self.reportsDirectory = monitor.reportsDirectory
        lastCrash = monitor.lastCrash()
    }

    // MARK: Ciclo de vida

    /// No boot, depois do lock da instância: log em disco do app, sentinela de crash e, no produto, o MetricKit.
    public func start(build: String, systemHooks: Bool, installLog: Bool = true) {
        DiagnosticsExporter.clearStaging(paths: paths)
        if installLog { DiskLog.install(DiskLog(.init(directory: paths.logsDirectory, process: "app"))) }
        if let found = crash.begin(build: build) {
            lastCrash = found
            surfaceCrash(found)
        }
        if systemHooks {
            let collector = MetricKitCollector(logsDirectory: paths.logsDirectory)
            collector.start()
            metricKit = collector
        }
    }

    /// Store aberto: liga a tabela `metric` ao recorder compartilhado.
    public func attach(store: RackyStore) async {
        self.store = store
        let writer = MetricWriter(store: store)
        metricWriter = writer
        await writer.start()
    }

    /// Saída limpa: apaga a sentinela e descarrega métricas e log.
    public func stop() async {
        crash.endCleanly()
        await metricWriter?.stop()
        DiskLog.current?.flush()
        metricKit?.stop()
    }

    /// Aviso único do encerramento inesperado (08 AR-604): toast com "Copy Details"; depois disso só a linha do Diagnostics fica.
    private func surfaceCrash(_ found: PreviousRunCrash) {
        guard !found.surfaced else { return }
        toasts.show(
            kind: .warning, title: String(localized: "Racky quit unexpectedly.", bundle: .module),
            detail: String(localized: "A report is in Settings › Diagnostics.", bundle: .module),
            action: ToastAction(.appCopyDetails, title: String(localized: "Copy Details", bundle: .module), argument: .select("crash")),
            duration: 30)
        crash.markSurfaced()
        log.publicError("previous run ended unexpectedly")
    }

    // MARK: Atualização da página

    /// Recarrega o que a página mostra (daemon, métricas, erros, banco).
    public func refresh() async {
        daemon = await daemonProbe()
        DiskLog.current?.flush()
        errors = RecentErrors.read(logFiles: RecentErrors.logFiles(in: paths.logsDirectory), limit: 10)
        lastCrash = crash.lastCrash()
        if let store {
            summaries = (try? await store.metricSummaries(since: Date().addingTimeInterval(-MetricWriter.retention))) ?? []
            let counts = (try? await store.tableCounts()) ?? [:]
            let schema = (try? await store.appliedMigrations())?.last ?? "unknown"
            database = "\(counts.values.reduce(0, +)) rows · \(schema)"
        }
    }

    var versionRows: [(String, String)] { appInfo() }

    /// `app.checkProblems` e o botão "Run All Checks Again": refaz a checklist inteira e a página.
    func runAllChecks() async {
        isChecking = true
        defer { isChecking = false }
        await settings.refreshAgents(force: true)
        await onboarding.runDiagnostics(force: true)
        await refresh()
    }

    // MARK: Exportação

    func prepareExport() async {
        exportError = nil
        discardPending()
        await refresh()
        var versions = Dictionary(uniqueKeysWithValues: versionRows.map { ($0.0, $0.1) })
        for info in settings.agents { versions[info.provider.rawValue] = info.version ?? "not installed" }
        let native = settings.usesNativeRuntime
        let dockerSummary: @Sendable () async -> [String: String] = native
            ? { @Sendable in [:] } : { @Sendable in await DiagnosticsExporter.liveDockerSummary() }
        for (name, value) in await DiagnosticsExporter.cliVersions(names: native ? ["git", "gh"] : ["git", "gh", "docker"]) { versions[name] = value }
        var checks: [String: String] = [:]
        for item in onboarding.diagnosticItems { checks[item.key.rawValue] = "\(item.state): \(item.detail)" }
        let context = DiagnosticsExportContext(
            paths: paths, store: store, versions: versions, settingsJSON: settingsJSON(), daemonSessions: daemon.sessions, checks: checks,
            crashReports: lastCrash?.reports.map(\.fileName) ?? [], reportsDirectory: reportsDirectory,
            dockerSummary: dockerSummary)
        do {
            let bundle = try await DiagnosticsExporter.prepare(context)
            pendingBundle = bundle
            export = ExportPreview(name: bundle.name, entries: bundle.entries, totalBytes: bundle.totalBytes)
        } catch {
            exportError = String(localized: "Couldn't prepare the diagnostics.", bundle: .module)
            log.error("diagnostics export failed: \(error)")
        }
    }

    func saveExport() async throws -> URL {
        guard let bundle = pendingBundle else { throw ActionError.failed(.diagnosticsSaveExport, message: "Export Diagnostics first.") }
        pendingBundle = nil
        export = nil
        let url = try await DiagnosticsExporter.save(bundle, paths: paths)
        reveal(url)
        toasts.show(kind: .success, title: String(localized: "Diagnostics saved.", bundle: .module))
        return url
    }

    func cancelExport() {
        discardPending()
        export = nil
    }

    private func discardPending() {
        pendingBundle?.discard()
        pendingBundle = nil
    }

    /// Configurações sem segredos: `AppSettings` e os proxies sem usuário, chave nem CA (só se há credencial guardada).
    func settingsJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let general = (try? encoder.encode(settings.settings)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let proxies = settings.proxies.map { p in
            ["name": p.name, "scheme": "\(p.scheme)", "host": p.host, "port": "\(p.port)", "hasCredential": "\(p.secretID != nil)", "default": "\(p.isDefault)"]
        }
        let extra = (try? JSONSerialization.data(withJSONObject: ["proxies": proxies], options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "{\"app\": \(general), \"computers\": \(extra)}"
    }

    // MARK: Ações

    func registerActions(in registry: ActionRegistry) throws {
        try registry.register(.appCheckProblems) { [unowned self] _ in
            settings.open(section: "diagnostics")
            await runAllChecks()
            return "checked"
        }
        try registry.register(.appOpenDiagnostics) { [unowned self] _ in
            settings.open(section: "diagnostics")
            await refresh()
            return "opened"
        }
        try registry.register(.helpRevealLogs) { [unowned self] _ in
            DiskLog.current?.flush()
            reveal(paths.logsDirectory)
            return paths.logsDirectory.path
        }
        try registry.register(.helpExportDiagnostics) { [unowned self] _ in
            settings.open(section: "diagnostics")
            await prepareExport()
            if let exportError { throw ActionError.failed(.helpExportDiagnostics, message: exportError) }
            return export?.name
        }
        try registry.register(.diagnosticsSaveExport, enablement: { [unowned self] in export == nil ? .disabled(reason: "Export Diagnostics first.") : .enabled }) {
            [unowned self] _ in try await saveExport().path
        }
        try registry.register(.diagnosticsCancelExport) { [unowned self] _ in
            cancelExport()
            return "cancelled"
        }
        try registry.register(.appCopyDetails) { [unowned self] arg in
            guard arg.value == "crash", let found = lastCrash ?? crash.lastCrash() else { throw ActionError.failed(.appCopyDetails, message: "There are no details to copy.") }
            copy(found.details)
            toasts.show(kind: .success, title: String(localized: "Details copied.", bundle: .module))
            return found.details
        }
        try registry.register(.diagnosticsDismissCrash) { [unowned self] _ in
            crash.dismiss()
            lastCrash = nil
            return "dismissed"
        }
    }
}
