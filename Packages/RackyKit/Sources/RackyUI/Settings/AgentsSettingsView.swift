import RackyCore
import RackyDesignSystem
import RackyProtocol
import SwiftUI

/// Settings › Agents (03 §14.2): agente padrão, estado de cada CLI e os perfis de lançamento (06 §2.3).
/// É a tela de destino de `agent.openSettings` (03 §4.6).
struct AgentsSettingsView: View {
    let model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionGap) {
            SettingsBlock(title: nil) {
                SettingsRow(title: "Default agent", help: "Used by the + button and clean sessions.") {
                    DSCombobox(
                        id: .settings("agents", "defaultAgent"), selection: model.settings.agents.defaultAgent.rawValue,
                        entries: defaultAgentEntries, action: .settingsAgentsDefaultAgent,
                        searchPlaceholder: String(localized: "Search agents…", bundle: .module))
                }
            }
            ForEach(model.agents) { info in
                AgentBlock(model: model, info: info)
            }
        }
    }

    private var defaultAgentEntries: [DSMenuEntry] {
        var items: [DSMenuEntry] = model.agents.map { info in
            .item(DSMenuItem(
                info.provider.rawValue, info.displayName, icon: .agent(DSAgentKind(info.provider)),
                disabledReason: info.phase == .notInstalled ? String(localized: "Not installed", bundle: .module) : nil))
        }
        items.append(.separator("agents"))
        items.append(.item(DSMenuItem(TerminalProvider.shell.rawValue, String(localized: "Blank Terminal", bundle: .module), icon: .agent(.shell))))
        return items
    }
}

/// Bloco de um agente: logo, nome, versão e estado; executável, perfil padrão, ações e lista de perfis.
private struct AgentBlock: View {
    let model: SettingsModel
    let info: AgentInfo

    private var provider: TerminalProvider { info.provider }
    private func key(_ name: String) -> A11yID { .settings("agents", "\(provider.rawValue)\(name)") }

    var body: some View {
        SettingsBlock(title: nil) {
            header
            if let path = info.path {
                SettingsRow(title: "Executable", help: nil) {
                    HStack(spacing: DS.Space.s2) {
                        Text(verbatim: path)
                            .dsFont(DS.Font.monoMicro)
                            .foregroundStyle(DS.Color.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .dsTooltip(path)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            SettingsRow(title: "Default profile", help: "Used when you don't pick one.") {
                DSCombobox(
                    id: key("DefaultProfile"), selection: defaultSelection, entries: profileEntries, action: .settingsAgentsDefaultProfile,
                    searchPlaceholder: String(localized: "Search profiles…", bundle: .module))
            }
            HStack(spacing: DS.Space.s2) {
                if info.isLoggedOut {
                    DSButton(.accountLogIn, id: key("LogIn"), "Log In", variant: .primary, argument: .select(provider.rawValue))
                }
                if case .notInstalled = info.phase {
                    DSButton(.agentInstallHelp, id: key("Install"), "Install…", variant: .primary, argument: .select(provider.rawValue))
                }
                DSButton(.agentDetect, id: key("Check"), "Check Again", variant: .outline, argument: .select(provider.rawValue))
                Spacer(minLength: 0)
            }
            ProfileList(model: model, provider: provider)
        }
        .a11y(.settings("agents", provider.rawValue), kind: "container", label: info.displayName)
    }

    private var header: some View {
        HStack(spacing: DS.Space.s2) {
            DSAgentLogo(DSAgentKind(provider), size: SettingsMetrics.agentLogo)
            Text(verbatim: info.displayName)
                .dsFont(DS.Font.bodyStrong)
                .foregroundStyle(DS.Color.textPrimary)
            if let version = info.version {
                Text(verbatim: version).dsFont(DS.Font.monoMicro).foregroundStyle(DS.Color.textTertiary)
            }
            Spacer(minLength: DS.Space.s2)
            Text(verbatim: info.statusText)
                .dsFont(DS.Font.label)
                .foregroundStyle(color(info.tone))
                .lineLimit(1)
                .a11y(key("Status"), kind: "text", value: info.statusText)
        }
    }

    private func color(_ tone: AgentInfo.Tone) -> Color {
        switch tone {
        case .success: DS.Color.success
        case .warning: DS.Color.warning
        case .neutral: DS.Color.textSecondary
        }
    }

    private var defaultSelection: String {
        model.defaultProfile(for: provider).map { "\(provider.rawValue):\($0.id.uuidString)" } ?? ""
    }

    private var profileEntries: [DSMenuEntry] {
        model.profiles(for: provider).map { profile in
            .item(DSMenuItem(
                "\(provider.rawValue):\(profile.id.uuidString)", profile.name, icon: profile.skipsPermissions == nil ? nil : .symbol("shield.slash"),
                detail: profile.skipsPermissions?.flag, detailMono: true))
        }
    }
}

/// Lista de perfis do agente: nome, origem, padrão, indicador de bypass e as ações listar/criar/duplicar/editar/apagar.
private struct ProfileList: View {
    let model: SettingsModel
    let provider: TerminalProvider

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            HStack {
                Text("Launch profiles", bundle: .module)
                    .dsFont(DS.Font.label)
                    .foregroundStyle(DS.Color.textSecondary)
                Spacer(minLength: DS.Space.s2)
                DSButton(
                    .settingsAgentsProfileNew, id: .settings("agents", "\(provider.rawValue)ProfileNew"), "New Profile", variant: .outline,
                    symbol: "plus", argument: .select(provider.rawValue))
            }
            VStack(spacing: .zero) {
                ForEach(model.profiles(for: provider)) { profile in
                    ProfileRow(model: model, profile: profile)
                    if model.editingProfileID == profile.id { ProfileEditor(model: model, profile: profile) }
                }
            }
            .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Color.panel))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Color.border, lineWidth: DSMetrics.hairline))
        }
    }
}

private struct ProfileRow: View {
    let model: SettingsModel
    let profile: LaunchProfile

    private var isDefault: Bool { model.defaultProfile(for: profile.provider)?.id == profile.id }
    private var idString: String { profile.id.uuidString }
    private func id(_ name: String) -> A11yID { .settings("agents", "profile\(name)-\(idString)") }

    private func iconButton(_ action: ActionID, _ id: A11yID, _ symbol: String, _ name: String, destructive: Bool = false, active: Bool = false) -> some View {
        ActionButton(action, id: id, argument: .select(idString), tooltip: name) { Image(systemName: symbol) }
            .buttonStyle(DSIconButtonStyle(.header, destructive: destructive, active: active))
            .accessibilityLabel(Text(verbatim: name))
    }

    var body: some View {
        HStack(spacing: DS.Space.s2) {
            Text(verbatim: profile.name)
                .dsFont(DS.Font.body)
                .foregroundStyle(DS.Color.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .dsTooltip(profile.name)
            if let skip = profile.skipsPermissions {
                // Bypass sempre sinalizado: `ShieldOff` sem cor, com a flag exata no tooltip (02 §1 regra 5, 06 §2.3).
                HStack(spacing: DS.Space.s1) {
                    Image(systemName: "shield.slash").font(.system(size: DS.Space.s3))
                    Text("Skips permissions", bundle: .module).dsFont(DS.Font.small).lineLimit(1)
                }
                .foregroundStyle(DS.Color.textSecondary)
                .dsTooltip(skip.tooltip)
                .a11y(id("Skips"), kind: "indicator", label: skip.tooltip)
            }
            if profile.isBuiltin {
                DSBadge(String(localized: "Built-in", bundle: .module))
            }
            if isDefault { DSBadge(String(localized: "Default", bundle: .module), variant: .mono) }
            Spacer(minLength: DS.Space.s2)
            if profile.isBuiltin {
                DisabledControl(symbol: "pencil", reason: SettingsModel.builtinEditReason)
            } else {
                iconButton(.settingsAgentsProfileEdit, id("Edit"), "pencil", String(localized: "Edit", bundle: .module), active: model.editingProfileID == profile.id)
            }
            iconButton(.settingsAgentsProfileDuplicate, id("Duplicate"), "plus.square.on.square", String(localized: "Duplicate", bundle: .module))
            if profile.isBuiltin {
                DisabledControl(symbol: "trash", reason: SettingsModel.builtinDeleteReason)
            } else {
                iconButton(.settingsAgentsProfileDelete, id("Delete"), "trash", String(localized: "Delete", bundle: .module), destructive: true)
            }
        }
        .padding(.horizontal, DS.Space.s3)
        .frame(minHeight: SettingsMetrics.profileRowHeight)
        .a11y(id("Row"), kind: "row", label: profile.name)
    }
}

/// Edição do perfil aberto: nome, permissões, modelo e as flags permitidas do agente. Cada campo salva ao sair (03 §14.1).
private struct ProfileEditor: View {
    let model: SettingsModel
    let profile: LaunchProfile

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowGap) {
            SettingsRow(title: "Name", help: nil) {
                SettingsTextField(
                    id: .settings("agents", "profileName"), action: .settingsAgentsProfileName, saved: profile.name,
                    error: model.fieldErrors["agents.profileName"])
            }
            SettingsRow(title: "Permissions", help: "How much the agent can do without asking.") {
                DSCombobox(
                    id: .settings("agents", "profilePermission"), selection: profile.permissionMode ?? "default",
                    entries: ProfileOptions.permissionChoices(for: profile.provider).map { choice in
                        .item(DSMenuItem(choice.id, choice.title, icon: choice.skips ? .symbol("shield.slash") : nil))
                    }, action: .settingsAgentsProfilePermission)
            }
            SettingsRow(title: "Model", help: "Optional. Leave empty for the agent's default.") {
                SettingsTextField(
                    id: .settings("agents", "profileModel"), action: .settingsAgentsProfileModel, saved: profile.model ?? "",
                    error: model.fieldErrors["agents.profileModel"], placeholder: "Default", mono: true)
            }
            SettingsRow(title: "Extra flags", helpText: allowedHelp) {
                SettingsTextField(
                    id: .settings("agents", "profileArgs"), action: .settingsAgentsProfileArgs, saved: profile.extraArgs.joined(separator: " "),
                    error: model.fieldErrors["agents.profileArgs"], placeholder: "None", mono: true)
            }
        }
        .padding(DS.Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.fg5)
        .a11y(.settings("agents", "profileEditor"), kind: "container", label: profile.name)
    }

    private var allowedHelp: String {
        "Allowed: " + ProfileOptions.allowedExtraFlags(for: profile.provider).map(\.flag).joined(separator: " ")
    }
}
