import RackyDesignSystem
import RackyProtocol
import AppKit
import SnapshotTesting
import SwiftUI
import Testing

@testable import RackyUI

/// Snapshots da sidebar com fixtures (T1-13): 3 projetos com sessões em vários estados, nomes longos (`F-LONG`), vazio e
/// busca sem resultado. Referências em `__Snapshots__/`; gravar com `RACKY_RECORD_SNAPSHOTS=1`.
@MainActor
@Suite(.serialized, .offscreenAppKit) struct SidebarSnapshotTests {
    static let now = Date(timeIntervalSince1970: 1_900_000_000)

    func snap(
        _ name: String, cast: SidebarFixtures.Cast?, slice: String = "1", size: CGSize = CGSize(width: 280, height: 900),
        edit: (SidebarModel) -> Void = { _ in }, line: UInt = #line
    ) {
        DSFonts.registerIfNeeded()
        let previous = MotionPolicy.shared.preference
        MotionPolicy.shared.preference = .on
        defer { MotionPolicy.shared.preference = previous }
        let env = AppEnvironment(environment: ["RACKY_SLICE": slice, "RACKY_SCREEN": SidebarFixtures.screenID])
        env.sidebar.clock = { Self.now }
        if let cast {
            env.sidebar.apply(cast.snapshot)
            if let s = cast.selectedSessionID { env.sidebar.select(s) }
        }
        edit(env.sidebar)
        let root = SidebarView(model: env.sidebar)
            .environment(\.actionRegistry, env.registry)
            .environment(\.elementStore, env.elements)
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        withSnapshotTesting(record: ComponentSnapshotTests.recording) {
            assertSnapshot(of: host, as: .image(precision: 0.98, perceptualPrecision: 0.97), named: name, testName: "sidebar", line: line)
        }
    }

    @Test func threeProjectsSelectedAndPending() {
        let cast = SidebarFixtures.full(now: Self.now)
        snap("threeProjects", cast: cast) { model in
            model.beginPending(
                PendingLaunch(
                    id: UUID(uuid: (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16)), name: "Add retry logic",
                    projectID: cast.pendingProjectID, phase: .fetching))
        }
    }

    @Test func longNamesAndShowMoreOpen() {
        let cast = SidebarFixtures.full(now: Self.now)
        snap("longNamesShowMoreOpen", cast: cast) { model in model.showMore(cast.projects[0].id) }
    }

    @Test func collapsedProjectAndEmptyProject() {
        let cast = SidebarFixtures.full(now: Self.now)
        snap("collapsedAndEmptyProject", cast: cast, size: CGSize(width: 280, height: 480)) { model in
            model.setProject(cast.projects[0].id, collapsed: true)
        }
    }

    @Test func emptyWorkspace() {
        snap("empty", cast: nil, size: CGSize(width: 280, height: 480))
    }

    @Test func emptyWorkspaceMinimumWidth() {
        snap("emptyNarrow", cast: nil, size: CGSize(width: 220, height: 480))
    }

    @Test func fullStructureWithSearchAndNav() {
        snap("fullStructure", cast: SidebarFixtures.full(now: Self.now), slice: "4")
    }

    @Test func searchFiltersAndHighlights() {
        snap("searchHighlight", cast: SidebarFixtures.full(now: Self.now), slice: "2", size: CGSize(width: 280, height: 480)) { $0.query = "arizona" }
    }

    @Test func searchWithoutResults() {
        snap("searchNoResults", cast: SidebarFixtures.full(now: Self.now), slice: "2", size: CGSize(width: 280, height: 480)) { $0.query = "zzz" }
    }

    @Test func renamingInline() {
        let cast = SidebarFixtures.full(now: Self.now)
        snap("renaming", cast: cast, size: CGSize(width: 280, height: 480)) { model in
            let id = cast.sessions.first { $0.title == "main" }!.id
            _ = model.beginRename(id)
        }
    }

    @Test func renamingProjectInline() {
        let cast = SidebarFixtures.full(now: Self.now)
        snap("renamingProject", cast: cast, size: CGSize(width: 280, height: 480)) { model in
            _ = model.beginRenameProject(cast.projects[0].id)
        }
    }
}
