import RackyProtocol
import AppKit
import Foundation

/// Efeitos de sistema da sidebar (área de transferência, Finder), trocáveis nos testes.
struct SidebarSystemActions {
    var copy: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    var reveal: (URL) -> Void = { url in NSWorkspace.shared.activateFileViewerSelecting([url]) }
}

extension SidebarModel {
    /// Registra no `ActionRegistry` as ações da sidebar que esta tarefa possui (03 §24.2). Menus, botões, teclado e
    /// `ctl ui action` disparam o mesmo handler. Ações cujo fluxo é de outra tarefa (composer, arquivar, apagar, abrir no
    /// editor, atualizar Git...) não são registradas aqui e, por isso, não aparecem nos menus (`ActionRegistry.isOffered`).
    func registerActions(in registry: ActionRegistry, system: SidebarSystemActions = SidebarSystemActions()) throws {
        func uuid(_ arg: ActionArgument, _ id: ActionID) throws -> UUID {
            guard arg.kind == .select, let raw = arg.value, let value = UUID(uuidString: raw) else {
                throw ActionError.failed(id, message: "expected select(<id>)")
            }
            return value
        }
        func selectedOrArgument(_ arg: ActionArgument, _ id: ActionID) throws -> UUID {
            if arg.kind == .select { return try uuid(arg, id) }
            guard let s = selectedSession else { throw ActionError.failed(id, message: "No session selected") }
            return s
        }
        /// Caminho de um projeto ou de uma sessão pelo ID.
        func path(of id: UUID) -> String? { project(id)?.rootPath ?? session(id)?.folderPath }

        try registry.register(.sessionSelect) { [unowned self] arg in
            // `select(<id>|agent)`: além de abrir a sessão, mostra o terminal do agente (com uma tab de dados na frente, só
            // selecionar a sessão não mudava nada na tela).
            if arg.kind == .select, let raw = arg.value, raw.hasSuffix("|agent"), let id = UUID(uuidString: String(raw.dropLast(6))) {
                guard select(id) else { throw ActionError.failed(.sessionSelect, message: "Session not found") }
                onShowAgent?(id)
                return "agent"
            }
            let id = try uuid(arg, .sessionSelect)
            if pending(id) != nil, session(id) == nil {
                focus(pending: id)
                return "pending"
            }
            guard select(id) else { throw ActionError.failed(.sessionSelect, message: "Session not found") }
            return "selected"
        }
        let order: [(ActionID, Int)] = [
            (.sessionSelect1, 1), (.sessionSelect2, 2), (.sessionSelect3, 3), (.sessionSelect4, 4), (.sessionSelect5, 5),
            (.sessionSelect6, 6), (.sessionSelect7, 7), (.sessionSelect8, 8), (.sessionSelect9, 9),
        ]
        for (action, n) in order {
            try registry.register(action, enablement: { [unowned self] in
                projection.sessionOrder.indices.contains(n - 1) ? .enabled : .disabled(reason: "No session \(n)")
            }) { [unowned self] _ in selectNth(n)?.uuidString }
        }
        try registry.register(.sessionPrevious) { [unowned self] _ in selectNeighbor(-1)?.uuidString }
        try registry.register(.sessionNext) { [unowned self] _ in selectNeighbor(1)?.uuidString }
        try registry.register(.sidebarFocus) { [unowned self] _ in
            requestListFocus()
            return "focused"
        }
        try registry.register(.sidebarSearch) { [unowned self] arg in
            if arg.kind == .set { query = arg.value ?? "" } else { requestSearchFocus() }
            return query
        }
        try registry.register(.sidebarClearSearch) { [unowned self] _ in
            query = ""
            return nil
        }
        try registry.register(.sidebarSortFilter) { [unowned self] arg in
            switch arg.kind {
            case .select:
                switch arg.value {
                case "sort:recent": setSort(.recent)
                case "sort:name": setSort(.name)
                default: throw ActionError.failed(.sidebarSortFilter, message: "unknown sort \(arg.value ?? "")")
                }
                return sort.rawValue
            case .set:
                let parts = (arg.value ?? "").split(separator: "=").map(String.init)
                guard parts.count == 2 else { throw ActionError.failed(.sidebarSortFilter, message: "expected <filter>=on|off") }
                setFilter(parts[0], on: parts[1] == "on")
                return nil
            default:
                filterMenuOpen.toggle()
                return filterMenuOpen ? "opened" : "closed"
            }
        }
        try registry.register(.sidebarResetFilters) { [unowned self] _ in
            resetFilters()
            return nil
        }
        try registry.register(.sidebarClearFilters) { [unowned self] _ in
            clearFilters()
            return nil
        }
        try registry.register(.sidebarProjectToggle) { [unowned self] arg in
            let id = try uuid(arg, .sidebarProjectToggle)
            guard project(id) != nil else { throw ActionError.failed(.sidebarProjectToggle, message: "Project not found") }
            toggleProject(id)
            return collapsedProjects.contains(id) ? "collapsed" : "expanded"
        }
        try registry.register(.projectShowMore) { [unowned self] arg in
            guard arg.kind == .select, let raw = arg.value else { throw ActionError.failed(.projectShowMore, message: "expected select(<id>)") }
            if raw.hasPrefix("less:"), let id = UUID(uuidString: String(raw.dropFirst(5))) {
                showMore(id, open: false)
            } else if let id = UUID(uuidString: raw) {
                showMore(id)
            } else {
                throw ActionError.failed(.projectShowMore, message: "expected select(<id>)")
            }
            return nil
        }
        try registry.register(.projectCollapseAll) { [unowned self] arg in
            collapseAllSessions(in: try uuid(arg, .projectCollapseAll))
            return nil
        }
        try registry.register(.projectHide) { [unowned self] arg in
            hideProject(try uuid(arg, .projectHide))
            return nil
        }
        try registry.register(.sessionToggleAgents) { [unowned self] arg in
            let id = try uuid(arg, .sessionToggleAgents)
            guard let card = projection.card(id) else { throw ActionError.failed(.sessionToggleAgents, message: "Session not found") }
            if card.summary != nil, !card.agentsCollapsed {
                toggleSummary(id)
                return card.summaryExpanded ? "collapsed" : "expanded"
            }
            setSession(id, agentsCollapsed: !card.agentsCollapsed)
            return card.agentsCollapsed ? "expanded" : "collapsed"
        }
        try registry.register(.agentToggleChildren) { [unowned self] arg in
            let id = try uuid(arg, .agentToggleChildren)
            toggleChildren(terminal: id)
            return collapsedChildren.contains(id) ? "collapsed" : "expanded"
        }
        try registry.register(.sessionRename) { [unowned self] arg in
            switch arg.kind {
            case .set:
                try await commitRename(arg.value ?? "")
                return nil
            default:
                let id = try selectedOrArgument(arg, .sessionRename)
                guard beginRename(id) else { throw ActionError.failed(.sessionRename, message: "Session not found") }
                return "renaming"
            }
        }
        // Nota da sessão (AC-208): `select(<id>)` abre a edição inline; `set(<texto>)` grava (vazio remove).
        try registry.register(.sessionEditNote) { [unowned self] arg in
            switch arg.kind {
            case .set:
                guard let target = editingNote ?? selectedSession else { throw ActionError.failed(.sessionEditNote, message: "No session selected") }
                try await commitNote(arg.value ?? "", to: target)
                return session(target)?.statusNote?.text ?? ""
            default:
                let id = try selectedOrArgument(arg, .sessionEditNote)
                guard beginEditNote(id) else { throw ActionError.failed(.sessionEditNote, message: "Session not found") }
                return "editing"
            }
        }
        try registry.register(.sidebarRevealCurrent, enablement: { [unowned self] in
            selectedSession == nil ? .disabled(reason: "No session selected") : .enabled
        }) { [unowned self] _ in revealCurrent() ? "revealed" : nil }

        try registry.register(.itemRevealInFinder) { arg in
            let id = try uuid(arg, .itemRevealInFinder)
            guard let p = path(of: id) else { throw ActionError.failed(.itemRevealInFinder, message: "Item not found") }
            system.reveal(URL(fileURLWithPath: p))
            return p
        }
        try registry.register(.itemCopyPath) { arg in
            let id = try uuid(arg, .itemCopyPath)
            guard let p = path(of: id) else { throw ActionError.failed(.itemCopyPath, message: "Item not found") }
            system.copy(p)
            return p
        }
        try registry.register(.sessionCopyBranch) { [unowned self] arg in
            let id = try uuid(arg, .sessionCopyBranch)
            guard let s = session(id), let branch = worktree(of: s)?.branch, !branch.isEmpty else {
                throw ActionError.failed(.sessionCopyBranch, message: "No branch")
            }
            system.copy(branch)
            return branch
        }
        try registry.register(.itemCopyId) { arg in
            guard arg.kind == .select, let raw = arg.value else { throw ActionError.failed(.itemCopyId, message: "expected select(<id>)") }
            system.copy(raw)
            return raw
        }
        try registry.register(.sessionCancelLaunch) { [unowned self] arg in
            let id = try uuid(arg, .sessionCancelLaunch)
            guard cancel(pending: id) || cancelLaunchFallback(id) else {
                throw ActionError.failed(.sessionCancelLaunch, message: "Session already created")
            }
            return nil
        }
        try registry.register(.sessionDiscardPending) { [unowned self] arg in
            let id = try uuid(arg, .sessionDiscardPending)
            onDiscardPending(id)
            finish(pending: id)
            return nil
        }
    }
}

extension SidebarProjection {
    func card(_ id: UUID) -> SessionCardData? {
        for p in projects { if let c = p.sessions.first(where: { $0.id == id }) { return c } }
        return cleanSessions.first { $0.id == id }
    }
}
