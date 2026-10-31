import RackyCore
import RackyProtocol
import AppKit
import Foundation
import Testing

@testable import RackyUI

/// Módulo Files (10-right-panel §2): seguimento do cwd, pin, árvore, FSEvents, marcação de git e visualizador.
@MainActor
@Suite(.tags(.integration), .serialized) struct FilesControllerTests {  // FSEvents e disco de verdade: na fase serial
    // MARK: Seguimento do cwd (AC-RP01)

    @Test func startsOnTheSessionFolderAndFollowsTheAgentCwd() async throws {
        let session = try FilesFixture.makeTree(["a.txt", "pkg/b.txt", "other/c.txt"])
        defer { try? FileManager.default.removeItem(atPath: session) }
        let box = FilesSourceBox()
        box.sessionRoot = session
        let terminal = UUID()
        box.focused = FilesFixture.claude(terminal, cwd: session)
        let files = FilesFixture.controller(box: box)
        files.recompute()
        #expect(files.resolution.root == session)
        #expect(files.resolution.mode == .following(agent: "Claude"))
        #expect(await FilesFixture.wait { FilesFixture.rowNames(files) == ["other", "pkg", "a.txt"] })

        // O Claude (que não emite OSC 7) informa a pasta pelos hooks: a raiz muda na hora, e a árvore da nova pasta carrega.
        let epoch = files.rootEpoch
        files.noteCwd(session + "/pkg", terminal: terminal, source: .hook)
        #expect(files.resolution.root == session + "/pkg")
        #expect(files.rootEpoch == epoch + 1, "a view anima a troca de raiz")
        #expect(await FilesFixture.wait { FilesFixture.rowNames(files) == ["b.txt"] })

        // Um shell com OSC 7 volta para fora da pasta da sessão.
        files.noteCwd(session + "/other", terminal: terminal, source: .osc7)
        #expect(files.resolution.root == session + "/other")
        #expect(files.resolution.isOutsideSession == false, "other está dentro da sessão")
        #expect(await FilesFixture.wait { FilesFixture.rowNames(files) == ["c.txt"] })
    }

    @Test func cwdOutsideTheSessionIsFlaggedAndOfferedBack() async throws {
        let session = try FilesFixture.makeTree(["proj/a.txt"], name: UUID().uuidString)
        let outside = try FilesFixture.makeTree(["z.txt"], name: UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(atPath: session)
            try? FileManager.default.removeItem(atPath: outside)
        }
        let box = FilesSourceBox()
        box.sessionRoot = session + "/proj"
        let terminal = UUID()
        box.focused = FilesFixture.claude(terminal)
        let files = FilesFixture.controller(box: box)
        files.recompute()
        files.noteCwd(outside, terminal: terminal, source: .hook)
        #expect(files.resolution.root == outside)
        #expect(files.resolution.isOutsideSession)
        #expect(files.canShowSessionFolder)
        files.showSessionFolder()
        #expect(files.resolution.root == session + "/proj")
        #expect(files.isPinned, "voltar fixa a pasta da sessão")
        #expect(!files.canShowSessionFolder)
    }

    @Test func pinningKeepsTheRootAndUnpinningCatchesUp() async throws {
        let session = try FilesFixture.makeTree(["a.txt", "pkg/b.txt"])
        defer { try? FileManager.default.removeItem(atPath: session) }
        let box = FilesSourceBox()
        box.sessionRoot = session
        let terminal = UUID()
        box.focused = FilesFixture.claude(terminal)
        let files = FilesFixture.controller(box: box)
        files.recompute()
        files.togglePin()
        #expect(files.isPinned)
        #expect(files.resolution.mode == .pinned)
        files.noteCwd(session + "/pkg", terminal: terminal, source: .hook)
        #expect(files.resolution.root == session, "pin vence o cwd do agente")
        files.togglePin()
        #expect(!files.isPinned)
        #expect(files.resolution.root == session + "/pkg", "ao soltar, volta a seguir o último cwd")
    }

    @Test func pinIsPerSession() async throws {
        let one = try FilesFixture.makeTree(["a.txt"])
        let two = try FilesFixture.makeTree(["b.txt"])
        defer {
            try? FileManager.default.removeItem(atPath: one)
            try? FileManager.default.removeItem(atPath: two)
        }
        let box = FilesSourceBox()
        let sessionOne = UUID(), sessionTwo = UUID()
        box.sessionID = sessionOne
        box.sessionRoot = one
        box.focused = FilesFixture.claude()
        let files = FilesFixture.controller(box: box)
        files.recompute()
        files.togglePin()
        box.sessionID = sessionTwo
        box.sessionRoot = two
        files.recompute()
        #expect(files.resolution.root == two)
        #expect(!files.isPinned)
        box.sessionID = sessionOne
        box.sessionRoot = one
        files.recompute()
        #expect(files.isPinned)
    }

    @Test func noSessionMeansAnEmptyModule() async throws {
        let box = FilesSourceBox()
        box.sessionID = nil
        let files = FilesFixture.controller(box: box)
        files.recompute()
        #expect(files.resolution.mode == .none)
        #expect(files.tree == nil)
    }

    @Test func switchingSessionClosesTheViewerButFollowingKeepsIt() async throws {
        let session = try FilesFixture.makeTree(["a.swift", "pkg/b.txt"])
        defer { try? FileManager.default.removeItem(atPath: session) }
        let box = FilesSourceBox()
        box.sessionRoot = session
        let terminal = UUID()
        box.focused = FilesFixture.claude(terminal)
        let files = FilesFixture.controller(box: box)
        files.recompute()
        files.open(session + "/a.swift")
        #expect(files.viewer?.path == session + "/a.swift")
        files.noteCwd(session + "/pkg", terminal: terminal, source: .hook)
        #expect(files.viewer != nil, "seguir o agente não fecha o arquivo que o usuário está lendo")
        box.sessionID = UUID()
        files.recompute()
        #expect(files.viewer == nil)
    }

    // MARK: Árvore

    @Test func ignoredItemsAreHiddenAndTheToggleRevealsThem() async throws {
        let session = try FilesFixture.makeTree([".git/HEAD", "node_modules/x.js", "build/out.o", "src/main.swift", ".gitignore"])
        try FilesFixture.write("build/\n", to: session + "/.gitignore")
        defer { try? FileManager.default.removeItem(atPath: session) }
        let box = FilesSourceBox()
        box.sessionRoot = session
        box.focused = FilesFixture.claude()
        let files = FilesFixture.controller(box: box)
        files.recompute()
        #expect(await FilesFixture.wait { FilesFixture.rowNames(files) == ["src", ".gitignore"] })
        files.setShowIgnored(true)
        #expect(await FilesFixture.wait { FilesFixture.rowNames(files).contains("node_modules") })
        let rows = files.tree?.rows ?? []
        #expect(rows.first { $0.entry.name == "build" }?.entry.isIgnored == true)
        #expect(rows.first { $0.entry.name == "src" }?.entry.isIgnored == false)
        files.setShowIgnored(false)
        #expect(await FilesFixture.wait { FilesFixture.rowNames(files) == ["src", ".gitignore"] })
    }

    @Test func expandingAFolderLoadsItsChildrenAndKeepsExpansionPerRoot() async throws {
        let session = try FilesFixture.makeTree(["src/a.swift", "src/deep/b.swift", "docs/readme.md"])
        defer { try? FileManager.default.removeItem(atPath: session) }
        let box = FilesSourceBox()
        box.sessionRoot = session
        let terminal = UUID()
        box.focused = FilesFixture.claude(terminal)
        let files = FilesFixture.controller(box: box)
        files.recompute()
        #expect(await FilesFixture.wait { FilesFixture.rowNames(files) == ["docs", "src"] })
        files.toggleFolder(session + "/src")
        #expect(await FilesFixture.wait { FilesFixture.rowNames(files) == ["docs", "src", "deep", "a.swift"] })
        // Sai e volta: a pasta continua expandida.
        files.noteCwd(session + "/docs", terminal: terminal, source: .hook)
        #expect(await FilesFixture.wait { FilesFixture.rowNames(files) == ["readme.md"] })
        files.noteCwd(session, terminal: terminal, source: .hook)
        #expect(await FilesFixture.wait { FilesFixture.rowNames(files) == ["docs", "src", "deep", "a.swift"] })
    }

    @Test func fileSystemEventsRefreshTheTree() async throws {
        let session = try FilesFixture.makeTree(["a.txt"])
        defer { try? FileManager.default.removeItem(atPath: session) }
        let box = FilesSourceBox()
        box.sessionRoot = session
        box.focused = FilesFixture.claude()
        let files = FilesFixture.controller(box: box)
        files.recompute()
        #expect(await FilesFixture.wait { FilesFixture.rowNames(files) == ["a.txt"] })
        // O stream do FSEvents leva um instante para ficar de pé (mais sob carga): a escrita se repete até a árvore ver o arquivo.
        var seen = false
        for attempt in 0..<8 where !seen {
            try FilesFixture.write("new \(attempt)\n", to: session + "/created-by-agent.txt")
            seen = await FilesFixture.wait(timeout: .seconds(2)) { FilesFixture.rowNames(files).contains("created-by-agent.txt") }
        }
        #expect(seen, "FSEvents atualiza a árvore")
        try FileManager.default.removeItem(atPath: session + "/a.txt")
        #expect(await FilesFixture.wait(timeout: .seconds(8)) { !FilesFixture.rowNames(files).contains("a.txt") })
    }

    // MARK: Git

    @Test func changedFilesAreMarkedFromGitStatus() async throws {
        let session = try FilesFixture.makeTree(["src/main.swift", "src/new.swift", "notes.md", "clean.txt"])
        defer { try? FileManager.default.removeItem(atPath: session) }
        let box = FilesSourceBox()
        box.sessionRoot = session
        box.focused = FilesFixture.claude()
        let porcelain = " M src/main.swift\0A  src/new.swift\0?? notes.md\0"
        let files = FilesFixture.controller(box: box, porcelain: porcelain)
        files.recompute()
        #expect(await FilesFixture.wait { files.changes.count == 3 })
        #expect(files.changes.change(for: session + "/src/main.swift") == .modified)
        #expect(files.changes.change(for: session + "/src/new.swift") == .added)
        #expect(files.changes.change(for: session + "/notes.md") == .untracked)
        #expect(files.changes.change(for: session + "/clean.txt") == nil)
        #expect(files.changes.directoryHasChanges(session + "/src"))
        #expect(files.branch == "main")
    }

    // MARK: Visualizador

    @Test func viewerLoadsHighlightsAndSearches() async throws {
        let session = try FilesFixture.makeTree([])
        defer { try? FileManager.default.removeItem(atPath: session) }
        let source = "// header\nlet answer = 42\nfunc run() {\n    let other = answer\n}\n"
        try FilesFixture.write(source, to: session + "/main.swift")
        let box = FilesSourceBox()
        box.sessionRoot = session
        box.focused = FilesFixture.claude()
        let diff = "@@ -2 +2 @@\n-let answer = 41\n+let answer = 42\n"
        let files = FilesFixture.controller(box: box, porcelain: " M main.swift\0", diff: diff)
        files.recompute()
        #expect(await FilesFixture.wait { files.changes.count == 1 })
        files.open(session + "/main.swift")
        #expect(await FilesFixture.wait { files.viewer?.content != nil })
        let viewer = try #require(files.viewer)
        #expect(viewer.language == .swift)
        #expect(viewer.lineCount == 5)
        #expect(viewer.spans.contains { $0.kind == .comment })
        #expect(viewer.spans.contains { $0.kind == .keyword })
        #expect(viewer.change == .modified)
        #expect(await FilesFixture.wait { files.viewer?.marks.kind(forLine: 2) == .modified }, "calha do git: linha 2 alterada")

        files.setSearchActive(true)
        files.setSearchQuery("answer")
        #expect(files.search.matches.count == 2)
        #expect(files.search.countLabel == "1 of 2")
        files.stepSearch(1)
        #expect(files.search.current == 1)
        files.stepSearch(1)
        #expect(files.search.current == 0, "a busca dá a volta")
        files.stepSearch(-1)
        #expect(files.search.current == 1)
        files.setSearchQuery("zzz")
        #expect(files.search.matches.isEmpty)
        files.setSearchActive(false)
        #expect(files.search.query.isEmpty)
        files.closeViewer()
        #expect(files.viewer == nil)
    }

    @Test func viewerHandlesBinaryAndTheFileChangingOnDisk() async throws {
        let session = try FilesFixture.makeTree([])
        defer { try? FileManager.default.removeItem(atPath: session) }
        try Data([0x00, 0x01, 0x02]).write(to: URL(fileURLWithPath: session + "/blob.dat"))
        try FilesFixture.write("one\n", to: session + "/note.txt")
        let box = FilesSourceBox()
        box.sessionRoot = session
        box.focused = FilesFixture.claude()
        let files = FilesFixture.controller(box: box)
        files.recompute()
        files.open(session + "/blob.dat")
        #expect(await FilesFixture.wait { files.viewer?.content == .binary(size: 3) })
        files.open(session + "/note.txt")
        #expect(await FilesFixture.wait { files.viewer?.content == .text("one\n", truncated: false) })
        try FilesFixture.write("one\ntwo\n", to: session + "/note.txt")
        files.diskChanged([session + "/note.txt"])
        #expect(await FilesFixture.wait { files.viewer?.content == .text("one\ntwo\n", truncated: false) }, "o arquivo aberto relê quando muda")
        #expect(files.viewer?.lineCount == 2)
    }

    // MARK: Ações

    @Test func actionsDriveTheModule() async throws {
        let session = try FilesFixture.makeTree(["src/a.swift", "b.txt"])
        defer { try? FileManager.default.removeItem(atPath: session) }
        let box = FilesSourceBox()
        box.sessionRoot = session
        box.focused = FilesFixture.claude()
        let files = FilesFixture.controller(box: box)
        let registry = try FilesFixture.registry(for: files)
        files.recompute()
        #expect(await FilesFixture.wait { FilesFixture.rowNames(files) == ["src", "b.txt"] })

        // Sem arquivo aberto, as ações do visualizador dizem por quê.
        await #expect(throws: ActionError.disabled(.filesCloseFile, reason: "No file is open.")) { try await registry.perform(.filesCloseFile, .press) }
        await #expect(throws: ActionError.disabled(.filesFind, reason: "Open a file first.")) { try await registry.perform(.filesFind, .press) }
        #expect(registry.availability(of: .filesShowSessionFolder) == .disabled(reason: "Already showing the session folder."))

        let folder = try await registry.perform(.filesOpen, .select(session + "/src"))
        #expect(folder.message == "expanded")
        #expect(await FilesFixture.wait { FilesFixture.rowNames(files).contains("a.swift") })
        let collapsed = try await registry.perform(.filesOpen, .select(session + "/src"))
        #expect(collapsed.message == "collapsed")

        let opened = try await registry.perform(.filesOpen, .select(session + "/b.txt"))
        #expect(opened.message == "opened")
        #expect(files.viewer?.path == session + "/b.txt")
        #expect(await FilesFixture.wait { files.viewer?.content != nil })
        let find = try await registry.perform(.filesFind, .set("value"))
        #expect(find.message == "open")
        #expect(files.search.matches.count == 1)
        _ = try await registry.perform(.filesFindClose, .press)
        #expect(!files.search.isActive)
        _ = try await registry.perform(.filesCloseFile, .press)
        #expect(files.viewer == nil)

        let pinned = try await registry.perform(.filesTogglePin, .press)
        #expect(pinned.message == "pinned")
        let shown = try await registry.perform(.filesToggleIgnored, .press)
        #expect(shown.message == "shown")
        await #expect(throws: ActionError.self) { try await registry.perform(.filesOpen, .press) }
    }
}
