import RackyProtocol
import AppKit

/// Uma linha dos menus do app (03 §18). Só dados: `MainMenu` transforma em `NSMenuItem`.
enum AppMenuEntry {
    /// Item que dispara uma ação do registro. `chord` escolhe o atalho quando a ação tem mais de um na tabela (§21).
    case action(ActionID, title: String, chord: String? = nil, argument: ActionArgument = .press)
    /// Item padrão do sistema (cadeia de respondedores): Undo, Cut, Copy, Paste, Hide Others... Sem `ActionID`.
    case system(title: String, selector: String, chord: String? = nil)
    case separator
    case submenu(title: String, [AppMenuEntry])
}

struct AppMenuSpec {
    let title: String
    let entries: [AppMenuEntry]
}

/// Quais menus existem e o que há em cada um (03 §18). O atalho de cada item vem do `KeyBindingRegistry`,
/// nunca daqui: a tabela canônica (§21) é a fonte única.
enum MenuLayout {
    static let appMenu = "Racky"

    static func menus() -> [AppMenuSpec] {
        let sessionSelect: [ActionID] = [
            .sessionSelect1, .sessionSelect2, .sessionSelect3, .sessionSelect4, .sessionSelect5,
            .sessionSelect6, .sessionSelect7, .sessionSelect8, .sessionSelect9,
        ]
        let tabSelect: [ActionID] = [
            .tabSelect1, .tabSelect2, .tabSelect3, .tabSelect4, .tabSelect5, .tabSelect6, .tabSelect7, .tabSelect8, .tabSelect9,
        ]
        return [
            AppMenuSpec(
                title: appMenu,
                entries: [
                    .action(.appAbout, title: "About Racky"),
                    .separator,
                    .action(.appSettings, title: "Settings…"),
                    .action(.appSetup, title: "Set Up Racky…"),
                    .separator,
                    .system(title: "Services", selector: "services"),
                    .separator,
                    .action(.appHideAppName, title: "Hide Racky"),
                    .system(title: "Hide Others", selector: "hideOtherApplications:", chord: "⌥⌘H"),
                    .system(title: "Show All", selector: "unhideAllApplications:"),
                    .separator,
                    .action(.appQuit, title: "Quit Racky"),
                ]),
            AppMenuSpec(
                title: "File",
                entries: [
                    .action(.sessionNew, title: "New Session…"),
                    .action(.sessionNewClean, title: "New Clean Session"),
                    .action(.sessionNewCleanInFolder, title: "New Clean Session in Folder…"),
                    .action(.batchNew, title: "New Batch…"),
                    .separator,
                    .action(.tabQuickLaunch, title: "New Tab…"),
                    .action(.tabNewAgent, title: "New Agent Tab"),
                    .action(.tabNewTerminal, title: "New Terminal"),
                    .separator,
                    .action(.projectAdd, title: "Add Project…"),
                    .action(.itemOpenInEditor, title: "Open in Editor"),
                    .action(.itemRevealInFinder, title: "Reveal in Finder"),
                    .separator,
                    .action(.paneClose, title: "Close Pane"),
                    .action(.tabClose, title: "Close Tab"),
                    .action(.tabReopen, title: "Reopen Closed Tab"),
                    .action(.windowClose, title: "Close Window"),
                ]),
            AppMenuSpec(
                title: "Edit",
                entries: [
                    .system(title: "Undo", selector: "undo:", chord: "⌘Z"),
                    .system(title: "Redo", selector: "redo:", chord: "⇧⌘Z"),
                    .separator,
                    .system(title: "Cut", selector: "cut:", chord: "⌘X"),
                    .system(title: "Copy", selector: "copy:", chord: "⌘C"),
                    .system(title: "Paste", selector: "paste:", chord: "⌘V"),
                    .system(title: "Select All", selector: "selectAll:", chord: "⌘A"),
                    .separator,
                    .submenu(
                        title: "Find",
                        [
                            .action(.findOpen, title: "Find…"),
                            .action(.findNext, title: "Find Next", chord: "⌘G"),
                            .action(.findPrevious, title: "Find Previous", chord: "⇧⌘G"),
                        ]),
                    .action(.terminalClear, title: "Clear Terminal"),
                    .separator,
                    .system(title: "Emoji & Symbols", selector: "orderFrontCharacterPalette:"),
                ]),
            AppMenuSpec(
                title: "View",
                entries: [
                    .action(.viewToggleSidebar, title: "Toggle Sidebar"),
                    .action(.viewToggleRightPanel, title: "Toggle Right Panel"),
                    .action(.rightPanelToggle, title: "Toggle All Right Panel Modules"),
                    .action(.rightPanelToggleFiles, title: "Files"),
                    .action(.rightPanelToggleInsights, title: "Insights"),
                    .action(.rightPanelSwap, title: "Swap Right Panel Modules"),
                    .separator,
                    .action(.panelSourceControl, title: "Source Control"),
                    .action(.panelChecks, title: "Checks"),
                    .action(.panelComputers, title: "Computers Panel"),
                    .action(.panelConversations, title: "Conversations"),
                    .action(.panelContext, title: "Context"),
                    .separator,
                    .action(.pageSessions, title: "Sessions"),
                    .action(.pageLibrary, title: "Library"),
                    .action(.pageComputers, title: "Computers"),
                    .separator,
                    .action(.terminalFontBigger, title: "Bigger"),
                    .action(.terminalFontSmaller, title: "Smaller"),
                    .action(.terminalFontReset, title: "Actual Size"),
                    .separator,
                    .system(title: "Enter Full Screen", selector: "toggleFullScreen:", chord: "⌃⌘F"),
                ]),
            AppMenuSpec(
                title: "Session",
                entries: [
                    .action(.paletteOpen, title: "Jump To…"),
                    .action(.sessionNextNeedingAttention, title: "Next Needing Attention"),
                    .action(.sessionPrevious, title: "Previous Session"),
                    .action(.sessionNext, title: "Next Session"),
                    .submenu(
                        title: "Select Session",
                        sessionSelect.enumerated().map { .action($1, title: "Select Session \($0 + 1)") }),
                    .action(.navBack, title: "Back"),
                    .action(.navForward, title: "Forward"),
                    .action(.sidebarFocus, title: "Focus Session List"),
                    .separator,
                    .action(.sessionRename, title: "Rename Session…"),
                    .action(.sessionEditNote, title: "Edit Note…"),
                    .action(.sessionMarkRead, title: "Mark as Read"),
                    .action(.sessionResumeAgents, title: "Resume Agents…"),
                    .action(.sessionMoveToProject, title: "Move to Project…"),
                    .action(.sessionConvertToProject, title: "Convert to Project…"),
                    .separator,
                    .action(.sessionArchive, title: "Archive Session…"),
                    .action(.sessionDelete, title: "Delete Session…"),
                ]),
            AppMenuSpec(
                title: "Terminal",
                entries: [
                    .action(.paneSplitRight, title: "Split Right"),
                    .action(.paneSplitDown, title: "Split Down"),
                    .separator,
                    .action(.paneNext, title: "Next Pane"),
                    .action(.panePrevious, title: "Previous Pane"),
                    .action(.paneToggleExpand, title: "Expand Pane"),
                    .action(.paneEqualize, title: "Equalize Pane Sizes"),
                    .separator,
                    .action(.tabNext, title: "Next Tab"),
                    .action(.tabPrevious, title: "Previous Tab"),
                    .action(.tabRecent, title: "Recent Tab", chord: "⌃⇥"),
                    .action(.tabRecent, title: "Recent Tab (Reverse)", chord: "⌃⇧⇥", argument: .select("reverse")),
                    .submenu(
                        title: "Select Tab",
                        tabSelect.enumerated().map { .action($1, title: "Select Tab \($0 + 1)") }),
                    .action(.tabRename, title: "Rename Tab…"),
                    .separator,
                    .action(.terminalRestart, title: "Restart"),
                    .action(.terminalResume, title: "Resume Conversation"),
                    .action(.terminalCopyResumeCommand, title: "Copy Resume Command"),
                    .separator,
                    .action(.terminalSendInterrupt, title: "Send Interrupt (⌃C)"),
                    .action(.terminalForceQuit, title: "Force Quit…"),
                ]),
            AppMenuSpec(
                title: "Computer",
                entries: [
                    .action(.computerOpenViewer, title: "Open Viewer"),
                    .action(.computerPopOut, title: "Open in New Window"),
                    .action(.computerTakeOver, title: "Take Over / Hand Back"),
                    .action(.computerReleaseKeyboard, title: "Release Keyboard"),
                    .separator,
                    .action(.computerPaste, title: "Paste to Computer"),
                    .action(.computerCopySelection, title: "Copy Selection from Computer"),
                    .separator,
                    .action(.computerStop, title: "Stop Computer…"),
                ]),
            AppMenuSpec(
                title: "Window",
                entries: [
                    .system(title: "Minimize", selector: "performMiniaturize:", chord: "⌘M"),
                    .system(title: "Zoom", selector: "performZoom:"),
                    .separator,
                    .system(title: "Bring All to Front", selector: "arrangeInFront:"),
                ]),
            AppMenuSpec(
                title: "Help",
                entries: [
                    .action(.helpOpen, title: "Racky Help"),
                    .action(.helpShortcuts, title: "Keyboard Shortcuts"),
                    .action(.appSetup, title: "Run Diagnostics"),
                    .action(.helpRevealLogs, title: "Reveal Logs in Finder"),
                    .action(.helpExportDiagnostics, title: "Export Diagnostics…"),
                ]),
        ]
    }

    /// Escopos que um item de menu pode usar para o atalho, do mais comum ao mais restrito.
    static let menuScopes: [KeyScope] = [.global, .app, .find, .terminal]
}

extension KeyChord {
    /// Tecla e modificadores no formato de `NSMenuItem`. `nil` para o que um menu nunca deve capturar:
    /// tecla sem ⌘/⌃/⌥ (↵, ⎋, ⇥, setas, letras soltas) e chord só de modificadores (F27: nada de roubar tecla do terminal).
    nonisolated var menuKeyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags)? {
        guard !key.isEmpty, modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option) else { return nil }
        // ⌃ + letra, ⌥ + letra, ⌘←/→/⌫, ⇧↵, ⌥←/→ pertencem ao PTY (03 §21): nunca viram key equivalent de menu.
        guard !isReservedForTerminal else { return nil }
        var flags: NSEvent.ModifierFlags = []
        for m in modifiers {
            switch m {
            case .control: flags.insert(.control)
            case .option: flags.insert(.option)
            case .shift: flags.insert(.shift)
            case .command: flags.insert(.command)
            }
        }
        func fn(_ code: Int) -> String { String(UnicodeScalar(code)!) }
        let shifted = modifiers.contains(.shift)
        let ns: String
        switch key {
        case "↵": ns = "\r"
        case "⇥": ns = "\t"
        case "⎋": ns = "\u{1b}"
        case "⌫": ns = fn(NSDeleteCharacter)
        case "←": ns = fn(NSLeftArrowFunctionKey)
        case "→": ns = fn(NSRightArrowFunctionKey)
        case "↑": ns = fn(NSUpArrowFunctionKey)
        case "↓": ns = fn(NSDownArrowFunctionKey)
        case "space": ns = " "
        case "]": ns = shifted ? "}" : "]"
        case "[": ns = shifted ? "{" : "["
        default: ns = key
        }
        return (ns, flags)
    }
}
