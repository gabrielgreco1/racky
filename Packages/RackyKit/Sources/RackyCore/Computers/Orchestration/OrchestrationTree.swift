import RackyProtocol
import RackyStore
import Foundation

/// Árvore pai -> filhos (07 §4.3, CS-320..322): derivação pura do estado do pai e do rótulo do card a partir dos filhos.
public enum OrchestrationTree {
    /// Um filho como a UI o vê: estado do slot na árvore e a atividade do `agent_run` do filho nativo (quando já correlacionado).
    public struct ChildSummary: Sendable, Equatable {
        public var childID: String
        public var computerName: String?
        public var state: OrchestrationChildState
        public var activity: AgentActivity?
        public var boxState: BoxState?

        public init(childID: String, computerName: String? = nil, state: OrchestrationChildState, activity: AgentActivity? = nil, boxState: BoxState? = nil) {
            self.childID = childID; self.computerName = computerName; self.state = state; self.activity = activity; self.boxState = boxState
        }

        /// Filho que ainda segura o pai: computador reservado ou em uso e sem `SubagentStop`.
        public var isActive: Bool { state.isActive && activity != .done && activity != .failed && activity != .interrupted }

        public var needsYou: Bool { if case .needsInput = activity { true } else { false } }
    }

    /// Estado do pai (CS-322): `waitingOnSubagents` quando o turno dele terminou (`done`/`idle`) e há filho ativo. Nunca esconde
    /// `needsInput` de um filho: a atenção do filho sobe para o card da sessão (T10, 01 §6.3), então o pior estado vence.
    public static func parentActivity(parent: AgentActivity, children: [ChildSummary]) -> AgentActivity {
        var effective = parent
        let active = children.contains { $0.isActive }
        switch parent {
        case .done, .idle: if active { effective = .waitingOnSubagents }
        case .waitingOnSubagents: if !active { effective = .done }
        default: break
        }
        var samples = [AgentActivityMachine.Sample(effective)]
        for child in children where child.needsYou { if let activity = child.activity { samples.append(.init(activity)) } }
        return AgentActivityMachine.aggregate(samples) ?? effective
    }

    /// `"2 of 15 running · 1 needs you"` (CS-322). `nil` sem filhos.
    public static func label(children: [ChildSummary]) -> String? {
        let live = children.filter { $0.state != .idle }
        guard !live.isEmpty else { return nil }
        let running = live.filter(\.isActive).count
        var text = "\(running) of \(live.count) running"
        let needing = live.filter(\.needsYou).count
        if needing > 0 { text += " · \(needing) need\(needing == 1 ? "s" : "") you" }
        return text
    }
}

extension RackyStore {
    /// Filhos do pai com a atividade do `agent_run` correlacionado e o estado do computador, para a árvore da sidebar.
    public func orchestrationSummaries(parentID: String, boxStates: [String: BoxState] = [:]) async throws -> [OrchestrationTree.ChildSummary] {
        var out: [OrchestrationTree.ChildSummary] = []
        for child in try await orchestrationChildren(parentID: parentID) {
            var activity: AgentActivity?
            if let runID = child.runID, let run = try await agentRun(id: runID) { activity = run.activity }
            out.append(OrchestrationTree.ChildSummary(
                childID: child.id, computerName: child.computerName, state: child.state, activity: activity,
                boxState: child.computerName.flatMap { boxStates[$0] }))
        }
        return out
    }
}
