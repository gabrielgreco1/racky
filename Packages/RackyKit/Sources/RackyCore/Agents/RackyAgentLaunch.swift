import RackyPlatform
import Foundation

/// Agente do Racky já gerado para os três CLIs (o Claude vai em `SessionLibraryInjection.agents`).
public struct RackyGeneratedAgent: Sendable, Equatable {
    public var name: String
    public var description: String
    /// Conteúdo de `<launch>/agents-codex/agents/<nome>.toml`.
    public var codexTOML: Data
    /// Conteúdo de `<launch>/agents-opencode/agent/<nome>.md`.
    public var openCodeMarkdown: Data
}

/// Lançamento com agentes do Racky (backlog 25 f): lê o agente, os anexos fixos e o índice da memória na hora de lançar e gera a versão
/// de cada CLI no diretório do lançamento. Nada é escrito em `~/.claude`, `~/.codex` nem `~/.config/opencode`.
public enum RackyAgentLaunch {
    public static func isRackyAgent(_ ref: ActivationRef) -> Bool { ref.kind == "agent" && ref.id.hasPrefix("racky:") }

    /// O plugin e os agentes da Library mais, para cada agente do Racky ligado na sessão, a definição completa (instruções, tom,
    /// anexos, variáveis por nome, índice da memória e os comandos de memória) para os três CLIs.
    public static func build(refs: [ActivationRef], agentStore: AgentStore, helperPath: String?) async -> SessionLibraryInjection? {
        let others = refs.filter { !isRackyAgent($0) }
        var injection = await BlockingIOBridge.run { SessionLibraryBuilder.build(others) }
        let mine = refs.filter(isRackyAgent)
        guard !mine.isEmpty else { return injection }
        var result = injection ?? SessionLibraryInjection(pluginFiles: [], agents: [:], skillNames: [], skipped: [])
        for ref in mine.sorted(by: { $0.name < $1.name }) {
            guard let agent = try? agentStore.load(ref.name) else { result.skipped.append(ref.name); continue }
            let attachments = (try? agentStore.attachments(agent.name)) ?? AgentAttachmentManifest()
            var index = ""
            if helperPath != nil, let url = try? agentStore.memoryURL(for: agent.name), let memory = try? AgentMemoryStore(path: url) {
                index = (try? await memory.index()) ?? ""
            }
            func gen(_ c: LibraryClient) -> AgentLaunchArtifacts {
                AgentCLIGenerator.generate(agent, for: c, attachments: attachments, memoryIndex: index, memoryHelper: helperPath)
            }
            if let def = gen(.claude).claudeAgents[agent.name] { result.agents[agent.name] = def }
            result.rackyAgents.append(RackyGeneratedAgent(
                name: agent.name, description: agent.description, codexTOML: gen(.codex).files.first?.contents ?? Data(),
                openCodeMarkdown: gen(.opencode).files.first?.contents ?? Data()))
        }
        injection = result
        return injection
    }
}
