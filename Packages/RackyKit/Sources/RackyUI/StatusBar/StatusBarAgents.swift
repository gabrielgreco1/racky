import RackyCore
import RackyDesignSystem
import RackyProtocol
import Foundation

/// Segmento `Agents` da status bar (03 §5): quantos agentes trabalham e quantos pedem você. Função pura do estado que a fila de
/// atenção já guarda; nada novo é medido ou estimado. Sem agente trabalhando e sem pedido aberto, o segmento não aparece.
struct StatusBarAgents: Equatable {
    var working: Int
    /// Atenção agregada: a mesma conta do badge do Inbox (itens 1–2 abertos + pedidos de ajuda de computador).
    var needYou: Int

    /// `needsInput` vence `working` (02 §2.6): o indicador agregado mostra o que exige ação primeiro.
    var glyph: DSIndicatorGlyph { needYou > 0 ? .needsInput : .working }

    /// `4 working · 2 need you`: só as partes não zero.
    var text: String { parts.joined(separator: " · ") }

    var parts: [String] {
        var out: [String] = []
        if working > 0 { out.append(String(localized: "\(working) working", bundle: .module)) }
        if needYou > 0 { out.append(String(localized: "\(needYou) need you", bundle: .module)) }
        return out
    }

    /// - Parameters:
    ///   - statuses: atividade atual por terminal (`AttentionCenter.statuses`).
    ///   - providers: provedor de cada terminal conhecido; só terminais de agente contam (shell e custom ficam de fora).
    ///   - needYou: contagem do badge do Inbox.
    static func summary(statuses: [UUID: AgentActivity], providers: [UUID: TerminalProvider], needYou: Int) -> StatusBarAgents? {
        let working = statuses.reduce(0) { count, entry in
            count + (entry.value == .working && providers[entry.key]?.isAgent == true ? 1 : 0)
        }
        let waiting = max(0, needYou)
        guard working > 0 || waiting > 0 else { return nil }
        return StatusBarAgents(working: working, needYou: waiting)
    }

    /// Mesma fonte do Inbox e do Dock: `center.badgeCount` mais os pedidos de ajuda de computador.
    static func summary(center: AttentionCenter, contexts: [UUID: AttentionContext], extraNeedYou: Int) -> StatusBarAgents? {
        summary(
            statuses: center.statuses.mapValues(\.activity), providers: contexts.mapValues(\.provider),
            needYou: center.badgeCount + extraNeedYou)
    }
}
