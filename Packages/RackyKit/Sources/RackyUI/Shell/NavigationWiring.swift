import RackyProtocol
import Foundation

/// Histórico de navegação e o retorno à sessão: clicar numa sessão ou terminal sempre mostra aquele terminal, e ←/→ andam
/// entre sessão, terminal, viewer de computador, Inbox e Computers.
extension AppEnvironment {
    func wireNavigation() {
        sidebar.onSelected = { [computers] _ in computers.closePage() }
        sidebar.onShowAgent = { [workspace] _ in
            guard let agent = workspace.terminalsInCurrentSession.first(where: { $0.provider.isAgent }) else { return }
            workspace.show(terminalID: agent.id)
        }
        workspace.onShowTerminal = { [computers, sidebar] in
            computers.closePage()
            sidebar.setInbox(open: false)
        }
        let note: () -> Void = { [weak self] in self?.noteNavigation() }
        sidebar.onNavigate = note
        computers.onNavigate = note
        workspace.addListener(note)
    }

    /// Onde o usuário está agora (`nil` sem sessão e sem página: landing).
    func currentDestination() -> NavDestination? {
        switch computers.page {
        case .viewer(let name): return .viewer(name)
        case .computers: return .computers
        case .batch(let name): return .batch(name)
        case .library: return .library
        case .datasets: return .datasets
        case .dataset(let id): return .dataset(id)
        case .workspace: break
        }
        if sidebar.inboxOpen { return .inbox }
        guard let session = sidebar.selectedSession else { return nil }
        if workspace.currentSessionID == session, let terminal = workspace.focusedTerminalID { return .terminal(session: session, terminal: terminal) }
        return .session(session)
    }

    func isValid(_ destination: NavDestination) -> Bool {
        switch destination {
        case .session(let id): sidebar.session(id) != nil
        case .terminal(let session, let terminal): sidebar.session(session) != nil && sidebar.snapshot.terminals.contains(where: { $0.id == terminal })
        case .viewer(let name): computers.model.computer(named: name) != nil
        case .computers: true
        case .batch(let name): computers.model.batch(name) != nil
        case .inbox: attention != nil
        case .library: true
        case .datasets: true
        case .dataset(let id): datasets.summaries.contains { $0.dataset.id == id } || datasets.currentID == id
        }
    }

    func noteNavigation() {
        guard !navigating, let destination = currentDestination() else { return }
        navigation.record(destination)
        refreshNavigationState()
    }

    func refreshNavigationState() {
        shell.canGoBack = navigation.canMove(-1, isValid: isValid)
        shell.canGoForward = navigation.canMove(1, isValid: isValid)
    }

    /// ←/→: vai ao destino anterior/seguinte que ainda existe. `false` se não há para onde ir.
    @discardableResult
    func navigate(_ delta: Int) -> Bool {
        noteNavigation()
        guard let destination = navigation.move(delta, isValid: isValid) else {
            refreshNavigationState()
            return false
        }
        navigating = true
        apply(destination)
        navigating = false
        // A lista da sidebar pede o foco ao selecionar; ir e voltar pelo histórico devolve o teclado ao terminal.
        if case .viewer = destination {} else if destination != .computers, destination != .inbox, destination != .datasets {
            DispatchQueue.main.async { [workspace] in workspace.focusTerminalOfActiveTab() }
        }
        refreshNavigationState()
        return true
    }

    private func apply(_ destination: NavDestination) {
        switch destination {
        case .viewer(let name):
            sidebar.setInbox(open: false)
            computers.openViewer(name)
        case .computers:
            computers.show(.computers)
        case .batch(let name):
            sidebar.setInbox(open: false)
            computers.openBatch(name)
        case .inbox:
            computers.closePage()
            sidebar.setInbox(open: true)
        case .session(let id):
            computers.closePage()
            sidebar.select(id, requestingListFocus: false)
        case .terminal(let session, let terminal):
            computers.closePage()
            sidebar.select(session, requestingListFocus: false)
            workspace.show(terminalID: terminal)
        case .library:
            sidebar.setInbox(open: false)
            computers.show(.library)
        case .datasets:
            sidebar.setInbox(open: false)
            computers.show(.datasets)
        case .dataset(let id):
            sidebar.setInbox(open: false)
            Task { _ = await datasets.open(id) }
        }
    }
}
