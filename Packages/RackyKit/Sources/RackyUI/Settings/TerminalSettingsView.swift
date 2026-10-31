import RackyCore
import RackyDesignSystem
import RackyProtocol
import SwiftUI

/// Settings › Terminal (03 §14.2): fonte, tamanho, tema da paleta do dono e cursor, com prévia de 6 linhas.
/// Vale para terminais novos e abertos (`TerminalAppearance(settings:)`), sem reiniciar o app.
struct TerminalSettingsView: View {
    let model: SettingsModel

    private var terminal: AppSettings.Terminal { model.settings.terminal }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionGap) {
            SettingsBlock(title: "Text") {
                SettingsRow(title: "Font", help: "Monospaced fonts installed on this Mac.") {
                    DSCombobox(
                        id: .settings("terminal", "font"), selection: terminal.fontFamily, entries: fontEntries, action: .settingsTerminalFont,
                        searchPlaceholder: String(localized: "Search fonts…", bundle: .module))
                }
                SettingsRow(title: "Size", help: "Points, from 8 to 32.") {
                    SettingsStepper(
                        value: terminal.fontSize, action: .settingsTerminalSize, id: .settings("terminal", "size"),
                        range: AppSettings.Terminal.fontSizeRange)
                }
                SettingsRow(title: "Theme", help: "The color palette of the terminal.") {
                    DSCombobox(
                        id: .settings("terminal", "theme"), selection: terminal.theme, entries: themeEntries, action: .settingsTerminalTheme,
                        searchPlaceholder: String(localized: "Search themes…", bundle: .module))
                }
            }
            SettingsBlock(title: "Cursor") {
                SettingsRow(title: "Cursor", help: "Shape of the cursor.") {
                    DSSegmented(
                        [.init("block", "Block"), .init("bar", "Bar"), .init("underline", "Underline")],
                        selection: terminal.cursor.rawValue, action: .settingsTerminalCursor, id: .settings("terminal", "cursor"))
                }
                SettingsRow(title: "Blink", help: nil) {
                    DSSwitch(isOn: terminal.cursorBlink, action: .settingsTerminalCursorBlink, id: .settings("terminal", "cursorBlink"), "")
                        .accessibilityLabel(Text("Blink", bundle: .module))
                }
            }
            SettingsBlock(title: "Preview") {
                TerminalPreview(settings: terminal)
                Text("Applies to new terminals.", bundle: .module)
                    .dsFont(DS.Font.small)
                    .foregroundStyle(DS.Color.textSecondary)
            }
        }
    }

    private var fontEntries: [DSMenuEntry] {
        AppSettings.Terminal.fontFamilies.map { .item(DSMenuItem($0, $0)) }
    }

    private var themeEntries: [DSMenuEntry] {
        [.item(DSMenuItem(AppSettings.Terminal.defaultTheme, TerminalPreview.themeName))]
    }
}

/// Prévia de 6 linhas com a paleta do dono (02 §3): fundo, texto, ANSI e o cursor escolhido.
struct TerminalPreview: View {
    static let themeName = "Ghostty Default Style Dark"
    let settings: AppSettings.Terminal

    private var font: Font {
        let size = CGFloat(settings.fontSize)
        return settings.fontFamily == AppSettings.Terminal.defaultFont ? .system(size: size, weight: .medium, design: .monospaced) : .custom(settings.fontFamily, size: size)
    }

    private func ansi(_ index: Int) -> Color { DS.Terminal.ansi[index].color }

    var body: some View {
        VStack(alignment: .leading, spacing: .zero) {
            line {
                Text(verbatim: "~/Racky/worktrees/otter").foregroundColor(ansi(4))
                Text(verbatim: " $ ").foregroundColor(DS.Terminal.foreground.color)
                Text(verbatim: "git status").foregroundColor(DS.Terminal.foreground.color)
            }
            line { Text(verbatim: "On branch feat/arizona-pagination").foregroundColor(DS.Terminal.foreground.color) }
            line { Text(verbatim: "  modified:   src/crawler.py").foregroundColor(ansi(1)) }
            line { Text(verbatim: "  new file:   tests/test_paging.py").foregroundColor(ansi(2)) }
            line {
                Text(verbatim: "claude").foregroundColor(ansi(3))
                Text(verbatim: " — ready").foregroundColor(ansi(8))
            }
            HStack(spacing: .zero) {
                Text(verbatim: "$ ").foregroundColor(DS.Terminal.foreground.color)
                cursor
            }
            .font(font)
        }
        .frame(maxWidth: .infinity, minHeight: SettingsMetrics.previewHeight, alignment: .topLeading)
        .padding(DS.Space.s3)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Terminal.background.color))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Color.border, lineWidth: DSMetrics.hairline))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
        .a11y(.settings("terminal", "preview"), kind: "container", label: "Terminal preview")
    }

    private func line(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: .zero) { content() }.font(font).lineLimit(1).truncationMode(.tail)
    }

    @ViewBuilder private var cursor: some View {
        let cell = CGFloat(settings.fontSize) * 0.6
        let height = CGFloat(settings.fontSize) * 1.2
        switch settings.cursor {
        case .block: Rectangle().fill(DS.Terminal.cursor.color).frame(width: cell, height: height)
        case .bar: Rectangle().fill(DS.Terminal.cursor.color).frame(width: DS.Space.s0_5, height: height)
        case .underline: Rectangle().fill(DS.Terminal.cursor.color).frame(width: cell, height: DS.Space.s0_5).frame(height: height, alignment: .bottom)
        }
    }
}
