import RackyDesignSystem
import RackyProtocol
import AppKit
import SwiftUI

extension ActionRegistry {
    /// `true` se o controle da ação deve aparecer: a fatia já existe e a tarefa dona já registrou o handler.
    /// Evita botão morto na sidebar enquanto o fluxo (composer, arquivar, apagar...) ainda não existe (AC-T28).
    func isOffered(_ id: ActionID) -> Bool {
        switch availability(of: id) {
        case .unavailable, .unregistered: false
        case .disabled, .enabled: true
        }
    }
}

/// Texto com o trecho casado da busca em `warning/20` (M-207).
struct HighlightedText: View {
    let text: String
    let query: String
    let style: DSTextStyle
    let color: Color

    var body: some View {
        Text(attributed)
            .dsFont(style)
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var attributed: AttributedString {
        var a = AttributedString(text)
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty, let r = a.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) {
            a[r].backgroundColor = DS.ColorSpec.warning.scaled(0.2).color
        }
        return a
    }
}

// MARK: Linha de projeto (03 §2.5)

struct ProjectRowView: View {
    let model: SidebarModel
    let data: ProjectSectionData
    @Environment(\.actionRegistry) private var registry
    @State private var hovering = false

    var body: some View {
        let pid = data.id.uuidString
        let renaming = model.renamingProject == data.id
        ZStack(alignment: .trailing) {
            if renaming {
                projectLine(renaming: true, pid: pid)
            } else {
                ActionButton(.sidebarProjectToggle, id: .sidebarProject(pid), argument: .select(pid)) {
                    projectLine(renaming: false, pid: pid)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(Text(verbatim: projectLabel))
                        .accessibilityValue(Text(verbatim: data.collapsed ? "collapsed" : "expanded"))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isHeader)
            }
            if hovering, !renaming {
                HStack(spacing: DS.Space.s0_5) {
                    ProjectMenuButton(model: model, project: data.id)
                    if let registry, registry.isOffered(.projectNewSession) {
                        DSIconButton(
                            .projectNewSession, id: .sidebarProjectNewSession(pid), symbol: "plus",
                            name: String(localized: "New Session in \(data.name)…", bundle: .module), variant: .row, argument: .select(pid))
                    }
                }
                .padding(.trailing, DS.Space.s2)
            }
        }
        .frame(height: SidebarMetrics.projectRowHeight)
        .onHover { hovering = $0 }
        .animation(MotionPolicy.shared.animation(MotionTokens.Easing.ease, MotionTokens.Duration.hover), value: hovering)
        .dsContextMenu(name: "projectContext", groups: { ProjectMenuItems(model: model, project: data.id).groups() })
        .overlay { focusRing(model.keyboardFocus == .project(data.id)) }
    }

    /// Conteúdo da linha; no modo renomear, o nome vira o campo inline (03 §2.11) e a linha deixa de ser um botão.
    private func projectLine(renaming: Bool, pid: String) -> some View {
        HStack(spacing: SidebarMetrics.projectGap) {
            Image(systemName: "chevron.down")
                .font(.system(size: SidebarMetrics.chevron - 2, weight: .semibold))
                .foregroundStyle(DS.Color.textTertiary)
                .rotationEffect(.degrees(data.collapsed ? -90 : 0))
                .animation(MotionPolicy.shared.animation(MotionTokens.Easing.standard, MotionTokens.Duration.fast), value: data.collapsed)
                .frame(width: SidebarMetrics.chevron, height: SidebarMetrics.chevron)
                .a11y(.sidebarProjectToggle(pid), kind: "image")
            if renaming {
                InlineRenameField(
                    initialText: data.name, font: DS.Font.bodyStrong.nsFont,
                    onCommit: { text in
                        guard let registry else { return }
                        Task { _ = try? await registry.perform(.projectRename, .set(text)) }
                    },
                    onCancel: { model.cancelRenameProject() }
                )
                .padding(.horizontal, DS.Space.s1)
                .frame(height: SidebarMetrics.line1Height)
                .background(RoundedRectangle(cornerRadius: DS.Radius.xs * 2).fill(DS.ColorSpec.paneTitleInputBackground.color))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.xs * 2).strokeBorder(DS.ColorSpec.ring.scaled(0.5).color, lineWidth: DSMetrics.hairline))
                .a11y(.sidebarProjectRename(pid), kind: "textfield", value: data.name)
            } else {
                Text(verbatim: data.name)
                    .dsFont(DS.Font.sectionLabel)
                    .foregroundStyle(DS.Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: DS.Space.s1)
            if !hovering, !renaming {
                Text(verbatim: "\(data.sessionCount)")
                    .dsFont(DS.Font.microNumeric)
                    .foregroundStyle(DS.Color.textTertiary)
            }
        }
        .padding(.leading, SidebarMetrics.projectPaddingLeading)
        .padding(.trailing, SidebarMetrics.sectionPaddingH)
        .frame(height: SidebarMetrics.projectRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering && !renaming ? DS.Color.fg5 : Color.clear)
        .contentShape(Rectangle())
    }

    private var projectLabel: String {
        let n = data.sessionCount
        return String(localized: "\(data.name), \(n) sessions", bundle: .module)
    }
}

/// Anel de foco por teclado: interno, 2 pt `ring/50` (DS §13).
@ViewBuilder
func focusRing(_ visible: Bool, radius: CGFloat = SidebarMetrics.agentRowRadius) -> some View {
    if visible {
        RoundedRectangle(cornerRadius: radius)
            .strokeBorder(DS.ColorSpec.ring.scaled(0.5).color, lineWidth: MotionTokens.Stroke.ring)
            .allowsHitTesting(false)
    }
}

// MARK: Linha pendente (03 §2.9)

struct PendingRowView: View {
    let model: SidebarModel
    let data: PendingRowData
    @Environment(\.actionRegistry) private var registry
    @State private var hovering = false

    var body: some View {
        let pid = data.id.uuidString
        ZStack(alignment: .trailing) {
            ActionButton(.sessionSelect, argument: .select(pid)) {
                pendingContent
            }
            .buttonStyle(.plain)
            if hovering || data.failed {
                if let registry, registry.isOffered(data.failed ? .sessionDiscardPending : .sessionCancelLaunch) {
                    DSIconButton(
                        data.failed ? .sessionDiscardPending : .sessionCancelLaunch, id: .sidebarPendingCancel(pid),
                        symbol: "xmark", name: data.failed ? String(localized: "Discard", bundle: .module) : String(localized: "Cancel", bundle: .module),
                        variant: .row, argument: .select(pid))
                    .padding(.trailing, SidebarMetrics.cardPaddingH)
                }
            }
        }
        .padding(.leading, SidebarMetrics.cardMarginLeading)
        .padding(.trailing, SidebarMetrics.cardMarginTrailing)
        .onHover { hovering = $0 }
        .a11y(.sidebarPending(pid), kind: "row", label: data.name)
        .overlay { focusRing(model.keyboardFocus == .pending(data.id), radius: SidebarMetrics.cardRadius) }
    }

    private var pendingContent: some View {
        let pid = data.id.uuidString
        return ZStack(alignment: .trailing) {
            HStack(alignment: .center, spacing: SidebarMetrics.statusGap) {
                ZStack {
                    if data.failed {
                        DSAgentIndicator(.alert, size: .lg)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    } else {
                        DSSpinner(size: SidebarMetrics.pendingSpinner)
                    }
                }
                .frame(width: SidebarMetrics.statusColumn, height: SidebarMetrics.pendingHeight)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: data.name)
                        .dsFont(DS.Font.body)
                        .foregroundStyle(DS.Color.textSecondary)
                        .lineLimit(1)
                    Text(verbatim: data.phaseText)
                        .dsFont(DS.Font.small)
                        .foregroundStyle(data.failed ? DS.Color.destructive : DS.Color.textTertiary)
                        .lineLimit(1)
                        .id(data.phaseText)
                        .transition(MotionPolicy.shared.reduceMotion ? .opacity : .push(from: .bottom))
                        .a11y(.sidebarSessionPhase(pid), kind: "text", label: data.phaseText)
                }
                .clipped()
                Spacer(minLength: DS.Space.s1)
            }
            .padding(.horizontal, SidebarMetrics.cardPaddingH)
            .frame(height: SidebarMetrics.pendingHeight + SidebarMetrics.line2Height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: SidebarMetrics.cardRadius).fill(hovering ? DS.Color.hoverRow : Color.clear))
            .animation(MotionPolicy.shared.animation(MotionTokens.Easing.standard, MotionTokens.Duration.fast), value: data.phaseText)
            .animation(MotionPolicy.shared.animation(MotionTokens.Easing.expoOut, MotionTokens.Duration.disclosure), value: data.failed)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(verbatim: "\(data.name), \(data.phaseText)"))
        }
    }
}

// MARK: Card de sessão (03 §2.6, DS §12.9)

struct SessionCardView: View {
    let model: SidebarModel
    let data: SessionCardData
    let query: String
    let selection: Namespace.ID
    let glowing: Bool
    @Environment(\.actionRegistry) private var registry
    @State private var hovering = false

    var body: some View {
        let sid = data.id.uuidString
        let renaming = model.renamingSession == data.id
        VStack(alignment: .leading, spacing: SidebarMetrics.cardGap) {
            if renaming {
                header(renaming: true)
            } else {
                ActionButton(.sessionSelect, id: .sidebarSession(sid), argument: .select(sid)) {
                    header(renaming: false)
                        .contentShape(Rectangle())
                        .accessibilityElement(children: .combine)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: data.a11yLabel))
                .accessibilityAddTraits(data.selected ? .isSelected : [])
                .accessibilityAction(named: Text("Rename…", bundle: .module)) {
                    guard let registry else { return }
                    Task { _ = try? await registry.perform(.sessionRename, .select(sid)) }
                }
            }
            if !data.agentRows.isEmpty, !data.agentsCollapsed {
                agents
            } else if data.groupedTerminals > 0, !data.agentsCollapsed, data.agentRows.isEmpty {
                groupedRow
            }
            if !data.computers.isEmpty, !data.agentsCollapsed {
                computerRows
            }
            // As tabelas que a sessão coletou: um clique abre como tab da sessão (o mesmo nível do agente e dos computadores).
            let tables = model.sessionDatasets(data.id)
            if !tables.isEmpty, !data.agentsCollapsed {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(tables) { SessionDatasetRowView(sessionID: data.id, row: $0) }
                }
                .padding(.leading, agentIndent - SidebarMetrics.agentRowPaddingH)
            }
        }
        .animation(MotionPolicy.shared.animation(MotionTokens.Springs.snappy), value: data.computers.map(\.id))
        .padding(.vertical, verticalPadding)
        .padding(.horizontal, SidebarMetrics.cardPaddingH)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { surface }
        .overlay { focusRing(model.keyboardFocus == .session(data.id), radius: SidebarMetrics.cardRadius) }
        .overlay { glow }
        .padding(.leading, SidebarMetrics.cardMarginLeading)
        .padding(.trailing, SidebarMetrics.cardMarginTrailing)
        .onHover { hovering = $0 }
        .animation(MotionPolicy.shared.animation(MotionTokens.Easing.ease, MotionTokens.Duration.hover), value: hovering)
        // Sessão limpa: o caminho real da pasta aparece no hover, porque renomear a sessão não renomeia a pasta (AC-1103).
        .dsTooltip(data.folderPath, enabled: data.kind == .clean && !renaming)
        .dsContextMenu(name: "sessionContext", groups: { SessionMenuItems(model: model, session: data.id).groups() })
    }

    private var verticalPadding: CGFloat {
        let titleOnly = data.agentRows.isEmpty && data.groupedTerminals == 0
        return titleOnly ? SidebarMetrics.cardPaddingVTitleOnly : SidebarMetrics.cardPaddingV
    }

    @ViewBuilder private var surface: some View {
        ZStack {
            if hovering, !data.selected {
                RoundedRectangle(cornerRadius: SidebarMetrics.cardRadius).fill(DS.Color.hoverRow)
            }
            if data.selected {
                RoundedRectangle(cornerRadius: SidebarMetrics.cardRadius).fill(DS.Color.sidebarSelected)
                    .matchedGeometryEffect(id: "selection", in: selection)
            }
        }
        .animation(MotionPolicy.shared.animation(MotionTokens.Springs.snappy), value: data.selected)
    }

    @ViewBuilder private var glow: some View {
        RoundedRectangle(cornerRadius: SidebarMetrics.cardRadius)
            .strokeBorder(DS.Color.locate, lineWidth: MotionTokens.Stroke.rim)
            .opacity(glowing ? 1 : 0)
            .animation(MotionPolicy.shared.animation(MotionTokens.Easing.ease, MotionTokens.Duration.hover), value: glowing)
            .allowsHitTesting(false)
            .a11y(.sidebarSessionRevealGlow(data.id.uuidString), kind: "container", value: glowing ? "on" : "off")
    }

    // Colunas de status + linhas 1 e 2.
    private func header(renaming: Bool) -> some View {
        let sid = data.id.uuidString
        return HStack(alignment: .top, spacing: SidebarMetrics.statusGap) {
            statusColumn
            VStack(alignment: .leading, spacing: SidebarMetrics.cardGap) {
                HStack(spacing: DS.Space.s1_5) {
                    if renaming {
                        InlineRenameField(
                            initialText: data.title, font: renameFont,
                            onCommit: { text in
                                guard let registry else { return }
                                Task { _ = try? await registry.perform(.sessionRename, .set(text)) }
                            },
                            onCancel: { model.cancelRename() }
                        )
                        .padding(.horizontal, DS.Space.s1)
                        .frame(height: SidebarMetrics.line1Height)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.xs * 2).fill(DS.ColorSpec.paneTitleInputBackground.color))
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.xs * 2).strokeBorder(DS.ColorSpec.ring.scaled(0.5).color, lineWidth: DSMetrics.hairline))
                        .a11y(.sidebarSessionRename(sid), kind: "textfield", value: data.title)
                    } else {
                        HighlightedText(
                            text: data.title, query: query, style: DS.Font.sessionTitle,
                            color: data.unread || data.selected ? DS.Color.textPrimary : DS.Color.textPrimary.opacity(0.88))
                            .fontWeight(data.unread ? .semibold : .medium)
                            // Nome cortado ("Detached…"): o hover mostra inteiro.
                            .help(data.title)
                            .a11y(.sidebarSessionName(sid), kind: "text", label: data.title)
                            .simultaneousGesture(
                                TapGesture(count: 2).onEnded {
                                    guard let registry else { return }
                                    Task { _ = try? await registry.perform(.sessionRename, .select(sid)) }
                                })
                    }
                    ForEach(Array(data.badges.enumerated()), id: \.offset) { _, badge in
                        DSBadge(badge.title, variant: badge.variant)
                    }
                    Spacer(minLength: DS.Space.s1)
                    if data.offersSubagentToggle, !renaming, let registry, registry.isOffered(.sessionSetSubagentComputers) {
                        SubagentToggleButton(
                            sessionID: data.id, mode: data.subagent, id: .sidebarSessionComputers(sid), restartPending: data.restartToApply)
                            .opacity(data.subagent.isOn || hovering || data.selected ? 1 : 0)
                            .animation(MotionPolicy.shared.animation(MotionTokens.Easing.ease, MotionTokens.Duration.hover), value: hovering)
                    }
                    trailing
                }
                .frame(height: SidebarMetrics.line1Height)
                line2
                    .frame(height: SidebarMetrics.line2Height)
                if data.note != nil || data.editingNote {
                    noteLine
                }
                if data.restartToApply, !renaming, let registry, registry.isOffered(.sessionRestartToApply) {
                    RestartToApplyPill(sessionID: data.id, id: .sidebarSessionRestartToApply(sid))
                }
            }
        }
    }

    private var renameFont: NSFont { DS.Font.sessionTitle.nsFont }

    private var statusColumn: some View {
        ZStack(alignment: .topTrailing) {
            DSAgentIndicator(data.glyph, size: .lg)
                .frame(width: SidebarMetrics.statusColumn, height: SidebarMetrics.line1Height)
                .a11y(.sidebarSessionStatus(data.id.uuidString), kind: "image", label: data.stateLabel)
            if data.unread {
                Circle().fill(DS.Color.unread)
                    .frame(width: SidebarMetrics.unreadDot, height: SidebarMetrics.unreadDot)
            }
        }
        .frame(width: SidebarMetrics.statusColumn)
    }

    @ViewBuilder private var trailing: some View {
        if hovering, let registry, registry.isOffered(.sessionArchive) {
            DSIconButton(
                .sessionArchive, id: .sidebarSessionArchive(data.id.uuidString), symbol: "archivebox",
                name: String(localized: "Archive Session…", bundle: .module), variant: .row, argument: .select(data.id.uuidString))
        } else {
            Text(verbatim: data.timeText)
                .dsFont(DS.Font.sidebarMetaNumeric)
                .foregroundStyle(DS.Color.textTertiary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    @ViewBuilder private var line2: some View {
        HStack(spacing: SidebarMetrics.statusGap) {
            switch data.line2 {
            case .branch(let b):
                Image(systemName: "arrow.triangle.branch").font(.system(size: SidebarMetrics.line2Icon))
                HighlightedText(text: b, query: query, style: DS.Font.sidebarMeta, color: DS.Color.textTertiary)
                    .truncationMode(.middle)
            case .folder(let f):
                Image(systemName: "folder").font(.system(size: SidebarMetrics.line2Icon))
                HighlightedText(text: f, query: query, style: DS.Font.sidebarMeta, color: DS.Color.textTertiary)
                    .truncationMode(.middle)
            case .missingFolder:
                Image(systemName: "exclamationmark.circle").font(.system(size: SidebarMetrics.line2Icon))
                    .foregroundStyle(DS.Color.destructive)
                Text("Folder not found", bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.destructive)
            }
            if data.dirty {
                Circle().fill(DS.Color.gitModified)
                    .frame(width: GitHubMetrics.dot, height: GitHubMetrics.dot)
                    .accessibilityLabel(Text("Uncommitted changes", bundle: .module))
            }
            if data.ahead > 0 {
                Text(verbatim: "↑\(data.ahead)")
                    .dsFont(DS.Font.microNumeric)
                    .foregroundStyle(DS.Color.textTertiary)
                    .fixedSize()
                    .accessibilityLabel(Text("\(data.ahead) commits not pushed", bundle: .module))
            }
            if data.notStarted {
                Text("Not started", bundle: .module)
                    .dsFont(DS.Font.small)
                    .foregroundStyle(DS.Color.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: .zero)
            if let pr = data.pr {
                PullRequestChipView(pr: pr, sessionID: data.id)
                    .fixedSize()
            }
        }
        .foregroundStyle(DS.Color.textTertiary)
    }

    /// Linha 3, nota da sessão (03 §2.6, AC-208): `small` `fg/60`, uma linha; duplo clique edita; o hover mostra autor e tempo.
    @ViewBuilder private var noteLine: some View {
        let sid = data.id.uuidString
        if data.editingNote {
            InlineRenameField(
                initialText: data.note ?? "", font: DS.Font.small.nsFont,
                onCommit: { text in
                    guard let registry else { return }
                    Task { _ = try? await registry.perform(.sessionEditNote, .set(text)) }
                },
                onCancel: { model.cancelEditNote() }
            )
            .padding(.horizontal, DS.Space.s1)
            .frame(height: SidebarMetrics.line2Height + DS.Space.s1)
            .background(RoundedRectangle(cornerRadius: DS.Radius.xs * 2).fill(DS.ColorSpec.paneTitleInputBackground.color))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.xs * 2).strokeBorder(DS.ColorSpec.ring.scaled(0.5).color, lineWidth: DSMetrics.hairline))
            .a11y(.sidebarSessionNote(sid), kind: "textfield", value: data.note ?? "")
        } else if let note = data.note {
            Text(verbatim: note)
                .dsFont(DS.Font.small)
                .foregroundStyle(DS.ColorSpec.textSecondary.scaled(0.6).color)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, minHeight: SidebarMetrics.line2Height, alignment: .leading)
                .contentShape(Rectangle())
                .dsTooltip(data.noteDetail ?? "", enabled: data.noteDetail != nil)
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        guard let registry else { return }
                        Task { _ = try? await registry.perform(.sessionEditNote, .select(sid)) }
                    })
                .a11y(.sidebarSessionNote(sid), kind: "text", label: note)
        }
    }

    // MARK: Linhas de agente (03 §2.7) e pílula-resumo (03 §2.6)

    private var agentIndent: CGFloat { SidebarMetrics.statusColumn + SidebarMetrics.statusGap }

    @ViewBuilder private var agents: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let summary = data.summary {
                SummaryPillView(model: model, data: data, summary: summary)
            }
            if data.summary == nil || data.summaryExpanded {
                ForEach(data.agentRows) { row in
                    AgentRowView(model: model, row: row, query: query, soleAgent: data.agentRows.count == 1 && data.groupedTerminals == 0)
                }
            }
            if data.groupedTerminals > 0 {
                groupedRow
            }
        }
        .padding(.leading, agentIndent - SidebarMetrics.agentRowPaddingH)
        .a11y(.sidebarSessionAgents(data.id.uuidString), kind: "container")
    }

    /// Computadores que o Claude desta sessão reservou: uma linha filha cada, com estado, o que fazem e a miniatura no hover (F12).
    private var computerRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(data.computers) { row in
                ComputerChildRowView(sessionID: data.id, row: row)
            }
        }
        .padding(.leading, agentIndent - SidebarMetrics.agentRowPaddingH)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(DS.Color.border)
                .frame(width: SubagentMetrics.connector)
                .padding(.leading, SubagentMetrics.connectorInset)
                .padding(.vertical, DS.Space.s1)
        }
    }

    private var groupedRow: some View {
        Text("+\(data.groupedTerminals) terminals", bundle: .module)
            .dsFont(DS.Font.small)
            .foregroundStyle(DS.Color.textTertiary)
            .padding(.horizontal, SidebarMetrics.agentRowPaddingH)
            .frame(height: SidebarMetrics.agentRowHeight, alignment: .leading)
            .padding(.leading, data.agentRows.isEmpty ? agentIndent - SidebarMetrics.agentRowPaddingH : .zero)
    }
}

struct AgentRowView: View {
    let model: SidebarModel
    let row: AgentRowData
    let query: String
    /// Único agente da sessão: o estado já está no card, a linha não repete o indicador.
    var soleAgent = false
    @Environment(\.actionRegistry) private var registry
    @Environment(\.computersController) private var computers
    @State private var hovering = false

    var body: some View {
        let sid = row.sessionID.uuidString, tid = row.id.uuidString
        let line = HStack(spacing: SidebarMetrics.agentRowGap + DS.Space.s0_5) {
            // v5: o estado fica no card; a linha só repete o indicador quando a sessão tem mais de um agente.
            if soleAgent {
                DSAgentLogo(row.provider, size: SidebarMetrics.agentLogo)
                    .a11y(.sidebarSessionAgentStatus(sid, tid), kind: "image", label: row.stateLabel)
            } else {
                DSAgentIndicator(row.glyph, size: .sm)
                    .a11y(.sidebarSessionAgentStatus(sid, tid), kind: "image", label: row.stateLabel)
                DSAgentLogo(row.provider, size: SidebarMetrics.agentLogo)
            }
            HStack(spacing: DS.Space.s1) {
                HighlightedText(text: row.lead, query: query, style: DS.Font.sidebarMeta, color: DS.Color.textSecondary)
                    .a11y(.sidebarSessionAgentLastMessage(sid, tid), kind: "text", label: row.lead)
                    .help([row.lead, row.trail].compactMap { $0 }.joined(separator: " · "))
                if let trail = row.trail {
                    Text(verbatim: "· \(trail)").dsFont(DS.Font.sidebarMeta).foregroundStyle(DS.Color.textTertiary).lineLimit(1)
                }
            }
            Spacer(minLength: DS.Space.s1)
        }
        .padding(.leading, SidebarMetrics.agentRowPaddingH)
        .padding(.trailing, row.children.isEmpty ? SidebarMetrics.agentRowPaddingH : .zero)
        .frame(height: SidebarMetrics.agentRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(SidebarProjector.providerName(row.provider)), \(row.lead), \(row.stateLabel)"))
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                if let registry, registry.isOffered(.paneShow) {
                    ActionButton(.paneShow, id: .sidebarSessionAgent(sid, tid), argument: .select(tid)) { line }
                        .buttonStyle(.plain)
                } else {
                    line.a11y(.sidebarSessionAgent(sid, tid), kind: "row", label: row.lead)
                }
                if !row.children.isEmpty {
                    ActionButton(
                        .agentToggleChildren, id: .sidebarSessionAgentChildrenToggle(sid, tid), argument: .select(tid),
                        tooltip: row.childrenCollapsed ? String(localized: "Show Subagents", bundle: .module) : String(localized: "Hide Subagents", bundle: .module)
                    ) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: SidebarMetrics.chevron, weight: .medium))
                            .foregroundStyle(DS.Color.textSecondary)
                            .rotationEffect(.degrees(row.childrenCollapsed ? -90 : 0))
                            .animation(MotionPolicy.shared.animation(MotionTokens.Easing.standard, MotionTokens.Duration.fast), value: row.childrenCollapsed)
                            .frame(width: SubagentMetrics.toggleBox, height: SidebarMetrics.agentRowHeight)
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(Text(verbatim: row.childrenCollapsed ? "collapsed" : "expanded"))
                }
            }
            .background(RoundedRectangle(cornerRadius: SidebarMetrics.agentRowRadius).fill(hovering ? DS.Color.hoverAgentRow : Color.clear))
            .overlay { focusRing(model.keyboardFocus == .agent(session: row.sessionID, terminal: row.id)) }
            .onHover { hovering = $0 }
            .animation(MotionPolicy.shared.animation(MotionTokens.Easing.ease, MotionTokens.Duration.hover), value: hovering)
            // F28: com os subagentes recolhidos o card ainda mostra que o humano tem o controle (e deixa devolver).
            if row.childrenCollapsed, let held = row.children.compactMap(\.computer).first(where: { HumanControlLine.isHuman($0, computers) }) {
                HumanControlLine(computer: held, controlID: .sidebarSessionAgentControl(sid, tid), handBackID: .sidebarSessionAgentHandBack(sid, tid))
            }
            if !row.children.isEmpty, !row.childrenCollapsed {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(row.children) { child in
                        SubagentRowView(sessionID: row.sessionID, terminalID: row.id, child: child)
                    }
                }
                .padding(.leading, SidebarMetrics.statusColumn)
                .transition(MotionPolicy.shared.reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -DS.Space.s1)))
            }
        }
        .animation(MotionPolicy.shared.animation(MotionTokens.Springs.snappy), value: row.children.map(\.id))
        .animation(MotionPolicy.shared.animation(MotionTokens.Springs.snappy), value: row.childrenCollapsed)
    }
}

struct SummaryPillView: View {
    let model: SidebarModel
    let data: SessionCardData
    let summary: [SummaryGroup]

    var body: some View {
        let sid = data.id.uuidString
        ActionButton(.sessionToggleAgents, id: .sidebarSessionSummaryPill(sid), argument: .select(sid)) {
            HStack(spacing: DS.Space.s2) {
                ForEach(Array(summary.enumerated()), id: \.offset) { _, group in
                    HStack(spacing: DS.Space.s1) {
                        DSAgentIndicator(group.glyph, size: .sm)
                        ForEach(Array(group.providers.enumerated()), id: \.offset) { _, p in DSAgentLogo(p, size: SidebarMetrics.summaryLogo) }
                        Text(verbatim: "\(group.count)").dsFont(DS.Font.microNumeric).foregroundStyle(DS.Color.textSecondary)
                    }
                }
                Spacer(minLength: DS.Space.s1)
                Image(systemName: "chevron.down")
                    .font(.system(size: SidebarMetrics.chevron, weight: .medium))
                    .foregroundStyle(DS.Color.textSecondary)
                    .rotationEffect(.degrees(data.summaryExpanded ? 180 : 0))
            }
            .padding(.horizontal, SidebarMetrics.agentRowPaddingH)
            .frame(height: SidebarMetrics.agentRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: String(localized: "with \(data.agentRows.count) terminals", bundle: .module)))
        .accessibilityValue(Text(verbatim: data.summaryExpanded ? "expanded" : "collapsed"))
    }
}

/// "▤ books2 · 80 rows" no card da sessão: abre a tabela numa tab da sessão.
struct SessionDatasetRowView: View {
    let sessionID: UUID
    let row: SessionDatasetRow
    @State private var hovering = false

    var body: some View {
        ActionButton(
            .datasetOpen, id: .sidebarSessionDataset(sessionID.uuidString, row.id), argument: .select(row.id),
            tooltip: String(localized: "Open the table in a tab", bundle: .module)
        ) {
            HStack(spacing: SidebarMetrics.agentRowGap) {
                Image(systemName: "tablecells")
                    .font(.system(size: SidebarMetrics.line2Icon + DS.Space.s0_5))
                    .foregroundStyle(DS.Color.dataValid)
                Text(verbatim: row.name).dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary).lineLimit(1).help(row.name)
                Spacer(minLength: DS.Space.s1)
                Text(verbatim: row.rows.formatted()).dsFont(DS.Font.microNumeric).foregroundStyle(DS.Color.textTertiary).fixedSize()
            }
            .padding(.horizontal, SidebarMetrics.agentRowPaddingH)
            .frame(height: SidebarMetrics.agentRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: SidebarMetrics.agentRowRadius).fill(hovering ? DS.Color.hoverAgentRow : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
