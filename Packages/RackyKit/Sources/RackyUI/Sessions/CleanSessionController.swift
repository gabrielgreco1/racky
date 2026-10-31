import RackyCore
import RackyDesignSystem
import RackyPlatform
import RackyProtocol
import RackyStore
import AppKit
import Foundation

/// Seletor de pasta de "New Clean Session in Folder…" (03 §2.10). Usa o mesmo seletor do composer (um só `NSOpenPanel`,
/// e um só ponto que testes e automação trocam por um fake). O app não cria nem apaga nada na pasta.
@MainActor
struct CleanFolderPicker: FolderPicking {
    let base: @MainActor () -> any SessionFolderPicking

    func chooseFolder() async -> URL? {
        await base().chooseFolder(
            title: String(localized: "New Clean Session in Folder", bundle: .module),
            message: String(localized: "Pick the folder the session works in. Racky won't create or delete anything in it.", bundle: .module),
            prompt: String(localized: "Start Session", bundle: .module))
    }
}

/// Sessões limpas (P10, P11): criar em um clique, criar numa pasta escolhida, arquivar, apagar e promover a projeto.
/// Os handlers vão para o `ActionRegistry`: sidebar, menu File, landing, atalhos e `ctl ui action` disparam o mesmo código.
@MainActor
final class CleanSessionController {
    private let launcher: SessionLauncher
    private let sidebar: SidebarModel
    private let workspace: WorkspaceModel
    private let overlays: OverlayRouter
    private let toasts: ToastCenter
    private let elements: UIElementStore
    private let settings: SettingsModel
    private let projects: ProjectsController
    private let sessionsRoot: () -> URL
    private let runsRoot: () -> URL
    private let automationEnabled: Bool
    var picker: any FolderPicking = CleanFolderPicker(base: { OpenPanelSessionFolderPicker() })
    /// Move para o Lixo do macOS (recuperável); os testes trocam por um destino temporário.
    var trashItem: (URL) throws -> Void = CleanSessionFolders.systemTrash
    /// Checagem prévia e remoção de worktree (06 §5.2); os testes trocam pelo serviço de um sandbox.
    var removal = SessionRemovalService()
    private var store: RackyStore?
    private var pendingArchive: UUID?
    /// Toast de Undo vivo por sessão (arquivar e apagar), para fechar o toast quando o Undo é usado.
    private var undoToasts: [UUID: UUID] = [:]
    /// Registros apagados nos últimos segundos, para o Undo do toast `Session deleted.` (restaura só o registro).
    private var deletedSessions: [UUID: Session] = [:]
    private(set) var pendingDelete: DeleteSessionState?
    private(set) var pendingMove: MoveToProjectState?
    private weak var registry: ActionRegistry?
    private let log = LogFacade(.app, category: "clean-sessions")

    init(
        launcher: SessionLauncher, sidebar: SidebarModel, workspace: WorkspaceModel, overlays: OverlayRouter, toasts: ToastCenter,
        elements: UIElementStore, settings: SettingsModel, projects: ProjectsController, sessionsRoot: @escaping () -> URL,
        runsRoot: @escaping () -> URL, automationEnabled: Bool
    ) {
        self.launcher = launcher
        self.sidebar = sidebar
        self.workspace = workspace
        self.overlays = overlays
        self.toasts = toasts
        self.elements = elements
        self.settings = settings
        self.projects = projects
        self.sessionsRoot = sessionsRoot
        self.runsRoot = runsRoot
        self.automationEnabled = automationEnabled
    }

    func attach(store: RackyStore) { self.store = store }

    // MARK: Criar

    /// Agente padrão pronto para uso? `nil` = pode usar; senão o motivo (03 §24.2).
    private func defaultAgentBlockReason() -> String? {
        let agent = settings.settings.agents.defaultAgent
        guard settings.agent(agent)?.installedState == false else { return nil }
        return String(localized: "Install \(AgentInfo.displayName(agent)) or choose another default agent.", bundle: .module)
    }

    /// ⇧⌘N e o `+` de "Sessions": pasta nova gerenciada + agente padrão, sem diálogo (AC-1101). `set(<json>)` troca o agente, o modelo,
    /// os argumentos ou o prompt (automação e testes; é o mesmo pedido de `session.launch`).
    func newCleanSession(_ arg: ActionArgument) async throws -> String? {
        var request = SessionLaunchRequest()
        if arg.kind == .set, let raw = arg.value, let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(SessionLaunchRequest.self, from: data) {
            request = decoded
            request.cwd = nil
        }
        return try await start(request, action: .sessionNewClean)
    }

    /// ⌥⇧⌘N: `NSOpenPanel` e sessão na pasta escolhida (AC-1105). `set(<pasta ou json>)` pula o painel (só com a automação ligada).
    func newCleanSessionInFolder(_ arg: ActionArgument) async throws -> String? {
        var request = SessionLaunchRequest()
        if arg.kind == .set {
            guard automationEnabled, let raw = arg.value, !raw.isEmpty else {
                throw ActionError.failed(.sessionNewCleanInFolder, message: "Automation is off")
            }
            if let data = raw.data(using: .utf8), let decoded = try? JSONDecoder().decode(SessionLaunchRequest.self, from: data) {
                request = decoded
            } else {
                request.cwd = raw
            }
            guard request.cwd?.isEmpty == false else { throw ActionError.failed(.sessionNewCleanInFolder, message: "expected a folder") }
        } else {
            guard let url = await picker.chooseFolder() else { return "cancelled" }
            request.cwd = url.path
        }
        return try await start(request, action: .sessionNewCleanInFolder)
    }

    private func start(_ original: SessionLaunchRequest, action: ActionID) async throws -> String? {
        var request = original
        if request.provider == nil {
            if let reason = defaultAgentBlockReason() { throw ActionError.failed(action, message: reason) }
            request.provider = settings.settings.agents.defaultAgent.rawValue
        }
        if request.origin == nil, let frame = elements.frame(of: .sidebarCleanSessionsNew), frame.width > 0 {
            request.origin = [Double(frame.midX), Double(frame.midY)]
        }
        return try await launcher.launch(request)
    }

    // MARK: Arquivar

    private func target(_ arg: ActionArgument, _ id: ActionID) throws -> Session {
        let raw = arg.kind == .select ? arg.value : sidebar.selectedSession?.uuidString
        guard let raw, let uuid = UUID(uuidString: raw), let session = sidebar.session(uuid) else {
            throw ActionError.failed(id, message: "Session not found")
        }
        return session
    }

    func archive(_ session: Session) async throws {
        guard let store else { throw ActionError.failed(.dialogArchiveConfirm, message: "Store not ready") }
        sidebar.leave(session: session.id)
        await workspace.stopTerminals(ofSession: session.id)
        var archived = session
        archived.lifecycle = .archived
        archived.archivedAt = Date()
        try await store.save(archived)
        if settings.settings.general.archivedWorktrees == .delete, session.kind == .worktree,
           let worktree = sidebar.worktree(of: session), let project = sidebar.project(session.projectID ?? UUID()) {
            let removal = removal
            Task {
                _ = await removal.removeIfClean(
                    repositoryURL: URL(fileURLWithPath: project.rootPath, isDirectory: true), worktreePath: URL(fileURLWithPath: worktree.path, isDirectory: true))
            }
        }
        undoToasts[session.id] = toasts.show(
            kind: .success, title: String(localized: "Session archived.", bundle: .module),
            action: ToastAction(.sessionUndoArchive, title: String(localized: "Undo", bundle: .module), argument: .select(session.id.uuidString)),
            undo: true)
    }

    /// Desarquiva (menu `Restore Session`, Undo do toast): volta a `active`; os terminais ficam parados (03 §24.2).
    @discardableResult
    func restore(_ id: UUID, select: Bool) async throws -> Session {
        guard let store, var session = try await store.session(id: id), session.lifecycle == .archived || session.archivedAt != nil else {
            throw ActionError.failed(.sessionRestore, message: "Session not found")
        }
        // Storage › Worktrees of archived sessions: o checkout pode ter saído ao arquivar; volta antes da sessão reabrir.
        if session.kind == .worktree, let worktree = sidebar.worktree(of: session), let project = sidebar.project(session.projectID ?? UUID()) {
            do {
                try await removal.restoreIfMissing(
                    repositoryURL: URL(fileURLWithPath: project.rootPath, isDirectory: true),
                    worktreePath: URL(fileURLWithPath: worktree.path, isDirectory: true), branch: worktree.branch)
            } catch {
                log.error("could not restore worktree: \(error)")
                toasts.show(kind: .error, title: String(localized: "Couldn't bring the worktree back.", bundle: .module), detail: error.localizedDescription)
                throw ActionError.failed(.sessionRestore, message: error.localizedDescription)
            }
        }
        session.lifecycle = .active
        session.archivedAt = nil
        try await store.save(session)
        if let toast = undoToasts.removeValue(forKey: id) { toasts.dismiss(toast) }
        if select { _ = sidebar.select(id) }
        return session
    }

    /// Settings › Storage › Clean up now: tira do disco o checkout das sessões arquivadas que nada perdem (a branch fica para o Restore).
    func removeArchivedWorktrees() async -> Int64 {
        guard let store, let sessions = try? await store.sessions(includeArchived: true) else { return 0 }
        var freed: Int64 = 0
        for session in sessions where session.kind == .worktree && session.lifecycle == .archived {
            guard let worktree = sidebar.worktree(of: session), let project = sidebar.project(session.projectID ?? UUID()) else { continue }
            let path = URL(fileURLWithPath: worktree.path, isDirectory: true)
            // DETACHED: medir e apagar pastas grandes leva segundos de disco; fora do MainActor.
            let size = await Task.detached(priority: .utility) { StorageUsage.size(of: path) }.value
            if await removal.removeIfClean(repositoryURL: URL(fileURLWithPath: project.rootPath, isDirectory: true), worktreePath: path) {
                freed += size
            }
        }
        return freed
    }

    // MARK: Apagar

    /// Apaga a sessão: para os terminais, remove o registro e, só para pasta criada pelo app, move a pasta para o Lixo
    /// (recuperável) e, se pedido, apaga os run folders (AC-1108). Pasta escolhida nunca é tocada (AC-1105).
    func delete(_ state: DeleteSessionState) async throws {
        guard let store, let session = sidebar.session(state.sessionID) else { throw ActionError.failed(.dialogDeleteSessionConfirm, message: "Session not found") }
        var detail: String?
        if state.isWorktree {
            // Primeiro o disco: se o Git recusar, a sessão e o registro ficam como estavam.
            await workspace.stopTerminals(ofSession: session.id)
            detail = try await removeWorktree(of: session, state: state)
            sidebar.leave(session: session.id)
        } else {
            sidebar.leave(session: session.id)
            await workspace.stopTerminals(ofSession: session.id)
        }
        try await store.deleteSession(id: session.id)
        if state.isWorktree, let worktreeID = session.worktreeID { try await store.deleteWorktree(id: worktreeID) }
        var trashedFolder = false
        if state.managedFolder, state.trashFolder {
            do {
                try CleanSessionFolders.trash(folder: session.folderPath, managed: session.managedFolder, sessionsRoot: sessionsRoot(), mover: trashItem)
                trashedFolder = true
            } catch {
                log.error("could not trash session folder: \(error)")
                toasts.show(kind: .error, title: String(localized: "Couldn't move the folder to the Trash.", bundle: .module), detail: error.localizedDescription)
            }
        }
        if state.deleteRuns { _ = try? CleanSessionFolders.deleteRunFolders(forSession: session.id, runsRoot: runsRoot()) }
        if state.dontAsk, state.showsDontAsk, let registry { _ = try? await registry.perform(.settingsGeneralConfirmDeleteSession, .set("off")) }
        // Undo restaura só o registro: não é oferecido quando a pasta saiu do disco (worktree) ou foi para o Lixo.
        if state.isWorktree || trashedFolder {
            toasts.show(kind: .success, title: String(localized: "Session deleted.", bundle: .module), detail: detail)
        } else {
            deletedSessions[session.id] = session
            undoToasts[session.id] = toasts.show(
                kind: .success, title: String(localized: "Session deleted.", bundle: .module),
                action: ToastAction(.sessionUndoDelete, title: String(localized: "Undo", bundle: .module), argument: .select(session.id.uuidString)),
                undo: true)
        }
    }

    /// Remove o worktree da sessão pelo `GitService`. Relê o estado antes: se surgiu trabalho novo desde que o diálogo listou o que se
    /// perde, não apaga (a confirmação não cobre o que o usuário não viu). `force` só vale para o que o diálogo mostrou.
    private func removeWorktree(of session: Session, state: DeleteSessionState) async throws -> String? {
        let action = ActionID.dialogDeleteSessionConfirm
        guard let worktree = sidebar.worktree(of: session), let project = sidebar.project(session.projectID ?? UUID()), let shown = state.preview else {
            throw ActionError.failed(action, message: "Worktree not found")
        }
        let repository = URL(fileURLWithPath: project.rootPath, isDirectory: true)
        let path = URL(fileURLWithPath: worktree.path, isDirectory: true)
        do {
            let fresh = try await removal.preview(repositoryURL: repository, worktreePath: path)
            if fresh.uncommittedFiles > shown.uncommittedFiles || fresh.unpublished > shown.unpublished {
                toasts.show(kind: .error, title: String(localized: "The worktree changed.", bundle: .module),
                            detail: String(localized: "Review what will be lost and delete again.", bundle: .module))
                throw ActionError.failed(action, message: "The worktree changed")
            }
            let outcome = try await removal.remove(
                repositoryURL: repository, worktreePath: path, deleteBranch: !state.keepBranch && state.showsKeepBranch, force: shown.hasUncommittedChanges)
            if outcome.branchNotMerged, let branch = outcome.branch {
                return String(localized: "The branch \"\(branch)\" isn't merged, so it was kept.", bundle: .module)
            }
            return nil
        } catch let error as ActionError {
            throw error
        } catch {
            log.error("could not remove worktree: \(error)")
            toasts.show(kind: .error, title: String(localized: "Couldn't delete the worktree.", bundle: .module), detail: error.localizedDescription)
            throw ActionError.failed(action, message: error.localizedDescription)
        }
    }

    /// Lê o worktree antes do diálogo (06 §5.2). Worktree que o Git já não conhece e que não existe no disco só perde o registro.
    func deleteState(for session: Session) async throws -> DeleteSessionState {
        guard session.kind == .worktree else {
            return DeleteSessionState(sessionID: session.id, title: session.title, managedFolder: session.kind == .clean && session.managedFolder)
        }
        guard let worktree = sidebar.worktree(of: session), let project = sidebar.project(session.projectID ?? UUID()) else {
            throw ActionError.failed(.sessionDelete, message: "Worktree not found")
        }
        let path = URL(fileURLWithPath: worktree.path, isDirectory: true)
        let preview: SessionRemovalPreview
        do {
            preview = try await removal.preview(repositoryURL: URL(fileURLWithPath: project.rootPath, isDirectory: true), worktreePath: path)
        } catch {
            guard !SessionFolderProbe.isDirectory(path.path) else {
                log.error("could not inspect worktree: \(error)")
                toasts.show(kind: .error, title: String(localized: "Couldn't check the worktree.", bundle: .module), detail: error.localizedDescription)
                throw ActionError.failed(.sessionDelete, message: error.localizedDescription)
            }
            preview = SessionRemovalPreview(worktreePath: path.path, branch: nil, missingOnDisk: true)
        }
        return DeleteSessionState(
            sessionID: session.id, title: session.title, managedFolder: false, isWorktree: true,
            branch: preview.branch ?? worktree.branch, preview: preview)
    }

    func undoDelete(_ id: UUID) async throws {
        guard let store, let session = deletedSessions.removeValue(forKey: id) else { throw ActionError.failed(.sessionUndoDelete, message: "Session not found") }
        do {
            try await store.save(session)
        } catch {
            toasts.show(kind: .error, title: String(localized: "Couldn't restore the session.", bundle: .module), detail: error.localizedDescription)
            throw ActionError.failed(.sessionUndoDelete, message: error.localizedDescription)
        }
        if let toast = undoToasts.removeValue(forKey: id) { toasts.dismiss(toast) }
        _ = sidebar.select(id)
    }

    // MARK: Promover

    func move(_ state: MoveToProjectState) async throws {
        guard let store, let session = sidebar.session(state.sessionID) else { throw ActionError.failed(.dialogMoveToProjectConfirm, message: "Session not found") }
        let projectID: UUID
        let name: String
        if state.isConvert {
            // "New Project from This Folder": a pasta vira a raiz; tipo `git` se já é repositório, sem `git init`.
            let project = try await projects.addProject(folder: URL(fileURLWithPath: session.folderPath, isDirectory: true))
            projectID = project.id
            name = project.name
        } else if let id = state.projectID, let project = sidebar.project(id) {
            projectID = id
            name = project.name
        } else {
            throw ActionError.failed(.dialogMoveToProjectConfirm, message: "Choose a project.")
        }
        try await store.save(SessionPromotion.attach(session, to: projectID))
        toasts.show(kind: .success, title: String(localized: "Moved to \(name).", bundle: .module))
    }

    // MARK: Registro de ações

    func register(in registry: ActionRegistry) throws {
        self.registry = registry
        let blocked: ActionRegistry.Enablement = { [unowned self] in
            defaultAgentBlockReason().map { .disabled(reason: $0) } ?? .enabled
        }
        try registry.register(.sessionNewClean, enablement: blocked) { [unowned self] arg in try await newCleanSession(arg) }
        try registry.register(.sessionNewCleanInFolder, enablement: blocked) { [unowned self] arg in try await newCleanSessionInFolder(arg) }

        // Arquivar (03 §16.2)
        try registry.register(.sessionArchive) { [unowned self] arg in
            let session = try target(arg, .sessionArchive)
            pendingArchive = session.id
            let opened = overlays.present(.confirmation(.archiveSession(name: session.title)), from: .sidebarSession(session.id.uuidString))
            if !opened { pendingArchive = nil }
            return opened ? "confirming" : "busy"
        }
        try registry.register(.dialogArchiveCancel) { [unowned self] _ in
            pendingArchive = nil
            overlays.dismiss(.action)
            return nil
        }
        try registry.register(.dialogArchiveConfirm) { [unowned self] _ in
            guard let id = pendingArchive, let session = sidebar.session(id) else { throw ActionError.failed(.dialogArchiveConfirm, message: "Nothing to archive") }
            pendingArchive = nil
            overlays.dismiss(.action)
            try await archive(session)
            return "archived"
        }

        // Apagar (03 §16.5)
        func flag(_ arg: ActionArgument, current: Bool) -> Bool {
            switch arg.value {
            case "on": true
            case "off": false
            default: !current
            }
        }
        try registry.register(.sessionDelete) { [unowned self] arg in
            let session = try target(arg, .sessionDelete)
            let state = try await deleteState(for: session)
            // Sem perda de dados e com a confirmação desligada em Settings, apaga direto; com perda, o diálogo sempre aparece.
            if !settings.settings.general.confirmDeleteSession, !state.losesData {
                try await delete(state)
                return "deleted"
            }
            pendingDelete = state
            let opened = overlays.present(.deleteSession(state), from: .sidebarSession(session.id.uuidString))
            if !opened { pendingDelete = nil }
            return opened ? "confirming" : "busy"
        }
        try registry.register(.dialogDeleteSessionKeepBranch) { [unowned self] arg in
            guard let state = pendingDelete, state.showsKeepBranch else { return nil }
            state.keepBranch = flag(arg, current: state.keepBranch)
            return state.keepBranch ? "on" : "off"
        }
        try registry.register(.sessionRestore) { [unowned self] arg in
            let id = try target(arg, .sessionRestore).id
            try await restore(id, select: false)
            return "restored"
        }
        try registry.register(.sessionUndoArchive) { [unowned self] arg in
            guard arg.kind == .select, let raw = arg.value, let id = UUID(uuidString: raw) else {
                throw ActionError.failed(.sessionUndoArchive, message: "expected select(<sessionId>)")
            }
            try await restore(id, select: true)
            return "restored"
        }
        try registry.register(.sessionUndoDelete) { [unowned self] arg in
            guard arg.kind == .select, let raw = arg.value, let id = UUID(uuidString: raw) else {
                throw ActionError.failed(.sessionUndoDelete, message: "expected select(<sessionId>)")
            }
            try await undoDelete(id)
            return "restored"
        }
        try registry.register(.dialogDeleteSessionTrashFolder) { [unowned self] arg in
            guard let state = pendingDelete else { return nil }
            state.trashFolder = flag(arg, current: state.trashFolder)
            return state.trashFolder ? "on" : "off"
        }
        try registry.register(.dialogDeleteSessionDeleteRuns) { [unowned self] arg in
            guard let state = pendingDelete else { return nil }
            state.deleteRuns = flag(arg, current: state.deleteRuns)
            return state.deleteRuns ? "on" : "off"
        }
        try registry.register(.dialogDeleteSessionDontAsk) { [unowned self] arg in
            guard let state = pendingDelete else { return nil }
            state.dontAsk = flag(arg, current: state.dontAsk)
            return state.dontAsk ? "on" : "off"
        }
        try registry.register(.dialogDeleteSessionCancel) { [unowned self] _ in
            pendingDelete = nil
            overlays.dismiss(.action)
            return nil
        }
        try registry.register(.dialogDeleteSessionConfirm) { [unowned self] _ in
            guard let state = pendingDelete else { throw ActionError.failed(.dialogDeleteSessionConfirm, message: "Nothing to delete") }
            pendingDelete = nil
            overlays.dismiss(.action)
            try await delete(state)
            return "deleted"
        }

        // Promover (03 §16.8)
        func presentMove(_ arg: ActionArgument, convert: Bool, id: ActionID) throws -> String? {
            let session = try target(arg, id)
            guard session.kind == .clean else { throw ActionError.failed(id, message: "Only a clean session can be moved to a project") }
            let live = sidebar.snapshot.projects.filter { $0.archivedAt == nil }
            let state = MoveToProjectState(
                sessionID: session.id, title: session.title, projects: live, selection: convert ? MoveToProjectState.convertID : "")
            pendingMove = state
            let opened = overlays.present(.moveToProject(state), from: .sidebarSession(session.id.uuidString))
            if !opened { pendingMove = nil }
            return opened ? "opened" : "busy"
        }
        try registry.register(.sessionMoveToProject) { arg in try presentMove(arg, convert: false, id: .sessionMoveToProject) }
        try registry.register(.sessionConvertToProject) { arg in try presentMove(arg, convert: true, id: .sessionConvertToProject) }
        try registry.register(.dialogMoveToProjectSetProject) { [unowned self] arg in
            guard let state = pendingMove, arg.kind == .select, let value = arg.value else { return nil }
            guard value == MoveToProjectState.convertID || state.projects.contains(where: { $0.id.uuidString == value }) else {
                throw ActionError.failed(.dialogMoveToProjectSetProject, message: "Unknown project")
            }
            state.selection = value
            return value
        }
        try registry.register(.dialogMoveToProjectCancel) { [unowned self] _ in
            pendingMove = nil
            overlays.dismiss(.action)
            return nil
        }
        try registry.register(
            .dialogMoveToProjectConfirm,
            enablement: { [unowned self] in
                (pendingMove?.selection ?? "").isEmpty ? .disabled(reason: String(localized: "Choose a project.", bundle: .module)) : .enabled
            }
        ) { [unowned self] _ in
            guard let state = pendingMove else { throw ActionError.failed(.dialogMoveToProjectConfirm, message: "Nothing to move") }
            pendingMove = nil
            overlays.dismiss(.action)
            try await move(state)
            return "moved"
        }
    }
}
