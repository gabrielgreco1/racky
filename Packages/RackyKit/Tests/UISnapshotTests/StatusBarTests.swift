import RackyCore
import RackyDesignSystem
import RackyProtocol
import AppKit
import Foundation
import SnapshotTesting
import SwiftUI
import Testing

@testable import RackyUI

// T4-01 (AC-1001…1004): a status bar lê o Insights e os computadores; nada estimado, segmento sem dado não aparece.

private let noon = InsightsPreviewData.now

private func utc() -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC") ?? .current
    return c
}

private func snapshot(claude: (Double, Double)? = (0.62, 0.31), codex: Double? = nil) -> InsightsSnapshot {
    var s = InsightsSnapshot.empty
    if let claude {
        s.claude = InsightsPreviewData.provider(.claude, level: claude.0, weekly: claude.1)
    }
    if let codex {
        var p = InsightsPreviewData.provider(.codex, level: codex, weekly: 0.2)
        p.sevenDay = nil
        s.codex = p
    }
    return s
}

private func row(_ name: String, _ state: BoxState = .inUse, proxy: String = "zyte-us", session: String? = "Austin listings") -> ComputerRow {
    ComputerRow(snapshot: ViewerSnapshot(name: name, state: state, display: "headless", control: .agent, proxy: proxy), sessionTitle: session)
}

private func usage(_ name: String, memory: Int64, cpu: Double = 4) -> ComputerUsage {
    ComputerUsage(id: name, name: name, state: "running", cpuPercent: cpu, memoryBytes: memory, memoryLimitBytes: 4 << 30, pids: 20, sessionID: nil)
}

struct StatusBarContentTests {
    @Test func claudeWindowsReadLikeTheSpec() throws {
        let content = StatusBarContent.make(snapshot: snapshot(), rows: [], now: noon, calendar: utc())
        let claude = try #require(content.claude)
        #expect(claude.text == "5h 67% · 7d 88%".replacingOccurrences(of: "67", with: "62").replacingOccurrences(of: "88", with: "31"))
        #expect(claude.level == .normal)
        #expect(claude.source == "From Claude Code statusline")
        #expect(content.codex == nil, "sem Codex instalado o segmento não aparece")
    }

    @Test func levelsFollowTheThresholds() throws {
        func level(_ f: Double) -> StatusBarLevel { StatusBarLevel(fraction: f) }
        #expect(level(0.79) == .normal && level(0.80) == .warning && level(0.94) == .warning && level(0.95) == .destructive && level(1.0) == .destructive)
        let hot = StatusBarContent.make(snapshot: snapshot(claude: (0.82, 0.97)), rows: [], now: noon)
        #expect(try #require(hot.claude).level == .destructive)
    }

    /// AC-1002: o rollout do Codex com `used_percent = 100` vira `5h 100%` em vermelho, com `Resets at …` no popover.
    @Test func codexAtOneHundredPercentIsRedWithAResetTime() throws {
        let content = StatusBarContent.make(snapshot: snapshot(claude: nil, codex: 1.0), rows: [], now: noon, calendar: utc())
        let codex = try #require(content.codex)
        #expect(codex.text == "5h 100%" && codex.level == .destructive)
        #expect(codex.source == "From Codex session logs")
        let reset = try #require(codex.windows.first?.resetsAt)
        #expect(StatusBarContent.resetText(reset, now: noon, calendar: utc()) == "Resets at 1:54 PM")
        #expect(content.claude == nil)
    }

    @Test func resetTextNamesTheDayWhenItIsNotToday() {
        let cal = utc()
        let monday = noon.addingTimeInterval(2 * 86_400 + 4 * 3600)
        #expect(StatusBarContent.resetText(monday, now: noon, calendar: cal) == "Resets Mon 4:00 PM")
    }

    @Test func windowsWithoutAnExactNumberOrAlreadyOverAreLeftOut() {
        var s = snapshot()
        s.claude.fiveHour?.source = .unavailable
        s.claude.sevenDay?.resetsAt = noon.addingTimeInterval(-60)
        #expect(StatusBarContent.make(snapshot: s, rows: [], now: noon).claude == nil, "nenhum número exato: nada de estimativa")
    }

    /// AC-1003: contagem, RAM somada e uma linha por computador com sessão, estado, modo, proxy, CPU e RAM.
    @Test func computersShowCountMemoryAndOneLineEach() throws {
        var s = snapshot()
        s.computers = [usage("phoenix-az", memory: 2_500_000_000), usage("austin-tx", memory: 2_000_000_000, cpu: 12), usage("dallas-tx", memory: 2_000_000_000)]
        let rows = [row("phoenix-az"), row("austin-tx"), row("dallas-tx", .ready), row("el-paso-tx", .stopped), row("reno-nv", .queued)]
        let computers = try #require(StatusBarContent.make(snapshot: s, rows: rows, now: noon).computers)
        #expect(computers.active == 3 && computers.queued == 1)
        #expect(computers.text == "3 computers · 1 queued · 6.1 GB")
        let line = try #require(computers.lines.first { $0.name == "austin-tx" })
        #expect(line.session == "Austin listings" && line.state == "In use" && line.mode == "headless" && line.proxy == "zyte-us")
        #expect(line.memoryBytes == 2_000_000_000 && line.cpuPercent == 12)
    }

    @Test func oneComputerIsSingularAndMemoryIsOmittedWithoutSamples() throws {
        let computers = try #require(StatusBarContent.make(snapshot: snapshot(), rows: [row("a")], now: noon).computers)
        #expect(computers.text == "1 computer")
        #expect(StatusBarContent.make(snapshot: snapshot(), rows: [row("a", .stopped)], now: noon).computers == nil)
    }

    /// AC-1004: soma o que os provedores informam hoje; o proxy que não informa é `Usage unavailable`, sem estimativa.
    @Test func proxyUsageSumsOnlyWhatTheProviderReports() throws {
        let cal = utc()
        let today = cal.startOfDay(for: noon)
        func summary(_ name: String, micros: Int64, reports: Bool) -> ProxyUsageSummary {
            ProxyUsageSummary(
                id: name, name: name, isDefault: false, requests: 40, bytes: 0, costMicros: micros,
                daily: [ProxyDay(dayStart: today, requests: 40, bytes: 0, costMicros: micros)], reportsCost: reports)
        }
        var s = snapshot()
        s.proxies = [summary("zyte-us", micros: 300_000, reports: true), summary("zyte-eu", micros: 120_000, reports: true), summary("homebrew", micros: 0, reports: false)]
        let content = StatusBarContent.make(snapshot: s, rows: [row("a", proxy: "zyte-us"), row("b", proxy: "homebrew")], now: noon, calendar: cal)
        let proxy = try #require(content.proxy)
        #expect(proxy.todayMicros == 420_000 && proxy.text == "Proxy $0.42 today")
        #expect(proxy.lines.first { $0.name == "homebrew" }?.todayMicros == nil)
        #expect(content.computers?.lines.first { $0.name == "a" }?.proxyUsage == "$0.30")
        #expect(content.computers?.lines.first { $0.name == "b" }?.proxyUsage == nil)
        #expect(content.computers?.lines.first { $0.name == "b" }?.proxyUsageUnavailable == true)
        #expect(content.computers?.lines.first { $0.name == "a" }?.proxyUsageUnavailable == false)
        s.proxies = [summary("homebrew", micros: 0, reports: false)]
        #expect(StatusBarContent.make(snapshot: s, rows: [], now: noon, calendar: cal).proxy == nil, "nenhum proxy informa uso: o segmento some")
    }

    @Test func claudeUsageSourceNamesTheExactEndpointWhenLive() {
        var s = snapshot()
        s.claudeLimits = .live(fetchedAt: noon)
        #expect(StatusBarContent.make(snapshot: s, rows: [], now: noon).claude?.source == "From Claude Code usage")
    }
}

/// Segmento `Agents` (03 §5): contagem pura a partir do estado de atenção.
struct StatusBarAgentsTests {
    private let claude = UUID(), codex = UUID(), shell = UUID(), blocked = UUID()
    private var providers: [UUID: TerminalProvider] { [claude: .claude, codex: .codex, shell: .shell, blocked: .opencode] }

    @Test func countsOnlyWorkingAgentTerminals() throws {
        let statuses: [UUID: AgentActivity] = [claude: .working, codex: .working, shell: .working, blocked: .idle]
        let summary = try #require(StatusBarAgents.summary(statuses: statuses, providers: providers, needYou: 0))
        #expect(summary.working == 2 && summary.needYou == 0, "shell não é agente; idle não trabalha")
        #expect(summary.text == "2 working")
        #expect(summary.glyph == .working)
    }

    @Test func needYouWinsTheGlyphAndOnlyNonZeroPartsShow() throws {
        let both = try #require(StatusBarAgents.summary(statuses: [claude: .working], providers: providers, needYou: 2))
        #expect(both.text == "1 working · 2 need you" && both.glyph == .needsInput)
        let onlyNeed = try #require(StatusBarAgents.summary(statuses: [claude: .idle], providers: providers, needYou: 3))
        #expect(onlyNeed.text == "3 need you" && onlyNeed.glyph == .needsInput)
    }

    @Test func hiddenWhenNothingWorksAndNothingNeedsYou() {
        #expect(StatusBarAgents.summary(statuses: [:], providers: [:], needYou: 0) == nil)
        #expect(StatusBarAgents.summary(statuses: [claude: .done, codex: .waitingOnSubagents], providers: providers, needYou: 0) == nil)
        #expect(StatusBarAgents.summary(statuses: [shell: .working], providers: providers, needYou: 0) == nil)
        #expect(StatusBarAgents.summary(statuses: [unknownTerminal: .working], providers: providers, needYou: 0) == nil, "sem contexto, não é agente conhecido")
    }

    private let unknownTerminal = UUID()

    /// A contagem de `need you` é a do badge do Inbox: itens 1–2 abertos da fila mais os pedidos de ajuda de computador.
    @Test func needYouMatchesTheInboxBadge() throws {
        var center = AttentionCenter()
        let context = AttentionContext(sessionID: UUID(), sessionTitle: "S", projectName: "P", provider: .claude)
        let now = Date()
        _ = center.apply(
            TerminalActivity(terminalID: claude, activity: .needsInput(.permission), changedAt: now), context: context, now: now)
        _ = center.apply(TerminalActivity(terminalID: codex, activity: .working, changedAt: now), context: context, now: now)
        let summary = try #require(StatusBarAgents.summary(center: center, contexts: [claude: context, codex: AttentionContext(sessionID: UUID(), sessionTitle: "T", projectName: nil, provider: .codex)], extraNeedYou: 1))
        #expect(summary.needYou == center.badgeCount + 1 && summary.working == 1)
    }
}

@MainActor
@Suite("T4-01 - status bar", .serialized, .offscreenAppKit)
struct StatusBarUITests {
    func controller(_ content: StatusBarContent, flags: SliceFlags = SliceFlags(current: .slice4, restricted: false)) -> (StatusBarController, ActionRegistry, OverlayRouter) {
        let registry = ActionRegistry(flags: flags, surface: FakeSurface())
        let overlays = OverlayRouter()
        let controller = StatusBarController(preview: content, overlays: overlays, flags: flags)
        controller.now = { noon }
        controller.calendar = utc()
        try? controller.register(in: registry)
        // As ações que os botões dos popovers disparam (donas do ComputersController, do Settings e do Docker) entram como no-op.
        for id in [ActionID.computerStop, .pageComputers, .settingsOpenSection, .dockerStart] { try? registry.register(id) { _ in nil } }
        return (controller, registry, overlays)
    }

    func full() -> StatusBarContent {
        var s = snapshot(claude: (0.62, 0.31), codex: 1.0)
        s.computers = [usage("phoenix-az", memory: 2_500_000_000), usage("austin-tx", memory: 2_000_000_000, cpu: 12), usage("dallas-tx", memory: 2_000_000_000)]
        let day = utc().startOfDay(for: noon)
        s.proxies = [
            ProxyUsageSummary(id: "zyte-us", name: "zyte-us", isDefault: true, requests: 120, bytes: 0, costMicros: 420_000,
                              daily: [ProxyDay(dayStart: day, requests: 120, bytes: 0, costMicros: 420_000)], reportsCost: true),
            ProxyUsageSummary(id: "homebrew", name: "homebrew", isDefault: false, requests: 30, bytes: 0, costMicros: 0,
                              daily: [ProxyDay(dayStart: day, requests: 30, bytes: 0, costMicros: 0)], reportsCost: false),
        ]
        return StatusBarContent.make(
            snapshot: s, rows: [row("phoenix-az"), row("austin-tx", .ready, session: "Houston batch"), row("dallas-tx", proxy: "homebrew")], dockerStopped: false, now: noon, calendar: utc())
    }

    func render(_ view: some View, size: CGSize, name: String, line: UInt = #line) {
        DSFonts.registerIfNeeded()
        let previous = MotionPolicy.shared.preference
        MotionPolicy.shared.preference = .on
        defer { MotionPolicy.shared.preference = previous }
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).environment(\.colorScheme, .dark))
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        withSnapshotTesting(record: ComponentSnapshotTests.recording) {
            assertSnapshot(of: host, as: .image(precision: 0.98, perceptualPrecision: 0.97), named: name, testName: "statusBar", line: line)
        }
    }

    func environment(_ view: some View, registry: ActionRegistry) -> some View {
        view.environment(\.actionRegistry, registry).environment(\.elementStore, UIElementStore())
    }

    @Test func barHasTheSegmentsOfTheSpecOnBothSides() {
        let (controller, registry, _) = controller(full())
        render(environment(StatusBarView(controller: controller), registry: registry), size: CGSize(width: 1000, height: DS.Layout.statusBarHeight), name: "bar")
    }

    @Test func barWithOnlyTheClaudeWindows() {
        let (controller, registry, _) = controller(StatusBarContent.make(snapshot: snapshot(), rows: [], now: noon))
        render(environment(StatusBarView(controller: controller), registry: registry), size: CGSize(width: 760, height: DS.Layout.statusBarHeight), name: "barClaudeOnly")
    }

    @Test func popoversShowUsageComputersAndProxy() {
        let (controller, registry, _) = controller(full())
        func popover(_ segment: StatusBarSegment) -> some View {
            environment(StatusBarPopoverContent(controller: controller, segment: segment, dismiss: {}).padding(DS.Space.s4), registry: registry)
                .background(DS.Color.canvas)
        }
        render(popover(.claude), size: CGSize(width: 340, height: 190), name: "popoverClaude")
        render(popover(.codex), size: CGSize(width: 340, height: 150), name: "popoverCodexRed")
        render(popover(.computers), size: CGSize(width: 360, height: 260), name: "popoverComputers")
        render(popover(.proxyUsage), size: CGSize(width: 340, height: 120), name: "popoverProxy")
    }

    @Test func toggleActionHidesTheBarAndKeepsTheSegmentChoices() async throws {
        let (controller, registry, _) = controller(full())
        #expect(controller.isShown)
        let hidden = try await registry.perform(.viewToggleStatusBar, .press)
        #expect(hidden.message == "hidden" && !controller.isShown)
        _ = try await registry.perform(.viewToggleStatusBar, .press)
        #expect(controller.isShown)
        #expect(try await registry.perform(.statusBarToggleSegment, .select("codex")).message == "off")
        #expect(!controller.shows(.codex) && controller.shows(.claude))
        #expect(try await registry.perform(.statusBarToggleSegment, .select("codex")).message == "on")
    }

    @Test func openingASegmentWithoutDataExplainsWhy() async throws {
        let (controller, registry, overlays) = controller(StatusBarContent())
        defer { withExtendedLifetime(controller) {} }
        await #expect(throws: ActionError.failed(.statusBarOpenSegment, message: "Nothing to show yet.")) {
            _ = try await registry.perform(.statusBarOpenSegment, .select("claude"))
        }
        await #expect(throws: ActionError.self) { _ = try await registry.perform(.statusBarOpenSegment, .select("nope")) }
        #expect(overlays.popover == nil && !controller.hasData(.proxyUsage))
    }

    @Test func openingASegmentPresentsItsPopover() async throws {
        let (bar, registry, overlays) = controller(full())
        _ = try await registry.perform(.statusBarOpenSegment, .select("computers"))
        withExtendedLifetime(bar) {}
        #expect(overlays.popover?.spec.id == .statusBarPopover("computers"))
    }

    @Test func agentsSegmentAppearsOnlyWithDataAndFollowsTheToggle() async throws {
        let (controller, _, _) = controller(StatusBarContent())
        #expect(!controller.shows(.agents), "sem agente trabalhando nem pedindo você, o segmento some")
        controller.agentsSource = { StatusBarAgents(working: 4, needYou: 2) }
        #expect(controller.shows(.agents) && controller.agents?.text == "4 working · 2 need you")
        controller.toggle(.agents)
        #expect(!controller.shows(.agents))
    }

    @Test func agentsSegmentHasNoPopoverAndPerformsTheInboxAction() async throws {
        let (controller, registry, overlays) = controller(StatusBarContent())
        controller.agentsSource = { StatusBarAgents(working: 1, needYou: 0) }
        var opened = 0
        try registry.register(.pageSessions) { _ in opened += 1; return "sessions" }
        await #expect(throws: ActionError.self) { _ = try await registry.perform(.statusBarOpenSegment, .select("agents")) }
        #expect(overlays.popover == nil)

        let store = UIElementStore()
        let host = NSHostingView(rootView: StatusBarView(controller: controller).environment(\.actionRegistry, registry).environment(\.elementStore, store).frame(width: 800, height: DS.Layout.statusBarHeight))
        host.frame = NSRect(x: 0, y: 0, width: 800, height: DS.Layout.statusBarHeight)
        host.layoutSubtreeIfNeeded()
        let node = try #require(store.snapshot().find(.statusBarAgents))
        #expect(node.action == .pageSessions && node.kind == "button")
        _ = try await registry.perform(try #require(node.action), .press)
        #expect(opened == 1)
    }

    @Test func contextMenuListsEverySegmentAndHide() {
        let (controller, _, _) = controller(full())
        let ids = controller.contextEntries().compactMap { $0.item?.id }
        #expect(ids == ["segment.claude", "segment.codex", "segment.agents", "segment.computers", "segment.proxyUsage", "segment.docker", "hide"])
        controller.toggle(.codex)
        #expect(controller.contextEntries().compactMap(\.item).first { $0.id == "segment.codex" }?.checked == false)
    }

    @Test func slicesBelowFourHideTheBarButTheDefaultAppShowsIt() {
        #expect(!controller(full(), flags: SliceFlags(current: .slice3)).0.isShown)
        #expect(controller(full(), flags: SliceFlags(current: .slice4)).0.isShown)
        #expect(controller(full(), flags: SliceFlags(current: .slice3, restricted: false)).0.isShown)
    }
}
