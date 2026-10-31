import RackyCore
import RackyDesignSystem
import RackyProtocol
import SwiftUI

enum LibraryMetrics {
    static let listWidth: CGFloat = 320
    static let rowHeight: CGFloat = 48
    static let logo: CGFloat = 16
    static let chipLogo: CGFloat = 10
    static let metaLabel: CGFloat = 96
    static let separator: CGFloat = 1
    static let detailMaxWidth: CGFloat = 720
    static let codeMinHeight: CGFloat = 160
}

extension LibraryClient {
    var agentKind: DSAgentKind {
        switch self {
        case .claude: .claude
        case .codex: .codex
        case .opencode: .opencode
        }
    }
}

/// Página Library (03 §13): cabeçalho com `Agents · Skills · Profiles`, lista de 320 e detalhe ao lado (M-112).
struct LibraryPageView: View {
    let controller: LibraryController

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Library") {
                DSSegmented(
                    [.init("agents", "Agents"), .init("skills", "Skills"), .init("profiles", "Profiles")], selection: controller.section.rawValue,
                    action: .librarySetSection, id: .librarySection)
            }
            HStack(spacing: 0) {
                LibraryListView(controller: controller).frame(width: LibraryMetrics.listWidth)
                DS.Color.border.frame(width: LibraryMetrics.separator)
                LibraryDetailView(controller: controller).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(DS.Color.canvas)
        .a11y(.libraryPage, kind: "page")
        .task { await controller.reload() }
    }
}

// MARK: Lista

struct LibraryListView: View {
    let controller: LibraryController

    private var placeholder: LocalizedStringKey {
        switch controller.section {
        case .agents: "Search agents…"
        case .skills: "Search skills…"
        case .profiles: "Search profiles…"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                DSTextField(placeholder, text: Binding(get: { controller.query }, set: { controller.setQuery($0) }), id: .librarySearch, action: .librarySetSearch, compact: true)
                if controller.section != .profiles { DSCombobox(id: .librarySource, selection: controller.category?.rawValue ?? "all", entries: sourceEntries, action: .librarySetSource) }
            }
            .padding(DS.Space.s3)
            DS.Color.border.frame(height: LibraryMetrics.separator)
            content
        }
        .background(DS.Color.panel)
    }

    /// `All Sources` e uma entrada por fonte presente, com a contagem do que existe no disco.
    private var sourceEntries: [DSMenuEntry] {
        let counts = controller.counts
        let total = counts.values.reduce(0, +)
        var entries: [DSMenuEntry] = [.item(DSMenuItem("all", String(localized: "All Sources", bundle: .module), detail: "\(total)"))]
        for category in controller.presentCategories {
            entries.append(.item(DSMenuItem(category.rawValue, category.label, detail: "\(counts[category] ?? 0)")))
        }
        return entries
    }

    @ViewBuilder private var content: some View {
        if controller.section == .profiles {
            profiles
        } else if controller.visibleItems.isEmpty {
            Text(verbatim: emptyText).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).padding(DS.Space.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .a11y(.libraryEmpty, kind: "text")
            Spacer(minLength: 0)
        } else {
            ScrollView {
                LazyVStack(spacing: DS.Space.s0_5) {
                    ForEach(controller.visibleItems) { row($0) }
                }
                .padding(DS.Space.s2)
            }
        }
    }

    private var emptyText: String {
        if controller.isLoading, !controller.loaded { return String(localized: "Loading…", bundle: .module) }
        if !controller.query.isEmpty || controller.category != nil { return String(localized: "No results", bundle: .module) }
        return controller.section == .agents
            ? String(localized: "No agents found in ~/.claude/agents or ~/.codex/agents.", bundle: .module)
            : String(localized: "No skills found in ~/.claude/skills or ~/.agents/skills.", bundle: .module)
    }

    /// A pasta de topo (`~/.codex`) quando outro item da lista tem o mesmo nome; senão nada.
    private func duplicateFolder(_ item: LibraryEntry) -> String? {
        guard controller.visibleItems.contains(where: { $0.name == item.name && $0.id != item.id }) else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = item.path.hasPrefix(home) ? "~" + item.path.dropFirst(home.count) : item.path
        return path.split(separator: "/").prefix(2).joined(separator: "/")
    }

    private func row(_ item: LibraryEntry) -> some View {
        DSListRow(.librarySelectItem, id: .libraryRow(item.kind.rawValue, item.id), selected: item.id == controller.selectedID, argument: .select(item.id)) {
            HStack(spacing: DS.Space.s2) {
                if let first = item.clients.first { DSAgentLogo(first.agentKind, size: LibraryMetrics.logo) }
                VStack(alignment: .leading, spacing: DS.Space.s0_5) {
                    HStack(spacing: DS.Space.s1) {
                        Text(verbatim: item.name).dsFont(DS.Font.label).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                        // Mesmo nome em duas pastas (~/.claude e ~/.codex, ~/.agents): a lista mostrava duas linhas iguais.
                        if let folder = duplicateFolder(item) {
                            Text(verbatim: folder).dsFont(DS.Font.monoMicro).foregroundStyle(DS.Color.textTertiary).lineLimit(1).fixedSize()
                        }
                    }
                    Text(verbatim: item.summary ?? item.category.label).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).lineLimit(1)
                }
                Spacer(minLength: DS.Space.s1)
                HStack(spacing: DS.Space.s1) {
                    ForEach(item.clients, id: \.rawValue) { DSAgentLogo($0.agentKind, size: LibraryMetrics.chipLogo, dimmed: true) }
                }
            }
            .padding(.horizontal, DS.Space.s2)
            .frame(maxWidth: .infinity, minHeight: LibraryMetrics.rowHeight, alignment: .leading)
        }
    }

    @ViewBuilder private var profiles: some View {
        let all = controller.profileList.filter { query.isEmpty || $0.name.lowercased().contains(query) }
        if all.isEmpty {
            Text("No results", bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).padding(DS.Space.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        } else {
            ScrollView {
                LazyVStack(spacing: DS.Space.s0_5) {
                    ForEach(all) { profile in
                        DSListRow(.librarySelectItem, id: .libraryProfileRow(profile.id.uuidString), selected: profile.id.uuidString == controller.selectedID, argument: .select(profile.id.uuidString)) {
                            HStack(spacing: DS.Space.s2) {
                                DSAgentLogo(profile.provider.dsKind, size: LibraryMetrics.logo)
                                VStack(alignment: .leading, spacing: DS.Space.s0_5) {
                                    Text(verbatim: profile.name).dsFont(DS.Font.label).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                                    Text(verbatim: LibraryProfileFormat.summary(profile)).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).lineLimit(1)
                                }
                                Spacer(minLength: DS.Space.s1)
                                if LibraryProfileFormat.isBuiltin(profile) { Text("Built-in", bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary) }
                            }
                            .padding(.horizontal, DS.Space.s2)
                            .frame(maxWidth: .infinity, minHeight: LibraryMetrics.rowHeight, alignment: .leading)
                        }
                    }
                }
                .padding(DS.Space.s2)
            }
        }
    }

    private var query: String { controller.query.trimmingCharacters(in: .whitespaces).lowercased() }
}

extension TerminalProvider {
    var dsKind: DSAgentKind {
        switch self {
        case .claude: .claude
        case .codex: .codex
        case .opencode: .opencode
        case .shell, .custom: .shell
        }
    }
}

enum LibraryProfileFormat {
    static func isBuiltin(_ profile: LaunchProfile) -> Bool { BuiltinProfiles.all.contains { $0.id == profile.id } }

    static func summary(_ profile: LaunchProfile) -> String {
        var parts = [AgentInfo.displayName(profile.provider)]
        parts.append(profile.model ?? "Default model")
        switch profile.permissionMode {
        case "bypassPermissions", "bypass": parts.append("Skip permissions")
        case "acceptEdits": parts.append("Accept edits")
        default: break
        }
        return parts.joined(separator: " · ")
    }

    static func permissions(_ profile: LaunchProfile) -> String {
        switch profile.permissionMode {
        case "bypassPermissions", "bypass": "Skip Permissions"
        case "acceptEdits": "Accept Edits"
        case nil, "", "default": "Ask"
        case let other?: other
        }
    }
}

// MARK: Detalhe

struct LibraryDetailView: View {
    let controller: LibraryController

    var body: some View {
        Group {
            if controller.section == .profiles {
                if let profile = controller.selectedProfile { LibraryProfileDetail(controller: controller, profile: profile) } else { placeholder }
            } else if let item = controller.selectedItem {
                LibraryItemDetail(controller: controller, item: item, preview: controller.preview)
            } else {
                placeholder
            }
        }
        .animation(MotionPolicy.shared.animation(MotionTokens.Easing.standard, MotionTokens.Duration.base), value: controller.selectedID)
    }

    private var placeholder: some View {
        Text("Select an item to see its details.", bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Quebra de linha para chips (skills, servidores MCP).
struct ChipFlow: Layout {
    var spacing: CGFloat = DS.Space.s1

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(bounds.width, subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    /// Itens de alturas diferentes (seta e chip) ficam centrados na linha.
    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var rows: [(start: Int, height: CGFloat)] = []
        var sizes: [CGSize] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0, rowStart = 0
        for (index, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                rows.append((rowStart, rowHeight)); rowStart = index
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            sizes.append(size)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        rows.append((rowStart, rowHeight))
        for (r, row) in rows.enumerated() {
            let end = r + 1 < rows.count ? rows[r + 1].start : origins.count
            for i in row.start ..< end { origins[i].y += (row.height - sizes[i].height) / 2 }
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}

private struct MetaRow<Content: View>: View {
    let label: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
            Text(label, bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary)
                .frame(width: LibraryMetrics.metaLabel, alignment: .leading)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct LibraryItemDetail: View {
    let controller: LibraryController
    let item: LibraryEntry
    let preview: LibraryPreview?

    private var activation: LibraryActivation { controller.activation(of: item) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.s4) {
                header
                if controller.hasPendingChange, activation == .thisSession || controller.added.isEmpty == false { pendingBanner }
                meta
                actions
                if item.kind == .skill, let preview, !preview.files.isEmpty { files(preview) }
                content
            }
            .padding(DS.Space.s4)
            .frame(maxWidth: LibraryMetrics.detailMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.s1_5) {
            HStack(spacing: DS.Space.s2) {
                Text(verbatim: item.name).dsFont(DS.Font.pageTitle).foregroundStyle(DS.Color.textPrimary).lineLimit(2)
                if let shadow = item.shadowedBy.flatMap({ id in controller.items.first { $0.id == id } }) {
                    DSBadge(String(localized: "Shadowed by \(shadow.category.label)", bundle: .module), variant: .neutral)
                }
            }
            if let summary = item.summary {
                Text(verbatim: summary).dsFont(DS.Font.body).foregroundStyle(DS.Color.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error = item.parseError ?? preview?.error {
                DSBadge(error, variant: .warning)
            }
        }
    }

    private var pendingBanner: some View {
        HStack(spacing: DS.Space.s2) {
            Text("Applies on next launch", bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary)
            Spacer(minLength: DS.Space.s2)
            DSButton(.contextRestartWithResume, id: .libraryDetailRestart, "Restart Agents with Resume", variant: .outline, size: .xs)
        }
        .padding(DS.Space.s2)
        .background(RoundedRectangle(cornerRadius: DS.Radius.md).fill(DS.Color.fg5))
    }

    private var meta: some View {
        VStack(alignment: .leading, spacing: DS.Space.s1_5) {
            MetaRow(label: "Source") {
                VStack(alignment: .leading, spacing: DS.Space.s0_5) {
                    Text(verbatim: item.category.label).dsFont(DS.Font.small).foregroundStyle(DS.Color.textPrimary)
                    Text(verbatim: item.path).dsFont(DS.Font.monoMicro).foregroundStyle(DS.Color.textTertiary).lineLimit(2).truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            MetaRow(label: "Works with") {
                HStack(spacing: DS.Space.s2) {
                    ForEach(item.clients, id: \.rawValue) { client in
                        HStack(spacing: DS.Space.s1) {
                            DSAgentLogo(client.agentKind, size: LibraryMetrics.chipLogo)
                            Text(verbatim: client.displayName).dsFont(DS.Font.small).foregroundStyle(DS.Color.textPrimary)
                        }
                    }
                }
            }
            if item.kind == .skill {
                MetaRow(label: "Activation") { Text(verbatim: activationText).dsFont(DS.Font.small).foregroundStyle(DS.Color.textPrimary) }
            }
            if item.kind == .agent {
                if let model = item.model { MetaRow(label: "Model") { Text(verbatim: model).dsFont(DS.Font.small).foregroundStyle(DS.Color.textPrimary) } }
                if !item.tools.isEmpty { MetaRow(label: "Tools") { chips(item.tools) } }
                if !item.skills.isEmpty { MetaRow(label: "Skills") { chips(item.skills) } }
                if !item.mcpServers.isEmpty { MetaRow(label: "MCP Servers") { chips(item.mcpServers, highlight: "racky") } }
                MetaRow(label: "Activation") { Text(verbatim: activationText).dsFont(DS.Font.small).foregroundStyle(DS.Color.textPrimary) }
            }
        }
    }

    private var activationText: String {
        switch activation {
        case .alwaysOn: String(localized: "Always on (global)", bundle: .module)
        case .thisSession: String(localized: "On in this session", bundle: .module)
        case .off: String(localized: "Off", bundle: .module)
        case .unavailable(let reason): reason
        }
    }

    private func chips(_ values: [String], highlight: String? = nil) -> some View {
        ChipFlow {
            ForEach(values, id: \.self) { value in
                DSBadge(value, variant: value == highlight ? .pill : .mono)
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            HStack(spacing: DS.Space.s2) {
                if activation.canToggle {
                    DSButton(
                        .libraryToggleInSession, id: .libraryDetailEnable, activation == .thisSession ? "Disable in This Session" : "Enable in This Session",
                        variant: .outline, size: .sm, argument: .select(item.id))
                }
                DSButton(.promptInsertItem, id: .libraryDetailInsert, "Insert in Prompt", variant: .ghost, size: .sm, argument: .select(item.id))
                DSButton(.libraryOpenInEditor, id: .libraryDetailOpenInEditor, "Open in Editor", variant: .ghost, size: .sm, argument: .select(item.id))
                DSButton(.libraryReveal, id: .libraryDetailReveal, "Reveal in Finder", variant: .ghost, size: .sm, argument: .select(item.id))
            }
            if case .alwaysOn = activation {
                Text(verbatim: item.kind == .skill
                    ? String(localized: "Global skills load in every Claude Code session.", bundle: .module)
                    : String(localized: "Global agents load in every Claude Code session.", bundle: .module))
                    .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
            }
            if case .unavailable(let reason) = activation {
                Text(verbatim: reason).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
            }
        }
    }

    private func files(_ preview: LibraryPreview) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            Text("Files", bundle: .module).dsFont(DS.Font.sectionLabel).foregroundStyle(DS.Color.textSecondary)
            ForEach(preview.files) { file in
                HStack(spacing: DS.Space.s1_5) {
                    if file.isScript {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: DS.Space.s3)).foregroundStyle(DS.Color.warning)
                            .dsTooltip(String(localized: "Contains executable scripts", bundle: .module))
                    }
                    Text(verbatim: file.path).dsFont(DS.Font.monoMicro).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                    Spacer(minLength: DS.Space.s1)
                    Text(verbatim: ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)).dsFont(DS.Font.microNumeric).foregroundStyle(DS.Color.textTertiary)
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let preview {
            VStack(alignment: .leading, spacing: DS.Space.s1) {
                Text(verbatim: item.isSkillFolder ? "SKILL.md" : item.url.lastPathComponent).dsFont(DS.Font.sectionLabel).foregroundStyle(DS.Color.textSecondary)
                Text(verbatim: preview.body.isEmpty ? " " : preview.body)
                    .font(DS.Font.monoMicro.font)
                    .foregroundStyle(DS.Color.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, minHeight: LibraryMetrics.codeMinHeight, alignment: .topLeading)
                    .padding(DS.Space.s3)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.md).fill(DS.Color.editor))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).strokeBorder(DS.Color.border, lineWidth: DSMetrics.hairline))
                if preview.truncated {
                    Text("Showing the first part of this file. Open it in the editor to read the rest.", bundle: .module)
                        .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                }
            }
        } else {
            HStack(spacing: DS.Space.s2) {
                DSSpinner(size: DS.Space.s4, delayed: true)
                Text("Loading…", bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
            }
        }
    }
}

struct LibraryProfileDetail: View {
    let controller: LibraryController
    let profile: LaunchProfile

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.s4) {
                HStack(spacing: DS.Space.s2) {
                    Text(verbatim: profile.name).dsFont(DS.Font.pageTitle).foregroundStyle(DS.Color.textPrimary).lineLimit(2)
                    if LibraryProfileFormat.isBuiltin(profile) { DSBadge(String(localized: "Built-in", bundle: .module)) }
                }
                VStack(alignment: .leading, spacing: DS.Space.s1_5) {
                    MetaRow(label: "Agent") { Text(verbatim: AgentInfo.displayName(profile.provider)).dsFont(DS.Font.small).foregroundStyle(DS.Color.textPrimary) }
                    MetaRow(label: "Model") { Text(verbatim: profile.model ?? "Default").dsFont(DS.Font.small).foregroundStyle(DS.Color.textPrimary) }
                    MetaRow(label: "Permissions") { Text(verbatim: LibraryProfileFormat.permissions(profile)).dsFont(DS.Font.small).foregroundStyle(DS.Color.textPrimary) }
                    if !profile.extraArgs.isEmpty {
                        MetaRow(label: "Extra arguments") { Text(verbatim: profile.extraArgs.joined(separator: " ")).dsFont(DS.Font.monoMicro).foregroundStyle(DS.Color.textPrimary) }
                    }
                    if !profile.env.isEmpty {
                        MetaRow(label: "Environment") { Text(verbatim: profile.env.keys.sorted().joined(separator: ", ")).dsFont(DS.Font.monoMicro).foregroundStyle(DS.Color.textPrimary) }
                    }
                    MetaRow(label: "Default for agent") { Text(verbatim: profile.isDefault ? "Yes" : "No").dsFont(DS.Font.small).foregroundStyle(DS.Color.textPrimary) }
                }
                Text(verbatim: LibraryProfileLine.commandLine(for: profile)).font(DS.Font.monoMicro.font).foregroundStyle(DS.Color.textSecondary).textSelection(.enabled)
                DSButton(.libraryEditProfiles, id: .libraryProfileEdit, "Edit Profiles…", variant: .outline, size: .sm)
            }
            .padding(DS.Space.s4)
            .frame(maxWidth: LibraryMetrics.detailMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
