import RackyProtocol
import Foundation

/// Estimativa do que uma retomada recarrega (R2.5, "custo à vista"). O número é o tamanho do contexto da conversa: o último
/// `usage` do transcript quando existe, senão bytes/4. É uma ordem de grandeza, nunca uma cobrança.
public enum ResumeCost {
    public static let bytesPerToken = 4

    public static func tokens(contextTokens: Int?, transcriptBytes: Int) -> Int {
        if let contextTokens, contextTokens > 0 { return contextTokens }
        return max(0, transcriptBytes / bytesPerToken)
    }

    /// `~850 tokens`, `~84k tokens`, `~1.2M tokens`.
    public static func format(tokens: Int) -> String {
        switch tokens {
        case ..<1_000: "~\(max(tokens, 0)) tokens"
        case ..<1_000_000: "~\(tokens / 1_000)k tokens"
        default: "~" + String(format: "%.1f", Double(tokens) / 1_000_000) + "M tokens"
        }
    }
}

/// Um agente parado que "Resume Agents…" pode relançar.
public struct ResumeCandidate: Identifiable, Sendable, Equatable {
    public var id: UUID
    public var sessionID: UUID?
    public var sessionTitle: String
    public var provider: TerminalProvider
    public var model: String?
    public var lastMessage: String?
    public var nativeID: String
    /// Contexto estimado a recarregar; `nil` = transcript não encontrado.
    public var estimatedTokens: Int?
    /// A conversa já roda em outro processo (F32): não entra na seleção.
    public var isLive: Bool
    /// Saiu sozinho (`exited`) em vez de ter sido interrompido: listado, mas desmarcado de início.
    public var exited: Bool

    public init(
        id: UUID, sessionID: UUID? = nil, sessionTitle: String = "", provider: TerminalProvider, model: String? = nil,
        lastMessage: String? = nil, nativeID: String, estimatedTokens: Int? = nil, isLive: Bool = false, exited: Bool = false
    ) {
        self.id = id; self.sessionID = sessionID; self.sessionTitle = sessionTitle; self.provider = provider; self.model = model
        self.lastMessage = lastMessage; self.nativeID = nativeID; self.estimatedTokens = estimatedTokens; self.isLive = isLive
        self.exited = exited
    }
}

/// Seleção do overlay "Resume interrupted agents?" (03 §16.7): todos marcados (AC-207), menos os que já rodam em outro
/// processo e os que saíram sozinhos.
public struct ResumeSelection: Equatable, Sendable {
    public private(set) var candidates: [ResumeCandidate]
    public private(set) var selected: Set<UUID>

    public init(candidates: [ResumeCandidate]) {
        self.candidates = candidates
        selected = Set(candidates.filter { !$0.isLive && !$0.exited }.map(\.id))
    }

    public func isSelected(_ id: UUID) -> Bool { selected.contains(id) }
    public var count: Int { selected.count }
    /// Marcados, na ordem da lista.
    public var chosen: [ResumeCandidate] { candidates.filter { selected.contains($0.id) } }
    public var selectableCount: Int { candidates.filter { !$0.isLive }.count }

    /// Soma do contexto dos marcados (só os que têm estimativa) e quantos ficaram sem.
    public var totalTokens: Int { chosen.compactMap(\.estimatedTokens).reduce(0, +) }
    public var unknownCostCount: Int { chosen.filter { $0.estimatedTokens == nil }.count }

    @discardableResult
    public mutating func toggle(_ id: UUID) -> Bool {
        guard let c = candidates.first(where: { $0.id == id }), !c.isLive else { return false }
        if !selected.insert(id).inserted { selected.remove(id) }
        return true
    }

    public mutating func set(_ id: UUID, on: Bool) {
        guard let c = candidates.first(where: { $0.id == id }), !c.isLive else { return }
        if on { selected.insert(id) } else { selected.remove(id) }
    }

    public mutating func selectAll() { selected = Set(candidates.filter { !$0.isLive }.map(\.id)) }
    public mutating func selectNone() { selected = [] }

    /// Atualiza o que muda depois de aberto (custo lido do transcript, conversa que ficou viva), mantendo a marcação.
    public mutating func update(_ id: UUID, tokens: Int?? = nil, live: Bool? = nil) {
        guard let i = candidates.firstIndex(where: { $0.id == id }) else { return }
        if let tokens { candidates[i].estimatedTokens = tokens }
        if let live {
            candidates[i].isLive = live
            if live { selected.remove(id) }
        }
    }
}
