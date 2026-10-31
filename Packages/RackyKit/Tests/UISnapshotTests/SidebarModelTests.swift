import RackyProtocol
import RackyStore
import AppKit
import Foundation
import Testing

@testable import RackyUI

/// Modelo, ações e persistência da sidebar ligados ao Store real (banco temporário isolado).
@MainActor
@Suite(.serialized, .offscreenAppKit) struct SidebarModelTests {
    static func tempPaths() throws -> StorePaths {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("racky-sidebar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return StorePaths(root: root)
    }

    /// Ambiente com o Store aberto, o cenário completo gravado e a sidebar observando.
    func make() async throws -> (env: AppEnvironment, store: RackyStore, cast: SidebarFixtures.Cast, paths: StorePaths) {
        let paths = try Self.tempPaths()
        let store = try await RackyStore.open(paths: paths, debounce: .milliseconds(10))
        let cast = SidebarFixtures.full()
        try await SidebarFixtures.seed(cast, into: store)
        let env = AppEnvironment(environment: [:])
        await env.sidebar.attach(store: store)
        for _ in 0..<100 where env.sidebar.snapshot.sessions.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        return (env, store, cast, paths)
    }

    @Test func sidebarObservesTheStore() async throws {
        let (env, store, cast, paths) = try await make()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        #expect(env.sidebar.snapshot.projects.count == 3)
        var extra = Session(kind: .clean, folderPath: NSHomeDirectory() + "/Racky/sessions/new-one", title: "new-one", createdAt: Date(), lastActiveAt: Date())
        extra.managedFolder = true
        try await store.save(extra)
        for _ in 0..<100 where !env.sidebar.snapshot.sessions.contains(where: { $0.id == extra.id }) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(env.sidebar.projection.cleanSessions.contains { $0.title == "new-one" })
        #expect(cast.sessions.count + 1 == env.sidebar.snapshot.sessions.count)
    }

    @Test func selectingASessionThroughTheActionMarksItReadAndPersists() async throws {
        let (env, store, cast, paths) = try await make()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let unread = cast.sessions.first { $0.unread }!
        let result = try await env.registry.perform(.sessionSelect, .select(unread.id.uuidString))
        #expect(result.message == "selected")
        #expect(env.sidebar.selectedSession == unread.id)
        for _ in 0..<100 {
            if try await store.session(id: unread.id)?.unread == false { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try await store.session(id: unread.id)?.unread == false)
        try await store.flush()
        let again = SidebarModel()
        await again.attach(store: store)
        #expect(again.selectedSession == unread.id, "a seleção sobrevive ao reinício")
        again.detach()
        env.sidebar.detach()
    }

    /// F36: a seleção salva aponta para uma sessão que foi arquivada; ao relançar a seleção cai (a landing aparece) em vez de
    /// abrir uma sessão que a sidebar esconde.
    @Test func restoredSelectionOfAnArchivedSessionFallsBackToTheLanding() async throws {
        let (env, store, cast, paths) = try await make()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        var session = cast.sessions.first { $0.archivedAt == nil && $0.lifecycle != .archived }!
        _ = try await env.registry.perform(.sessionSelect, .select(session.id.uuidString))
        session.lifecycle = .archived
        session.archivedAt = Date()
        try await store.save(session)
        try await store.flush()
        env.sidebar.detach()
        let again = SidebarModel()
        await again.attach(store: store)
        for _ in 0..<100 where again.snapshot.sessions.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(again.selectedSession == nil)
        again.detach()
    }

    @Test func selectingAnUnknownSessionFails() async throws {
        let env = AppEnvironment(environment: [:])
        await #expect(throws: ActionError.self) { _ = try await env.registry.perform(.sessionSelect, .select(UUID().uuidString)) }
    }

    @Test func keyboardNavigationActionsFollowTheVisibleOrder() async throws {
        let (env, _, _, paths) = try await make()
        defer { try? FileManager.default.removeItem(at: paths.root); env.sidebar.detach() }
        _ = try await env.registry.perform(.sessionSelect1, .press)
        let first = env.sidebar.projection.sessionOrder[0]
        #expect(env.sidebar.selectedSession == first)
        _ = try await env.registry.perform(.sessionNext, .press)
        #expect(env.sidebar.selectedSession == env.sidebar.projection.sessionOrder[1])
        _ = try await env.registry.perform(.sessionPrevious, .press)
        #expect(env.sidebar.selectedSession == first)
        _ = try await env.registry.perform(.sidebarFocus, .press)
        #expect(env.sidebar.focusListRequest > 0)
    }

    @Test func collapsingAProjectPersistsAndCollapseAllHidesAgentRows() async throws {
        let (env, store, cast, paths) = try await make()
        defer { try? FileManager.default.removeItem(at: paths.root); env.sidebar.detach() }
        let pid = cast.projects[0].id
        let r = try await env.registry.perform(.sidebarProjectToggle, .select(pid.uuidString))
        #expect(r.message == "collapsed")
        var state: SidebarPersistedState?
        for _ in 0..<100 {
            try await store.flush()
            state = try await store.uiState(SidebarModel.uiStateKey, as: SidebarPersistedState.self)
            if state?.collapsedProjects == [pid] { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(state?.collapsedProjects == [pid])
        _ = try await env.registry.perform(.sidebarProjectToggle, .select(pid.uuidString))
        let other = cast.projects[1].id
        _ = try await env.registry.perform(.projectCollapseAll, .select(other.uuidString))
        let card = env.sidebar.projection.projects.first { $0.id == other }!.sessions[0]
        #expect(card.agentsCollapsed)
        _ = try await env.registry.perform(.projectShowMore, .select(pid.uuidString))
        #expect(env.sidebar.projection.projects.first { $0.id == pid }!.hiddenCount == 0)
    }

    @Test func hidingAProjectRemovesItFromTheSidebar() async throws {
        let (env, _, cast, paths) = try await make()
        defer { try? FileManager.default.removeItem(at: paths.root); env.sidebar.detach() }
        _ = try await env.registry.perform(.projectHide, .select(cast.projects[1].id.uuidString))
        #expect(!env.sidebar.projection.projects.contains { $0.id == cast.projects[1].id })
    }

    @Test func openingASessionOfAHiddenProjectShowsTheProjectAgain() async throws {
        let (env, _, cast, paths) = try await make()
        defer { try? FileManager.default.removeItem(at: paths.root); env.sidebar.detach() }
        let project = cast.projects[1].id
        let session = try #require(cast.snapshot.sessions.first { $0.projectID == project })
        _ = try await env.registry.perform(.projectHide, .select(project.uuidString))
        env.sidebar.select(session.id)
        env.sidebar.apply(env.sidebar.snapshot)
        #expect(env.sidebar.projection.projects.contains { $0.id == project })
    }

    // MARK: Renomear (03 §2.11)

    @Test func renameCommitsToTheStoreWithoutTouchingBranchOrFolder() async throws {
        let (env, store, cast, paths) = try await make()
        defer { try? FileManager.default.removeItem(at: paths.root); env.sidebar.detach() }
        let s = cast.sessions.first { $0.title == "sandperch" }!
        _ = try await env.registry.perform(.sessionRename, .select(s.id.uuidString))
        #expect(env.sidebar.renamingSession == s.id)
        _ = try await env.registry.perform(.sessionRename, .set("  better name  "))
        #expect(env.sidebar.renamingSession == nil)
        let saved = try await store.session(id: s.id)
        #expect(saved?.title == "better name")
        #expect(saved?.folderPath == s.folderPath)
        let wt = try await store.worktrees(projectID: s.projectID!).first { $0.id == s.worktreeID }
        #expect(wt?.branch == "sandperch", "renomear a sessão não renomeia a branch")
    }

    @Test func emptyRenameFallsBackToTheAutomaticNameAndEscCancels() async throws {
        let (env, store, cast, paths) = try await make()
        defer { try? FileManager.default.removeItem(at: paths.root); env.sidebar.detach() }
        let s = cast.sessions.first { $0.title == "Shaq ia dias slack" }!
        _ = try await env.registry.perform(.sessionRename, .select(s.id.uuidString))
        _ = try await env.registry.perform(.sessionRename, .set(""))
        #expect(try await store.session(id: s.id)?.title == "shaq-ia-dias-slack", "vazio volta ao nome automático (branch)")
        _ = try await env.registry.perform(.sessionRename, .select(s.id.uuidString))
        env.sidebar.cancelRename()
        #expect(env.sidebar.renamingSession == nil)
        #expect(try await store.session(id: s.id)?.title == "shaq-ia-dias-slack")
    }

    @Test func renamingTheSelectedSessionWithoutArgumentWorksAndFailsWithoutSelection() async throws {
        let env = AppEnvironment(environment: [:])
        await #expect(throws: ActionError.self) { _ = try await env.registry.perform(.sessionRename, .press) }
        let cast = SidebarFixtures.minimal()
        env.sidebar.apply(cast.snapshot)
        env.sidebar.select(cast.sessions[0].id)
        _ = try await env.registry.perform(.sessionRename, .press)
        #expect(env.sidebar.renamingSession == cast.sessions[0].id)
    }

    // MARK: Pendentes

    @Test func pendingLifecycleAndCancel() async throws {
        let env = AppEnvironment(environment: [:])
        var cancelled: UUID?
        env.sidebar.onCancelPending = { cancelled = $0 }
        let launch = PendingLaunch(name: "x", projectID: nil)
        env.sidebar.beginPending(launch)
        env.sidebar.advance(pending: launch.id, to: .fetching)
        #expect(env.sidebar.projection.cleanPending.first?.phaseText == "Fetching origin…")
        env.sidebar.fail(pending: launch.id, message: "Couldn't create worktree")
        #expect(env.sidebar.projection.cleanPending.first?.failed == true)
        env.sidebar.advance(pending: launch.id, to: .creatingWorktree)
        _ = try await env.registry.perform(.sessionCancelLaunch, .select(launch.id.uuidString))
        #expect(cancelled == launch.id)
        #expect(env.sidebar.pending.isEmpty)
        await #expect(throws: ActionError.self) { _ = try await env.registry.perform(.sessionCancelLaunch, .select(launch.id.uuidString)) }
    }

    // MARK: Filtros e busca

    @Test func sortAndFilterActionsChangeTheProjection() async throws {
        let env = AppEnvironment(environment: [:])
        env.sidebar.apply(SidebarFixtures.full().snapshot)
        _ = try await env.registry.perform(.sidebarSortFilter, .select("sort:name"))
        #expect(env.sidebar.sort == .name)
        _ = try await env.registry.perform(.sidebarSortFilter, .set("hiddenProjects=on"))
        #expect(env.sidebar.filters.hiddenProjects)
        _ = try await env.registry.perform(.sidebarResetFilters, .press)
        #expect(env.sidebar.sort == .recent && env.sidebar.filters.isDefault)
        let open = try await env.registry.perform(.sidebarSortFilter, .press)
        #expect(open.message == "opened" && env.sidebar.filterMenuOpen)
    }

    @Test func searchAndNavItemsDoNotRenderInSliceOneButDoFromSliceTwoOrFour() async throws {
        let slice1 = AppEnvironment(environment: ["RACKY_SLICE": "1"])
        let host1 = await EmptyWindowTreeTests.host(slice1, size: NSSize(width: 1440, height: 900))
        defer { host1.window?.close() }
        let t1 = await slice1.registry.uiTree(root: nil)
        #expect(t1.find(.sidebarSearch) == nil)
        #expect(t1.find(.sidebarNavSessions) == nil && t1.find(.sidebarNavComputers) == nil && t1.find(.sidebarNavLibrary) == nil)
        #expect(t1.find(.sidebar) != nil)

        let all = AppEnvironment(environment: ["RACKY_SLICE": "4", "RACKY_SCREEN": SidebarFixtures.screenID])
        let host4 = await EmptyWindowTreeTests.host(all, size: NSSize(width: 1440, height: 900))
        defer { host4.window?.close() }
        try await Task.sleep(for: .milliseconds(200))
        let t4 = await all.registry.uiTree(root: nil)
        for id in [A11yID.sidebarSearch, .sidebarNavSessions, .sidebarNavComputers, .sidebarNavLibrary] { #expect(t4.find(id) != nil, "\(id.rawValue)") }
    }

    @Test func systemActionsCopyPathBranchAndReveal() async throws {
        let model = SidebarModel()
        let cast = SidebarFixtures.full()
        model.apply(cast.snapshot)
        let env = AppEnvironment(environment: [:])
        let registry = ActionRegistry(flags: env.flags, surface: WindowAutomation(store: UIElementStore(), flags: env.flags, fixture: nil, automationEnabled: false))
        var copied: [String] = []
        var revealed: [URL] = []
        try model.registerActions(in: registry, system: SidebarSystemActions(copy: { copied.append($0) }, reveal: { revealed.append($0) }))
        let s = cast.sessions.first { $0.title == "sandperch" }!
        _ = try await registry.perform(.itemCopyPath, .select(s.id.uuidString))
        _ = try await registry.perform(.sessionCopyBranch, .select(s.id.uuidString))
        _ = try await registry.perform(.itemCopyId, .select(s.id.uuidString))
        _ = try await registry.perform(.itemRevealInFinder, .select(cast.projects[0].id.uuidString))
        #expect(copied == [s.folderPath, "sandperch", s.id.uuidString])
        #expect(revealed == [URL(fileURLWithPath: cast.projects[0].rootPath)])
        let clean = cast.sessions.first { $0.kind == .clean }!
        await #expect(throws: ActionError.self) { _ = try await registry.perform(.sessionCopyBranch, .select(clean.id.uuidString)) }
    }

    @Test func actionsWithoutAnOwnerAreNotOffered() {
        let env = AppEnvironment(environment: [:])
        #expect(env.registry.isOffered(.sessionArchive), "arquivar e apagar sessão limpa são de T1-17")
        #expect(env.registry.isOffered(.sessionNewClean), "New Clean Session é de T1-17")
        #expect(env.registry.isOffered(.projectAdd), "adicionar projeto é de T1-19")
        #expect(env.registry.isOffered(.projectNewSession), "composer é de T1-20")
        #expect(env.registry.isOffered(.sessionEditNote), "a nota da sessão é de T2-05")
        #expect(!env.registry.isOffered(.libraryNewAgent), "fatia futura")
        #expect(env.registry.isOffered(.sessionRename))
    }

    @Test func revealCurrentNeedsASelection() async throws {
        let env = AppEnvironment(environment: [:])
        await #expect(throws: ActionError.self) { _ = try await env.registry.perform(.sidebarRevealCurrent, .press) }
        let cast = SidebarFixtures.full()
        env.sidebar.apply(cast.snapshot)
        let hidden = cast.sessions.first { $0.title.hasPrefix("Arizona") }!
        env.sidebar.select(hidden.id)
        _ = try await env.registry.perform(.sidebarRevealCurrent, .press)
        #expect(env.sidebar.reveal?.id == hidden.id)
        #expect(env.sidebar.projection.sessionOrder.contains(hidden.id), "revelar abre o `Show more` que escondia o card")
    }
}
