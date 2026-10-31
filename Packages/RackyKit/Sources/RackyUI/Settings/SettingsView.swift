import RackyCore
import RackyDesignSystem
import RackyProtocol
import SwiftUI

/// Settings em página da janela inteira (03 §14): nav de 240 à esquerda e conteúdo centralizado até 720.
/// Sem cena `Settings`, sem sheet e sem botão Save: cada controle salva na hora (03 §14.1).
struct SettingsView: View {
    let model: SettingsModel
    @Environment(\.actionRegistry) private var registry

    var body: some View {
        // O host fica sempre na janela (escondido): sem a página aberta o conteúdo nem existe, senão os controles continuavam na
        // árvore do `ctl` (com frames por cima da sidebar) e a view seguia atualizando fora da tela.
        if model.isOpen { page } else { Color.clear }
    }

    private var page: some View {
        HStack(spacing: .zero) {
            SettingsNav(model: model)
                .frame(width: SettingsMetrics.navWidth)
            Rectangle().fill(DS.Color.border).frame(width: DSMetrics.hairline)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Color.canvas)
        .ignoresSafeArea()
        .onKeyPress(.escape) {
            guard let registry else { return .ignored }
            Task { _ = try? await registry.perform(.settingsBack, .press) }
            return .handled
        }
        .a11y(.settingsPage, kind: "page", label: "Settings")
    }

    private var title: String { model.visibleSections.first { $0.id == model.section }?.title ?? "" }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsMetrics.sectionGap) {
                Text(LocalizedStringKey(title), bundle: .module)
                    .dsFont(DS.Font.pageTitle)
                    .foregroundStyle(DS.Color.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                switch model.section {
                case "agents": AgentsSettingsView(model: model)
                case "general": GeneralSettingsView(model: model)
                case "terminal": TerminalSettingsView(model: model)
                case "notifications": NotificationsSettingsView(model: model)
                case "computers": ComputersSettingsView(model: model)
                case "diagnostics": DiagnosticsSettingsView(model: model)
                default: EmptyView()
                }
            }
            .frame(maxWidth: SettingsMetrics.contentMaxWidth, alignment: .leading)
            .a11y(.settings(model.section, "content"), kind: "container", label: title)
            .padding(.top, SettingsMetrics.contentTop)
            .padding(.horizontal, SettingsMetrics.contentSide)
            .padding(.bottom, SettingsMetrics.contentBottom)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollIndicators(.automatic)
        .id(model.section)
    }
}

/// Nav de 240: `← Back to App`, grupos com rótulo uppercase 11/500 e itens de 30 (03 §14.1).
private struct SettingsNav: View {
    let model: SettingsModel

    private var groups: [(name: String, items: [SettingsSectionSpec])] {
        var order: [String] = []
        var map: [String: [SettingsSectionSpec]] = [:]
        for spec in model.visibleSections {
            if map[spec.group] == nil { order.append(spec.group) }
            map[spec.group, default: []].append(spec)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            DSButton(.settingsBack, id: .settingsBack, "Back to App", variant: .ghost, symbol: "chevron.left")
            VStack(alignment: .leading, spacing: DS.Space.s4) {
                ForEach(groups, id: \.name) { group in
                    VStack(alignment: .leading, spacing: DS.Space.s0_5) {
                        Text(LocalizedStringKey(group.name), bundle: .module)
                            .textCase(.uppercase)
                            .dsFont(DS.Font.micro)
                            .tracking(DS.Font.micro.size * 0.18)
                            .foregroundStyle(DS.Color.textTertiary)
                            .padding(.horizontal, DS.Space.s3)
                            .padding(.bottom, DS.Space.s1)
                        ForEach(group.items) { spec in item(spec) }
                    }
                }
            }
            Spacer(minLength: .zero)
        }
        .padding(SettingsMetrics.navPadding)
        .padding(.top, DS.Layout.titlebarHeight)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DS.Color.panel)
    }

    private func item(_ spec: SettingsSectionSpec) -> some View {
        let selected = model.section == spec.id
        return ActionButton(.settingsOpenSection, id: .settingsNav(spec.id), argument: .select(spec.id)) {
            HStack(spacing: DS.Space.s2) {
                Image(systemName: spec.symbol).font(.system(size: SettingsMetrics.rowIcon)).opacity(selected ? 1 : 0.5)
                Text(LocalizedStringKey(spec.title), bundle: .module)
            }
        }
        .buttonStyle(SettingsNavStyle(selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
