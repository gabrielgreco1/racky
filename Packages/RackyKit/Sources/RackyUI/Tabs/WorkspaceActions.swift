import RackyCore
import RackyDesignSystem
import RackyProtocol
import AppKit
import Foundation

extension WorkspaceModel {
    private static let noSession = "Select a session first."
    private static let onlyOnePane = "Only one pane"

    /// Registra as ações de tabs, panes e terminal que esta tarefa possui (03 §24.3). Menus, botões, teclado, menus de contexto
    /// e `ctl ui action` disparam o mesmo handler. `includeCloseDialog` liga os botões do overlay "Close this terminal?".
    func registerActions(
        in registry: ActionRegistry, elements: UIElementStore, includeCloseDialog: Bool = true, excluding: Set<ActionID> = []
    ) throws {
        func reg(_ id: ActionID, enablement: @escaping ActionRegistry.Enablement = { .enabled }, handler: @escaping ActionRegistry.Handler) throws {
            guard !excluding.contains(id) else { return }
            try registry.register(id, enablement: enablement, handler: handler)
        }
        func uuid(_ arg: ActionArgument) -> UUID? { arg.kind == .select ? arg.value.flatMap { UUID(uuidString: $0) } : nil }
        let hasSession: ActionRegistry.Enablement = { [unowned self] in
            isLoaded ? .enabled : .disabled(reason: Self.noSession)
        }
        let hasTab: ActionRegistry.Enablement = { [unowned self] in
            guard isLoaded else { return .disabled(reason: Self.noSession) }
            return activeTab == nil ? .disabled(reason: "No tab is open") : .enabled
        }
        let hasPanes: ActionRegistry.Enablement = { [unowned self] in
            guard isLoaded else { return .disabled(reason: Self.noSession) }
            return (activeTab?.layout.leafCount ?? 0) > 1 ? .enabled : .disabled(reason: Self.onlyOnePane)
        }

        // Nova tab
        try reg(.tabNewTerminal, enablement: hasSession) { [unowned self] _ in newTab(provider: .shell)?.uuidString }
        // ⌥⌘T: agente e perfil padrão, sem seletor (03 §7). Não instalado: motivo com a saída (03 §24.3).
        let defaultAgentReady: ActionRegistry.Enablement = { [unowned self] in
            guard isLoaded else { return .disabled(reason: Self.noSession) }
            let agent = defaultAgent()
            if agentInstalled(agent) == false {
                let name = AgentInfo.displayName(agent)
                return .disabled(reason: String(localized: "Install \(name) or choose another default agent.", bundle: .module))
            }
            return .enabled
        }
        try reg(.tabNewAgent, enablement: defaultAgentReady) { [unowned self] _ in newTab(provider: defaultAgent())?.uuidString }
        try reg(.tabNewWithAgent, enablement: hasSession) { [unowned self] arg in
            guard arg.kind == .select, let raw = arg.value, let provider = TerminalProvider(rawValue: raw) else {
                throw ActionError.failed(.tabNewWithAgent, message: "expected select(<provider>)")
            }
            return newTab(provider: provider)?.uuidString
        }
        try reg(.tabReopen, enablement: { [unowned self] in
            guard isLoaded else { return .disabled(reason: Self.noSession) }
            return hasClosedTabs ? .enabled : .disabled(reason: "No closed tabs")
        }) { [unowned self] _ in
            reopenClosedTab()
            return nil
        }

        // Fechar
        try reg(.paneClose, enablement: hasTab) { [unowned self] arg in
            if arg.value == nil, pageCloser() { return nil }
            closePane(uuid(arg))
            return nil
        }
        try reg(.tabClose, enablement: hasTab) { [unowned self] arg in
            if arg.value == nil, pageCloser() { return nil }
            closeTab(uuid(arg))
            return nil
        }
        try reg(.tabCloseOthers, enablement: { [unowned self] in
            isLoaded && tabs.count > 1 ? .enabled : .disabled(reason: "No other tabs")
        }) { [unowned self] arg in
            closeOtherTabs(except: uuid(arg))
            return nil
        }
        try reg(.tabCloseRight, enablement: { [unowned self] in
            guard isLoaded, let i = tabs.firstIndex(where: { $0.id == activeTabID }), i < tabs.count - 1 else { return .disabled(reason: "No tabs to the right") }
            return .enabled
        }) { [unowned self] arg in
            closeTabs(toTheRightOf: uuid(arg))
            return nil
        }
        try reg(.paneCloseOthers, enablement: hasPanes) { [unowned self] arg in
            closeOtherPanes(keeping: uuid(arg))
            return nil
        }

        // Navegar entre tabs
        try reg(.tabNext, enablement: hasTab) { [unowned self] _ in
            selectTab(delta: 1)
            return activeTabID?.uuidString
        }
        try reg(.tabPrevious, enablement: hasTab) { [unowned self] _ in
            selectTab(delta: -1)
            return activeTabID?.uuidString
        }
        try reg(.tabRecent, enablement: hasTab) { [unowned self] arg in
            selectRecentTab(reverse: arg.value == "reverse")
            return activeTabID?.uuidString
        }
        let selects: [ActionID] = [
            .tabSelect1, .tabSelect2, .tabSelect3, .tabSelect4, .tabSelect5, .tabSelect6, .tabSelect7, .tabSelect8, .tabSelect9,
        ]
        for (i, action) in selects.enumerated() {
            try reg(action, enablement: { [unowned self] in
                tabs.indices.contains(i) ? .enabled : .disabled(reason: "No tab \(i + 1)")
            }) { [unowned self] _ in
                selectTab(at: i)
                return activeTabID?.uuidString
            }
        }

        // Renomear, reordenar
        try reg(.tabRename, enablement: hasTab) { [unowned self] arg in
            switch arg.kind {
            case .set:
                commitRename(arg.value ?? "")
                return nil
            default:
                guard let id = uuid(arg) ?? activeTabID, beginRename(id) else { throw ActionError.failed(.tabRename, message: "Tab not found") }
                return "renaming"
            }
        }
        try reg(.tabResetTitle, enablement: { [unowned self] in
            guard isLoaded, let tab = activeTab else { return .disabled(reason: Self.noSession) }
            return tab.titleLocked ? .enabled : .disabled(reason: "Title isn't customized")
        }) { [unowned self] arg in
            if let id = uuid(arg) ?? activeTabID { resetTitle(id) }
            return nil
        }
        try reg(.tabReorder, enablement: hasTab) { [unowned self] arg in
            let parts = (arg.value ?? "").split(separator: "=").map(String.init)
            guard arg.kind == .set, parts.count == 2, let id = UUID(uuidString: parts[0]), let index = Int(parts[1]) else {
                throw ActionError.failed(.tabReorder, message: "expected set(<tabId>=<index>)")
            }
            moveTab(id, to: index)
            return "\(tabs.firstIndex { $0.id == id } ?? -1)"
        }

        // Arrastar para a área de panes (F11): as mesmas operações do arrasto, acionáveis por `ctl ui action`.
        func dropArgument(_ arg: ActionArgument, _ id: ActionID) throws -> (UUID, UUID, PaneDropZone) {
            let sides = (arg.value ?? "").split(separator: "=", maxSplits: 1).map(String.init)
            let rest = sides.count == 2 ? sides[1].split(separator: "@").map(String.init) : []
            guard arg.kind == .set, sides.count == 2, rest.count == 2, let source = UUID(uuidString: sides[0]),
                  let target = UUID(uuidString: rest[0]), let zone = PaneDropZone(rawValue: rest[1])
            else { throw ActionError.failed(id, message: "expected set(<id>=<terminalId>@left|right|top|bottom|center)") }
            return (source, target, zone)
        }
        func dropResult(_ outcome: DropOutcome, _ id: ActionID) throws -> String? {
            switch outcome {
            case .applied: return "applied"
            case .noRoom: return "noRoom"
            case .invalid: throw ActionError.failed(id, message: "that drop is not possible here")
            }
        }
        try reg(.tabDropOnPane, enablement: hasTab) { [unowned self] arg in
            let (tabID, target, zone) = try dropArgument(arg, .tabDropOnPane)
            return try dropResult(performDrop(.tab(tabID), onTerminal: target, zone: zone), .tabDropOnPane)
        }
        try reg(.paneMove, enablement: hasPanes) { [unowned self] arg in
            let (source, target, zone) = try dropArgument(arg, .paneMove)
            return try dropResult(performDrop(.pane(source), onTerminal: target, zone: zone), .paneMove)
        }
        try reg(.paneDetach, enablement: hasPanes) { [unowned self] arg in
            let outcome: DropOutcome
            if arg.kind == .select, let id = uuid(arg) {
                outcome = detachPane(id)
            } else {
                let parts = (arg.value ?? "").split(separator: "=").map(String.init)
                guard arg.kind == .set, parts.count == 2, let id = UUID(uuidString: parts[0]), let index = Int(parts[1]) else {
                    throw ActionError.failed(.paneDetach, message: "expected select(<terminalId>) or set(<terminalId>=<index>)")
                }
                outcome = detachPane(id, toIndex: index)
            }
            return try dropResult(outcome, .paneDetach)
        }

        // Panes
        try reg(.paneSplitRight, enablement: hasTab) { [unowned self] arg in
            try splitResult(split(.horizontal, source: uuid(arg), shell: EventModifiers.held(.option)), .paneSplitRight)
        }
        try reg(.paneSplitDown, enablement: hasTab) { [unowned self] arg in
            try splitResult(split(.vertical, source: uuid(arg), shell: EventModifiers.held(.option)), .paneSplitDown)
        }
        try reg(.paneNext, enablement: hasPanes) { [unowned self] _ in focusNextPane(delta: 1) ? focusedTerminalID?.uuidString : nil }
        try reg(.panePrevious, enablement: hasPanes) { [unowned self] _ in focusNextPane(delta: -1) ? focusedTerminalID?.uuidString : nil }
        try reg(.paneToggleExpand, enablement: { [unowned self] in
            guard isLoaded, let tab = activeTab else { return .disabled(reason: Self.noSession) }
            return tab.layout.leafCount > 1 || expandedPane(in: tab) != nil ? .enabled : .disabled(reason: Self.onlyOnePane)
        }) { [unowned self] arg in
            toggleExpand(uuid(arg))
            return activeTab.flatMap(expandedPane(in:))?.uuidString
        }
        try reg(.paneEqualize, enablement: hasPanes) { [unowned self] _ in
            equalize()
            return nil
        }
        try reg(.paneShow, enablement: hasSession) { [unowned self] arg in
            // Uma tab sem terminal (só a tabela de um dataset) chega aqui com o id da própria tab: o clique seleciona a tab.
            if let id = uuid(arg), tab(id) != nil {
                selectTab(id)
                return id.uuidString
            }
            guard let id = uuid(arg), tabContaining(terminalID: id) != nil else { throw ActionError.failed(.paneShow, message: "Pane not found") }
            show(terminalID: id)
            return id.uuidString
        }
        try reg(.paneResizeDivider, enablement: hasPanes) { [unowned self] arg in
            let parts = (arg.value ?? "").split(separator: "=").map(String.init)
            guard arg.kind == .set, parts.count == 2, let id = UUID(uuidString: parts[0]), let ratio = Double(parts[1]), let tab = activeTab else {
                throw ActionError.failed(.paneResizeDivider, message: "expected set(<dividerId>=<ratio>)")
            }
            let area = CGRect(origin: .zero, size: contentSize)
            guard let divider = tab.layout.arrangement(in: area).dividers.first(where: { $0.secondLeadingPaneID == id }) else {
                throw ActionError.failed(.paneResizeDivider, message: "Divider not found")
            }
            setRatio(at: divider.path, ratio: ratio, final: true)
            return nil
        }
        try reg(.tabsPaneActions, enablement: hasPanes) { [unowned self] _ in
            guard let overlays else { return nil }
            let anchor = elements.frame(of: .tabsPaneActions) ?? .zero
            let entries: [DSMenuEntry] = [
                .item(DSMenuItem("splitRight", String(localized: "Split Right", bundle: .module), shortcut: ActionID.paneSplitRight.spec.shortcut, action: .paneSplitRight)),
                .item(DSMenuItem("splitDown", String(localized: "Split Down", bundle: .module), shortcut: ActionID.paneSplitDown.spec.shortcut, action: .paneSplitDown)),
                .item(DSMenuItem("equalize", String(localized: "Equalize Pane Sizes", bundle: .module), action: .paneEqualize)),
                .item(DSMenuItem("expand", String(localized: "Expand Pane", bundle: .module), shortcut: ActionID.paneToggleExpand.spec.shortcut, action: .paneToggleExpand)),
                .item(DSMenuItem("closeOthers", String(localized: "Close Other Panes", bundle: .module), action: .paneCloseOthers)),
            ]
            return DSMenuPanel.present(router: overlays, registry: registry, name: "paneActions", anchor: anchor, entries: entries, alignment: .trailing) ? "opened" : nil
        }

        // Terminal
        try reg(.terminalRestart, enablement: hasTab) { [unowned self] arg in
            guard let id = uuid(arg) ?? focusedTerminalID, terminal(id) != nil else { throw ActionError.failed(.terminalRestart, message: "Terminal not found") }
            restart(id)
            return id.uuidString
        }
        try reg(.terminalResume, enablement: hasTab) { [unowned self] arg in
            guard let id = uuid(arg) ?? focusedTerminalID, terminal(id) != nil else { throw ActionError.failed(.terminalResume, message: "Terminal not found") }
            resume(id)
            return id.uuidString
        }
        try reg(.sessionResumeStopped, enablement: { [unowned self] in
            stoppedAgentsInCurrentSession.isEmpty ? .disabled(reason: "No stopped agents") : .enabled
        }) { [unowned self] _ in
            let count = await resumeStoppedAgentsInCurrentSession()
            return String(count)
        }
        try reg(.terminalStartFresh, enablement: hasTab) { [unowned self] arg in
            guard let id = uuid(arg) ?? focusedTerminalID, terminal(id) != nil else { throw ActionError.failed(.terminalStartFresh, message: "Terminal not found") }
            startFresh(id)
            return id.uuidString
        }
        try reg(.terminalRetryStart, enablement: hasTab) { [unowned self] arg in
            guard let id = uuid(arg) ?? focusedTerminalID else { throw ActionError.failed(.terminalRetryStart, message: "Terminal not found") }
            restart(id)
            return id.uuidString
        }
        try reg(.terminalCopyStartError, enablement: hasTab) { [unowned self] arg in
            guard let id = uuid(arg) ?? focusedTerminalID, case .failed(let detail) = paneState(id) else { return nil }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(detail, forType: .string)
            return detail
        }
        try reg(.terminalSendInterrupt, enablement: hasTab) { [unowned self] arg in
            guard let id = uuid(arg) ?? focusedTerminalID, let t = terminal(id) else { return nil }
            await runtime.sendInterrupt(t)
            return nil
        }
        // Automação (08 AR-806 `terminal send|screen`). `set {"terminal":"<uuid>","text":"..."}`; sem `terminal`, o terminal em foco.
        try reg(.terminalSendText, enablement: hasTab) { [unowned self] arg in
            struct Payload: Decodable { var terminal: String?; var text: String }
            let payload = try arg.value.flatMap { try? JSONDecoder().decode(Payload.self, from: Data($0.utf8)) }
                ?? { throw ActionError.failed(.terminalSendText, message: "expected {\"terminal\":\"<uuid>\",\"text\":\"...\"}") }()
            guard let id = payload.terminal.flatMap({ UUID(uuidString: $0) }) ?? focusedTerminalID, let t = terminal(id) else {
                throw ActionError.failed(.terminalSendText, message: "Terminal not found")
            }
            do { try await runtime.sendText(payload.text, to: t) } catch { throw ActionError.failed(.terminalSendText, message: "Terminal isn't running") }
            return String(payload.text.utf8.count)
        }
        // "Paste into <Agent>" (03 §16.12, T11): clique explícito. `set {"terminal":"<uuid>","text":"..."}` ou o texto cru no terminal em foco.
        try reg(.dialogPasteToAgentConfirm, enablement: hasTab) { [unowned self] arg in
            struct Payload: Decodable { var terminal: String?; var text: String }
            let raw = arg.value ?? ""
            let payload = raw.data(using: .utf8).flatMap { try? JSONDecoder().decode(Payload.self, from: $0) } ?? Payload(terminal: nil, text: raw)
            guard let id = payload.terminal.flatMap({ UUID(uuidString: $0) }) ?? focusedTerminalID, let t = terminal(id) else {
                throw ActionError.failed(.dialogPasteToAgentConfirm, message: "Terminal not found")
            }
            guard t.provider.isAgent, paneState(id) == .running else {
                throw ActionError.failed(.dialogPasteToAgentConfirm, message: "The agent isn't ready for input.")
            }
            do {
                let outcome = try await runtime.pasteIntoAgent(payload.text, terminal: t)
                if outcome == .copied { toasts?.show(kind: .info, title: String(localized: "Copied — paste it into the agent", bundle: .module)) }
                return outcome == .pasted ? "pasted" : "copied"
            } catch {
                throw ActionError.failed(.dialogPasteToAgentConfirm, message: "The agent isn't ready for input.")
            }
        }
        try reg(.terminalScreen, enablement: hasTab) { [unowned self] arg in
            guard let id = uuid(arg) ?? focusedTerminalID, let t = terminal(id) else { throw ActionError.failed(.terminalScreen, message: "Terminal not found") }
            do { return try await runtime.screenText(of: t, lines: 200) } catch { throw ActionError.failed(.terminalScreen, message: "Terminal isn't running") }
        }
        try reg(.terminalForceQuit, enablement: hasTab) { [unowned self] arg in
            guard let id = uuid(arg) ?? focusedTerminalID else { return nil }
            forceQuit(id)
            return nil
        }
        try reg(.terminalCancelClose, enablement: hasTab) { [unowned self] arg in
            guard let id = uuid(arg) ?? focusedTerminalID else { return nil }
            cancelClose(id)
            return nil
        }
        try reg(.terminalCopyId, enablement: hasTab) { [unowned self] arg in
            guard let id = uuid(arg) ?? focusedTerminalID else { return nil }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(id.uuidString.lowercased(), forType: .string)
            return id.uuidString.lowercased()
        }
        try reg(.paneCopyId, enablement: hasTab) { [unowned self] arg in
            guard let id = uuid(arg) ?? focusedTerminalID, let pane = tabContaining(terminalID: id)?.layout.pane(forTerminal: id) else { return nil }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(pane.id.uuidString.lowercased(), forType: .string)
            return pane.id.uuidString.lowercased()
        }

        // Overlay "Close this terminal?"
        if includeCloseDialog {
            try reg(.dialogCloseTerminalConfirm) { [unowned self] _ in
                confirmPendingClose()
                return nil
            }
            try reg(.dialogCloseTerminalCancel) { [unowned self] _ in
                cancelPendingClose()
                return nil
            }
            try reg(.dialogCloseTerminalDontAsk) { [unowned self] arg in
                confirmationState.dontAsk = arg.value == "on"
                return nil
            }
        }
    }

    private func splitResult(_ result: SplitResult, _ action: ActionID) throws -> String? {
        switch result {
        case .created(let id): id.uuidString
        case .noRoom: "no room"
        case .unavailable: throw ActionError.failed(action, message: "No pane to split")
        }
    }

    /// Menu de contexto do pane (03 §4.5, F17): `DSMenuPanel` na posição do clique, com as ações que têm dono. O pane já recebeu o foco.
    func presentPaneContextMenu(registry: ActionRegistry, terminalID: UUID, at point: CGPoint) {
        let option = EventModifiers.held(.option)
        let arg = ActionArgument.select(terminalID.uuidString)
        func e(_ action: ActionID, _ title: String, _ argument: ActionArgument = .press) -> MenuEntry { MenuEntry(action: action, title: title, argument: argument) }
        var groups: [[MenuEntry]] = [
            [e(.editCopy, "Copy"), e(.editPaste, "Paste"), e(.editSelectAll, "Select All")],
            [e(.findOpen, "Find…"), e(.terminalClear, "Clear")],
            [e(.paneSplitRight, "Split Right", arg), e(.paneSplitDown, "Split Down", arg), e(.paneEqualize, "Equalize Pane Sizes", arg), e(.paneToggleExpand, "Expand Pane", arg)],
            [e(.tabRename, "Rename…"), e(.tabResetTitle, "Reset Title")],
            [e(.terminalRestart, "Restart", arg), e(.paneClose, "Close Pane", arg)],
        ]
        if option {
            groups.append([
                e(.terminalCopyId, "Copy Terminal ID", arg), e(.paneCopyId, "Copy Pane ID", arg),
                e(.terminalSendInterrupt, "Send Interrupt (⌃C)", arg), e(.terminalForceQuit, String(localized: "pane.menu.forceQuit", bundle: .module), arg),
            ])
        }
        DSMenuPanel.presentContext(
            router: overlays, registry: registry, name: "paneContext", at: point,
            entries: ContextMenuStyle.entries(groups: groups, registry: registry))
    }
}
