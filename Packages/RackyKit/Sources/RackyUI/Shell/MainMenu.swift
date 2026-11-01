import RackyProtocol
import AppKit

/// Item de menu que dispara uma ação do registro (08 AR-805): estado e motivo vêm de `availability`.
nonisolated final class ActionMenuItem: NSMenuItem {
    let actionID: ActionID
    let argument: ActionArgument
    private weak var registry: ActionRegistry?

    /// Atalho da tabela canônica (03 §21) que este item mostra; `nil` = sem atalho.
    let binding: KeyBinding?

    nonisolated init(
        _ id: ActionID, title: String, key: String, modifiers: NSEvent.ModifierFlags = [.command], argument: ActionArgument = .press,
        binding: KeyBinding? = nil, registry: ActionRegistry
    ) {
        actionID = id
        self.argument = argument
        self.registry = registry
        self.binding = binding
        super.init(title: title, action: #selector(fire(_:)), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
    }

    /// Liga ou remove o key equivalent (escopo inativo = a tecla segue para o terminal, 03 §21).
    nonisolated func setShortcut(active: Bool) {
        guard let pair = binding?.chord.menuKeyEquivalent else { return }
        keyEquivalent = active ? pair.key : ""
        keyEquivalentModifierMask = active ? pair.modifiers : []
    }

    @available(*, unavailable) required nonisolated init(coder: NSCoder) { fatalError("init(coder:) is not used") }  // required init?(coder:) não usado

    @objc nonisolated private func fire(_ sender: Any?) {
        guard let registry else { return }
        let id = actionID, argument = argument
        Task { @MainActor in _ = try? await registry.perform(id, argument) }
    }

    nonisolated override var isEnabled: Bool {
        get {
            let registry = self.registry, id = actionID
            return MainActor.assumeIsolated { registry?.availability(of: id).isEnabled ?? false }
        }
        set {}
    }
}

/// Valida os key equivalents quando o menu abre ou é consultado por uma tecla: item cujo escopo não está ativo
/// (ou que perde para um atalho mais específico, ex.: ⇧⌘G com a find bar aberta) fica sem tecla e o evento segue o fluxo normal.
@MainActor
final class MenuKeyValidator: NSObject, NSMenuDelegate {
    let keys: KeyBindingRegistry
    let registry: ActionRegistry
    let activeScopes: @MainActor () -> Set<KeyScope>

    init(keys: KeyBindingRegistry, registry: ActionRegistry, activeScopes: @escaping @MainActor () -> Set<KeyScope>) {
        self.keys = keys
        self.registry = registry
        self.activeScopes = activeScopes
    }

    func menuNeedsUpdate(_ menu: NSMenu) { validate(menu) }

    func validate(_ menu: NSMenu, scopes: Set<KeyScope>? = nil) {
        let scopes = scopes ?? activeScopes()
        for case let item as ActionMenuItem in menu.items {
            if let binding = item.binding {
                item.setShortcut(active: keys.resolve(binding.chord, activeScopes: scopes) == binding)
            }
            if case .disabled(let reason) = registry.availability(of: item.actionID) { item.toolTip = reason } else { item.toolTip = nil }
        }
        for sub in menu.items.compactMap(\.submenu) { validate(sub, scopes: scopes) }
    }
}

/// Escopos ativos agora, só lendo a cadeia de respondedores (nunca vira first responder, F27).
@MainActor
enum MenuScopeProbe {
    static func current() -> Set<KeyScope> {
        var scopes: Set<KeyScope> = [.global, .app]
        var responder = NSApp.keyWindow?.firstResponder
        while let r = responder {
            if let terminal = r as? TerminalHostView {
                scopes.insert(.terminal)
                if terminal.findModel.isOpen { scopes.insert(.find) }
                break
            }
            responder = r.nextResponder
        }
        return scopes
    }
}

/// Menus do app (03 §18), gerados de `MenuLayout` + `KeyBindingRegistry` + `ActionRegistry`.
/// Só entram ações da fatia entregue; sem handler ou sem pré-condição o item fica desabilitado (nunca escondido).
@MainActor
enum MainMenu {
    private static var validator: MenuKeyValidator?

    static func build(
        registry: ActionRegistry, keys: KeyBindingRegistry? = nil,
        activeScopes: @escaping @MainActor () -> Set<KeyScope> = MenuScopeProbe.current
    ) -> NSMenu {
        let keys = keys ?? ((try? KeyBindingRegistry.canonical()) ?? KeyBindingRegistry())
        let validator = MenuKeyValidator(keys: keys, registry: registry, activeScopes: activeScopes)
        Self.validator = validator
        let main = NSMenu()
        var ids = Set<String>()
        for spec in MenuLayout.menus() {
            let menu = NSMenu(title: spec.title)
            fill(menu, spec.entries, group: spec.title, registry: registry, keys: keys, ids: &ids)
            menu.delegate = validator
            // lint-ui: allow buttons contêiner de submenu (não é gatilho)
            let item = NSMenuItem(title: spec.title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
            switch spec.title {
            case "Window": NSApp.windowsMenu = menu
            case "Help": NSApp.helpMenu = menu
            default: break
            }
        }
        validator.validate(main, scopes: [.global, .app])
        return main
    }

    private static func fill(
        _ menu: NSMenu, _ entries: [AppMenuEntry], group: String, registry: ActionRegistry, keys: KeyBindingRegistry, ids: inout Set<String>
    ) {
        for entry in entries {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case .submenu(let title, let inner):
                let sub = NSMenu(title: title)
                fill(sub, inner, group: group, registry: registry, keys: keys, ids: &ids)
                sub.delegate = validator
                // lint-ui: allow buttons contêiner de submenu (não é gatilho)
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.submenu = sub
                if !sub.items.isEmpty { menu.addItem(item) }
            case .system(let title, let selector, let chord):
                if selector == "services" {
                    let services = NSMenu(title: title)
                    // lint-ui: allow buttons contêiner de submenu (não é gatilho)
                    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    item.submenu = services
                    NSApp.servicesMenu = services
                    menu.addItem(item)
                    continue
                }
                // lint-ui: allow buttons seletor padrão do sistema (sem ação de produto)
                let item = NSMenuItem(title: title, action: Selector(selector), keyEquivalent: "")
                if let pair = chord.flatMap(KeyChord.init)?.menuKeyEquivalent {
                    item.keyEquivalent = pair.key
                    item.keyEquivalentModifierMask = pair.modifiers
                }
                menu.addItem(item)
            case .action(let id, let title, let chord, let argument):
                guard registry.flags.isEnabled(id.spec.slice) else { continue }  // versão futura não aparece (03 §18)
                let binding = binding(for: id, chord: chord, keys: keys)
                let item = ActionMenuItem(id, title: title, key: "", modifiers: [], argument: argument, binding: binding, registry: registry)
                item.setShortcut(active: binding.map { MenuLayout.menuScopes.contains($0.scope) } ?? false)
                var name = id.rawValue.split(separator: ".").last.map(String.init) ?? id.rawValue
                if argument.kind == .select, let v = argument.value { name += v.prefix(1).uppercased() + v.dropFirst() }
                let groupID = group.replacingOccurrences(of: " ", with: "")
                let groupName = groupID.prefix(1).lowercased() + groupID.dropFirst()
                var identifier = A11yID.menu(groupName, name).rawValue
                // `pane.close` e `tab.close` dariam o mesmo sufixo: o ActionID inteiro desempata.
                if !ids.insert(identifier).inserted {
                    identifier = A11yID.menu(groupName, id.rawValue + (argument.kind == .select ? "-" + (argument.value ?? "") : "")).rawValue
                    ids.insert(identifier)
                }
                item.setAccessibilityIdentifier(identifier)
                menu.addItem(item)
            }
        }
    }

    /// Atalho do item na tabela canônica: o chord pedido, ou o primeiro de escopo de menu.
    static func binding(for id: ActionID, chord: String?, keys: KeyBindingRegistry) -> KeyBinding? {
        let candidates = keys.bindings(for: id).filter { MenuLayout.menuScopes.contains($0.scope) && ($0.chord.menuKeyEquivalent != nil || $0.chord.isReservedForTerminal) }
        if let chord, let wanted = KeyChord(chord) { return candidates.first { $0.chord == wanted } }
        return MenuLayout.menuScopes.lazy.compactMap { scope in candidates.first { $0.scope == scope } }.first
    }

    /// Caminho de menu por `ActionID` (`Edit ▸ Find ▸ Find…`), só de itens com ação.
    static func actionPaths(_ menu: NSMenu) -> [ActionID: [String]] {
        var out: [ActionID: [String]] = [:]
        func walk(_ m: NSMenu, _ path: [String]) {
            for item in m.items {
                if let a = item as? ActionMenuItem { out[a.actionID, default: []].append((path + [item.title]).joined(separator: " ▸ ")) }
                if let sub = item.submenu { walk(sub, path + [item.title]) }
            }
        }
        for top in menu.items { if let sub = top.submenu { walk(sub, [top.title]) } }
        return out
    }
}
