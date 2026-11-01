import RackyDesignSystem
import RackyProtocol
import AppKit
import SnapshotTesting
import SwiftUI
import Testing

@testable import RackyUI

/// Snapshots e medidas de Settings e do onboarding (T1-26): nav 240, conteúdo até 720, controles de 240 e nada fora da caixa
/// em 1440×900 e 760×480 (AC-T27). Referências em `__Snapshots__/`; gravar com `RACKY_RECORD_SNAPSHOTS=1`.
@MainActor
@Suite(.serialized, .offscreenAppKit) struct SettingsSnapshotTests {
    static let sizes = [CGSize(width: 1440, height: 900), CGSize(width: 760, height: 480)]

    static func demoEnv() -> AppEnvironment {
        AppEnvironment(environment: ["RACKY_SCREEN": AppEnvironment.setupDemoFixture, "RACKY_SKIP_ONBOARDING": "1"])
    }

    func snap<V: View>(_ view: V, env: AppEnvironment, size: CGSize, name: String, line: UInt = #line) {
        DSFonts.registerIfNeeded()
        let previous = MotionPolicy.shared.preference
        MotionPolicy.shared.preference = .on
        defer { MotionPolicy.shared.preference = previous }
        let root = view
            .environment(\.actionRegistry, env.registry)
            .environment(\.elementStore, env.elements)
            .environment(\.overlayRouter, env.overlays)
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        withSnapshotTesting(record: ComponentSnapshotTests.recording) {
            assertSnapshot(of: host, as: .image(precision: 0.98, perceptualPrecision: 0.97), named: name, testName: "settings", line: line)
        }
    }

    func settingsSnap(_ section: String, size: CGSize, variant: String = "", edit: (SettingsModel) async -> Void = { _ in }) async {
        let env = Self.demoEnv()
        await env.settings.refreshAgents(force: false)
        env.settings.select(section)
        env.settings.open()  // a página só monta com o Settings aberto
        await edit(env.settings)
        snap(SettingsView(model: env.settings), env: env, size: size, name: "\(section)\(variant)-\(Int(size.width))x\(Int(size.height))")
    }

    @Test func agentsSection() async {
        for size in Self.sizes { await settingsSnap("agents", size: size) }
    }

    @Test func agentsSectionWithAProfileOpenForEditing() async {
        // Sem Store o perfil não persiste; a edição só exibe o formulário para o perfil já gravado na memória do modelo.
        await settingsSnap("agents", size: CGSize(width: 1440, height: 1300), variant: "-tall")
    }

    @Test func generalSection() async {
        for size in Self.sizes { await settingsSnap("general", size: size) }
    }

    @Test func generalSectionWithCustomPrefixAndInvalidFolder() async {
        await settingsSnap("general", size: CGSize(width: 1440, height: 1000), variant: "-customInvalid") { model in
            model.change("Branch prefix") { $0.general.branchPrefix = .custom; $0.general.branchPrefixCustom = "alex/" }
            _ = model.fail("general.worktreeFolder", .init("Use an absolute path, starting with / or ~."))
        }
    }

    @Test func terminalSection() async {
        for size in Self.sizes { await settingsSnap("terminal", size: size) }
    }

    @Test func terminalSectionWithBarCursorAndLargeFont() async {
        await settingsSnap("terminal", size: CGSize(width: 1440, height: 900), variant: "-barMenlo18") { model in
            model.change("Cursor") { $0.terminal.cursor = .bar; $0.terminal.fontSize = 18; $0.terminal.fontFamily = "Menlo" }
        }
    }

    @Test func onboardingChecklist() async {
        for size in [CGSize(width: 640, height: 560), CGSize(width: 440, height: 600)] {
            let env = Self.demoEnv()
            await env.settings.refreshAgents(force: false)
            let card = OnboardingView(model: env.onboarding)
                .frame(width: size.width)
                .background(DS.Color.overlaySolid)
            snap(card, env: env, size: size, name: "onboarding-\(Int(size.width))")
        }
    }

    @Test func onboardingWhileChecking() {
        let env = Self.demoEnv()
        snap(OnboardingView(model: env.onboarding).frame(width: 640).background(DS.Color.overlaySolid), env: env, size: CGSize(width: 640, height: 560), name: "onboarding-checking")
    }

    @Test func onboardingSkipConfirmation() async throws {
        let env = Self.demoEnv()
        await env.settings.refreshAgents(force: false)
        _ = try await env.registry.perform(.onboardingSkip, .press)
        snap(OnboardingView(model: env.onboarding).frame(width: 640).background(DS.Color.overlaySolid), env: env, size: CGSize(width: 640, height: 560), name: "onboarding-skip")
    }

    /// Checklist completa (T2-09): CLIs + gh deslogado, Docker parado, imagem à espera e conflitos com a skill global.
    @Test func onboardingWithDiagnostics() async {
        let env = Self.demoEnv()
        await env.settings.refreshAgents(force: false)
        await env.onboarding.runDiagnostics(force: false)
        snap(OnboardingView(model: env.onboarding).frame(width: 640).background(DS.Color.overlaySolid), env: env, size: CGSize(width: 640, height: 820), name: "onboarding-diagnostics")
    }

    @Test func onboardingConfirmsDisablingTheGlobalSkillInline() async throws {
        let env = Self.demoEnv()
        await env.settings.refreshAgents(force: false)
        await env.onboarding.runDiagnostics(force: false)
        _ = try await env.registry.perform(.conflictDisableGlobal, .press)
        snap(OnboardingView(model: env.onboarding).frame(width: 640).background(DS.Color.overlaySolid), env: env, size: CGSize(width: 640, height: 820), name: "onboarding-disable-confirm")
    }

    // MARK: Medidas na janela

    /// Sem scroll horizontal: a página rola na vertical, então só a largura precisa caber (AC-T27).
    func within(_ inner: UIFrame, _ outer: UIFrame, _ tolerance: Double = 0.5) -> Bool {
        inner.x >= outer.x - tolerance && inner.x + inner.width <= outer.x + outer.width + tolerance
    }

    @Test func settingsFillsTheWindowAndNothingLeavesItsBox() async throws {
        for size in Self.sizes {
            let env = Self.demoEnv()
            let controller = await EmptyWindowTreeTests.host(env, size: NSSize(width: size.width, height: size.height))
            defer { controller.window?.close() }
            await env.settings.refreshAgents(force: false)
            for section in ["agents", "general", "terminal"] {
                _ = try await env.registry.perform(.settingsOpenSection, .select(section))
                _ = try await env.registry.perform(.appSettings, .press)
                try await Task.sleep(for: .milliseconds(400))
                let tree = await env.registry.uiTree(root: nil)
                let page = try #require(tree.find(.settingsPage)?.frame, "\(section) \(size): settings.page")
                #expect(page.width == Double(size.width) && page.height == Double(size.height), "Settings ocupa a janela inteira")
                let nav = try #require(tree.find(.settingsNav(section))?.frame)
                #expect(abs(nav.width - (240 - 16)) < 0.5, "item da nav: 240 menos o padding de 8")
                #expect(tree.find(.settingsBack) != nil)
                // Nada ultrapassa a página (AC-T27).
                func walk(_ node: UITreeNode) {
                    if let f = node.frame, node.id != .windowMain { #expect(within(f, page), "\(node.id.rawValue) fora da página em \(section) \(size)") }
                    node.children.forEach(walk)
                }
                if let root = tree.find(.settingsPage) { root.children.forEach(walk) }
                // Conteúdo centralizado até 720.
                let content = try #require(tree.find(.settings(section, "content"))?.frame)
                #expect(content.width <= 720.5, "conteúdo centralizado até 720: \(content.width)")
                _ = try await env.registry.perform(.settingsBack, .press)
            }
        }
    }

    @Test func controlsAre240WideWhenThereIsRoom() async throws {
        let env = Self.demoEnv()
        let controller = await EmptyWindowTreeTests.host(env, size: NSSize(width: 1440, height: 900))
        defer { controller.window?.close() }
        _ = try await env.registry.perform(.settingsOpenSection, .select("terminal"))
        _ = try await env.registry.perform(.appSettings, .press)
        try await Task.sleep(for: .milliseconds(400))
        let tree = await env.registry.uiTree(root: nil)
        let font = try #require(tree.find(.settings("terminal", "font"))?.frame)
        #expect(font.width == 240, "combobox de 240")
        let cursor = try #require(tree.find(.settings("terminal", "cursor"))?.frame)
        #expect(cursor.width <= 240)
    }

    @Test func onboardingOverlayStaysInsideTheWindowAtMinimumWidth() async throws {
        for size in Self.sizes {
            let env = AppEnvironment(environment: ["RACKY_SCREEN": AppEnvironment.setupDemoFixture])
            let controller = await EmptyWindowTreeTests.host(env, size: NSSize(width: size.width, height: size.height))
            defer { controller.window?.close() }
            env.onboarding.show()
            // As sondas são falsas, mas rodam fora da main: espera os quatro itens extras e os três agentes (sem depender de 600 ms fixos).
            for _ in 0 ..< 200 where env.onboarding.diagnosticItems.count < 4 || env.onboarding.items.contains(where: { $0.phase == .checking }) {
                try await Task.sleep(for: .milliseconds(25))
            }
            try await Task.sleep(for: .milliseconds(300))
            let tree = await env.registry.uiTree(root: nil)
            let overlay = try #require(tree.find(.onboarding)?.frame, "overlay do onboarding em \(size)")
            #expect(overlay.width <= min(640, Double(size.width) - 32) + 0.5)
            #expect(overlay.x >= 0 && overlay.x + overlay.width <= Double(size.width) + 0.5)
            #expect(tree.find(.onboardingItem("claude")) != nil && tree.find(.onboardingItem("codex")) != nil && tree.find(.onboardingItem("opencode")) != nil)
            #expect(tree.find(.onboardingSkip) != nil && tree.find(.onboardingDone) != nil)
            for key in ["gh", "docker", "image", "conflicts"] {
                #expect(tree.find(.onboardingItem(key)) != nil, "item \(key) da checklist")
            }
            #expect(tree.find(.onboardingItem("ghFix2")) == nil, "sem terminal, o Log In do gh vira Copy Command, sem botão repetido")
            let card = overlay.y + overlay.height
            #expect(overlay.y >= 0 && card <= Double(size.height) + 0.5, "o overlay cabe na janela: a lista rola, Skip e Done ficam à vista")
            let done = try #require(tree.find(.onboardingDone)?.frame)
            #expect(done.y + done.height <= Double(size.height) + 0.5)
            env.overlays.dismissAll()
        }
    }
}
