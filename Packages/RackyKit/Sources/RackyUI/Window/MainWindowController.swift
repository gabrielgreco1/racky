import RackyDesignSystem
import RackyPlatform
import RackyProtocol
import AppKit
import SwiftUI
import WebKit

/// Contêiner do conteúdo: o split ocupa a janela inteira e a faixa de 36 pt flutua por cima
/// (largura da sidebar quando aberta; largura do próprio conteúdo quando recolhida, 03 §1.3).
@MainActor
final class ChromeContainerView: NSView {
    let strip: NSView
    let split: NSView
    /// Overlays e toasts: acima de tudo, cobrindo a janela inteira (02 §12.17).
    let overlay: NSView
    /// Settings em página inteira (03 §14): cobre sidebar, centro e painel; a faixa da titlebar fica por cima.
    let settings: NSView
    /// Botões Files · Insights · painel no canto superior direito (10-right-panel §1): fixos sobre a tab row ou a barra do painel.
    let panelButtons: NSView
    /// Status bar (03 §5): 24 pt no rodapé, largura da janela; o split e o Settings ocupam o que sobra.
    let statusBar: NSView
    var statusBarHeight: () -> CGFloat = { 0 }
    var stripWidth: () -> CGFloat = { 0 }

    init(split: NSView, strip: NSView, overlay: NSView, settings: NSView, panelButtons: NSView, statusBar: NSView) {
        self.statusBar = statusBar
        self.split = split
        self.strip = strip
        self.overlay = overlay
        self.settings = settings
        self.panelButtons = panelButtons
        super.init(frame: .zero)
        settings.isHidden = true
        addSubview(split)
        addSubview(statusBar)
        addSubview(settings)
        addSubview(strip)
        addSubview(panelButtons)
        addSubview(overlay)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        let bar = min(statusBarHeight(), bounds.height)
        statusBar.isHidden = bar == 0
        statusBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bar)
        let content = NSRect(x: 0, y: bar, width: bounds.width, height: bounds.height - bar)
        split.frame = content
        settings.frame = bounds  // Settings cobre a janela inteira, status bar incluída (03 §14)
        overlay.frame = bounds
        let h = DS.Layout.titlebarHeight
        strip.frame = NSRect(x: 0, y: bounds.height - h, width: min(stripWidth(), bounds.width), height: h)
        let buttonsWidth = min(RightPanelMetrics.stripButtons, bounds.width)
        panelButtons.frame = NSRect(x: bounds.width - buttonsWidth, y: bounds.height - h, width: buttonsWidth, height: h)
    }
}

/// Janela principal: tecla que chega e nenhum responder aceita (first responder preso na chrome, view oculta) vai para
/// `onUnhandledKey`, que devolve o foco ao terminal e reenvia (watchdog de digitação).
final class RackyWindow: NSWindow {
    var onUnhandledKey: ((NSEvent) -> Bool)?
    /// Antes de entregar `keyDown` ao first responder: `true` se a tecla foi redirecionada (responder que não é terminal
    /// nem campo de texto, como um captador de teclas de menu esquecido, engole a digitação sem passar pelo watchdog).
    var routeStrayKey: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let routeStrayKey, routeStrayKey(event) { return }
        super.sendEvent(event)
    }

    override func keyDown(with event: NSEvent) {
        if let onUnhandledKey, onUnhandledKey(event) { return }
        super.keyDown(with: event)
    }
}

/// Janela principal (03 §1.1, 00 T5): `fullSizeContentView`, titlebar transparente, sem `NSToolbar`,
/// semáforos nativos reposicionados, mínimo 760×480, inicial 1440×900.
@MainActor
public final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let env: AppEnvironment
    private let split: MainSplitViewController
    /// O split principal (sidebar, centro, painel direito); testes arrastam os divisores por ele.
    var splitView: NSSplitView { split.splitView }
    private let container: ChromeContainerView
    private let strip: ChromeHostingView
    private let panelButtons: ChromeHostingView
    private let statusBarHost: ChromeHostingView
    private let overlayHost: OverlayHostingView
    private let settingsHost: ChromeHostingView
    private let overlayFocus = OverlayFocusCoordinator()
    private var positioner: TrafficLightPositioner?
    private var observers: [any NSObjectProtocol] = []
    private let mainToken = UUID()

    /// `autosaveName` é `nil` nos testes (não lê nem grava o frame do usuário).
    public init(env: AppEnvironment, autosaveName: String? = "workspace") {
        self.env = env
        split = MainSplitViewController(env: env)
        let strip = ChromeHostingView(
            content: TitlebarStrip(env: env).environment(\.elementStore, env.elements).environment(\.a11yParent, .windowMain))
        strip.inputBlocked = { [overlays = env.overlays] in overlays.blocksTerminalInput }
        self.strip = strip
        let panelButtons = ChromeHostingView(
            content: RightPanelStripButtons(controller: env.rightPanel).environment(\.elementStore, env.elements)
                .environment(\.actionRegistry, env.registry).environment(\.a11yParent, .windowMain))
        panelButtons.inputBlocked = { [overlays = env.overlays] in overlays.blocksTerminalInput }
        self.panelButtons = panelButtons
        let statusBarHost = ChromeHostingView(
            content: StatusBarView(controller: env.statusBar).environment(\.elementStore, env.elements).environment(\.actionRegistry, env.registry)
                .environment(\.overlayRouter, env.overlays).environment(\.a11yParent, .windowMain))
        statusBarHost.inputBlocked = { [overlays = env.overlays] in overlays.blocksTerminalInput }
        self.statusBarHost = statusBarHost
        let overlayHost = OverlayHostingView(router: env.overlays, toasts: env.toasts, registry: env.registry, elements: env.elements)
        self.overlayHost = overlayHost
        let settingsHost = ChromeHostingView(
            content: SettingsView(model: env.settings).environment(\.elementStore, env.elements).environment(\.actionRegistry, env.registry)
                .environment(\.overlayRouter, env.overlays).environment(\.a11yParent, .windowMain))
        settingsHost.inputBlocked = { [overlays = env.overlays] in overlays.blocksTerminalInput }
        self.settingsHost = settingsHost
        container = ChromeContainerView(
            split: split.view, strip: strip, overlay: overlayHost, settings: settingsHost, panelButtons: panelButtons, statusBar: statusBarHost)
        container.statusBarHeight = { [statusBar = env.statusBar] in statusBar.isShown ? DS.Layout.statusBarHeight : 0 }

        let window = RackyWindow(
            contentRect: NSRect(x: 0, y: 0, width: DS.Layout.windowDefaultWidth, height: DS.Layout.windowDefaultHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = nil
        window.isMovableByWindowBackground = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = DS.ColorSpec.canvas.nsColor
        window.contentMinSize = NSSize(width: DS.Layout.windowMinWidth, height: DS.Layout.windowMinHeight)
        window.title = "Racky"
        window.contentView = container
        window.contentViewController = nil
        super.init(window: window)
        window.delegate = self
        window.onUnhandledKey = { [weak self] event in self?.recoverTypingFocus(for: event) ?? false }
        window.routeStrayKey = { [weak self] event in self?.redirectStrayKey(event) ?? false }

        container.stripWidth = { [weak self] in self?.currentStripWidth() ?? 0 }
        window.center()
        if let autosaveName { window.setFrameAutosaveName(autosaveName) }
        positioner = TrafficLightPositioner(window: window)
        env.elements.window = window
        overlayFocus.window = window
        overlayFocus.hostView = overlayHost
        env.overlays.focus = overlayFocus
        overlayFocus.fallbackFocus = { [weak env] in env?.workspace.focusTerminalOfActiveTab() }
        env.elements.register(mainToken, id: .windowMain, kind: "window", label: "Racky", value: nil, action: nil, parent: nil)
        registerActions()
        observeSettings()
        observeStatusBar()
        observeLayout()
        window.layoutIfNeeded()
        container.needsLayout = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private let focusLog = LogFacade(.app, category: "focus")

    /// Watchdog: `keyDown` chegou à janela sem que nenhum responder o tratasse. Sem overlay e sem Settings, o terminal do
    /// pane focado recebe o foco e a tecla. Devolve `true` se a tecla foi reenviada.
    /// Quem pode ficar com as teclas: o terminal, qualquer campo de texto (field editor, `NSTextView`), o viewer (WebView) e as
    /// hosting views do SwiftUI (atalhos de lista, Esc). Qualquer outro responder (captador de menu fechado, janela, content
    /// view) é um responder invisível: a tecla vai para o terminal focado.
    static func acceptsTyping(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        if responder is TerminalSurfaceView || responder is NSText || responder is NSTextView { return true }
        if let view = responder as? NSView {
            var node: NSView? = view
            while let current = node {
                if current is WKWebView || current is NSTextField { return true }
                node = current.superview
            }
        }
        return false
    }

    /// Esc numa página do centro (viewer, Computers) volta à sessão. Com o teclado capturado pelo viewer o Esc é do computador.
    private func closePageOnEscape(_ event: NSEvent) -> Bool {
        guard event.keyCode == Self.escapeKeyCode, event.modifierFlags.intersection([.command, .option, .shift, .control]).isEmpty,
            !env.overlays.blocksTerminalInput, settingsHost.isHidden, env.computers.page != .workspace
        else { return false }
        if case .viewer = env.computers.page, env.computers.activeViewer?.model.keyboardCaptured == true { return false }
        env.computers.closePage()
        return true
    }

    static let escapeKeyCode: UInt16 = 53

    /// Responders do SwiftUI (hosting views e o `KeyViewProxy` que fica com o foco depois de uma lista): navegação por setas,
    /// Return e Esc são deles; texto digitado não é de ninguém ali e vai para o terminal.
    static func isSwiftUIHosted(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        return responder is NSHostingView<AnyView> || responder is OverlayHostingView || String(describing: type(of: responder)).hasPrefix("SwiftUI.")
    }

    static func isPrintable(_ event: NSEvent) -> Bool {
        guard let scalar = event.characters?.unicodeScalars.first else { return false }
        return scalar.value >= 0x20 && scalar.value != 0x7f && !(0xF700 ... 0xF8FF).contains(scalar.value)
    }

    func redirectStrayKey(_ event: NSEvent) -> Bool {
        if closePageOnEscape(event) { return true }
        guard let window, !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control) else { return false }
        guard !env.overlays.blocksTerminalInput, settingsHost.isHidden, env.computers.page == .workspace else { return false }
        let responder = window.firstResponder
        guard !Self.acceptsTyping(responder), let host = env.workspace.focusedHost() else { return false }
        if Self.isSwiftUIHosted(responder), !Self.isPrintable(event) { return false }
        let name = responder.map { String(describing: type(of: $0)) } ?? "nil"
        focusLog.publicError("keyDown went to a responder that is not a terminal or text field; redirected to the terminal")
        focusLog.error("responder=\(name)")
        host.focusTerminal()
        guard window.firstResponder === host.surface else { return false }
        host.surface.keyDown(with: event)
        return true
    }

    func recoverTypingFocus(for event: NSEvent) -> Bool {
        let responder = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let blocked = env.overlays.blocksTerminalInput
        let settingsOpen = !settingsHost.isHidden
        guard !event.modifierFlags.contains(.command), !blocked, !settingsOpen, let host = env.workspace.focusedHost() else {
            focusLog.publicError("keyDown reached the window but no terminal accepts it")
            focusLog.error("responder=\(responder) overlayBlocks=\(blocked) settingsOpen=\(settingsOpen)")
            return false
        }
        focusLog.publicError("keyDown reached the window unhandled; refocusing the terminal")
        focusLog.error("responder=\(responder)")
        host.focusTerminal()
        guard window?.firstResponder === host.surface else { return false }
        host.surface.keyDown(with: event)
        return true
    }
    /// Testes: a janela nunca aparece para o usuário (transparente, sem mouse, atrás de tudo e fora da tela).
    public static var invisibleForTests = false

    /// Abre sem ativar o app (o chamador decide se traz para frente).
    /// Testes desligam: a janela nunca é ordenada para a frente (o AppKit puxaria uma janela titulada para dentro da tela).
    public var orderingEnabled = true

    public func present(activate: Bool) {
        guard let window else { return }
        guard orderingEnabled, !Self.invisibleForTests else {
            if Self.invisibleForTests {
                window.alphaValue = 0
                window.ignoresMouseEvents = true
                window.animationBehavior = .none
            }
            window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            positioner?.apply()
            updateMainFrame()
            return
        }
        if activate {
            showWindow(nil)
            NSApp.activate()
        } else {
            // Sem ativar (open -g, automação): sem a animação de entrada, que congela no meio com o app em segundo plano.
            window.animationBehavior = .none
            window.orderFront(nil)
        }
        positioner?.apply()
        updateMainFrame()
    }

    /// Keep Running: esconde a janela sem destruir as views de terminal (reabrir volta já anexada).
    public func hide() {
        window?.orderOut(nil)
    }

    /// Settings abre por cima da sidebar e do centro (03 §14): o split some enquanto a página está aberta e o foco vai para ela.
    private func observeSettings() {
        let previous = env.settings.onPresentationChange
        env.settings.onPresentationChange = { [weak self] open in
            previous(open)
            guard let self else { return }
            self.split.view.isHidden = open
            self.panelButtons.isHidden = open
            self.settingsHost.isHidden = !open
            self.container.stripWidth = { [weak self] in self?.currentStripWidth() ?? 0 }
            self.container.needsLayout = true
            if open {
                self.window?.makeFirstResponder(self.settingsHost)
            } else {
                self.env.workspace.focusTerminalOfActiveTab()
            }
        }
    }

    /// Mostrar/esconder a barra (View › Show Status Bar, menu dela) refaz o layout; o split encolhe e o terminal reajusta o PTY uma vez.
    private func observeStatusBar() {
        withObservationTracking {
            _ = env.statusBar.isShown
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.container.needsLayout = true
                self.container.layoutSubtreeIfNeeded()
                self.env.workspace.runtime.syncSizesToLayout()
                self.observeStatusBar()
            }
        }
    }

    private func currentStripWidth() -> CGFloat {
        if env.settings.isOpen { return SettingsMetrics.navWidth }
        let width = env.shell.sidebarCollapsed ? strip.fittingSize.width : split.sidebarWidth
        // As páginas (área Data) deixam esse espaço livre no topo quando a faixa flutua sobre elas.
        if env.shell.sidebarCollapsed, abs(env.shell.titlebarStripWidth - width) > 0.5 {
            let shell = env.shell
            DispatchQueue.main.async { shell.titlebarStripWidth = width }
        }
        return width
    }

    private func registerActions() {
        do {
            try env.registry.register(.viewToggleSidebar) { [weak self] _ in
                guard let self else { return nil }
                self.setSidebarCollapsed(!self.env.shell.sidebarCollapsed)
                return self.env.shell.sidebarCollapsed ? "collapsed" : "expanded"
            }
        } catch {
            // Já registrada (outra janela): nada a fazer.
        }
    }

    func setSidebarCollapsed(_ collapsed: Bool) {
        env.shell.sidebarCollapsed = collapsed
        split.setSidebarCollapsed(collapsed)
        // O SwiftUI da faixa troca de modo no próximo ciclo; refaz o layout depois.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            self.container.needsLayout = true
        }
    }

    private func observeLayout() {
        let center = NotificationCenter.default
        let view = split.sidebarItem.viewController.view
        view.postsFrameChangedNotifications = true
        observers.append(
            center.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.container.needsLayout = true
                    self?.container.layoutSubtreeIfNeeded()
                }
            })
    }

    private func updateMainFrame() {
        guard let content = window?.contentView else { return }
        env.elements.updateFrame(mainToken, CGRect(origin: .zero, size: content.bounds.size))
    }

    // MARK: NSWindowDelegate

    /// Voltou de um NSOpenPanel, sheet ou outro app: o foco volta ao terminal, salvo overlay, Settings ou campo de texto.
    public func windowDidBecomeKey(_ notification: Notification) {
        restoreTerminalFocusIfLost()
    }

    public func windowDidResignKey(_ notification: Notification) {
        TooltipController.shared.dismiss(animated: false)
    }

    func restoreTerminalFocusIfLost() {
        guard let window, !env.overlays.blocksTerminalInput, settingsHost.isHidden else { return }
        let responder = window.firstResponder
        if responder is NSText { return }
        if let host = env.workspace.focusedHost(), responder !== host.surface { host.focusTerminal() }
    }

    public func windowDidResize(_ notification: Notification) {
        positioner?.apply()
        updateMainFrame()
        container.needsLayout = true
    }

    public func windowDidEnterFullScreen(_ notification: Notification) { env.shell.isFullScreen = true }
    public func windowDidExitFullScreen(_ notification: Notification) {
        env.shell.isFullScreen = false
        positioner?.apply()
    }
    public func windowDidChangeScreen(_ notification: Notification) { positioner?.apply() }
    public func windowDidChangeBackingProperties(_ notification: Notification) { positioner?.apply() }
}
