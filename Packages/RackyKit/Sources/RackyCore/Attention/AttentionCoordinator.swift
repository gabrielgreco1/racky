import RackyPlatform
import RackyProtocol
import RackyStore
import Foundation
import Observation

/// Liga o estado de atividade (`ActivityService`) à atenção: mantém a `AttentionCenter`, decide e entrega as notificações do
/// sistema, atualiza o badge do Dock e persiste o não lido da sessão. A UI só observa `center` e fornece o que ela sabe
/// (quem é o terminal, o que está visível, para onde navegar). Tudo que toca o sistema entra por protocolo ou closure.
/// De onde veio a navegação: o Inbox mantém o feed aberto; notificação e atalho voltam à lista de sessões.
public enum AttentionNavigation: Sendable, Equatable { case notification, inbox, shortcut }

@MainActor
@Observable
public final class AttentionCoordinator {
    public private(set) var center = AttentionCenter()

    // Fornecidos pela UI.
    @ObservationIgnored public var contexts: () -> [UUID: AttentionContext] = { [:] }
    @ObservationIgnored public var preferences: () -> AppSettings.Notifications = { AppSettings.Notifications() }
    /// Terminais com o pane na tela (tab ativa da sessão selecionada).
    @ObservationIgnored public var visibleTerminals: () -> Set<UUID> = { [] }
    @ObservationIgnored public var windowIsKey: () -> Bool = { false }
    /// Seleciona sessão e tab, foca o pane e dispara o rim flash (M-309, M-702).
    @ObservationIgnored public var navigate: (_ terminalID: UUID, _ sessionID: UUID, _ source: AttentionNavigation) -> Void = { _, _, _ in }
    /// `NSApp.dockTile.badgeLabel` (injetável: os testes gravam o texto).
    @ObservationIgnored public var setDockBadge: (String?) -> Void = { _ in }
    /// Pedidos de ajuda de computador abertos (T3-05): entram na mesma contagem do badge do Dock.
    @ObservationIgnored public var extraBadgeCount: () -> Int = { 0 }
    /// Abre o painel `Batch` (clique na notificação ou no item do Inbox de "lote concluído").
    @ObservationIgnored public var openBatch: (String) -> Void = { _ in }
    @ObservationIgnored public var clock: () -> Date = { Date() }
    /// Quanto o pane precisa ficar visível com a janela key para contar como visto (06 §3.6).
    @ObservationIgnored public var viewDwell: Duration = .seconds(1)

    @ObservationIgnored private let notifier: any NotificationCentering
    @ObservationIgnored private var store: RackyStore?
    @ObservationIgnored private var consumer: Task<Void, Never>?
    @ObservationIgnored private var dwellTask: Task<Void, Never>?
    @ObservationIgnored private var dwellSet: Set<UUID> = []
    @ObservationIgnored private var lastPosted: [UUID: (at: Date, priority: Int)] = [:]
    @ObservationIgnored private var lastBadge: String??
    @ObservationIgnored private let log = LogFacade(.app, category: "attention")

    public init(notifier: any NotificationCentering) {
        self.notifier = notifier
        notifier.setOpenHandler { [weak self] target in
            Task { @MainActor in self?.open(target) }
        }
    }

    public var notificationCenter: any NotificationCentering { notifier }

    // MARK: - Ligação

    /// Semeia o estado com o que o banco guarda (o que aconteceu com o app fechado) e passa a consumir as atualizações.
    public func start(activity: ActivityService, store: RackyStore) async {
        self.store = store
        await seed(from: store)
        consumer?.cancel()
        let updates = activity.updates
        consumer = Task { [weak self] in
            for await update in updates {
                guard !Task.isCancelled else { return }
                self?.handle(update)
            }
        }
    }

    public func stop() {
        consumer?.cancel(); consumer = nil
        dwellTask?.cancel(); dwellTask = nil
    }

    /// Estado persistido: `needsInput` pendente volta para a fila; `done`/`failed` só se a sessão estava não lida.
    public func seed(from store: RackyStore) async {
        guard let runs = try? await store.latestMainRuns() else { return }
        let snapshot = (try? await store.snapshot()) ?? StoreSnapshot()
        let unreadSessions = Set(snapshot.sessions.filter(\.unread).map(\.id))
        let map = AttentionContext.contexts(in: snapshot)
        let now = clock()
        for run in runs {
            guard let terminalID = run.terminalID else { continue }
            let context = map[terminalID]
            let status = TerminalActivity(
                terminalID: terminalID, runID: run.id, activity: run.activity, lastMessage: nil, reason: run.statusReason,
                subtitle: run.subtitle, liveChildren: 0, estimated: run.estimated, changedAt: run.lastEventAt ?? run.startedAt)
            var enriched = status
            if let terminal = try? await store.terminal(id: terminalID) { enriched.lastMessage = terminal.lastMessage }
            center.apply(
                enriched, context: context, now: now, seeding: true, unreadHint: context.map { unreadSessions.contains($0.sessionID) } ?? false)
        }
        refreshDock()
        scheduleViewCheck()
    }

    // MARK: - Eventos

    public func handle(_ update: ActivityService.Update) {
        guard let terminalID = update.terminalID else { return }
        if let context = contexts()[terminalID] {
            apply(update, terminalID: terminalID, context: context)
        } else if let store {
            // Terminal novo que a UI ainda não viu no snapshot: pergunta ao banco (uma leitura).
            Task { @MainActor in
                let snapshot = try? await store.snapshot()
                apply(update, terminalID: terminalID, context: snapshot.flatMap { AttentionContext.contexts(in: $0)[terminalID] })
            }
        } else {
            apply(update, terminalID: terminalID, context: nil)
        }
    }

    private func apply(_ update: ActivityService.Update, terminalID: UUID, context: AttentionContext?) {
        let now = clock()
        let status = TerminalActivity(
            terminalID: terminalID, runID: update.runID, activity: update.activity, lastMessage: update.lastMessage,
            reason: update.statusReason, subtitle: update.subtitle, liveChildren: update.liveChildren, changedAt: now, children: update.children)
        let item = center.apply(status, context: context, now: now)
        if let item {
            persistUnread(sessionID: item.sessionID, kind: item.kind)
            notify(item)
        }
        refreshDock()
        scheduleViewCheck()
    }

    /// "Lote concluído" (07 CS-326, AC-429): **um** item na fila e **uma** notificação, sem uma por filho. O terminal é o do pai.
    public func batchFinished(batchID: String, title: String, body: String, sessionID: UUID, terminalID: UUID, runID: UUID? = nil) {
        guard let item = center.openBatchDone(
            batchID: batchID, sessionID: sessionID, terminalID: terminalID, runID: runID, title: title, body: body, now: clock()) else { return }
        notify(item)
        refreshDock()
    }

    /// BEL (06 §3.6): o pane fica não lido até ser visto. Com o pane visível e a janela key nada muda.
    public func bell(terminalID: UUID) {
        let context = contexts()[terminalID]
        if windowIsKey(), visibleTerminals().contains(terminalID) { return }
        _ = center.bell(terminal: terminalID)
        if let context { persistUnread(sessionID: context.sessionID, kind: .done) }
        if let context {
            let prefs = preferences()
            let now = clock()
            Task { @MainActor in
                let auth = await notifier.authorization()
                let decision = NotificationPlanner.planBell(
                    terminalID: terminalID, context: context, preferences: prefs,
                    environment: .init(
                        authorization: auth, windowIsKey: windowIsKey(), paneVisible: visibleTerminals().contains(terminalID), now: now,
                        last: lastPosted[terminalID]))
                if case .post(let n) = decision {
                    lastPosted[terminalID] = (now, 3)
                    await notifier.post(n)
                }
            }
        }
        scheduleViewCheck()
    }

    private func notify(_ item: AttentionItem) {
        let prefs = preferences()
        let now = clock()
        Task { @MainActor in
            let auth = await notifier.authorization()
            let decision = NotificationPlanner.plan(
                item, preferences: prefs,
                environment: .init(
                    authorization: auth, windowIsKey: windowIsKey(), paneVisible: visibleTerminals().contains(item.terminalID), now: now,
                    last: item.kind == .batchDone ? nil : lastPosted[item.terminalID]))
            guard case .post(var notification) = decision else { return }
            if let batch = item.batchID { notification.target.batchID = batch }
            if item.kind != .batchDone { lastPosted[item.terminalID] = (now, item.priority) }
            center.markNotified(itemID: item.id)
            await notifier.post(notification)
        }
    }

    /// "Send Test Notification" (Settings › Notifications). Devolve o estado da permissão.
    @discardableResult
    public func sendTest() async -> NotificationAuthorization {
        let auth = await notifier.authorization()
        guard auth == .authorized else { return auth }
        let preferences = preferences()
        await notifier.post(SystemNotification(
            id: "test.\(UUID().uuidString.lowercased())", title: "Racky — test notification",
            body: "This is how Racky will tell you an agent needs you.", threadID: "test",
            target: NotificationTarget(terminalID: UUID(), sessionID: UUID()), kind: .done, sound: preferences.sound == .system))
        return auth
    }

    // MARK: - Leitura

    /// Chamada pela UI sempre que muda o que está visível ou o foco da janela (e após cada evento). Depois de `viewDwell`
    /// com o mesmo conjunto visível e a janela key, marca esses terminais como vistos.
    public func scheduleViewCheck() {
        guard windowIsKey() else {
            dwellTask?.cancel(); dwellTask = nil; dwellSet = []
            return
        }
        let visible = visibleTerminals()
        let pending = visible.filter { center.unread.contains($0) || center.hasUnresolvedItem(terminal: $0) || center.statuses[$0]?.activity == .done }
        guard !pending.isEmpty else {
            dwellTask?.cancel(); dwellTask = nil; dwellSet = []
            return
        }
        // O mesmo conjunto visível já está contando: não reinicia o segundo (eventos frequentes não podem adiar o "visto").
        if dwellTask != nil, dwellSet == visible { return }
        dwellTask?.cancel()
        dwellSet = visible
        dwellTask = Task { [weak self, dwell = viewDwell] in
            try? await Task.sleep(for: dwell)
            guard !Task.isCancelled, let self, self.windowIsKey() else { return }
            self.dwellTask = nil
            self.markViewed(self.visibleTerminals().intersection(visible))
        }
    }

    public func markViewed(_ terminals: Set<UUID>) {
        guard !terminals.isEmpty else { return }
        let now = clock()
        let before = center.unread
        guard center.markViewed(terminals: terminals, now: now) else { return }
        refreshDock()
        let map = contexts()
        for id in terminals {
            Task { await notifier.withdraw(terminalID: id) }
        }
        settleSessionUnread(touched: terminals.intersection(before).compactMap { map[$0]?.sessionID })
    }

    public func markAllRead() {
        let touched = center.unread
        center.markAllRead(now: clock())
        refreshDock()
        let map = contexts()
        settleSessionUnread(touched: touched.compactMap { map[$0]?.sessionID })
    }

    /// "Mark as Read" de uma sessão: todos os terminais dela.
    public func markSessionRead(_ sessionID: UUID) {
        let ids = Set(contexts().filter { $0.value.sessionID == sessionID }.keys)
        _ = center.markViewed(terminals: ids, now: clock())
        refreshDock()
        persistRead(sessionID)
    }

    public func markSessionUnread(_ sessionID: UUID) {
        for (id, context) in contexts() where context.sessionID == sessionID { center.markUnread(terminal: id) }
        if let store { Task { try? await store.setSessionUnread(id: sessionID, unread: true) } }
    }

    public func markRead(terminal id: UUID) { markViewed([id]) }

    public func terminalClosed(_ id: UUID) {
        center.remove(terminal: id)
        refreshDock()
    }

    // MARK: - Navegação

    /// Clique numa notificação ou numa linha do Inbox: leva ao pane e marca como lido.
    public func open(_ target: NotificationTarget, source: AttentionNavigation = .notification) {
        if let batch = target.batchID {
            center.resolveBatch(batch, now: clock())
            refreshDock()
            openBatch(batch)
            return
        }
        navigate(target.terminalID, target.sessionID, source)
        markViewed([target.terminalID])
    }

    /// ⇧⌘A. Devolve o terminal levado, ou `nil` se nada precisa de atenção.
    @discardableResult
    public func goToNextNeedingAttention(from current: UUID?) -> AttentionItem? {
        guard let item = center.next(after: current) else { return nil }
        navigate(item.terminalID, item.sessionID, .shortcut)
        markViewed([item.terminalID])
        return item
    }

    // MARK: - Efeitos

    /// Badge do Dock = itens de prioridade 1–2 abertos (06 §3.5), vazio quando 0 ou desligado nas preferências.
    public func refreshDock() {
        let count = center.badgeCount + extraBadgeCount()
        let label: String? = preferences().dockBadge && count > 0 ? String(count) : nil
        if let lastBadge, lastBadge == label { return }
        lastBadge = .some(label)
        setDockBadge(label)
    }

    private func persistUnread(sessionID: UUID, kind: AttentionKind) {
        guard kind == .done || kind == .failed, let store else { return }
        Task { try? await store.setSessionUnread(id: sessionID, unread: true) }
    }

    private func persistRead(_ sessionID: UUID) {
        guard let store else { return }
        Task { try? await store.markSessionViewed(id: sessionID) }
    }

    /// Quando nenhum terminal da sessão continua não lido, o não lido persistido da sessão também sai.
    private func settleSessionUnread(touched: [UUID]) {
        let map = contexts()
        for sessionID in Set(touched) {
            let stillUnread = center.unread.contains { map[$0]?.sessionID == sessionID }
            if !stillUnread { persistRead(sessionID) }
        }
    }
}
