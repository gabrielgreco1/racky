import RackyCore
import RackyProtocol
import RackyStore
import Foundation
import Testing

@testable import RackyUI

/// Seletor falso: devolve a pasta combinada (ou nil = usuário cancelou).
@MainActor
final class FakePicker: FolderPicking {
    var next: URL?
    private(set) var calls = 0
    func chooseFolder() async -> URL? {
        calls += 1
        return next
    }
}

/// Fluxo de projetos ligado ao Store real e a repositórios temporários (nunca toca em repositórios do usuário).
@MainActor
@Suite(.tags(.integration), .serialized, .offscreenAppKit) struct ProjectsControllerTests {
    struct Rig {
        let env: AppEnvironment
        let store: RackyStore
        let picker: FakePicker
        let root: URL
    }

    static func git(_ args: [String], in dir: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        for (k, v) in ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_AUTHOR_NAME": "T", "GIT_AUTHOR_EMAIL": "t@e.x",
                       "GIT_COMMITTER_NAME": "T", "GIT_COMMITTER_EMAIL": "t@e.x"] { env[k] = v }
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw CocoaError(.fileReadUnknown) }
    }

    func makeRig(automation: Bool = false) async throws -> Rig {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("racky-projects-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("home"), withIntermediateDirectories: true)
        // `realpath`, como o git informa (/var vira /private/var); `resolvingSymlinksInPath` desfaz isso.
        let resolved = try #require(realpath(base.path, nil))
        defer { free(resolved) }
        let root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        let store = try await RackyStore.open(paths: StorePaths(root: root.appendingPathComponent("home")), debounce: .milliseconds(10))
        let env = AppEnvironment(environment: automation ? ["RACKY_AUTOMATION": "1"] : [:])
        let picker = FakePicker()
        env.projects.picker = picker
        await env.sidebar.attach(store: store)
        env.projects.attach(store: store)
        return Rig(env: env, store: store, picker: picker, root: root)
    }

    func makeRepo(_ rig: Rig, name: String = "demo-repo") throws -> URL {
        let repo = rig.root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try Self.git(["init", "-q", "-b", "main"], in: repo)
        try "hi\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try Self.git(["add", "."], in: repo)
        try Self.git(["commit", "-q", "-m", "init"], in: repo)
        return repo
    }

    func wait(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<250 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
        #expect(condition(), "\(what)")
    }

    func projectID(_ result: ActionResult) throws -> UUID {
        try #require(result.message.flatMap(UUID.init(uuidString:)))
    }

    @Test func projectActionsAreOfferedOnceRegistered() async throws {
        let rig = try await makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        for id in [ActionID.projectAdd, .projectRename, .projectRemove, .itemRefreshGit, .dialogRemoveProjectConfirm, .dialogRemoveProjectCancel] {
            #expect(rig.env.registry.isOffered(id), "\(id.rawValue)")
        }
    }

    @Test func addProjectThroughThePickerShowsProjectAndUnstartedSessions() async throws {
        let rig = try await makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let repo = try makeRepo(rig)
        try Self.git(["worktree", "add", "-q", "-b", "feat", rig.root.appendingPathComponent("wt-feat").path], in: repo)
        rig.picker.next = repo

        let id = try projectID(try await rig.env.registry.perform(.projectAdd, .press))
        try await wait("project in sidebar") { rig.env.sidebar.project(id) != nil && rig.env.sidebar.snapshot.sessions.count == 2 }
        #expect(rig.env.sidebar.project(id)?.name == "demo-repo")
        let section = try #require(rig.env.sidebar.projection.projects.first { $0.id == id })
        #expect(section.sessions.count == 2)
        #expect(rig.env.toasts.items.contains { $0.title == "Added demo-repo." })

        // Segunda vez: avisa e não duplica.
        _ = try await rig.env.registry.perform(.projectAdd, .press)
        #expect(try await rig.store.projects().count == 1)
        #expect(rig.env.toasts.items.contains { $0.title.contains("already") })
    }

    @Test func cancelingThePickerDoesNothing() async throws {
        let rig = try await makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        rig.picker.next = nil
        let result = try await rig.env.registry.perform(.projectAdd, .press)
        #expect(result.message == "cancelled" && rig.picker.calls == 1)
        #expect(try await rig.store.projects().isEmpty)
    }

    @Test func folderPathArgumentIsAutomationOnly() async throws {
        let off = try await makeRig(automation: false)
        defer { try? FileManager.default.removeItem(at: off.root) }
        let repo = try makeRepo(off)
        await #expect(throws: (any Error).self) { _ = try await off.env.registry.perform(.projectAdd, .set(repo.path)) }
        #expect(try await off.store.projects().isEmpty && off.picker.calls == 0)

        let on = try await makeRig(automation: true)
        defer { try? FileManager.default.removeItem(at: on.root) }
        let repo2 = try makeRepo(on)
        let result = try await on.env.registry.perform(.projectAdd, .set(repo2.path))
        #expect(UUID(uuidString: result.message ?? "") != nil)
        #expect(on.picker.calls == 0, "o caminho de automação não abre o seletor")
        #expect(try await on.store.projects().count == 1)
    }

    @Test func nonRepoFolderAndInvalidPathReportErrors() async throws {
        let rig = try await makeRig(automation: true)
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let plain = rig.root.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        _ = try await rig.env.registry.perform(.projectAdd, .set(plain.path))
        #expect(try await rig.store.projects().first?.kind == .folder)
        await #expect(throws: (any Error).self) { _ = try await rig.env.registry.perform(.projectAdd, .set(rig.root.path + "/missing")) }
        #expect(rig.env.toasts.items.contains { $0.title == "Couldn't add the project." })
    }

    @Test func removeProjectAsksThenArchivesWithoutDeletingFiles() async throws {
        let rig = try await makeRig(automation: true)
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let repo = try makeRepo(rig)
        let id = try projectID(try await rig.env.registry.perform(.projectAdd, .set(repo.path)))
        try await wait("project listed") { rig.env.sidebar.projection.projects.contains { $0.id == id } }

        _ = try await rig.env.registry.perform(.projectRemove, .select(id.uuidString))
        #expect(rig.env.overlays.top?.spec.name == "confirmRemoveProject")
        // Cancelar: nada muda.
        _ = try await rig.env.registry.perform(.dialogRemoveProjectCancel, .press)
        #expect(rig.env.projects.pendingRemoval == nil)
        #expect(try await rig.store.projects().count == 1)
        // Confirmar.
        _ = try await rig.env.registry.perform(.projectRemove, .select(id.uuidString))
        _ = try await rig.env.registry.perform(.dialogRemoveProjectConfirm, .press)
        try await wait("project gone from sidebar") { !rig.env.sidebar.projection.projects.contains { $0.id == id } }
        #expect(try await rig.store.projects().isEmpty)
        #expect(FileManager.default.fileExists(atPath: repo.appendingPathComponent("README.md").path))
        await #expect(throws: (any Error).self) { _ = try await rig.env.registry.perform(.dialogRemoveProjectConfirm, .press) }
    }

    @Test func renameProjectInlineFlowPersists() async throws {
        let rig = try await makeRig(automation: true)
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let repo = try makeRepo(rig)
        let id = try projectID(try await rig.env.registry.perform(.projectAdd, .set(repo.path)))
        try await wait("project listed") { rig.env.sidebar.project(id) != nil }

        #expect(try await rig.env.registry.perform(.projectRename, .select(id.uuidString)).message == "renaming")
        #expect(rig.env.sidebar.renamingProject == id)
        _ = try await rig.env.registry.perform(.projectRename, .set("Pretty Name"))
        #expect(rig.env.sidebar.renamingProject == nil)
        // Um snapshot do store ainda em trânsito (o do projectAdd) pode chegar depois; o nome converge para o novo.
        try await wait("renamed in the sidebar") { rig.env.sidebar.project(id)?.name == "Pretty Name" }
        for _ in 0..<100 {
            if try await rig.store.project(id: id)?.name == "Pretty Name" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try await rig.store.project(id: id)?.name == "Pretty Name")
        #expect(FileManager.default.fileExists(atPath: repo.path))

        _ = try await rig.env.registry.perform(.projectRename, .select(id.uuidString))
        rig.env.sidebar.cancelRenameProject()
        #expect(rig.env.sidebar.renamingProject == nil)
    }

    @Test func gitRefreshInBackgroundFeedsStatusAndBranch() async throws {
        let rig = try await makeRig(automation: true)
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let repo = try makeRepo(rig)
        let id = try projectID(try await rig.env.registry.perform(.projectAdd, .set(repo.path)))
        try await wait("status of main") { rig.env.sidebar.gitStatus[repo.path]?.branch == "main" }

        try Self.git(["checkout", "-q", "-b", "elsewhere"], in: repo)
        try "dirty".write(to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        let count = try await rig.env.registry.perform(.itemRefreshGit, .select(id.uuidString))
        #expect(count.message == "1")
        try await wait("branch and dirty seen") {
            let s = rig.env.sidebar.gitStatus[repo.path]
            return s?.branch == "elsewhere" && s?.untrackedFiles == 1
        }
        try await wait("branch persisted") { rig.env.sidebar.snapshot.worktrees.first?.branch == "elsewhere" }
    }
}
