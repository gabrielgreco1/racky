import RackyProtocol
import Foundation
import Testing

@testable import RackyCore

/// Gerador determinístico (SplitMix64) para os testes de nomes.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite struct CleanSessionFoldersTests {
    func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("racky-clean-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func namesAreAdjectiveDashNoun() {
        var generator = SeededGenerator(state: 7)
        for _ in 0 ..< 200 {
            let parts = SessionNameGenerator.random(using: &generator).split(separator: "-").map(String.init)
            #expect(parts.count == 2)
            #expect(SessionNameGenerator.adjectives.contains(parts[0]))
            #expect(SessionNameGenerator.nouns.contains(parts[1]))
        }
        #expect(Set(SessionNameGenerator.adjectives).count == SessionNameGenerator.adjectives.count)
        #expect(Set(SessionNameGenerator.nouns).count == SessionNameGenerator.nouns.count)
    }

    /// AC-1102: o nome colide com `quiet-harbor` já existente; o app gera outro e nunca reaproveita a pasta.
    @Test func neverReusesAnExistingFolder() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Descobre os primeiros nomes que a semente produz e ocupa todos eles.
        var probe = SeededGenerator(state: 42)
        let taken = (0 ..< 5).map { _ in SessionNameGenerator.random(using: &probe) }
        for name in taken {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "keep".write(to: dir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        }
        var generator = SeededGenerator(state: 42)
        let created = try CleanSessionFolders.createManaged(root: root, using: &generator)
        #expect(!taken.contains(created.lastPathComponent))
        #expect(try FileManager.default.contentsOfDirectory(atPath: created.path).isEmpty)
        for name in taken {
            #expect(try String(contentsOf: root.appendingPathComponent(name).appendingPathComponent("file.txt"), encoding: .utf8) == "keep")
        }
    }

    @Test func uniqueFallsBackToASuffixWhenEverythingCollides() {
        var generator = SeededGenerator(state: 1)
        let name = SessionNameGenerator.unique(exists: { $0.split(separator: "-").count < 3 }, using: &generator)
        #expect(name.split(separator: "-").count == 3)
    }

    @Test func createsTheRootAndManyDistinctFolders() throws {
        let root = try tempRoot().appendingPathComponent("a/b/sessions", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent().deletingLastPathComponent()) }
        let folders = try (0 ..< 40).map { _ in try CleanSessionFolders.createManaged(root: root) }
        #expect(Set(folders.map(\.path)).count == 40)
        #expect(folders.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func trashRefusesFoldersTheAppDidNotCreate() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var moved: [URL] = []
        #expect(throws: CleanSessionFolders.FolderError.notManaged) {
            try CleanSessionFolders.trash(folder: root.path, managed: false, mover: { moved.append($0) })
        }
        #expect(moved.isEmpty)
    }

    @Test func trashRefusesHomeRootAndTheSessionsRoot() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var moved: [URL] = []
        for path in ["/", home.path, root.path] {
            #expect(throws: (any Error).self) {
                try CleanSessionFolders.trash(folder: path, managed: true, sessionsRoot: root, mover: { moved.append($0) })
            }
        }
        #expect(moved.isEmpty)
    }

    @Test func trashMovesAManagedFolder() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try CleanSessionFolders.createManaged(root: root)
        var moved: [URL] = []
        try CleanSessionFolders.trash(folder: folder.path, managed: true, sessionsRoot: root, mover: { moved.append($0) })
        #expect(moved.map(\.lastPathComponent) == [folder.lastPathComponent])
    }

    /// AC-1108: os run folders ficam, a menos que "Also delete run folders" seja marcado.
    @Test func runFoldersAreMatchedBySessionID() throws {
        let runs = try tempRoot()
        defer { try? FileManager.default.removeItem(at: runs) }
        let id = UUID.v7(), other = UUID.v7()
        for name in [id.uuidString.lowercased(), id.uuidString.lowercased() + "-batch1", other.uuidString.lowercased()] {
            try FileManager.default.createDirectory(at: runs.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        #expect(CleanSessionFolders.runFolders(forSession: id, runsRoot: runs).count == 2)
        #expect(try CleanSessionFolders.deleteRunFolders(forSession: id, runsRoot: runs) == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: runs.path) == [other.uuidString.lowercased()])
    }

    @Test func promotionOnlyLinksTheSession() {
        let project = UUID.v7()
        var session = Session(kind: .clean, folderPath: "/tmp/quiet-harbor", managedFolder: true, title: "listings-oct")
        session.statusNote = StatusNote(text: "x", author: "me")
        let promoted = SessionPromotion.attach(session, to: project)
        #expect(promoted.id == session.id)
        #expect(promoted.projectID == project)
        #expect(promoted.kind == .folder)
        #expect(promoted.isStructurallyValid)
        #expect(promoted.folderPath == session.folderPath)
        #expect(promoted.title == session.title)
        // A pasta passa a ser do projeto: apagar a sessão depois nunca a manda ao Lixo.
        #expect(promoted.managedFolder == false)
    }

    @Test func sessionsRootFollowsTheSettingAndStaysInsideAnIsolatedHome() {
        let isolated = URL(fileURLWithPath: "/tmp/abx-home", isDirectory: true)
        #expect(CleanSessionPaths.sessionsRoot(configured: "~/Racky/sessions", isolatedHome: isolated).path == "/tmp/abx-home/Racky/sessions")
        #expect(CleanSessionPaths.sessionsRoot(configured: "/tmp/custom", isolatedHome: isolated).path == "/tmp/custom")
        #expect(CleanSessionPaths.sessionsRoot(configured: "~/Racky/sessions", isolatedHome: nil).path
            == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Racky/sessions").path)
        #expect(CleanSessionPaths.runsRoot(isolatedHome: isolated).path == "/tmp/abx-home/Racky/runs")
    }
}
