import RackyCore
import RackyDesignSystem
import RackyProtocol
import RackyStore
import AppKit
import Foundation
import SwiftUI
import Testing

@testable import RackyUI

/// Contêiner do painel direito (10-right-panel §1): layout, ações, regras de janela, persistência e posição na janela.
@MainActor
@Suite(.serialized) struct RightPanelTests {
    // MARK: Contrato

    @Test func environmentRegistersTheModulesWithStripButtonsForFilesAndInsights() {
        let env = AppEnvironment(environment: [:])
        #expect(env.rightPanel.modules.map(\.id) == [.files, .insights, .computers, .data, .conversations, .sourceControl, .checks, .context])
        #expect(env.rightPanel.layout.visible == [.files, .insights])
        let withButtons = env.rightPanel.modules.filter { $0.toggleAction != nil }.map(\.id)
        #expect(withButtons == [.files, .insights, .computers, .data])
        #expect(env.rightPanel.module(.files)?.stripButtonID == .tabsFilesToggle)
        #expect(env.rightPanel.module(.insights)?.stripButtonID == .tabsInsightsToggle)
        #expect(env.rightPanel.module(.insights)?.title == "Insights", "o placeholder do Insights está registrado")
    }

    @Test func geometryConstantsAgreeWithTheDesignSystemTokens() {
        #expect(RightPanelGeometry.collapseBelowWindowWidth == Double(DS.Layout.rightPanelCollapseBelowWindowWidth))
        #expect(RightPanelGeometry.centerMinWidth == Double(DS.Layout.rightPanelCenterMinWidth))
        #expect(RightPanelGeometry.barHeight == Double(DS.Layout.titlebarHeight))
        #expect(RightPanelMetrics.stripButtons == StripMetrics.toggleSize.width * 5 + StripMetrics.navGap * 4 + DS.Space.s2 * 2)
        #expect(DS.Layout.windowMinWidth == 760 && DS.Layout.windowMinHeight == 480)
    }

    @Test func shortcutsAreBoundAndMatchTheActionTable() throws {
        let registry = try KeyBindingRegistry.canonical()
        #expect(registry.conflicts().isEmpty)
        for (action, chord) in [(ActionID.rightPanelToggleFiles, "⌥⌘1"), (.rightPanelToggleInsights, "⌥⌘2"), (.rightPanelToggle, "⌥⌘0")] {
            let found = registry.bindings(for: action).map(\.chord.description)
            #expect(found.contains(KeyChord(chord)?.description ?? "?"), "\(action) esperava \(chord), tem \(found)")
            #expect(action.spec.shortcut == chord)
            #expect(action.spec.slice == .slice1, "a feature é da v1: o botão aparece sem RACKY_SLICE")
        }
    }

    // MARK: Ações e layout

    @Test func actionsToggleMinimizeSwapAndResize() async throws {
        let env = AppEnvironment(environment: [:])
        let panel = env.rightPanel
        panel.updateWindow(width: 1440, sidebarWidth: 280)
        #expect(panel.isShown)
        #expect(panel.isOn(.files) && panel.isOn(.insights))

        // AC-RP03: minimizar Insights faz o Files ocupar o painel; o botão reabre.
        var result = try await env.registry.perform(.rightPanelMinimize, .select("insights"))
        #expect(result.message == "off")
        #expect(panel.layout.visible == [.files])
        #expect(panel.isShown)
        result = try await env.registry.perform(.rightPanelToggleInsights, .press)
        #expect(result.message == "on")
        #expect(panel.layout.visible == [.files, .insights])

        // AC-RP04: soltar o header de Insights em cima troca a ordem.
        result = try await env.registry.perform(.rightPanelMove, .select("insights:top"))
        #expect(result.message == "insights,files")
        result = try await env.registry.perform(.rightPanelSwap, .press)
        #expect(result.message == "files,insights")

        // AC-RP02: largura e divisão por ação (a mesma coisa que arrastar).
        result = try await env.registry.perform(.rightPanelSetWidth, .set("500"))
        #expect(result.message == "500")
        result = try await env.registry.perform(.rightPanelSetSplit, .set("0.5"))
        #expect(result.message == "0.500")
        #expect(panel.effectiveWidth == 500)

        // Fechar o painel inteiro e reabrir (⌥⌘0).
        result = try await env.registry.perform(.rightPanelToggle, .press)
        #expect(result.message == "closed")
        #expect(!panel.isShown)
        #expect(!panel.isOn(.files))
        result = try await env.registry.perform(.rightPanelToggleFiles, .press)
        #expect(result.message == "on", "o botão de um módulo reabre o painel")
        #expect(panel.isShown)
    }

    @Test func actionsRejectBadArguments() async throws {
        let env = AppEnvironment(environment: [:])
        env.rightPanel.updateWindow(width: 1440, sidebarWidth: 280)
        await #expect(throws: ActionError.self) { try await env.registry.perform(.rightPanelMinimize, .press) }
        await #expect(throws: ActionError.self) { try await env.registry.perform(.rightPanelMinimize, .select("nope")) }
        await #expect(throws: ActionError.self) { try await env.registry.perform(.rightPanelMove, .select("files:sideways")) }
        await #expect(throws: ActionError.self) { try await env.registry.perform(.rightPanelSetWidth, .set("wide")) }
        _ = try await env.registry.perform(.rightPanelMinimize, .select("insights"))
        let swap = env.registry.availability(of: .rightPanelSwap)
        #expect(swap == .disabled(reason: "Open both modules to swap them."))
    }

    @Test func lastModuleClosesThePanelAndTheShortcutRestoresDefaults() async throws {
        let env = AppEnvironment(environment: [:])
        let panel = env.rightPanel
        panel.updateWindow(width: 1440, sidebarWidth: 280)
        _ = try await env.registry.perform(.rightPanelMinimize, .select("insights"))
        _ = try await env.registry.perform(.rightPanelMinimize, .select("files"))
        #expect(!panel.isShown)
        #expect(!panel.layout.isOpen)
        _ = try await env.registry.perform(.rightPanelToggle, .press)
        #expect(panel.isShown)
        #expect(panel.layout.visible == [.files, .insights])
    }

    // MARK: Regras de janela (03 §1.1, §1.5)

    @Test func panelCollapsesBelow1100AndOpensForcedWhenAsked() async throws {
        let env = AppEnvironment(environment: [:])
        let panel = env.rightPanel
        panel.updateWindow(width: 1440, sidebarWidth: 280)
        #expect(panel.isShown)
        panel.updateWindow(width: 1000, sidebarWidth: 280)
        #expect(!panel.isShown, "abaixo de 1100 recolhe sozinho")
        #expect(panel.layout.isOpen, "a intenção de estar aberto fica guardada")
        panel.updateWindow(width: 1200, sidebarWidth: 280)
        #expect(panel.isShown, "reabre ao alargar")

        panel.updateWindow(width: 1000, sidebarWidth: 280)
        #expect(!panel.isShown)
        _ = try await env.registry.perform(.rightPanelToggleFiles, .press)
        #expect(panel.isShown, "abrir pelo botão abaixo de 1100 vale: sobram 400 para o painel")
        #expect(panel.effectiveWidth == 400, "o padrão (520) cabe só até o centro mínimo")
        _ = try await env.registry.perform(.rightPanelSetWidth, .set("600"))
        #expect(panel.effectiveWidth == 400, "o centro nunca fica abaixo de 320 (1000 − 280 − 320)")
        panel.updateWindow(width: 1200, sidebarWidth: 280)
        panel.updateWindow(width: 1000, sidebarWidth: 280)
        #expect(!panel.isShown, "ao alargar acima de 1100 a abertura forçada acaba")
    }

    @Test func nothingOpensWhenEvenTheMinimumDoesNotFit() async throws {
        let env = AppEnvironment(environment: [:])
        let panel = env.rightPanel
        panel.updateWindow(width: 760, sidebarWidth: 280)
        #expect(!panel.isShown)
        #expect(panel.effectiveWidth == nil)
        _ = try await env.registry.perform(.rightPanelToggleFiles, .press)
        #expect(!panel.isShown, "em 760×480 não cabe: nada sai da caixa")
        panel.updateWindow(width: 760, sidebarWidth: 220)
        #expect(panel.effectiveWidth == nil, "760 − 220 − 320 = 220 < 260")
    }

    // MARK: Persistência (AC-RP02)

    @Test func layoutIsPersistedInUiState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("racky-rightpanel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await RackyStore.open(paths: StorePaths(root: root), debounce: .milliseconds(10))

        let first = AppEnvironment(environment: [:])
        await first.rightPanel.attach(store: store)
        first.rightPanel.updateWindow(width: 1440, sidebarWidth: 280)
        _ = try await first.registry.perform(.rightPanelSetWidth, .set("512"))
        _ = try await first.registry.perform(.rightPanelSetSplit, .set("0.4"))
        _ = try await first.registry.perform(.rightPanelMove, .select("insights:top"))
        _ = try await first.registry.perform(.rightPanelMinimize, .select("files"))
        // O salvamento é debounced: espera ele chegar ao store (sob carga 150 ms não bastavam).
        var layout = RightPanelLayout()
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(100))
            try await store.flush()
            let second = AppEnvironment(environment: [:])
            await second.rightPanel.attach(store: store)
            layout = second.rightPanel.layout
            if layout.width == 512, layout.visible == [.insights] { break }
        }
        #expect(layout.width == 512)
        #expect(abs(layout.topFraction - 0.4) < 0.001)
        #expect(layout.order.prefix(2) == [.insights, .files])
        #expect(layout.visible == [.insights])
        #expect(layout.isOpen)
    }

    // MARK: Na janela (motion, faixa de topo, 760×480)

    private func host(width: CGFloat, height: CGFloat, env: AppEnvironment) async -> MainWindowController {
        let controller = await EmptyWindowTreeTests.host(env, size: NSSize(width: width, height: height))
        for _ in 0..<80 where env.elements.snapshot().find(.tabsRightPanelToggle)?.frame == nil { try? await Task.sleep(for: .milliseconds(25)) }
        return controller
    }

    private func settle(_ env: AppEnvironment, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    @Test func panelSitsOnTheRightAndStripButtonsReflectState() async throws {
        let previous = MotionPolicy.shared.mode
        MotionPolicy.shared.mode = .instant
        defer { MotionPolicy.shared.mode = previous }
        let env = AppEnvironment(environment: [:])
        let controller = await host(width: 1440, height: 900, env: env)
        defer { controller.window?.close() }
        #expect(await settle(env) { env.rightPanel.isShown && env.elements.snapshot().find(.rightPanel)?.frame != nil })
        let tree = env.elements.snapshot()
        let panel = try #require(tree.find(.rightPanel)?.frame)
        #expect(abs(panel.width - RightPanelGeometry.defaultWidth) < 1.5, "largura padrão \(RightPanelGeometry.defaultWidth), medida \(panel.width)")
        #expect(abs(panel.x + panel.width - 1440) < 1.5, "encosta na borda direita")
        let files = try #require(tree.find(.rightPanelModule("files"))?.frame)
        let insights = try #require(tree.find(.rightPanelModule("insights"))?.frame)
        #expect(files.y < insights.y, "Files em cima, Insights embaixo")
        let usable = panel.height - 36
        #expect(abs(files.height / (files.height + insights.height) - 2.0 / 3.0) < 0.02, "~2/3 e ~1/3 de \(usable)")

        // Botões na faixa de topo à direita, dentro dos 36 pt.
        let filesButton = try #require(tree.find(.tabsFilesToggle)?.frame)
        let insightsButton = try #require(tree.find(.tabsInsightsToggle)?.frame)
        let panelButton = try #require(tree.find(.tabsRightPanelToggle)?.frame)
        for button in [filesButton, insightsButton, panelButton] {
            #expect(button.y >= 0 && button.y + button.height <= 36)
            #expect(button.x + button.width <= 1440)
        }
        #expect(filesButton.x < insightsButton.x && insightsButton.x < panelButton.x)

        // Fechar o painel: o terminal (centro) ocupa a janela; os botões continuam no mesmo canto.
        _ = try await env.registry.perform(.rightPanelToggle, .press)
        #expect(await settle(env) { !env.rightPanel.isContentVisible && env.elements.snapshot().find(.rightPanel) == nil })
        let closed = env.elements.snapshot()
        #expect(closed.find(.rightPanel) == nil, "recolhido não deixa controles na árvore")
        #expect(closed.find(.tabsFilesToggle) != nil)
        #expect(closed.find(.tabsRightPanelToggle)?.frame?.x == panelButton.x, "os botões não se mexem")
    }

    @Test func compactModeBelowTheThresholdHidesTitles() async throws {
        let previous = MotionPolicy.shared.mode
        MotionPolicy.shared.mode = .instant
        defer { MotionPolicy.shared.mode = previous }
        let env = AppEnvironment(environment: [:])
        let controller = await host(width: 1440, height: 900, env: env)
        defer { controller.window?.close() }
        #expect(await settle(env) { env.rightPanel.isShown })
        _ = try await env.registry.perform(.rightPanelSetWidth, .set("280"))
        #expect(await settle(env) { abs(env.rightPanel.measuredWidth - 280) < 1.5 })
        #expect(RightPanelGeometry.isCompact(width: Double(env.rightPanel.measuredWidth)))
        let tree = env.elements.snapshot()
        let panel = try #require(tree.find(.rightPanel)?.frame)
        for node in tree.find(.rightPanel)?.flattened() ?? [] {
            guard let frame = node.frame, node.id != .rightPanel else { continue }
            #expect(frame.x >= panel.x - 1 && frame.x + frame.width <= panel.x + panel.width + 1, "\(node.id.rawValue) fica dentro do painel (\(frame))")
        }
    }

    @Test func nothingLeavesTheBoxAt760x480() async throws {
        let previous = MotionPolicy.shared.mode
        MotionPolicy.shared.mode = .instant
        defer { MotionPolicy.shared.mode = previous }
        let env = AppEnvironment(environment: [:])
        let controller = await host(width: 760, height: 480, env: env)
        defer { controller.window?.close() }
        #expect(!env.rightPanel.isShown, "painel recolhido na janela mínima")
        let tree = env.elements.snapshot()
        let window = try #require(tree.window)
        for id in [A11yID.tabsFilesToggle, .tabsInsightsToggle, .tabsComputersToggle, .tabsDataToggle, .tabsRightPanelToggle] {
            let frame = try #require(tree.find(id)?.frame, "\(id.rawValue) existe mesmo com o painel fechado")
            #expect(frame.x >= 0 && frame.x + frame.width <= window.width, "\(id.rawValue) dentro da janela: \(frame)")
            #expect(frame.y >= 0 && frame.y + frame.height <= 36)
        }
        // Os botões não invadem o botão de voltar/avançar da faixa nem a sidebar.
        let sidebar = try #require(tree.find(.sidebar)?.frame)
        let files = try #require(tree.find(.tabsFilesToggle)?.frame)
        #expect(files.x >= sidebar.x + sidebar.width)
    }
}
