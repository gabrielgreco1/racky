import RackyDesignSystem
import RackyProtocol
import RackyStore
import AppKit
import SnapshotTesting
import SwiftUI
import Testing

@testable import RackyUI

/// Snapshot de cada componente base (T1-11, 02 §12). Referências em `__Snapshots__/`; gravar com `RACKY_RECORD_SNAPSHOTS=1`.
@MainActor
@Suite(.serialized, .offscreenAppKit) struct ComponentSnapshotTests {
    static let recording: SnapshotTestingConfiguration.Record = ProcessInfo.processInfo.environment["RACKY_RECORD_SNAPSHOTS"] == "1" ? .all : .missing

    /// Ambiente com as ações usadas pelos controles registradas (sem efeito), para o `ActionButton` renderizar habilitado.
    static func env() -> AppEnvironment {
        let env = AppEnvironment(environment: [:])
        for id in [ActionID.composerSetProject, .composerSetAgent, .composerSetProfile, .composerSetWhere, .composerCreateMore, .composerCancel, .composerSubmit, .composerSetPrompt, .dialogCloseTerminalConfirm, .dialogCloseTerminalCancel, .dialogCloseTerminalDontAsk, .appCheckProblems, .sessionNew] {
            try? env.registry.register(id) { _ in nil }
        }
        return env
    }

    func snap<V: View>(_ view: V, size: CGSize, name: String, line: UInt = #line) {
        DSFonts.registerIfNeeded()
        let env = Self.env()
        let root = view
            .environment(\.actionRegistry, env.registry)
            .environment(\.elementStore, env.elements)
            .padding(DS.Space.s4)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(DS.Color.chrome)
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        withSnapshotTesting(record: Self.recording) {
            assertSnapshot(of: host, as: .image(precision: 0.98, perceptualPrecision: 0.97), named: name, testName: "component", line: line)
        }
    }

    @Test func buttons() {
        let variants: [DSButtonVariant] = [.primary, .secondary, .outline, .ghost, .destructive, .link]
        let states: [DSInteractionState] = [.rest, .hover, .pressed]
        snap(
            VStack(alignment: .leading, spacing: DS.Space.s3) {
                ForEach(variants, id: \.self) { v in
                    HStack(spacing: DS.Space.s3) {
                        ForEach(states, id: \.self) { st in
                            Button {} label: { Text(verbatim: "Create") }.buttonStyle(DSButtonStyle(v, .sm, forcedState: st))
                        }
                        Button {} label: { Text(verbatim: "Focus") }.buttonStyle(DSButtonStyle(v, .sm, forcedFocus: true))
                        Button {} label: { Text(verbatim: "Disabled") }.buttonStyle(DSButtonStyle(v, .sm)).disabled(true)
                    }
                }
                HStack(spacing: DS.Space.s3) {
                    ForEach(DSButtonSize.allCases, id: \.self) { sz in
                        Button {} label: { Text(verbatim: "Size") }.buttonStyle(DSButtonStyle(.outline, sz))
                    }
                }
            }, size: CGSize(width: 560, height: 360), name: "buttons")
    }

    @Test func iconButtons() {
        snap(
            VStack(alignment: .leading, spacing: DS.Space.s3) {
                ForEach(DSIconButtonVariant.allCases, id: \.self) { v in
                    HStack(spacing: DS.Space.s3) {
                        Button {} label: { Image(systemName: "plus") }.buttonStyle(DSIconButtonStyle(v, forcedState: .rest))
                        Button {} label: { Image(systemName: "plus") }.buttonStyle(DSIconButtonStyle(v, forcedState: .hover))
                        Button {} label: { Image(systemName: "plus") }.buttonStyle(DSIconButtonStyle(v, active: true))
                        Button {} label: { Image(systemName: "trash") }.buttonStyle(DSIconButtonStyle(v, destructive: true))
                        Button {} label: { Image(systemName: "plus") }.buttonStyle(DSIconButtonStyle(v)).disabled(true)
                    }
                }
            }, size: CGSize(width: 260, height: 340), name: "iconButtons")
    }

    @Test func badgesAndKeycaps() {
        snap(
            VStack(alignment: .leading, spacing: DS.Space.s3) {
                HStack {
                    DSBadge("Main"); DSBadge("Rename failed", variant: .error); DSBadge("Conflicts", variant: .warning)
                    DSBadge("3", variant: .count); DSBadge("3", variant: .countAttention); DSBadge("New", variant: .pill)
                    DSBadge("--model", variant: .mono)
                }
                HStack { Keycaps("⌘⇧D"); Keycaps("⌘↵"); Keycap("⎋") }
            }, size: CGSize(width: 520, height: 90), name: "badgesAndKeycaps")
    }

    @Test func inputs() {
        struct Fields: View {
            @State var empty = ""
            @State var filled = "quiet-harbor"
            @State var bad = "feature/x"
            var body: some View {
                VStack(alignment: .leading, spacing: DS.Space.s3) {
                    DSTextField("Branch name", text: $empty, id: .overlayComposerCreateFrom)
                    DSTextField("Branch name", text: $filled, id: .overlayComposerName)
                    DSTextField("Branch name", text: $bad, id: .overlayComposerBranch, error: "Branch already exists.")
                    DSTextField("Branch name", text: $filled, id: .overlayComposerLocation).disabled(true)
                    VStack(alignment: .leading) { Text(verbatim: "focus ring") }
                        .dsFieldChrome(focused: true)
                }.frame(width: 360)
            }
        }
        snap(Fields(), size: CGSize(width: 400, height: 320), name: "inputs")
    }

    @Test func segmentedSwitchCheckbox() {
        snap(
            VStack(alignment: .leading, spacing: DS.Space.s4) {
                DSSegmented(
                    [.init("newWorktree", "New Worktree"), .init("existingWorktree", "Existing Worktree"), .init("mainCheckout", "Main Checkout")],
                    selection: "existingWorktree", action: .composerSetWhere, id: .overlayComposerWhere)
                HStack(spacing: DS.Space.s6) {
                    DSSwitchVisual(isOn: false); DSSwitchVisual(isOn: true); DSSwitchVisual(isOn: true, focused: true)
                    DSCheckboxVisual(isOn: false); DSCheckboxVisual(isOn: true); DSCheckboxVisual(isOn: true, focused: true)
                }
                DSSwitch(isOn: true, action: .composerCreateMore, id: .overlayComposerCreateMore, "Create More")
                DSCheckbox(isOn: false, action: .dialogCloseTerminalDontAsk, id: .overlayConfirmCloseDontAsk, "Don't ask again")
            }, size: CGSize(width: 420, height: 200), name: "segmentedSwitchCheckbox")
    }

    @Test func listRows() {
        snap(
            VStack(spacing: DS.Space.s1) {
                Button {} label: { Text(verbatim: "Default row").dsFont(DS.Font.body) }.buttonStyle(DSListRowStyle())
                Button {} label: { Text(verbatim: "Hover row").dsFont(DS.Font.body) }.buttonStyle(DSListRowStyle(forcedState: .hover))
                Button {} label: { Text(verbatim: "Selected row").dsFont(DS.Font.body) }.buttonStyle(DSListRowStyle(selected: true))
                Button {} label: { Text(verbatim: "Disabled row").dsFont(DS.Font.body) }.buttonStyle(DSListRowStyle()).disabled(true)
            }.frame(width: 300), size: CGSize(width: 340, height: 190), name: "listRows")
    }

    @Test func toasts() {
        snap(
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                DSToastCard(kind: .success, title: "Session archived.", timeFraction: 0.6) {
                    Button {} label: { Text(verbatim: "Undo") }.buttonStyle(DSButtonStyle(.ghost, .xs))
                }
                DSToastCard(kind: .error, title: "Couldn't save setting.", detail: "The file is read-only.") {
                    Button {} label: { Text(verbatim: "Copy Details") }.buttonStyle(DSButtonStyle(.ghost, .xs))
                }
                DSToastCard(kind: .info, title: "Copied.")
                DSToastCard(kind: .warning, title: "Not enough room to split. Close a pane or widen the window.")
                DSToastCard(kind: .progress, title: "Preparing computer…")
            }, size: CGSize(width: 400, height: 380), name: "toasts")
    }

    @Test func emptyStates() {
        snap(
            VStack(spacing: DS.Space.s4) {
                DSEmptyState("No sessions match \"phx\".") {
                    Button {} label: { Text(verbatim: "Clear Search") }.buttonStyle(DSButtonStyle(.ghost, .xs))
                }
                DSEmptyState("No computers yet. Agents create them when they need a browser.", page: true)
            }.frame(width: 360), size: CGSize(width: 400, height: 200), name: "emptyStates")
    }

    /// Spinner parado (Reduce Motion): o snapshot não pode depender da fase da animação.
    @Test func spinnersAtRest() {
        snap(
            HStack(spacing: DS.Space.s4) {
                DSSpinner(size: 12, delayed: false, reduceMotion: true)
                DSSpinner(size: 16, delayed: false, reduceMotion: true)
                DSSpinner(kind: .agentWorking, size: 16, delayed: false, reduceMotion: true)
            }, size: CGSize(width: 140, height: 64), name: "spinnersAtRest")
    }

    @Test func confirmationOverlayCard() {
        let model = ConfirmationModel.closeTerminal(message: "Claude Code is still working. Closing ends the process; you can resume the conversation later.")
        snap(
            ConfirmationOverlayContent(model: model)
                .frame(width: DS.Layout.confirmationWidth)
                .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Color.overlayCard))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Color.borderStrong)),
            size: CGSize(width: 490, height: 220), name: "confirmationOverlayCard")
    }

    @Test func composerCard() {
        let env = Self.env()
        let project = Project(name: "acme-platform", kind: .git, rootPath: "/Users/me/Racky/worktrees/acme-platform", defaultBranch: "main")
        env.sidebar.apply(StoreSnapshot(projects: [project]))
        let model = ComposerModel(sidebar: env.sidebar, settings: env.settings, initial: ComposerPersistedState(), preferredProject: project.id)
        model.draft.prompt = "Fix the search pagination: the last page is dropped when resultOffset lands on a multiple of maxRecordCount."
        snap(
            ComposerView(model: model)
                .frame(width: DS.Layout.composerWidth)
                .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Color.overlayCard))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Color.borderStrong)),
            size: CGSize(width: 600, height: 620), name: "composerCard")
    }
}
