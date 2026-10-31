import RackyProtocol

/// Tabela de atalhos gerada do `KeyBindingRegistry` e do menu montado (T1-22). Saída: `docs/shortcuts.md`.
@MainActor
enum ShortcutsTable {
    static func markdown(keys: KeyBindingRegistry, paths: [ActionID: [String]]) -> String {
        var lines = [
            "# T1-22 · Tabela de atalhos (gerada)",
            "",
            "Gerada de `KeyBindingRegistry.canonical()` e do menu montado por `MainMenu.build` (03 §21). Não editar: `RACKY_WRITE_SHORTCUTS=1 swift test --filter ShortcutsTable`.",
            "",
            "Coluna Terminal: `PTY` = a tecla é reservada ao terminal (03 §21) e o app não a captura; `exceção` = ⌃⇥ e ⌃1…⌃9, tirados do PTY de propósito;",
            "`escopo` = só vale no escopo indicado (o item de menu perde o key equivalent quando o escopo não está ativo); `-` = sem conflito.",
            "",
            "| Atalho | Escopo | Ação | ActionID | Menu | Terminal |",
            "|---|---|---|---|---|---|",
        ]
        for b in keys.bindings {
            let id = b.action?.rawValue ?? "-"
            let menuPath = b.action.flatMap { paths[$0] }?.joined(separator: "; ") ?? (b.action == nil ? "sistema" : "-")
            let terminal: String
            if b.chord.isReservedForTerminal { terminal = "PTY" }
            else if b.scope != .global && b.scope != .app { terminal = "escopo" }
            else if b.chord.modifiers == [.control] { terminal = "exceção" }
            else { terminal = "-" }
            lines.append("| \(b.chord) | \(b.scope.rawValue) | \(b.title) | `\(id)` | \(menuPath) | \(terminal) |")
        }
        lines.append("")
        lines.append("Total: \(keys.bindings.count) atalhos, \(keys.conflicts().count) conflitos.")
        lines.append("")
        return lines.joined(separator: "\n")
    }
}
