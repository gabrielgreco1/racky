import RackyCore
import RackyPlatform
import RackyProtocol
import RackyStore
import AppKit
import Foundation

/// Liga os agentes do Racky (backlog 25): seção da sidebar, página do agente, criar, memória e as ações `agents.*`.
extension AppEnvironment {
    func wireAgents() {
        agents.showPage = { [computers, sidebar] page in
            sidebar.setInbox(open: false)
            computers.show(page)
        }
        agents.currentPage = { [computers] in computers.page }
        agents.closePage = { [computers] in computers.closePage() }
        agents.pickFile = { extensions in await AgentFilePicker.pick(extensions: extensions) }
        agents.openCreate = { [weak self] kind, mode in self?.showAgentCreate(kind: kind, mode: mode) }
        agents.attachables = { [weak self] in self?.attachableItems() ?? [] }
        library.rackyAgents = { [agents] in agents.libraryEntries }
        agents.addToSession = { [weak self] name, session in try await self?.addAgent(name, toSession: session) }
        sidebar.agents = agents
        do {
            try agents.register(in: registry)
        } catch { LogFacade(.app, category: "agents").publicError("duplicate agents registration") }
    }

    /// Chamado quando o Store abre: carrega a lista e liga a leitura dos nomes do cofre.
    func attachAgents(store: RackyStore) async {
        let vault = SecretVault(store: store, keyring: VaultKeyring(backend: SystemKeychainBackend.system()))
        agents.loadSecretNames = { ((try? await vault.list()) ?? []).filter { $0.kind == SecretKind.envVar.rawValue }.map(\.name).sorted() }
        await agents.reload()
        composer?.agentChoices = { [agents] in agents.agents.map(\.name) }
        composer?.addAgent = { [weak self] name, session in try? await self?.addAgent(name, toSession: session) }
        agents.insertInComposer = { [weak self] name in self?.composer?.toggleAgent(name) ?? false }
    }
}

/// Seletor de arquivo do sistema (`NSOpenPanel`), fora dos overlays do app porque devolve um caminho e some.
@MainActor
enum AgentFilePicker {
    static func pick(extensions: [String]) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if !extensions.isEmpty { panel.allowedContentTypes = extensions.compactMap { .init(filenameExtension: $0) } }
        return await withCheckedContinuation { continuation in
            panel.begin { response in continuation.resume(returning: response == .OK ? panel.url : nil) }
        }
    }
}

extension AppEnvironment {
    /// Abre a tela de criar. Sem a conversa (o modo `scratch` do primeiro passo), cria um agente em branco e abre a página dele.
    func showAgentCreate(kind: AgentCreateKind, mode: AgentCreateMode) {
        agentCreate.kind = kind
        agentCreate.mode = mode
        Task { await agentCreate.begin() }
        sidebar.setInbox(open: false)
        computers.show(.agentCreate)
    }

    /// Sessões, computers e datasets que dá para fixar num agente.
    func attachableItems() -> [AgentAttachable] {
        var out: [AgentAttachable] = []
        for s in sidebar.snapshot.sessions where s.archivedAt == nil { out.append(AgentAttachable(kind: .session, title: s.title, reference: s.id.uuidString)) }
        for c in computers.model.rows { out.append(AgentAttachable(kind: .computer, title: c.snapshot.name, reference: c.snapshot.name)) }
        for d in datasets.summaries { out.append(AgentAttachable(kind: .dataset, title: d.dataset.name, reference: d.dataset.id)) }
        return out
    }
}

extension AppEnvironment {
    /// Liga o agente numa sessão (a em foco ou a dada): vale no próximo lançamento, como `Enable in This Session` da Library.
    func addAgent(_ name: String, toSession session: UUID?) async throws {
        guard let target = session ?? sidebar.selectedSession else {
            throw ActionError.failed(.agentsAddToSession, message: String(localized: "Select a session first.", bundle: .module))
        }
        guard let agent = agents.agent(name) else {
            if library.items.contains(where: { $0.name == name && $0.works(with: .claude) && $0.scope == "user" }) {
                throw ActionError.failed(.agentsAddToSession, message: String(localized: "This agent is global in Claude Code, it is already on.", bundle: .module))
            }
            throw ActionError.failed(.agentsAddToSession, message: String(localized: "No such agent.", bundle: .module))
        }
        _ = await activations.set(ActivationRef(agents.libraryEntry(agent)), on: true, session: target)
        await library.refreshSession()
    }
}
