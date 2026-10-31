import RackyCore
import RackyDesignSystem
import RackyProtocol
import AppKit
import SwiftUI

/// Divisor com a cor de borda do DS (1 pt), no lugar do divisor padrão do sistema.
final class ChromeSplitView: NSSplitView {
    override var dividerColor: NSColor { DS.ColorSpec.border.nsColor }
    override var dividerThickness: CGFloat { 1 }
    /// Arrasto de um divisor (sidebar ou painel direito): os terminais seguram o resize do PTY até soltar (04 MA6, AC-RP02).
    var onDividerDrag: (Bool) -> Void = { _ in }

    override func mouseDown(with event: NSEvent) {
        // Só chega aqui o clique no próprio split (os divisores); o das subviews não passa por aqui. O arrasto roda dentro do `super`.
        onDividerDrag(true)
        super.mouseDown(with: event)
        onDividerDrag(false)
    }
}

/// Hosting view sem safe area: a faixa e o conteúdo desenham sob a titlebar (`fullSizeContentView`).
final class ChromeHostingView: NSHostingView<AnyView> {
    /// Enquanto há overlay, estas views recusam o foco: Tab e cliques ficam dentro do overlay (02 §12.17).
    var inputBlocked: () -> Bool = { false }

    override var acceptsFirstResponder: Bool {
        if inputBlocked() { return false }
        if let cachedAccepts { return cachedAccepts }
        let value = super.acceptsFirstResponder
        cachedAccepts = value
        DispatchQueue.main.async { [weak self] in self?.cachedAccepts = nil }
        return value
    }
    /// A resposta do SwiftUI vale pela volta do run loop. O AppKit pergunta a cada hosting view várias vezes por quadro ao refazer as
    /// regiões arrastáveis da titlebar (conteúdo sob a titlebar), e cada pergunta varre a árvore de foco do SwiftUI: na troca de
    /// sessão isso era a maior parte do tempo da main thread.
    private var cachedAccepts: Bool?

    init(content: some View) {
        super.init(rootView: AnyView(content))
        safeAreaRegions = []
    }

    @MainActor @preconcurrency required init(rootView: AnyView) { super.init(rootView: rootView) }

    @MainActor @preconcurrency required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }  // required init?(coder:) não usado

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Sidebar (T1-13) e centro (landing mínima). Sidebar 280 (220–500), recolhível (⌘B). Painel direito oculto.
@MainActor
final class MainSplitViewController: NSSplitViewController {
    private let env: AppEnvironment
    let sidebarItem: NSSplitViewItem
    let contentItem: NSSplitViewItem
    /// Painel direito (10-right-panel): Files, Insights e Computers como módulos; largura, visibilidade e motion vêm de
    /// `RightPanelController`.
    let rightItem: NSSplitViewItem
    private let rightHost: RightPanelHostView
    private var didSetInitialWidth = false
    /// Mudança de largura feita por código (não é arrasto do usuário).
    private var applyingPanelWidth = false
    /// O usuário está arrastando um divisor da janela: o painel não reaplica a largura gravada no meio do arrasto (os dois brigavam
    /// a cada movimento, com um layout síncrono a mais por passo, e o arrasto andava aos saltos). A transição dos terminais (um só
    /// resize de PTY no fim) é do `ChromeSplitView`.
    private var draggingDivider = false
    private var dragWatch: Timer?
    private var panelTransitionToken = 0
    /// A primeira apresentação (estado restaurado na abertura do app) não anima.
    private var presentedOnce = false

    init(env: AppEnvironment) {
        self.env = env
        let sidebarVC = NSViewController()
        let sidebarView = ChromeHostingView(
            content: SidebarView(model: env.sidebar).environment(\.elementStore, env.elements).environment(\.actionRegistry, env.registry).environment(\.overlayRouter, env.overlays)
                .environment(\.subagentHoverCards, env.subagentHoverCards).environment(\.computersController, env.computers).environment(\.a11yParent, .windowMain))
        sidebarView.inputBlocked = { [overlays = env.overlays] in overlays.blocksTerminalInput }
        sidebarVC.view = sidebarView
        let contentVC: NSViewController
        if env.fixture == "terminal-demo" {
            // Tela de dev da T1-09 (um pane de terminal real, fora do workspace).
            contentVC = TerminalDemoViewController(env: env)
        } else {
            contentVC = WorkspaceViewController(env: env)
        }
        let rightVC = NSViewController()
        let rightHost = RightPanelHostView(
            content: RightPanelView(controller: env.rightPanel).environment(\.elementStore, env.elements).environment(\.actionRegistry, env.registry)
                .environment(\.a11yParent, .windowMain))
        rightHost.hosting.inputBlocked = { [overlays = env.overlays] in overlays.blocksTerminalInput }
        rightVC.view = rightHost
        self.rightHost = rightHost
        sidebarItem = NSSplitViewItem(viewController: sidebarVC)
        contentItem = NSSplitViewItem(viewController: contentVC)
        rightItem = NSSplitViewItem(viewController: rightVC)
        super.init(nibName: nil, bundle: nil)
        let split = ChromeSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        splitView = split
        sidebarItem.minimumThickness = DS.Layout.sidebarMinWidth
        sidebarItem.maximumThickness = DS.Layout.sidebarMaxWidth
        sidebarItem.canCollapse = true
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: NSLayoutConstraint.Priority.defaultLow.rawValue + 1)
        contentItem.minimumThickness = DS.Layout.windowMinWidth - DS.Layout.sidebarMaxWidth
        rightItem.minimumThickness = CGFloat(RightPanelGeometry.minWidth)
        rightItem.maximumThickness = CGFloat(RightPanelGeometry.maxWidth)
        rightItem.canCollapse = true
        rightItem.isCollapsed = true
        rightItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: NSLayoutConstraint.Priority.defaultLow.rawValue + 1)
        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
        addSplitViewItem(rightItem)
        split.autosaveName = nil
        split.onDividerDrag = { [workspace = env.workspace] dragging in workspace.runtime.setLayoutTransition(dragging) }
        env.rightPanel.onPresentationChange = { [weak self] animated in self?.applyRightPanelPresentation(animated: animated) }
        env.computers.onPanelChange = { [panel = env.rightPanel] open in
            if open { panel.show(.computers) } else { panel.hide(.computers) }
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var sidebarWidth: CGFloat { sidebarItem.isCollapsed ? 0 : sidebarItem.viewController.view.frame.width }

    override func viewDidLayout() {
        super.viewDidLayout()
        if !didSetInitialWidth, splitView.bounds.width > 0 {
            didSetInitialWidth = true
            splitView.setPosition(DS.Layout.sidebarWidth, ofDividerAt: 0)
        }
        syncRightPanelWindow()
    }

    // O NSSplitViewController não implementa este método do delegate (chamar `super` derruba o app).
    override func splitViewWillResizeSubviews(_ notification: Notification) {
        guard !applyingPanelWidth, !draggingDivider, NSEvent.pressedMouseButtons & 1 != 0 else { return }
        draggingDivider = true
        // O NSSplitView rastreia o mouse no próprio laço; o fim do arrasto é o botão solto.
        dragWatch = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, NSEvent.pressedMouseButtons & 1 == 0 else { return }
                self.endDividerDrag()
            }
        }
    }

    private func endDividerDrag() {
        guard draggingDivider else { return }
        draggingDivider = false
        dragWatch?.invalidate()
        dragWatch = nil
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        syncRightPanelWindow()
        // Arrasto do divisor do painel (mouse pressionado): grava a largura nova.
        guard !applyingPanelWidth, !rightItem.isCollapsed, NSEvent.pressedMouseButtons & 1 != 0 else { return }
        env.rightPanel.userResized(width: rightItem.viewController.view.frame.width)
    }

    /// Largura da janela e da sidebar para as regras do painel (recolhe abaixo de 1100, centro mínimo de 320).
    private func syncRightPanelWindow() {
        env.rightPanel.updateWindow(width: splitView.bounds.width, sidebarWidth: sidebarWidth)
    }

    /// Reflete `RightPanelController.isShown` e a largura efetiva no split. Abrir: o split expande de uma vez (um único resize do
    /// terminal) e o painel é revelado por recorte; fechar: recorte e só no último quadro o split recolhe (M-108).
    func applyRightPanelPresentation(animated: Bool) {
        let panel = env.rightPanel
        let reduceMotion = MotionPolicy.shared.reduceMotion
        let instant = !animated || !presentedOnce || MotionPolicy.shared.mode == .instant || view.window?.isVisible != true
        defer { presentedOnce = true }
        panelTransitionToken += 1
        let token = panelTransitionToken
        if panel.isShown, let width = panel.effectiveWidth {
            if rightItem.isCollapsed {
                panel.isContentVisible = true
                if !instant { rightHost.prepareReveal(reduceMotion: reduceMotion) }
                setRightCollapsed(false)
                setRightWidth(width)
                if instant {
                    rightHost.showInstantly()
                } else {
                    rightHost.reveal(
                        reduceMotion: reduceMotion, duration: MotionTokens.Duration.panel,
                        timing: Motion.caTiming(MotionTokens.Easing.expoOut))
                }
            } else {
                setRightWidth(width)
            }
        } else if !rightItem.isCollapsed {
            let finish: @MainActor () -> Void = { [weak self] in
                guard let self, self.panelTransitionToken == token else { return }
                self.setRightCollapsed(true)
                panel.isContentVisible = false
            }
            if instant {
                finish()
                rightHost.showInstantly()
            } else {
                rightHost.conceal(
                    reduceMotion: reduceMotion, duration: MotionTokens.Duration.base,
                    timing: Motion.caTiming(MotionTokens.Easing.exitClip), completion: finish)
            }
        } else {
            panel.isContentVisible = false
        }
    }

    private func setRightCollapsed(_ collapsed: Bool) {
        applyingPanelWidth = true
        defer { applyingPanelWidth = false }
        rightItem.isCollapsed = collapsed
        splitView.layoutSubtreeIfNeeded()
        env.workspace.runtime.syncSizesToLayout()
    }

    private func setRightWidth(_ width: CGFloat) {
        guard !draggingDivider, splitView.bounds.width > 0, abs(rightItem.viewController.view.frame.width - width) > 0.5 else { return }
        applyingPanelWidth = true
        defer { applyingPanelWidth = false }
        splitView.setPosition(max(0, splitView.bounds.width - width), ofDividerAt: 1)
        splitView.layoutSubtreeIfNeeded()
        env.workspace.runtime.syncSizesToLayout()
    }

    func setSidebarCollapsed(_ collapsed: Bool) {
        guard sidebarItem.isCollapsed != collapsed else { return }
        let runtime = env.workspace.runtime
        // Sem animação também com a janela invisível (fora da tela, minimizada, tela apagada): sem ciclo de display a animação
        // não avança, o completion nunca roda e o terminal ficava preso na largura antiga.
        let visible = view.window?.occlusionState.contains(.visible) ?? false
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || !visible {
            sidebarItem.isCollapsed = collapsed
            splitView.layoutSubtreeIfNeeded()
            runtime.syncSizesToLayout()
        } else {
            // F31: o colapso animado é uma transição de layout: nenhum resize de PTY durante os quadros e um só no fim,
            // medido pelo frame final (o completion roda depois do último quadro).
            runtime.setLayoutTransition(true)
            NSAnimationContext.runAnimationGroup(
                { _ in sidebarItem.animator().isCollapsed = collapsed },
                completionHandler: { [weak self] in
                    MainActor.assumeIsolated {
                        self?.splitView.layoutSubtreeIfNeeded()
                        runtime.setLayoutTransition(false)
                    }
                })
        }
    }
}

