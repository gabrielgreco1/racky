import RackyProtocol
import Testing

@testable import RackyUI

@MainActor
@Suite(.offscreenAppKit) struct KeyBindingRegistryTests {
    /// AC-T03: um teste falha se a tabela canônica de 03 §21 tem atalho duplicado no mesmo escopo,
    /// Global contra a lista reservada ao terminal, ou Overlay contra Palette sem declaração.
    @Test func canonicalTableHasNoConflicts() throws {
        let r = try KeyBindingRegistry.canonical()
        #expect(r.conflicts().isEmpty, "\(r.conflicts())")
        #expect(r.bindings.count >= 90)
        #expect(!r.bindings.contains { $0.chord.key == "?" }, "glifo de atalho inválido na tabela canônica")
    }

    @Test func everyBoundActionExistsInTheActionTable() throws {
        let r = try KeyBindingRegistry.canonical()
        for b in r.bindings {
            if let a = b.action { #expect(ActionID(rawValue: a.rawValue) != nil) }
        }
    }

    @Test func canonicalShortcutsMatchTheActionTableColumn() throws {
        let r = try KeyBindingRegistry.canonical()
        for (action, chord) in [
            (ActionID.sessionNew, "⌘N"), (.sessionNewClean, "⇧⌘N"), (.sessionNewCleanInFolder, "⌥⇧⌘N"), (.paletteOpen, "⌘J"),
            (.tabQuickLaunch, "⌥⌘N"), (.tabNewAgent, "⌥⌘T"), (.tabNewTerminal, "⌘T"), (.paneSplitRight, "⌘D"),
            (.viewToggleSidebar, "⌘B"), (.appQuit, "⌘Q"), (.appSettings, "⌘,"),
        ] {
            let found = r.bindings(for: action).map(\.chord.description)
            #expect(found.contains(KeyChord(chord)?.description ?? "?"), "\(action) esperava \(chord), tem \(found)")
            #expect(action.spec.shortcut == chord, "coluna Atalho de \(action)")
        }
    }

    @Test func duplicateInTheSameScopeIsRejectedAtRegistration() throws {
        var r = KeyBindingRegistry()
        try r.register(KeyBinding("⌘N", scope: .global, action: .sessionNew, title: "New Session"))
        #expect(throws: KeyBindingError.self) {
            try r.register(KeyBinding("⌘N", scope: .global, action: .sessionNewClean, title: "Other"))
        }
        // mesmo chord em escopo diferente é permitido (o mais específico vence)
        try r.register(KeyBinding("⌘N", scope: .overlay, action: nil, title: "Field"))
    }

    @Test func globalAgainstTheTerminalReservedListIsReported() throws {
        var r = KeyBindingRegistry()
        try r.register(KeyBinding("⌃C", scope: .global, action: nil, title: "bad"))
        try r.register(KeyBinding("⌥B", scope: .global, action: nil, title: "bad option letter"))
        try r.register(KeyBinding("⌘←", scope: .global, action: nil, title: "bad line start"))
        try r.register(KeyBinding("⇧↵", scope: .global, action: nil, title: "bad csi-u"))
        let kinds = r.conflicts().map(\.kind)
        #expect(kinds.count == 4)
        #expect(kinds.allSatisfy { $0 == .reservedByTerminal })
    }

    @Test func deliberateGlobalExceptionsToTheTerminalAreNotConflicts() throws {
        var r = KeyBindingRegistry()
        try r.register(KeyBinding("⌃⇥", scope: .global, action: .tabRecent, title: "Recent Tab"))
        try r.register(KeyBinding("⌃⇧⇥", scope: .global, action: .tabRecent, title: "Recent Tab reverse"))
        try r.register(KeyBinding("⌃1", scope: .global, action: .tabSelect1, title: "Tab 1"))
        try r.register(KeyBinding("⌃C", scope: .terminal, action: .terminalSendInterrupt, title: "Interrupt"))
        #expect(r.conflicts().isEmpty)
    }

    @Test func overlayVersusPaletteNeedsADeclaredOverride() throws {
        var bad = KeyBindingRegistry()
        try bad.register(KeyBinding("⌘↵", scope: .overlay, action: .composerSubmit, title: "Submit"))
        try bad.register(KeyBinding("⌘↵", scope: .palette, action: .paletteNewSessionWithText, title: "New with text"))
        #expect(bad.conflicts().map(\.kind) == [.overlayVersusPalette])

        var ok = KeyBindingRegistry()
        try ok.register(KeyBinding("⌘↵", scope: .overlay, action: .composerSubmit, title: "Submit"))
        try ok.register(KeyBinding("⌘↵", scope: .palette, action: .paletteNewSessionWithText, title: "New with text", overrides: [.overlay]))
        #expect(ok.conflicts().isEmpty)
    }

    @Test func resolveUsesTheMostSpecificActiveScope() throws {
        let r = try KeyBindingRegistry.canonical()
        let cmdEnter = try #require(KeyChord("⌘↵"))
        #expect(r.resolve(cmdEnter, activeScopes: [.global, .overlay])?.action == .composerSubmit)
        #expect(r.resolve(cmdEnter, activeScopes: [.global, .overlay, .palette])?.action == .paletteNewSessionWithText)
        let cmdW = try #require(KeyChord("⌘W"))
        #expect(r.resolve(cmdW, activeScopes: [.global])?.action == .paneClose)
        #expect(r.resolve(cmdW, activeScopes: [.global, .viewer])?.action == .tabClose)
        let ctrlC = try #require(KeyChord("⌃C"))
        #expect(r.resolve(ctrlC, activeScopes: [.global]) == nil)  // vai ao PTY
        #expect(r.resolve(ctrlC, activeScopes: [.global, .terminal])?.action == .terminalSendInterrupt)
    }

    @Test func chordParsing() throws {
        let c = try #require(KeyChord("⇧⌘N"))
        #expect(c.key == "n")
        #expect(c.modifiers == [.shift, .command])
        #expect(c.description == "⇧⌘N")
        #expect(KeyChord("⌥⌘N") == KeyChord(key: "N", modifiers: [.command, .option]))
        #expect(KeyChord("esc")?.key == "⎋")
        #expect(KeyChord("⌃⌥")?.key == "")
        #expect(KeyChord("") == nil)
    }
}
