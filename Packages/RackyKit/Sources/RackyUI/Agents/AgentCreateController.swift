import RackyCore
import RackyProtocol
import Foundation
import Observation

/// Criar agente ou skill com a ajuda do Claude (backlog 25 d, e, f, h): conversa de um lado, rascunho do outro, avatar, anexos e
/// arquivos que o usuário sobe para o agente (ou a skill) sempre trabalhar do mesmo jeito.
@MainActor @Observable
final class AgentCreateController {
    let agents: AgentsController
    var kind: AgentCreateKind = .agent
    var mode: AgentCreateMode = .scratch
    private(set) var messages: [AuthoringMessage] = []
    var input = ""
    private(set) var uploads: [AuthoringUpload] = []
    /// Arquivos subidos que ainda não foram numa mensagem (aparecem como etiquetas em cima da caixa).
    private(set) var pendingUploads: [AuthoringUpload] = []
    var draft = AuthoringDraft()
    private(set) var variant = 0
    private(set) var photo: URL?
    private(set) var chosen: [AgentAttachable] = []
    private(set) var isSending = false
    private(set) var error: String?

    @ObservationIgnored var runner: any AuthoringRunner = ClaudeCLIAuthoringRunner()
    @ObservationIgnored var skills = SkillStore(root: SkillStore.defaultRoot())
    @ObservationIgnored var closePage: @MainActor () -> Void = {}
    @ObservationIgnored var skillCreated: @MainActor (String) -> Void = { _ in }
    @ObservationIgnored private var sending: Task<Void, Never>?

    init(agents: AgentsController) { self.agents = agents }

    // MARK: Começar

    func begin(kind: AgentCreateKind, mode: AgentCreateMode) async {
        sending?.cancel()
        self.kind = kind
        self.mode = mode
        messages = [AuthoringMessage(role: .assistant, text: Self.greeting(kind))]
        input = ""; uploads = []; pendingUploads = []; draft = AuthoringDraft(); variant = 0; photo = nil; chosen = []; error = nil; isSending = false
        if mode == .import { await importFile(nil) }
    }

    static func greeting(_ kind: AgentCreateKind) -> String {
        kind == .agent
            ? String(localized: "Tell me what this agent does and how you want it to talk. Drop in any example of the result you want and it will always do it the same way.", bundle: .module)
            : String(localized: "Tell me what this skill teaches and how you will know it came out right. Drop in examples of the result and the files it should follow.", bundle: .module)
    }

    /// Importa um `.md` (ou `SKILL.md`) para o rascunho. `url == nil` abre o seletor de arquivo.
    func importFile(_ url: URL?) async {
        let picked: URL? = if let url { url } else { await agents.pickFile(["md", "markdown"]) }
        guard let file = picked else { return }
        guard let imported = AgentImporter.importMarkdown(at: file) else {
            error = String(localized: "Racky couldn't read that file.", bundle: .module)
            return
        }
        error = nil
        draft.name = AuthoringDraft.slug(imported.name)
        draft.description = imported.description
        draft.instructions = imported.instructions
        draft.skills = imported.skills
        messages.append(AuthoringMessage(role: .assistant, text: String(localized: "I read \(file.lastPathComponent). Tell me what to change, or create it as it is.", bundle: .module)))
    }

    // MARK: Conversa

    func attach(file url: URL) {
        let upload = AuthoringUpload(url: url)
        uploads.append(upload)
        pendingUploads.append(upload)
    }

    func attach(_ item: AgentAttachable) {
        guard !chosen.contains(item) else { return }
        chosen.append(item)
    }

    func removeChosen(_ item: AgentAttachable) { chosen.removeAll { $0 == item } }

    func send(_ text: String) async throws {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty || !pendingUploads.isEmpty else { throw ActionError.failed(.agentsCreateSend, message: String(localized: "Write a message first.", bundle: .module)) }
        guard !isSending else { throw ActionError.failed(.agentsCreateSend, message: String(localized: "Claude is still answering.", bundle: .module)) }
        messages.append(AuthoringMessage(role: .user, text: t.isEmpty ? String(localized: "Here are the files.", bundle: .module) : t, fileNames: pendingUploads.map(\.name)))
        pendingUploads = []
        input = ""
        error = nil
        isSending = true
        let system = AgentAuthoring.systemPrompt(for: kind == .agent ? .agent : .skill)
        let prompt = AgentAuthoring.prompt(messages: messages.filter { $0.role == .user || $0.text != Self.greeting(kind) }, uploads: uploads, draft: draft)
        let runner = runner
        defer { isSending = false }
        do {
            let response = try await runner.complete(system: system, prompt: prompt)
            let (reply, patch) = AgentAuthoring.parse(response)
            messages.append(AuthoringMessage(role: .assistant, text: reply.isEmpty ? String(localized: "Updated the draft.", bundle: .module) : reply))
            if let patch { draft.apply(patch) }
        } catch {
            self.error = "\(error)"
            throw ActionError.failed(.agentsCreateSend, message: "\(error)")
        }
    }

    // MARK: Rascunho

    func setField(_ field: String, _ value: String) throws {
        switch field {
        case "name": draft.name = Self.typingSlug(value)
        case "description": draft.description = value
        case "instructions": draft.instructions = value
        case "tone": draft.tone = value
        case "skills": draft.skills = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        case "computer": draft.needsComputer = value == "on"
        default: throw ActionError.failed(.agentsCreateSetField, message: "unknown field \(field)")
        }
    }

    /// Enquanto digita: minúsculas e traço no lugar do que não vale, sem cortar o traço do fim (senão `meu agente` nunca sairia).
    static func typingSlug(_ s: String) -> String {
        let dashed = s.lowercased().folding(options: .diacriticInsensitive, locale: nil).replacingOccurrences(of: "[^a-z0-9._]+", with: "-", options: .regularExpression)
        return String(dashed.drop(while: { $0 == "-" || $0 == "." || $0 == "_" }).prefix(64))
    }

    func value(of field: String) -> String {
        switch field {
        case "name": draft.name
        case "description": draft.description
        case "instructions": draft.instructions
        case "tone": draft.tone
        case "skills": draft.skills.joined(separator: ", ")
        default: ""
        }
    }

    var avatarName: String { draft.name.isEmpty ? "new-agent" : draft.name }

    func pickAvatar(_ index: Int) throws {
        guard (0..<Self.avatarChoices).contains(index) else { throw ActionError.failed(.agentsCreatePickAvatar, message: "expected select(0...\(Self.avatarChoices - 1))") }
        variant = index
        photo = nil
    }

    static let avatarChoices = 6

    func setPhoto(_ url: URL) throws {
        guard AgentStore.photoExtensions.contains(url.pathExtension.lowercased()) else {
            throw ActionError.failed(.agentsCreateUploadPhoto, message: String(localized: "Use a PNG, JPEG, HEIC or WebP photo.", bundle: .module))
        }
        guard ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) <= AgentStore.maxPhotoBytes else {
            throw ActionError.failed(.agentsCreateUploadPhoto, message: String(localized: "That photo is over 5 MB.", bundle: .module))
        }
        photo = url
    }

    // MARK: Confirmar

    /// Cria o agente ou a skill. Devolve o nome.
    @discardableResult
    func confirm() async throws -> String {
        let name = AuthoringDraft.slug(draft.name)
        draft.name = name
        let action: ActionID = .agentsCreateConfirm
        guard !name.isEmpty else { throw ActionError.failed(action, message: String(localized: "Give it a name first.", bundle: .module)) }
        guard AgentDefinition.isValidName(name) else { throw ActionError.failed(action, message: String(localized: "Use letters, numbers and dashes in the name.", bundle: .module)) }
        let files = uploads
        if kind == .skill {
            guard !skills.exists(name) else { throw ActionError.failed(action, message: String(localized: "A skill with this name already exists.", bundle: .module)) }
            let payload = files.compactMap { u -> (name: String, data: Data, folder: String)? in
                guard !u.path.isEmpty, let data = try? Data(contentsOf: URL(fileURLWithPath: u.path)) else { return nil }
                return (u.name, data, Self.isExample(u.name) ? "examples" : "references")
            }
            do { try skills.create(name: name, description: draft.description, body: draft.instructions, files: payload) } catch {
                throw ActionError.failed(action, message: "\(error)")
            }
            await agents.reload()
            skillCreated(name)
            return name
        }
        guard !agents.store.exists(name) else { throw ActionError.failed(action, message: String(localized: "An agent with this name already exists.", bundle: .module)) }
        let def = AgentDefinition(
            name: name, description: draft.description, instructions: draft.instructions, skills: draft.skills, tone: draft.tone,
            avatar: AgentAvatar(kind: .generated, variant: variant), computer: draft.needsComputer ? AgentComputerPreset() : nil)
        do {
            try agents.store.create(def)
            if let photo, let data = try? Data(contentsOf: photo) { try agents.store.setPhoto(name, data: data, fileExtension: photo.pathExtension) }
            var manifest = AgentAttachmentManifest()
            let folder = try agents.store.folder(for: name).appendingPathComponent("files", isDirectory: true)
            for u in files where !u.path.isEmpty {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let target = folder.appendingPathComponent(u.name)
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: URL(fileURLWithPath: u.path), to: target)
                manifest.add(AgentAttachment(kind: Self.isSpreadsheet(u.name) ? .spreadsheet : .file, title: u.name, reference: target.path))
            }
            for c in chosen { manifest.add(AgentAttachment(kind: c.kind, title: c.title, reference: c.reference)) }
            try agents.store.setAttachments(name, manifest)
        } catch {
            throw ActionError.failed(action, message: "\(error)")
        }
        await agents.reload()
        try await agents.open(name)
        return name
    }

    static func isExample(_ file: String) -> Bool {
        let l = file.lowercased()
        return ["example", "exemplo", "sample", "silver", "output"].contains { l.contains($0) } || ["parquet", "csv"].contains((l as NSString).pathExtension)
    }

    static func isSpreadsheet(_ file: String) -> Bool { ["xlsx", "xls", "csv", "tsv", "numbers", "ods"].contains((file as NSString).pathExtension.lowercased()) }

    func cancel() {
        sending?.cancel()
        closePage()
    }

    // MARK: Ações

    func register(in registry: ActionRegistry) throws {
        try registry.register(.agentsCreateSetMode) { [unowned self] arg in
            guard arg.kind == .select, let raw = arg.value, let m = AgentCreateMode(rawValue: raw) else { throw ActionError.failed(.agentsCreateSetMode, message: "expected select(scratch|description|import)") }
            mode = m
            if m == .import { await importFile(nil) }
            return raw
        }
        try registry.register(.agentsCreateSend) { [unowned self] arg in
            guard arg.kind == .set || arg.kind == .select else { throw ActionError.failed(.agentsCreateSend, message: "expected set(<text>)") }
            try await send(arg.value ?? input)
            return "\(messages.count)"
        }
        try registry.register(.agentsCreateAttach) { [unowned self] arg in
            if let raw = arg.value, arg.kind == .select || arg.kind == .set {
                let parts = raw.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                if parts.count == 3, let k = AgentAttachmentKind(rawValue: parts[0]) {
                    attach(AgentAttachable(kind: k, title: parts[1], reference: parts[2]))
                    return parts[1]
                }
                guard FileManager.default.fileExists(atPath: raw) else { throw ActionError.failed(.agentsCreateAttach, message: String(localized: "That file doesn't exist.", bundle: .module)) }
                attach(file: URL(fileURLWithPath: raw))
                return raw
            }
            guard let url = await agents.pickFile([]) else { return "cancelled" }
            attach(file: url)
            return url.path
        }
        try registry.register(.agentsCreateSetField) { [unowned self] arg in
            guard let raw = arg.value, arg.kind == .set || arg.kind == .select, let eq = raw.firstIndex(of: "=") else {
                throw ActionError.failed(.agentsCreateSetField, message: "expected set(<field>=<value>)")
            }
            try setField(String(raw[..<eq]), String(raw[raw.index(after: eq)...]))
            return String(raw[..<eq])
        }
        try registry.register(.agentsCreatePickAvatar) { [unowned self] arg in
            guard arg.kind == .select, let raw = arg.value, let i = Int(raw) else { throw ActionError.failed(.agentsCreatePickAvatar, message: "expected select(<n>)") }
            try pickAvatar(i)
            return raw
        }
        try registry.register(.agentsCreateUploadPhoto) { [unowned self] arg in
            if arg.kind == .select, let path = arg.value, !path.isEmpty {
                try setPhoto(URL(fileURLWithPath: path))
                return path
            }
            guard let url = await agents.pickFile(["png", "jpg", "jpeg", "heic", "webp"]) else { return "cancelled" }
            try setPhoto(url)
            return url.path
        }
        try registry.register(.agentsCreateConfirm) { [unowned self] _ in try await confirm() }
        try registry.register(.agentsCreateCancel) { [unowned self] _ in
            cancel()
            return "cancelled"
        }
    }
}
