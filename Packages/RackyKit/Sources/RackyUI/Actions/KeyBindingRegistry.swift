import RackyProtocol
import Foundation

/// Escopos de atalho (03 §21). `Palette` é escopo próprio, mais específico que `Overlay`.
public enum KeyScope: String, CaseIterable, Sendable, Hashable {
    case global, app, terminal, find, viewer, sidebar, settings, overlay, palette, menu

    /// Em conflito, o escopo mais específico vence (03 §21).
    public var specificity: Int {
        switch self {
        case .global: 0
        case .app: 1
        case .menu: 2
        case .sidebar, .settings, .terminal, .viewer, .find: 3
        case .overlay: 4
        case .palette: 5
        }
    }
}

public enum KeyModifier: String, CaseIterable, Sendable, Hashable {
    case control = "⌃", option = "⌥", shift = "⇧", command = "⌘"
}

/// Tecla com modificadores. `key` em minúsculas (`n`, `1`, `,`) ou nome: `↵ ⇥ ⎋ ⌫ ← → ↑ ↓ space`; vazio = só modificadores.
public struct KeyChord: Hashable, Sendable, CustomStringConvertible {
    public let key: String
    public let modifiers: Set<KeyModifier>

    public init(key: String, modifiers: Set<KeyModifier>) {
        self.key = key.count == 1 ? key.lowercased() : key
        self.modifiers = modifiers
    }

    /// `⇧⌘N` -> chord. Ordem dos glifos livre; o resto é a tecla.
    public init?(_ display: String) {
        var mods = Set<KeyModifier>()
        var rest = Substring(display)
        while let first = rest.first, let m = KeyModifier(rawValue: String(first)) {
            mods.insert(m)
            rest = rest.dropFirst()
        }
        let key = rest.lowercased() == "esc" ? "⎋" : String(rest)
        guard !(key.isEmpty && mods.isEmpty) else { return nil }
        self.init(key: key, modifiers: mods)
    }

    public var description: String {
        let order: [KeyModifier] = [.control, .option, .shift, .command]
        return order.filter(modifiers.contains).map(\.rawValue).joined() + key.uppercased()
    }

    /// Chord reservado ao terminal: ⌃ + letra, ⌥ + letra, ⌘←, ⌘→, ⌘⌫, ⇧↵, ⌥←, ⌥→ (03 §21).
    public nonisolated var isReservedForTerminal: Bool {
        let isLetter = key.count == 1 && key.first?.isLetter == true
        if modifiers == [.control] && isLetter { return true }
        if modifiers == [.option] && isLetter { return true }
        if modifiers == [.command] && ["←", "→", "⌫"].contains(key) { return true }
        if modifiers == [.shift] && key == "↵" { return true }
        if modifiers == [.option] && ["←", "→"].contains(key) { return true }
        return false
    }
}

public struct KeyBinding: Sendable, Hashable {
    public let chord: KeyChord
    public let scope: KeyScope
    public let action: ActionID?
    public let title: String
    /// Escopos que este atalho substitui de propósito (Palette sobre Overlay: 03 §21).
    public let overrides: Set<KeyScope>

    public init(_ display: String, scope: KeyScope, action: ActionID?, title: String, overrides: Set<KeyScope> = []) {
        // Falha cedo: a tabela canônica é código, um glifo inválido é erro de programação visível no teste.
        self.chord = KeyChord(display) ?? KeyChord(key: "?", modifiers: [])
        self.scope = scope
        self.action = action
        self.title = title
        self.overrides = overrides
    }
}

public struct KeyBindingConflict: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Dois atalhos iguais no mesmo escopo.
        case sameScope
        /// Atalho Global igual a um chord reservado ao terminal.
        case reservedByTerminal
        /// Overlay e Palette com o mesmo chord sem declaração de substituição.
        case overlayVersusPalette
    }

    public let kind: Kind
    public let chord: KeyChord
    public let titles: [String]
}

public enum KeyBindingError: Error, Equatable {
    case duplicate(chord: String, scope: KeyScope, existing: String, new: String)
}

/// Registro de atalhos com escopo explícito (08 AR-121, 03 §21). Um teste falha se houver conflito
/// no mesmo escopo, Global contra a lista reservada ao terminal, ou Overlay contra Palette sem declaração.
public struct KeyBindingRegistry: Sendable {
    public private(set) var bindings: [KeyBinding] = []

    public init() {}

    /// Registra e rejeita na hora um atalho duplicado no mesmo escopo.
    public mutating func register(_ binding: KeyBinding) throws {
        if let existing = bindings.first(where: { $0.chord == binding.chord && $0.scope == binding.scope }) {
            throw KeyBindingError.duplicate(
                chord: binding.chord.description, scope: binding.scope, existing: existing.title, new: binding.title)
        }
        bindings.append(binding)
    }

    /// Verifica todas as regras de 03 §21 sobre o conjunto registrado.
    public func conflicts() -> [KeyBindingConflict] {
        var out: [KeyBindingConflict] = []
        for (i, a) in bindings.enumerated() {
            if a.scope == .global, a.chord.isReservedForTerminal {
                out.append(.init(kind: .reservedByTerminal, chord: a.chord, titles: [a.title]))
            }
            for b in bindings[(i + 1)...] where a.chord == b.chord {
                if a.scope == b.scope {
                    out.append(.init(kind: .sameScope, chord: a.chord, titles: [a.title, b.title]))
                } else if let (overlay, palette) = Self.overlayAndPalette(a, b), !palette.overrides.contains(.overlay) {
                    out.append(.init(kind: .overlayVersusPalette, chord: a.chord, titles: [overlay.title, palette.title]))
                }
            }
        }
        return out
    }

    private static func overlayAndPalette(_ a: KeyBinding, _ b: KeyBinding) -> (KeyBinding, KeyBinding)? {
        if a.scope == .overlay && b.scope == .palette { return (a, b) }
        if a.scope == .palette && b.scope == .overlay { return (b, a) }
        return nil
    }

    /// Atalho que vale para `chord` dado os escopos ativos: vence o mais específico.
    public func resolve(_ chord: KeyChord, activeScopes: Set<KeyScope>) -> KeyBinding? {
        bindings
            .filter { $0.chord == chord && activeScopes.contains($0.scope) }
            .max { $0.scope.specificity < $1.scope.specificity }
    }

    public func bindings(for action: ActionID) -> [KeyBinding] { bindings.filter { $0.action == action } }
}
