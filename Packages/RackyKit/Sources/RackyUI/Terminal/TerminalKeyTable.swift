import AppKit

/// Tabela tecla → bytes das teclas reservadas ao terminal (03 §21, AC-T08). O app as intercepta antes do `TerminalView`
/// porque o SwiftTerm não as traduz como um terminal nativo: ⌘← ⌘→ ⌘⌫ viram ^A ^E ^U, ⇧↵ vira CSI-u e ⌥← ⌥→ saltam palavra.
public enum TerminalKeyTable {
    public enum Key: Equatable {
        case leftArrow, rightArrow, delete, `return`
    }

    private static let relevant: NSEvent.ModifierFlags = [.command, .option, .shift, .control]

    public static func bytes(key: Key, modifiers: NSEvent.ModifierFlags) -> [UInt8]? {
        switch (key, modifiers.intersection(relevant)) {
        case (.leftArrow, [.command]): return [0x01]  // ^A: início da linha
        case (.rightArrow, [.command]): return [0x05]  // ^E: fim da linha
        case (.delete, [.command]): return [0x15]  // ^U: apaga até o início da linha
        case (.return, [.shift]): return [0x1b, 0x5b, 0x31, 0x33, 0x3b, 0x32, 0x75]  // CSI 13 ; 2 u (Shift+Enter)
        case (.leftArrow, [.option]): return [0x1b, 0x62]  // ESC b: palavra anterior
        case (.rightArrow, [.option]): return [0x1b, 0x66]  // ESC f: próxima palavra
        default: return nil
        }
    }

    /// Códigos de tecla virtuais do macOS (`kVK_*`) independentes de layout.
    public static func key(forKeyCode code: UInt16) -> Key? {
        switch code {
        case 123: .leftArrow
        case 124: .rightArrow
        case 51: .delete
        case 36, 76: .return
        default: nil
        }
    }

    public static func bytes(for event: NSEvent) -> [UInt8]? {
        guard event.type == .keyDown, let key = key(forKeyCode: event.keyCode) else { return nil }
        return bytes(key: key, modifiers: event.modifierFlags)
    }
}
