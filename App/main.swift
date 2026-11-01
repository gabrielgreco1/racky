import RackyUI
import AppKit
import Foundation

// Escrita num pipe/socket fechado não pode derrubar o app com SIGPIPE (o rackyd já ignora).
signal(SIGPIPE, SIG_IGN)

// Casca AppKit (00 T5): sem cena SwiftUI; a janela é um NSWindow configurado à mão.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // RACKY_TEST_HEADLESS=1 (testes e evidência): sem Dock, sem janela à frente, sem item na barra de menus, sem notificações do sistema.
    app.setActivationPolicy(ProcessInfo.processInfo.environment["RACKY_TEST_HEADLESS"] == "1" ? .prohibited : .regular)
    app.run()
}
