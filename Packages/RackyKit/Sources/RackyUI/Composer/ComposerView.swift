import RackyCore
import RackyDesignSystem
import RackyProtocol
import SwiftUI

/// Conteúdo do composer ⌘N (03 §6, DS §12.17): Project, Where, Create from / Worktree / Folder conforme o Where, Agent,
/// Profile, Prompt, Advanced, resumo do comando, erro de validação e footer. Cada controle dispara uma ação do registro.
struct ComposerView: View {
    let model: ComposerModel

    var body: some View {
        VStack(alignment: .leading, spacing: DSMetrics.overlayGap) {
            Text("New Session", bundle: .module)
                .dsFont(DS.Font.composerTitle)
                .foregroundStyle(DS.Color.textPrimary)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: DS.Space.s3) {
                field("Project") {
                    DSCombobox(
                        id: .overlayComposerProject, selection: model.draft.projectID?.uuidString ?? "none", entries: model.projectEntries,
                        action: .composerSetProject, searchPlaceholder: String(localized: "Search projects…", bundle: .module))
                }
                field("Where") {
                    DSSegmented(
                        model.whereOptions.map { .init($0.rawValue, $0.title(hasProject: model.project != nil, kind: model.project?.kind ?? .git)) },
                        selection: model.draft.whereChoice.rawValue, action: .composerSetWhere, id: .overlayComposerWhere, fillWidth: true,
                        height: DSMetrics.segmentedHeightComposer)
                }
            }
            .overlayGroup(0)
            whereDetails
                .overlayGroup(1)
            VStack(alignment: .leading, spacing: DS.Space.s3) {
                HStack(alignment: .top, spacing: DS.Space.s3) {
                    field("Agent") {
                        DSCombobox(
                            id: .overlayComposerAgent, selection: model.draft.provider.rawValue, entries: model.agentEntries,
                            action: .composerSetAgent, searchPlaceholder: String(localized: "Search agents…", bundle: .module))
                    }
                    if model.draft.provider != .shell {
                        field("Profile") {
                            DSCombobox(
                                id: .overlayComposerProfile, selection: model.draft.profileID?.uuidString ?? "", entries: model.profileEntries,
                                action: .composerSetProfile, searchPlaceholder: String(localized: "Search profiles…", bundle: .module))
                        }
                    }
                }
                // Logo abaixo do perfil que causa o aviso (no fim do formulário parecia solto, longe do campo).
                summary
                if model.draft.provider.supportsSubagentComputers {
                    subagentComputers
                    if model.draft.subagentComputers.isOn { subagentHarness }
                }
                if model.draft.provider != .shell { dataDestination }
                advanced
                if let issue = model.boxIssue { errorBox(issue) }
                footer
            }
            .overlayGroup(2)
        }
        .padding(DSMetrics.overlayPadding)
    }

    // MARK: Campos que dependem do Where

    @ViewBuilder private var whereDetails: some View {
        switch model.draft.whereChoice {
        case .newWorktree:
            VStack(alignment: .leading, spacing: DS.Space.s3) {
                createFrom
            }
        case .existingWorktree:
            VStack(alignment: .leading, spacing: DS.Space.s3) {
                field("Worktree") {
                    DSCombobox(
                        id: .overlayComposerWorktree, selection: model.draft.worktreeID?.uuidString ?? "", entries: model.worktreeEntries,
                        action: .composerSetWorktree, searchPlaceholder: String(localized: "Search worktrees…", bundle: .module),
                        placeholder: String(localized: "Choose a worktree", bundle: .module))
                }
                if let warning = model.warning {
                    HStack(spacing: DS.Space.s1_5) {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: DS.Space.s3))
                        Text(verbatim: warning).dsFont(DS.Font.small)
                    }
                    .foregroundStyle(DS.Color.warning)
                    .a11y(.overlayComposerError("worktree"), kind: "text", label: warning)
                }
            }
        case .chooseFolder:
            field("Folder") {
                HStack(spacing: DS.Space.s2) {
                    Text(verbatim: model.draft.folderPath.map { ComposerDraft.abbreviate($0, home: model.context.home) } ?? String(localized: "No folder chosen", bundle: .module))
                        .dsFont(DS.Font.monoPane)
                        .foregroundStyle(model.draft.folderPath == nil ? DS.Color.textQuaternary : DS.Color.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .dsFieldChrome(height: DSMetrics.fieldHeightComposer)
                        .a11y(.overlayComposerFolder, kind: "textfield", value: model.draft.folderPath)
                    DSButton(.composerChooseFolder, "Choose…", variant: .outline, size: .compact)
                }
            }
        case .mainCheckout, .newFolder:
            EmptyView()
        }
    }

    private var createFrom: some View {
        field("Create from", trailing: AnyView(baseSelector)) {
            VStack(alignment: .leading, spacing: DS.Space.s1_5) {
                DSTextField(
                    "Branch name, #123 or a PR / issue URL", text: Bindable(model).draft.createFrom, id: .overlayComposerCreateFrom,
                    action: .composerSetBase, error: model.issue(for: .createFrom)?.message, compact: true)
                if model.createFromLookup == .local || model.createFromLookup == .remote {
                    HStack(spacing: DS.Space.s2) {
                        DSBadge(String(localized: "Branch exists", bundle: .module))
                        DSCheckbox(
                            isOn: model.draft.reuseBranch, action: .composerReuseBranch, id: .overlayComposerReuseBranch, "Reuse existing branch")
                    }
                }
            }
        }
    }

    /// `origin/main ⌄` à direita do label: abre a lista de bases (branch padrão e demais branches).
    private var baseSelector: some View {
        ActionButton(.composerSetBase, id: .overlayComposerBaseRef, tooltip: String(localized: "Base branch", bundle: .module)) {
            HStack(spacing: DS.Space.s1) {
                Text(verbatim: model.baseLabel)
                Image(systemName: "chevron.down").font(.system(size: DS.Space.s2, weight: .medium))
            }
            .dsFont(DS.Font.monoMicro)
            .foregroundStyle(DS.Color.textTertiary)
        }
        .buttonStyle(.plain)
    }

    // MARK: Subagent computers (F12)

    /// Linha "Subagent computers" com `Off` / `Ask` / `Full access`: o Claude pode dar um computador (navegador, shell, log de
    /// requisições) a cada subagente que vai estudar sites. A explicação muda com a escolha, com transição suave.
    private var subagentComputers: some View {
        field("Subagent computers") {
            // O que cada opção faz fica no tooltip do segmento: sem linha de texto embaixo.
            DSSegmented(
                SubagentComputersMode.allCases.map { .init($0.rawValue, $0.segmentTitle, help: $0.explanation) },
                selection: model.draft.subagentComputers.rawValue, action: .composerSetSubagentComputers, id: .overlayComposerComputers,
                fillWidth: true, height: DSMetrics.segmentedHeightComposer)
        }
    }

    /// "Subagents run as": Claude (os subagentes do próprio agente) ou sessões separadas de Codex / OpenCode, cada uma num pane.
    private var subagentHarness: some View {
        field("Subagents run as") {
            DSSegmented(
                SubagentHarness.allCases.map { .init($0.rawValue, LocalizedStringKey($0.segmentTitle), logos: $0.logos, help: $0.explanation) },
                selection: model.draft.subagentHarness.rawValue, action: .composerSetSubagentHarness, id: .overlayComposerSubagentHarness,
                fillWidth: true, height: DSMetrics.segmentedHeightComposer)
        }
    }

    /// "Save data to": onde os agentes gravam o que coletam (Racky por padrão, ou um lugar de uma conexão), com a frase do que acontece.
    private var dataDestination: some View {
        var options = model.dataDestinations()
        if !options.contains(where: { $0.key == "racky" }) { options.insert(.thisMac, at: 0) }
        let chosen = options.first { $0.key == model.draft.dataDestination } ?? options.first
        var entries: [DSMenuEntry] = []
        var lastGroup = ""
        for option in options {
            if option.group != lastGroup {
                if !entries.isEmpty { entries.append(.separator(option.group)) }
                entries.append(.header(option.group))
                lastGroup = option.group
            }
            // Cada lugar com o logo (este Mac, Supabase, S3…); protegido diz em letra pequena à direita.
            entries.append(.item(DSMenuItem(
                option.key, option.title, icon: option.brand.map { .data($0) } ?? .symbol("laptopcomputer"),
                detail: option.production ? String(localized: "Protected", bundle: .module) : nil)))
        }
        return field("Save data to") {
            VStack(alignment: .leading, spacing: DS.Space.s1_5) {
                DSCombobox(
                    id: .overlayComposerDataDestination, selection: chosen?.key ?? "racky", entries: entries,
                    action: .composerSetDataDestination, searchPlaceholder: String(localized: "Search places…", bundle: .module))
                // Fora deste Mac: uma linha só com o caminho do dado; numa conexão protegida, em âmbar com o cadeado.
                if let chosen, chosen.key != "racky" {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.s1_5) {
                        Image(systemName: chosen.production ? "lock.fill" : "arrow.triangle.branch")
                            .font(.system(size: DS.Space.s2_5))
                        Text(verbatim: chosen.explanation).dsFont(DS.Font.small).fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(chosen.production ? DS.Color.warning : DS.Color.textTertiary)
                    .a11y(.overlayComposerDataNote, kind: "text")
                }
            }
        }
    }

    // MARK: Advanced

    @ViewBuilder private var advanced: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            ActionButton(.composerToggleAdvanced, id: .overlayComposerAdvanced) {
                HStack(spacing: DS.Space.s1_5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: DS.Space.s3))
                        .rotationEffect(.degrees(model.advancedOpen ? 90 : 0))
                        .animation(MotionPolicy.shared.animation(MotionTokens.Easing.standard, MotionTokens.Duration.fast), value: model.advancedOpen)
                    Text("Advanced", bundle: .module)
                }
                .dsFont(DS.Font.label)
                .foregroundStyle(DS.Color.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(Text(verbatim: model.advancedOpen ? "expanded" : "collapsed"))
            if model.advancedOpen {
                VStack(alignment: .leading, spacing: DS.Space.s3) {
                    command
                    field("Session name") {
                        DSTextField(
                            LocalizedStringKey(model.draft.sessionTitle), text: Bindable(model).draft.sessionName, id: .overlayComposerName,
                            action: .composerSetSessionName, error: model.issue(for: .name)?.message, compact: true)
                    }
                    if model.draft.whereChoice == .newWorktree {
                        field("Branch name") {
                            DSTextField(
                                LocalizedStringKey(model.draft.defaultBranchName(model.context)), text: Bindable(model).draft.branchName,
                                id: .overlayComposerBranch, action: .composerSetBranchName, compact: true, mono: true)
                        }
                        field("Worktree location") {
                            HStack(spacing: DS.Space.s2) {
                                Text(verbatim: model.locationText)
                                    .dsFont(DS.Font.monoMicro)
                                    .foregroundStyle(DS.Color.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .a11y(.overlayComposerLocation, kind: "text", value: model.locationText)
                                DSButton(.composerChangeLocation, "Change…", variant: .outline, size: .xs)
                            }
                        }
                    }
                }
                .transition(MotionPolicy.shared.reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -DS.Space.s1)))
            }
        }
        .animation(MotionPolicy.shared.animation(MotionTokens.Easing.standard, MotionTokens.Duration.base), value: model.advancedOpen)
    }

    // MARK: Resumo, erro e footer

    /// Fora do Advanced só fica o aviso de um perfil que pula as permissões (sob o campo Profile); o comando inteiro mora no Advanced.
    @ViewBuilder private var summary: some View {
        if model.summary.contains("--dangerously-skip-permissions"), !model.confirmingRisk {
            HStack(spacing: DS.Space.s1) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: DS.Space.s2_5))
                // Diz o nome do perfil: "Default" que pula as permissões parecia contradição.
                Text(verbatim: String(localized: "The \(model.profileName) profile skips permission prompts: the agent won't ask before running commands", bundle: .module))
                    .dsFont(DS.Font.label)
            }
            .foregroundStyle(DS.Color.warning)
            .a11y(.overlayComposerSkipPermissions, kind: "text")
        }
    }

    private var command: some View {
        let text = model.summary
        return field("Command") {
            Text(verbatim: text)
                .dsFont(DS.Font.monoMicro)
                .foregroundStyle(DS.Color.textSecondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .dsTooltip(text, side: .top)
                .a11y(.overlayComposerSummary, kind: "text", value: text)
        }
    }

    private func errorBox(_ issue: ComposerIssue) -> some View {
        HStack(spacing: DS.Space.s2) {
            Image(systemName: "exclamationmark.circle").font(.system(size: DS.Space.s3))
            Text(verbatim: issue.message).dsFont(DS.Font.small)
            if issue.recovery == .reuseBranch {
                DSButton(.composerReuseBranch, id: nil, "Reuse it", variant: .link, size: .xs, argument: .press)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(DS.Color.destructive)
        .padding(.horizontal, DS.Space.s3)
        .padding(.vertical, DS.Space.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.Color.destructive.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(DS.Color.destructive.opacity(0.4), lineWidth: DSMetrics.hairline))
        .a11y(.overlayComposerError(issue.field.rawValue), kind: "text", label: issue.message)
    }

    @ViewBuilder private var footer: some View {
        if model.confirmingDiscard {
            HStack(spacing: DS.Space.s2) {
                Text("Discard this session?", bundle: .module)
                    .dsFont(DS.Font.body)
                    .foregroundStyle(DS.Color.textPrimary)
                Spacer(minLength: DS.Space.s2)
                DSButton(.composerKeepEditing, "Keep Editing", variant: .outline, size: .compact)
                DSButton(.composerDiscard, "Discard", variant: .destructive, size: .compact)
            }
        } else if model.confirmingRisk {
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                HStack(alignment: .top, spacing: DS.Space.s1) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: DS.Space.s2_5))
                    // Diz qual campo causa cada risco (Profile e Save data to): sem isso os testers não sabiam o que mudar.
                    Text(verbatim: String(localized: "Two risks together: the \(model.profileName) profile skips permission prompts, and Save data to copies what the agent collects to a protected table. Go back to change the profile or Save data to.", bundle: .module))
                        .dsFont(DS.Font.label).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(DS.Color.warning)
                .a11y(.overlayComposerRiskNote, kind: "text")
                HStack(spacing: DS.Space.s2) {
                    Spacer(minLength: DS.Space.s2)
                    // O caminho seguro é o destacado; criar mesmo assim fica no botão de contorno.
                    DSButton(.composerKeepEditing, "Back", variant: .primary, size: .compact)
                    // Sem atalho: ⌘↵ de novo não confirma o risco sem querer (precisa do clique).
                    DSButton(.composerSubmit, id: .overlayComposerSubmit, "Create anyway", variant: .outline, size: .compact, argument: .select("anyway"))
                }
            }
        } else {
            HStack(spacing: DS.Space.s2) {
                DSSwitch(isOn: model.draft.createMore, action: .composerCreateMore, id: .overlayComposerCreateMore, "Create More", compact: true)
                Spacer(minLength: DS.Space.s2)
                DSButton(.composerCancel, id: .overlayComposerCancel, "Cancel", variant: .outline, size: .compact, keycap: "esc")
                DSButton(.composerSubmit, id: .overlayComposerSubmit, "Create Session", variant: .primary, size: .compact, keycap: "⌘↵")
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.canSubmit)
            }
        }
    }

    // MARK: Peças

    private func field(_ title: LocalizedStringKey, trailing: AnyView? = nil, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s1_5) {
            HStack {
                Text(title, bundle: .module)
                    .dsFont(DS.Font.label)
                    .foregroundStyle(DS.Color.textSecondary)
                Spacer(minLength: DS.Space.s2)
                if let trailing { trailing }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Textos e listas

extension ComposerWhere {
    func title(hasProject: Bool, kind: ProjectKind) -> LocalizedStringKey {
        switch self {
        case .newWorktree: "New Worktree"
        case .existingWorktree: "Existing Worktree"
        case .mainCheckout: kind == .folder ? "Project Folder" : "Main Checkout"
        case .newFolder: "New Folder"
        case .chooseFolder: "Choose Folder…"
        }
    }
}

extension ComposerModel {
    var baseLabel: String {
        let text = draft.createFromText
        if !text.isEmpty, createFromLookup != nil, createFromLookup != GitBranchLookup.none { return text }
        return draft.baseRef ?? defaultBaseRef
    }

    var locationText: String {
        draft.worktreeLocation(context).map { ComposerDraft.abbreviate($0, home: context.home) } ?? ""
    }

    var projectEntries: [DSMenuEntry] {
        var entries: [DSMenuEntry] = projects.map { project in
            .item(DSMenuItem(
                project.id.uuidString, project.name, icon: .symbol("folder"),
                detail: ComposerDraft.abbreviate(project.rootPath, home: context.home), detailMono: true, detailInTrigger: true))
        }
        if !entries.isEmpty { entries.append(.separator("projects")) }
        entries.append(.item(DSMenuItem("none", String(localized: "No Project (Clean Session)", bundle: .module), icon: .symbol("sparkles"))))
        entries.append(.separator("pinned"))
        entries.append(.item(DSMenuItem("add", String(localized: "Add a New Project…", bundle: .module), icon: .symbol("plus"), pinned: true, action: .composerSetProject)))
        entries.append(.item(DSMenuItem("clone", String(localized: "Clone from GitHub…", bundle: .module), icon: .symbol("arrow.down.circle"), pinned: true, action: .projectCloneFromGitHub)))
        return entries
    }

    var agentEntries: [DSMenuEntry] {
        func item(_ provider: TerminalProvider, _ kind: DSAgentKind) -> DSMenuEntry {
            let info = agentInfo(provider)
            let name = AgentInfo.displayName(provider)
            if info?.isInstalled == false {
                return .item(DSMenuItem(provider.rawValue, name, icon: .agent(kind), disabledReason: String(localized: "Not installed", bundle: .module)))
            }
            if info?.isLoggedOut == true {
                return .item(DSMenuItem(provider.rawValue, name, icon: .symbol("exclamationmark.triangle"), detail: String(localized: "Not logged in", bundle: .module)))
            }
            return .item(DSMenuItem(provider.rawValue, name, icon: .agent(kind)))
        }
        return [
            item(.claude, .claude), item(.codex, .codex), item(.opencode, .opencode),
            .separator("agents"),
            .item(DSMenuItem(TerminalProvider.shell.rawValue, String(localized: "Blank Terminal", bundle: .module), icon: .agent(.shell))),
            .separator("pinned"),
            .item(DSMenuItem("manage", String(localized: "Manage Agents…", bundle: .module), icon: .symbol("gearshape"), pinned: true, action: .composerManageAgents)),
        ]
    }

    var profileEntries: [DSMenuEntry] {
        var entries: [DSMenuEntry] = providerProfiles.map { profile in
            let flags = profileFlags(profile)
            return .item(DSMenuItem(profile.id.uuidString, profile.name, detail: flags, detailMono: true))
        }
        entries.append(.separator("pinned"))
        entries.append(.item(DSMenuItem("edit", String(localized: "Edit Profiles…", bundle: .module), icon: .symbol("slider.horizontal.3"), pinned: true, action: .composerEditProfiles)))
        return entries
    }

    /// Flags do perfil em `mono` (`--dangerously-skip-permissions`), pelo mesmo planejador do lançamento.
    private func profileFlags(_ profile: LaunchProfile) -> String? {
        let text = LaunchPreview.command(spec: LaunchSpec(provider: profile.provider, profileID: profile.id), catalog: settingsCatalog, projectID: nil)
        let words = text.split(separator: " ").dropFirst()
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    var worktreeEntries: [DSMenuEntry] {
        let users = worktreeUsers
        return worktrees.map { wt in
            let name = wt.branch.isEmpty ? URL(fileURLWithPath: wt.path).lastPathComponent : wt.branch
            let detail = users[wt.id].map { String(localized: "Used by \($0)", bundle: .module) } ?? ComposerDraft.abbreviate(wt.path, home: context.home)
            return .item(DSMenuItem(wt.id.uuidString, name, icon: .symbol("arrow.triangle.branch"), detail: detail, detailMono: users[wt.id] == nil, detailInTrigger: false))
        }
    }

    /// `origin/main` com remoto; `main` num repo só local.
    var defaultBaseRef: String { hasOrigin ? "origin/\(defaultBranch ?? "main")" : (defaultBranch ?? "main") }

    var baseEntries: [DSMenuEntry] {
        let main = defaultBaseRef
        var refs = [main] + baseBranches.filter { $0 != main && $0 != defaultBranch }
        if refs.count > 30 { refs = Array(refs.prefix(30)) }
        return refs.enumerated().map { index, ref in
            .item(DSMenuItem(ref, ref, icon: .symbol("arrow.triangle.branch"), detail: index == 0 ? String(localized: "Default", bundle: .module) : nil, checked: ref == baseLabel))
        }
    }
}
