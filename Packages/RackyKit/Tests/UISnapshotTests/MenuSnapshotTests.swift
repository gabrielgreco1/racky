import RackyDesignSystem
import RackyProtocol
import AppKit
import SnapshotTesting
import SwiftUI
import Testing

@testable import RackyUI

/// Snapshots de T1-12: combobox, painel de menu, tooltip e editor de prompt. Referências em `__Snapshots__/`.
@MainActor
@Suite(.serialized, .offscreenAppKit) struct MenuSnapshotTests {
    func snap<V: View>(_ view: V, size: CGSize, name: String, line: UInt = #line) {
        DSFonts.registerIfNeeded()
        let env = ComponentSnapshotTests.env()
        let root = view
            .environment(\.actionRegistry, env.registry)
            .environment(\.elementStore, env.elements)
            .padding(DS.Space.s4)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(DS.Color.overlayCard)
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        withSnapshotTesting(record: ComponentSnapshotTests.recording) {
            assertSnapshot(of: host, as: .image(precision: 0.98, perceptualPrecision: 0.97), named: name, testName: "menu", line: line)
        }
    }

    private func panel(_ nav: DSMenuNavigator, width: CGFloat = DS.Layout.menuMinWidth, placeholder: String = "Search…") -> some View {
        DSMenuPanelView(navigator: nav, width: width, searchPlaceholder: placeholder, solidSurface: true) { _ in }
    }

    @Test func comboboxStates() {
        snap(
            VStack(alignment: .leading, spacing: DS.Space.s3) {
                DSComboboxField(icon: .symbol("folder"), title: "otter", detail: "~/Racky/worktrees/otter")
                DSComboboxField(icon: .agent(.claude), title: "Claude Code", open: true)
                DSComboboxField(title: "Claude · Skip permissions", focused: true)
                DSComboboxField(icon: .agent(.codex), title: "Codex").disabled(true)
                DSComboboxField(icon: .symbol("folder"), title: "otter", height: DSMetrics.fieldHeight)
            }.frame(width: 320), size: CGSize(width: 360, height: 260), name: "comboboxStates")
    }

    @Test func comboboxOpenWithAgentIcons() {
        let nav = DSMenuNavigator(entries: OverlayHostTests.PopoverTests.agents, selectedID: "claude")
        snap(
            VStack(alignment: .leading, spacing: DS.Space.s1) {
                DSComboboxField(icon: .agent(.claude), title: "Claude Code", open: true)
                panel(nav, width: 320)
            }.frame(width: 320), size: CGSize(width: 360, height: 280), name: "comboboxOpen")
    }

    @Test func comboboxSearchFiltersAndKeepsPinnedItem() {
        let agents = ["Claude Code", "Codex", "OpenCode", "Gemini", "Aider", "Goose", "Amp", "Cursor"].map {
            DSMenuEntry.item(DSMenuItem($0, $0, icon: .symbol("terminal")))
        } + [.separator("p"), .item(DSMenuItem("manage", "Manage Agents…", icon: .symbol("gearshape"), pinned: true))]
        let nav = DSMenuNavigator(entries: agents, searchable: DSMenuNavigator.shouldSearch(itemCount: 8))
        nav.type("co")
        snap(panel(nav, width: 300, placeholder: "Search agents…").frame(width: 300), size: CGSize(width: 340, height: 240), name: "comboboxSearch")
    }

    @Test func menuPanelWithShortcutsSeparatorsAndStates() {
        let nav = DSMenuNavigator(entries: [
            .header("Session"),
            .item(DSMenuItem("rename", "Rename", icon: .symbol("pencil"), shortcut: "⌥⌘R")),
            .item(DSMenuItem("copy", "Copy Path", icon: .symbol("doc.on.doc"), shortcut: "⇧⌘C")),
            .item(DSMenuItem("open", "Open in…", icon: .symbol("arrow.up.forward.app"), submenu: [.item(DSMenuItem("a", "Cursor"))])),
            .item(DSMenuItem("pr", "Open Pull Request", icon: .symbol("arrow.triangle.pull"), disabledReason: "No pull request for this branch")),
            .separator("danger"),
            .item(DSMenuItem("archive", "Archive", icon: .symbol("archivebox"), checked: true)),
            .item(DSMenuItem("delete", "Delete…", icon: .symbol("trash"), shortcut: "⇧⌘⌫", destructive: true)),
        ])
        _ = nav.handle(.down)
        _ = nav.handle(.down)
        snap(panel(nav, width: 240).frame(width: 240), size: CGSize(width: 280, height: 290), name: "menuPanel")
    }

    @Test func menuPanelWithOpenSubmenu() {
        let sub: [DSMenuEntry] = [.item(DSMenuItem("c1", "Cursor")), .item(DSMenuItem("c2", "VS Code")), .item(DSMenuItem("c3", "Zed"))]
        let nav = DSMenuNavigator(entries: [
            .item(DSMenuItem("start", "Start Claude Code")),
            .item(DSMenuItem("computer", "Open Computer…", submenu: sub)),
            .item(DSMenuItem("settings", "Agent Settings…")),
        ])
        _ = nav.handle(.down)
        _ = nav.handle(.right)
        snap(panel(nav, width: 200).frame(width: 200), size: CGSize(width: 440, height: 180), name: "menuSubmenu")
    }

    @Test func tooltips() {
        snap(
            VStack(alignment: .leading, spacing: DS.Space.s4) {
                TooltipBubble(content: TooltipContent("Split Right", shortcut: "⌘D"), side: .bottom)
                TooltipBubble(content: TooltipContent("Settings"), side: .top)
                TooltipBubble(content: TooltipContent("Close"), side: .bottom, arrowOffset: 12)
                TooltipBubble(content: TooltipContent("Claude Code is using this computer. Take over to interact, or wait until the agent finishes its current step."), side: .bottom)
            }.padding(DS.Space.s4), size: CGSize(width: 360, height: 260), name: "tooltips")
    }

    @Test func promptEditorStates() {
        final class Holder { var empty = ""; var filled = "Fix the search pagination: the last page is dropped when resultOffset lands on a multiple of maxRecordCount." }
        let h = Holder()
        snap(
            VStack(alignment: .leading, spacing: DS.Space.s3) {
                DSPromptEditorField(text: Binding(get: { h.empty }, set: { h.empty = $0 }), placeholder: "What should the agent do? (optional)")
                DSPromptEditorField(text: Binding(get: { h.filled }, set: { h.filled = $0 }), placeholder: "Describe the task")
            }.frame(width: 440), size: CGSize(width: 480, height: 260), name: "promptEditor")
    }

    @Test func keyHintsInButtons() {
        snap(
            HStack(spacing: DS.Space.s2) {
                DSButton(.composerCancel, "Cancel", variant: .outline, size: .compact, keycap: "esc")
                DSButton(.composerSubmit, "Create Session", variant: .primary, size: .compact, keycap: "⌘↵")
            }, size: CGSize(width: 320, height: 64), name: "keyHints")
    }

    @Test func fullWidthSegmentedAndCompactSwitch() {
        snap(
            VStack(alignment: .leading, spacing: DS.Space.s3) {
                DSSegmented(
                    [.init("a", "New Worktree"), .init("b", "Existing Worktree"), .init("c", "Main Checkout")], selection: "a",
                    action: .composerSetWhere, id: .overlayComposerWhere, fillWidth: true, height: DSMetrics.segmentedHeightComposer)
                DSSwitch(isOn: false, action: .composerCreateMore, id: .overlayComposerCreateMore, "Create More", compact: true)
                DSSwitch(isOn: true, action: .composerCreateMore, id: .overlayComposerCreateMore, "Create More", compact: true)
            }.frame(width: 440), size: CGSize(width: 480, height: 140), name: "segmentedFull")
    }
}
