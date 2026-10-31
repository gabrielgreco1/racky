import RackyCore
import RackyDesignSystem
import RackyPlatform
import RackyProtocol
import RackyStore
import AppKit
import Foundation
import SwiftUI

/// Escolhe a pasta de uma sessão limpa ou da worktree (`NSOpenPanel` nativo; testes e automação trocam por um fake).
@MainActor
protocol SessionFolderPicking {
    func chooseFolder(title: String, message: String, prompt: String) async -> URL?
}

@MainActor
struct OpenPanelSessionFolderPicker: SessionFolderPicking {
    func chooseFolder(title: String, message: String, prompt: String) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.title = title
        panel.message = message
        panel.prompt = prompt
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            if let window = NSApp.keyWindow {
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            } else {
                panel.begin { continuation.resume(returning: $0) }
            }
        }
        return response == .OK ? panel.url : nil
    }
}

/// Composer ⌘N de verdade (T1-20, 03 §6): abre o overlay com o modelo, registra as ações `composer.*`, `session.new*` e
/// `project.newSession*` e, ao criar, entrega o pedido ao `SessionLauncher` (P9: o overlay fecha na hora e a linha pendente
/// aparece na sidebar).
@MainActor
final class ComposerController {
    private let sidebar: SidebarModel
    private let settings: SettingsModel
    private let overlays: OverlayRouter
    private let toasts: ToastCenter
    private let elements: UIElementStore
    private let launcher: SessionLauncher
    private let automationEnabled: Bool
    var picker: any SessionFolderPicking = OpenPanelSessionFolderPicker()
    private(set) var model: ComposerModel?
    /// Lugares de "Save data to" (área Data).
    @ObservationIgnored var dataDestinations: () -> [ComposerDataDestination] = { [] }
    private var store: RackyStore?
    private var registry: ActionRegistry?
    private var saved = ComposerPersistedState()
    private let log = LogFacade(.app, category: "composer")

    init(
        sidebar: SidebarModel, settings: SettingsModel, overlays: OverlayRouter, toasts: ToastCenter, elements: UIElementStore,
        launcher: SessionLauncher, automationEnabled: Bool
    ) {
        self.sidebar = sidebar
        self.settings = settings
        self.overlays = overlays
        self.toasts = toasts
        self.elements = elements
        self.launcher = launcher
        self.automationEnabled = automationEnabled
    }

    func attach(store: RackyStore) async {
        self.store = store
        if let state = try? await store.uiState(ComposerModel.uiStateKey, as: ComposerPersistedState.self) { saved = state }
    }

    // MARK: Abrir

    /// Abre o composer. `project` pré-seleciona o projeto (`+` do projeto); sem ele vale a sessão atual, depois o último usado.
    @discardableResult
    func open(project: UUID? = nil, whereChoice: ComposerWhere? = nil, from origin: A11yID? = .sidebarProjectsNewSession) -> Bool {
        let current = sidebar.selectedSession.flatMap { sidebar.session($0)?.projectID }
        let model = ComposerModel(sidebar: sidebar, settings: settings, initial: saved, preferredProject: project ?? current)
        if let whereChoice, model.whereOptions.contains(whereChoice) { model.setWhere(whereChoice) }
        model.dataDestinations = dataDestinations
        self.model = model
        return overlays.present(
            OverlaySpec(
                name: "composer", id: .overlayComposer, width: DS.Layout.composerWidth, cancelAction: .composerCancel,
                dismissOnScrim: { !model.draft.hasData },
                content: { AnyView(ComposerView(model: model)) }),
            from: origin)
    }

    private var isOpen: Bool { overlays.top?.spec.name == "composer" && model != nil }

    // MARK: Criar

    /// ⌘↵ de qualquer campo. Fecha o overlay na hora (ou limpa para o próximo com Create More) e entrega ao launcher.
    @discardableResult
    func submit(_ arg: ActionArgument = .press) async throws -> String {
        guard let model, isOpen else { throw ActionError.failed(.composerSubmit, message: "The composer isn't open") }
        await model.settle()
        guard self.model === model, isOpen else { throw ActionError.failed(.composerSubmit, message: "The composer isn't open") }
        let context = model.context
        // O risco só passa pelo botão "Create anyway" (`select("anyway")`); ⌘↵ de novo mantém a pergunta.
        if model.needsRiskConfirmation, !(model.confirmingRisk && arg == .select("anyway")) {
            model.confirmingRisk = true
            return "confirming risk"
        }
        model.confirmingRisk = false
        guard let request = model.draft.request(context) else {
            throw ActionError.failed(.composerSubmit, message: model.issues.first?.message ?? "Fill in the required fields")
        }
        let origin = elements.frame(of: .overlayComposerSubmit).map { [Double($0.midX), Double($0.midY)] }
        let pendingID = launcher.begin(request, projectID: model.draft.projectID, origin: origin)
        remember(model)
        if model.draft.createMore {
            model.resetForNext()
        } else {
            self.model = nil
            overlays.dismiss(.action)
        }
        return pendingID.uuidString
    }

    private func remember(_ model: ComposerModel) {
        saved = model.persisted
        guard let store else { return }
        let state = saved
        Task { try? await store.scheduleUIState(ComposerModel.uiStateKey, state) }
    }

    /// Um projeto acabou de ser clonado (`Clone from GitHub…` aberto pelo combobox Project): seleciona-o no composer, que
    /// continua aberto com o que já foi digitado. Sem composer aberto não faz nada.
    /// Clone terminou (pelo composer ou pela tela inicial): o próximo passo é a sessão nesse projeto, então o composer abre (ou
    /// continua aberto) com o projeto clonado já escolhido. Espera o projeto chegar à sidebar (clone grande: o banco avisa
    /// depois de alguns segundos; com 2 s a escolha se perdia em silêncio e o composer ficava em "No Project").
    func projectCloned(_ project: Project) {
        Task { @MainActor in
            for _ in 0 ..< 300 where sidebar.project(project.id) == nil { try? await Task.sleep(for: .milliseconds(50)) }
            guard sidebar.project(project.id) != nil else { return }
            if !isOpen { _ = open() }
            guard let model, isOpen else { return }
            model.setProject(project.id)
        }
    }

    // MARK: Ações

    func register(in registry: ActionRegistry) throws {
        self.registry = registry
        try registry.register(.sessionNew, enablement: { [unowned self] in
            overlays.live.count < OverlayRouter.maxDepth || isOpen ? .enabled : .disabled(reason: "Close the open dialog first")
        }) { [unowned self] _ in
            if isOpen { return "opened" }
            return open() ? "opened" : "busy"
        }
        for action in [ActionID.projectNewSession, .projectNewSessionFromRef] {
            try registry.register(action) { [unowned self] arg in
                guard arg.kind == .select, let raw = arg.value, let id = UUID(uuidString: raw), sidebar.project(id) != nil else {
                    throw ActionError.failed(action, message: "Project not found")
                }
                let opened = open(project: id, whereChoice: .newWorktree, from: .sidebarProject(raw))
                if opened, action == .projectNewSessionFromRef { model?.draft.createFrom = "" }
                return opened ? "opened" : "busy"
            }
        }

        func edit(_ id: ActionID, _ change: @escaping @MainActor (ComposerModel, ActionArgument) async throws -> String?) throws {
            try registry.register(id) { [unowned self] arg in
                guard let model, isOpen else { throw ActionError.failed(id, message: "The composer isn't open") }
                return try await change(model, arg)
            }
        }
        try edit(.composerSetProject) { [unowned self] model, arg in
            if arg.kind == .select, let value = arg.value {
                if value == "none" {
                    model.setProject(nil)
                } else if let id = UUID(uuidString: value), sidebar.project(id) != nil {
                    model.setProject(id)
                } else {
                    throw ActionError.failed(.composerSetProject, message: "Project not found")
                }
                return model.draft.projectID?.uuidString ?? "none"
            }
            // `Add a New Project…` (fixo no rodapé): escolhe a pasta e volta ao composer com tudo o que já foi digitado.
            guard let registry = self.registry else { return nil }
            let result = try await registry.perform(.projectAdd, .press)
            if let raw = result.message, let id = UUID(uuidString: raw) {
                for _ in 0 ..< 100 where sidebar.project(id) == nil { try? await Task.sleep(for: .milliseconds(20)) }
                model.setProject(id)
                return raw
            }
            return "cancelled"
        }
        try edit(.composerSetWhere) { model, arg in
            if let value = arg.value, let choice = ComposerWhere(rawValue: value) { model.setWhere(choice) }
            return model.draft.whereChoice.rawValue
        }
        try edit(.composerSetBase) { [unowned self] model, arg in
            // `set(<texto>)`: o campo "Create from"; `select(<ref>)`: o seletor de base; `press`: abre a lista de bases.
            if arg.kind == .set {
                model.setCreateFrom(arg.value ?? "")
                return model.draft.createFrom
            }
            if arg.kind == .select, let value = arg.value {
                model.draft.baseRef = value == model.defaultBaseRef ? nil : value
                return model.baseLabel
            }
            guard let anchor = elements.frame(of: .overlayComposerBaseRef), let registry = self.registry else { return nil }
            DSMenuPanel.present(
                router: overlays, registry: registry, name: "composerBase", anchor: anchor,
                entries: model.baseEntries.map { entry in
                    guard case .item(var item) = entry else { return entry }
                    item.action = .composerSetBase
                    item.argument = .select(item.id)
                    return .item(item)
                })
            return "menu"
        }
        try edit(.composerReuseBranch) { model, arg in
            if arg.kind == .press {
                model.reuseTypedBranch()
            } else {
                model.draft.reuseBranch = arg.value != "off"
            }
            return model.draft.reuseBranch ? "on" : "off"
        }
        try edit(.composerSetWorktree) { model, arg in
            if let value = arg.value { model.draft.worktreeID = UUID(uuidString: value) }
            return model.draft.worktreeID?.uuidString
        }
        try edit(.composerChooseFolder) { [unowned self] model, arg in
            if arg.kind == .set {
                guard automationEnabled, let path = arg.value, !path.isEmpty else { throw ActionError.failed(.composerChooseFolder, message: "Automation is off") }
                model.draft.folderPath = path
                return path
            }
            guard let url = await picker.chooseFolder(
                title: String(localized: "Choose a Folder", bundle: .module),
                message: String(localized: "The session runs in this folder. Racky doesn't create or delete anything in it.", bundle: .module),
                prompt: String(localized: "Select", bundle: .module))
            else { return "cancelled" }
            model.draft.folderPath = url.path
            return url.path
        }
        try edit(.composerSetAgent) { model, arg in
            if let value = arg.value, let provider = TerminalProvider(rawValue: value), provider != .custom { model.setProvider(provider) }
            return model.draft.provider.rawValue
        }
        try edit(.composerSetDefaultAgent) { [unowned self] model, arg in
            let provider = arg.value.flatMap(TerminalProvider.init(rawValue:)) ?? model.draft.provider
            guard let registry = self.registry else { return nil }
            _ = try await registry.perform(.settingsAgentsDefaultAgent, .select(provider.rawValue))
            return provider.rawValue
        }
        try edit(.composerManageAgents) { [unowned self] _, _ in
            overlays.dismiss(.action)
            self.model = nil
            _ = try await self.registry?.perform(.settingsOpenSection, .select("agents"))
            return "settings"
        }
        try edit(.composerSetSubagentComputers) { model, arg in
            guard model.draft.provider.supportsSubagentComputers else { throw ActionError.failed(.composerSetSubagentComputers, message: "Subagent computers works with Claude Code, Codex and OpenCode.") }
            if let value = arg.value, let mode = SubagentComputersMode(rawValue: value) { model.draft.subagentComputers = mode }
            return model.draft.subagentComputers.rawValue
        }
        try edit(.composerSetSubagentHarness) { model, arg in
            if let value = arg.value, let harness = SubagentHarness(rawValue: value) { model.draft.subagentHarness = harness }
            return model.draft.subagentHarness.rawValue
        }
        try edit(.composerSetDataDestination) { model, arg in
            if let value = arg.value { model.draft.dataDestination = value }
            return model.draft.dataDestination
        }
        try edit(.composerSetProfile) { model, arg in
            if let value = arg.value { model.draft.profileID = UUID(uuidString: value) }
            return model.draft.profileID?.uuidString
        }
        try edit(.composerEditProfiles) { [unowned self] _, _ in
            overlays.dismiss(.action)
            self.model = nil
            _ = try await self.registry?.perform(.settingsOpenSection, .select("agents"))
            return "settings"
        }
        try edit(.composerSetPrompt) { model, arg in
            model.draft.prompt = arg.value ?? ""
            return nil
        }
        try edit(.composerToggleAdvanced) { [unowned self] model, _ in
            model.advancedOpen.toggle()
            remember(model)
            return model.advancedOpen ? "expanded" : "collapsed"
        }
        try edit(.composerSetSessionName) { model, arg in
            model.draft.sessionName = arg.value ?? ""
            return nil
        }
        try edit(.composerSetBranchName) { model, arg in
            model.setBranchName(arg.value ?? "")
            return nil
        }
        try edit(.composerChangeLocation) { [unowned self] model, arg in
            if arg.kind == .set {
                guard automationEnabled, let path = arg.value, !path.isEmpty else { throw ActionError.failed(.composerChangeLocation, message: "Automation is off") }
                model.draft.locationRoot = path
                return path
            }
            guard let url = await picker.chooseFolder(
                title: String(localized: "Where to Create Worktrees", bundle: .module),
                message: String(localized: "New worktrees go in a folder named after the project inside this one.", bundle: .module),
                prompt: String(localized: "Select", bundle: .module))
            else { return "cancelled" }
            model.draft.locationRoot = url.path
            return url.path
        }
        try edit(.composerCreateMore) { model, arg in
            model.draft.createMore = arg.value == "on"
            return model.draft.createMore ? "on" : "off"
        }
        try registry.register(.composerSubmit) { [unowned self] arg in try await submit(arg) }
        try registry.register(.composerCancel) { [unowned self] _ in
            guard let model, isOpen else {
                overlays.dismiss(.action)
                return nil
            }
            if model.confirmingDiscard || model.confirmingRisk {
                model.confirmingDiscard = false
                model.confirmingRisk = false
                return "keep editing"
            }
            if model.draft.hasData {
                model.confirmingDiscard = true
                return "confirming"
            }
            self.model = nil
            overlays.dismiss(.escape)
            return "closed"
        }
        try registry.register(.composerKeepEditing) { [unowned self] _ in
            model?.confirmingDiscard = false
            model?.confirmingRisk = false
            return nil
        }
        try registry.register(.composerDiscard) { [unowned self] _ in
            model = nil
            overlays.dismiss(.action)
            return nil
        }
    }
}
