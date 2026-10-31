import RackyDesignSystem
import RackyProtocol
import SwiftUI

enum PaletteMetrics {
    static let inputHeight: CGFloat = 48
    static let rowHeight: CGFloat = 32
    static let maxList: CGFloat = 560
    static let footerHeight: CGFloat = 28
    static let icon: CGFloat = 14
}

/// Overlay da palette (03 §8): campo de 48, lista agrupada com linhas de 32 e o rodapé de teclas de 28.
struct PaletteView: View {
    let model: PaletteModel
    @FocusState private var focused: Bool
    @Environment(\.actionRegistry) private var registry

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .leading) {
                if model.query.isEmpty {
                    Text(verbatim: model.placeholder).dsFont(DS.Font.paletteInput).foregroundStyle(DS.Color.textQuaternary).allowsHitTesting(false)
                }
                TextField(text: Binding(get: { model.query }, set: { model.query = $0; model.queryChanged() })) { EmptyView() }
                    .textFieldStyle(.plain)
                    .dsFont(DS.Font.paletteInput)
                    .foregroundStyle(DS.Color.textPrimary)
                    .focused($focused)
                    .onKeyPress(.upArrow) { model.move(-1); return .handled }
                    .onKeyPress(.downArrow) { model.move(1); return .handled }
                    .onKeyPress(.return) { openHighlighted(); return .handled }
                    .a11y(.overlayPaletteInput, kind: "textfield", value: model.query)
            }
            .padding(.horizontal, DS.Space.s4)
            .frame(height: PaletteMetrics.inputHeight)
            DS.Color.border.frame(height: DSMetrics.hairline)
            list
            DS.Color.border.frame(height: DSMetrics.hairline)
            Text(verbatim: model.insertMode ? String(localized: "↵ Insert · Esc Close", bundle: .module) : String(localized: "↵ Open · ⌘↵ New Session · Esc Close", bundle: .module))
                .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                .frame(maxWidth: .infinity, minHeight: PaletteMetrics.footerHeight, alignment: .leading).padding(.horizontal, DS.Space.s4)
        }
        .a11y(model.insertMode ? .overlayPaletteInsertMode : .overlayPalette, kind: "overlay")
        .task {
            await Task.yield()
            focused = true
        }
    }

    private func openHighlighted() {
        guard let registry else { return }
        Task { _ = try? await registry.perform(.paletteOpenRow, .press) }
    }

    @ViewBuilder private var list: some View {
        let rows = model.rows
        if rows.isEmpty {
            Text(verbatim: model.query.isEmpty ? " " : String(localized: "No results for \"\(model.query)\".", bundle: .module))
                .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).padding(DS.Space.s4).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index == 0 || rows[index - 1].group != row.group {
                            Text(verbatim: row.group).dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary)
                                .padding(.horizontal, DS.Space.s4).frame(height: PaletteMetrics.rowHeight, alignment: .leading)
                        }
                        rowView(row)
                    }
                }
                .padding(.bottom, DS.Space.s1)
            }
            .frame(maxHeight: PaletteMetrics.maxList)
        }
    }

    private func rowView(_ row: PaletteRow) -> some View {
        ActionButton(.paletteOpenRow, id: .overlayPaletteRow(row.kind, row.itemID), argument: .select(row.id)) {
            HStack(spacing: DS.Space.s2) {
                if let logo = row.logo { DSAgentLogo(logo, size: PaletteMetrics.icon) } else if let symbol = row.symbol {
                    Image(systemName: symbol).font(.system(size: PaletteMetrics.icon)).foregroundStyle(DS.Color.textSecondary)
                }
                Text(verbatim: row.title).dsFont(DS.Font.body).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                if let context = row.context { Text(verbatim: context).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).lineLimit(1) }
                Spacer(minLength: DS.Space.s2)
                if let reason = row.disabledReason { Text(verbatim: reason).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary) }
            }
            .padding(.horizontal, DS.Space.s4)
            .frame(maxWidth: .infinity, minHeight: PaletteMetrics.rowHeight, alignment: .leading)
            .background(row.id == model.highlighted ? DS.Color.hoverRow : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(row.disabledReason != nil)
        .opacity(row.disabledReason == nil ? 1 : 0.5)
    }
}
