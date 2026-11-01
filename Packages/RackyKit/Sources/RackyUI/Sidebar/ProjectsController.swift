import RackyCore
import RackyPlatform
import RackyProtocol
import RackyStore
import AppKit
import Foundation

/// Escolhe uma pasta. Produção: `NSOpenPanel` nativo; testes e automação trocam por um fake.
@MainActor
protocol FolderPicking {
    func chooseFolder() async -> URL?
}

/// Seletor nativo (03 §16.9: "Choose a Folder…"). Aceita repositório Git ou qualquer pasta.
@MainActor
struct OpenPanelFolderPicker: FolderPicking {
    func chooseFolder() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.title = String(localized: "Add a Project", bundle: .module)
        panel.message = String(localized: "A Git repository or any folder on this Mac.", bundle: .module)
        panel.prompt = String(localized: "Add", bundle: .module)
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

/// Fluxo de projetos da sidebar (T1-19): adicionar (seletor nativo), renomear, remover com confirmação em overlay,
/// sincronizar worktrees e atualizar status Git em segundo plano. Os handlers vão para o `ActionRegistry`: menus, botões
/// e `ctl ui action` disparam o mesmo código. Nada aqui bloqueia a main thread: o trabalho de Git e de Store roda nos
/// serviços do Core (`await` sai da main).
@MainActor
final class ProjectsController {
    private let sidebar: SidebarModel
    private let overlays: OverlayRouter
    private let toasts: ToastCenter
    var picker: any FolderPicking
    private let automationEnabled: Bool
    private let git: GitService
    private let log = LogFacade(.app, category: "projects")

    private var service: ProjectService?
    private var refresher: GitStatusRefresher?
    private var watcher: GitChangeWatcher?
    private var watchedKey: [String] = []
    private var knownWorktrees: Set<String> = []
    private var sweep: Task<Void, Never>?
    private var observation: Task<Void, Never>?
    /// Projeto à espera da confirmação de remoção.
    private(set) var pendingRemoval: UUID?

    init(sidebar: SidebarModel, overlays: OverlayRouter, toasts: ToastCenter, picker: any FolderPicking = OpenPanelFolderPicker(),
         automationEnabled: Bool, git: GitService = GitService()) {
        self.sidebar = sidebar
        self.overlays = overlays
        self.toasts = toasts
        self.picker = picker
        self.automationEnabled = automationEnabled
        self.git = git
    }

    // MARK: Ciclo de vida

    /// Liga ao Store: sincroniza os worktrees de todos os projetos, pede status de cada um e passa a observar mudanças
    /// (FSEvents + varredura a cada 60 s para o que está fora da tela).
    func attach(store: RackyStore) {
        let service = ProjectService(store: store, git: git)
        self.service = service
        let sidebar = self.sidebar
        let refresher = GitStatusRefresher(git: git) { [weak sidebar] path, status in
            // Atualiza o branch gravado primeiro; a UI recebe o status depois, na main.
            _ = try? await service.applyBranch(status, toWorktreeAt: path)
            await MainActor.run { sidebar?.setGitStatus(status, at: path) }
        }
        self.refresher = refresher
        Task { [weak self] in
            _ = await service.syncAll()
            await self?.refreshWatching(requestAll: true)
        }
        // O conjunto de worktrees muda com o snapshot (adição, remoção, sync): reajusta o que o FSEvents observa.
        observation = Task { [weak self] in
            do {
                for try await _ in store.snapshots() { await self?.refreshWatching(requestAll: false) }
            } catch {
                self?.log.error("project observation ended: \(error)")
            }
        }
        sweep = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.refreshWatching(requestAll: true)
            }
        }
    }

    func detach() {
        sweep?.cancel()
        observation?.cancel()
        watcher?.stop()
        watcher = nil
        if let refresher { Task { await refresher.stop() } }
    }

    /// Alvos de refresh: worktrees dos projetos visíveis.
    private func targets() -> [GitEventRouter.Target] {
        let snap = sidebar.snapshot
        let projects = snap.projects.filter { $0.archivedAt == nil && $0.kind == .git }
        return projects.flatMap { p in
            snap.worktrees.filter { $0.projectID == p.id && $0.archivedAt == nil }
                .map { GitEventRouter.Target(worktreePath: $0.path, mainRoot: p.rootPath) }
        }
    }

    private func refreshWatching(requestAll: Bool) async {
        let targets = targets()
        // Worktree que acabou de aparecer (projeto adicionado, sync) ganha status sem esperar o próximo gatilho.
        let current = Set(targets.map(\.worktreePath))
        let fresh = requestAll ? current : current.subtracting(knownWorktrees)
        knownWorktrees = current
        if let refresher { for path in fresh.sorted() { await refresher.request(path) } }
        let paths = Array(Set(targets.flatMap { [$0.worktreePath, $0.mainRoot + "/.git"] })).sorted()
        guard paths != watchedKey else { return }
        watchedKey = paths
        watcher?.stop()
        guard let refresher else { return }
        let router = targets
        let w = GitChangeWatcher(paths: paths) { events in
            let touched = GitEventRouter.worktrees(for: events, targets: router)
            guard !touched.isEmpty else { return }
            Task { for path in touched { await refresher.request(path) } }
        }
        w.start()
        watcher = w
    }

    /// `Refresh Git` (⌥ no menu): refaz o status do projeto (todos os worktrees) ou da sessão, sem esperar o debounce.
    func refreshGit(itemID: UUID) async -> Int {
        let snap = sidebar.snapshot
        var paths: [String] = []
        if snap.projects.contains(where: { $0.id == itemID }) {
            paths = snap.worktrees.filter { $0.projectID == itemID && $0.archivedAt == nil }.map(\.path)
            if let service { _ = try? await service.syncWorktrees(projectID: itemID) }
        } else if let s = snap.sessions.first(where: { $0.id == itemID }), s.worktreeID != nil {
            paths = [s.folderPath]
        }
        for p in paths { await refresher?.request(p, immediate: true) }
        return paths.count
    }

    // MARK: Adicionar

    /// Adiciona a pasta como projeto; avisa por toast se já existia ou se falhou. Devolve o projeto.
    @discardableResult
    func addProject(folder: URL, announce: Bool = true) async throws -> Project {
        guard let service else { throw ActionError.failed(.projectAdd, message: "Store not ready") }
        do {
            let result = try await service.addProject(folder: folder)
            if sidebar.collapsedProjects.contains(result.project.id) { sidebar.setProject(result.project.id, collapsed: false) }
            switch result.outcome {
            case _ where !announce: break
            case .added, .restored:
                toasts.show(kind: .success, title: String(localized: "Added \(result.project.name).", bundle: .module))
            case .alreadyAdded:
                toasts.show(kind: .info, title: String(localized: "\(result.project.name) is already in your projects.", bundle: .module))
            }
            await refreshWatching(requestAll: true)
            return result.project
        } catch {
            toasts.show(kind: .error, title: String(localized: "Couldn't add the project.", bundle: .module), detail: Self.describe(error))
            throw ActionError.failed(.projectAdd, message: Self.describe(error))
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case ProjectError.notADirectory:
            String(localized: "That isn't a folder.", bundle: .module)
        case ProjectError.git(.gitNotInstalled):
            String(localized: "Git isn't installed.", bundle: .module)
        case ProjectError.git(.timedOut):
            String(localized: "Git took too long to answer.", bundle: .module)
        case ProjectError.git(let g):
            String(describing: g)
        default:
            String(localized: "Something went wrong.", bundle: .module)
        }
    }

    // MARK: Registro de ações

    func registerActions(in registry: ActionRegistry) throws {
        try registry.register(.projectAdd) { [unowned self] arg in
            // Caminho de automação: `ctl ui action project.add --set <pasta>` pula o NSOpenPanel. Só com RACKY_AUTOMATION=1.
            if arg.kind == .set {
                guard automationEnabled, let path = arg.value, !path.isEmpty else {
                    throw ActionError.failed(.projectAdd, message: "Automation is off")
                }
                return try await addProject(folder: URL(fileURLWithPath: path, isDirectory: true)).id.uuidString
            }
            guard let url = await picker.chooseFolder() else { return "cancelled" }
            return try await addProject(folder: url).id.uuidString
        }

        try registry.register(.projectRename) { [unowned self] arg in
            switch arg.kind {
            case .set:
                guard let done = sidebar.finishRenameProject(arg.value ?? "") else { return nil }
                try await requireService(.projectRename).renameProject(id: done.id, to: done.name)
                return done.name
            default:
                guard arg.kind == .select, let raw = arg.value, let id = UUID(uuidString: raw), sidebar.beginRenameProject(id) else {
                    throw ActionError.failed(.projectRename, message: "Project not found")
                }
                return "renaming"
            }
        }

        try registry.register(.projectRemove) { [unowned self] arg in
            guard arg.kind == .select, let raw = arg.value, let id = UUID(uuidString: raw), let project = sidebar.project(id),
                  project.archivedAt == nil
            else { throw ActionError.failed(.projectRemove, message: "Project not found") }
            let count = sidebar.snapshot.sessions.filter { $0.projectID == id && $0.archivedAt == nil }.count
            pendingRemoval = id
            let opened = overlays.present(
                .confirmation(.removeProject(name: project.name, sessionCount: count)), from: .sidebarProject(raw))
            if !opened { pendingRemoval = nil }
            return opened ? "confirming" : "busy"
        }
        try registry.register(.dialogRemoveProjectCancel) { [unowned self] _ in
            pendingRemoval = nil
            overlays.dismiss(.action)
            return nil
        }
        try registry.register(.dialogRemoveProjectConfirm) { [unowned self] _ in
            guard let id = pendingRemoval else { throw ActionError.failed(.dialogRemoveProjectConfirm, message: "Nothing to remove") }
            pendingRemoval = nil
            overlays.dismiss(.action)
            do {
                let archived = try await requireService(.dialogRemoveProjectConfirm).removeProject(id: id)
                return "removed, \(archived) sessions archived"
            } catch {
                toasts.show(kind: .error, title: String(localized: "Couldn't remove the project.", bundle: .module), detail: Self.describe(error))
                throw error
            }
        }

        try registry.register(.itemRefreshGit) { [unowned self] arg in
            guard arg.kind == .select, let raw = arg.value, let id = UUID(uuidString: raw) else {
                throw ActionError.failed(.itemRefreshGit, message: "expected select(<id>)")
            }
            return "\(await refreshGit(itemID: id))"
        }
    }

    private func requireService(_ id: ActionID) throws -> ProjectService {
        guard let service else { throw ActionError.failed(id, message: "Store not ready") }
        return service
    }
}
