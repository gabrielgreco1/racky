import RackyCore
import RackyDesignSystem
import AppKit
import Carbon.HIToolbox
import SwiftTerm

/// Aparência do terminal (02 §3). Os valores padrão vêm dos tokens; Settings › Terminal sobrescreve depois (T1-26).
public struct TerminalAppearance: Equatable {
    public var fontSize: CGFloat
    public var padding: CGFloat
    public var scrollback: Int
    /// `Option as Meta` (02 §3). `auto` decide pelo layout de teclado.
    public var optionAsMeta: OptionAsMeta
    /// Família escolhida em Settings › Terminal; `SF Mono` = fonte do sistema (padrão).
    public var fontFamily: String
    public var cursor: AppSettings.CursorStyle
    public var cursorBlink: Bool

    public init(
        fontSize: CGFloat = DS.TerminalFont.defaultSize, padding: CGFloat = DS.TerminalFont.padding, scrollback: Int = 5000,
        optionAsMeta: OptionAsMeta = .auto, fontFamily: String = AppSettings.Terminal.defaultFont,
        cursor: AppSettings.CursorStyle = .block, cursorBlink: Bool = true
    ) {
        self.fontFamily = fontFamily
        self.cursor = cursor
        self.cursorBlink = cursorBlink
        self.fontSize = Self.clamp(fontSize)
        self.padding = padding
        self.scrollback = scrollback
        self.optionAsMeta = optionAsMeta
    }

    /// Aparência a partir de Settings › Terminal: o que o usuário mudou vale para o terminal que abrir (e os abertos, ao reaplicar).
    public init(settings: AppSettings.Terminal) {
        self.init(fontSize: CGFloat(settings.fontSize), fontFamily: settings.fontFamily, cursor: settings.cursor, cursorBlink: settings.cursorBlink)
    }

    public static func clamp(_ size: CGFloat) -> CGFloat {
        min(max(size, DS.TerminalFont.sizeMin), DS.TerminalFont.sizeMax)
    }

    /// SF Mono Medium (500); o negrito (700) é derivado pela view. Line height 1.0 = altura natural da célula.
    public var font: NSFont {
        if fontFamily != AppSettings.Terminal.defaultFont, let custom = NSFont(name: fontFamily, size: fontSize) { return custom }
        return NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
    }

    /// Parâmetro de DECSCUSR (`CSI n SP q`): 1 bloco piscando (padrão), 2 bloco fixo, 3/4 sublinhado, 5/6 barra.
    var decscusr: Int {
        let base = switch cursor {
        case .block: 1
        case .underline: 3
        case .bar: 5
        }
        return cursorBlink ? base : base + 1
    }
}

public enum OptionAsMeta: String, CaseIterable, Sendable {
    case auto, left, right, always, never

    /// `Auto`: Option vira Meta nos layouts latinos sem composição por Option (US, ABC, Dvorak, Colemak...); em
    /// layouts onde Option compõe caracteres (ABNT2, ISO europeus) a tecla fica com o sistema.
    public func resolves(layoutID: String?) -> Bool {
        switch self {
        case .always: return true
        case .never: return false
        case .left, .right: return true  // SwiftTerm só distingue ligado/desligado; lado exato fica para o endurecimento
        case .auto:
            guard let id = layoutID?.lowercased() else { return true }
            let metaFriendly = ["keylayout.us", "keylayout.abc", "keylayout.dvorak", "keylayout.colemak", "keylayout.usextended"]
            return metaFriendly.contains { id.contains($0) }
        }
    }
}

/// Aplica o tema de 02 §3 numa view do SwiftTerm: paleta ANSI do dono, fundo, texto, cursor, seleção e fonte.
public enum TerminalTheme {
    static func swiftTermColor(_ c: DSRGBA) -> SwiftTerm.Color {
        SwiftTerm.Color(
            red8: UInt16((c.red * 255).rounded()), green8: UInt16((c.green * 255).rounded()), blue8: UInt16((c.blue * 255).rounded()))
    }

    /// Paleta de 16 cores (índices 0-7 normais, 8-15 bright).
    public static var ansiPalette: [SwiftTerm.Color] { DS.Terminal.ansi.map(swiftTermColor) }

    @MainActor
    public static func apply(to view: TerminalView, appearance: TerminalAppearance) {
        view.installColors(ansiPalette)
        view.nativeBackgroundColor = DS.Terminal.background.nsColor
        view.nativeForegroundColor = DS.Terminal.foreground.nsColor
        view.caretColor = DS.Terminal.cursor.nsColor
        view.caretTextColor = DS.Terminal.cursorText.nsColor
        view.selectedTextBackgroundColor = DS.Terminal.selectionBackground.nsColor
        view.font = appearance.font
        // Cursor inicial: o emulador do SwiftTerm só o expõe por DECSCUSR. É estado de exibição; nada vai ao PTY.
        if appearance.decscusr != 1 { view.feed(byteArray: ArraySlice(Array("\u{1b}[\(appearance.decscusr) q".utf8))) }
        view.optionAsMetaKey = appearance.optionAsMeta.resolves(layoutID: TerminalKeyboardLayout.currentID())
    }
}

enum TerminalKeyboardLayout {
    static func currentID() -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
        else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
}
