import RackyDesignSystem
import RackyProtocol
import AppKit
import SwiftUI

// Menus de contexto (03 §2.5, §2.6): `dsContextMenu` abre o `DSMenuPanel` (F17); nada de `NSMenu` nativo. Só entram itens cuja
// ação já tem dono nesta fatia (registrada) e que fazem sentido para o item (sem Git, não há "Copy Branch Name").

struct MenuEntry: Identifiable {
    var id: String { action.rawValue + (argument.value ?? "") }
    let action: ActionID
    let title: String
    var argument: ActionArgument = .press
}

private func optionHeld() -> Bool { EventModifiers.held(.option) }

struct ProjectMenuItems {
    let model: SidebarModel
    let project: UUID

    @MainActor func groups() -> [[MenuEntry]] {
        if let p = model.project(project) {
            let id = project.uuidString
            let arg = ActionArgument.select(id)
            let hasGitHub = p.gitRemoteURL?.contains("github.com") == true
            return [
                [
                    MenuEntry(action: .projectNewSession, title: String(localized: "New Session in \(p.name)…", bundle: .module), argument: arg),
                    MenuEntry(action: .projectNewSessionFromRef, title: String(localized: "New Session from Branch or PR…", bundle: .module), argument: arg),
                ],
                [
                    MenuEntry(action: .itemOpenIn, title: String(localized: "Open in…", bundle: .module), argument: arg),
                    MenuEntry(action: .itemOpenInEditor, title: String(localized: "Open in Editor", bundle: .module), argument: arg),
                    MenuEntry(action: .itemRevealInFinder, title: String(localized: "Reveal in Finder", bundle: .module), argument: arg),
                ] + (hasGitHub ? [MenuEntry(action: .itemOpenOnGitHub, title: String(localized: "Open on GitHub", bundle: .module), argument: arg)] : [])
                    + [MenuEntry(action: .itemCopyPath, title: String(localized: "Copy Path", bundle: .module), argument: arg)],
                [
                    MenuEntry(action: .projectRename, title: String(localized: "Rename…", bundle: .module), argument: arg),
                    MenuEntry(action: .projectCollapseAll, title: String(localized: "Collapse All Sessions", bundle: .module), argument: arg),
                    MenuEntry(action: .projectHide, title: String(localized: "Hide Project", bundle: .module), argument: arg),
                ],
                [MenuEntry(action: .projectRemove, title: String(localized: "Remove Project…", bundle: .module), argument: arg)],
                optionHeld()
                    ? [
                        MenuEntry(action: .itemRefreshGit, title: String(localized: "Refresh Git", bundle: .module), argument: arg),
                        MenuEntry(action: .itemCopyId, title: String(localized: "Copy Project ID", bundle: .module), argument: arg),
                    ] : [],
            ]
        }
        return []
    }
}

struct SessionMenuItems {
    let model: SidebarModel
    let session: UUID

    @MainActor func groups() -> [[MenuEntry]] {
        if let s = model.session(session) {
            let id = session.uuidString
            let arg = ActionArgument.select(id)
            let branch = model.worktree(of: s)?.branch
            let hasGit = s.kind == .worktree || s.kind == .checkout
            let interrupted = model.snapshot.terminals.contains { t in
                t.state == .interrupted && model.snapshot.tabs.contains { $0.id == t.tabID && $0.sessionID == s.id }
            }
            return [
                [
                    MenuEntry(action: .sessionRename, title: String(localized: "Rename…", bundle: .module), argument: arg),
                    MenuEntry(action: .sessionEditNote, title: String(localized: "Edit Note…", bundle: .module), argument: arg),
                ],
                [
                    MenuEntry(action: .itemOpenIn, title: String(localized: "Open in…", bundle: .module), argument: arg),
                    MenuEntry(action: .itemOpenInEditor, title: String(localized: "Open in Editor", bundle: .module), argument: arg),
                    MenuEntry(action: .itemRevealInFinder, title: String(localized: "Reveal in Finder", bundle: .module), argument: arg),
                    MenuEntry(action: .itemCopyPath, title: String(localized: "Copy Path", bundle: .module), argument: arg),
                ] + ((branch ?? "").isEmpty ? [] : [MenuEntry(action: .sessionCopyBranch, title: String(localized: "Copy Branch Name", bundle: .module), argument: arg)])
                    + (hasGit && !(branch ?? "").isEmpty
                        ? [
                            model.pullRequests[session] != nil
                                ? MenuEntry(action: .gitOpenPR, title: String(localized: "Open Pull Request", bundle: .module), argument: arg)
                                : MenuEntry(action: .gitCreatePR, title: String(localized: "Create Pull Request…", bundle: .module), argument: arg)
                        ] : []),
                [
                    s.unread
                        ? MenuEntry(action: .sessionMarkRead, title: String(localized: "Mark as Read", bundle: .module), argument: arg)
                        : MenuEntry(action: .sessionMarkUnread, title: String(localized: "Mark as Unread", bundle: .module), argument: arg)
                ],
                (interrupted ? [MenuEntry(action: .sessionResumeAgents, title: String(localized: "Resume Agents…", bundle: .module), argument: arg)] : [])
                    + (s.kind == .clean
                        ? [
                            MenuEntry(action: .sessionMoveToProject, title: String(localized: "Move to Project…", bundle: .module), argument: arg),
                            MenuEntry(action: .sessionConvertToProject, title: String(localized: "Convert to Project…", bundle: .module), argument: arg),
                        ] : []),
                [
                    s.archivedAt != nil || s.lifecycle == .archived
                        ? MenuEntry(action: .sessionRestore, title: String(localized: "Restore Session", bundle: .module), argument: arg)
                        : MenuEntry(action: .sessionArchive, title: String(localized: "Archive Session…", bundle: .module), argument: arg),
                    MenuEntry(action: .sessionDelete, title: String(localized: "Delete Session…", bundle: .module), argument: arg),
                ],
                optionHeld()
                    ? (hasGit ? [MenuEntry(action: .itemRefreshGit, title: String(localized: "Refresh Git", bundle: .module), argument: arg)] : [])
                        + [MenuEntry(action: .itemCopyId, title: String(localized: "Copy Session ID", bundle: .module), argument: arg)]
                    : [],
            ]
        }
        return []
    }
}

/// Botão `…` da linha de projeto: abre o mesmo conteúdo do context menu no `DSMenuPanel` (03 §2.5).
struct ProjectMenuButton: View {
    let model: SidebarModel
    let project: UUID
    @Environment(\.overlayRouter) private var router
    @Environment(\.actionRegistry) private var registry
    @State private var anchor: CGRect = .zero

    var body: some View {
        // lint-ui: allow buttons abre o DSMenuPanel (apresentação); os itens disparam ações do registro
        Button {
            DSMenuPanel.present(
                router: router, registry: registry, name: "projectMenu", anchor: anchor, width: DSMetrics.contextMenuWidth,
                entries: ContextMenuStyle.entries(groups: ProjectMenuItems(model: model, project: project).groups(), registry: registry),
                alignment: .trailing, itemFont: DS.Font.body)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: DSIconButtonVariant.row.icon, weight: .regular))
                .foregroundStyle(DS.Color.textSecondary)
                .frame(width: DSIconButtonVariant.row.box.width, height: DSIconButtonVariant.row.box.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { anchor = $0 }
        .dsTooltip(String(localized: "More", bundle: .module))
        .a11y(.sidebarProjectMenu(project.uuidString), kind: "menu", label: String(localized: "Project menu", bundle: .module))
    }
}

// MARK: Sort and Filter

/// Painel de menu temporário (03 §2.4, DS §12.15): o `DSMenuPanel` é da T1-12. Este é o **único** ponto que desenha
/// um menu rico à mão na sidebar; quando o `DSMenuPanel` existir, só este arquivo muda.
struct TemporaryMenuPanel<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s0_5) { content }
            .padding(DS.Space.s1)
            .frame(width: SidebarMetrics.filterMenuWidth)
            .background(DS.Color.menuSolid)
            .a11y(.sidebarProjectsFilterMenu, kind: "menu")
    }
}

struct MenuGroupLabel: View {
    let title: String
    var body: some View {
        Text(verbatim: title)
            .dsFont(DS.Font.small)
            .fontWeight(.medium)
            .foregroundStyle(DS.Color.textSecondary)
            .padding(.horizontal, DS.Space.s2)
            .frame(height: SidebarMetrics.agentRowHeight, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

struct MenuToggleRow: View {
    let title: String
    let on: Bool
    let radio: Bool
    let argument: ActionArgument
    let name: String
    @State private var hovering = false

    var body: some View {
        ActionButton(.sidebarSortFilter, id: .menuPanel(name), argument: argument) {
            HStack(spacing: DS.Space.s2) {
                Image(systemName: "checkmark")
                    .font(.system(size: SidebarMetrics.line2Icon + DS.Space.s0_5, weight: .semibold))
                    .opacity(on ? 1 : 0)
                    .frame(width: SidebarMetrics.chevron)
                Text(verbatim: title).dsFont(DS.Font.menuItem)
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
        .accessibilityValue(Text(verbatim: radio ? (on ? "selected" : "") : (on ? "checked" : "unchecked")))
    }
}

struct FilterMenuPanel: View {
    let model: SidebarModel

    var body: some View {
        TemporaryMenuPanel {
            MenuGroupLabel(title: String(localized: "Sort by", bundle: .module))
            MenuToggleRow(title: String(localized: "Recent Activity", bundle: .module), on: model.sort == .recent, radio: true, argument: .select("sort:recent"), name: "sort.recent")
            MenuToggleRow(title: String(localized: "Name", bundle: .module), on: model.sort == .name, radio: true, argument: .select("sort:name"), name: "sort.name")
            Divider().padding(.vertical, DS.Space.s0_5)
            MenuGroupLabel(title: String(localized: "Show", bundle: .module))
            MenuToggleRow(
                title: String(localized: "Sessions Idle for More Than 7 Days", bundle: .module), on: model.filters.idleOverWeek, radio: false,
                argument: .set("idleOverWeek=\(model.filters.idleOverWeek ? "off" : "on")"), name: "show.idleOverWeek")
            MenuToggleRow(
                title: String(localized: "Archived Sessions", bundle: .module), on: model.filters.archived, radio: false,
                argument: .set("archived=\(model.filters.archived ? "off" : "on")"), name: "show.archived")
            MenuToggleRow(
                title: String(localized: "Hidden Projects", bundle: .module), on: model.filters.hiddenProjects, radio: false,
                argument: .set("hiddenProjects=\(model.filters.hiddenProjects ? "off" : "on")"), name: "show.hiddenProjects")
            MenuToggleRow(
                title: String(localized: "Main Checkouts", bundle: .module), on: model.filters.mainCheckouts, radio: false,
                argument: .set("mainCheckouts=\(model.filters.mainCheckouts ? "off" : "on")"), name: "show.mainCheckouts")
            Divider().padding(.vertical, DS.Space.s0_5)
            HStack {
                Spacer()
                DSButton(.sidebarResetFilters, id: .menuPanel("reset"), "Reset", variant: .ghost, size: .xs)
            }
            .padding(.horizontal, DS.Space.s1)
        }
    }
}
