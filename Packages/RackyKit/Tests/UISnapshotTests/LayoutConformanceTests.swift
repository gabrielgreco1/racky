import RackyDesignSystem
import RackyProtocol
import AppKit
import Testing

@testable import RackyUI

/// Medidas da janela e do chrome (03 §1, T1-10): semáforos, faixa de titlebar, largura da sidebar, tamanho mínimo.
@MainActor
@Suite(.offscreenAppKit) struct LayoutConformanceTests {
    @Test func trafficLightGeometryMatchesTheSpec() {
        for h: CGFloat in [12, 14, 16, 20] {
            let origins = WindowGeometry.trafficLightOrigins(buttonSize: CGSize(width: h, height: h))
            #expect(origins.map(\.x) == [16, 36, 56])
            for o in origins { #expect(DS.Layout.titlebarHeight - (o.y + h / 2) == 18, "centro vertical em y = 18") }
        }
        #expect(WindowGeometry.trafficLightPad(fullScreen: false) == 80)
        #expect(WindowGeometry.trafficLightPad(fullScreen: true) == 0)
        #expect(DS.Layout.titlebarHeight == 36)
    }

    @Test func sidebarWidthIsClamped() {
        #expect(DS.Layout.sidebarWidth == 280)
        #expect(WindowGeometry.clampedSidebarWidth(100) == 220)
        #expect(WindowGeometry.clampedSidebarWidth(900) == 500)
        #expect(WindowGeometry.clampedSidebarWidth(300) == 300)
    }

    /// Posição de um semáforo medida na janela: origem x e distância do centro ao topo.
    private func lightMetrics(_ window: NSWindow, _ type: NSWindow.ButtonType) -> (x: CGFloat, centerFromTop: CGFloat) {
        let b = window.standardWindowButton(type)!
        let r = b.convert(b.bounds, to: nil)
        return (r.minX, window.frame.height - r.midY)
    }

    private func expectLights(_ window: NSWindow, _ note: String) {
        let xs = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map { lightMetrics(window, $0) }
        #expect(xs.map(\.x) == [16, 36, 56], "\(note): x")
        for m in xs { #expect(abs(m.centerFromTop - 18) < 0.5, "\(note): centro y = \(m.centerFromTop)") }
    }

    @Test func windowIsConfiguredAndTrafficLightsSurviveResizeAndRelayout() async {
        let env = AppEnvironment(environment: [:])
        let controller = await EmptyWindowTreeTests.host(env)
        let window = controller.window!
        defer { window.close() }
        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.titlebarAppearsTransparent)
        #expect(window.titleVisibility == .hidden)
        #expect(window.toolbar == nil)
        #expect(!window.isMovableByWindowBackground)
        #expect(window.contentMinSize == NSSize(width: 760, height: 480))
        expectLights(window, "760x480")

        window.setContentSize(NSSize(width: 1440, height: 900))
        try? await Task.sleep(for: .milliseconds(100))
        expectLights(window, "1440x900")

        // Se o AppKit mexer nos botões (relayout da titlebar), eles voltam ao lugar.
        window.standardWindowButton(.closeButton)!.setFrameOrigin(NSPoint(x: 3, y: 3))
        window.setContentSize(NSSize(width: 1200, height: 800))
        try? await Task.sleep(for: .milliseconds(100))
        expectLights(window, "depois de bagunçar")
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: window)
        expectLights(window, "mudança de tela")
    }

    @Test func titlebarStripIs36AndSidebarStartsAt280() async {
        let env = AppEnvironment(environment: [:])
        let controller = await EmptyWindowTreeTests.host(env, size: NSSize(width: 1440, height: 900))
        defer { controller.window?.close() }
        let tree = await env.registry.uiTree(root: nil)
        let strip = tree.find(.windowTitlebar)?.frame
        #expect(strip?.height == 36)
        #expect(strip?.y == 0)
        #expect(strip?.width == 280)
        #expect(tree.find(.sidebar)?.frame?.width == 280)
        #expect((tree.find(.windowAppName)?.frame?.x ?? 0) >= 80)
        #expect(tree.find(.windowAppName)?.frame?.height == 24)
        #expect(tree.find(.windowSidebarToggle)?.frame?.width == 32)
        #expect(tree.find(.windowSidebarToggle)?.frame?.height == 24)
        #expect(tree.find(.windowHistoryBack)?.frame?.width == 22)
        #expect(tree.find(.windowHistoryBack)?.frame?.height == 20)
        // ←/→ terminam 12 pt antes da borda direita da faixa
        let fwd = tree.find(.windowHistoryForward)?.frame
        let right: Double = (fwd?.x ?? 0) + (fwd?.width ?? 0)
        #expect(right == 268)
    }

    @Test func toggleSidebarActionCollapsesAndExpands() async throws {
        let env = AppEnvironment(environment: [:])
        let controller = await EmptyWindowTreeTests.host(env, size: NSSize(width: 1440, height: 900))
        defer { controller.window?.close() }
        let r1 = try await env.registry.perform(.viewToggleSidebar, .press)
        #expect(r1.message == "collapsed")
        #expect(env.shell.sidebarCollapsed)
        let r2 = try await env.registry.perform(.viewToggleSidebar, .press)
        #expect(r2.message == "expanded")
        #expect(!env.shell.sidebarCollapsed)
    }

    // MARK: Sidebar (03 §2, T1-13)

    @Test func sidebarMetricsMatchTheSpecNumbers() {
        #expect(SidebarMetrics.searchHeight == 32 && SidebarMetrics.navHeight == 32)
        #expect(SidebarMetrics.sectionHeaderHeight == 32)
        #expect(SidebarMetrics.projectRowHeight == 28)
        #expect(SidebarMetrics.agentRowHeight == 26)  // v5
        #expect(SidebarMetrics.pendingHeight == 32)
        #expect(SidebarMetrics.footerHeight == 32)
        #expect(SidebarMetrics.cardRadius == 10)
        #expect(SidebarMetrics.cardPaddingV == 8 && SidebarMetrics.cardPaddingVTitleOnly == 10)  // v5
        #expect(SidebarMetrics.cardMarginLeading == 4 && SidebarMetrics.cardMarginTrailing == 6)
        #expect(SidebarMetrics.statusColumn == 16 && SidebarMetrics.line1Height == 22 && SidebarMetrics.line2Height == 16)  // v5
        #expect(SidebarMetrics.paddingH == 8 && SidebarMetrics.paddingTop == 8 && SidebarMetrics.paddingBottom == 4 && SidebarMetrics.navGap == 2)
        #expect(SidebarMetrics.projectPaddingLeading == 10)
        #expect(SidebarMetrics.sessionsBeforeShowMore == 5 && SidebarMetrics.agentRowsBeforeSummary == 4)
    }

    @Test func sidebarFramesFollowTheSpecInBothWindowSizes() async throws {
        for size in [NSSize(width: 1440, height: 900), NSSize(width: 760, height: 480)] {
            let env = AppEnvironment(environment: ["RACKY_SLICE": "4", "RACKY_SCREEN": SidebarFixtures.screenID])
            let cast = SidebarFixtures.full()
            env.sidebar.apply(cast.snapshot)
            env.sidebar.select(cast.selectedSessionID!)
            env.sidebar.beginPending(PendingLaunch(name: "Add retry logic", projectID: cast.pendingProjectID, phase: .fetching))
            let controller = await EmptyWindowTreeTests.host(env, size: size)
            defer { controller.window?.close() }
            try await Task.sleep(for: .milliseconds(300))
            let tree = await env.registry.uiTree(root: nil)
            let note = "\(Int(size.width))x\(Int(size.height))"

            let search = try #require(tree.find(.sidebarSearch)?.frame, "search \(note)")
            #expect(search.height == 32 && search.x == 8 && search.width == 264 && search.y == 44, "search \(note): \(search)")
            var previous = search
            for id in [A11yID.sidebarNavSessions, .sidebarNavComputers, .sidebarNavDatasets, .sidebarNavLibrary] {
                let nav = try #require(tree.find(id)?.frame, "\(id.rawValue) \(note)")
                #expect(nav.height == 32 && nav.x == 8 && nav.width == 264, "\(id.rawValue) \(note)")
                #expect(nav.y == previous.y + previous.height + 2, "gap 2 antes de \(id.rawValue) \(note)")
                previous = nav
            }

            let motion = cast.projects[0], otter = cast.projects[1]
            // A rolagem da lista usa overlay (DS §12.24), mas o `NSScrollView` só troca de estilo depois do primeiro quadro e,
            // com mouse ligado ou "Always show scroll bars", o sistema reserva ~15 pt. O teste mede a largura da coluna de
            // conteúdo (280 menos a rolagem que o sistema reservou) e, assim, não depende do estilo de scroller da máquina.
            let projectFrame: UIFrame? = tree.find(.sidebarProject(motion.id.uuidString))?.frame
            let reserved: Double = 264 - (projectFrame?.width ?? 264)
            #expect(reserved == 0 || (reserved > 0 && reserved <= 20), "rolagem reservada \(reserved) \(note)")
            if size.height >= 900 {
            let row = try #require(tree.find(.sidebarProject(motion.id.uuidString))?.frame, "project row \(note)")
            #expect(row.height == 28 && row.x == 8 && row.width == 264 - reserved, "project row \(note): \(row)")

            // v5: o primeiro card do projeto começa 8 pt (padding vertical) abaixo da linha do projeto.
            let main = try #require(tree.find(.sidebarSession(cast.selectedSessionID!.uuidString))?.frame, "card header \(note)")
            #expect(main.y == row.y + row.height + 8, "padding vertical do card \(note): \(main.y) vs \(row.y + row.height)")
            #expect(main.height == 42, "linha 1 (22) + gap 4 + linha 2 (16) \(note)")
            #expect(main.x == 8 + 4 + 10, "margem 4 + padding 10 \(note)")
            let expectedWidth: Double = 280 - 16 - 4 - 6 - 20 - reserved
            #expect(main.width == expectedWidth, "margem direita 6 \(note)")

            let agent = cast.terminals.first { t in cast.tabs.first { $0.id == t.tabID }?.sessionID == cast.selectedSessionID }!
            let agentRow = try #require(tree.find(.sidebarSessionAgent(cast.selectedSessionID!.uuidString, agent.id.uuidString))?.frame, "agent row \(note)")
            #expect(agentRow.height == 26, "linha de agente \(note)")
            }

            let pending = try #require(tree.find(.sidebarPending(env.sidebar.pending[0].id.uuidString))?.frame, "pending \(note)")
            #expect(pending.height == 32 + 16, "linha pendente: 32 + fase \(note)")
            let otterRow = try #require(tree.find(.sidebarProject(otter.id.uuidString))?.frame)
            #expect(pending.y == otterRow.y + otterRow.height, "pendente é a primeira linha do projeto \(note)")

            let reveal = try #require(tree.find(.sidebarFooterReveal)?.frame, "footer \(note)")
            // A status bar (24 pt, T4-01) ocupa o rodapé da janela inteira: o rodapé da sidebar termina logo acima dela.
            let floor = Double(size.height) - (env.statusBar.isShown ? Double(DS.Layout.statusBarHeight) : 0)
            #expect(reveal.y + reveal.height <= floor && reveal.y >= floor - 32 - 1, "rodapé de 32 \(note): \(reveal)")
        }
    }
}
