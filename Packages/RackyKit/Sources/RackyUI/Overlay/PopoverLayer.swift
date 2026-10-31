import RackyDesignSystem
import RackyProtocol
import SwiftUI

extension EnvironmentValues {
    /// Roteador de overlays e popovers da janela; os controles abrem menus e comboboxes por ele.
    @Entry var overlayRouter: OverlayRouter?
}

/// Popover ancorado (menu, combobox): `DSMenuPanel` desenhado dentro da janela, nunca `NSPopover` nem `NSMenu` (02 §12.15).
public struct PopoverSpec {
    /// `<nome>` de `menuPanel.<nome>` (03 §22).
    public var name: String
    public var id: A11yID
    /// Frame do gatilho no espaço global da janela.
    public var anchor: CGRect
    public var width: CGFloat
    public var alignment: PopoverAlignment
    public var content: @MainActor (_ dismiss: @escaping @MainActor () -> Void) -> AnyView

    public init(
        name: String, id: A11yID, anchor: CGRect, width: CGFloat, alignment: PopoverAlignment = .leading,
        content: @escaping @MainActor (_ dismiss: @escaping @MainActor () -> Void) -> AnyView
    ) {
        self.name = name
        self.id = id
        self.anchor = anchor
        self.width = width
        self.alignment = alignment
        self.content = content
    }
}

public enum PopoverAlignment: Sendable { case leading, trailing }

public struct PopoverEntry: Identifiable {
    public let id = UUID()
    public let spec: PopoverSpec
    public internal(set) var isClosing = false
}

/// Posição do painel: abaixo do gatilho (acima se não couber), preso às margens da janela. Pura, testada sem janela.
public enum PopoverGeometry {
    public struct Placement: Equatable {
        public var origin: CGPoint
        public var below: Bool
        /// Âncora da escala (M-105): ponto do painel mais próximo do gatilho.
        public var anchor: UnitPoint
    }

    public static func place(anchor: CGRect, size: CGSize, container: CGSize, alignment: PopoverAlignment, gap: CGFloat, margin: CGFloat) -> Placement {
        var x = alignment == .leading ? anchor.minX : anchor.maxX - size.width
        x = min(max(x, margin), max(container.width - size.width - margin, margin))
        let spaceBelow = container.height - anchor.maxY - gap - margin
        let spaceAbove = anchor.minY - gap - margin
        let below = size.height <= spaceBelow || spaceBelow >= spaceAbove
        var y = below ? anchor.maxY + gap : anchor.minY - gap - size.height
        y = min(max(y, margin), max(container.height - size.height - margin, margin))
        let fx = size.width > 0 ? min(max((anchor.midX - x) / size.width, 0), 1) : 0.5
        return Placement(origin: CGPoint(x: x, y: y), below: below, anchor: UnitPoint(x: fx, y: below ? 0 : 1))
    }
}

/// Camada dos popovers: sobre cartões e toasts. Um painel por vez; clicar fora fecha (e não passa para o fundo).
struct PopoverLayer: View {
    let router: OverlayRouter

    var body: some View {
        GeometryReader { proxy in
            if let entry = router.popover {
                ZStack(alignment: .topLeading) {
                    // lint-ui: allow buttons fecha o popover (apresentação); o clique não chega ao fundo
                    Color.clear.contentShape(Rectangle()).onTapGesture { router.dismissPopover() }
                        .accessibilityHidden(true)
                    PopoverEntryView(entry: entry, container: proxy.size, router: router)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
        }
        .allowsHitTesting(router.popover != nil)
    }
}

/// Um popover com M-105: abre 0,15 `standard` (opacidade, escala 0,98, 8 pt a partir do lado do gatilho); fecha 0,12 só com fade.
private struct PopoverEntryView: View {
    let entry: PopoverEntry
    let container: CGSize
    let router: OverlayRouter
    @State private var size: CGSize = .zero
    @State private var shown = false

    private var resolution: MotionResolution { MotionPolicy.shared.resolution }
    private var reduced: Bool { if case .crossfade = resolution { true } else { false } }

    var body: some View {
        let placement = PopoverGeometry.place(
            anchor: entry.spec.anchor, size: size, container: container, alignment: entry.spec.alignment,
            gap: DSMetrics.popoverGap, margin: DS.Space.s2)
        let slide = reduced ? 0 : MotionTokens.Distance.small
        let hiddenScale = (reduced || entry.isClosing) ? 1 : MotionTokens.Scale.menuFrom
        let hiddenOffset = entry.isClosing ? 0 : (placement.below ? -slide : slide)
        entry.spec.content { router.dismissPopover() }
            .environment(\.dsMenuKeysActive, !entry.isClosing)
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { newSize in
                size = newSize
                if !shown, newSize.width > 0, !entry.isClosing { shown = true }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { router.setPopoverFrame($0) }
            .scaleEffect(shown ? 1 : hiddenScale, anchor: placement.anchor)
            .offset(y: shown ? 0 : hiddenOffset)
            .opacity(shown && !entry.isClosing ? 1 : 0)
            .animation(animation, value: shown)
            .animation(animation, value: entry.isClosing)
            .offset(x: placement.origin.x, y: placement.origin.y)
            .opacity(size == .zero ? 0 : 1)
            .accessibilityElement(children: .contain)
            .a11y(entry.spec.id, kind: "menu")
    }

    private var animation: Animation? {
        switch resolution {
        case .none: nil
        case .crossfade(let d): Motion.curve(MotionTokens.Easing.ease, d)
        case .normal(let scale):
            entry.isClosing
                ? Motion.curve(MotionTokens.Easing.exit, OverlayMotion.popoverExitDuration * scale)
                : Motion.curve(MotionTokens.Easing.standard, OverlayMotion.popoverEnterDuration * scale)
        }
    }
}
