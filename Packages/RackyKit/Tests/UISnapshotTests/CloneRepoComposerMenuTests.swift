import RackyDesignSystem
import RackyProtocol
import RackyStore
import AppKit
import SnapshotTesting
import SwiftUI
import Testing

@testable import RackyUI

/// Item `Clone from GitHub…` no combobox Project do composer (F24), ao lado de `Add a New Project…`.
@MainActor
@Suite(.serialized, .offscreenAppKit) struct CloneRepoComposerMenuTests {
    @Test func projectComboboxOffersCloneFromGitHubNextToAddANewProject() {
        DSFonts.registerIfNeeded()
        let env = ComponentSnapshotTests.env()
        try? env.registry.register(.projectCloneFromGitHub) { _ in nil }
        let project = Project(name: "acme-platform", kind: .git, rootPath: "/Users/me/Racky/projects/acme-platform", defaultBranch: "main")
        env.sidebar.apply(StoreSnapshot(projects: [project]))
        let model = ComposerModel(sidebar: env.sidebar, settings: env.settings, initial: ComposerPersistedState(), preferredProject: project.id)
        let entries = DSMenuPanel.resolve(model.projectEntries, registry: env.registry)
        #expect(entries.compactMap(\.item).map(\.id).suffix(2) == ["add", "clone"])
        let navigator = DSMenuNavigator(entries: entries, searchable: false, selectedID: project.id.uuidString)
        let size = CGSize(width: 360, height: 220)
        let root = DSMenuPanelView(navigator: navigator, width: 328, searchPlaceholder: "Search projects…", solidSurface: true) { _ in }
            .padding(DS.Space.s4)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(DS.Color.overlayCard)
            .environment(\.actionRegistry, env.registry)
            .environment(\.elementStore, env.elements)
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        withSnapshotTesting(record: ComponentSnapshotTests.recording) {
            assertSnapshot(of: host, as: .image(precision: 0.98, perceptualPrecision: 0.97), named: "composerProjectMenu", testName: "clone")
        }
    }
}
