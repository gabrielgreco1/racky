import RackyProtocol
import Foundation

/// Grupos do feed do Inbox (03 §9.1): `Needs You · Working · Done · Earlier`.
public enum InboxGroup: String, Sendable, CaseIterable, Equatable {
    case needsYou, working, done, earlier

    public var title: String {
        switch self {
        case .needsYou: "Needs You"
        case .working: "Working"
        case .done: "Done"
        case .earlier: "Earlier"
        }
    }
}

public enum InboxFilter: String, Sendable, CaseIterable, Equatable {
    case all, needsYou, unread

    public var title: String {
        switch self {
        case .all: "All"
        case .needsYou: "Needs You"
        case .unread: "Unread"
        }
    }
}

public struct InboxRow: Identifiable, Sendable, Equatable {
    /// O ID do terminal: um agente aparece uma vez no feed, com o estado em que está.
    public var id: UUID
    public var sessionID: UUID
    public var group: InboxGroup
    public var title: String
    public var provider: TerminalProvider
    public var activity: AgentActivity
    /// Linha 2: última mensagem, pedido de permissão ("Wants to run: …"), "Waiting on 2 subagents", "Exited with code 1".
    public var message: String
    public var at: Date
    public var unread: Bool
}

public struct InboxFeed: Sendable, Equatable {
    public var groups: [(group: InboxGroup, rows: [InboxRow])]
    public var unreadCount: Int

    public var isEmpty: Bool { groups.allSatisfy { $0.rows.isEmpty } }
    public var rows: [InboxRow] { groups.flatMap(\.rows) }

    public static func == (a: InboxFeed, b: InboxFeed) -> Bool {
        a.unreadCount == b.unreadCount && a.groups.count == b.groups.count
            && zip(a.groups, b.groups).allSatisfy { $0.group == $1.group && $0.rows == $1.rows }
    }
}

extension AttentionCenter {
    /// Monta o feed a partir do estado vivo dos terminais (`contexts`: quem é cada um). Terminais sem contexto ficam de fora.
    public func inbox(contexts: [UUID: AttentionContext], filter: InboxFilter = .all, now: Date) -> InboxFeed {
        var buckets: [InboxGroup: [InboxRow]] = [:]
        for (id, status) in statuses {
            guard let context = contexts[id] else { continue }
            let activity = effectiveActivity(of: id, now: now) ?? status.activity
            let isUnread = unread.contains(id)
            let group: InboxGroup
            let message: String
            switch activity {
            case .needsInput:
                group = .needsYou
                message = status.reason ?? status.lastMessage ?? "Needs your input"
            case .working, .starting:
                group = .working
                message = status.subtitle ?? status.lastMessage ?? "Working…"
            case .waitingOnSubagents:
                group = .working
                message = status.liveChildren == 1 ? "Waiting on 1 subagent" : "Waiting on \(status.liveChildren) subagents"
            case .done:
                group = isUnread ? .done : .earlier
                message = status.lastMessage ?? "Finished"
            case .failed:
                group = isUnread ? .done : .earlier
                message = AttentionText.failureText(status.reason)
            case .idle:
                group = .earlier
                message = status.lastMessage ?? "Idle"
            case .interrupted:
                group = .earlier
                message = "Interrupted"
            case .blocked, .unknown:
                continue
            }
            buckets[group, default: []].append(InboxRow(
                id: id, sessionID: context.sessionID, group: group, title: "\(context.sessionTitle) · \(context.providerName)",
                provider: context.provider, activity: activity, message: message, at: status.changedAt, unread: isUnread))
        }
        var groups: [(group: InboxGroup, rows: [InboxRow])] = []
        for group in InboxGroup.allCases {
            var rows = buckets[group] ?? []
            switch filter {
            case .all: break
            case .needsYou: if group != .needsYou { rows = [] }
            case .unread: rows = rows.filter(\.unread)
            }
            // Quem espera há mais tempo vem primeiro; nos outros grupos, o mais recente.
            rows.sort { group == .needsYou ? ($0.at, $0.id.uuidString) < ($1.at, $1.id.uuidString) : ($0.at, $0.id.uuidString) > ($1.at, $1.id.uuidString) }
            if !rows.isEmpty { groups.append((group, rows)) }
        }
        return InboxFeed(groups: groups, unreadCount: unread.filter { contexts[$0] != nil }.count)
    }
}
