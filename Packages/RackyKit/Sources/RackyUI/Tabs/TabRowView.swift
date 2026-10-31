import RackyDesignSystem
import RackyProtocol
import AppKit
import SwiftUI

/// Medidas da tab row (03 §3, DS §12.7). Tudo vem de `DS.Layout`/`DS.Space`.
enum TabMetrics {
    static let rowHeight = DS.Layout.tabRowHeight
    static let dragStrip = DS.Layout.tabDragStripHeight
    /// Tab row 32 + faixa de arrasto 4 = 36, a altura da titlebar (03 §3.1).
    static let chromeHeight = DS.Layout.tabRowHeight + DS.Layout.tabDragStripHeight
    static let baseWidth = DS.Layout.tabWidth
    static let wideWidth = DS.Layout.tabWidthWide
    static let wideBreakpoint = DS.Layout.tabWidthWideBreakpoint
    static let minWidth = DS.Layout.tabMinWidth
    static let paddingH = DS.Space.s1_5
    static let gap = DS.Space.s1
    static let indicatorHeight = CGFloat(MotionTokens.Distance.hairline)
    static let logo = DS.Space.s3
    static let unreadDot: CGFloat = 6
    static let fade = DS.Space.s6
    static let chevron = CGSize(width: DS.Space.s4 + DS.Space.s1, height: DS.Space.s6)
    static let hairline: CGFloat = 1
    static let toolbarButton = DSIconButtonVariant.toolbar.box.width
    static let dragActivation: CGFloat = DS.Space.s3
    static let dropBar: CGFloat = 2
    /// Faixa à direita da tab reservada ao ✕ (fora da área de arrasto).
    static let closeInset = DSIconButtonVariant.tabClose.box.width + 2 * DS.Space.s1_5
}

/// Estado da tab row que só a view usa: rolagem. O arrasto (reordenar, soltar sobre um pane) vive no `PaneDragController`.
@MainActor
@Observable
final class TabRowState {
    var canScrollLeading = false
    var canScrollTrailing = false
    /// Sessão da última rolagem até a tab ativa: mudou de sessão, rola sem animação.
    @ObservationIgnored var session: UUID?
}

/// Tab row (03 §3): tabs da sessão selecionada, `+`, menu de panes. Fundo `chrome`, borda inferior de 1 pt.
struct TabRowView: View {
    let model: WorkspaceModel
    /// Com o painel recolhido a tab row termina na borda da janela e reserva o canto para os botões do painel; com ele aberto
    /// a tab row termina na borda do painel e os botões ficam sobre a barra dele.
    var rightPanel: RightPanelController?
    @State private var state = TabRowState()
    @Environment(\.actionRegistry) private var registry
    @Namespace private var indicatorSpace

    var body: some View {
        GeometryReader { geo in
            let showPaneActions = (model.activeTab?.layout.leafCount ?? 0) > 1
            // O fim da faixa é dos botões Files · Insights · painel (overlay da janela, 10-right-panel §1).
            let reserved = TabMetrics.toolbarButton + DS.Space.s2 + (showPaneActions ? TabMetrics.toolbarButton + DS.Space.s1 : 0) + DS.Space.s4
                + (rightPanel.map { $0.isContentVisible ? 0 : RightPanelMetrics.stripButtons } ?? 0)
            let available = max(0, geo.size.width - reserved)
            let width = tabWidth(count: model.tabs.count, available: available, window: geo.size.width)
            let content = width * CGFloat(model.tabs.count)
            HStack(spacing: 0) {
                strip(tabWidth: width, stripWidth: min(content, available))
                ActionButton(.tabQuickLaunch, id: .tabsNew, tooltip: String(localized: "New Tab", bundle: .module)) {
                    Image(systemName: "plus")
                }
                .buttonStyle(DSIconButtonStyle(.toolbar))
                .accessibilityLabel(Text("New Tab", bundle: .module))
                .padding(.leading, DS.Space.s1)
                if showPaneActions { paneActions.padding(.leading, DS.Space.s1) }
                Spacer(minLength: 0)
            }
            .frame(height: TabMetrics.rowHeight)
            .padding(.top, TabMetrics.dragStrip)
        }
        .frame(height: TabMetrics.chromeHeight)
        // Trocar de sessão troca a faixa inteira de uma vez: sem entrada animada das tabs, sem o indicador deslizando e sem rolagem
        // animada (cada animação era mais quadros de layout e a troca parecia lenta).
        .transaction(value: model.currentSessionID) { $0.disablesAnimations = true; $0.animation = nil }
        .overlay(alignment: .topLeading) { dropIndicator }
        .background(TabRowBackground())
        .background(DS.Color.chrome)
        .overlay(alignment: .bottom) { DS.Color.border.frame(height: TabMetrics.hairline) }
        .environment(\.actionRegistry, registry)
    }

    /// Barra de inserção quando um pane é arrastado sobre a tab row (vira tab nessa posição).
    @ViewBuilder
    private var dropIndicator: some View {
        let drag = model.dragController
        if case .tabRow(let index)? = drag.session?.target {
            GeometryReader { geo in
                let origin = geo.frame(in: .global).minX
                let tabs = model.tabs
                let x: CGFloat = {
                    if index < tabs.count, let f = drag.tabFrames[tabs[index].id] { return f.minX - origin }
                    if let last = tabs.last, let f = drag.tabFrames[last.id] { return f.maxX - origin }
                    return 0
                }()
                DS.Color.locate
                    .frame(width: TabMetrics.dropBar, height: TabMetrics.rowHeight)
                    .offset(x: x - TabMetrics.dropBar / 2, y: TabMetrics.dragStrip)
                    .a11y(.tabsDropIndicator, kind: "indicator")
                    .transition(.opacity)
            }
            .allowsHitTesting(false)
        }
    }

    /// 180 (220 com a janela ≥ 1280), encolhendo até o mínimo de 72 quando as tabs não cabem (03 §3.2).
    func tabWidth(count: Int, available: CGFloat, window: CGFloat) -> CGFloat {
        let base = window >= TabMetrics.wideBreakpoint ? TabMetrics.wideWidth : TabMetrics.baseWidth
        guard count > 0 else { return base }
        return min(base, max(TabMetrics.minWidth, (available / CGFloat(count)).rounded(.down)))
    }

    private func strip(tabWidth: CGFloat, stripWidth: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(model.tabs.enumerated()), id: \.element.id) { index, tab in
                        TabItemView(
                            model: model, tab: tab, index: index, width: tabWidth, indicatorSpace: indicatorSpace)
                            .id(tab.id)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .onScrollGeometryChange(for: ScrollEdges.self) { geo in
                ScrollEdges(
                    leading: geo.contentOffset.x > TabMetrics.hairline,
                    trailing: geo.contentOffset.x + geo.containerSize.width < geo.contentSize.width - TabMetrics.hairline)
            } action: { _, edges in
                state.canScrollLeading = edges.leading
                state.canScrollTrailing = edges.trailing
            }
            .overlay(alignment: .leading) { overflowEdge(leading: true, proxy: proxy) }
            .overlay(alignment: .trailing) { overflowEdge(leading: false, proxy: proxy) }
            .onChange(of: model.activeTabID) { _, id in
                guard let id else { return }
                if state.session != model.currentSessionID {
                    state.session = model.currentSessionID
                    proxy.scrollTo(id, anchor: nil)
                    return
                }
                withAnimation(MotionPolicy.shared.animation(MotionTokens.Easing.drawer, MotionTokens.Duration.medium)) {
                    proxy.scrollTo(id, anchor: nil)
                }
            }
        }
        .frame(width: stripWidth, height: TabMetrics.rowHeight)
        .clipped()
    }

    struct ScrollEdges: Equatable {
        var leading: Bool
        var trailing: Bool
    }

    /// Fade de 24 pt e chevron 20×24 nas bordas com overflow (M-305).
    @ViewBuilder
    private func overflowEdge(leading: Bool, proxy: ScrollViewProxy) -> some View {
        let visible = leading ? state.canScrollLeading : state.canScrollTrailing
        if visible { overflowControl(leading: leading, proxy: proxy) }
    }

    private func overflowControl(leading: Bool, proxy: ScrollViewProxy) -> some View {
        ZStack(alignment: leading ? .leading : .trailing) {
            LinearGradient(
                colors: [DS.Color.chrome, DS.Color.chrome.opacity(0)], startPoint: leading ? .leading : .trailing,
                endPoint: leading ? .trailing : .leading)
                .frame(width: TabMetrics.fade)
                .allowsHitTesting(false)
            // lint-ui: allow buttons rola a faixa de tabs (apresentação); nenhuma ação de produto
            Button {
                scroll(leading: leading, proxy: proxy)
            } label: {
                Image(systemName: leading ? "chevron.left" : "chevron.right")
                    .font(.system(size: DSIconButtonVariant.tabClose.icon))
                    .foregroundStyle(DS.Color.textSecondary)
                    .frame(width: TabMetrics.chevron.width, height: TabMetrics.chevron.height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .a11y(leading ? .tabsOverflowLeading : .tabsOverflowTrailing, kind: "button", label: leading ? "Scroll tabs left" : "Scroll tabs right")
        }
        .frame(height: TabMetrics.rowHeight)
        .transition(.opacity)
    }

    private func scroll(leading: Bool, proxy: ScrollViewProxy) {
        guard let active = model.activeTabID, let i = model.tabs.firstIndex(where: { $0.id == active }) else { return }
        let target = min(max(i + (leading ? -1 : 1), 0), model.tabs.count - 1)
        withAnimation(MotionPolicy.shared.animation(MotionTokens.Easing.drawer, MotionTokens.Duration.medium)) {
            proxy.scrollTo(model.tabs[target].id, anchor: leading ? .leading : .trailing)
        }
    }

    /// `⋯` com 2+ panes: Split Right, Split Down, Equalize, Expand, Close Other Panes (03 §3.3).
    private var paneActions: some View {
        ActionButton(.tabsPaneActions, id: .tabsPaneActions) {
            Image(systemName: "ellipsis")
                .font(.system(size: DSIconButtonVariant.toolbar.icon))
                .foregroundStyle(DS.Color.textSecondary)
                .frame(width: DSIconButtonVariant.toolbar.box.width, height: DSIconButtonVariant.toolbar.box.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .dsTooltip(String(localized: "Pane Actions", bundle: .module))
    }
}

/// Uma tab (DS §12.7): estado · logo · título (ou campo de renomear) · ✕. Ativa: fundo `fg6` e barra inferior de 2 pt.
struct TabItemView: View {
    let model: WorkspaceModel
    let tab: RackyProtocol.Tab
    let index: Int
    let width: CGFloat
    let indicatorSpace: Namespace.ID
    @Environment(\.actionRegistry) private var registry
    @State private var hovering = false

    private var isActive: Bool { model.activeTabID == tab.id }
    private var tabID: String { tab.id.uuidString }

    var body: some View {
        let terminal = model.primaryTerminal(of: tab)
        let glyph = terminal.map { model.status(of: $0) }
        let unread = tab.layout.terminalIDs.contains { model.isUnread($0) }
        let bell = tab.layout.terminalIDs.contains { model.attention?.center.bells.contains($0) ?? false }
        let title = model.displayTitle(of: tab)
        let renaming = model.renamingTab == tab.id
        ZStack(alignment: .bottom) {
            tabBody(terminal: terminal, glyph: glyph?.glyph, title: title, renaming: renaming, unread: unread, bell: bell)
            if isActive {
                DS.Color.textPrimary
                    .frame(height: TabMetrics.indicatorHeight)
                    .matchedGeometryEffect(id: "activeTab", in: indicatorSpace)
                    .a11y(.tabsActiveIndicator, kind: "indicator")
            }
        }
        .frame(width: width, height: TabMetrics.rowHeight)
        .background(isActive ? DS.Color.fg6 : Color.clear)
        // Tab com `done`, `failed` ou BEL não vistos: overlay âmbar a 10% e ponto (02 §2.6, 06 §3.6).
        .background(unread && !isActive ? DS.Color.unreadTabOverlay : Color.clear)
        .overlay(alignment: .trailing) { DS.Color.border.frame(width: TabMetrics.hairline) }
        .overlay { MiddleClickCatcher { perform(.tabClose, .select(tabID)) } }
        .overlay(alignment: .leading) {
            if !renaming {
                // Clique, duplo clique e arrasto: o ✕ à direita fica de fora e segue clicável.
                PaneDragSource(
                    controller: model.dragController, payload: .tab(tab.id), title: { title },
                    onClick: { count in perform(count >= 2 ? .tabRename : .paneShow, .select(count >= 2 ? tabID : selectTarget)) }
                )
                .frame(width: max(TabMetrics.dropBar, width - TabMetrics.closeInset))
            }
        }
        .scaleEffect(dragging ? MotionTokens.Scale.dragLift : 1)
        .shadow(color: dragging ? DS.Color.border : .clear, radius: DS.Space.s1_5)
        .opacity(draggedOut ? MotionTokens.Opacity.ghostIdle : 1)
        .offset(x: dragOffset)
        .zIndex(dragging ? 1 : 0)
        .animation(MotionPolicy.shared.animation(MotionTokens.Easing.standard, MotionTokens.Duration.fast), value: dragOffset)
        .animation(MotionPolicy.shared.animation(MotionTokens.Easing.standard, MotionTokens.Duration.fast), value: draggedOut)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.dragController.tabFrames[tab.id] = $0 }
        .onHover { hovering = $0 }
        .dsContextMenu(name: "tabContext", groups: { TabMenuItems(model: model, tab: tab).groups() })
        .transition(
            MotionPolicy.shared.reduceMotion
                ? .opacity : .asymmetric(insertion: .opacity.combined(with: .scale(scale: MotionTokens.Scale.tabFromX, anchor: .leading)), removal: .opacity))
        .a11y(.tabsTab(tabID), kind: "tab", label: title, value: isActive ? "selected" : nil)
    }

    /// A sessão de arrasto desta tab (ela é a arrastada), se houver.
    private var session: PaneDragController.Session? {
        guard let s = model.dragController.session, case .tab(let id) = s.payload, id == tab.id else { return nil }
        return s
    }

    private var dragging: Bool { session?.overTabRow == true }

    /// Arrastada para fora da tab row: fica na vaga, esmaecida, enquanto a etiqueta segue o cursor.
    private var draggedOut: Bool { session.map { !$0.overTabRow } ?? false }

    /// Deslocamento em x: a tab arrastada segue o cursor; as outras abrem espaço (M-303).
    private var dragOffset: CGFloat {
        guard let drag = model.dragController.session, case .tab(let id) = drag.payload, let start = drag.originIndex else { return 0 }
        if id == tab.id { return drag.overTabRow ? drag.point.x - drag.start.x : 0 }
        guard drag.overTabRow else { return 0 }
        let target = model.dragController.reorderTarget(for: drag)
        if start < target, index > start, index <= target { return -width }
        if start > target, index < start, index >= target { return width }
        return 0
    }

    @ViewBuilder
    private func tabBody(terminal: Terminal?, glyph: DSIndicatorGlyph?, title: String, renaming: Bool, unread: Bool, bell: Bool) -> some View {
        let showClose = isActive || hovering
        ZStack(alignment: .trailing) {
            if renaming {
                HStack(spacing: TabMetrics.gap) {
                    leading(terminal: terminal, glyph: glyph)
                    InlineRenameField(
                        initialText: title, font: DS.Font.tabActive.nsFont,
                        onCommit: { perform(.tabRename, .set($0)) }, onCancel: { model.cancelRename() })
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, TabMetrics.paddingH)
            } else {
                ActionButton(.paneShow, argument: .select(selectTarget)) {
                    HStack(spacing: TabMetrics.gap) {
                        leading(terminal: terminal, glyph: glyph)
                        Text(verbatim: title)
                            .dsFont(isActive ? DS.Font.tabActive : DS.Font.tab)
                            .foregroundStyle(isActive || hovering ? DS.Color.textPrimary : DS.Color.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .a11y(.tabsTabTitle(tabID), kind: "text", label: title)
                        if unread {
                            if bell {
                                Image(systemName: "bell.fill").font(.system(size: TabMetrics.unreadDot + 3)).foregroundStyle(DS.Color.unread)
                            } else {
                                Circle().fill(DS.Color.unread).frame(width: TabMetrics.unreadDot, height: TabMetrics.unreadDot)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, TabMetrics.paddingH)
                    // Com o ✕ à mostra o título corta ("…") antes dele; antes o ✕ ficava em cima das letras.
                    .padding(.trailing, showClose ? TabMetrics.closeInset : TabMetrics.paddingH)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .animation(MotionPolicy.shared.animation(MotionTokens.Easing.ease, MotionTokens.Duration.hover), value: hovering)
            }
            ActionButton(.tabClose, id: .tabsTabClose(tabID), argument: .select(tabID), tooltip: String(localized: "Close Tab", bundle: .module)) {
                Image(systemName: "xmark")
            }
            .buttonStyle(DSIconButtonStyle(.tabClose))
            .padding(.trailing, TabMetrics.paddingH)
            .opacity(showClose && !renaming ? 1 : 0)
            .allowsHitTesting(showClose && !renaming)
            .animation(MotionPolicy.shared.animation(MotionTokens.Easing.ease, MotionTokens.Duration.hover), value: showClose)
        }
    }

    /// Clicar numa tab só foca o pane se o terminal já está visível; nunca substitui o conteúdo de outro pane (03 §3.4).
    private var selectTarget: String {
        (model.primaryTerminal(of: tab)?.id ?? tab.layout.terminalIDs.first ?? tab.id).uuidString
    }

    @ViewBuilder
    private func leading(terminal: Terminal?, glyph: DSIndicatorGlyph?) -> some View {
        if let glyph, glyph != .none {
            DSAgentIndicator(glyph, size: .md)
                .a11y(.tabsTabStatus(tabID), kind: "status")
        }
        if let terminal {
            DSAgentLogo(terminal.provider, size: TabMetrics.logo, dimmed: !isActive)
        } else if tab.layout.panes.contains(where: { if case .traffic = $0.content { true } else { false } }) {
            // Tab de Traffic: o tráfego de rede de um computador.
            Image(systemName: "network").font(.system(size: TabMetrics.logo * 0.8))
                .foregroundStyle(isActive ? DS.Color.textSecondary : DS.Color.textTertiary)
                .frame(width: TabMetrics.logo, height: TabMetrics.logo)
        } else if tab.layout.panes.contains(where: { if case .notebook = $0.content { true } else { false } }) {
            // Tab de notebook: a marca do Jupyter, para não parecer mais uma tabela.
            JupyterMark(size: TabMetrics.logo).opacity(isActive ? 1 : 0.7)
        } else if tab.layout.panes.contains(where: { if case .computer = $0.content { true } else { false } }) {
            // Tab da tela de um computador de subagente.
            Image(systemName: "display").font(.system(size: TabMetrics.logo * 0.8))
                .foregroundStyle(isActive ? DS.Color.textSecondary : DS.Color.textTertiary)
                .frame(width: TabMetrics.logo, height: TabMetrics.logo)
        } else if !tab.layout.datasetIDs.isEmpty {
            // Tab de dataset: uma tabela.
            Image(systemName: "tablecells").font(.system(size: TabMetrics.logo * 0.8))
                .foregroundStyle(isActive ? DS.Color.textSecondary : DS.Color.textTertiary)
                .frame(width: TabMetrics.logo, height: TabMetrics.logo)
        }
    }

    private func perform(_ action: ActionID, _ argument: ActionArgument) {
        guard let registry else { return }
        Task { _ = try? await registry.perform(action, argument) }
    }
}

/// Menu de contexto da tab (03 §3.5): só entram as ações que têm dono.
struct TabMenuItems {
    let model: WorkspaceModel
    let tab: RackyProtocol.Tab

    @MainActor func groups() -> [[MenuEntry]] {
        let arg = ActionArgument.select(tab.id.uuidString)
        return [
            [
                MenuEntry(action: .tabRename, title: String(localized: "Rename…", bundle: .module), argument: arg),
                MenuEntry(action: .tabResetTitle, title: String(localized: "Reset Title", bundle: .module), argument: arg),
            ],
            [
                MenuEntry(action: .paneSplitRight, title: String(localized: "Split Right", bundle: .module), argument: splitArgument),
                MenuEntry(action: .paneSplitDown, title: String(localized: "Split Down", bundle: .module), argument: splitArgument),
            ],
            [
                MenuEntry(action: .tabClose, title: String(localized: "Close Tab", bundle: .module), argument: arg),
                MenuEntry(action: .tabCloseOthers, title: String(localized: "Close Other Tabs", bundle: .module), argument: arg),
                MenuEntry(action: .tabCloseRight, title: String(localized: "Close Tabs to the Right", bundle: .module), argument: arg),
            ],
            EventModifiers.held(.option)
                ? [MenuEntry(action: .terminalCopyId, title: String(localized: "Copy Terminal ID", bundle: .module), argument: terminalArgument)] : [],
        ]
    }

    private var terminalArgument: ActionArgument { .select((model.primaryTerminal(of: tab)?.id ?? tab.id).uuidString) }
    private var splitArgument: ActionArgument { terminalArgument }
}

/// Fundo da tab row: arrasta a janela e, com duplo clique no vazio, abre uma tab com o agente padrão (03 §3.3).
struct TabRowBackground: NSViewRepresentable {
    @Environment(\.actionRegistry) private var registry

    final class DragView: NSView {
        var onDoubleClick: () -> Void = {}
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { onDoubleClick() } else { super.mouseDown(with: event) }
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }

    func updateNSView(_ view: DragView, context: Context) {
        let registry = registry
        view.onDoubleClick = { Task { _ = try? await registry?.perform(.tabNewAgent, .press) } }
    }
}

/// Captura só o clique do botão do meio (fecha a tab); os demais eventos atravessam (`hitTest` nulo).
struct MiddleClickCatcher: NSViewRepresentable {
    let onMiddleClick: () -> Void

    final class CatcherView: NSView {
        var onMiddleClick: () -> Void = {}
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent, event.type == .otherMouseDown || event.type == .otherMouseUp else { return nil }
            return super.hitTest(point)
        }
        override func otherMouseUp(with event: NSEvent) {
            if event.buttonNumber == 2 { onMiddleClick() }
        }
    }

    func makeNSView(context: Context) -> CatcherView { CatcherView() }
    func updateNSView(_ view: CatcherView, context: Context) { view.onMiddleClick = onMiddleClick }
}
