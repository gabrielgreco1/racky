import RackyPlatform
import RackyCore
import RackyDesignSystem
import RackyProtocol
import SwiftUI

/// Campo de texto que grava sozinho: espera uma pausa na digitação e manda `agents.setField` (ou a ação dada).
struct AgentFieldEditor: View {
    let placeholder: LocalizedStringKey
    let initial: String
    let id: A11yID
    var multiline = false
    var mono = false
    var compact = false
    let send: (String) -> (ActionID, ActionArgument)
    @State private var text = ""
    @State private var loaded = false
    @State private var pending: Task<Void, Never>?
    @Environment(\.actionRegistry) private var registry

    var body: some View {
        DSTextField(placeholder, text: $text, id: id, multiline: multiline, compact: compact, mono: mono)
            .onAppear { if !loaded { text = initial; loaded = true } }
            .onChange(of: text) { _, new in
                guard loaded, new != initial else { return }
                pending?.cancel()
                pending = Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled, let registry else { return }
                    let (action, argument) = send(new)
                    await registry.performFromUI(action, argument)
                }
            }
    }
}

private struct AgentBlock<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            Text(title, bundle: .module).dsFont(DS.Font.sectionLabel).foregroundStyle(DS.Color.textSecondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Página do agente (backlog 25 b): rosto, jeito de falar, instruções, skills, anexos fixos, computador pronto, variáveis,
/// sites logados e memória editável.
struct AgentPageView: View {
    let controller: AgentsController
    let name: String

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(verbatim: name) {
                DSButton(.agentsNewSession, id: .agentsNewSession, "New Session with Agent", variant: .outline, size: .xs, argument: .select(name))
                if controller.confirmingDelete == name {
                    DSButton(.agentsDelete, id: .agentsDelete, "Delete for good", variant: .destructive, size: .xs, argument: .select(name))
                } else {
                    DSIconButton(.agentsDelete, id: .agentsDelete, symbol: "trash", name: String(localized: "Delete Agent…", bundle: .module), variant: .header)
                }
            }
            if let agent = controller.agent(name) {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.s6) {
                        identity(agent)
                        HStack(alignment: .top, spacing: DS.Space.s6) {
                            VStack(alignment: .leading, spacing: DS.Space.s6) {
                                instructions(agent)
                                skills(agent)
                                attachments(agent)
                                memory(agent)
                            }
                            .frame(minWidth: AgentMetrics.columnMin, maxWidth: .infinity, alignment: .topLeading)
                            VStack(alignment: .leading, spacing: DS.Space.s6) {
                                computer(agent)
                                variables(agent)
                                sites(agent)
                            }
                            .frame(minWidth: AgentMetrics.columnMin, maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                    .padding(DS.Space.s6)
                    .frame(maxWidth: AgentMetrics.pageMaxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(agent.name)
            } else {
                DSEmptyState(String(localized: "This agent no longer exists.", bundle: .module)) { EmptyView() }
                    .a11y(.agentsEmpty, kind: "container")
            }
        }
        .background(DS.Color.canvas)
        .a11y(.agentsPage, kind: "page")
        .task(id: name) { await controller.loadDetail(name) }
    }

    // MARK: Identidade

    private func identity(_ agent: AgentDefinition) -> some View {
        HStack(alignment: .top, spacing: DS.Space.s4) {
            VStack(spacing: DS.Space.s2) {
                AgentAvatarView(image: controller.images[agent.name], size: AgentMetrics.pageAvatar).a11y(.agentsAvatar, kind: "image")
                HStack(spacing: DS.Space.s1) {
                    DSIconButton(.agentsRegenerateAvatar, id: .agentsAvatarRegenerate, symbol: "arrow.triangle.2.circlepath", name: String(localized: "Regenerate Avatar", bundle: .module), variant: .row, argument: .select(agent.name))
                    DSIconButton(.agentsSetPhoto, id: .agentsAvatarUpload, symbol: "photo", name: String(localized: "Upload Photo…", bundle: .module), variant: .row)
                }
            }
            VStack(alignment: .leading, spacing: DS.Space.s3) {
                Text(verbatim: agent.name).dsFont(DS.Font.pageTitle).foregroundStyle(DS.Color.textPrimary).a11y(.agentsName, kind: "text", label: agent.name)
                AgentBlock(title: "Description") {
                    AgentFieldEditor(placeholder: "What this agent does", initial: agent.description, id: .agentsDescription, compact: true) { (.agentsSetField, .set("description=\($0)")) }
                }
                AgentBlock(title: "How it talks") {
                    AgentFieldEditor(placeholder: "Short and direct. Two sentences, always with the number and the file.", initial: agent.tone, id: .agentsTone, multiline: true, compact: true) { (.agentsSetField, .set("tone=\($0)")) }
                    Text("Used in its summaries and in the diary.", bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Coluna esquerda

    private func instructions(_ agent: AgentDefinition) -> some View {
        AgentBlock(title: "Instructions") {
            AgentFieldEditor(placeholder: "What the agent should do and how", initial: agent.instructions, id: .agentsInstructions, multiline: true, mono: true) { (.agentsSetField, .set("instructions=\($0)")) }
        }
    }

    private func skills(_ agent: AgentDefinition) -> some View {
        AgentBlock(title: "Skills") {
            AgentFieldEditor(placeholder: "tdd, qa, diagnosing-bugs", initial: agent.skills.joined(separator: ", "), id: .agentsSkills, mono: true, compact: true) { (.agentsSetField, .set("skills=\($0)")) }
            if !agent.skills.isEmpty {
                ChipFlow { ForEach(agent.skills, id: \.self) { DSBadge($0, variant: .mono) } }
            }
        }
    }

    private func attachments(_ agent: AgentDefinition) -> some View {
        AgentBlock(title: "Fixed attachments, in every task") {
            VStack(alignment: .leading, spacing: DS.Space.s1) {
                if controller.attachments.attachments.isEmpty {
                    Text("Sessions, computers, datasets, spreadsheets and files the agent always receives.", bundle: .module)
                        .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                }
                ForEach(controller.attachments.attachments) { item in
                    HStack(spacing: DS.Space.s2) {
                        Image(systemName: Self.symbol(item.kind)).foregroundStyle(DS.Color.textTertiary).frame(width: AgentMetrics.chipAvatar)
                        Text(verbatim: item.title).dsFont(DS.Font.label).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                        Spacer(minLength: DS.Space.s1)
                        Text(verbatim: item.kind.rawValue).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                        DSIconButton(.agentsRemoveAttachment, id: .agentsAttachmentRemove(item.id.uuidString), symbol: "xmark", name: String(localized: "Remove", bundle: .module), variant: .row, argument: .select(item.id.uuidString))
                    }
                    .a11y(.agentsAttachment(item.id.uuidString), kind: "row", label: item.title)
                }
                HStack(spacing: DS.Space.s2) {
                    DSCombobox(id: .agentsAttachmentAdd, selection: "", entries: controller.attachableEntries(), action: .agentsAddAttachment, searchPlaceholder: String(localized: "Search items", bundle: .module), placeholder: String(localized: "Add session, computer or dataset…", bundle: .module))
                    DSButton(.agentsAddAttachment, id: nil, "Add File…", variant: .outline, size: .sm, symbol: "paperclip")
                }
            }
            .a11y(.agentsAttachments, kind: "container")
        }
    }

    static func symbol(_ kind: AgentAttachmentKind) -> String {
        switch kind {
        case .session: "rectangle.stack"
        case .computer: "display"
        case .dataset: "cylinder.split.1x2"
        case .spreadsheet: "tablecells"
        case .file: "doc"
        }
    }

    private func memory(_ agent: AgentDefinition) -> some View {
        AgentMemoryBlock(controller: controller)
    }

    // MARK: Coluna direita

    private func computer(_ agent: AgentDefinition) -> some View {
        let preset = agent.computer
        let memoryMB = preset?.memoryMB ?? AgentComputerPreset().memoryMB
        return AgentBlock(title: "Ready computer") {
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                DSSegmented(
                    [.init("computer.enabled=off", "No computer"), .init("computer.enabled=on", "With a computer")], selection: "computer.enabled=\(preset == nil ? "off" : "on")",
                    action: .agentsSetField, id: .agentsComputer)
                if let preset {
                    DSSegmented(
                        [.init("computer.screen=off", "Screen off"), .init("computer.screen=on", "Screen on")], selection: "computer.screen=\(preset.screen ? "on" : "off")",
                        action: .agentsSetField, id: .agentsComputerScreen)
                    DSSegmented(
                        [.init("computer.memory=1024", "1 GB"), .init("computer.memory=2048", "2 GB"), .init("computer.memory=4096", "4 GB"), .init("computer.memory=8192", "8 GB")],
                        selection: "computer.memory=\(memoryMB)", action: .agentsSetField, id: .agentsComputerMemory)
                    AgentFieldEditor(placeholder: "Proxy country (US, BR…)", initial: preset.proxyCountry ?? "", id: .agentsComputerCountry, compact: true) { (.agentsSetField, .set("computer.country=\($0)")) }
                    AgentFieldEditor(placeholder: "Packages (pytest, playwright…)", initial: preset.packages.joined(separator: ", "), id: .agentsComputerPackages, mono: true, compact: true) { (.agentsSetField, .set("computer.packages=\($0)")) }
                } else {
                    Text("The agent works in the session folder, without its own computer.", bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                }
            }
        }
    }

    private func variables(_ agent: AgentDefinition) -> some View {
        AgentBlock(title: "Variables, only inside the computer") {
            VStack(alignment: .leading, spacing: DS.Space.s1) {
                ForEach(agent.variables) { v in
                    HStack(spacing: DS.Space.s2) {
                        Text(verbatim: v.envName).font(DS.Font.monoMicro.font).foregroundStyle(DS.Color.textPrimary)
                        Text(verbatim: "••••••••").dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                        Spacer(minLength: DS.Space.s1)
                        Text(verbatim: v.secretName).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary).lineLimit(1)
                        DSIconButton(.agentsRemoveVariable, id: .agentsVariableRemove(v.envName), symbol: "xmark", name: String(localized: "Remove", bundle: .module), variant: .row, argument: .select(v.envName))
                    }
                    .a11y(.agentsVariable(v.envName), kind: "row", label: v.envName)
                }
                AgentVariableAdder(controller: controller)
                Text("They never go into the prompt and show as ••• in logs.", bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
            }
            .a11y(.agentsVariables, kind: "container")
        }
    }

    private func sites(_ agent: AgentDefinition) -> some View {
        AgentBlock(title: "Logged-in sites") {
            VStack(alignment: .leading, spacing: DS.Space.s1) {
                ForEach(agent.sites) { site in
                    HStack(spacing: DS.Space.s2) {
                        Text(verbatim: site.host).dsFont(DS.Font.label).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                        Spacer(minLength: DS.Space.s1)
                        if site.isExpired(at: Date()) {
                            Text("Expired, log in again", bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.unread)
                        } else if let saved = site.savedAt {
                            Text(verbatim: saved.formatted(.relative(presentation: .named))).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                        } else {
                            Text("Not logged in yet", bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                        }
                        if controller.runningComputers.isEmpty == false {
                            DSCombobox(
                                id: .agentsSiteSave(site.host), selection: "",
                                entries: controller.runningComputers.map { .item(DSMenuItem("\(site.host)|\($0.title)", $0.title)) }, action: .agentsSaveSite,
                                placeholder: String(localized: "Save login from…", bundle: .module), height: DSMetrics.fieldHeightComposer)
                                .frame(width: AgentMetrics.saveLoginWidth)
                        }
                        DSIconButton(.agentsRemoveSite, id: .agentsSiteRemove(site.host), symbol: "xmark", name: String(localized: "Remove", bundle: .module), variant: .row, argument: .select(site.host))
                    }
                    .a11y(.agentsSite(site.host), kind: "row", label: site.host)
                }
                AgentSiteAdder()
                Text("Log in once with Take over on a computer, then choose Save login. Racky keeps the cookies encrypted in the vault and loads them into the agent's computers before it starts.", bundle: .module)
                    .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
            }
            .a11y(.agentsSites, kind: "container")
        }
    }
}

private struct AgentVariableAdder: View {
    let controller: AgentsController
    @State private var env = ""
    @State private var secret = ""

    var body: some View {
        HStack(spacing: DS.Space.s2) {
            DSTextField("ENV_NAME", text: $env, id: .agentsVariableEnvName, compact: true, mono: true)
            DSCombobox(
                id: .agentsVariableSecret, selection: secret, entries: controller.secretNames.map { .item(DSMenuItem($0, $0)) }, action: .agentsSetVariable,
                placeholder: String(localized: "Vault secret…", bundle: .module))
            ActionButton(.agentsSetVariable, id: .agentsVariableAdd, argument: .set("\(env)=\(secret)")) {
                Text("Add", bundle: .module)
            }
            .buttonStyle(DSButtonStyle(.outline, .sm, hasIcon: false))
            .disabled(env.isEmpty || secret.isEmpty)
        }
    }
}

private struct AgentSiteAdder: View {
    @State private var host = ""

    var body: some View {
        HStack(spacing: DS.Space.s2) {
            DSTextField("github.com", text: $host, id: .agentsSiteAdd, compact: true, mono: true)
            ActionButton(.agentsAddSite, argument: .set(host)) { Text("Add", bundle: .module) }
                .buttonStyle(DSButtonStyle(.outline, .sm, hasIcon: false))
                .disabled(host.isEmpty)
        }
    }
}

private struct AgentMemoryBlock: View {
    let controller: AgentsController
    @State private var search = ""
    @State private var title = ""
    @State private var note = ""

    var body: some View {
        AgentBlock(title: "Memory") {
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                DSTextField("Search the memory", text: $search, id: .agentsMemorySearch, action: .agentsMemorySearch, compact: true)
                if controller.visibleMemory.isEmpty {
                    Text(verbatim: controller.memoryQuery.isEmpty
                        ? String(localized: "After each task the agent saves a short entry here. You can read and edit all of it.", bundle: .module)
                        : String(localized: "Nothing matches.", bundle: .module))
                        .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                }
                ForEach(controller.visibleMemory) { entry in
                    AgentMemoryRow(controller: controller, entry: entry)
                }
                HStack(spacing: DS.Space.s2) {
                    DSTextField("Title", text: $title, id: .agentsMemoryAdd, compact: true)
                    DSTextField("What to remember", text: $note, id: .agentsMemoryAddBody, compact: true)
                    ActionButton(.agentsMemoryAdd, argument: .set("\(title)|\(note)")) { Text("Add", bundle: .module) }
                        .buttonStyle(DSButtonStyle(.outline, .sm, hasIcon: false))
                        .disabled(title.isEmpty && note.isEmpty)
                }
            }
            .a11y(.agentsMemory, kind: "container")
        }
    }
}

private struct AgentMemoryRow: View {
    let controller: AgentsController
    let entry: AgentMemoryEntry
    @State private var title = ""
    @State private var body_ = ""
    @State private var loaded = false
    @State private var pending: Task<Void, Never>?
    @Environment(\.actionRegistry) private var registry

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            HStack(spacing: DS.Space.s2) {
                DSTextField("Title", text: $title, id: .agentsMemoryEntry("\(entry.id)"), compact: true)
                Text(verbatim: entry.createdAt.formatted(date: .abbreviated, time: .omitted)).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                DSIconButton(.agentsMemoryDelete, id: .agentsMemoryEntryDelete("\(entry.id)"), symbol: "trash", name: String(localized: "Delete Entry", bundle: .module), variant: .row, argument: .select("\(entry.id)"))
            }
            DSTextField("Details", text: $body_, id: .agentsMemoryEntryBody("\(entry.id)"), multiline: true, compact: true)
        }
        .onAppear { if !loaded { title = entry.title; body_ = entry.body; loaded = true } }
        .onChange(of: title) { _, _ in save() }
        .onChange(of: body_) { _, _ in save() }
    }

    private func save() {
        guard loaded, title != entry.title || body_ != entry.body else { return }
        pending?.cancel()
        let id = entry.id, t = title, b = body_
        pending = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let registry else { return }
            await registry.performFromUI(.agentsMemoryEdit, .set("\(id)|\(t)|\(b)"))
        }
    }
}
