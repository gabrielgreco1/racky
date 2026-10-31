import RackyCore
import RackyPlatform
import RackyProtocol
import RackyStore
import AppKit
import Foundation

/// Liga a Fatia 2 à casca (T2-04): `ActivityService` -> `AttentionCoordinator` -> sidebar, tabs, panes, Inbox, Dock e
/// notificações do sistema. Tudo que toca o sistema entra por closure ou protocolo e é trocável nos testes.
extension AppEnvironment {
    /// `racky` embutido: o helper que os hooks por lançamento chamam. `RACKY_HELPER` sobrepõe (dev e testes).
    static func helperPath(_ environment: [String: String]) -> String? {
        HookHelperLocator.path(environment: environment, bundleURL: Bundle.main.bundleURL)
    }

    /// Sobe o `ActivityService` (drena o spool do que chegou com o app fechado) e passa a alimentar a atenção.
    func startActivity(store: RackyStore) async {
        guard let attention else { return }
        let service = ActivityService(store: store, spoolDirectory: HookSpool.directory(forSocketPath: socketPath))
        do { try await service.start() } catch { LogFacade(.app, category: "attention").error("activity service failed to start: \(error)") }
        activity = service
        // O `cwd` dos hooks (o Claude Code não emite OSC 7) alimenta o módulo Files (10-right-panel §2).
        await service.setCwdObserver { [files] terminal, path in
            await MainActor.run { files.noteCwd(path, terminal: terminal, source: .hook) }
        }
        // F12: os hooks dos filhos nativos ligam cada slot de worker ao `agent_run` dele (S-08).
        if let orchestrator = orchestratorHolder.value {
            let model = computers.model
            await service.setChildObserver { hook in
                await orchestrator.scheduler.handleChildHook(
                    parentRunID: hook.parentRunID, event: hook.event, agentID: hook.agentID, mcpServer: hook.mcpServer)
                if let name = await orchestrator.scheduler.computerName(forAgent: hook.agentID) {
                    await MainActor.run { model.agentComputers[hook.agentID] = name }
                }
            }
        }
        await attention.start(activity: service, store: store)
    }

    func wireAttention(environment: [String: String]) {
        guard let attention else { return }
        sidebar.attention = attention
        // Pedidos de ajuda de computador (T3-05): mesma fila, mesmo Inbox, mesmo badge do Dock.
        sidebar.helpInbox = computers.model
        workspace.finishedWorkers = { [weak model = computers.model] in model?.finishedWorkers ?? [] }
        attention.extraBadgeCount = { [computers] in computers.model.attentionCount }
        computers.model.onAttentionChange = { [attention] _ in attention.refreshDock() }
        workspace.attention = attention
        settings.attention = attention
        attention.contexts = { [sidebar] in sidebar.attentionContexts() }
        attention.preferences = { [settings] in settings.settings.notifications }
        attention.visibleTerminals = { [workspace] in workspace.visibleTerminalIDs }
        attention.windowIsKey = { NSApp?.isActive == true && NSApp?.keyWindow?.isKeyWindow == true }
        let badgeLog = fakeNotifier == nil ? nil : StorePaths.default(environment: environment).root.appendingPathComponent("run/dock-badge.txt")
        let override = dockBadgeOverride
        attention.setDockBadge = { label in
            if let override { override(label) } else { NSApp?.dockTile.badgeLabel = label }
            if let badgeLog { try? (label ?? "").write(to: badgeLog, atomically: true, encoding: .utf8) }
        }
        attention.navigate = { [weak self] terminalID, sessionID, source in
            self?.navigate(to: terminalID, in: sessionID, source: source)
        }
        workspace.onBell = { [attention] id in attention.bell(terminalID: id) }
        workspace.addListener { [attention] in attention.scheduleViewCheck() }
        // O "visto" depende de a janela estar key: reavalia quando o app ou a janela ganham ou perdem o foco.
        let names: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification, NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
        ]
        for name in names {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [attention] _ in
                MainActor.assumeIsolated { attention.scheduleViewCheck() }
            }
        }
        do { try registerAttentionActions(attention) } catch { LogFacade(.app, category: "attention").publicError("duplicate attention action registration") }
    }

    /// Clique em notificação, linha do Inbox, ⇧⌘A: seleciona a sessão, foca o pane e dá o rim flash (M-702, M-309).
    private func navigate(to terminalID: UUID, in sessionID: UUID, source: AttentionNavigation) {
        if source == .notification {
            NSApp?.activate(ignoringOtherApps: true)
            NSApp?.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            if settings.isOpen { settings.close() }
        }
        sidebar.select(sessionID, closingInbox: source != .inbox)
        workspace.show(terminalID: terminalID, flash: true)
        if source != .inbox { sidebar.revealCurrent() }
    }

    private func registerAttentionActions(_ attention: AttentionCoordinator) throws {
        let sidebar = sidebar, workspace = workspace
        func terminalID(_ arg: ActionArgument, _ id: ActionID) throws -> UUID {
            guard arg.kind == .select, let raw = arg.value, let value = UUID(uuidString: String(raw.split(separator: ":").first ?? "")) else {
                throw ActionError.failed(id, message: "expected select(<terminalId>)")
            }
            return value
        }
        // "Sessions" (o item que substituiu o Inbox): volta para as sessões, fecha a página do centro e o feed antigo.
        try registry.register(.pageSessions) { [computers] _ in
            sidebar.setInbox(open: false)
            computers.closePage()
            return "sessions"
        }
        try registry.register(.pageInbox) { _ in
            sidebar.setInbox(open: !sidebar.inboxOpen)
            return sidebar.inboxOpen ? "opened" : "closed"
        }
        try registry.register(.inboxFilter) { arg in
            if arg.kind == .select, let raw = arg.value {
                guard let filter = InboxFilter(rawValue: raw) else { throw ActionError.failed(.inboxFilter, message: "unknown filter \(raw)") }
                sidebar.inboxFilter = filter
                sidebar.inboxFilterMenuOpen = false
                return filter.rawValue
            }
            sidebar.inboxFilterMenuOpen.toggle()
            return sidebar.inboxFilterMenuOpen ? "opened" : "closed"
        }
        let computers = computers
        try registry.register(.inboxMarkRead) { arg in
            // O ID de um pedido de ajuda é o `request_id` (não um UUID de terminal): vai para o diretório de computadores.
            if arg.kind == .select, let raw = arg.value, computers.model.inbox.contains(where: { $0.id == raw }) {
                computers.model.markRead(raw)
                return nil
            }
            attention.markRead(terminal: try terminalID(arg, .inboxMarkRead))
            return nil
        }
        try registry.register(
            .inboxMarkAllRead,
            enablement: {
                attention.center.unread.isEmpty && attention.center.pending.isEmpty && computers.model.unreadCount == 0
                    ? .disabled(reason: "Nothing unread") : .enabled
            }
        ) { _ in
            attention.markAllRead()
            computers.model.markAllRead()
            return nil
        }
        // Clique no item do Inbox (`select(<terminalId>)`) ou, com o sufixo `:notification`, o clique numa notificação do sistema.
        try registry.register(.notificationOpen) { arg in
            let id = try terminalID(arg, .notificationOpen)
            guard let context = sidebar.attentionContexts()[id] else { throw ActionError.failed(.notificationOpen, message: "Terminal not found") }
            let source: AttentionNavigation = (arg.value ?? "").hasSuffix(":notification") ? .notification : .inbox
            attention.open(NotificationTarget(terminalID: id, sessionID: context.sessionID), source: source)
            return context.sessionID.uuidString
        }
        try registry.register(
            .sessionNextNeedingAttention,
            enablement: { attention.center.pending.isEmpty ? .disabled(reason: "Nothing needs attention") : .enabled }
        ) { _ in
            attention.goToNextNeedingAttention(from: workspace.focusedTerminalID)?.terminalID.uuidString
        }
        func sessionArgument(_ arg: ActionArgument, _ id: ActionID) throws -> UUID {
            if arg.kind == .select, let raw = arg.value, let value = UUID(uuidString: raw) { return value }
            guard let selected = sidebar.selectedSession else { throw ActionError.failed(id, message: "No session selected") }
            return selected
        }
        try registry.register(.sessionMarkRead) { arg in
            attention.markSessionRead(try sessionArgument(arg, .sessionMarkRead))
            return nil
        }
        try registry.register(.sessionMarkUnread) { arg in
            attention.markSessionUnread(try sessionArgument(arg, .sessionMarkUnread))
            return nil
        }
    }
}
