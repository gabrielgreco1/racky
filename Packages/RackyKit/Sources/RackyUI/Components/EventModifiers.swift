import AppKit

/// Modificadores do evento que disparou a ação (clique, tecla), não do teclado inteiro: `NSEvent.modifierFlags` é o estado
/// global, então um ⌘/⌥ segurado por acaso (ou por outro app) mudava ações vindas do ctl, de atalhos ou dos testes.
@MainActor
enum EventModifiers {
    static func held(_ flag: NSEvent.ModifierFlags) -> Bool {
        guard let event = NSApp?.currentEvent else { return false }
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .keyDown, .keyUp:
            return event.modifierFlags.contains(flag)
        default:
            return false
        }
    }
}
