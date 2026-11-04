import RackyCore
import RackyDesignSystem
import RackyPlatform
import RackyProtocol
import AppKit
import Foundation
import Observation

/// Agentes do Racky (backlog 25): lista na sidebar, página do agente, memória, anexos, variáveis e sites. Os agentes moram em
/// `~/Racky/agents` (`AgentStore`); nada é escrito em `~/.claude`, `~/.codex` nem `~/.config/opencode`.
@MainActor @Observable
final class AgentsController {
    private(set) var agents: [AgentDefinition] = []
    /// Agentes das pastas dos CLIs, fundidos por nome (só leitura): a Library e o "importar".
    private(set) var imported: [ImportedAgent] = []
    private(set) var selectedName: String?
    private(set) var attachments = AgentAttachmentManifest()
    private(set) var memoryEntries: [AgentMemoryEntry] = []
    private(set) var memoryHits: [AgentMemoryHit]?
    private(set) var memoryQuery = ""
    private(set) var secretNames: [String] = []
    private(set) var images: [String: NSImage] = [:]
    private(set) var lastError: String?
    /// Agente cujo `Delete` espera o segundo clique.
    var confirmingDelete: String?
    /// Sessões, computers e datasets que dá para fixar num agente (a UI do app preenche).
    @ObservationIgnored var attachables: @MainActor () -> [AgentAttachable] = { [] }
    private(set) var loaded = false
    /// Agentes com site cuja sessão venceu: pedem você (ponto azul na sidebar).
    var needsLogin: Set<String> { Set(agents.filter { $0.sites.contains { $0.isExpired(at: Date()) } }.map(\.name)) }

    @ObservationIgnored let store: AgentStore
    @ObservationIgnored let home: URL
    @ObservationIgnored private var memory: AgentMemoryStore?
    @ObservationIgnored var loadSecretNames: @Sendable () async -> [String] = { [] }
    @ObservationIgnored var showPage: @MainActor (CenterPage) -> Void = { _ in }
    @ObservationIgnored var currentPage: @MainActor () -> CenterPage = { .workspace }
    @ObservationIgnored var closePage: @MainActor () -> Void = {}
    /// Seletor de arquivo (`NSOpenPanel` na app; trocável nos testes).
    @ObservationIgnored var pickFile: @MainActor (_ extensions: [String]) async -> URL? = { _ in nil }
    @ObservationIgnored var startSession: @MainActor (_ agent: String) -> Void = { _ in }
    @ObservationIgnored var addToSession: @MainActor (_ agent: String, _ session: UUID?) async throws -> Void = { _, _ in }
    @ObservationIgnored var insertInComposer: @MainActor (_ text: String) -> Bool = { _ in false }
    /// Cookies do site no navegador de um computador (depois do Take over), o cofre e o computador de destino; ligados pelo app.
    @ObservationIgnored var captureCookies: @MainActor (_ computer: String, _ host: String) async throws -> [AgentSiteSessions.Cookie] = { _, _ in [] }
    @ObservationIgnored var storeCookies: @MainActor (_ agent: String, _ host: String, _ cookies: [AgentSiteSessions.Cookie]) async throws -> Date? = { _, _, _ in nil }
    @ObservationIgnored var loadCookies: @MainActor (_ agent: String, _ host: String) async -> [AgentSiteSessions.Cookie] = { _, _ in [] }
    @ObservationIgnored var restoreCookies: @MainActor (_ computer: String, _ cookies: [AgentSiteSessions.Cookie]) async throws -> Void = { _, _ in }
    /// Agentes do Racky ligados numa sessão (para carregar os sites deles no computador dela).
    @ObservationIgnored var agentsInSession: @MainActor (_ session: UUID) async -> [String] = { _ in [] }
    @ObservationIgnored var openCreate: @MainActor (_ kind: AgentCreateKind, _ mode: AgentCreateMode) -> Void = { _, _ in }

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, root: URL? = nil) {
        self.home = home
        store = AgentStore(root: root ?? AgentStore.defaultRoot(home: home))
    }

    // MARK: Carregar

    func reload() async {
        let store = store, home = home
        let (list, found) = await BlockingIOBridge.run { (store.list(), AgentImporter.discover(home: home)) }
        agents = list
        imported = found
        images = images.filter { key, _ in list.contains { $0.name == key } }
        for a in list where images[a.name] == nil { images[a.name] = loadImage(a.name) }
        loaded = true
        if let selectedName, !list.contains(where: { $0.name == selectedName }) { self.selectedName = nil }
        secretNames = await loadSecretNames()
    }

    private func loadImage(_ name: String) -> NSImage? { store.avatarURL(name).flatMap { NSImage(contentsOf: $0) } }

    func clearSelection() { selectedName = nil }

    func agent(_ name: String) -> AgentDefinition? { agents.first { $0.name == name } }
    var selected: AgentDefinition? { selectedName.flatMap(agent) }

    // MARK: Abrir

    func open(_ name: String) async throws {
        guard agent(name) != nil else { throw ActionError.failed(.agentsOpen, message: String(localized: "No such agent.", bundle: .module)) }
        selectedName = name
        await loadDetail(name)
        showPage(.agent(name))
    }

    func loadDetail(_ name: String) async {
        attachments = (try? store.attachments(name)) ?? AgentAttachmentManifest()
        memoryQuery = ""
        memoryHits = nil
        confirmingDelete = nil
        memory = (try? store.memoryURL(for: name)).flatMap { try? AgentMemoryStore(path: $0) }
        await refreshMemory()
        secretNames = await loadSecretNames()
    }

    // MARK: Editar

    private func mutate(_ name: String, _ change: (inout AgentDefinition) throws -> Void) throws {
        guard var a = agent(name) else { throw AgentStoreError.notFound(name) }
        try change(&a)
        try store.update(a)
        if let i = agents.firstIndex(where: { $0.name == name }) { agents[i] = a }
    }

    /// `set(<campo>=<valor>)`: description, tone, instructions, model, tools, skills e o preset do computador.
    func setField(_ name: String, field: String, value: String) throws {
        let list = { (s: String) in s.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        try mutate(name) { a in
            switch field {
            case "description": a.description = value
            case "tone": a.tone = value
            case "instructions": a.instructions = value
            case "model": a.model = value.isEmpty ? nil : value
            case "tools": a.tools = list(value)
            case "skills": a.skills = list(value)
            case "computer.enabled":
                a.computer = value == "on" ? (a.computer ?? AgentComputerPreset()) : nil
            case "computer.screen", "computer.memory", "computer.country", "computer.region", "computer.packages":
                var c = a.computer ?? AgentComputerPreset()
                switch field {
                case "computer.screen": c.screen = value == "on"
                case "computer.memory": c.memoryMB = max(512, Int(value) ?? c.memoryMB)
                case "computer.country": c.proxyCountry = value.isEmpty ? nil : value.uppercased()
                case "computer.region": c.proxyRegion = value.isEmpty ? nil : value
                default: c.packages = list(value)
                }
                a.computer = c
            default: throw ActionError.failed(.agentsSetField, message: "unknown field \(field)")
            }
        }
    }

    func delete(_ name: String) throws {
        try store.delete(name)
        agents.removeAll { $0.name == name }
        images[name] = nil
        if selectedName == name { selectedName = nil; closePage() }
    }

    // MARK: Avatar

    func regenerateAvatar(_ name: String) throws {
        let a = try store.regenerateAvatar(name)
        if let i = agents.firstIndex(where: { $0.name == name }) { agents[i] = a }
        images[name] = loadImage(name)
    }

    func setPhoto(_ name: String, from url: URL) throws {
        let data = try Data(contentsOf: url)
        let a = try store.setPhoto(name, data: data, fileExtension: url.pathExtension)
        if let i = agents.firstIndex(where: { $0.name == name }) { agents[i] = a }
        images[name] = loadImage(name)
    }

    // MARK: Anexos, variáveis, sites

    func addAttachment(_ name: String, kind: AgentAttachmentKind, title: String, reference: String) throws {
        var m = attachments
        m.add(AgentAttachment(kind: kind, title: title.isEmpty ? (reference as NSString).lastPathComponent : title, reference: reference))
        try store.setAttachments(name, m)
        attachments = m
    }

    func removeAttachment(_ name: String, id: UUID) throws {
        var m = attachments
        m.remove(id: id)
        try store.setAttachments(name, m)
        attachments = m
    }

    func setVariable(_ name: String, envName: String, secretName: String) throws {
        guard envName.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil, !envName.hasPrefix("RACKY_") else {
            throw ActionError.failed(.agentsSetVariable, message: String(localized: "Use a valid environment variable name.", bundle: .module))
        }
        guard secretNames.contains(secretName) else {
            throw ActionError.failed(.agentsSetVariable, message: String(localized: "No such secret in the vault.", bundle: .module))
        }
        try mutate(name) { a in
            a.variables.removeAll { $0.envName == envName }
            a.variables.append(AgentVariable(envName: envName, secretName: secretName))
        }
    }

    func removeVariable(_ name: String, envName: String) throws { try mutate(name) { $0.variables.removeAll { $0.envName == envName } } }

    func addSite(_ name: String, host: String) throws {
        let h = host.trimmingCharacters(in: .whitespaces).lowercased()
        guard !h.isEmpty, !h.contains("/"), !h.contains(" ") else {
            throw ActionError.failed(.agentsAddSite, message: String(localized: "Enter a host like github.com.", bundle: .module))
        }
        try mutate(name) { a in
            guard !a.sites.contains(where: { $0.host == h }) else { return }
            a.sites.append(AgentSite(host: h, secretName: AgentSiteSessions.secretName(agent: name, host: h)))
        }
    }

    /// Lê os cookies do site no navegador do computador e guarda no cofre: o login feito no Take over passa a valer para o agente.
    func saveSite(_ name: String, host: String, computer: String) async throws {
        guard agent(name)?.sites.contains(where: { $0.host == host }) == true else {
            throw ActionError.failed(.agentsSaveSite, message: String(localized: "Add the site first.", bundle: .module))
        }
        let cookies = try await captureCookies(computer, host)
        guard !cookies.isEmpty else {
            throw ActionError.failed(.agentsSaveSite, message: String(localized: "No cookies for this site yet. Log in on the computer first.", bundle: .module))
        }
        let expiry = try await storeCookies(name, host, cookies)
        try mutate(name) { a in
            guard let i = a.sites.firstIndex(where: { $0.host == host }) else { return }
            a.sites[i].savedAt = Date()
            a.sites[i].expiresAt = expiry
        }
    }

    /// Um computador novo de uma sessão: carrega nele os logins dos agentes do Racky ligados na sessão. Login vencido acende o
    /// ponto azul do agente (precisa de você).
    func seedSites(computer: String, session: UUID?) async {
        guard let session else { return }
        for name in await agentsInSession(session) {
            guard let a = agent(name) else { continue }
            for site in a.sites where site.savedAt != nil {
                let cookies = await loadCookies(name, site.host)
                if cookies.isEmpty {
                    try? mutate(name) { x in
                        if let i = x.sites.firstIndex(where: { $0.host == site.host }) { x.sites[i].expiresAt = Date(timeIntervalSince1970: 1) }
                    }
                } else {
                    try? await restoreCookies(computer, cookies)
                }
            }
        }
    }

    func removeSite(_ name: String, host: String) throws { try mutate(name) { $0.sites.removeAll { $0.host == host } } }

    // MARK: Memória

    func refreshMemory() async {
        guard let memory else { memoryEntries = []; return }
        memoryEntries = (try? await memory.all()) ?? []
        if !memoryQuery.isEmpty { await search(memoryQuery) }
    }

    func search(_ text: String) async {
        memoryQuery = text
        guard let memory, !text.trimmingCharacters(in: .whitespaces).isEmpty else { memoryHits = nil; return }
        memoryHits = (try? await memory.search(text, limit: 30)) ?? []
    }

    func addMemory(title: String, body: String) async throws {
        guard let memory else { return }
        try await memory.add(title: title, body: body)
        await refreshMemory()
    }

    func editMemory(id: Int64, title: String, body: String) async throws {
        try await memory?.update(id: id, title: title, body: body)
        await refreshMemory()
    }

    func deleteMemory(id: Int64) async throws {
        try await memory?.delete(id: id)
        await refreshMemory()
    }

    var visibleMemory: [AgentMemoryEntry] {
        guard let hits = memoryHits else { return memoryEntries }
        let ids = hits.map(\.id)
        return ids.compactMap { id in memoryEntries.first { $0.id == id } }
    }

    // MARK: Library

    /// O agente do Racky como item da Library: ligar na sessão usa `agent.md` (o lançamento gera o resto).
    func libraryEntry(_ a: AgentDefinition) -> LibraryEntry {
        let path = ((try? store.folder(for: a.name)) ?? store.root).appendingPathComponent("agent.md").path
        return LibraryEntry(
            id: "racky:\(a.name)", kind: .agent, name: a.name, summary: a.description.isEmpty ? nil : a.description, path: path, category: .racky,
            source: "racky", scope: "racky", clients: [.claude, .codex, .opencode], model: a.model, tools: a.tools, skills: a.skills)
    }

    /// Computadores abertos agora (de onde dá para salvar um login).
    var runningComputers: [AgentAttachable] { attachables().filter { $0.kind == .computer } }

    var libraryEntries: [LibraryEntry] { agents.map(libraryEntry) }

    /// Skills do Racky (`~/Racky/skills`) como itens da Library: ligar na sessão copia a pasta para o plugin do lançamento.
    func libraryEntries(skills store: SkillStore) -> [LibraryEntry] {
        store.list().compactMap { skill in
            guard let url = try? store.skillURL(skill.name) else { return nil }
            return LibraryEntry(
                id: "racky:skill:\(skill.name)", kind: .skill, name: skill.name, summary: skill.description.isEmpty ? nil : skill.description, path: url.path,
                category: .racky, source: "racky", scope: "racky", clients: [.claude, .codex, .opencode])
        }
    }

    // MARK: Drag

    static let dragPrefix = "racky-agent:"
    static func dragPayload(_ name: String) -> String { dragPrefix + name }
    static func agentName(fromDrag text: String) -> String? { text.hasPrefix(dragPrefix) ? String(text.dropFirst(dragPrefix.count)) : nil }
}

enum AgentCreateKind: String, Sendable { case agent, skill }
enum AgentCreateMode: String, Sendable, CaseIterable { case scratch, description, `import` }

struct AgentAttachable: Equatable {
    var kind: AgentAttachmentKind
    var title: String
    var reference: String
}

extension AgentsController {
    /// Itens do combobox "Add session, computer or dataset…": o `id` é `<tipo>|<título>|<referência>`, o que `agents.addAttachment` lê.
    func attachableEntries() -> [DSMenuEntry] {
        attachables().map { item in
            .item(DSMenuItem("\(item.kind.rawValue)|\(item.title)|\(item.reference)", item.title, detail: item.kind.rawValue))
        }
    }
}
