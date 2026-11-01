import RackyCore
import RackyDesignSystem
import RackyProtocol
import SwiftUI

enum ConversationsMetrics {
    static let rowHeight: CGFloat = 48
    static let logo: CGFloat = 13
}

/// Corpo do módulo Conversations (03 §10.5): busca, escopo, lista de conversas e, aberto, o transcript em leitura.
struct ConversationsView: View {
    let controller: ConversationsController

    var body: some View {
        Group {
            if let open = controller.transcript {
                TranscriptView(open: open)
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(DS.Color.panel)
        .task(id: controller.reloadKey) { await controller.reload() }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                DSTextField(
                    "Search conversations", text: Binding(get: { controller.query }, set: { controller.query = $0 }),
                    id: .rightPanelConversationsSearch, action: .conversationSetQuery, compact: true)
                DSSegmented(
                    [.init("session", "Session"), .init("project", "Project"), .init("all", "All")], selection: controller.scope.rawValue,
                    action: .conversationSetScope, id: .rightPanelConversationsScope, fillWidth: true)
            }
            .padding(.horizontal, DS.Space.s3)
            .padding(.top, DS.Space.s3)
            ForEach(controller.scan.unreadable, id: \.rawValue) { provider in
                Text(verbatim: provider == .codex
                    ? String(localized: "Couldn't read Codex sessions.", bundle: .module)
                    : String(localized: "Couldn't read Claude conversations.", bundle: .module))
                    .dsFont(DS.Font.small)
                    .foregroundStyle(DS.Color.warning)
                    .padding(.horizontal, DS.Space.s3)
                    .a11y(.rightPanelConversationsWarning, kind: "text")
            }
            content
        }
    }

    @ViewBuilder private var content: some View {
        let rows = controller.rows
        if rows.isEmpty {
            Group {
                if controller.isLoading {
                    HStack(spacing: DS.Space.s2) {
                        DSSpinner(size: DS.Space.s4, delayed: true)
                        Text("Loading conversations…", bundle: .module)
                            .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                    }
                } else {
                    Text("No conversations yet.", bundle: .module)
                        .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                        .a11y(.rightPanelConversationsEmpty, kind: "text")
                }
            }
            .padding(.horizontal, DS.Space.s3)
            .padding(.top, DS.Space.s2)
        } else {
            ScrollView {
                LazyVStack(spacing: DS.Space.s0_5) {
                    ForEach(rows) { row($0) }
                }
                .padding(.horizontal, DS.Space.s2)
                .padding(.bottom, DS.Space.s3)
            }
        }
    }

    private func row(_ c: ConversationSummary) -> some View {
        let live = controller.isLive(c)
        return HStack(spacing: DS.Space.s1) {
            DSListRow(.conversationMenu, id: .rightPanelConversationsRow(c.nativeID), argument: .select(c.nativeID)) {
                HStack(spacing: DS.Space.s2) {
                    DSAgentLogo(c.provider, size: ConversationsMetrics.logo)
                    VStack(alignment: .leading, spacing: DS.Space.s0_5) {
                        Text(verbatim: c.title)
                            .dsFont(DS.Font.body).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                        Text(verbatim: Self.detail(c, now: controller.now()))
                            .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).lineLimit(1)
                        if live {
                            Text("Open in another terminal", bundle: .module)
                                .dsFont(DS.Font.small).foregroundStyle(DS.Color.warning).lineLimit(1)
                        }
                    }
                    Spacer(minLength: DS.Space.s1)
                }
                .padding(.horizontal, DS.Space.s2)
                .frame(maxWidth: .infinity, minHeight: ConversationsMetrics.rowHeight, alignment: .leading)
            }
            DSButton(.conversationResume, id: .rightPanelConversationsRowResume(c.nativeID), "Resume", variant: .outline, size: .xs, argument: .select(c.nativeID))
                .disabled(live)
        }
    }

    /// `<branch> · <n> messages · 3h ago`
    static func detail(_ c: ConversationSummary, now: Date) -> String {
        var parts: [String] = []
        if let branch = c.branch { parts.append(branch) }
        if c.messageCount > 0 {
            parts.append(c.messageCount == 1
                ? String(localized: "1 message", bundle: .module) : String(localized: "\(c.messageCount) messages", bundle: .module))
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        parts.append(formatter.localizedString(for: c.updatedAt, relativeTo: now))
        return parts.joined(separator: " · ")
    }
}

/// Transcript em leitura: `← Back` + título; mensagens com o papel em `label` (03 §10.5).
struct TranscriptView: View {
    let open: ConversationsController.OpenTranscript

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.s2) {
                DSButton(.conversationBack, id: .rightPanelConversationsBack, "Back", variant: .ghost, size: .xs, symbol: "chevron.left")
                Text(verbatim: open.summary.title)
                    .dsFont(DS.Font.bodyStrong).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                Spacer(minLength: DS.Space.s1)
            }
            .padding(.horizontal, DS.Space.s3)
            .frame(height: DS.Space.s8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Space.s3) {
                    ForEach(open.blocks) { block in
                        VStack(alignment: .leading, spacing: DS.Space.s0_5) {
                            Text(verbatim: block.role).dsFont(DS.Font.label).foregroundStyle(DS.Color.textSecondary)
                            Text(verbatim: block.text).dsFont(DS.Font.body).foregroundStyle(DS.Color.textPrimary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(DS.Space.s3)
            }
            .a11y(.rightPanelConversationsTranscript, kind: "list")
        }
    }
}
