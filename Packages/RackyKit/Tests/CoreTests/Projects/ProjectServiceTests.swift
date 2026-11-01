import RackyProtocol
import RackyStore
import Foundation
import Testing
@testable import RackyCore

/// Integração com repositórios temporários e um Store real em pasta temporária (nada do usuário é tocado).
struct ProjectHarness {
    let sandbox: GitSandbox
    let store: RackyStore
    let service: ProjectService

    init(clock: @escaping @Sendable () -> Date = { Date() }) async throws {
        sandbox = try GitSandbox()
        let home = try sandbox.dir("racky-home")
        store = try await RackyStore.open(paths: StorePaths(root: home))
        service = ProjectService(store: store, git: sandbox.service,
                                 worktreeBase: sandbox.root.appendingPathComponent("wt", isDirectory: true), clock: clock)
    }

    func sessions(of project: Project, includeArchived: Bool = false) async throws -> [Session] {
        try await store.sessions(includeArchived: includeArchived).filter { $0.projectID == project.id }
    }
}

@Suite struct ProjectAddTests {
    @Test func gitRepoIsDetectedWithRootNameBranchAndRemote() async throws {
        let h = try await ProjectHarness()
        let (repo, _) = try await h.sandbox.makeRepoWithOrigin("acme-platform")
        try await h.sandbox.git(["remote", "set-url", "origin", "https://user:s3cret@example.com/x/rti.git"], in: repo)
        let sub = repo.appendingPathComponent("deep/dir", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        let result = try await h.service.addProject(folder: sub)
        let p = result.project
        #expect(result.outcome == .added)
        #expect(p.kind == .git && p.rootPath == repo.path && p.name == "acme-platform")
        #expect(p.defaultBranch == "main")
        #expect(p.gitRemoteURL == "https://example.com/x/rti.git")
        #expect(p.branchPrefix == "alex-doe")
        #expect(p.worktreeRoot == h.sandbox.root.appendingPathComponent("wt/acme-platform").path)
        #expect(try await h.store.projects().map(\.id) == [p.id])
    }

    @Test func folderWithoutGitBecomesFolderProject() async throws {
        let h = try await ProjectHarness()
        let folder = try h.sandbox.dir("notes")
        let result = try await h.service.addProject(folder: folder)
        #expect(result.project.kind == .folder && result.project.name == "notes" && result.project.rootPath == folder.path)
        #expect(result.project.defaultBranch == nil && result.project.gitRemoteURL == nil)
        #expect(try await h.sessions(of: result.project).isEmpty)
    }

    @Test func repoWithoutCommitsOrOriginStillAdds() async throws {
        let h = try await ProjectHarness()
        let repo = try h.sandbox.dir("fresh")
        try await h.sandbox.git(["init", "-q", "-b", "main"], in: repo)
        let result = try await h.service.addProject(folder: repo)
        #expect(result.project.kind == .git && result.project.defaultBranch == nil && result.project.gitRemoteURL == nil)
    }

    @Test func missingOrFileFolderIsRejected() async throws {
        let h = try await ProjectHarness()
        await #expect(throws: ProjectError.self) { _ = try await h.service.addProject(folder: h.sandbox.root.appendingPathComponent("nope")) }
        let file = h.sandbox.root.appendingPathComponent("a.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        await #expect(throws: ProjectError.self) { _ = try await h.service.addProject(folder: file) }
        #expect(try await h.store.projects(includeArchived: true).isEmpty)
    }

    @Test func addingTwiceOrFromALinkedWorktreeDoesNotDuplicate() async throws {
        let h = try await ProjectHarness()
        let repo = try await h.sandbox.makeRepo("proj")
        let first = try await h.service.addProject(folder: repo)
        let again = try await h.service.addProject(folder: repo)
        #expect(again.outcome == .alreadyAdded && again.project.id == first.project.id)

        let linked = h.sandbox.root.appendingPathComponent("linked")
        try await h.sandbox.git(["worktree", "add", "-q", "-b", "side", linked.path], in: repo)
        let fromLinked = try await h.service.addProject(folder: linked)
        #expect(fromLinked.outcome == .alreadyAdded && fromLinked.project.id == first.project.id)
        #expect(try await h.store.projects().count == 1)
    }

    @Test func sortIndexGrows() async throws {
        let h = try await ProjectHarness()
        let a = try await h.service.addProject(folder: h.sandbox.dir("a")).project
        let b = try await h.service.addProject(folder: h.sandbox.dir("b")).project
        #expect(b.sortIndex == a.sortIndex + 1)
    }
}

@Suite struct ProjectWorktreeSyncTests {
    @Test func existingWorktreesBecomeUnstartedSessions() async throws {
        let h = try await ProjectHarness()
        let repo = try await h.sandbox.makeRepo("proj")
        let one = h.sandbox.root.appendingPathComponent("wt-one")
        let two = h.sandbox.root.appendingPathComponent("wt-two")
        try await h.sandbox.git(["worktree", "add", "-q", "-b", "feat/one", one.path], in: repo)
        try await h.sandbox.git(["worktree", "add", "-q", "--detach", two.path], in: repo)

        let result = try await h.service.addProject(folder: repo)
        #expect(result.sync == ProjectSyncReport(added: 3))
        let sessions = try await h.sessions(of: result.project)
        #expect(sessions.count == 3)
        let byPath = Dictionary(uniqueKeysWithValues: sessions.map { ($0.folderPath, $0) })
        let main = try #require(byPath[repo.path])
        #expect(main.kind == .checkout && main.title == "main" && main.lifecycle == .active)
        let feat = try #require(byPath[one.path])
        #expect(feat.kind == .worktree && feat.title == "feat/one" && !feat.managedFolder)
        let detached = try #require(byPath[two.path])
        #expect(detached.kind == .worktree && detached.title == "wt-two")
        for s in sessions {
            #expect(s.isStructurallyValid)
            #expect(try await h.store.tabs(sessionID: s.id, includeClosed: true).isEmpty, "sessão não iniciada: sem tabs")
        }
        let worktrees = try await h.store.worktrees(projectID: result.project.id)
        #expect(worktrees.count == 3 && worktrees.filter(\.isMain).count == 1)
        #expect(worktrees.first { $0.path == one.path }?.branch == "feat/one")
        #expect(worktrees.first { $0.path == two.path }?.branch == "")
    }

    @Test func syncIsIdempotentAndPicksUpNewAndRemovedWorktrees() async throws {
        let h = try await ProjectHarness()
        let repo = try await h.sandbox.makeRepo("proj")
        let project = try await h.service.addProject(folder: repo).project
        #expect(try await h.service.syncWorktrees(projectID: project.id) == ProjectSyncReport())

        let side = h.sandbox.root.appendingPathComponent("side")
        try await h.sandbox.git(["worktree", "add", "-q", "-b", "side", side.path], in: repo)
        #expect(try await h.service.syncWorktrees(projectID: project.id) == ProjectSyncReport(added: 1))
        #expect(try await h.sessions(of: project).count == 2)

        try await h.sandbox.git(["worktree", "remove", "--force", side.path], in: repo)
        #expect(try await h.service.syncWorktrees(projectID: project.id) == ProjectSyncReport(removed: 1))
        #expect(try await h.sessions(of: project).map(\.kind) == [.checkout])
        #expect(try await h.store.worktrees(projectID: project.id).count == 1)
    }

    @Test func renamedSessionAndStartedSessionSurviveSync() async throws {
        let h = try await ProjectHarness()
        let repo = try await h.sandbox.makeRepo("proj")
        let side = h.sandbox.root.appendingPathComponent("side")
        try await h.sandbox.git(["worktree", "add", "-q", "-b", "side", side.path], in: repo)
        let project = try await h.service.addProject(folder: repo).project
        var sideSession = try #require(try await h.sessions(of: project).first { $0.kind == .worktree })
        sideSession.title = "My name"
        try await h.store.save(sideSession)
        // Sessão com tab: o worktree some do disco, mas o registro fica.
        let tab = Tab(sessionID: sideSession.id, title: "claude", layout: .leaf(Pane(content: .terminal(.v7()))))
        try await h.store.save(tab)
        try await h.sandbox.git(["worktree", "remove", "--force", side.path], in: repo)

        #expect(try await h.service.syncWorktrees(projectID: project.id) == ProjectSyncReport())
        let kept = try #require(try await h.store.session(id: sideSession.id))
        #expect(kept.title == "My name")
        #expect(try await h.store.worktrees(projectID: project.id).count == 2)
    }

    @Test func branchSwitchedInTerminalIsPersistedFromStatus() async throws {
        let h = try await ProjectHarness()
        let repo = try await h.sandbox.makeRepo("proj")
        let project = try await h.service.addProject(folder: repo).project
        try await h.sandbox.git(["checkout", "-q", "-b", "other"], in: repo)
        let status = try await h.sandbox.service.status(at: repo)
        #expect(try await h.service.applyBranch(status, toWorktreeAt: repo.path))
        #expect(try await h.store.worktrees(projectID: project.id).first?.branch == "other")
        #expect(try await h.service.applyBranch(status, toWorktreeAt: repo.path) == false)
    }

    @Test func syncOfMissingRepoThrowsAndKeepsRecords() async throws {
        let h = try await ProjectHarness()
        let repo = try await h.sandbox.makeRepo("proj")
        let project = try await h.service.addProject(folder: repo).project
        try FileManager.default.moveItem(at: repo, to: h.sandbox.root.appendingPathComponent("moved"))
        await #expect(throws: (any Error).self) { _ = try await h.service.syncWorktrees(projectID: project.id) }
        #expect(try await h.sessions(of: project).count == 1)
        #expect(await h.service.syncAll().isEmpty)
    }
}

@Suite struct ProjectRenameRemoveTests {
    @Test func renameAndEmptyNameFallsBackToFolder() async throws {
        let h = try await ProjectHarness()
        let repo = try await h.sandbox.makeRepo("proj")
        let project = try await h.service.addProject(folder: repo).project
        try await h.service.renameProject(id: project.id, to: "  My App  ")
        #expect(try await h.store.project(id: project.id)?.name == "My App")
        try await h.service.renameProject(id: project.id, to: "   ")
        #expect(try await h.store.project(id: project.id)?.name == "proj")
        #expect(FileManager.default.fileExists(atPath: repo.path), "renomear não mexe na pasta")
        await #expect(throws: ProjectError.self) { try await h.service.renameProject(id: .v7(), to: "x") }
    }

    @Test func removeArchivesSessionsKeepsFilesAndReAddRestores() async throws {
        let h = try await ProjectHarness()
        let repo = try await h.sandbox.makeRepo("proj")
        let side = h.sandbox.root.appendingPathComponent("side")
        try await h.sandbox.git(["worktree", "add", "-q", "-b", "side", side.path], in: repo)
        let project = try await h.service.addProject(folder: repo).project

        #expect(try await h.service.removeProject(id: project.id) == 2)
        #expect(try await h.store.projects().isEmpty)
        let archived = try await h.sessions(of: project, includeArchived: true)
        #expect(archived.count == 2 && archived.allSatisfy { $0.lifecycle == .archived && $0.archivedAt != nil })
        #expect(try await h.store.sessions().isEmpty)
        // Nada em disco mudou.
        #expect(FileManager.default.fileExists(atPath: repo.appendingPathComponent("README.md").path))
        #expect(FileManager.default.fileExists(atPath: side.path))
        #expect(try await h.sandbox.service.listWorktrees(in: repo).count == 2)
        #expect(try await h.sandbox.git(["branch", "--list", "side"], in: repo).contains("side"))

        let back = try await h.service.addProject(folder: repo)
        #expect(back.outcome == .restored && back.project.id == project.id)
        #expect(try await h.store.projects().count == 1)
        #expect(try await h.store.sessions().isEmpty, "as sessões arquivadas continuam arquivadas")
        await #expect(throws: ProjectError.self) { _ = try await h.service.removeProject(id: .v7()) }
    }

    @Test func removeFolderProject() async throws {
        let h = try await ProjectHarness()
        let folder = try h.sandbox.dir("notes")
        try h.sandbox.write("a.txt", "x", in: folder)
        let project = try await h.service.addProject(folder: folder).project
        #expect(try await h.service.removeProject(id: project.id) == 0)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("a.txt").path))
    }
}

@Suite struct CredentialStrippingTests {
    @Test func stripsOnlyUrlCredentials() {
        #expect(GitNaming.stripCredentials("https://user:pw@github.com/a/b.git") == "https://github.com/a/b.git")
        #expect(GitNaming.stripCredentials("https://token@github.com/a/b.git") == "https://github.com/a/b.git")
        #expect(GitNaming.stripCredentials("https://github.com/a/b.git") == "https://github.com/a/b.git")
        #expect(GitNaming.stripCredentials("git@github.com:a/b.git") == "git@github.com:a/b.git")
        #expect(GitNaming.stripCredentials("ssh://git@github.com/a/b.git") == "ssh://git@github.com/a/b.git")
        #expect(GitNaming.stripCredentials("ssh://git:pw@host/a/b.git") == "ssh://host/a/b.git")
        #expect(GitNaming.stripCredentials("/local/path") == "/local/path")
    }
}
