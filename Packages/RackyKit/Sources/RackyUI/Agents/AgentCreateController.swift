import RackyCore
import Foundation
import Observation

/// Criar agente ou skill (backlog 25 d, e, f, h). Preenchido nas tarefas seguintes; por enquanto só guarda o modo.
@MainActor @Observable
final class AgentCreateController {
    let agents: AgentsController
    var kind: AgentCreateKind = .agent
    var mode: AgentCreateMode = .scratch
    init(agents: AgentsController) { self.agents = agents }
    func begin() async {}
}
