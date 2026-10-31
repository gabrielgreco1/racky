import RackyPlatform
import RackyProtocol
import RackyTerminalCore
import AppKit
import Foundation
import Synchronization
import SwiftTerm

/// `TerminalView` do SwiftTerm 1.99 com as regras do app (00 T6, 08 AR-105/AR-520/AR-708). Nunca
/// `LocalProcessTerminalView`: o PTY é do daemon, os bytes chegam por `feed` fora do main e o que o usuário digita sai
/// por `outputSink` com a origem marcada (06 §1.3).
///
/// Quem escreve no PTY, por origem (08 AR-105):
/// - teclado e mouse (main thread): `.key`; colagem (`pasteUser`): `.userPaste`.
/// - respostas do emulador a consultas do programa (DA, DSR, tamanho): `.terminalReply`. O parse roda fora do main,
///   então qualquer `send(source:)` chamado fora do main é resposta; elas passam por `UIReplyFilter` (OSC 52 nunca) e
///   ficam caladas durante o replay de um `snapshot` (consultas antigas do ring não podem ser respondidas de novo).
public final class TerminalSurfaceView: TerminalView {
    public typealias OutputSink = @Sendable ([UInt8], InputOrigin) -> Void

    private struct Routing {
        var sink: OutputSink?
        var replaying = false
        var userPasteOrigin: InputOrigin?
    }

    nonisolated private let routing = Mutex(Routing())
    /// Delegado forte: `TerminalView.terminalDelegate` é `weak`.
    private let surfaceDelegate = SurfaceDelegate()
    private let log = LogFacade(.app, category: "terminal")
    /// `true` se o renderer Metal subiu (AR-708); `false` registra o fallback para CoreGraphics.
    public private(set) var metalEnabled = false
    /// Caminhos de arquivo clicáveis (hover com ⌘, clique); URLs são do SwiftTerm.
    private(set) var links: TerminalLinkInteraction!
    /// ⌘ estava apertado no `mouseDown` em curso: o programa não recebe nem press, nem arrasto, nem release dele.
    private var commandPress = false

    public init(appearance: TerminalAppearance = TerminalAppearance()) {
        let options = TerminalOptions(cols: 80, rows: 25, cursorStyle: .blinkBlock, scrollback: appearance.scrollback)
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 400), font: appearance.font, options: options)
        terminalDelegate = surfaceDelegate
        surfaceDelegate.surface = self
        TerminalTheme.apply(to: self, appearance: appearance)
        linkReporting = .implicit
        linkHighlightMode = .hoverWithModifier
        do {
            try setUseMetal(true)
            metalEnabled = isUsingMetalRenderer
        } catch {
            log.error("Metal unavailable, using CoreGraphics: \(error)")
        }
        if !metalEnabled { log.publicError("terminal renderer fell back to CoreGraphics") }
        _ = Self.installArrowCursor
        links = TerminalLinkInteraction(surface: self)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }  // required init?(coder:) não usado

    /// Seta comum sobre o terminal: o SwiftTerm põe o I-beam no pane inteiro (`resetCursorRects`/`cursorUpdate`), o que
    /// incomoda sem estar selecionando texto. Os dois métodos são `public` (não `open`) lá; o AppKit os chama pelo runtime do ObjC, então
    /// esta subclasse ganha as próprias implementações uma vez, sem tocar no `TerminalView` original.
    static let installArrowCursor: Void = {
        let resetBlock: @convention(block) (NSView) -> Void = { view in view.addCursorRect(view.bounds, cursor: .arrow) }
        let updateBlock: @convention(block) (NSView, NSEvent) -> Void = { _, _ in NSCursor.arrow.set() }
        for (selector, block) in [(#selector(NSView.resetCursorRects), resetBlock as Any), (#selector(NSResponder.cursorUpdate(with:)), updateBlock as Any)] {
            guard let method = class_getInstanceMethod(NSView.self, selector) else { continue }
            let imp = imp_implementationWithBlock(block)
            if !class_addMethod(TerminalSurfaceView.self, selector, imp, method_getTypeEncoding(method)) {
                class_replaceMethod(TerminalSurfaceView.self, selector, imp, method_getTypeEncoding(method))
            }
        }
    }()

    /// Clique no terminal sempre devolve o foco à superfície (um overlay aberto engole o clique antes, no hit test).
    public override func mouseDown(with event: NSEvent) {
        takeFocus()
        if links.claimClick(event) { return }
        commandPress = event.modifierFlags.contains(.command)
        withLocalMouse { super.mouseDown(with: event) }
    }

    public override func mouseDragged(with event: NSEvent) {
        if links.hasClaimedClick { return }
        withLocalMouse { super.mouseDragged(with: event) }
    }

    public override func mouseUp(with event: NSEvent) {
        if links.hasClaimedClick { return links.finishClaimedClick(event) }
        withLocalMouse { super.mouseUp(with: event) }
        commandPress = false
    }

    /// ⌘-clique é do app mesmo com o programa pedindo mouse (TUIs como o Claude Code): sem `allowMouseReporting` o SwiftTerm
    /// trata o clique localmente, e `mouseUp` abre o link sob o cursor em vez de mandar o release ao PTY.
    private func withLocalMouse(_ body: () -> Void) {
        guard commandPress else { return body() }
        let previous = allowMouseReporting
        allowMouseReporting = false
        defer { allowMouseReporting = previous }
        body()
    }

    /// Pasta para resolver caminhos relativos (cwd do terminal); o runtime liga isto ao Files/OSC 7.
    public var linkCwd: () -> String? {
        get { links.cwd }
        set { links.cwd = newValue }
    }
    /// Abre um caminho clicado (⌘ = visualizador do app, ⇧⌘ = app padrão).
    public var onOpenFile: ((TerminalFileTarget, TerminalLinkOpenMode) -> Void)? {
        get { links.onOpen }
        set { links.onOpen = newValue }
    }

    /// Torna a surface first responder de qualquer jeito: descarta texto marcado preso (tecla morta do ABNT2) e, se o
    /// responder atual recusar largar o foco, força a janela a ficar sem responder e então entrega à surface.
    @discardableResult
    public func takeFocus() -> Bool {
        guard let window else { return false }
        if hasMarkedText() {
            inputContext?.discardMarkedText()
            unmarkText()
        }
        if window.firstResponder === self { return true }
        if window.makeFirstResponder(self) { return true }
        log.publicError("terminal focus refused by the current responder; forcing")
        _ = window.makeFirstResponder(nil)
        return window.makeFirstResponder(self)
    }

    /// Menu de contexto do terminal (03 §4.5, F17): desenhado pelo `DSMenuPanel` de quem hospeda o pane; recebe o ponto em
    /// coordenadas globais da janela (origem no topo). A view nunca devolve `NSMenu` nativo.
    public var onContextMenu: ((CGPoint) -> Void)?

    public override func menu(for event: NSEvent) -> NSMenu? {  // lint-ui: allow override obrigatório: devolve nil e abre o DSMenuPanel
        if let onContextMenu, let content = event.window?.contentView {
            onContextMenu(CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y))
        }
        return nil
    }

    /// Recalcula cols/rows a partir do frame atual (F31). O AppKit nem sempre chama `setFrameSize` por um caminho que o SwiftTerm
    /// observa (colapso animado do split, painel que recolhe no último quadro): o frame cresce e o emulador fica com as colunas
    /// antigas, então o PTY nunca recebe o tamanho novo. `setFrameSize` com o mesmo tamanho refaz a medição e dispara
    /// `onResize` só se cols/rows mudaram.
    public func syncTerminalSizeToFrame() {
        guard window != nil || frame.width > 0 else { return }
        setFrameSize(frame.size)
    }


    // MARK: Saída para o PTY

    /// Quem recebe o que a view quer escrever no PTY. Pode ser chamado de qualquer thread; ordem preservada pelo sink.
    public func setOutputSink(_ sink: OutputSink?) {
        routing.withLock { $0.sink = sink }
    }

    /// Replay de snapshot em andamento: as respostas do emulador ficam caladas (a thread de parse liga e desliga).
    public nonisolated func setReplaying(_ replaying: Bool) {
        routing.withLock { $0.replaying = replaying }
    }

    nonisolated var isReplaying: Bool { routing.withLock { $0.replaying } }

    /// Respostas do emulador (parse fora do main) e eventos gerados no main thread dentro do lock do terminal
    /// (colagem, mouse). Não passa por `onMain` como o `TerminalView` faz: o sink só enfileira.
    nonisolated public override func send(source: SwiftTerm.Terminal, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        guard !bytes.isEmpty else { return }
        if Thread.isMainThread {
            let (sink, origin) = routing.withLock { ($0.sink, $0.userPasteOrigin ?? .key) }
            sink?(bytes, origin)
            return
        }
        let (sink, replaying) = routing.withLock { ($0.sink, $0.replaying) }
        guard !replaying, UIReplyFilter.allows(bytes) else { return }
        sink?(bytes, .terminalReply)
    }

    /// Input do `TerminalView` (teclado, IME, `send(data:)`): sempre `.key`.
    fileprivate func routeKeyboardInput(_ bytes: [UInt8]) {
        let sink = routing.withLock { $0.sink }
        sink?(bytes, .key)
    }

    // MARK: Colar

    /// Cola texto do usuário (⌘V, arrastar): sanitiza (ESC e controles C0/C1 saem, 08 A3), aplica bracketed paste
    /// se o programa o ligou e envia com a origem `.userPaste`.
    public func pasteUser(_ text: String, origin: InputOrigin = .userPaste) {
        routing.withLock { $0.userPasteOrigin = origin }
        defer { routing.withLock { $0.userPasteOrigin = nil } }
        pasteText(PasteSanitizer.sanitize(text))
    }

    public func pasteUser(from pasteboard: NSPasteboard) {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        pasteUser(text)
    }

    public override func paste(_ sender: Any) {
        pasteUser(from: .general)
    }

    /// Ativa um link (⌘-clique): só passa o que `TerminalLinkPolicy` aceita.
    func activateLink(_ link: String) {
        guard let url = TerminalLinkPolicy.openableURL(link) else { return }
        surfaceDelegate.openURL(url)
    }

    // MARK: Callbacks de interface

    public var onResize: ((_ cols: Int, _ rows: Int) -> Void)? {
        get { surfaceDelegate.onResize }
        set { surfaceDelegate.onResize = newValue }
    }
    public var onTitle: ((String) -> Void)? {
        get { surfaceDelegate.onTitle }
        set { surfaceDelegate.onTitle = newValue }
    }
    public var onCwd: ((String?) -> Void)? {
        get { surfaceDelegate.onCwd }
        set { surfaceDelegate.onCwd = newValue }
    }
    public var onBell: (() -> Void)? {
        get { surfaceDelegate.onBell }
        set { surfaceDelegate.onBell = newValue }
    }
    /// OSC 52 de escrita (programas escrevem no clipboard). Ligado por padrão (02 §3); o aviso é do chamador.
    public var osc52WriteEnabled: Bool {
        get { surfaceDelegate.osc52WriteEnabled }
        set { surfaceDelegate.osc52WriteEnabled = newValue }
    }
    public var onClipboardWritten: (() -> Void)? {
        get { surfaceDelegate.onClipboardWritten }
        set { surfaceDelegate.onClipboardWritten = newValue }
    }
    /// Pasteboard alvo do OSC 52 (testes usam um privado).
    public var clipboardPasteboard: NSPasteboard {
        get { surfaceDelegate.pasteboard }
        set { surfaceDelegate.pasteboard = newValue }
    }
    /// Abre o link (⌘-clique); padrão: `NSWorkspace`. Só chega aqui o que passou por `TerminalLinkPolicy`.
    public var openURL: (URL) -> Void {
        get { surfaceDelegate.openURL }
        set { surfaceDelegate.openURL = newValue }
    }
    /// Contagem de pedidos de leitura de clipboard recusados (T6; evidência de teste).
    public var clipboardReadRefusals: Int { surfaceDelegate.clipboardReadRefusals }
}

/// Delegado da view: o único ponto onde a decisão de política (T6) acontece.
@MainActor
private final class SurfaceDelegate: TerminalViewDelegate {
    weak var surface: TerminalSurfaceView?
    var onResize: ((Int, Int) -> Void)?
    var onTitle: ((String) -> Void)?
    var onCwd: ((String?) -> Void)?
    var onBell: (() -> Void)?
    var onClipboardWritten: (() -> Void)?
    var osc52WriteEnabled = true
    var pasteboard = NSPasteboard.general
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    private(set) var clipboardReadRefusals = 0

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { onResize?(newCols, newRows) }
    func setTerminalTitle(source: TerminalView, title: String) { onTitle?(title) }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) { onCwd?(directory) }
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func bell(source: TerminalView) { onBell?() }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        surface?.routeKeyboardInput(Array(data))
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        surface?.activateLink(link)
    }

    /// OSC 52 de escrita: honra o setting. Nada além do texto vai ao pasteboard.
    func clipboardCopy(source: TerminalView, content: Data) {
        guard osc52WriteEnabled, !content.isEmpty, content.count <= 1 << 20 else { return }
        pasteboard.clearContents()
        pasteboard.setString(String(decoding: content, as: UTF8.self), forType: .string)
        onClipboardWritten?()
    }

    /// T6, AR-520: nunca devolve o clipboard a um programa do terminal.
    func clipboardRead(source: TerminalView) -> Data? {
        clipboardReadRefusals += 1
        return nil
    }
}
