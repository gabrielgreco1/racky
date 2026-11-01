import Foundation
import Synchronization

// Notificações do sistema (06 §3.5, 03 §9.2). O app fala com este protocolo; a implementação real (`UNUserNotificationCenter`)
// vive na UI e só pede autorização quando o usuário aperta "Allow" em Settings › Notifications. Testes e a evidência usam
// `RecordingNotificationCenter`, que nunca toca o sistema.

public enum NotificationAuthorization: String, Sendable, Equatable, Codable {
    case notDetermined, denied, authorized
}

/// Para onde o clique leva (`userInfo = {terminalID, sessionID}`).
public struct NotificationTarget: Sendable, Equatable, Codable {
    public var terminalID: UUID
    public var sessionID: UUID
    /// "Lote concluído" (07 CS-326): o clique abre o painel `Batch` desse lote em vez de levar ao pane.
    public var batchID: String?
    public init(terminalID: UUID, sessionID: UUID, batchID: String? = nil) { self.terminalID = terminalID; self.sessionID = sessionID; self.batchID = batchID }
}

public struct SystemNotification: Sendable, Equatable, Codable {
    public var id: String
    public var title: String
    public var body: String
    /// `threadIdentifier` = a sessão: agrupa no Centro de Notificações.
    public var threadID: String
    public var target: NotificationTarget
    public var kind: AttentionKind
    public var sound: Bool

    public init(id: String, title: String, body: String, threadID: String, target: NotificationTarget, kind: AttentionKind, sound: Bool) {
        self.id = id; self.title = title; self.body = body; self.threadID = threadID; self.target = target; self.kind = kind; self.sound = sound
    }
}

public protocol NotificationCentering: Sendable {
    /// Estado atual da permissão. Nunca abre o diálogo do sistema.
    func authorization() async -> NotificationAuthorization
    /// Pede a permissão (abre o diálogo do sistema). Só é chamado por um clique do usuário.
    func requestAuthorization() async -> NotificationAuthorization
    func post(_ notification: SystemNotification) async
    /// Tira da tela as notificações já entregues do terminal (o pane foi visto).
    func withdraw(terminalID: UUID) async
    /// Quem recebe o clique na notificação.
    func setOpenHandler(_ handler: @escaping @Sendable (NotificationTarget) -> Void)
}

/// Centro de notificações de mentira: grava o que seria entregue e deixa o teste "clicar". Também usado pelo modo
/// `RACKY_NOTIFICATIONS=fake` do app (evidência e testes de UI), com um arquivo JSONL opcional.
public final class RecordingNotificationCenter: NotificationCentering {
    private struct State {
        var authorization: NotificationAuthorization
        var posted: [SystemNotification] = []
        var withdrawn: [UUID] = []
        var requests = 0
        var handler: (@Sendable (NotificationTarget) -> Void)?
    }
    private let state: Mutex<State>
    private let logURL: URL?
    private let grantsOnRequest: Bool

    public init(authorization: NotificationAuthorization = .notDetermined, grantsOnRequest: Bool = true, logURL: URL? = nil) {
        state = Mutex(State(authorization: authorization))
        self.grantsOnRequest = grantsOnRequest
        self.logURL = logURL
    }

    public var posted: [SystemNotification] { state.withLock { $0.posted } }
    public var withdrawn: [UUID] { state.withLock { $0.withdrawn } }
    public var requestCount: Int { state.withLock { $0.requests } }

    public func authorization() async -> NotificationAuthorization { state.withLock { $0.authorization } }

    public func requestAuthorization() async -> NotificationAuthorization {
        state.withLock {
            $0.requests += 1
            if $0.authorization == .notDetermined { $0.authorization = grantsOnRequest ? .authorized : .denied }
            return $0.authorization
        }
    }

    public func post(_ notification: SystemNotification) async {
        let delivered = state.withLock { s -> Bool in
            guard s.authorization == .authorized else { return false }
            s.posted.append(notification)
            return true
        }
        guard delivered, let logURL, let data = try? JSONEncoder().encode(notification) else { return }
        var line = data
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: logURL)
        }
    }

    public func withdraw(terminalID: UUID) async { state.withLock { $0.withdrawn.append(terminalID) } }

    public func setOpenHandler(_ handler: @escaping @Sendable (NotificationTarget) -> Void) { state.withLock { $0.handler = handler } }

    /// O usuário clicou na notificação.
    public func simulateClick(_ target: NotificationTarget) {
        let handler = state.withLock { $0.handler }
        handler?(target)
    }
}

/// Decide se um item vira notificação do sistema (06 §3.5, 03 §9.2). Função pura.
public enum NotificationPlanner {
    public struct Environment: Sendable {
        public var authorization: NotificationAuthorization
        public var windowIsKey: Bool
        /// O pane do evento está visível (tab ativa da sessão selecionada).
        public var paneVisible: Bool
        public var now: Date
        /// Última notificação entregue para o mesmo terminal e a prioridade dela (cooldown de 5 s).
        public var last: (at: Date, priority: Int)?

        public init(
            authorization: NotificationAuthorization, windowIsKey: Bool, paneVisible: Bool, now: Date, last: (at: Date, priority: Int)? = nil
        ) {
            self.authorization = authorization; self.windowIsKey = windowIsKey; self.paneVisible = paneVisible; self.now = now; self.last = last
        }
    }

    public static let cooldown: TimeInterval = 5

    public enum Decision: Sendable, Equatable {
        case post(SystemNotification)
        case skip(Reason)
    }

    public enum Reason: String, Sendable, Equatable {
        case notAuthorized, kindDisabled, visible, cooldown, alreadyNotified
    }

    public static func plan(_ item: AttentionItem, preferences: AppSettings.Notifications, environment env: Environment) -> Decision {
        guard env.authorization == .authorized else { return .skip(.notAuthorized) }
        if item.systemNotified { return .skip(.alreadyNotified) }
        let sound: Bool
        switch item.kind {
        case .needsInput, .helpRequest:
            guard preferences.needsInput else { return .skip(.kindDisabled) }
            sound = preferences.sound == .system
        case .done, .batchDone:
            guard preferences.finished else { return .skip(.kindDisabled) }
            sound = false
        case .failed, .childBlocked, .dockerStopped:
            guard preferences.failed else { return .skip(.kindDisabled) }
            sound = preferences.sound == .system
        }
        if preferences.suppressWhenVisible, env.windowIsKey, env.paneVisible { return .skip(.visible) }
        if let last = env.last, env.now.timeIntervalSince(last.at) < cooldown, item.priority >= last.priority { return .skip(.cooldown) }
        return .post(SystemNotification(
            id: item.id, title: item.title, body: item.body, threadID: item.sessionID.uuidString.lowercased(),
            target: NotificationTarget(terminalID: item.terminalID, sessionID: item.sessionID), kind: item.kind, sound: sound))
    }

    /// Notificação de BEL (`Terminal bell`, desligada por padrão).
    public static func planBell(
        terminalID: UUID, context: AttentionContext, preferences: AppSettings.Notifications, environment env: Environment
    ) -> Decision {
        guard env.authorization == .authorized else { return .skip(.notAuthorized) }
        guard preferences.terminalBell else { return .skip(.kindDisabled) }
        if preferences.suppressWhenVisible, env.windowIsKey, env.paneVisible { return .skip(.visible) }
        if let last = env.last, env.now.timeIntervalSince(last.at) < cooldown { return .skip(.cooldown) }
        return .post(SystemNotification(
            id: "\(terminalID.uuidString.lowercased()).bell.\(Int(env.now.timeIntervalSince1970 * 1000))",
            title: "\(context.place) — \(context.providerName) rang the bell", body: "Terminal bell", threadID: context.sessionID.uuidString.lowercased(),
            target: NotificationTarget(terminalID: terminalID, sessionID: context.sessionID), kind: .done, sound: preferences.sound == .system))
    }
}
