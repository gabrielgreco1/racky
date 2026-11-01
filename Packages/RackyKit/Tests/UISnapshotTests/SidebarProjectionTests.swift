import RackyCore
import RackyDesignSystem
import RackyProtocol
import RackyStore
import Foundation
import Testing

@testable import RackyUI

/// Regras puras da sidebar (03 §2): filtro, busca, ordem, `Show more`, agregação de estado, estados vazios e ordem de teclado.
@MainActor
@Suite(.offscreenAppKit) struct SidebarProjectionTests {
    static let now = Date(timeIntervalSince1970: 1_900_000_000)
    static let home = "/Users/test"

    func input(_ cast: SidebarFixtures.Cast, _ edit: (inout SidebarInput) -> Void = { _ in }) -> SidebarInput {
        var i = SidebarInput(snapshot: cast.snapshot, now: Self.now, home: Self.home)
        i.selectedSession = cast.selectedSessionID
        edit(&i)
        return i
    }

    static let cast = SidebarFixtures.full(now: now, home: home)
    func full() -> SidebarFixtures.Cast { Self.cast }

    @Test func fixtureHasThreeProjectsAndCleanSessionsInRecentOrder() {
        let p = SidebarProjector.build(input(full()))
        #expect(p.projects.map(\.name) == ["otter", "acme-motion", "racky"], "projetos por atividade recente; o vazio por último")
        #expect(p.cleanSessions.map(\.title) == ["quiet-harbor", "swift-otter"])
    }

    @Test func projectShowsFiveSessionsThenShowMore() {
        let p = SidebarProjector.build(input(full()))
        let motion = p.projects.first { $0.name == "acme-motion" }!
        #expect(motion.sessions.count == 5)
        #expect(motion.hiddenCount == 2)
        #expect(motion.sessionCount == 7)
        let opened = SidebarProjector.build(input(full()) { $0.showMoreOpen = [motion.id] }).projects.first { $0.id == motion.id }!
        #expect(opened.sessions.count == 7 && opened.hiddenCount == 0 && opened.showMoreExpanded)
    }

    @Test func sessionsAreOrderedByRecentActivityAndByName() {
        let recent = SidebarProjector.build(input(full())).projects.first { $0.name == "acme-motion" }!
        #expect(recent.sessions.first?.title == "main")
        let byName = SidebarProjector.build(input(full()) { $0.sort = .name }).projects.map(\.name)
        #expect(byName == ["acme-motion", "otter", "racky"])
    }

    @Test func cardTextAndBadges() {
        let p = SidebarProjector.build(input(full()) { $0.showMoreOpen = Set($0.snapshot.projects.map(\.id)) })
        let motion = p.projects.first { $0.name == "acme-motion" }!
        let main = motion.sessions.first { $0.title == "main" }!
        #expect(main.badges == [.main])
        #expect(main.line2 == .branch("main"))
        #expect(main.timeText == "2m")
        #expect(main.glyph == .unknown, "sem hooks, agente vivo = Status unavailable")
        #expect(motion.sessions.first { $0.title.hasPrefix("Arizona") }?.timeText == "5d")
        let detached = p.projects.first { $0.name == "otter" }!.sessions.first { $0.title == "Detached HEAD check" }!
        #expect(detached.badges == [.detached])
        let imported = motion.sessions.first { $0.title == "imported-chore" }!
        #expect(imported.notStarted)
        #expect(imported.glyph == .none)
        let clean = p.cleanSessions.first!
        #expect(clean.line2 == .folder("~/Racky/sessions/quiet-harbor"))
    }

    @Test func relativeTimeBuckets() {
        let n = Self.now
        #expect(SidebarProjector.relativeTime(since: n.addingTimeInterval(-5), now: n) == "now")
        #expect(SidebarProjector.relativeTime(since: n.addingTimeInterval(-12 * 60), now: n) == "12m")
        #expect(SidebarProjector.relativeTime(since: n.addingTimeInterval(-3 * 3600), now: n) == "3h")
        #expect(SidebarProjector.relativeTime(since: n.addingTimeInterval(-5 * 86400), now: n) == "5d")
        #expect(SidebarProjector.relativeTime(since: nil, now: n) == "")
    }

    @Test func processStateDrivesTheIndicatorWhileAgentActivityIsUnknown() {
        func glyph(_ state: TerminalProcessState, provider: TerminalProvider = .claude, code: Int? = nil) -> DSIndicatorGlyph {
            let t = Terminal(tabID: .v7(), provider: provider, title: "x", cwd: "/", launchSpec: LaunchSpec(provider: provider), state: state, exitCode: code)
            return SidebarProjector.glyph(for: t).glyph
        }
        #expect(glyph(.launching) == .spinner)
        #expect(glyph(.running) == .unknown)
        #expect(glyph(.running, provider: .shell) == .none, "shell puro não tem glifo")
        #expect(glyph(.exited, code: 0) == .dot(DS.ColorSpec.processExited))
        #expect(glyph(.exited, code: 2) == .dot(DS.ColorSpec.agentFailed))
        #expect(glyph(.failedToStart) == .dot(DS.ColorSpec.agentFailed))
        #expect(glyph(.interrupted) == .dot(DS.ColorSpec.agentInterrupted))
        #expect(glyph(.notStarted) == .none)
        // agregação: o pior estado vence (02 §2.6)
        let agg = SidebarProjector.aggregate([(.unknown, "a"), (.dot(DS.ColorSpec.agentFailed), "b"), (.spinner, "c")])
        #expect(agg.glyph == .dot(DS.ColorSpec.agentFailed))
    }

    @Test func manyAgentsCollapseIntoASummaryPill() {
        let p = SidebarProjector.build(input(full()) { $0.showMoreOpen = Set($0.snapshot.projects.map(\.id)) })
        let sandperch = p.projects.flatMap(\.sessions).first { $0.title == "sandperch" }!
        #expect(sandperch.agentRows.count == 5)
        #expect(sandperch.summary != nil && sandperch.summary!.count <= 3, "até 3 grupos de estado")
        #expect(sandperch.summary?.first?.count == 2, "o maior grupo (agente vivo, sem hooks) vem primeiro")
        #expect(!p.items.contains(.agent(session: sandperch.id, terminal: sandperch.agentRows[0].id)), "pílula recolhida esconde as linhas")
        let open = SidebarProjector.build(input(full()) { $0.showMoreOpen = Set($0.snapshot.projects.map(\.id)); $0.expandedSummaries = [sandperch.id] })
        #expect(open.items.contains(.agent(session: sandperch.id, terminal: sandperch.agentRows[0].id)))
    }

    @Test func idleShellsGroupUnderAnAgentSession() {
        let p = SidebarProjector.build(input(full()))
        let long = p.projects.flatMap(\.sessions).first { $0.title.hasPrefix("shop") }!
        #expect(long.title.count > 60, "F-LONG: nome longo")
        // um agente + shell ocioso (agrupado) + shell rodando comando (título OSC, vira linha)
        #expect(long.agentRows.count == 2)
        #expect(long.groupedTerminals == 1)
    }

    @Test func idleOverAWeekAndArchivedAreHiddenByDefault() {
        var cast = full()
        let old = Session(kind: .clean, folderPath: "\(Self.home)/Racky/sessions/old", title: "old-one", createdAt: Self.now.addingTimeInterval(-10 * 86400), lastActiveAt: Self.now.addingTimeInterval(-9 * 86400))
        var archived = Session(kind: .clean, folderPath: "\(Self.home)/Racky/sessions/arch", title: "archived-one", createdAt: Self.now, lastActiveAt: Self.now)
        archived.lifecycle = .archived
        archived.archivedAt = Self.now
        cast.sessions += [old, archived]
        #expect(!SidebarProjector.build(input(cast)).cleanSessions.contains { $0.title == "old-one" })
        #expect(!SidebarProjector.build(input(cast)).cleanSessions.contains { $0.title == "archived-one" })
        var f = SidebarFilters()
        f.idleOverWeek = true
        f.archived = true
        let shown = SidebarProjector.build(input(cast) { $0.filters = f }).cleanSessions.map(\.title)
        #expect(shown.contains("old-one") && shown.contains("archived-one"))
    }

    @Test func mainCheckoutsFilterAndSelectedSessionStaysVisible() {
        var f = SidebarFilters()
        f.mainCheckouts = false
        let hidden = SidebarProjector.build(input(full()) { $0.filters = f; $0.selectedSession = nil })
        #expect(!hidden.projects.flatMap(\.sessions).contains { $0.title == "main" })
        let kept = SidebarProjector.build(input(full()) { $0.filters = f })
        #expect(kept.projects.flatMap(\.sessions).contains { $0.title == "main" }, "a sessão selecionada nunca some por filtro")
    }

    @Test func hiddenProjectsAreRemovedUnlessShown() {
        let cast = full()
        let id = cast.projects[1].id
        #expect(!SidebarProjector.build(input(cast) { $0.hiddenProjects = [id] }).projects.contains { $0.id == id })
        var f = SidebarFilters()
        f.hiddenProjects = true
        #expect(SidebarProjector.build(input(cast) { $0.hiddenProjects = [id]; $0.filters = f }).projects.contains { $0.id == id })
    }

    @Test func collapsedProjectKeepsItsCountAndDropsItsRowsFromKeyboardOrder() {
        let cast = full()
        let pid = cast.projects[0].id
        let p = SidebarProjector.build(input(cast) { $0.collapsedProjects = [pid] })
        let section = p.projects.first { $0.id == pid }!
        #expect(section.collapsed && section.sessionCount == 7)
        #expect(p.items.contains(.project(pid)))
        #expect(!p.items.contains { if case .session(let s) = $0 { section.sessions.contains { $0.id == s } } else { false } })
    }

    // MARK: Busca (03 §2.2)

    @Test func searchMatchesNameBranchFolderAndProjectAtItemLevel() {
        func titles(_ q: String) -> [String] {
            let p = SidebarProjector.build(input(full()) { $0.query = q })
            return (p.projects.flatMap(\.sessions) + p.cleanSessions).map(\.title)
        }
        #expect(titles("arizona") == ["Arizona context recap"])
        #expect(titles("fix/pagination") == ["Fix pagination"], "casa pela branch")
        #expect(titles("quiet") == ["quiet-harbor"], "casa pela pasta/nome")
        #expect(titles("ÓTTER").count >= 2, "projeto casa -> todas as sessões; sem acento e sem caixa")
        #expect(titles("zzzz").isEmpty)
    }

    @Test func searchMatchesTerminalsAndShowsOnlyThemInTheCard() {
        let p = SidebarProjector.build(input(full()) { $0.query = "port motion shadows" })
        let card = p.projects.flatMap(\.sessions).first { $0.title == "sandperch" }
        #expect(card != nil)
        #expect(card?.agentRows.count == 1, "só o terminal que casou")
        #expect(card?.agentRows.first?.lead == "Port motion shadows")
    }

    @Test func searchDropsProjectsAndSectionsWithoutResultsAndReportsEmpty() {
        let p = SidebarProjector.build(input(full()) { $0.query = "arizona" })
        #expect(p.projects.map(\.name) == ["acme-motion"])
        #expect(!p.showSessionsSection)
        let none = SidebarProjector.build(input(full()) { $0.query = "nothing-matches" })
        #expect(none.empty == .searchNoResults)
        #expect(none.projects.isEmpty && none.items.isEmpty)
    }

    @Test func searchIgnoresCollapseAndShowMoreLimit() {
        let cast = full()
        let p = SidebarProjector.build(input(cast) { $0.query = "e"; $0.collapsedProjects = Set(cast.projects.map(\.id)) })
        #expect(p.projects.allSatisfy { !$0.collapsed })
    }

    // MARK: Estados vazios (03 §2.13)

    @Test func emptyWorkspaceProjectWithoutSessionsAndFilteredOut() {
        let empty = SidebarProjector.build(SidebarInput(snapshot: StoreSnapshot(), now: Self.now, home: Self.home))
        #expect(empty.empty == .workspace)
        let cast = full()
        let noSessions = SidebarProjector.build(input(cast)).projects.first { $0.id == cast.emptyProjectID }!
        #expect(noSessions.hasNoSessions)
        var onlyOld = SidebarFixtures.minimal(now: Self.now, home: Self.home)
        onlyOld.sessions[0].lastActiveAt = Self.now.addingTimeInterval(-30 * 86400)
        let filtered = SidebarProjector.build(input(onlyOld) { $0.selectedSession = nil })
        #expect(filtered.empty == .filtersNoResults)
    }

    /// Tudo arquivado (F36): a sidebar mostra o começo ("No projects yet." + oferta de mostrar as arquivadas), não "nenhum
    /// resultado para os filtros".
    @Test func onlyArchivedSessionsShowTheStartNotFiltersEmpty() {
        var cast = SidebarFixtures.minimal(now: Self.now, home: Self.home)
        for i in cast.sessions.indices { cast.sessions[i].lifecycle = .archived; cast.sessions[i].archivedAt = Self.now }
        let live = SidebarProjector.build(input(cast) { $0.selectedSession = nil })
        #expect(live.empty == .none && live.projects.first?.hasNoSessions == true, "projeto ativo aparece oferecendo uma sessão nova")
        for i in cast.projects.indices { cast.projects[i].archivedAt = Self.now }
        let all = SidebarProjector.build(input(cast) { $0.selectedSession = nil })
        #expect(all.empty == .workspace)
        #expect(all.archivedHidden == cast.sessions.filter { $0.projectID == nil }.count, "só as que apareceriam (projeto arquivado não volta)")
    }

    // MARK: Pendentes (03 §2.9)

    @Test func pendingRowsSitOnTopOfTheirProjectAndHideWhileSearching() {
        let cast = full()
        let launch = PendingLaunch(name: "Add retry logic", projectID: cast.pendingProjectID, phase: .creatingWorktree)
        let p = SidebarProjector.build(input(cast) { $0.pending = [launch] })
        let otter = p.projects.first { $0.id == cast.pendingProjectID }!
        #expect(otter.pending.map(\.name) == ["Add retry logic"])
        #expect(otter.pending.first?.phaseText == "Creating worktree…")
        #expect(p.items.firstIndex(of: .pending(launch.id))! == p.items.firstIndex(of: .project(otter.id))! + 1)
        #expect(SidebarProjector.build(input(cast) { $0.pending = [launch]; $0.query = "arizona" }).projects.allSatisfy { $0.pending.isEmpty })
        var failed = launch
        failed.failure = "Couldn't create worktree"
        #expect(failed.phaseText == "Couldn't create worktree")
    }

    // MARK: Ordem visível (teclado, ⌘1…9)

    @Test func sessionOrderFollowsTheVisibleList() {
        let p = SidebarProjector.build(input(full()))
        let titles = p.sessionOrder.compactMap { id in (p.projects.flatMap(\.sessions) + p.cleanSessions).first { $0.id == id }?.title }
        #expect(titles.first == "Fix pagination", "primeiro projeto visível, sessão mais recente")
        #expect(titles.last == "swift-otter")
        let keyboard = p.items
        #expect(keyboard.first == .project(p.projects[0].id))
    }

    @Test func unreadSessionsReadAsUnread() {
        let p = SidebarProjector.build(input(full()) { $0.showMoreOpen = Set($0.snapshot.projects.map(\.id)) })
        let shaq = p.projects.flatMap(\.sessions).first { $0.title == "Shaq ia dias slack" }!
        #expect(shaq.unread)
        #expect(shaq.a11yLabel.contains("Unread"))
        #expect(shaq.a11yLabel.contains("branch shaq-ia-dias-slack"))
    }

    @Test func maximumTwoBadges() {
        var cast = SidebarFixtures.minimal(now: Self.now, home: Self.home)
        cast.worktrees[0].isMain = true
        cast.worktrees[0].branch = "HEAD"
        let card = SidebarProjector.build(input(cast)).projects[0].sessions[0]
        #expect(card.badges == [.main, .detached])
    }
}

/// Workers de app (`agent_spawn`): ficam embaixo do agente que os pediu, com o CLI e o terminal, e não viram linha de agente.
@MainActor
@Suite(.offscreenAppKit) struct SidebarWorkerRowsTests {
    @Test func appWorkersHangUnderTheirParentWithTheirCLI() throws {
        var cast = SidebarFixtures.full(now: SidebarProjectionTests.now, home: SidebarProjectionTests.home)
        let session = try #require(cast.sessions.first { $0.title == "quiet-harbor" })
        let tabs = Set(cast.tabs.filter { $0.sessionID == session.id }.map(\.id))
        let parent = try #require(cast.terminals.first { tabs.contains($0.tabID) && $0.provider == .claude })
        var spec = LaunchSpec(provider: .codex, workerChildID: "01a15eca-a1")
        spec.workerParentTerminalID = parent.id
        let worker = Terminal(
            tabID: parent.tabID, provider: .codex, title: "Codex 1 · Pages 1–4", titleSource: .user, cwd: parent.cwd, launchSpec: spec, state: .running,
            createdAt: SidebarProjectionTests.now, startedAt: SidebarProjectionTests.now)
        cast.terminals.append(worker)
        var input = SidebarInput(snapshot: cast.snapshot, now: SidebarProjectionTests.now, home: SidebarProjectionTests.home)
        input.selectedSession = session.id
        input.workerComputers = [worker.id: "books-p1-4"]
        let own = ComputerChildRow(ComputerRow(
            snapshot: ViewerSnapshot(name: "books-p1-4", state: .inUse, display: "headless", control: .agent, proxy: "direct"), thumbnail: nil,
            sessionTitle: "quiet-harbor", owner: nil, lastActivity: SidebarProjectionTests.now))
        input.computers = [session.id: [own]]
        let card = try #require(SidebarProjector.build(input).cleanSessions.first { $0.id == session.id })
        #expect(card.agentRows.map(\.id) == [parent.id], "the worker is not an agent row")
        #expect(card.computers.isEmpty, "the worker's computer lives on the worker's row, not as a loose computer row")
        #expect(card.groupedTerminals == 0, "nor a hidden \"+N terminals\" one")
        let child = try #require(card.agentRows.first?.children.first { $0.workerTerminalID == worker.id })
        #expect(child.title == "Codex 1" && child.task == "Pages 1–4" && child.worker == .codex && child.phase == .running)
        #expect(child.computer == "books-p1-4")
        // Entregou o resultado e o Codex ficou aberto esperando input: a linha mostra concluído, não rodando.
        input.finishedWorkers = [worker.id]
        let after = try #require(SidebarProjector.build(input).cleanSessions.first { $0.id == session.id })
        #expect(after.agentRows.first?.children.first { $0.workerTerminalID == worker.id }?.phase == .done)
    }
}
