import RackyCore
import RackyDesignSystem
import RackyProtocol
import SwiftUI

/// Criar agente ou skill: a conversa com o Claude à esquerda, o rascunho que se preenche à direita (backlog 25 d, e, h).
struct AgentCreatePageView: View {
    let controller: AgentCreateController

    private var isAgent: Bool { controller.kind == .agent }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(verbatim: isAgent ? String(localized: "New Agent", bundle: .module) : String(localized: "New Skill", bundle: .module)) {
                DSSegmented(
                    [.init("scratch", "From scratch"), .init("description", "From a description"), .init("import", "Import a .md")],
                    selection: controller.mode.rawValue, action: .agentsCreateSetMode, id: .agentsCreateImport)
            }
            HStack(spacing: 0) {
                AgentChatColumn(controller: controller).frame(width: AgentMetrics.chatWidth)
                DS.Color.border.frame(width: AgentMetrics.separator)
                AgentDraftColumn(controller: controller)
            }
        }
        .background(DS.Color.canvas)
        .a11y(.agentsCreatePage, kind: "page")
    }
}

private struct AgentChatColumn: View {
    let controller: AgentCreateController

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.s3) {
                        ForEach(Array(controller.messages.enumerated()), id: \.element.id) { index, message in
                            bubble(message).a11y(.agentsCreateMessage("\(index)"), kind: "text", label: message.text).id(message.id)
                        }
                        if controller.isSending {
                            HStack(spacing: DS.Space.s2) {
                                DSSpinner(size: DS.Space.s4, delayed: false)
                                Text("Claude is writing…", bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                            }
                            .id("sending")
                        }
                    }
                    .padding(DS.Space.s4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: controller.messages.count) { _, _ in
                    if let last = controller.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .a11y(.agentsCreateChat, kind: "container")
            }
            composer
        }
    }

    @ViewBuilder private func bubble(_ m: AuthoringMessage) -> some View {
        VStack(alignment: m.role == .user ? .trailing : .leading, spacing: DS.Space.s1) {
            Text(verbatim: m.text)
                .dsFont(DS.Font.body)
                .foregroundStyle(m.role == .user ? DS.Color.textPrimary : DS.Color.textSecondary)
                .textSelection(.enabled)
                .padding(m.role == .user ? DS.Space.s2_5 : .zero)
                .background { if m.role == .user { RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Color.fg5) } }
            if !m.fileNames.isEmpty {
                ChipFlow { ForEach(m.fileNames, id: \.self) { DSBadge($0, variant: .mono) } }
            }
        }
        .frame(maxWidth: .infinity, alignment: m.role == .user ? .trailing : .leading)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            if !controller.pendingUploads.isEmpty {
                ChipFlow {
                    ForEach(Array(controller.pendingUploads.enumerated()), id: \.element.id) { index, u in
                        DSBadge(u.name, variant: .mono).a11y(.agentsCreateUpload("\(index)"), kind: "text", label: u.name)
                    }
                }
            }
            if let error = controller.error {
                Text(verbatim: error).dsFont(DS.Font.small).foregroundStyle(DS.Color.destructive).a11y(.agentsCreateError, kind: "text", label: error)
            }
            DSTextField("Answer Claude, or paste an example", text: Bindable(controller).input, id: .agentsCreateInput, multiline: true, compact: true)
            HStack(spacing: DS.Space.s2) {
                DSButton(.agentsCreateAttach, id: .agentsCreateAttach, "Add Files…", variant: .ghost, size: .sm, symbol: "paperclip")
                Spacer(minLength: DS.Space.s2)
                ActionButton(.agentsCreateSend, id: .agentsCreateSend, argument: .set(controller.input)) {
                    HStack(spacing: DS.Space.s1_5) {
                        Image(systemName: "arrow.up")
                        Text("Send", bundle: .module)
                    }
                }
                .buttonStyle(DSButtonStyle(.primary, .sm, hasIcon: true))
                .disabled(controller.isSending || (controller.input.trimmingCharacters(in: .whitespaces).isEmpty && controller.pendingUploads.isEmpty))
            }
        }
        .padding(DS.Space.s3)
        .overlay(alignment: .top) { DS.Color.border.frame(height: AgentMetrics.separator) }
    }
}

private struct AgentDraftColumn: View {
    let controller: AgentCreateController

    private var isAgent: Bool { controller.kind == .agent }

    private func binding(_ field: String) -> Binding<String> {
        Binding(get: { controller.value(of: field) }, set: { try? controller.setField(field, $0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.s4) {
                    if isAgent { faces }
                    block("Name") { DSTextField("kebab-case-name", text: binding("name"), id: .agentsCreateName, compact: true, mono: true) }
                    block("Description") {
                        DSTextField(isAgent ? "What this agent does" : "When Claude should use this skill", text: binding("description"), id: .agentsCreateDescription, compact: true)
                    }
                    if isAgent {
                        block("How it talks") {
                            DSTextField("Short and direct, with the number and the file", text: binding("tone"), id: .agentsCreateTone, compact: true)
                        }
                    }
                    block(isAgent ? "Instructions" : "SKILL.md") {
                        DSTextField("Filled in as you talk", text: binding("instructions"), id: .agentsCreateInstructions, multiline: true, mono: true)
                    }
                    if isAgent {
                        block("Skills") {
                            DSTextField("tdd, qa", text: binding("skills"), id: .agentsCreateSkills, compact: true, mono: true)
                        }
                        block("Computer") {
                            DSSegmented(
                                [.init("computer=off", "No computer"), .init("computer=on", "With a computer")], selection: "computer=\(controller.draft.needsComputer ? "on" : "off")",
                                action: .agentsCreateSetField, id: .agentsCreateComputer)
                        }
                    }
                    attachments
                }
                .padding(DS.Space.s4)
                .a11y(.agentsCreateDraft, kind: "container")
            }
            footer
        }
        .background(DS.Color.sidebar)
    }

    private func block<Content: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s1_5) {
            Text(title, bundle: .module).dsFont(DS.Font.sectionLabel).foregroundStyle(DS.Color.textSecondary)
            content()
        }
    }

    private var faces: some View {
        block("Face") {
            HStack(spacing: DS.Space.s2) {
                ForEach(0..<AgentCreateController.avatarChoices, id: \.self) { index in
                    ActionButton(.agentsCreatePickAvatar, id: .agentsCreateAvatar("\(index)"), argument: .select("\(index)")) {
                        AgentAvatarView(image: AgentAvatarImages.image(name: controller.avatarName, variant: index), size: AgentMetrics.pickAvatar)
                            .padding(DS.Space.s0_5)
                            .overlay(Circle().strokeBorder(controller.photo == nil && controller.variant == index ? DS.Color.textSecondary : Color.clear, lineWidth: DSMetrics.hairline * 2))
                    }
                    .buttonStyle(.plain)
                }
                ActionButton(.agentsCreateUploadPhoto, id: .agentsCreatePhoto) {
                    ZStack {
                        if let url = controller.photo, let image = NSImage(contentsOf: url) {
                            AgentAvatarView(image: image, size: AgentMetrics.pickAvatar)
                        } else {
                            Circle().strokeBorder(DS.Color.border, style: StrokeStyle(lineWidth: DSMetrics.hairline, dash: [DS.Space.s1]))
                                .frame(width: AgentMetrics.pickAvatar, height: AgentMetrics.pickAvatar)
                            Image(systemName: "photo").foregroundStyle(DS.Color.textTertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .dsTooltip(String(localized: "Upload Photo…", bundle: .module))
            }
        }
    }

    private var attachments: some View {
        block(isAgent ? "Fixed attachments" : "Files that go with it") {
            VStack(alignment: .leading, spacing: DS.Space.s1) {
                ForEach(controller.uploads) { u in
                    HStack(spacing: DS.Space.s2) {
                        Image(systemName: AgentCreateController.isSpreadsheet(u.name) ? "tablecells" : "doc").foregroundStyle(DS.Color.textTertiary)
                        Text(verbatim: u.name).dsFont(DS.Font.label).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                        Spacer(minLength: DS.Space.s1)
                        Text(verbatim: u.text == nil ? String(localized: "kept, not read", bundle: .module) : String(localized: "read by Claude", bundle: .module))
                            .dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                    }
                }
                if isAgent {
                    ForEach(controller.chosen, id: \.reference) { item in
                        HStack(spacing: DS.Space.s2) {
                            Image(systemName: AgentPageView.symbol(item.kind)).foregroundStyle(DS.Color.textTertiary)
                            Text(verbatim: item.title).dsFont(DS.Font.label).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                            Spacer(minLength: DS.Space.s1)
                            Text(verbatim: item.kind.rawValue).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                        }
                    }
                    DSCombobox(
                        id: .agentsCreateAttachmentAdd, selection: "", entries: controller.agents.attachableEntries(), action: .agentsCreateAttach,
                        searchPlaceholder: String(localized: "Search items", bundle: .module), placeholder: String(localized: "Add session, computer or dataset…", bundle: .module))
                } else if controller.uploads.isEmpty {
                    Text("Examples and references you drop in the chat are saved with the skill.", bundle: .module).dsFont(DS.Font.small).foregroundStyle(DS.Color.textTertiary)
                }
            }
            .a11y(.agentsCreateAttachments, kind: "container")
        }
    }

    private var footer: some View {
        HStack(spacing: DS.Space.s2) {
            Spacer(minLength: DS.Space.s2)
            DSButton(.agentsCreateCancel, id: .agentsCreateCancel, "Discard", variant: .ghost, size: .sm)
            DSButton(.agentsCreateConfirm, id: .agentsCreateConfirm, isAgent ? "Create Agent" : "Create Skill", variant: .primary, size: .sm)
        }
        .padding(DS.Space.s3)
        .overlay(alignment: .top) { DS.Color.border.frame(height: AgentMetrics.separator) }
    }
}
