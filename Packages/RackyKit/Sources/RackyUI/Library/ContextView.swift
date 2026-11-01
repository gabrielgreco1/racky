import RackyCore
import RackyDesignSystem
import RackyProtocol
import SwiftUI

enum ContextMetrics {
    static let rowHeight: CGFloat = 28
    static let logo: CGFloat = 12
}

/// Corpo da aba Context (03 §10.6): grupos `Agents` e `Skills`, uma linha de 28 por item com a fonte, o switch compacto e, quando a
/// sessão tem agentes vivos, o banner de mudança com `Restart Agents with Resume`. Rodapé: `Open Library`.
struct ContextView: View {
    let controller: ContextController

    private var library: LibraryController { controller.library }

    var body: some View {
        let groups = controller.groups()
        VStack(alignment: .leading, spacing: 0) {
            if library.hasPendingChange { banner }
            if groups.isEmpty {
                Text(verbatim: library.target == nil ? String(localized: "Select a session to see what it loads.", bundle: .module) : String(localized: "Nothing loaded yet.", bundle: .module))
                    .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).padding(DS.Space.s3)
                    .a11y(.rightPanelContextEmpty, kind: "text")
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groups) { group in
                            Text(verbatim: group.title).dsFont(DS.Font.sectionLabel).foregroundStyle(DS.Color.textSecondary)
                                .padding(.horizontal, DS.Space.s3).frame(height: ContextMetrics.rowHeight, alignment: .leading)
                            ForEach(group.rows) { ContextRowView(controller: controller, row: $0) }
                        }
                    }
                    .padding(.bottom, DS.Space.s2)
                }
            }
            HStack {
                DSButton(.pageLibrary, id: .rightPanelContextOpenLibrary, "Open Library", variant: .outline, size: .xs)
                Spacer(minLength: 0)
            }
            .padding(DS.Space.s3)
            .overlay(alignment: .top) { DS.Color.border.frame(height: DSMetrics.hairline) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DS.Color.panel)
        .task(id: library.currentSession()?.id) {
            if !library.loaded { await library.reload() } else { await library.refreshSession() }
        }
    }

    private var banner: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            Text("Changes apply the next time an agent starts in this session.", bundle: .module)
                .dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary).fixedSize(horizontal: false, vertical: true)
            DSButton(.contextRestartWithResume, id: .rightPanelContextRestart, "Restart Agents with Resume", variant: .outline, size: .xs)
        }
        .padding(DS.Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.fg5)
        .a11y(.rightPanelContextBanner, kind: "text")
    }
}

private struct ContextRowView: View {
    let controller: ContextController
    let row: ContextController.Row

    @State private var hovering = false
    private var on: Bool { row.activation != .off }

    var body: some View {
        HStack(spacing: DS.Space.s2) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: row.entry.name).dsFont(DS.Font.small).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                Text(verbatim: row.source).dsFont(DS.Font.micro).foregroundStyle(DS.Color.textTertiary).lineLimit(1)
            }
            Spacer(minLength: DS.Space.s1)
            // `Insert in Prompt` no hover (03 §8): cola `/<skill>` ou a menção do agente no prompt do pane focado.
            ActionButton(.promptInsertItem, id: .rightPanelContextItemInsert(row.entry.kind.rawValue, row.entry.id), argument: .select(row.entry.id), tooltip: String(localized: "Insert in Prompt", bundle: .module)) {
                Image(systemName: "text.insert")
            }
            .buttonStyle(DSIconButtonStyle(.header))
            .opacity(hovering ? 1 : 0)
            toggle
        }
        .onHover { hovering = $0 }
        .padding(.horizontal, DS.Space.s3)
        .frame(minHeight: ContextMetrics.rowHeight)
        .a11y(.rightPanelContextItem(row.entry.kind.rawValue, row.entry.id), kind: "row", label: row.entry.name)
    }

    /// Switch compacto. Global: ligado e desabilitado, com o motivo no tooltip (AC-905).
    @ViewBuilder private var toggle: some View {
        let id = A11yID.rightPanelContextItemToggle(row.entry.kind.rawValue, row.entry.id)
        if row.activation.canToggle {
            ActionButton(.contextToggleItem, id: id, argument: .select(row.entry.id)) { DSSwitchVisual(isOn: on, compact: true) }
                .buttonStyle(.plain)
                .accessibilityValue(Text(verbatim: on ? "on" : "off"))
        } else {
            ActionButton(.contextToggleItem, id: id, argument: .select(row.entry.id)) { DSSwitchVisual(isOn: true, compact: true) }
                .buttonStyle(.plain)
                .disabled(true)
                .opacity(0.5)
                .dsTooltip(String(localized: "Claude Code loads global skills in every session", bundle: .module))
                .accessibilityValue(Text(verbatim: "on"))
        }
    }
}
