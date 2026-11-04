import RackyProtocol
import RackyStore
import Foundation
import Testing
@testable import RackyCore

/// Backlog 11: a pasta do projeto ou da sessão sumiu do disco.
@Suite struct MissingFolderTests {
    @Test func remotesMatchAcrossSshHttpsAndDotGit() {
        #expect(ProjectService.sameRemote("git@github.com:Acme/crawlers.git", "https://github.com/acme/crawlers"))
        #expect(ProjectService.sameRemote("ssh://git@github.com/acme/crawlers.git", "https://github.com/acme/crawlers/"))
        #expect(!ProjectService.sameRemote("https://github.com/acme/crawlers", "https://github.com/acme/other"))
        #expect(!ProjectService.sameRemote(nil, "https://github.com/acme/crawlers"))
    }

    @Test func cloneAgainBringsTheRepositoryBackToTheSamePath() async throws {
        let h = try await ProjectHarness()
        let (repo, _) = try await h.sandbox.makeRepoWithOrigin("gone")
        let project = try await h.service.addProject(folder: repo).project
        try FileManager.default.removeItem(at: repo)

        let back = try await h.service.cloneAgain(id: project.id)
        #expect(back.rootPath == project.rootPath)
        #expect(FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git").path))
        await #expect(throws: ProjectError.folderStillThere(project.rootPath)) { try await h.service.cloneAgain(id: project.id) }
    }

    @Test func cloneAgainNeedsARemote() async throws {
        let h = try await ProjectHarness()
        let repo = try await h.sandbox.makeRepo("local-only")
        let project = try await h.service.addProject(folder: repo).project
        try FileManager.default.removeItem(at: repo)
        await #expect(throws: ProjectError.noRemote) { try await h.service.cloneAgain(id: project.id) }
    }

    @Test func locateFolderAcceptsTheSameRepositoryMovedAndRefusesAnother() async throws {
        let h = try await ProjectHarness()
        let (repo, _) = try await h.sandbox.makeRepoWithOrigin("moved")
        let project = try await h.service.addProject(folder: repo).project
        let newHome = h.sandbox.root.appendingPathComponent("elsewhere/moved", isDirectory: true)
        try FileManager.default.createDirectory(at: newHome.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: repo, to: newHome)

        let (other, _) = try await h.sandbox.makeRepoWithOrigin("other")
        await #expect(throws: ProjectError.differentRepository(other.canonicalPath.path)) { try await h.service.relocateProject(id: project.id, to: other) }

        let relocated = try await h.service.relocateProject(id: project.id, to: newHome)
        #expect(relocated.rootPath == newHome.canonicalPath.path)
        #expect(try await h.store.project(id: project.id)?.rootPath == newHome.canonicalPath.path)
    }

    @Test func aSessionWithoutGitGetsItsEmptyFolderBack() async throws {
        let h = try await ProjectHarness()
        let path = h.sandbox.root.appendingPathComponent("sessions/quiet-meadow").path
        let session = Session(kind: .clean, folderPath: path, managedFolder: true, title: "quiet-meadow")
        try await h.store.save(session)

        #expect(try await h.service.recreateSessionFolder(sessionID: session.id) == path)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue)
        await #expect(throws: ProjectError.folderStillThere(path)) { try await h.service.recreateSessionFolder(sessionID: session.id) }
    }
}
