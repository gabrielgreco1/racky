import SwiftUI

/// Gatilho do combobox (02 §12.11): igual ao `input` (raio 8), ícone 14 opcional + rótulo + `chevron-down` único à direita.
/// Nada de setas duplas do sistema (`NSPopUpButton`).
public struct DSComboboxField: View {
    private let icon: DSMenuItem.Icon?
    private let title: String
    private let detail: String?
    private let open: Bool
    private let forcedFocus: Bool?
    private let height: CGFloat
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    public init(
        icon: DSMenuItem.Icon? = nil, title: String, detail: String? = nil, open: Bool = false, focused: Bool? = nil,
        height: CGFloat = DSMetrics.fieldHeightComposer
    ) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.open = open
        self.forcedFocus = focused
        self.height = height
    }

    public var body: some View {
        HStack(spacing: DS.Space.s2) {
            if let icon {
                switch icon {
                case .symbol(let name):
                    Image(systemName: name)
                        .font(.system(size: DSMetrics.menuItemIcon - DS.Space.s0_5))
                        .foregroundStyle(DS.Color.textSecondary)
                        .frame(width: DSMetrics.menuItemIcon, height: DSMetrics.menuItemIcon)
                case .agent(let kind):
                    DSAgentLogo(kind, size: DSMetrics.menuItemIcon)
                case .data(let brand):
                    DSDataLogo(brand, size: DSMetrics.menuItemIcon)
                }
            }
            Text(verbatim: title)
                .dsFont(DS.Font.inputCompact)
                .foregroundStyle(DS.Color.textPrimary)
                .lineLimit(1)
            if let detail {
                Text(verbatim: detail)
                    .dsFont(DS.Font.monoMicro)
                    .foregroundStyle(DS.Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: DS.Space.s2)
            Image(systemName: "chevron.down")
                .font(.system(size: DSMetrics.comboboxChevron, weight: .medium))
                .foregroundStyle(DS.Color.textSecondary)
        }
        .dsFieldChrome(focused: open || (forcedFocus ?? (isFocused && isEnabled)), disabled: !isEnabled, height: height)
        .contentShape(Rectangle())
    }
}

/// Dica de tecla do protótipo (`esc`, `⌘↵`): texto `keycap` 9/500 a 60%, sem caixa. Dentro de botões e rodapés.
public struct KeyHint: View {
    private let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(verbatim: text)
            .dsFont(DS.Font.keycap)
            .opacity(0.6)
            .fixedSize()
    }
}
