import RackyProtocol

extension KeyBindingRegistry {
    /// Tabela canônica de atalhos (03 §21), uma entrada por linha da tabela. Sem ação = atalho de sistema
    /// ou de campo de texto que o registro só conhece para detectar colisão.
    public static func canonical() throws -> KeyBindingRegistry {
        var r = KeyBindingRegistry()
        func add(_ chord: String, _ scope: KeyScope, _ action: ActionID?, _ title: String, overrides: Set<KeyScope> = []) throws {
            try r.register(KeyBinding(chord, scope: scope, action: action, title: title, overrides: overrides))
        }

        // App
        try add("⌘,", .global, .appSettings, "Settings")
        try add("⌘/", .global, .helpShortcuts, "Keyboard Shortcuts")
        try add("⌘Q", .global, .appQuit, "Quit")
        try add("⌘H", .global, .appHideAppName, "Hide")
        try add("⌥⌘H", .global, nil, "Hide Others")

        // Sessions
        try add("⌘N", .global, .sessionNew, "New Session")
        try add("⇧⌘N", .global, .sessionNewClean, "New Clean Session")
        try add("⌥⇧⌘N", .global, .sessionNewCleanInFolder, "New Clean Session in Folder")
        try add("⌘J", .global, .paletteOpen, "Jump To")
        try add("⇧⌘A", .global, .sessionNextNeedingAttention, "Next Needing Attention")
        let sessionSelect: [ActionID] = [
            .sessionSelect1, .sessionSelect2, .sessionSelect3, .sessionSelect4, .sessionSelect5,
            .sessionSelect6, .sessionSelect7, .sessionSelect8, .sessionSelect9,
        ]
        let tabSelect: [ActionID] = [
            .tabSelect1, .tabSelect2, .tabSelect3, .tabSelect4, .tabSelect5,
            .tabSelect6, .tabSelect7, .tabSelect8, .tabSelect9,
        ]
        for (i, a) in sessionSelect.enumerated() { try add("⌘\(i + 1)", .global, a, "Select Session \(i + 1)") }
        try add("⇧⌘↑", .global, .sessionPrevious, "Previous Session")
        try add("⇧⌘↓", .global, .sessionNext, "Next Session")
        try add("⌥⌘←", .global, .navBack, "Back")
        try add("⌥⌘→", .global, .navForward, "Forward")
        try add("⇧⌘0", .global, .sidebarFocus, "Focus Session List")
        try add("⌥⌘R", .global, .sessionRename, "Rename Session")
        try add("⇧⌘⌫", .app, .sessionDelete, "Delete Session")
        try add("⇧⌘⌫", .sidebar, .sessionDelete, "Delete Session")
        try add("⇧⌘O", .global, .itemOpenInEditor, "Open in Editor")

        // Tabs
        try add("⌥⌘N", .global, .tabQuickLaunch, "New Tab")
        try add("⌥⌘T", .global, .tabNewAgent, "New Agent Tab")
        try add("⌘T", .global, .tabNewTerminal, "New Terminal")
        try add("⌘W", .global, .paneClose, "Close Pane / Tab")
        try add("⇧⌘T", .global, .tabReopen, "Reopen Closed Tab")
        try add("⇧⌘W", .global, .windowClose, "Close Window")
        try add("⇧⌘]", .global, .tabNext, "Next Tab")
        try add("⇧⌘[", .global, .tabPrevious, "Previous Tab")
        try add("⌃⇥", .global, .tabRecent, "Recent Tab")
        try add("⌃⇧⇥", .global, .tabRecent, "Recent Tab (reverse)")
        for (i, a) in tabSelect.enumerated() { try add("⌃\(i + 1)", .global, a, "Select Tab \(i + 1)") }
        try add("⌘R", .global, .tabRename, "Rename Tab")

        // Panes
        try add("⌘D", .global, .paneSplitRight, "Split Right")
        try add("⇧⌘D", .global, .paneSplitDown, "Split Down")
        try add("⌘]", .global, .paneNext, "Next Pane")
        try add("⌘[", .global, .panePrevious, "Previous Pane")
        try add("⇧⌘↵", .global, .paneToggleExpand, "Expand / Collapse Pane")

        // Find (⌘F é roteado pelo contexto; o app intercepta antes do PTY)
        try add("⌘F", .global, .findOpen, "Find")
        try add("⌘G", .find, .findNext, "Find Next")
        try add("⇧⌘G", .find, .findPrevious, "Find Previous")
        try add("↵", .find, .findNext, "Find Next (Return)")
        try add("⇧↵", .find, .findPrevious, "Find Previous (Shift Return)")
        try add("⎋", .find, .findClose, "Close Find")

        // Terminal
        try add("⌘K", .terminal, .terminalClear, "Clear")
        try add("⌘C", .terminal, .editCopy, "Copy")
        try add("⌘V", .terminal, .editPaste, "Paste")
        try add("⌘A", .terminal, .editSelectAll, "Select All")
        try add("⌃C", .terminal, .terminalSendInterrupt, "Send Interrupt")
        try add("⌘=", .terminal, .terminalFontBigger, "Font Bigger")
        try add("⌘-", .terminal, .terminalFontSmaller, "Font Smaller")
        try add("⌘0", .terminal, .terminalFontReset, "Font Reset")

        // Panels e pages
        try add("⌘B", .global, .viewToggleSidebar, "Toggle Sidebar")
        try add("⌘L", .global, .viewToggleRightPanel, "Toggle Right Panel")
        try add("⌥⌘1", .global, .rightPanelToggleFiles, "Toggle Files")
        try add("⌥⌘2", .global, .rightPanelToggleInsights, "Toggle Insights")
        try add("⌥⌘0", .global, .rightPanelToggle, "Toggle Right Panel (all modules)")
        try add("⇧⌘G", .global, .panelSourceControl, "Source Control")
        try add("⇧⌘C", .global, .panelComputers, "Computers panel")
        try add("⇧⌘H", .global, .panelConversations, "Conversations")
        try add("⇧⌘I", .global, .pageSessions, "Sessions")
        try add("⇧⌘L", .global, .pageLibrary, "Library")
        try add("⎋", .app, .pageClose, "Close page")

        // Computer
        try add("⇧⌘R", .global, .computerTakeOver, "Take Over / Hand Back")
        try add("⇧⌘R", .viewer, .computerTakeOver, "Take Over / Hand Back (viewer)")
        try add("⌘⎋", .viewer, .computerReleaseKeyboard, "Release Keyboard")
        try add("⌃⌥", .viewer, .computerReleaseKeyboard, "Release Keyboard (modifiers)")
        try add("⌘W", .viewer, .tabClose, "Close Viewer Tab")
        try add("⌘C", .viewer, .computerCopySelection, "Copy (inside computer)")
        try add("⌘V", .viewer, .computerPaste, "Paste to Computer")

        // Overlay e Palette (Palette substitui Overlay em ⌘↵ e ⇥, 03 §21)
        try add("⌘↵", .overlay, .composerSubmit, "Submit")
        try add("⎋", .overlay, .composerCancel, "Cancel / Close")
        try add("⇥", .overlay, nil, "Next field")
        try add("⇧⇥", .overlay, nil, "Previous field")
        try add("⇧↵", .palette, .paletteOpenInSplit, "Open in Split")
        try add("⌘↵", .palette, .paletteNewSessionWithText, "New Session with text", overrides: [.overlay])
        try add("⇥", .palette, .paletteCycleFilter, "Cycle filter", overrides: [.overlay])
        try add("↵", .palette, .paletteOpenRow, "Open Row")
        try add("/", .palette, .paletteInsertMode, "Insert mode")

        // Sidebar
        try add("↑", .sidebar, nil, "Move up")
        try add("↓", .sidebar, nil, "Move down")
        try add("→", .sidebar, .sidebarProjectToggle, "Expand")
        try add("←", .sidebar, .sidebarProjectToggle, "Collapse")
        try add("↵", .sidebar, nil, "Focus terminal of item")
        try add("space", .sidebar, nil, "Show details")

        // Edição padrão do sistema (menu Edit, 03 §18): cadeia de respondedores, o app não os trata
        try add("⌘Z", .app, nil, "Undo")
        try add("⇧⌘Z", .app, nil, "Redo")
        try add("⌘X", .app, nil, "Cut")

        // Window e Debug
        try add("⌘M", .global, nil, "Minimize")
        try add("⌃⌘F", .global, nil, "Full Screen")
        try add("⌃⌥⌘M", .global, nil, "Motion Lab")
        return r
    }
}
