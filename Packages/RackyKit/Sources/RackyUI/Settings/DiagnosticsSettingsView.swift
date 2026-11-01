import RackyCore
import RackyDesignSystem
import RackyProtocol
import RackyStore
import SwiftUI

/// Settings › Diagnostics (03 §14.2, T4-04): a checklist do onboarding em modo completo, versões e modos, serviço em segundo plano,
/// desempenho (p50/p95 de 7 dias), erros recentes, crash do encerramento anterior e o pacote exportável.
struct DiagnosticsSettingsView: View {
    let model: SettingsModel

    var body: some View {
        if let controller = model.diagnostics {
            DiagnosticsPage(controller: controller)
        }
    }
}

private struct DiagnosticsPage: View {
    let controller: DiagnosticsController

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionGap) {
            if let crash = controller.lastCrash { crashCard(crash) }
            checks
            SettingsBlock(title: "About") {
                ForEach(Array(controller.versionRows.enumerated()), id: \.offset) { _, row in
                    SettingsRow(title: LocalizedStringKey(row.0), helpText: row.1) { EmptyView() }
                }
                SettingsRow(title: "Background service", helpText: daemonText) { EmptyView() }
                    .a11y(.settings("diagnostics", "service"), kind: "row", label: "Background service", value: daemonText)
                SettingsRow(title: "Database", helpText: controller.database) { EmptyView() }
            }
            performance
            recentErrors
            logs
        }
        .task { await controller.refresh() }
    }

    private var checks: some View {
        SettingsBlock(title: "Checks") {
            VStack(spacing: DS.Space.s1) {
                ForEach(controller.onboarding.items) { OnboardingItemRow(model: controller.onboarding, info: $0) }
                ForEach(controller.onboarding.diagnosticItems) { OnboardingDiagnosticRow(model: controller.onboarding, item: $0) }
            }
            HStack {
                DSButton(.appCheckProblems, id: .settings("diagnostics", "runAll"), "Run All Checks Again", variant: .outline, symbol: "arrow.clockwise")
                if controller.isChecking { DSSpinner(size: SettingsMetrics.rowIcon, delayed: false) }
            }
        }
    }

    private var daemonText: String {
        let d = controller.daemon
        guard d.running else { return String(localized: "Not running", bundle: .module) }
        var parts = [String(localized: "Running", bundle: .module), "protocol v\(ProtocolVersion.current)"]
        if let build = d.build { parts.append("build \(build)") }
        parts.append("\(d.sessions.count) terminals")
        parts.append(d.mode)
        if d.updatePending { parts.append(String(localized: "update pending", bundle: .module)) }
        return parts.joined(separator: " · ")
    }

    private var performance: some View {
        SettingsBlock(title: "Performance (last 7 days)") {
            if controller.summaries.isEmpty {
                Text("No measurements yet.", bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary)
            } else {
                VStack(spacing: DS.Space.s1) {
                    ForEach(controller.summaries, id: \.name) { summary in
                        HStack(spacing: DS.Space.s3) {
                            Text(verbatim: summary.name).dsFont(DS.Font.monoMicro).foregroundStyle(DS.Color.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(verbatim: "n \(summary.count)").dsFont(DS.Font.monoMicro).foregroundStyle(DS.Color.textTertiary)
                            Text(verbatim: "p50 \(Self.format(summary.p50)) \(summary.unit)").dsFont(DS.Font.monoMicro).foregroundStyle(DS.Color.textSecondary)
                            Text(verbatim: "p95 \(Self.format(summary.p95)) \(summary.unit)").dsFont(DS.Font.monoMicro).foregroundStyle(DS.Color.textSecondary)
                        }
                        .padding(.horizontal, DS.Space.s3)
                        .padding(.vertical, DS.Space.s1)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Color.fg5))
                        .a11y(.settings("diagnostics", "metric.\(summary.name)"), kind: "row", label: summary.name,
                              value: "p50 \(Self.format(summary.p50)) p95 \(Self.format(summary.p95))")
                    }
                }
            }
        }
    }

    private static func format(_ value: Double) -> String { value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value) }

    private var recentErrors: some View {
        SettingsBlock(title: "Recent errors") {
            if controller.errors.isEmpty {
                Text("No recent errors.", bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary)
                    .a11y(.settings("diagnostics", "errors"), kind: "container", label: "Recent errors", value: "none")
            } else {
                VStack(alignment: .leading, spacing: DS.Space.s1) {
                    ForEach(controller.errors) { error in
                        Text(verbatim: error.line).dsFont(DS.Font.monoMicro).foregroundStyle(DS.Color.textSecondary)
                            .lineLimit(2).truncationMode(.tail).dsTooltip(error.line)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .a11y(.settings("diagnostics", "errors"), kind: "container", label: "Recent errors", value: "\(controller.errors.count)")
            }
        }
    }

    private var logs: some View {
        SettingsBlock(title: "Logs") {
            SettingsRow(title: "Reveal Logs in Finder", help: "Logs are redacted before they reach the disk.") {
                DSButton(.helpRevealLogs, id: .settings("diagnostics", "revealLogs"), "Reveal Logs in Finder", variant: .outline)
            }
            SettingsRow(title: "Export Diagnostics…", help: "A zip you can share: logs, versions, settings summary. No secrets.") {
                DSButton(.helpExportDiagnostics, id: .settings("diagnostics", "export"), "Export Diagnostics…", variant: .outline)
            }
            if let message = controller.exportError {
                Text(verbatim: message).dsFont(DS.Font.small).foregroundStyle(DS.Color.destructive)
            }
            if let export = controller.export { exportPreview(export) }
        }
    }

    private func exportPreview(_ export: DiagnosticsController.ExportPreview) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            Text("This zip will contain:", bundle: .module).dsFont(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
            VStack(alignment: .leading, spacing: DS.Space.s0_5) {
                ForEach(export.entries) { entry in
                    HStack {
                        Text(verbatim: entry.path).dsFont(DS.Font.monoMicro).foregroundStyle(DS.Color.textSecondary)
                        Spacer(minLength: DS.Space.s2)
                        Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(entry.bytes), countStyle: .file))
                            .dsFont(DS.Font.monoMicro).foregroundStyle(DS.Color.textTertiary)
                    }
                }
            }
            .a11y(.settings("diagnostics", "exportFiles"), kind: "container", label: "Files in the diagnostics zip", value: "\(export.entries.count)")
            HStack(spacing: DS.Space.s2) {
                DSButton(.diagnosticsSaveExport, id: .settings("diagnostics", "saveExport"), "Save Diagnostics", variant: .primary)
                DSButton(.diagnosticsCancelExport, id: .settings("diagnostics", "cancelExport"), "Cancel", variant: .ghost)
            }
        }
        .padding(DS.Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Color.fg5))
    }

    private func crashCard(_ crash: PreviousRunCrash) -> some View {
        HStack(alignment: .center, spacing: DS.Space.s4) {
            VStack(alignment: .leading, spacing: DS.Space.s0_5) {
                Text("Racky quit unexpectedly.", bundle: .module).dsFont(DS.Font.label).fontWeight(.medium).foregroundStyle(DS.Color.textPrimary)
                Text(verbatim: crash.sentinel.startedAt.formatted(date: .abbreviated, time: .shortened) + " · build " + crash.sentinel.build)
                    .dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary)
            }
            Spacer(minLength: DS.Space.s2)
            DSButton(.appCopyDetails, id: .settings("diagnostics", "copyCrash"), "Copy Details", variant: .outline, argument: .select("crash"))
            DSButton(.diagnosticsDismissCrash, id: .settings("diagnostics", "dismissCrash"), "Dismiss", variant: .ghost)
        }
        .padding(DS.Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Color.warningBackground))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Color.warningBorder, lineWidth: DSMetrics.hairline))
        .a11y(.settings("diagnostics", "crash"), kind: "container", label: "Racky quit unexpectedly.")
    }
}
