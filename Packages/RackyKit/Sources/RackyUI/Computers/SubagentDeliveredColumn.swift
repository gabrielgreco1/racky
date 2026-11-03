import RackyCore
import RackyDesignSystem
import RackyProtocol
import RackyStore
import SwiftUI

/// v6 (03/11): a aba do subagente é a tela do computador dele com esta coluna ao lado: o que ele está fazendo, onde, e o que já
/// entregou (as tabelas que o computador gravou, com o número de linhas; um clique abre a tabela).
struct SubagentDeliveredColumn: View {
    let paneID: UUID
    let computer: String
    let computers: ComputersController
    let datasets: DatasetsController
    @Environment(\.actionRegistry) private var registry

    private var row: ComputerRow? { computers.model.rows.first { $0.id == computer } }
    private var tables: [DatasetSummary] { datasets.summaries.filter { $0.computer == computer } }

    var body: some View {
        let pid = paneID.uuidString
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.s6) {
                VStack(alignment: .leading, spacing: DS.Space.s1) {
                    label(String(localized: "Now", bundle: .module))
                    Text(verbatim: row?.snapshot.lastDoing ?? String(localized: "Nothing yet", bundle: .module))
                        .dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary).lineLimit(4)
                    if let url = row?.snapshot.url {
                        Text(verbatim: url).dsFont(DS.Font.monoMicro).foregroundStyle(DS.Color.textTertiary).lineLimit(1).truncationMode(.middle)
                    }
                    Text(verbatim: facts).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).lineLimit(1)
                }
                VStack(alignment: .leading, spacing: 0) {
                    label(String(localized: "Delivered", bundle: .module)).padding(.bottom, DS.Space.s1)
                    if tables.isEmpty {
                        Text("No tables yet", bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                    }
                    ForEach(tables) { table in
                        ActionButton(
                            .datasetOpen, id: .paneDeliveredWithIdDatasetId(pid, table.id), argument: .select(table.id),
                            tooltip: String(localized: "Open the table in a tab", bundle: .module)
                        ) {
                            HStack(spacing: DS.Space.s2) {
                                Image(systemName: "tablecells").font(.system(size: SidebarMetrics.line2Icon + DS.Space.s0_5))
                                    .foregroundStyle(DS.Color.textTertiary)
                                Text(verbatim: Self.shortName(datasets.displayName(table), computer: computer))
                                    .dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: DS.Space.s1)
                                Text(verbatim: table.rowCount.formatted()).dsFont(DS.Font.microNumeric).foregroundStyle(DS.Color.textTertiary).fixedSize()
                            }
                            .frame(height: SidebarMetrics.agentRowHeight)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(DS.Color.border)
                    }
                }
            }
            .padding(DS.Space.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: SubagentTabMetrics.columnWidth)
        .background(DS.Color.chrome)
        .overlay(alignment: .leading) { Rectangle().fill(DS.Color.border).frame(width: DSMetrics.hairline) }
        .a11y(.paneDelivered(pid), kind: "container", label: computer)
    }

    private func label(_ text: String) -> some View {
        Text(verbatim: text).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
    }

    /// `com tela · sem proxy · ao vivo`
    private var facts: String {
        guard let snapshot = row?.snapshot else { return String(localized: "Off", bundle: .module) }
        let screen = snapshot.display == "http" ? String(localized: "no screen", bundle: .module) : String(localized: "with screen", bundle: .module)
        let proxy = snapshot.proxy == "direct" || snapshot.proxy.isEmpty ? String(localized: "no proxy", bundle: .module) : snapshot.proxy
        return [computer, screen, proxy].joined(separator: " · ")
    }

    static func shortName(_ name: String, computer: String) -> String {
        let prefix = computer + "-"
        return name.hasPrefix(prefix) && name.count > prefix.count ? String(name.dropFirst(prefix.count)) : name
    }
}

enum SubagentTabMetrics {
    static let columnWidth: CGFloat = 260
    /// Abaixo disto a coluna sai e a tela fica sozinha.
    static let minPaneWidthForColumn: CGFloat = 720
}

/// A tela do computador com a coluna "Delivered" ao lado quando cabe.
struct SubagentTabLayout<Screen: View>: View {
    let paneID: UUID
    let computer: String
    let computers: ComputersController
    let datasets: DatasetsController
    @ViewBuilder let screen: () -> Screen

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                screen()
                if geo.size.width >= SubagentTabMetrics.minPaneWidthForColumn {
                    SubagentDeliveredColumn(paneID: paneID, computer: computer, computers: computers, datasets: datasets)
                }
            }
        }
    }
}
