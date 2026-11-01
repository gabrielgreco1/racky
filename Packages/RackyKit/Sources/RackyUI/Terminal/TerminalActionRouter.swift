import RackyProtocol
import Foundation

/// Liga as ações de terminal do registro (03 §24: zoom, busca, copiar/colar, limpar) ao pane focado. O pane dono do
/// foco se declara com `focus(_:)`; sem pane focado as ações ficam desabilitadas com o motivo exato.
@MainActor
public final class TerminalActionRouter {
    public private(set) weak var focused: TerminalHostView?
    private static let noTerminal = "No terminal is focused"

    public init() {}

    public func focus(_ host: TerminalHostView?) { focused = host }

    public func register(in registry: ActionRegistry) throws {
        let enablement: ActionRegistry.Enablement = { [weak self] in
            self?.focused == nil ? .disabled(reason: Self.noTerminal) : .enabled
        }
        func add(_ id: ActionID, _ body: @escaping @MainActor (TerminalHostView, ActionArgument) -> String?) throws {
            try registry.register(id, enablement: enablement) { [weak self] arg in
                guard let host = self?.focused else { return nil }
                return body(host, arg)
            }
        }
        try add(.terminalFontBigger) { host, _ in
            host.fontBigger()
            return "\(host.terminalAppearance.fontSize)"
        }
        try add(.terminalFontSmaller) { host, _ in
            host.fontSmaller()
            return "\(host.terminalAppearance.fontSize)"
        }
        try add(.terminalFontReset) { host, _ in
            host.fontReset()
            return "\(host.terminalAppearance.fontSize)"
        }
        try add(.terminalClear) { host, _ in
            host.clearTerminal()
            return nil
        }
        try add(.editCopy) { host, _ in
            host.copySelection()
            return nil
        }
        try add(.editPaste) { host, _ in
            host.pasteClipboard()
            return nil
        }
        try add(.editSelectAll) { host, _ in
            host.selectAll()
            return nil
        }
        try add(.findOpen) { host, _ in
            host.openFind()
            return nil
        }
        try add(.findNext) { host, _ in host.findModel.next() ? "found" : "not found" }
        try add(.findPrevious) { host, _ in host.findModel.previous() ? "found" : "not found" }
        try add(.findClose) { host, _ in
            host.closeFind()
            return nil
        }
        try add(.findCaseSensitive) { host, _ in
            host.findModel.toggleCaseSensitive()
            return host.findModel.caseSensitive ? "on" : "off"
        }
        try add(.findRegex) { host, _ in
            host.findModel.toggleRegex()
            return host.findModel.regex ? "on" : "off"
        }
        try add(.findQuery) { host, arg in
            if arg.kind == .set, let value = arg.value {
                if !host.findModel.isOpen { host.openFind() }
                host.findModel.query = value
            }
            return host.findModel.query
        }
    }
}
