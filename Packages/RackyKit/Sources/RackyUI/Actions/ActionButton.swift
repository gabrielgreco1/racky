import RackyDesignSystem
import RackyProtocol
import SwiftUI

/// Único `Button` permitido pela lint de UI: dispara `ActionRegistry.perform` (08 AR-805).
/// Se a fatia da ação ainda não existe, não renderiza nada (AC-T28, nunca "desabilitado").
/// Desabilitado só por pré-condição real, com o motivo no tooltip.
public struct ActionButton<Label: View>: View {
    private let action: ActionID
    private let a11yID: A11yID?
    private let argument: ActionArgument
    private let tooltip: String?
    private let label: Label
    @Environment(\.actionRegistry) private var registry

    /// `id` é nulo para partes de um controle composto (segmentos, itens), que não entram sozinhas na árvore de automação:
    /// o controle pai registra o `A11yID` e a ação segue acessível por `ctl ui action`.
    public init(
        _ action: ActionID, id: A11yID? = nil, argument: ActionArgument = .press, tooltip: String? = nil,
        @ViewBuilder label: () -> Label
    ) {
        self.action = action
        self.a11yID = id
        self.argument = argument
        self.tooltip = tooltip
        self.label = label()
    }

    public var body: some View {
        if let registry, registry.isRendered(action) {
            let availability = registry.availability(of: action)
            let button = Button {
                Task { await registry.performFromUI(action, argument) }
            } label: {
                label
            }
            .disabled(!availability.isEnabled)
            .dsTooltip(
                Self.tooltip(availability, fallback: tooltip),
                shortcut: availability.isEnabled && tooltip != nil ? action.spec.shortcut : nil)
            if let a11yID {
                button.a11y(a11yID, kind: "button", label: action.spec.label, action: action, argument: argument == .press ? nil : argument)
            } else {
                button
            }
        }
    }

    private static func tooltip(_ availability: ActionAvailability, fallback: String?) -> String {
        if case .disabled(let reason) = availability { return reason }
        return fallback ?? ""
    }
}

/// Renderiza o conteúdo só se a fatia já foi entregue (feature flag por fatia, AC-T28).
public struct SliceGate<Content: View>: View {
    private let slice: ReleaseSlice
    private let flags: SliceFlags
    private let content: Content

    public init(_ slice: ReleaseSlice, flags: SliceFlags, @ViewBuilder content: () -> Content) {
        self.slice = slice
        self.flags = flags
        self.content = content()
    }

    public var body: some View {
        if flags.isEnabled(slice) { content }
    }
}
