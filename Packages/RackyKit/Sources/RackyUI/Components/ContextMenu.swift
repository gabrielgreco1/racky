import RackyDesignSystem
import RackyProtocol
import AppKit
import SwiftUI

// Menus de contexto no `DSMenuPanel` (F17, 02 §12.15): nenhum `NSMenu`/`.contextMenu` nativo fora da barra de menus do app.
// Clique direito (ou ⌃clique) abre o painel desenhado na posição do cursor; o painel já traz 13 pt, ícone à esquerda, atalho à
// direita, separadores sutis e o item destrutivo em vermelho (a confirmação é da própria ação).

/// Ícone, atalho e destrutividade de cada ação oferecida em menus de contexto.
enum ContextMenuStyle {
    private static let symbols: [ActionID: String] = [
        .sessionRename: "pencil", .sessionEditNote: "note.text", .sessionCopyBranch: "arrow.triangle.branch",
        .sessionMarkRead: "envelope.open", .sessionMarkUnread: "envelope.badge", .sessionResumeAgents: "play",
        .sessionMoveToProject: "folder", .sessionConvertToProject: "folder.badge.plus", .sessionRestore: "arrow.uturn.backward",
        .sessionArchive: "archivebox", .sessionDelete: "trash",
        .projectNewSession: "plus", .projectNewSessionFromRef: "arrow.triangle.pull", .projectRename: "pencil",
        .projectCollapseAll: "chevron.up.chevron.down", .projectHide: "eye.slash", .projectRemove: "trash",
        .itemOpenIn: "arrow.up.forward.app", .itemOpenInEditor: "chevron.left.forwardslash.chevron.right", .itemRevealInFinder: "folder",
        .itemOpenOnGitHub: "link", .itemCopyPath: "doc.on.doc", .itemRefreshGit: "arrow.clockwise", .itemCopyId: "number",
        .tabRename: "pencil", .tabResetTitle: "arrow.counterclockwise", .tabClose: "xmark", .tabCloseOthers: "xmark.square",
        .tabCloseRight: "arrow.right.to.line",
        .paneSplitRight: "rectangle.split.2x1", .paneSplitDown: "rectangle.split.1x2", .paneEqualize: "equal.square",
        .paneToggleExpand: "arrow.up.left.and.arrow.down.right", .paneCloseOthers: "xmark.square", .paneClose: "xmark",
        .paneCopyId: "number", .editCopy: "doc.on.doc", .editPaste: "doc.on.clipboard", .editSelectAll: "selection.pin.in.out",
        .findOpen: "magnifyingglass", .terminalClear: "eraser", .terminalRestart: "arrow.clockwise", .terminalCopyId: "number",
        .terminalSendInterrupt: "stop", .terminalForceQuit: "bolt.slash", .sidebarHideNavItem: "eye.slash", .appHideAppName: "eye.slash",
    ]
    static let destructive: Set<ActionID> = [.sessionDelete, .projectRemove, .terminalForceQuit]

    /// Alvo do clique direito enquanto o menu está aberto.
    static let targetRing: CGFloat = 1.5
    static let targetFill: Double = 0.6

    static func symbol(_ action: ActionID) -> String { symbols[action] ?? "circle.dashed" }

    static func item(_ action: ActionID, title: String, argument: ActionArgument = .press, shortcut: String? = nil) -> DSMenuItem {
        let key = shortcut ?? action.spec.shortcut
        return DSMenuItem(
            action.rawValue + (argument.value ?? ""), title, icon: .symbol(symbol(action)), shortcut: key.isEmpty ? nil : key,
            destructive: destructive.contains(action), action: action, argument: argument)
    }

    /// Grupos viram itens separados por divisor sutil; ações sem dono e grupos vazios somem.
    @MainActor
    static func entries(groups: [[MenuEntry]], registry: ActionRegistry?) -> [DSMenuEntry] {
        var out: [DSMenuEntry] = []
        for group in groups {
            let visible = group.filter { registry?.isOffered($0.action) ?? true }
            guard !visible.isEmpty else { continue }
            if !out.isEmpty { out.append(.separator("g\(out.count)")) }
            out += visible.map { .item(item($0.action, title: $0.title, argument: $0.argument)) }
        }
        return out
    }
}

extension DSMenuPanel {
    /// Abre o menu de contexto com a ponta no ponto `point` (coordenadas globais da janela, origem no topo à esquerda).
    @MainActor @discardableResult
    static func presentContext(router: OverlayRouter?, registry: ActionRegistry?, name: String, at point: CGPoint, entries: [DSMenuEntry]) -> Bool {
        guard !entries.isEmpty else { return false }
        return present(
            router: router, registry: registry, name: name, anchor: CGRect(origin: point, size: CGSize(width: 1, height: 1)),
            width: DSMetrics.contextMenuWidth, entries: entries, itemFont: DS.Font.body)
    }
}

/// Ponto do evento em coordenadas globais do SwiftUI da janela (a raiz dos overlays cobre a janela inteira).
@MainActor
func windowPoint(of event: NSEvent) -> CGPoint? {
    guard let content = event.window?.contentView else { return nil }
    return CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
}

/// Captura só o clique direito (e ⌃clique); os demais eventos atravessam (`hitTest` nulo).
struct RightClickCatcher: NSViewRepresentable {
    let onRightClick: @MainActor (CGPoint) -> Void

    final class CatcherView: NSView {
        var onRightClick: @MainActor (CGPoint) -> Void = { _ in }
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let isContext = event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return isContext ? super.hitTest(point) : nil
        }
        override func rightMouseDown(with event: NSEvent) { fire(event) }
        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { fire(event) } else { super.mouseDown(with: event) }
        }
        private func fire(_ event: NSEvent) {
            if let p = windowPoint(of: event) { onRightClick(p) }
        }
    }

    func makeNSView(context: Context) -> CatcherView { CatcherView() }
    func updateNSView(_ view: CatcherView, context: Context) { view.onRightClick = onRightClick }
}

extension View {
    /// Menu de contexto no `DSMenuPanel`. `entries` é avaliado no clique (estado atual, Option pressionado etc.).
    func dsContextMenu(name: String, entries: @escaping @MainActor () -> [DSMenuEntry]) -> some View {
        modifier(DSContextMenuModifier(name: name, entries: entries))
    }

    /// Variante para grupos de `MenuEntry` (filtra pelo registro de ações).
    func dsContextMenu(name: String, groups: @escaping @MainActor () -> [[MenuEntry]]) -> some View {
        modifier(DSContextMenuGroupsModifier(name: name, groups: groups))
    }
}

private struct DSContextMenuModifier: ViewModifier {
    let name: String
    let entries: @MainActor () -> [DSMenuEntry]
    @Environment(\.overlayRouter) private var router
    @Environment(\.actionRegistry) private var registry

    /// Painel aberto por este clique direito: enquanto ele vive, o alvo fica marcado (anel de foco + fundo), como no Finder.
    @State private var menuID: UUID?

    private var targeted: Bool {
        guard let menuID, let popover = router?.popover else { return false }
        return popover.id == menuID && !popover.isClosing
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.control)
                    .fill(DS.Color.fg10.opacity(ContextMenuStyle.targetFill))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(DS.Color.aiAccent, lineWidth: ContextMenuStyle.targetRing))
                    .opacity(targeted ? 1 : 0)
                    .animation(.easeOut(duration: MotionTokens.Duration.fast), value: targeted)
                    .allowsHitTesting(false)
            }
            .overlay {
                RightClickCatcher { point in
                    if DSMenuPanel.presentContext(router: router, registry: registry, name: name, at: point, entries: entries()) {
                        menuID = router?.popover?.id
                    }
                }
            }
    }
}

private struct DSContextMenuGroupsModifier: ViewModifier {
    let name: String
    let groups: @MainActor () -> [[MenuEntry]]
    @Environment(\.actionRegistry) private var registry

    func body(content: Content) -> some View {
        content.dsContextMenu(name: name) { ContextMenuStyle.entries(groups: groups(), registry: registry) }
    }
}
