import RackyCore
import RackyDesignSystem
import RackyPlatform
import RackyProtocol
import RackyStore
import Foundation
import Observation

/// Contêiner do painel direito (10-right-panel §1): módulos registrados, layout persistido (`ui_state`), regras de janela
/// (recolhe abaixo de 1100, nunca aperta o centro abaixo de 320) e as ações `rightPanel.*`. A parte AppKit
/// (`MainSplitViewController`) só reflete `isShown` e `effectiveWidth`; os gestos entram por aqui e viram `RightPanelLayout`.
@MainActor
@Observable
public final class RightPanelController {
    static let uiStateKey = "rightPanel"

    public private(set) var layout = RightPanelLayout()
    public private(set) var modules: [any RightPanelModule] = []
    /// Painel visível agora: aberto, cabendo na janela, e não recolhido sozinho por falta de largura.
    public private(set) var isShown = false
    /// O conteúdo do painel está montado (do início da abertura ao fim do recolhimento); recolhido não deixa controles na árvore.
    public var isContentVisible = false
    /// Fração provisória do divisor enquanto o usuário arrasta (só em memória; vai para o layout ao soltar).
    public var liveTopFraction: Double?
    /// Largura provisória durante o arrasto do divisor lateral, lida pela view para o modo compacto.
    public private(set) var measuredWidth: CGFloat = CGFloat(RightPanelGeometry.defaultWidth)
    /// Dispara a apresentação (abrir/fechar com motion, largura) na parte AppKit.
    @ObservationIgnored public var onPresentationChange: (_ animated: Bool) -> Void = { _ in }
    @ObservationIgnored public var toasts: ToastCenter?
    @ObservationIgnored private var store: RackyStore?
    @ObservationIgnored private var windowWidth: CGFloat = 0
    @ObservationIgnored private var sidebarWidth: CGFloat = 0
    /// Aberto pelo usuário numa janela estreita demais para recolher sozinho: fica aberto até ele fechar ou a janela alargar.
    @ObservationIgnored private var forcedOpenWhenNarrow = false
    /// Aplicando o estado salvo na abertura: a apresentação não anima.
    @ObservationIgnored private var restoring = false
    @ObservationIgnored private var lastSignature = Signature(shown: false, width: 0)

    private struct Signature: Equatable {
        var shown: Bool
        var width: Double
    }

    public init() {}

    // MARK: Módulos

    public func register(_ module: any RightPanelModule) {
        guard !modules.contains(where: { $0.id == module.id }) else { return }
        modules.append(module)
        layout.register(module.id)
    }

    public func module(_ id: PanelModuleID) -> (any RightPanelModule)? { modules.first { $0.id == id } }

    /// Módulos visíveis de cima para baixo.
    public var visibleModules: [any RightPanelModule] { layout.visible.compactMap { module($0) } }

    /// Botão da faixa de topo "ligado".
    public func isOn(_ id: PanelModuleID) -> Bool { isShown && layout.isVisible(id) }

    // MARK: Janela

    /// Largura efetiva do painel (a pedida limitada pelo que sobra na janela), `nil` quando nem a mínima cabe.
    public var effectiveWidth: CGFloat? {
        RightPanelGeometry.effectiveWidth(requested: layout.width, windowWidth: windowWidth, sidebarWidth: sidebarWidth).map { CGFloat($0) }
    }

    /// A janela ou a sidebar mudaram de largura.
    public func updateWindow(width: CGFloat, sidebarWidth: CGFloat) {
        let wasNarrow = RightPanelGeometry.autoCollapses(windowWidth: windowWidth)
        windowWidth = width
        self.sidebarWidth = sidebarWidth
        if wasNarrow, !RightPanelGeometry.autoCollapses(windowWidth: width) { forcedOpenWhenNarrow = false }
        refresh()
    }

    /// O usuário arrastou o divisor lateral: grava a largura (limitada) e persiste.
    public func userResized(width: CGFloat) {
        guard isShown else { return }
        measuredWidth = width
        let clamped = RightPanelGeometry.clampedStoredWidth(Double(width))
        guard clamped != layout.width else { return }
        layout.setWidth(clamped)
        persist()
    }

    /// Largura que a view usa para decidir o modo compacto (a medida real do painel na tela).
    public func measured(width: CGFloat) {
        if abs(width - measuredWidth) > 0.5 { measuredWidth = width }
    }

    // MARK: Mudanças pedidas pelo usuário

    public func toggle(_ id: PanelModuleID) {
        if layout.isVisible(id), layout.isOpen, !isShown {
            // Aberto na intenção, mas recolhido sozinho: o botão força a abertura.
            forceOpen()
            return
        }
        change(opening: !layout.isOn(id)) { $0.toggle(id) }
    }

    public func show(_ id: PanelModuleID) {
        change(opening: true) { $0.show(id) }
    }

    public func hide(_ id: PanelModuleID) {
        change(opening: false) { $0.hide(id) }
    }

    public func toggleOpen() {
        if layout.isOpen, !isShown {
            forceOpen()
            return
        }
        change(opening: !layout.isOpen) { $0.toggleOpen() }
    }

    public func drop(_ id: PanelModuleID, on slot: PanelSlot) {
        change(opening: false) { $0.drop(id, on: slot) }
    }

    public func swapVisible() {
        change(opening: false) { $0.swapVisible() }
    }

    public func setTopFraction(_ value: Double) {
        liveTopFraction = nil
        change(opening: false) { $0.setTopFraction(value) }
    }

    public func setWidth(_ value: Double) {
        change(opening: false) { $0.setWidth(value) }
    }

    private func forceOpen() {
        forcedOpenWhenNarrow = true
        refresh()
        warnIfTooNarrow()
        persist()
    }

    private func change(opening: Bool, _ body: (inout RightPanelLayout) -> Void) {
        body(&layout)
        if !layout.isOpen {
            forcedOpenWhenNarrow = false
        } else if opening, RightPanelGeometry.autoCollapses(windowWidth: Double(windowWidth)) {
            forcedOpenWhenNarrow = true
        }
        refresh()
        if opening, layout.isOpen { warnIfTooNarrow() }
        persist()
    }

    private func warnIfTooNarrow() {
        guard layout.isOpen, effectiveWidth == nil, windowWidth > 0 else { return }
        toasts?.show(kind: .info, title: String(localized: "The window is too narrow for the right panel.", bundle: .module))
    }

    private func refresh() {
        let narrow = RightPanelGeometry.autoCollapses(windowWidth: Double(windowWidth))
        let fits = effectiveWidth != nil
        let shown = layout.isOpen && fits && (!narrow || forcedOpenWhenNarrow)
        let signature = Signature(shown: shown, width: effectiveWidth.map(Double.init) ?? 0)
        let changed = signature != lastSignature
        isShown = shown
        lastSignature = signature
        if changed { onPresentationChange(!restoring) }
    }

    // MARK: Persistência

    public func attach(store: RackyStore) async {
        self.store = store
        restoring = true
        defer { restoring = false }
        if var saved = try? await store.uiState(Self.uiStateKey, as: RightPanelLayout.self) {
            for module in modules { saved.register(module.id) }
            layout = saved
        }
        refresh()
    }

    private func persist() {
        guard let store else { return }
        let value = layout
        Task { try? await store.scheduleUIState(Self.uiStateKey, value) }
    }

    // MARK: Ações

    public func register(in registry: ActionRegistry) throws {
        func moduleID(_ arg: ActionArgument, _ action: ActionID) throws -> PanelModuleID {
            guard arg.kind == .select, let raw = arg.value, !raw.isEmpty else {
                throw ActionError.failed(action, message: "expected select(<module>)")
            }
            let id = PanelModuleID(rawValue: String(raw.split(separator: ":").first ?? ""))
            guard module(id) != nil else { throw ActionError.failed(action, message: "unknown module \(id.rawValue)") }
            return id
        }
        func state(_ id: PanelModuleID) -> String { isOn(id) ? "on" : "off" }

        try registry.register(.rightPanelToggleFiles) { [unowned self] _ in
            toggle(.files)
            return state(.files)
        }
        try registry.register(.rightPanelToggleInsights) { [unowned self] _ in
            toggle(.insights)
            return state(.insights)
        }
        try registry.register(.rightPanelToggleData) { [unowned self] _ in
            toggle(.data)
            return state(.data)
        }
        try registry.register(.rightPanelToggleComputers) { [unowned self] _ in
            toggle(.computers)
            return state(.computers)
        }
        try registry.register(.rightPanelToggle) { [unowned self] _ in
            toggleOpen()
            return isShown ? "open" : "closed"
        }
        // ⌘L (03 §21) abre e fecha o mesmo painel; a ação existe desde a Fatia 2.
        try registry.register(.viewToggleRightPanel) { [unowned self] _ in
            toggleOpen()
            return isShown ? "open" : "closed"
        }
        try registry.register(
            .rightPanelMinimize,
            enablement: { [unowned self] in layout.visible.isEmpty ? .disabled(reason: String(localized: "No module is open.", bundle: .module)) : .enabled }
        ) { [unowned self] arg in
            let id = try moduleID(arg, .rightPanelMinimize)
            hide(id)
            return state(id)
        }
        try registry.register(.rightPanelMove) { [unowned self] arg in
            let id = try moduleID(arg, .rightPanelMove)
            let slotText = String((arg.value ?? "").split(separator: ":").dropFirst().first ?? "")
            guard let slot = PanelSlot(rawValue: slotText) else { throw ActionError.failed(.rightPanelMove, message: "expected select(<module>:top|bottom)") }
            drop(id, on: slot)
            return layout.visible.map(\.rawValue).joined(separator: ",")
        }
        try registry.register(
            .rightPanelSwap,
            enablement: { [unowned self] in
                layout.visible.count < 2 ? .disabled(reason: String(localized: "Open both modules to swap them.", bundle: .module)) : .enabled
            }
        ) { [unowned self] _ in
            swapVisible()
            return layout.visible.map(\.rawValue).joined(separator: ",")
        }
        try registry.register(.rightPanelSetWidth) { [unowned self] arg in
            guard arg.kind == .set, let raw = arg.value, let value = Double(raw) else {
                throw ActionError.failed(.rightPanelSetWidth, message: "expected set(<points>)")
            }
            setWidth(value)
            return "\(Int(layout.width))"
        }
        try registry.register(.rightPanelSetSplit) { [unowned self] arg in
            guard arg.kind == .set, let raw = arg.value, let value = Double(raw) else {
                throw ActionError.failed(.rightPanelSetSplit, message: "expected set(<fraction 0...1>)")
            }
            setTopFraction(value)
            return String(format: "%.3f", layout.topFraction)
        }
    }
}
