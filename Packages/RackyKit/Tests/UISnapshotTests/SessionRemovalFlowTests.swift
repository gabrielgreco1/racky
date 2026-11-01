import RackyCore
import RackyDesignSystem
import RackyProtocol
import RackyStore
import Foundation
import Testing

@testable import RackyUI

/// Arquivar, restaurar, apagar sessão de worktree/pasta/checkout e "Open in…" (T1-27; AC-T09, AC-1105, AC-502, AC-306).
/// Repositórios e worktrees reais, mas só em diretórios temporários com HOME e config global isolados; nenhum editor é aberto.
@MainActor
@Suite(.serialized, .offscreenAppKit) struct SessionRemovalFlowTests {
    struct Rig {
        let env: AppEnvironment
        let store: RackyStore
        let root: URL
        let runner: GitProcessRunner
        let service: GitService
        var registry: ActionRegistry { env.registry }
    }

    struct Seeded {
        let project: Project
        let worktree: Worktree
        let session: Session
        var path: URL { URL(fileURLWithPath: worktree.path, isDirectory: true) }
        var repo: URL { URL(fileURLWithPath: project.rootPath, isDirectory: true) }
    }

    func make() async throws -> Rig {
        let root = URL(fileURLWithPath: "/tmp/abr-\(UInt32.random(in: 0 ... 0xFFFFFF))", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let env = AppEnvironment(environment: ["RACKY_HOME": root.path, "RACKY_AUTOMATION": "1", "RACKY_SKIP_ONBOARDING": "1"])
        await env.start()
        let store = try #require(env.workspace.store)
        let runner = GitProcessRunner(extraEnvironment: [
            "HOME": root.path, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Test User", "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test User", "GIT_COMMITTER_EMAIL": "test@example.com",
        ])
        let service = GitService(runner: runner)
        env.cleanSessions?.removal = SessionRemovalService(service: service)
        env.cleanSessions?.trashItem = { _ in }
        return Rig(env: env, store: store, root: root, runner: runner, service: service)
    }

    func cleanup(_ rig: Rig) async {
        await rig.env.workspace.settlePersistence()
        try? await rig.store.close()
        try? FileManager.default.removeItem(at: rig.root)
    }

    @discardableResult
    func git(_ rig: Rig, _ args: [String], in dir: URL) async throws -> String {
        let result = try await rig.runner.run(args, in: dir, kind: .write, timeout: .seconds(30))
        guard result.succeeded else { throw GitError.commandFailed(operation: args.joined(separator: " "), exitCode: result.exitCode, stderr: result.stderr) }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 250 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
    }

    /// Repositório com `origin` local, um worktree da app (`me/<slug>`) e a sessão de worktree no Store.
    func seed(_ rig: Rig, slug: String = "feature") async throws -> Seeded {
        let repo = rig.root.appendingPathComponent("repo", isDirectory: true)
        if !FileManager.default.fileExists(atPath: repo.path) {
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try await git(rig, ["init", "-q", "-b", "main"], in: repo)
            try "hello\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            try await git(rig, ["add", "."], in: repo)
            try await git(rig, ["commit", "-q", "-m", "init"], in: repo)
            let origin = rig.root.appendingPathComponent("origin.git", isDirectory: true)
            try await git(rig, ["init", "-q", "--bare", "-b", "main", origin.path], in: rig.root)
            try await git(rig, ["remote", "add", "origin", origin.path], in: repo)
            try await git(rig, ["push", "-q", "-u", "origin", "main"], in: repo)
            try await git(rig, ["remote", "set-head", "origin", "main"], in: repo)
        }
        let creation = try await rig.service.createWorktree(GitWorktreeRequest(
            repositoryURL: repo, source: .newBranch(slug: slug, prefix: .gitUsername("me"), baseRef: nil),
            worktreeRoot: rig.root.appendingPathComponent("workspaces")))
        let existing = try await rig.store.projects().first { $0.rootPath == repo.path }
        let project: Project
        if let existing { project = existing } else {
            project = Project(name: "repo", kind: .git, rootPath: repo.path, defaultBranch: "main")
            try await rig.store.save(project)
        }
        let worktree = Worktree(projectID: project.id, path: creation.path.path, branch: creation.branch, createdByApp: true)
        try await rig.store.save(worktree)
        let session = Session(kind: .worktree, projectID: project.id, worktreeID: worktree.id, folderPath: creation.path.path, title: slug)
        try await rig.store.save(session)
        try await waitFor { rig.env.sidebar.session(session.id) != nil && rig.env.sidebar.worktree(of: session) != nil }
        return Seeded(project: project, worktree: worktree, session: session)
    }

    func branchExists(_ rig: Rig, _ seeded: Seeded) async throws -> Bool {
        try await !git(rig, ["branch", "--list", seeded.worktree.branch], in: seeded.repo).isEmpty
    }

    // MARK: Apagar worktree

    @Test func dirtyWorktreeAsksListsWhatIsLostAndKeepsEverythingUntilConfirmed() async throws {
        let rig = try await make()
        defer { Task { await cleanup(rig) } }
        let s = try await seed(rig)
        try "dirty\n".write(to: s.path.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "u\n".write(to: s.path.appendingPathComponent("scratch.txt"), atomically: true, encoding: .utf8)
        try "w\n".write(to: s.path.appendingPathComponent("work.txt"), atomically: true, encoding: .utf8)
        try await git(rig, ["add", "work.txt"], in: s.path)
        try await git(rig, ["commit", "-q", "-m", "work"], in: s.path)
        try "u\n".write(to: s.path.appendingPathComponent("more.txt"), atomically: true, encoding: .utf8)

        #expect(try await rig.registry.perform(.sessionDelete, .select(s.session.id.uuidString)).message == "confirming")
        #expect(rig.env.overlays.top?.spec.name == "confirmDelete")
        let dialog = try #require(rig.env.cleanSessions?.pendingDelete)
        #expect(dialog.isWorktree && dialog.showsKeepBranch)
        #expect(dialog.preview?.lossSummary == "3 uncommitted files and 1 unpushed commit will be lost.")
        #expect(Set(dialog.preview?.samplePaths ?? []) == ["README.md", "scratch.txt", "more.txt"])
        #expect(dialog.losesData && !dialog.showsDontAsk, "com perda não há \"Don't ask again\"")
        #expect(dialog.message.contains("deletes the local branch \"\(s.worktree.branch)\""))

        // Cancelar não toca em nada.
        _ = try await rig.registry.perform(.dialogDeleteSessionCancel, .press)
        #expect(FileManager.default.fileExists(atPath: s.path.path))
        #expect(try await rig.store.session(id: s.session.id) != nil)
        #expect(try await branchExists(rig, s))
        #expect(try String(contentsOf: s.path.appendingPathComponent("README.md"), encoding: .utf8) == "dirty\n")

        // Confirmar é a confirmação explícita: remove o worktree; a branch tem commit não mesclado e fica.
        _ = try await rig.registry.perform(.sessionDelete, .select(s.session.id.uuidString))
        _ = try await rig.registry.perform(.dialogDeleteSessionConfirm, .press)
        #expect(!FileManager.default.fileExists(atPath: s.path.path))
        #expect(try await rig.store.session(id: s.session.id) == nil)
        #expect(try await rig.store.worktrees(projectID: s.project.id).isEmpty)
        #expect(try await branchExists(rig, s), "git branch -d recusa a branch não mesclada")
        #expect(rig.env.toasts.items.contains { $0.title == "Session deleted." && $0.detail?.contains("isn't merged") == true && $0.action == nil })
    }

    @Test func settingOffStillAsksWhenThereIsDataToLose() async throws {
        let rig = try await make()
        defer { Task { await cleanup(rig) } }
        _ = try await rig.registry.perform(.settingsGeneralConfirmDeleteSession, .set("off"))
        let s = try await seed(rig)
        try "u\n".write(to: s.path.appendingPathComponent("scratch.txt"), atomically: true, encoding: .utf8)
        #expect(try await rig.registry.perform(.sessionDelete, .select(s.session.id.uuidString)).message == "confirming")
        _ = try await rig.registry.perform(.dialogDeleteSessionCancel, .press)
        #expect(FileManager.default.fileExists(atPath: s.path.path))
        try FileManager.default.removeItem(at: s.path.appendingPathComponent("scratch.txt"))
        #expect(try await rig.registry.perform(.sessionDelete, .select(s.session.id.uuidString)).message == "deleted")
        #expect(!FileManager.default.fileExists(atPath: s.path.path))
    }

    @Test func workAddedAfterTheDialogOpenedIsNeverForceDeleted() async throws {
        let rig = try await make()
        defer { Task { await cleanup(rig) } }
        let s = try await seed(rig)
        try "u\n".write(to: s.path.appendingPathComponent("scratch.txt"), atomically: true, encoding: .utf8)
        _ = try await rig.registry.perform(.sessionDelete, .select(s.session.id.uuidString))
        try "late\n".write(to: s.path.appendingPathComponent("late.txt"), atomically: true, encoding: .utf8)
        await #expect(throws: (any Error).self) { try await rig.registry.perform(.dialogDeleteSessionConfirm, .press) }
        #expect(FileManager.default.fileExists(atPath: s.path.appendingPathComponent("late.txt").path))
        #expect(try await rig.store.session(id: s.session.id) != nil, "a sessão continua na sidebar")
        #expect(rig.env.toasts.items.contains { $0.title == "The worktree changed." })
    }

    @Test func cleanWorktreeIsRemovedAndTheBranchDeletedByDefault() async throws {
        let rig = try await make()
        defer { Task { await cleanup(rig) } }
        let s = try await seed(rig)
        #expect(try await rig.registry.perform(.sessionDelete, .select(s.session.id.uuidString)).message == "confirming")
        let dialog = try #require(rig.env.cleanSessions?.pendingDelete)
        #expect(!dialog.losesData && dialog.showsDontAsk && dialog.preview?.lossSummary == nil)
        #expect(dialog.message == "Stops its terminals and computers, removes the worktree folder and deletes the local branch \"\(s.worktree.branch)\".")
        _ = try await rig.registry.perform(.dialogDeleteSessionConfirm, .press)
        #expect(!FileManager.default.fileExists(atPath: s.path.path))
        #expect(try await rig.store.session(id: s.session.id) == nil)
        #expect(try await !branchExists(rig, s))
        #expect(try await rig.service.listWorktrees(in: s.repo).count == 1)
        #expect(rig.env.toasts.items.contains { $0.title == "Session deleted." && $0.action == nil }, "sem Undo: a pasta saiu do disco")
    }

    @Test func keepTheBranchRemovesOnlyTheWorktree() async throws {
        let rig = try await make()
        defer { Task { await cleanup(rig) } }
        let s = try await seed(rig)
        _ = try await rig.registry.perform(.sessionDelete, .select(s.session.id.uuidString))
        #expect(try await rig.registry.perform(.dialogDeleteSessionKeepBranch, .press).message == "on")
        #expect(rig.env.cleanSessions?.pendingDelete?.message.hasSuffix("The branch \"\(s.worktree.branch)\" stays.") == true)
        _ = try await rig.registry.perform(.dialogDeleteSessionConfirm, .press)
        #expect(!FileManager.default.fileExists(atPath: s.path.path))
        #expect(try await branchExists(rig, s))
    }

    // MARK: Pasta e checkout

    @Test func deletingAFolderSessionKeepsTheFolderAndUndoRestoresTheRecord() async throws {
        let rig = try await make()
        defer { Task { await cleanup(rig) } }
        let folder = rig.root.appendingPathComponent("existing", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = Project(name: "plain", kind: .folder, rootPath: folder.path)
        try await rig.store.save(project)
        let session = Session(kind: .folder, projectID: project.id, folderPath: folder.path, title: "notes")
        try await rig.store.save(session)
        try await waitFor { rig.env.sidebar.session(session.id) != nil }

        _ = try await rig.registry.perform(.sessionDelete, .select(session.id.uuidString))
        let dialog = try #require(rig.env.cleanSessions?.pendingDelete)
        #expect(!dialog.isWorktree && dialog.message == "Stops its terminals and computers. The folder stays on disk.")
        _ = try await rig.registry.perform(.dialogDeleteSessionConfirm, .press)
        #expect(try await rig.store.session(id: session.id) == nil)
        #expect(FileManager.default.fileExists(atPath: folder.path))
        let toast = try #require(rig.env.toasts.items.first { $0.title == "Session deleted." })
        #expect(toast.action?.action == .sessionUndoDelete)

        _ = try await rig.registry.perform(.sessionUndoDelete, .select(session.id.uuidString))
        #expect(try await rig.store.session(id: session.id)?.title == "notes")
        #expect(!rig.env.toasts.items.contains { $0.title == "Session deleted." })
    }

    // MARK: Arquivar e restaurar

    @Test func archivingAWorktreeSessionKeepsTheWorktreeAndBranchAndUndoBringsItBack() async throws {
        let rig = try await make()
        defer { Task { await cleanup(rig) } }
        let s = try await seed(rig)
        #expect(try await rig.registry.perform(.sessionArchive, .select(s.session.id.uuidString)).message == "confirming")
        #expect(rig.env.overlays.top?.spec.name == "confirmArchive")
        _ = try await rig.registry.perform(.dialogArchiveConfirm, .press)
        let archived = try #require(try await rig.store.session(id: s.session.id))
        #expect(archived.lifecycle == .archived && archived.archivedAt != nil)
        #expect(FileManager.default.fileExists(atPath: s.path.path))
        #expect(try await branchExists(rig, s))
        try await waitFor { rig.env.sidebar.projection.sessionOrder.contains(s.session.id) == false }
        #expect(!rig.env.sidebar.projection.sessionOrder.contains(s.session.id), "some da lista")

        let toast = try #require(rig.env.toasts.items.first { $0.title == "Session archived." })
        #expect(toast.action?.action == .sessionUndoArchive && toast.action?.argument == .select(s.session.id.uuidString))
        _ = try await rig.registry.perform(.sessionUndoArchive, .select(s.session.id.uuidString))
        let back = try #require(try await rig.store.session(id: s.session.id))
        #expect(back.lifecycle == .active && back.archivedAt == nil)
        #expect(!rig.env.toasts.items.contains { $0.title == "Session archived." }, "o Undo fecha o toast")
        try await waitFor { rig.env.sidebar.projection.sessionOrder.contains(s.session.id) }
        #expect(rig.env.sidebar.projection.sessionOrder.contains(s.session.id))
    }

    @Test func archivedSessionComesBackThroughShowArchivedAndRestore() async throws {
        let rig = try await make()
        defer { Task { await cleanup(rig) } }
        let s = try await seed(rig)
        _ = try await rig.registry.perform(.sessionArchive, .select(s.session.id.uuidString))
        _ = try await rig.registry.perform(.dialogArchiveConfirm, .press)
        try await waitFor { !rig.env.sidebar.projection.sessionOrder.contains(s.session.id) }

        _ = try await rig.registry.perform(.sidebarSortFilter, .set("archived=on"))
        try await waitFor { rig.env.sidebar.projection.sessionOrder.contains(s.session.id) }
        #expect(rig.env.sidebar.projection.sessionOrder.contains(s.session.id), "Show › Archived Sessions")

        _ = try await rig.registry.perform(.sessionRestore, .select(s.session.id.uuidString))
        let back = try #require(try await rig.store.session(id: s.session.id))
        #expect(back.lifecycle == .active && back.archivedAt == nil)
        _ = try await rig.registry.perform(.sidebarSortFilter, .set("archived=off"))
        try await waitFor { rig.env.sidebar.projection.sessionOrder.contains(s.session.id) }
        #expect(rig.env.sidebar.projection.sessionOrder.contains(s.session.id))
    }

    @Test func archiveStopsTheLiveTerminalsOfAProjectSession() async throws {
        let rig = try await make()
        defer { Task { await cleanup(rig) } }
        let created = try await rig.registry.perform(.sessionNewClean, .press)
        let data = try #require(created.message?.data(using: .utf8))
        let dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        let id = try #require(dict["sessionID"].flatMap(UUID.init(uuidString:)))
        _ = try await rig.registry.perform(.sessionArchive, .select(id.uuidString))
        _ = try await rig.registry.perform(.dialogArchiveConfirm, .press)
        #expect(try await rig.store.session(id: id)?.lifecycle == .archived)
        #expect(rig.env.sidebar.selectedSession == nil)
    }

    // MARK: Open in…

    nonisolated final class OpenRecorder: @unchecked Sendable { // SAFETY: testes seriais; o fechamento roda em uma Task por vez.
        nonisolated(unsafe) var opened: [(folder: String, app: String)] = []
        nonisolated(unsafe) var revealed: [String] = []
        nonisolated(unsafe) var failOpen = false
    }

    func install(_ rig: Rig, installed: Set<String>) -> OpenRecorder {
        let recorder = OpenRecorder()
        var system = OpenInSystem()
        system.applicationURL = { installed.contains($0) ? URL(fileURLWithPath: "/Applications/\($0).app") : nil }
        system.open = { folder, app in
            if recorder.failOpen { throw CocoaError(.fileNoSuchFile) }
            recorder.opened.append((folder.path, app.lastPathComponent))
        }
        system.reveal = { recorder.revealed.append($0.path) }
        rig.env.openIn?.system = system
        return recorder
    }

    @Test func openInListsOnlyInstalledAppsDetectedByBundleID() async throws {
        let rig = try await make()
        defer { Task { await cleanup(rig) } }
        let s = try await seed(rig)
        _ = install(rig, installed: ["com.apple.Terminal", "com.googlecode.iterm2", "com.microsoft.VSCode", "com.apple.dt.Xcode", "dev.zed.Zed"])
        let controller = try #require(rig.env.openIn)
        #expect(controller.installedEditors().map(\.name) == ["Visual Studio Code", "Zed", "Xcode"])
        #expect(controller.installedTerminals().map(\.name) == ["Terminal", "iTerm"])
        let ids = controller.entries(for: s.session.id).compactMap { entry -> String? in
            if case .item(let item) = entry { item.id } else { nil }
        }
        #expect(ids == ["finder", "terminal:com.apple.Terminal", "terminal:com.googlecode.iterm2", "editor:com.microsoft.VSCode", "editor:dev.zed.Zed", "editor:com.apple.dt.Xcode"])

        #expect(try await rig.registry.perform(.itemOpenIn, .select(s.session.id.uuidString)).message == "opened")
        #expect(rig.env.overlays.popover?.spec.name == "openIn")
    }

    @Test func openInOpensTheSessionFolderThroughTheWorkspaceAndRemembersTheEditor() async throws {
        let rig = try await make()
        defer { Task { await cleanup(rig) } }
        let s = try await seed(rig)
        let recorder = install(rig, installed: ["com.apple.Terminal", "com.microsoft.VSCode", "dev.zed.Zed"])
        let id = s.session.id.uuidString

        _ = try await rig.registry.perform(.itemOpenInTarget, .select("\(id)/editor:dev.zed.Zed"))
        _ = try await rig.registry.perform(.itemOpenInTarget, .select("\(id)/terminal:com.apple.Terminal"))
        _ = try await rig.registry.perform(.itemOpenInTarget, .select("\(id)/finder"))
        #expect(recorder.opened.map(\.folder) == [s.path.path, s.path.path])
        #expect(recorder.opened.map(\.app) == ["dev.zed.Zed.app", "com.apple.Terminal.app"])
        #expect(recorder.revealed == [s.path.path])

        // ⇧⌘O usa o último editor escolhido.
        _ = try await rig.registry.perform(.itemOpenInEditor, .select(id))
        #expect(recorder.opened.last?.app == "dev.zed.Zed.app")

        // Projeto: abre a raiz do projeto.
        _ = try await rig.registry.perform(.itemOpenInTarget, .select("\(s.project.id.uuidString)/editor:com.microsoft.VSCode"))
        #expect(recorder.opened.last?.folder == s.repo.path)
    }

    @Test func openInDefaultAppRevealsWhatTheSystemWouldExecute() async throws {
        let rig = try await make()
        defer { Task { await cleanup(rig) } }
        let recorder = install(rig, installed: [])
        rig.env.openIn?.system.openDefault = { recorder.opened.append(($0.path, "default")); return true }
        let controller = try #require(rig.env.openIn)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("openin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("run.command")
        let binary = dir.appendingPathComponent("tool")
        let text = dir.appendingPathComponent("notes.txt")
        for url in [script, binary, text] { try Data("x".utf8).write(to: url) }
        chmod(binary.path, 0o755)
        #expect(try await controller.openFile(script, target: "default") == "finder")
        #expect(try await controller.openFile(binary, target: "default") == "finder")
        #expect(try await controller.openFile(text, target: "default") == "default")
        #expect(recorder.revealed == [script.path, binary.path])
        #expect(recorder.opened.map(\.folder) == [text.path])
    }

    @Test func openInEditorIsDisabledWithoutAnEditorAndRefusesMissingApps() async throws {
        let rig = try await make()
        defer { Task { await cleanup(rig) } }
        let s = try await seed(rig)
        let recorder = install(rig, installed: ["com.apple.Terminal"])
        guard case .disabled(let reason) = rig.registry.availability(of: .itemOpenInEditor) else {
            Issue.record("deveria estar desabilitado")
            return
        }
        #expect(reason == "Choose an editor in Settings › General.")
        await #expect(throws: (any Error).self) {
            try await rig.registry.perform(.itemOpenInTarget, .select("\(s.session.id.uuidString)/editor:dev.zed.Zed"))
        }
        #expect(recorder.opened.isEmpty)

        // Pasta sumiu: `Folder not found`.
        try FileManager.default.removeItem(at: s.path)
        await #expect(throws: (any Error).self) {
            try await rig.registry.perform(.itemOpenInTarget, .select("\(s.session.id.uuidString)/terminal:com.apple.Terminal"))
        }
        #expect(recorder.opened.isEmpty)
    }
}
