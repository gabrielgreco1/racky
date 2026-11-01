import RackyDesignSystem
import RackyProtocol
import AppKit
import SwiftUI
import Testing

@testable import RackyUI

/// F38: o canto do pane (ícone do computador, botões) cresce quando o "Restart to apply" aparece, sem cortar nem sair da borda.
@MainActor
@Suite(.serialized, .offscreenAppKit) struct PaneChromeSizingTests {
    @Test func floatingButtonsGrowWhenRestartToApplyAppears() async throws {
        let env = AppEnvironment(environment: ["RACKY_SKIP_ONBOARDING": "1"])
        let container = PaneContainerView(entry: env.workspace.runtime.entry(for: UUID()), registry: env.registry, elements: env.elements)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = container
        container.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let session = UUID()
        func apply(restart: Bool) {
            container.apply(
                title: "Claude Code", provider: .claude, glyph: .none, focused: true, multiPane: false, expanded: false, state: .running,
                subagent: (session, .full, restart))
        }
        func floating() -> NSRect? {
            container.subviews.compactMap { $0 as? ChromeSizingHostingView }.map(\.frame).first { $0.width > 0 && $0.width < container.bounds.width }
        }
        func settle() async {
            for _ in 0 ..< 20 {
                container.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        apply(restart: false)
        await settle()
        let before = try #require(floating())
        apply(restart: true)
        await settle()
        let after = try #require(floating())
        #expect(after.width > before.width + 60, "o aviso entra com o texto inteiro")
        #expect(after.maxX <= container.bounds.width, "nada passa da borda direita")
        let host = try #require(container.subviews.compactMap { $0 as? ChromeSizingHostingView }.first { $0.frame == after })
        #expect(after.width >= host.fittingSize.width - 0.5, "o quadro cabe o conteúdo")
    }
}
