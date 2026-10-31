import RackyProtocol
import AppKit
import Foundation
import Testing

@testable import RackyUI

/// T1-22: menus do app gerados da tabela canônica (03 §18/§21), AC-T02 (d), AC-T08.
@MainActor
@Suite(.serialized, .offscreenAppKit) struct MainMenuTests {
    private final class Scopes { var value: Set<KeyScope> = [.global, .app] }

    /// Registro com a fatia 3 ligada e só o que o teste registra: o resto fica desabilitado (não registrado).
    private func make(registering: [(ActionID, ActionAvailability)] = [], scopes: Scopes = Scopes()) throws -> (NSMenu, ActionRegistry, Scopes) {
        let registry = ActionRegistry(flags: SliceFlags(current: .slice3, restricted: false), surface: FakeSurface())
        for (id, availability) in registering {
            try registry.register(id, enablement: { availability }) { _ in nil }
        }
        let menu = MainMenu.build(registry: registry, activeScopes: { scopes.value })
        return (menu, registry, scopes)
    }

    private func allItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(allItems) ?? []) }
    }

    private func revalidate(_ menu: NSMenu) {
        for item in allItems(menu) { if let sub = item.submenu { sub.delegate?.menuNeedsUpdate?(sub) } }
    }

    private func actionItems(_ menu: NSMenu) -> [ActionMenuItem] { allItems(menu).compactMap { $0 as? ActionMenuItem } }

    private func chord(_ item: NSMenuItem) -> String? {
        guard !item.keyEquivalent.isEmpty else { return nil }
        return "\(item.keyEquivalentModifierMask.intersection([.command, .option, .shift, .control]).rawValue)|\(item.keyEquivalent)"
    }

    @Test func topLevelMenusFollowTheSpecOrder() throws {
        let (menu, _, _) = try make()
        #expect(menu.items.map(\.title) == ["Racky", "File", "Edit", "View", "Session", "Terminal", "Computer", "Window", "Help"])
    }

    /// Para cada atalho da tabela com escopo de menu: o item existe, aponta para o ActionID certo e mostra o chord.
    @Test func everyMenuScopedShortcutHasAMenuItemBoundToItsAction() throws {
        let (menu, registry, scopes) = try make()
        scopes.value = [.global, .app, .terminal, .find]
        revalidate(menu)
        let keys = try KeyBindingRegistry.canonical()
        let items = actionItems(menu)
        var checked = 0
        for b in keys.bindings where MenuLayout.menuScopes.contains(b.scope) {
            guard let action = b.action else { continue }
            // Esc, ↵ e afins não são key equivalent de menu (nada disso é capturado). ⌃C é reservado: o item existe, sem tecla.
            guard b.chord.menuKeyEquivalent != nil || action == .terminalSendInterrupt else { continue }
            if [ActionID.editCopy, .editPaste, .editSelectAll].contains(action) { continue }  // cadeia de respondedores, teste abaixo
            guard registry.flags.isEnabled(action.spec.slice) else {
                #expect(!items.contains { $0.actionID == action }, "\(action) é de fatia futura e não deve aparecer")
                continue
            }
            let item = items.first { $0.actionID == action && $0.binding == b }
            #expect(item != nil, "falta item de menu para \(b.chord) (\(b.title)) -> \(action)")
            guard let item else { continue }
            checked += 1
            if let pair = b.chord.menuKeyEquivalent {
                // Global que perde para um escopo ativo mais específico (⇧⌘G com a find bar) fica sem tecla.
                guard keys.resolve(b.chord, activeScopes: [.global, .app, .terminal, .find]) == b else {
                    #expect(item.keyEquivalent.isEmpty, "\(b.title) deveria ceder a tecla")
                    continue
                }
                #expect(item.keyEquivalent == pair.key, "\(b.title): tecla")
                #expect(item.keyEquivalentModifierMask == pair.modifiers, "\(b.title): modificadores")
            } else {
                #expect(item.keyEquivalent.isEmpty, "\(b.title) é reservado ao terminal e não pode ter key equivalent")
            }
        }
        #expect(checked >= 60, "\(checked)")
    }

    @Test func editMenuUsesTheResponderChainForSystemShortcuts() throws {
        let (menu, _, _) = try make()
        let edit = try #require(menu.items.first { $0.title == "Edit" }?.submenu)
        for (title, selector, key, mods) in [
            ("Undo", "undo:", "z", NSEvent.ModifierFlags.command), ("Redo", "redo:", "z", [.command, .shift]),
            ("Cut", "cut:", "x", .command), ("Copy", "copy:", "c", .command), ("Paste", "paste:", "v", .command),
            ("Select All", "selectAll:", "a", .command),
        ] {
            let item = try #require(edit.items.first { $0.title == title }, "\(title)")
            #expect(item.action == Selector(selector))
            #expect(item.target == nil)
            #expect(item.keyEquivalent == key)
            #expect(item.keyEquivalentModifierMask == mods)
        }
    }

    @Test func itemsAreEnabledOrDisabledByTheRegistryAvailability() throws {
        let reason = "Open a project first."
        let (menu, registry, _) = try make(registering: [
            (.sessionNew, .enabled), (.tabNewTerminal, .disabled(reason: reason)), (.viewToggleSidebar, .enabled),
        ])
        revalidate(menu)
        let items = actionItems(menu)
        for item in items {
            #expect(item.isEnabled == registry.availability(of: item.actionID).isEnabled, "\(item.title)")
        }
        #expect(items.first { $0.actionID == .sessionNew }?.isEnabled == true)
        let blocked = try #require(items.first { $0.actionID == .tabNewTerminal })
        #expect(!blocked.isEnabled)
        #expect(blocked.toolTip == reason)
        #expect(items.first { $0.actionID == .paneSplitRight }?.isEnabled == false)  // sem handler: desabilitado, não escondido
    }

    @Test func futureSliceItemsAreNotInTheMenu() throws {
        let registry = ActionRegistry(flags: SliceFlags(current: .slice1), surface: FakeSurface())
        let menu = MainMenu.build(registry: registry)
        let ids = Set(actionItems(menu).map(\.actionID))
        #expect(!ids.contains(.viewToggleRightPanel))  // ⌘L: Fatia 2 em diante (03 §21)
        #expect(!ids.contains(.computerTakeOver))
        #expect(ids.contains(.sessionNew))
    }

    @Test func itemsHaveMenuAccessibilityIdentifiers() throws {
        let (menu, _, _) = try make()
        let split = try #require(actionItems(menu).first { $0.actionID == .paneSplitRight })
        #expect(split.accessibilityIdentifier() == "menu.terminal.splitRight")
        let ids = actionItems(menu).map { $0.accessibilityIdentifier() }
        #expect(ids.allSatisfy { $0.hasPrefix("menu.") })
        #expect(Set(ids).count == ids.count, "duplicados: \(Dictionary(grouping: ids, by: { $0 }).filter { $1.count > 1 }.keys.sorted())")
    }

    /// F27 / AC-T02 (d): nenhum item de menu captura tecla reservada ao terminal e dois itens ativos não dividem a tecla.
    @Test func noMenuItemStealsTerminalKeysOrSharesAKey() throws {
        for active: Set<KeyScope> in [[.global, .app], [.global, .app, .terminal], [.global, .app, .terminal, .find]] {
            let (menu, _, scopes) = try make()
            scopes.value = active
            revalidate(menu)
            var seen: [String: String] = [:]
            for item in allItems(menu) where !item.keyEquivalent.isEmpty && item.submenu == nil {
                let mods = item.keyEquivalentModifierMask.intersection([.command, .option, .shift, .control])
                let key = item.keyEquivalent
                // Reconstrói o chord para consultar a lista reservada.
                var m = Set<KeyModifier>()
                if mods.contains(.control) { m.insert(.control) }
                if mods.contains(.option) { m.insert(.option) }
                if mods.contains(.shift) { m.insert(.shift) }
                if mods.contains(.command) { m.insert(.command) }
                let name: String
                switch key {
                case "\r": name = "↵"
                case "\t": name = "⇥"
                case "\u{1b}": name = "⎋"
                case String(UnicodeScalar(NSLeftArrowFunctionKey)!): name = "←"
                case String(UnicodeScalar(NSRightArrowFunctionKey)!): name = "→"
                case String(UnicodeScalar(NSDeleteCharacter)!): name = "⌫"
                default: name = key
                }
                #expect(!KeyChord(key: name, modifiers: m).isReservedForTerminal, "\(item.title) captura \(name) reservado ao terminal")
                #expect(mods.contains(.command) || mods.contains(.control) || mods.contains(.option), "\(item.title): tecla solta")
                let id = chord(item)!
                #expect(seen[id] == nil, "\(item.title) e \(seen[id] ?? "") usam a mesma tecla com escopos \(active)")
                seen[id] = item.title
            }
        }
    }

    @Test func scopedKeysAreRemovedWhenTheirScopeIsInactive() throws {
        let scopes = Scopes()
        let (menu, _, _) = try make(scopes: scopes)
        func item(_ id: ActionID) -> ActionMenuItem? { actionItems(menu).first { $0.actionID == id } }
        revalidate(menu)
        // fora do terminal: ⌘K e ⌘G não têm tecla; ⇧⌘G é Source Control
        #expect(item(.terminalClear)?.keyEquivalent == "")
        #expect(item(.findNext)?.keyEquivalent == "")
        #expect(item(.panelSourceControl)?.keyEquivalent == "g")
        #expect(item(.panelSourceControl)?.keyEquivalentModifierMask == [.shift, .command])
        scopes.value = [.global, .app, .terminal]
        revalidate(menu)
        #expect(item(.terminalClear)?.keyEquivalent == "k")
        #expect(item(.panelSourceControl)?.keyEquivalent == "g")
        // find bar aberta: ⇧⌘G passa a ser Find Previous e Source Control perde a tecla
        scopes.value = [.global, .app, .terminal, .find]
        revalidate(menu)
        #expect(item(.findNext)?.keyEquivalent == "g")
        #expect(item(.findPrevious)?.keyEquivalent == "g")
        #expect(item(.panelSourceControl)?.keyEquivalent == "")
    }

    @Test func sendInterruptAndOtherReservedKeysAreNeverMenuKeyEquivalents() throws {
        let (menu, _, scopes) = try make()
        scopes.value = [.global, .app, .terminal, .find]
        revalidate(menu)
        let interrupt = try #require(actionItems(menu).first { $0.actionID == .terminalSendInterrupt })
        #expect(interrupt.keyEquivalent.isEmpty)
        for display in ["⌃C", "⌥B", "⌘←", "⌘→", "⌘⌫", "⇧↵", "⌥←", "⌥→", "⌃A", "⌃R"] {
            #expect(try #require(KeyChord(display)).menuKeyEquivalent == nil, "\(display)")
        }
        // exceções deliberadas (03 §21) continuam sendo atalhos de menu
        for display in ["⌃⇥", "⌃⇧⇥", "⌃1", "⌃9"] { #expect(try #require(KeyChord(display)).menuKeyEquivalent != nil, "\(display)") }
    }

    @Test func menuDoesNotAddResponders() throws {
        // F27: o menu só lê a cadeia de respondedores; nada nele é first responder nem view de teclado.
        let (menu, _, _) = try make()
        #expect(allItems(menu).allSatisfy { $0.view == nil })
    }

    @Test func canonicalTableGeneratesTheEvidenceFile() throws {
        let (menu, _, _) = try make()
        let keys = try KeyBindingRegistry.canonical()
        #expect(keys.conflicts().isEmpty)
        let markdown = ShortcutsTable.markdown(keys: keys, paths: MainMenu.actionPaths(menu))
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }  // X.swift, UISnapshotTests, Tests, RackyKit, Packages -> raiz
        url = url.appendingPathComponent("docs/shortcuts.md")
        if ProcessInfo.processInfo.environment["RACKY_WRITE_SHORTCUTS"] != nil {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
        }
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        #expect(onDisk == markdown, "tabela desatualizada: rode com RACKY_WRITE_SHORTCUTS=1")
    }
}
