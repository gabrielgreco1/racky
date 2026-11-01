import RackyDesignSystem
import RackyProtocol
import AppKit
import SwiftTerm
import SwiftUI

/// Hospedeiro do terminal no pane (03 §4.1, 02 §3): fundo `terminalBackground`, `TerminalSurfaceView` com inset de 4 pt
/// nas constraints (não padding SwiftUI), barra de busca flutuante (⌘F) e as teclas que o app trata antes do PTY
/// (zoom, busca, copiar/colar, tabela de 03 §21). O foco é do `TerminalSurfaceView`; `inputBlocked` (overlay aberto,
/// AC-T06) tira o foco e recusa cliques e teclas para que nenhuma tecla chegue ao PTY.
@MainActor
public final class TerminalHostView: NSView {
    public let surface: TerminalSurfaceView
    public let findModel = TerminalFindModel()
    public private(set) var terminalAppearance: TerminalAppearance
    /// Terminal dono deste pane (id do modelo), usado no identificador `pane.<id>.terminal`.
    public let terminalID: String

    private var findHost: NSView?
    private var insetConstraints: [NSLayoutConstraint] = []
    /// Chamado quando o pane deve receber o foco do app (clique); o pai marca o pane como focado.
    public var onFocusRequested: (() -> Void)?
    /// Aviso de toast do OSC 52 de escrita (`"<title>" copied to the clipboard`); a UI de toasts chega na T1-11.
    public var onClipboardWritten: (() -> Void)? {
        get { surface.onClipboardWritten }
        set { surface.onClipboardWritten = newValue }
    }

    public var inputBlocked = false {
        didSet {
            guard inputBlocked != oldValue, inputBlocked, let window, window.firstResponder === surface else { return }
            window.makeFirstResponder(nil)
        }
    }

    public init(
        terminalID: String, appearance: TerminalAppearance = TerminalAppearance(), registry: ActionRegistry? = nil,
        elements: UIElementStore? = nil
    ) {
        self.terminalID = terminalID
        self.terminalAppearance = appearance
        surface = TerminalSurfaceView(appearance: appearance)
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        wantsLayer = true
        layer?.backgroundColor = DS.Terminal.background.nsColor.cgColor
        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.setAccessibilityIdentifier(A11yID.paneTerminal(terminalID).rawValue)
        addSubview(surface)
        applyInset()
        findModel.surface = surface
        findModel.onClose = { [weak self] in self?.findClosed() }
        installFindBar(registry: registry, elements: elements)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }  // required init?(coder:) não usado

    public override func layout() {
        super.layout()
        surface.syncTerminalSizeToFrame()
    }

    private func applyInset() {
        NSLayoutConstraint.deactivate(insetConstraints)
        let p = terminalAppearance.padding
        insetConstraints = [
            surface.leadingAnchor.constraint(equalTo: leadingAnchor, constant: p),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -p),
            surface.topAnchor.constraint(equalTo: topAnchor, constant: p),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -p),
        ]
        NSLayoutConstraint.activate(insetConstraints)
    }

    private func installFindBar(registry: ActionRegistry?, elements: UIElementStore?) {
        var content = AnyView(TerminalFindBar(model: findModel))
        if let registry { content = AnyView(content.environment(\.actionRegistry, registry)) }
        if let elements { content = AnyView(content.environment(\.elementStore, elements)) }
        let host = NSHostingView(rootView: content)
        host.translatesAutoresizingMaskIntoConstraints = false
        host.isHidden = true
        addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: topAnchor, constant: DS.Space.s2),
            host.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Space.s2),
            host.widthAnchor.constraint(equalToConstant: TerminalFindBar.width),
            host.heightAnchor.constraint(equalToConstant: TerminalFindBar.height),
        ])
        findHost = host
    }

    // MARK: Foco e cliques

    public override var acceptsFirstResponder: Bool { false }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        inputBlocked ? nil : super.hitTest(point)
    }

    /// Clique na margem de 4 pt (fora da view): foca o terminal.
    public override func mouseDown(with event: NSEvent) {
        focusTerminal()
        onFocusRequested?()
    }

    public func focusTerminal() {
        guard !inputBlocked else { return }
        surface.takeFocus()
    }

    private var surfaceHasFocus: Bool { window?.firstResponder === surface }

    // MARK: Teclas tratadas antes do PTY

    /// AppKit oferece cada tecla à hierarquia antes do `keyDown`. Só age com o terminal focado e sem overlay.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, !inputBlocked, surfaceHasFocus, !surface.hasMarkedText() else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        let key = event.charactersIgnoringModifiers ?? ""
        // Teclas reservadas ao terminal (03 §21): só quando o programa não ligou o protocolo de teclado do kitty.
        if surface.keyboardEnhancementFlags.isEmpty, let bytes = TerminalKeyTable.bytes(for: event) {
            surface.send(data: bytes[...])
            return true
        }
        if flags == [.command] {
            switch key {
            case "f": openFind(); return true
            case "g" where findModel.isOpen: findModel.next(); return true
            case "=", "+": fontBigger(); return true
            case "-": fontSmaller(); return true
            case "0": fontReset(); return true
            case "k": clearTerminal(); return true
            case "c": copySelection(); return true
            case "v": pasteClipboard(); return true
            case "a": selectAll(); return true
            default: break
            }
        } else if flags == [.command, .shift], key.lowercased() == "g", findModel.isOpen {
            findModel.previous()
            return true
        } else if flags == [.command, .shift], key == "+" {
            fontBigger()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Ações do terminal (registradas por `TerminalActionRouter`)

    public func openFind() {
        findHost?.isHidden = false
        findModel.open()
    }

    public func closeFind() {
        findModel.close()
    }

    private func findClosed() {
        findHost?.isHidden = true
        focusTerminal()
    }

    public func fontBigger() { setFontSize(terminalAppearance.fontSize + 1) }
    public func fontSmaller() { setFontSize(terminalAppearance.fontSize - 1) }
    public func fontReset() { setFontSize(DS.TerminalFont.defaultSize) }

    public func setFontSize(_ size: CGFloat) {
        let clamped = TerminalAppearance.clamp(size)
        guard clamped != terminalAppearance.fontSize else { return }
        terminalAppearance.fontSize = clamped
        surface.font = terminalAppearance.font
    }

    /// Copia a seleção (⌘C) sem espaços à direita em cada linha (02 §3, "Trim trailing whitespace on copy": ligado).
    @discardableResult
    public func copySelection(to pasteboard: NSPasteboard = .general) -> Bool {
        guard let text = surface.getSelection(), !text.isEmpty else { return false }
        let trimmed = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in String(line.reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed()) }
            .joined(separator: "\n")
        pasteboard.clearContents()
        pasteboard.setString(trimmed, forType: .string)
        return true
    }

    public func pasteClipboard() {
        surface.pasteUser(from: .general)
    }

    public func selectAll() {
        surface.selectAll(nil)
    }

    /// ⌘K: limpa o histórico e redesenha o prompt (^L).
    public func clearTerminal() {
        surface.clearScrollback()
        surface.send(data: [0x0c][...])
    }
}
