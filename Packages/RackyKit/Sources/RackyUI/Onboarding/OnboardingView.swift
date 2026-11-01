import RackyCore
import RackyDesignSystem
import RackyProtocol
import SwiftUI

/// Onboarding (03 §15): overlay de 560 com a checklist (agentes, `gh`, Docker, imagem, conflitos), o agente padrão e o aviso de permissões.
struct OnboardingView: View {
    let model: OnboardingModel
    private var settings: SettingsModel { model.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: DSMetrics.overlayGap) {
            VStack(alignment: .leading, spacing: DS.Space.s1) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Set Up Racky", bundle: .module)
                        .dsFont(DS.Font.composerTitle)
                        .foregroundStyle(DS.Color.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: DS.Space.s2)
                    DSButton(.agentDetect, id: .onboardingItem("check"), "Check Again", variant: .ghost, symbol: "arrow.clockwise")
                }
                Text("Racky checks what's on this Mac. Fix what you need now; the rest can wait.", bundle: .module)
                    .dsFont(DS.Font.body)
                    .foregroundStyle(DS.Color.textSecondary)
            }
            .overlayGroup(0)
            // A lista rola só quando a janela é baixa; cabeçalho e rodapé (Skip, Done) ficam sempre à vista.
            ViewThatFits(in: .vertical) {
                checklist
                ScrollView(.vertical) { checklist }.scrollIndicators(.never)
            }
            .overlayGroup(1)
            footer.overlayGroup(2)
        }
        .padding(DSMetrics.overlayPadding)
        .a11y(.onboardingStep("checklist"), kind: "container", label: "Checklist")
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            VStack(spacing: DS.Space.s1) {
                ForEach(model.items) { info in
                    OnboardingItemRow(model: model, info: info)
                }
                ForEach(model.diagnosticItems) { item in
                    OnboardingDiagnosticRow(model: model, item: item)
                }
            }
            defaultAgentRow
            permissionsNotice
        }
    }

    private var defaultAgentRow: some View {
        HStack(spacing: DS.Space.s4) {
            VStack(alignment: .leading, spacing: .zero) {
                Text("Default agent", bundle: .module).dsFont(DS.Font.label).foregroundStyle(DS.Color.textPrimary)
                Text("Used by the + button and clean sessions.", bundle: .module)
                    .dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary).lineLimit(1)
            }
            Spacer(minLength: DS.Space.s2)
            DSCombobox(
                id: .onboardingItem("defaultAgent"), selection: settings.settings.agents.defaultAgent.rawValue, entries: entries,
                action: .settingsAgentsDefaultAgent, searchPlaceholder: String(localized: "Search agents…", bundle: .module))
                .frame(width: OnboardingMetrics.agentControlWidth)
        }
    }

    private var entries: [DSMenuEntry] {
        var items: [DSMenuEntry] = settings.agents.map { info in
            .item(DSMenuItem(
                info.provider.rawValue, info.displayName, icon: .agent(DSAgentKind(info.provider)),
                disabledReason: info.phase == .notInstalled ? String(localized: "Not installed", bundle: .module) : nil))
        }
        items.append(.separator("agents"))
        items.append(.item(DSMenuItem(TerminalProvider.shell.rawValue, String(localized: "Blank Terminal", bundle: .module), icon: .agent(.shell))))
        return items
    }

    /// Os perfis padrão pulam permissões (06 §2.3): o aviso é explícito e leva à tela onde se troca.
    private var permissionsNotice: some View {
        HStack(alignment: .top, spacing: DS.Space.s2) {
            Image(systemName: "shield.slash").font(.system(size: SettingsMetrics.rowIcon)).foregroundStyle(DS.Color.warning)
            Text(verbatim: BuiltinProfiles.skipPermissionsNotice)
                .dsFont(DS.Font.small)
                .foregroundStyle(DS.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DS.Space.s2)
            DSButton(.agentOpenSettings, id: .onboardingItem("reviewProfiles"), "Review Profiles", variant: .outline)
        }
        .padding(DS.Space.s3)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Color.warningBackground))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Color.warningBorder, lineWidth: DSMetrics.hairline))
        .a11y(.onboardingItem("permissions"), kind: "container", label: BuiltinProfiles.skipPermissionsNotice)
    }

    private var footer: some View {
        HStack(spacing: DS.Space.s2) {
            if model.confirmingSkip {
                Text("Skip setup? You can finish it from Racky › Set Up Racky…", bundle: .module)
                    .dsFont(DS.Font.small)
                    .foregroundStyle(DS.Color.textSecondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                DSButton(.onboardingKeepSettingUp, id: .onboardingStep("keepSettingUp"), "Keep Setting Up", variant: .ghost)
                DSButton(.onboardingConfirmSkip, id: .onboardingStep("confirmSkip"), "Skip", variant: .outline)
            } else {
                DSButton(.onboardingSkip, id: .onboardingSkip, "Skip for Now", variant: .ghost)
                Spacer(minLength: DS.Space.s2)
                DSButton(.onboardingDone, id: .onboardingDone, "Done", variant: .primary)
            }
        }
    }
}

/// Linha da checklist (56): ícone de estado, título 13/500, detalhe `small` e uma ação à direita (03 §15, AC-103).
struct OnboardingItemRow: View {
    let model: OnboardingModel
    let info: AgentInfo

    private var provider: TerminalProvider { info.provider }

    var body: some View {
        HStack(spacing: DS.Space.s3) {
            stateIcon.frame(width: SettingsMetrics.rowIcon, height: SettingsMetrics.rowIcon)
            DSAgentLogo(DSAgentKind(provider), size: SettingsMetrics.rowIcon)
            VStack(alignment: .leading, spacing: .zero) {
                HStack(spacing: DS.Space.s1_5) {
                    Text(verbatim: info.displayName).dsFont(DS.Font.label).fontWeight(.medium).foregroundStyle(DS.Color.textPrimary)
                    if model.isOptional(provider) {
                        Text("Optional", bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                    }
                }
                Text(verbatim: info.detailText)
                    .dsFont(DS.Font.small)
                    .foregroundStyle(info.tone == .warning ? DS.Color.warning : DS.Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .dsTooltip(info.detailText)
            }
            Spacer(minLength: DS.Space.s2)
            action
        }
        .padding(.horizontal, DS.Space.s3)
        .frame(height: OnboardingMetrics.rowHeight)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Color.fg5))
        .a11y(.onboardingItem(provider.rawValue), kind: "row", label: info.displayName, value: info.statusText)
    }

    @ViewBuilder private var stateIcon: some View {
        switch info.phase {
        case .checking: DSSpinner(size: SettingsMetrics.rowIcon, delayed: false)
        case .notInstalled: Image(systemName: "circle").foregroundStyle(DS.Color.textTertiary)
        case .installed(_, _, let login):
            switch login {
            case .loggedIn: Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.Color.success)
            case .loggedOut: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.Color.warning)
            case .unknown: Image(systemName: "circle").foregroundStyle(DS.Color.textTertiary)
            }
        }
    }

    /// No máximo uma ação: `Log In` (deslogado) ou `Install…` (ausente e não opcional).
    @ViewBuilder private var action: some View {
        if info.isLoggedOut, info.loginCommand != nil {
            DSButton(.accountLogIn, id: .onboardingItem("\(provider.rawValue)LogIn"), "Log In", variant: .outline, argument: .select(provider.rawValue))
        } else if case .notInstalled = info.phase, !model.isOptional(provider) {
            DSButton(.agentInstallHelp, id: .onboardingItem("\(provider.rawValue)Install"), "Install…", variant: .outline, argument: .select(provider.rawValue))
        }
    }
}

/// Linha de diagnóstico (gh, Docker, imagem, conflitos): estado, motivo em uma linha, no máximo uma ação primária e, se houver,
/// as secundárias numa segunda linha (03 §15, AC-103).
struct OnboardingDiagnosticRow: View {
    let model: OnboardingModel
    let item: DiagnosticItem

    private var key: String { item.key.rawValue }
    private var secondaryFixes: [DiagnosticFix] { model.secondaryFixes(of: item) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s1_5) {
            HStack(spacing: DS.Space.s3) {
                stateIcon.frame(width: SettingsMetrics.rowIcon, height: SettingsMetrics.rowIcon)
                Image(systemName: symbol).font(.system(size: SettingsMetrics.rowIcon)).foregroundStyle(DS.Color.textSecondary)
                    .frame(width: SettingsMetrics.rowIcon, height: SettingsMetrics.rowIcon)
                VStack(alignment: .leading, spacing: .zero) {
                    Text(verbatim: item.title).dsFont(DS.Font.label).fontWeight(.medium).foregroundStyle(DS.Color.textPrimary)
                    Text(verbatim: item.detail)
                        .dsFont(DS.Font.small)
                        .foregroundStyle(item.state == .warning || item.state == .problem ? DS.Color.warning : DS.Color.textSecondary)
                        // Avisos e problemas dizem o que fazer: duas linhas em vez de cortar ("may compet…").
                        .lineLimit(item.state == .warning || item.state == .problem ? 2 : 1)
                        .fixedSize(horizontal: false, vertical: true)
                        .truncationMode(.tail)
                        .dsTooltip(item.detail)
                }
                Spacer(minLength: DS.Space.s2)
                if model.confirmingDisable, item.key == .conflicts {
                    EmptyView()
                } else if let fix = item.fix {
                    OnboardingFixButton(model: model, item: item, fix: fix, slot: "Fix", primary: true)
                }
            }
            if item.key == .conflicts, model.confirmingDisable {
                disableConfirmation
            } else if !item.notes.isEmpty || !secondaryFixes.isEmpty {
                details
            }
        }
        .padding(.horizontal, DS.Space.s3)
        .padding(.vertical, DS.Space.s2)
        .frame(minHeight: OnboardingMetrics.rowHeight, alignment: .center)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Color.fg5))
        .a11y(.onboardingItem(key), kind: "row", label: item.title, value: item.detail)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            ForEach(item.notes, id: \.self) { note in
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s1_5) {
                    Image(systemName: "info.circle").font(.system(size: SettingsMetrics.rowIcon - 4)).foregroundStyle(DS.Color.textTertiary)
                    Text(verbatim: note).dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !secondaryFixes.isEmpty {
                HStack(spacing: DS.Space.s1) {
                    ForEach(Array(secondaryFixes.enumerated()), id: \.offset) { index, fix in
                        OnboardingFixButton(model: model, item: item, fix: fix, slot: "Fix\(index + 2)", primary: false)
                    }
                }
            }
        }
        .padding(.leading, OnboardingMetrics.detailIndent)
    }

    private var disableConfirmation: some View {
        HStack(spacing: DS.Space.s2) {
            Text("Move the global skill to a backup? Restore Skill undoes it.", bundle: .module)
                .dsFont(DS.Font.small).foregroundStyle(DS.Color.textSecondary).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            DSButton(.conflictDisableGlobal, id: .onboardingItem("conflictsCancelDisable"), "Cancel", variant: .ghost, argument: .select("cancel"))
            DSButton(.conflictDisableGlobal, id: .onboardingItem("conflictsConfirmDisable"), "Disable", variant: .outline, argument: .select("confirm"))
        }
        .padding(.leading, OnboardingMetrics.detailIndent)
    }

    private var symbol: String {
        switch item.key {
        case .gh: "chevron.left.forwardslash.chevron.right"
        case .runtime: "desktopcomputer"
        case .docker: "shippingbox"
        case .image: "externaldrive"
        case .conflicts: "exclamationmark.arrow.triangle.2.circlepath"
        }
    }

    @ViewBuilder private var stateIcon: some View {
        switch item.state {
        case .checking: DSSpinner(size: SettingsMetrics.rowIcon, delayed: false)
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.Color.success)
        case .warning, .problem: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.Color.warning)
        case .neutral: Image(systemName: "circle").foregroundStyle(DS.Color.textTertiary)
        }
    }
}

/// Mapeia cada correção para uma ação do registro (03 §24.6). Nenhuma escreve em config global dos CLIs.
private struct OnboardingFixButton: View {
    let model: OnboardingModel
    let item: DiagnosticItem
    let fix: DiagnosticFix
    let slot: String
    let primary: Bool

    private var key: String { item.key.rawValue }
    private var id: A11yID { .onboardingItem(key + slot) }
    private var variant: DSButtonVariant { .outline }

    var body: some View {
        switch model.effective(fix) {
        case .openURL: DSButton(.agentInstallHelp, id: id, "Install…", variant: variant, argument: .select(key == "gh" ? "gh" : "docker"))
        case .copyCommand: DSButton(.onboardingCopyCommand, id: id, "Copy Command", variant: variant, argument: .select(key))
        case .logIn: DSButton(.accountLogIn, id: id, "Log In", variant: variant, argument: .select("gh"))
        case .retry: DSButton(.onboardingRetry, id: id, "Try Again", variant: variant, argument: .select(key))
        case .openSettings(let section): DSButton(.settingsOpenSection, id: id, "Open Settings", variant: variant, argument: .select(section))
        case .startDocker: DSButton(.dockerStart, id: id, "Start Docker", variant: variant)
        case .blockSkill: DSButton(.conflictBlock, id: id, "Block in Racky", variant: variant)
        case .disableSkill: DSButton(.conflictDisableGlobal, id: id, "Disable Globally…", variant: variant)
        case .keepSkill: DSButton(.conflictKeep, id: id, "Keep", variant: variant)
        case .restoreSkill: DSButton(.conflictRestore, id: id, "Restore Skill", variant: variant)
        }
    }
}

enum OnboardingMetrics {
    static let width: CGFloat = 560
    static let rowHeight: CGFloat = 56
    static let agentControlWidth: CGFloat = 200
    /// Alinha notas e botões secundários com o texto da linha (ícone de estado + ícone do item + espaços).
    static let detailIndent: CGFloat = SettingsMetrics.rowIcon * 2 + DS.Space.s3 * 2
}

extension OnboardingModel {
    /// Spec do overlay (03 §15, F4): 560 de largura, raio 14, Esc pede `Skip setup?`. O clique no scrim não fecha: o onboarding
    /// só sai por `Done`, `Skip` ou ao abrir o Settings.
    func overlaySpec() -> OverlaySpec {
        OverlaySpec(
            name: "onboarding", id: .onboarding, width: OnboardingMetrics.width, cornerRadius: DS.Radius.large,
            cancelAction: .onboardingSkip, dismissOnScrim: { false },
            content: { [self] in AnyView(OnboardingView(model: self)) })
    }
}
