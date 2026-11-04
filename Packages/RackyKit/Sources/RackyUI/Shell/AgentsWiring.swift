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
        library.rackyAgents = { [agents, agentCreate] in agents.libraryEntries + agents.libraryEntries(skills: agentCreate!.skills) }
        agents.addToSession = { [weak self] name, session in try await self?.addAgent(name, toSession: session) }
        sidebar.agents = agents
        do {
            try agents.register(in: registry)
            try agentCreate.register(in: registry)
            agentCreate.closePage = { [computers] in computers.closePage() }
            agentCreate.skillCreated = { [weak self] _ in
                guard let self else { return }
                self.library.setSection(.skills)
                self.computers.show(.library)
            }
        } catch { LogFacade(.app, category: "agents").publicError("duplicate agents registration") }
    }

    /// Chamado quando o Store abre: carrega a lista e liga a leitura dos nomes do cofre.
    func attachAgents(store: RackyStore) async {
        let vault = SecretVault(store: store, keyring: VaultKeyring(backend: SystemKeychainBackend.system()))
        agents.loadSecretNames = { ((try? await vault.list()) ?? []).filter { $0.delivery == SecretDelivery.profileEnv.rawValue }.map(\.name).sorted() }
        agents.captureCookies = { [computers] name, host in
            guard let computer = await computers.hub.computer(named: name) else { throw ActionError.failed(.agentsSaveSite, message: String(localized: "That computer is not running.", bundle: .module)) }
            return try await AgentSiteSessions.capture(from: computer.backend, host: host)
        }
        agents.storeCookies = { agent, host, cookies in try await AgentSiteSessions.save(vault: vault, agent: agent, host: host, cookies: cookies) }
        agents.loadCookies = { agent, host in (try? await AgentSiteSessions.load(vault: vault, agent: agent, host: host)) ?? [] }
        agents.restoreCookies = { [computers] name, cookies in
            guard let computer = await computers.hub.computer(named: name) else { return }
            try await AgentSiteSessions.restore(cookies, into: computer.backend)
        }
        agents.agentsInSession = { [activations] session in
            await activations.refs(for: session).filter(RackyAgentLaunch.isRackyAgent).map(\.name)
        }
        computers.computerReady = { [agents] name, session in await agents.seedSites(computer: name, session: session) }
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
        Task { await agentCreate.begin(kind: kind, mode: mode) }
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
