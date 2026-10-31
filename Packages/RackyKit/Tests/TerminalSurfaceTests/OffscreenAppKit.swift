import RackyDesignSystem
import AppKit
import Testing

/// Infraestrutura de testes com AppKit sem tocar a tela do dono (sem ícone no Dock, sem janela visível).
/// Regra (lint.sh): só este arquivo chama `orderFront`/`makeKeyAndOrderFront`/`activate` em Tests/.
@MainActor
enum OffscreenAppKit {
    private static var done = false

    /// `.accessory`: sem ícone do `swiftpm-testing-helper` no Dock e sem barra de menus, mas janelas ainda viram key.
    static func bootstrap() {
        guard !done else { return }
        done = true
        NSApplication.shared.setActivationPolicy(.accessory)
        TooltipController.orderingEnabled = false
    }

    /// Janela longe de qualquer tela, nunca ordenada para a frente (`makeKey()` basta para foco e eventos).
    static func makeWindow(size: NSSize, styleMask: NSWindow.StyleMask = [.borderless]) -> NSWindow {
        bootstrap()
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size), styleMask: styleMask, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }
}

/// Liga o bootstrap acima em toda suíte do alvo (`@Suite(.offscreenAppKit)`).
nonisolated struct OffscreenAppKitTrait: SuiteTrait, TestScoping {
    func provideScope(for test: Test, testCase: Test.Case?, performing function: @concurrent @Sendable () async throws -> Void) async throws {
        await MainActor.run { OffscreenAppKit.bootstrap() }
        try await function()
    }
}

extension Trait where Self == OffscreenAppKitTrait {
    nonisolated static var offscreenAppKit: Self { Self() }
}
