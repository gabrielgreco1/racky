import RackyCore
import RackyDesignSystem
import RackyProtocol
import AppKit
import SwiftUI

/// Medidas do painel direito na UI (valores puros em `RightPanelGeometry`, tokens em `DS`).
enum RightPanelMetrics {
    static let barHeight = CGFloat(RightPanelGeometry.barHeight)
    static let headerHeight = CGFloat(RightPanelGeometry.moduleHeaderHeight)
    static let dividerThickness = CGFloat(RightPanelGeometry.dividerThickness)
    static let dividerHit = CGFloat(RightPanelGeometry.dividerHitSlop) * 2 + CGFloat(RightPanelGeometry.dividerThickness)
    static let hairline: CGFloat = 1
    /// Largura reservada no canto superior direito da janela para os botões Files · Insights · Data · painel (`RightPanelStripButtons`).
    /// Files, Insights, Computers, Data e o painel inteiro.
    static let stripButtons = StripMetrics.toggleSize.width * 5 + StripMetrics.navGap * 4 + DS.Space.s2 * 2
    static let headerIcon: CGFloat = 12
}

/// Botões da faixa de topo à direita (10-right-panel §1): um por módulo com botão, mais o painel inteiro. "Ligado" = módulo
/// visível. Ficam num overlay fixo no canto da janela (`ChromeContainerView`), por cima da tab row ou da barra do painel.
struct RightPanelStripButtons: View {
    let controller: RightPanelController

    var body: some View {
        HStack(spacing: StripMetrics.navGap) {
            ForEach(controller.modules.filter { $0.toggleAction != nil && $0.stripButtonID != nil }, id: \.id) { module in
                if let action = module.toggleAction, let id = module.stripButtonID {
                    let on = controller.isOn(module.id)
                    ActionButton(action, id: id, tooltip: module.title) {
                        Image(systemName: module.icon)
                    }
                    .buttonStyle(
                        StripButtonStyle(size: StripMetrics.toggleSize, icon: StripMetrics.toggleIcon, secondary: true, active: on))
                    .accessibilityLabel(Text(verbatim: module.title))
                    .accessibilityValue(on ? Text("On", bundle: .module) : Text("Off", bundle: .module))
                }
            }
            ActionButton(.rightPanelToggle, id: .tabsRightPanelToggle, tooltip: String(localized: "Toggle Right Panel", bundle: .module)) {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(
                StripButtonStyle(size: StripMetrics.toggleSize, icon: StripMetrics.toggleIcon, secondary: true, active: false))
            .accessibilityLabel(Text("Toggle Right Panel", bundle: .module))
        }
        .padding(.horizontal, DS.Space.s2)
        .frame(height: DS.Layout.titlebarHeight)
        .environment(\.actionRegistry, registry)
    }

    @Environment(\.actionRegistry) private var registry
}

/// Raiz do painel direito: faixa de 36 alinhada com a tab row (os botões flutuam por cima dela) e, abaixo, um ou dois módulos
/// com divisor arrastável. Só monta o conteúdo enquanto `isContentVisible` (o painel recolhido não deixa controles na árvore).
struct RightPanelView: View {
    let controller: RightPanelController

    var body: some View {
        GeometryReader { geo in
            if controller.isContentVisible {
                VStack(spacing: 0) {
                    bar
                    RightPanelBody(controller: controller, size: CGSize(width: geo.size.width, height: max(0, geo.size.height - RightPanelMetrics.barHeight)))
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { controller.measured(width: $0) }
                .a11y(.rightPanel, kind: "container")
            }
        }
        .background(DS.Color.canvas)
        .overlay(alignment: .leading) { DS.Color.border.frame(width: RightPanelMetrics.hairline) }
    }

    private var bar: some View {
        Color.clear
            .frame(height: RightPanelMetrics.barHeight)
            .background(TitlebarDragRegion())
            .background(DS.Color.chrome)
            .overlay(alignment: .bottom) { DS.Color.border.frame(height: RightPanelMetrics.hairline) }
    }
}

/// Os módulos visíveis, de cima para baixo.
struct RightPanelBody: View {
    let controller: RightPanelController
    let size: CGSize

    var body: some View {
        let modules = controller.visibleModules
        let fraction = controller.liveTopFraction ?? controller.layout.topFraction
        let heights = RightPanelGeometry.slotHeights(total: Double(size.height), count: modules.count, topFraction: fraction).map { CGFloat($0) }
        VStack(spacing: 0) {
            if modules.isEmpty {
                Text("No module is open.", bundle: .module)
                    .font(DS.Font.small.font)
                    .foregroundStyle(DS.Color.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            ForEach(Array(modules.enumerated()), id: \.element.id) { index, module in
                if index == 1 {
                    RightPanelDivider(controller: controller, total: size.height, topHeight: heights.first ?? 0)
                }
                if index < heights.count {
                    RightPanelModuleFrame(
                        controller: controller, module: module, slot: index == 0 ? .top : .bottom,
                        size: CGSize(width: size.width, height: heights[index]))
                        .frame(height: heights[index])
                }
            }
        }
        .animation(MotionPolicy.shared.animation(MotionTokens.Easing.expoOut, MotionTokens.Duration.disclosure), value: controller.layout.visible)
    }
}

/// Divisor entre os dois módulos: linha de 1 pt com área de arrasto maior; o arrasto muda a fração em memória e grava ao soltar.
struct RightPanelDivider: View {
    let controller: RightPanelController
    let total: CGFloat
    let topHeight: CGFloat
    @State private var startTop: CGFloat?

    var body: some View {
        DS.Color.border
            .frame(height: RightPanelMetrics.dividerThickness)
            .overlay {
                Color.clear
                    .frame(height: RightPanelMetrics.dividerHit)
                    .contentShape(Rectangle())
                    .pointerStyle(.rowResize)
                    .gesture(drag)
            }
            .zIndex(1)
            .a11y(.rightPanelDivider, kind: "container")
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                let base = startTop ?? topHeight
                startTop = base
                controller.liveTopFraction = RightPanelGeometry.topFraction(forTopHeight: Double(base + value.translation.height), total: Double(total))
            }
            .onEnded { value in
                let base = startTop ?? topHeight
                startTop = nil
                controller.setTopFraction(RightPanelGeometry.topFraction(forTopHeight: Double(base + value.translation.height), total: Double(total)))
            }
    }
}

/// Um módulo: header de 32 pt (ícone, título, acessório, minimizar; arrastar o header troca de posição) e corpo.
struct RightPanelModuleFrame: View {
    let controller: RightPanelController
    let module: any RightPanelModule
    let slot: PanelSlot
    let size: CGSize
    @State private var dropTargeted = false
    @Environment(\.actionRegistry) private var registry

    var body: some View {
        let context = RightPanelModuleContext(
            isCompact: RightPanelGeometry.isCompact(width: Double(size.width)), slot: slot,
            size: CGSize(width: size.width, height: max(0, size.height - RightPanelMetrics.headerHeight)))
        VStack(spacing: 0) {
            header(context)
            module.makeView(context: context)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
        .background(DS.Color.canvas)
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.sm)
                .strokeBorder(DS.Color.locate.opacity(dropTargeted ? 1 : 0), lineWidth: MotionTokens.Stroke.focusRing)
                .allowsHitTesting(false)
                .animation(MotionPolicy.shared.animation(MotionTokens.Easing.ease, MotionTokens.Duration.hover), value: dropTargeted)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let dragged = items.first, dragged != module.id.rawValue, NotebookDrop.datasetID(dragged) == nil, let registry else { return false }
            let target = "\(dragged):\(slot.rawValue)"
            Task { _ = try? await registry.perform(.rightPanelMove, .select(target)) }
            return true
        } isTargeted: { dropTargeted = $0 }
        .a11y(.rightPanelModule(module.id.rawValue), kind: "container", label: module.title)
    }

    private func header(_ context: RightPanelModuleContext) -> some View {
        HStack(spacing: DS.Space.s1) {
            HStack(spacing: DS.Space.s1_5) {
                Image(systemName: module.icon)
                    .font(.system(size: RightPanelMetrics.headerIcon, weight: .regular))
                    .foregroundStyle(DS.Color.textSecondary)
                if !context.isCompact {
                    Text(verbatim: module.title)
                        .font(DS.Font.sectionLabel.font)
                        .foregroundStyle(DS.Color.textPrimary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
            .draggable(module.id.rawValue) {
                Label(module.title, systemImage: module.icon)
                    .font(DS.Font.label.font)
                    .padding(.horizontal, DS.Space.s2)
                    .padding(.vertical, DS.Space.s1)
                    .background(DS.Color.accent, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
            }
            .help(String(localized: "Drag to move this module", bundle: .module))
            .a11y(.rightPanelModuleHeader(module.id.rawValue), kind: "container", label: module.title)
            if let accessory = module.makeHeaderAccessory(context: context) {
                accessory.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }
            ActionButton(
                .rightPanelMinimize, id: .rightPanelModuleMinimize(module.id.rawValue), argument: .select(module.id.rawValue),
                tooltip: String(localized: "Minimize", bundle: .module)
            ) {
                Image(systemName: "minus")
            }
            .buttonStyle(DSIconButtonStyle(.header))
            .accessibilityLabel(Text("Minimize", bundle: .module))
        }
        .padding(.leading, DS.Space.s3)
        .padding(.trailing, DS.Space.s1_5)
        .frame(height: RightPanelMetrics.headerHeight)
        .overlay(alignment: .bottom) { DS.Color.border.frame(height: RightPanelMetrics.hairline) }
    }
}
