import RackyCore
import RackyDesignSystem
import RackyProtocol
import SwiftUI

/// Inbox (03 §9.1): feed que substitui o corpo da sidebar abaixo dos itens de nav (⇧⌘I).
/// Grupos `Needs You · Working · Done · Earlier`; clique leva ao pane com rim flash e marca como lido.
struct InboxView: View {
    let model: SidebarModel
    @Environment(\.actionRegistry) private var registry

    var body: some View {
        let feed = model.inboxFeed
        Section {
            let help = model.helpItems
            let approvals = model.approvalItems
            let batches = model.inboxFilter == .needsYou ? [] : model.batchItems
            if feed.isEmpty, help.isEmpty, approvals.isEmpty, batches.isEmpty {
                DSEmptyState(String(localized: "Nothing needs you.", bundle: .module)) { EmptyView() }
                    .padding(.top, DS.Space.s6)
                    .a11y(.inboxEmpty, kind: "container", label: String(localized: "Nothing needs you.", bundle: .module))
            }
            if !help.isEmpty || !approvals.isEmpty, !feed.groups.contains(where: { $0.group == .needsYou }) {
                groupHeader(.needsYou)
                approvalRows(approvals)
                helpRows(help)
            }
            if !batches.isEmpty, !feed.groups.contains(where: { $0.group == .done }) {
                groupHeader(.done)
                batchRows(batches)
            }
            ForEach(feed.groups, id: \.group) { entry in
                groupHeader(entry.group)
                if entry.group == .done { batchRows(batches) }
                if entry.group == .needsYou {
                    approvalRows(approvals)
                    helpRows(help)
                }
                ForEach(entry.rows) { row in
                    InboxRowView(row: row, now: model.clock())
                        .transition(.opacity.combined(with: .offset(y: -DS.Space.s2)))
                }
            }
        } header: {
            header(unread: feed.unreadCount)
        }
        .animation(MotionPolicy.shared.animation(MotionTokens.Easing.standard, MotionTokens.Duration.base), value: feed.rows.map(\.id))
        .a11y(.inbox, kind: "container", label: String(localized: "Inbox", bundle: .module))
    }

    private func approvalRows(_ items: [ComputerApprovalRequest]) -> some View {
        ForEach(items) { request in
            ComputerApprovalRowView(request: request).transition(.opacity.combined(with: .offset(y: -DS.Space.s2)))
        }
    }

    private func batchRows(_ items: [AttentionItem]) -> some View {
        ForEach(items) { item in
            BatchDoneRowView(item: item).transition(.opacity.combined(with: .offset(y: -DS.Space.s2)))
        }
    }

    private func helpRows(_ items: [InboxItem]) -> some View {
        ForEach(items) { item in
            HelpRequestRowView(item: item).transition(.opacity.combined(with: .offset(y: -DS.Space.s2)))
        }
    }

    private func header(unread: Int) -> some View {
        SectionHeader(title: String(localized: "Inbox", bundle: .module), tooltip: nil) {
            if let registry, registry.isOffered(.inboxFilter) {
                DSIconButton(
                    .inboxFilter, id: .inboxFilter, symbol: "slider.horizontal.3", name: String(localized: "Filter", bundle: .module),
                    variant: .header, active: model.inboxFilter != .all
                )
                .popover(isPresented: Bindable(model).inboxFilterMenuOpen, arrowEdge: .bottom) { InboxFilterPanel(model: model) }
            }
            if let registry, registry.isOffered(.inboxMarkAllRead) {
                DSIconButton(
                    .inboxMarkAllRead, id: .inboxMarkAllRead, symbol: "checkmark", name: String(localized: "Mark All as Read", bundle: .module),
                    variant: .header)
            }
        }
    }

    private func groupHeader(_ group: InboxGroup) -> some View {
        Text(verbatim: group.title)
            .dsFont(DS.Font.sectionLabel)
            .foregroundStyle(DS.ColorSpec.textSecondary.scaled(0.8).color)
            .padding(.horizontal, SidebarMetrics.sectionPaddingH)
            .frame(maxWidth: .infinity, minHeight: SidebarMetrics.sectionHeaderHeight - DS.Space.s2, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Pedido de ajuda de um computador (CAPTCHA, login): `<computer> needs you · <headline>` com `Take Over` (03 §9.1).
struct HelpRequestRowView: View {
    let item: InboxItem
    @State private var hovering = false

    var body: some View {
        // A linha inteira abre o computador (o Take Over continua no botão).
        ActionButton(.computerOpenViewer, argument: .select(item.computer), tooltip: item.message) { content }
            .buttonStyle(.plain)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: DS.Space.s0_5) {
            HStack(spacing: DS.Space.s1_5) {
                DSAgentIndicator(.needsInput, size: .sm)
                Text(verbatim: item.computer)
                    .dsFont(DS.Font.body)
                    .fontWeight(item.read ? .regular : .semibold)
                    .foregroundStyle(DS.Color.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: DS.Space.s1)
                if hovering, !item.read {
                    ActionButton(.inboxMarkRead, id: .inboxItemMarkRead(item.id), argument: .select(item.id), tooltip: String(localized: "Mark as Read", bundle: .module)) {
                        Image(systemName: "checkmark")
                    }
                    .buttonStyle(DSIconButtonStyle(.row))
                }
                DSButton(.computerTakeOver, id: .inboxItemTakeOver(item.id), "Take Over", variant: .outline, size: .xs, argument: .select(item.computer))
            }
            Text(verbatim: item.message)
                .dsFont(DS.Font.small)
                .foregroundStyle(DS.Color.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, DSIndicatorSize.sm.box + DS.Space.s1_5)
        }
        .padding(.horizontal, DS.Space.s2_5)
        .padding(.vertical, DS.Space.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: InboxMetrics.rowHeight)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(hovering ? DS.Color.fg8 : Color.clear))
        .onHover { hovering = $0 }
        .a11y(.inboxItem(item.id), kind: "row", label: item.message, value: "needs_you")
    }
}

struct InboxRowView: View {
    let row: InboxRow
    let now: Date
    @Environment(\.actionRegistry) private var registry
    @State private var hovering = false

    private var glyph: DSIndicatorGlyph {
        switch row.activity {
        case .needsInput: .needsInput
        case .working: .working
        case .waitingOnSubagents: .waiting
        case .starting: .spinner
        case .done: .done
        case .failed, .blocked: .dot(DS.ColorSpec.agentFailed)
        case .interrupted: .dot(DS.ColorSpec.agentInterrupted)
        case .idle: .dot(DS.ColorSpec.agentIdle)
        case .unknown: .unknown
        }
    }

    var body: some View {
        let id = row.id.uuidString
        let content = VStack(alignment: .leading, spacing: DS.Space.s0_5) {
            HStack(spacing: DS.Space.s1_5) {
                DSAgentIndicator(glyph, size: .sm)
                DSAgentLogo(row.provider, size: SidebarMetrics.agentLogo)
                Text(verbatim: row.title)
                    .dsFont(DS.Font.body)
                    .fontWeight(row.unread ? .semibold : .regular)
                    .foregroundStyle(DS.Color.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: DS.Space.s1)
                Text(verbatim: SidebarProjector.relativeTime(since: row.at, now: now))
                    .dsFont(DS.Font.microNumeric)
                    .foregroundStyle(DS.Color.textTertiary)
                    .fixedSize()
                    .opacity(hovering && row.unread ? 0 : 1)
            }
            Text(verbatim: row.message)
                .dsFont(DS.Font.small)
                .foregroundStyle(DS.Color.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, InboxMetrics.messageIndent)
        }
        .padding(.horizontal, DS.Space.s2_5)
        .padding(.vertical, DS.Space.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: InboxMetrics.rowHeight)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(hovering ? DS.Color.fg8 : Color.clear))
        .contentShape(Rectangle())
        .animation(MotionPolicy.shared.animation(MotionTokens.Easing.ease, MotionTokens.Duration.hover), value: hovering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "\(row.title), \(row.message)"))
        ZStack(alignment: .topTrailing) {
            ActionButton(.notificationOpen, id: .inboxItem(id), argument: .select(id), tooltip: row.message) { content }
                .buttonStyle(.plain)
            // Hover: `Mark as Read` no lugar do tempo (03 §9.1). Irmão da linha, não filho: botão dentro de botão não clica.
            if hovering, row.unread {
                ActionButton(.inboxMarkRead, id: .inboxItemMarkRead(id), argument: .select(id), tooltip: String(localized: "Mark as Read", bundle: .module)) {
                    Image(systemName: "checkmark")
                }
                .buttonStyle(DSIconButtonStyle(.row))
                .padding(.top, DS.Space.s2)
                .padding(.trailing, DS.Space.s2)
            }
        }
        .onHover { hovering = $0 }
    }
}

enum InboxMetrics {
    /// Item de 48, duas linhas, raio 10 (03 §9.1).
    static let rowHeight: CGFloat = 48
    /// A segunda linha alinha com o título: depois do indicador, do logo e dos dois espaços.
    static let messageIndent: CGFloat = DSIndicatorSize.sm.box + DS.Space.s1_5 * 2 + SidebarMetrics.agentLogo
}

struct InboxFilterPanel: View {
    let model: SidebarModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s0_5) {
            ForEach(InboxFilter.allCases, id: \.self) { filter in
                InboxFilterRow(filter: filter, on: model.inboxFilter == filter)
            }
        }
        .padding(DS.Space.s1)
        .frame(width: SidebarMetrics.filterMenuWidth)
        .background(DS.Color.menuSolid)
        .a11y(.menuPanel("inbox.filter"), kind: "menu")
    }
}

struct InboxFilterRow: View {
    let filter: InboxFilter
    let on: Bool
    @State private var hovering = false

    var body: some View {
        ActionButton(.inboxFilter, id: .menuPanel("inbox.filter.\(filter.rawValue)"), argument: .select(filter.rawValue)) {
            HStack(spacing: DS.Space.s2) {
                Image(systemName: "checkmark")
                    .font(.system(size: SidebarMetrics.line2Icon + DS.Space.s0_5, weight: .semibold))
                    .opacity(on ? 1 : 0)
                    .frame(width: SidebarMetrics.chevron)
                Text(verbatim: filter.title).dsFont(DS.Font.menuItem)
                Spacer(minLength: .zero)
            }
            .foregroundStyle(DS.Color.textPrimary)
            .padding(.horizontal, DS.Space.s2)
            .frame(height: SidebarMetrics.agentRowHeight)
            .background(RoundedRectangle(cornerRadius: DS.Radius.md).fill(hovering ? DS.ColorSpec.borderStrong.color : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
