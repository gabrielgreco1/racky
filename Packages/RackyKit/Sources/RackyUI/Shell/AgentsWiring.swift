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
