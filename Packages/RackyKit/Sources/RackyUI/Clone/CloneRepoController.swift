import RackyCore
import RackyDesignSystem
import RackyPlatform
import RackyProtocol
import RackyStore
import Foundation
import SwiftUI

/// "Clone from GitHub…" (F24, 03 §16.9b): abre o overlay, lista os repositórios da conta via `gh`, clona com progresso no
/// painel e na linha pendente da sidebar, registra o projeto e avisa quem abriu (o composer seleciona o projeto novo).
/// Todo trabalho de rede, git e disco roda nos serviços do Core; aqui só orquestra a UI.
@MainActor
final class CloneRepoController {
    private let sidebar: SidebarModel
    private let overlays: OverlayRouter
    private let toasts: ToastCenter
    private let projects: ProjectsController
    private let projectsRoot: () -> URL
    private let log = LogFacade(.app, category: "clone")

    /// Catálogo e clonador são trocáveis nos testes (runner falso, sem rede).
    var catalog = GitHubRepoCatalog()
    var clonerFactory: @Sendable (@escaping RepoCloner.Register) -> RepoCloner = { RepoCloner(register: $0) }
    /// `gh auth login` numa tab nova: `true` se abriu. Ligado pelo `AppEnvironment` (precisa de uma sessão aberta).
    var openLoginTerminal: (@MainActor ([String]) -> Bool)?
    var canOpenLoginTerminal: @MainActor () -> Bool = { false }
    var ghExecutable: URL? = GitHubProcessRunner.findExecutable()
    /// Chamado com o projeto clonado (ou o já existente): o composer o seleciona.
    var onCloned: (@MainActor (Project) -> Void)?

    private(set) var model: CloneRepoModel?
    private var task: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var pendingID: UUID?
    private var lastReference: RepoReference?

    init(sidebar: SidebarModel, overlays: OverlayRouter, toasts: ToastCenter, projects: ProjectsController, projectsRoot: @escaping () -> URL) {
        self.sidebar = sidebar
        self.overlays = overlays
        self.toasts = toasts
        self.projects = projects
        self.projectsRoot = projectsRoot
    }

    var isOpen: Bool { overlays.top?.spec.name == "cloneRepo" && model != nil }

    // MARK: Abrir

    @discardableResult
    func open(prefill: String = "", from origin: A11yID? = nil) -> Bool {
        if isOpen { return true }
        let model = CloneRepoModel()
        if !prefill.isEmpty { model.setSource(prefill) }
        self.model = model
        let opened = overlays.present(
            OverlaySpec(
                name: "cloneRepo", id: .overlayCloneRepo, width: DS.Layout.dialogWidth, cancelAction: .dialogCloneRepoCancel,
                dismissOnScrim: { !model.isCloning && model.source.isEmpty },
                content: { [weak self] in AnyView(CloneRepoView(model: model, submit: { self?.submitFromKeyboard() })) }),
            from: origin)
        guard opened else {
            self.model = nil
            return false
        }
        loadRepositories(model, force: false)
        return true
    }

    private func loadRepositories(_ model: CloneRepoModel, force: Bool) {
        loadTask?.cancel()
        loadTask = Task { [weak self, catalog] in
            if !force, let cached = await catalog.cached(), !cached.isEmpty {
                await MainActor.run { if self?.model === model { model.setRepositories(cached); model.listing = .ready } }
            }
            do {
                let list = try await catalog.repositories(forceRefresh: force)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self?.model === model else { return }
                    model.setRepositories(list)
                    model.listing = .ready
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    guard self?.model === model else { return }
                    model.listing = CloneRepoModel.listingMessage(for: error)
                }
            }
        }
    }

    // MARK: Clonar

    private func submitFromKeyboard() {
        Task { _ = try? await submit() }
    }

    /// `↵` ou `[Clone]`. Lança se não há o que clonar.
    @discardableResult
    func submit() async throws -> String {
        guard let model, isOpen else { throw ActionError.failed(.dialogCloneRepoSubmit, message: "The clone panel isn't open") }
        guard !model.isCloning else { return "cloning" }
        guard let reference = model.submitReference else {
            throw ActionError.failed(.dialogCloneRepoSubmit, message: "Choose a repository or paste a URL.")
        }
        return start(reference, model: model)
    }

    private func start(_ reference: RepoReference, model: CloneRepoModel) -> String {
        lastReference = reference
        model.beginCloning(reference)
        let pending = PendingLaunch(
            name: reference.name, projectID: nil, phase: .cloning(String(localized: "Cloning…", bundle: .module)), provider: .shell)
        var row = pending
        row.isClone = true
        sidebar.beginPending(row)
        pendingID = row.id
        let id = row.id
        let root = projectsRoot()
        let cloner = clonerFactory { [projects] url in try await projects.addProject(folder: url, announce: false) }
        task = Task { [weak self] in
            do {
                let result = try await cloner.clone(reference, into: root) { progress in
                    Task { @MainActor in self?.apply(progress, to: model, pending: id) }
                }
                await MainActor.run { self?.finish(result, model: model, pending: id) }
            } catch let error as CloneError {
                await MainActor.run { self?.fail(error, model: model, pending: id) }
            } catch {
                await MainActor.run { self?.fail(.failed("\(error)"), model: model, pending: id) }
            }
        }
        sidebar.pendingCancelHooks[id] = { [weak self] in self?.cancelClone(pending: id) }
        return id.uuidString
    }

    private func apply(_ progress: CloneProgress, to model: CloneRepoModel, pending id: UUID) {
        guard pendingID == id else { return }
        model.update(progress)
        let text = progress.percent.map { String(localized: "Cloning… \($0)%", bundle: .module) } ?? String(localized: "Cloning…", bundle: .module)
        sidebar.setCloneProgress(pending: id, text: text)
    }

    private func finish(_ result: CloneResult, model: CloneRepoModel, pending id: UUID) {
        guard pendingID == id else { return }
        endPending(id)
        let name = result.project.name
        if result.alreadyExisted {
            toasts.show(kind: .info, title: String(localized: "\(name) was already cloned. Opened it as a project.", bundle: .module))
        } else {
            toasts.show(kind: .success, title: String(localized: "Cloned \(name).", bundle: .module))
        }
        if sidebar.collapsedProjects.contains(result.project.id) { sidebar.setProject(result.project.id, collapsed: false) }
        if self.model === model, isOpen { overlays.dismiss(.action) }
        self.model = nil
        onCloned?(result.project)
    }

    private func fail(_ error: CloneError, model: CloneRepoModel, pending id: UUID) {
        guard pendingID == id else { return }
        endPending(id)
        if error == .cancelled {
            if self.model === model { model.reset() }
            return
        }
        log.error("clone failed: \(error.localizedDescription)")
        if self.model === model, isOpen {
            model.fail(error.localizedDescription)
        } else {
            toasts.show(kind: .error, title: String(localized: "Couldn't clone the repository.", bundle: .module), detail: error.localizedDescription)
        }
    }

    private func endPending(_ id: UUID) {
        sidebar.pendingCancelHooks[id] = nil
        sidebar.finish(pending: id)
        pendingID = nil
        task = nil
    }

    /// Cancel do painel, da linha pendente ou Esc: para o `git` e remove a pasta parcial (o `RepoCloner` limpa).
    private func cancelClone(pending id: UUID) {
        guard pendingID == id else { return }
        task?.cancel()
        sidebar.pendingCancelHooks[id] = nil
        sidebar.finish(pending: id)
        pendingID = nil
        task = nil
        model?.reset()
    }

    // MARK: Ações

    func register(in registry: ActionRegistry) throws {
        try registry.register(.projectCloneFromGitHub) { [unowned self] arg in
            let prefill = arg.kind == .set ? (arg.value ?? "") : ""
            return open(prefill: prefill, from: overlays.live.isEmpty ? .sidebarProjectsClone : nil) ? "opened" : "busy"
        }
        func edit(_ id: ActionID, _ change: @escaping @MainActor (CloneRepoModel, ActionArgument) throws -> String?) throws {
            try registry.register(id) { [unowned self] arg in
                guard let model, isOpen else { throw ActionError.failed(id, message: "The clone panel isn't open") }
                return try change(model, arg)
            }
        }
        try edit(.dialogCloneRepoSetSource) { model, arg in
            model.setSource(arg.value ?? "")
            return model.source
        }
        try edit(.dialogCloneRepoSelect) { model, arg in
            guard let value = arg.value, model.rows.contains(where: { $0.id == value }) else {
                throw ActionError.failed(.dialogCloneRepoSelect, message: "Repository not found in the list")
            }
            model.select(value)
            return value
        }
        try registry.register(
            .dialogCloneRepoSubmit,
            enablement: { [unowned self] in
                guard let model, isOpen else { return .enabled }
                return model.submitReference == nil && !model.isCloning ? .disabled(reason: "Choose a repository or paste a URL.") : .enabled
            }
        ) { [unowned self] _ in try await submit() }
        try registry.register(.dialogCloneRepoRetry) { [unowned self] _ in
            guard let model, isOpen else { throw ActionError.failed(.dialogCloneRepoRetry, message: "The clone panel isn't open") }
            model.reset()
            guard let reference = lastReference else { return "nothing to retry" }
            return start(reference, model: model)
        }
        try registry.register(.dialogCloneRepoCancel) { [unowned self] _ in
            if let id = pendingID { cancelClone(pending: id) }
            loadTask?.cancel()
            model = nil
            overlays.dismiss(.escape)
            return "closed"
        }
        try registry.register(
            .dialogCloneRepoLogIn,
            enablement: { [unowned self] in
                if ghExecutable == nil { return .disabled(reason: "Install the GitHub CLI first: brew install gh") }
                return canOpenLoginTerminal() ? .enabled : .disabled(reason: "Select a session first.")
            }
        ) { [unowned self] _ in
            guard let gh = ghExecutable, let openLoginTerminal else {
                throw ActionError.failed(.dialogCloneRepoLogIn, message: "Install the GitHub CLI first: brew install gh")
            }
            guard canOpenLoginTerminal() else { throw ActionError.failed(.dialogCloneRepoLogIn, message: "Select a session first.") }
            loadTask?.cancel()
            model = nil
            overlays.dismiss(.action)
            Task { await catalog.invalidate() }
            guard openLoginTerminal([gh.path, "auth", "login"]) else {
                throw ActionError.failed(.dialogCloneRepoLogIn, message: "Couldn't open a terminal.")
            }
            toasts.show(kind: .info, title: String(localized: "Finish logging in to GitHub in the new tab, then try again.", bundle: .module))
            return "login"
        }
    }
}
