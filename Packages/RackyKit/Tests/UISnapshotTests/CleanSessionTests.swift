import RackyCore
import RackyDesignSystem
import RackyProtocol
import RackyStore
import Foundation
import Testing

@testable import RackyUI

/// Sessões limpas e Quick Launch ligados ao Store real e a um `RACKY_HOME` temporário (T1-17, T1-21; AC-1101…1106, AC-1108,
/// AC-313). Os terminais não chegam a lançar (sem janela, o pane nunca tem tamanho): o lançamento real é coberto pelo E2E com o app.
@MainActor
@Suite(.serialized, .offscreenAppKit) struct CleanSessionTests {
    struct Rig {
        let env: AppEnvironment
        let store: RackyStore
        let root: URL
        let picker: FakePicker
        var registry: ActionRegistry { env.registry }
        var sessionsRoot: URL { root.appendingPathComponent("Racky/sessions", isDirectory: true) }
    }

    func make() async throws -> Rig {
        let root = URL(fileURLWithPath: "/tmp/abc-\(UInt32.random(in: 0 ... 0xFFFFFF))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let env = AppEnvironment(environment: ["RACKY_HOME": root.path, "RACKY_AUTOMATION": "1", "RACKY_SKIP_ONBOARDING": "1"])
        await env.start()
        let store = try #require(env.workspace.store)
        let picker = FakePicker()
        env.cleanSessions?.picker = picker
        return Rig(env: env, store: store, root: root, picker: picker)
    }

    func cleanup(_ rig: Rig) async {
        await rig.env.workspace.settlePersistence()
        try? await rig.store.close()
        try? FileManager.default.removeItem(at: rig.root)
    }

    func ids(_ json: String?) throws -> (session: UUID, tab: UUID, terminal: UUID) {
        let data = try #require(json?.data(using: .utf8))
        let dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        return (
            try #require(dict["sessionID"].flatMap(UUID.init(uuidString:))), try #require(dict["tabID"].flatMap(UUID.init(uuidString:))),
            try #require(dict["terminalID"].flatMap(UUID.init(uuidString:))))
    }

    func uuid(_ message: String?) throws -> UUID {
        let raw = try #require(message)
        return try #require(UUID(uuidString: raw))
    }

    func primary(_ model: WorkspaceModel, tab id: UUID) throws -> Terminal {
        let tab = try #require(model.tab(id))
        return try #require(model.primaryTerminal(of: tab))
    }

    func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 200 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
    }

    // MARK: AC-1101, AC-1102

    @Test func newCleanSessionCreatesAManagedFolderAndOpensTheDefaultAgentWithoutADialog() async throws {
        let rig = try await make()
        defer { Task { await cleanup(rig) } }
        let started = ContinuousClock.now
        let result = try await rig.registry.perform(.sessionNewClean, .press)
        let created = try ids(result.message)
        let elapsed = ContinuousClock.now - started
        #expect(elapsed < .seconds(1), "AC-1101: em até 1 s")

        let session = try #require(try await rig.store.session(id: created.session))
        #expect(session.kind == .clean)
        #expect(session.projectID == nil)
        #expect(session.managedFolder)
        let folder = URL(fileURLWithPath: session.folderPath)
        #expect(folder.deletingLastPathComponent().path == rig.sessionsRoot.path)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        let parts = folder.lastPathComponent.split(separator: "-").map(String.init)
        #expect(parts.count == 2 && SessionNameGenerator.adjectives.contains(parts[0]) && SessionNameGenerator.nouns.contains(parts[1]))
        #expect(session.title == folder.lastPathComponent, "sem prompt o título é o nome automático")

        // Tab com o agente padrão, no cwd da pasta, e a sessão selecionada; nenhum overlay.
        let terminal = try #require(try await rig.store.terminal(id: created.terminal))
        #expect(terminal.provider == .claude)
        #expect(terminal.cwd == session.folderPath)
        #expect(try await rig.store.tab(id: created.tab)?.sessionID == session.id)
        #expect(rig.env.sidebar.selectedSession == session.id)
        #expect(!rig.env.overlays.isPresenting)
    }

    @Test func eachCleanSessionGetsItsOwnFolder() async throws {
        let rig = try await make()
        defer { Task { await cleanup(rig) } }
        var folders: Set<String> = []
        for _ in 0 ..< 6 {
            let created = try ids(try await rig.registry.perform(.sessionNewClean, .press).message)
            folders.insert(try #require(try await rig.store.session(id: created.session)).folderPath)
        }
        #expect(folders.count == 6)
        #expect(try FileManager.default.contentsOfDirectory(atPath: rig.sessionsRoot.path).count == 6)
    }

    @Test func newCleanSessionHonorsTheDefaultAgentSetting() async throws {
        let rig = try await make()
        defer { Task { await cleanup(rig) } }
        _ = try await rig.registry.perform(.settingsGeneralCleanSessionFolder, .set(rig.root.appendingPathComponent("elsewhere").path))
        let created = try ids(try await rig.registry.perform(.sessionNewClean, .press).message)
        let session = try #require(try await rig.store.session(id: created.session))
        #expect(URL(fileURLWithPath: session.folderPath).deletingLastPathComponent().lastPathComponent == "elsewhere")
    }

    // MARK: AC-1105

    @Test func newCleanSessionInFolderUsesTheChosenFolderAndTouchesNothingInIt() async throws {
        let rig = try await make()
        defer { Task { await cleanup(rig) } }
        let chosen = rig.root.appendingPathComponent("my-notes", isDirectory: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        try "keep".write(to: chosen.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        rig.picker.next = chosen
        let created = try ids(try await rig.registry.perform(.sessionNewCleanInFolder, .press).message)
        #expect(rig.picker.calls == 1)
        let session = try #require(try await rig.store.session(id: created.session))
        #expect(session.kind == .clean)
        #expect(session.managedFolder == false)
        #expect(session.folderPath == chosen.path)
        #expect(session.title == "my-notes")
        #expect(try FileManager.default.contentsOfDirectory(atPath: chosen.path) == ["a.txt"])
        #expect(!FileManager.default.fileExists(atPath: rig.sessionsRoot.path), "nada foi criado na raiz gerenciada")
    }

    @Test func cancellingTheFolderPanelCreatesNothing() async throws {
        let rig = try await make()
        defer { Task { await cleanup(rig) } }
        rig.picker.next = nil
        let result = try await rig.registry.perform(.sessionNewCleanInFolder, .press)
        #expect(result.message == "cancelled")
        #expect(try await rig.store.sessions().isEmpty)
    }

    // MARK: AC-1103

    @Test func renamingKeepsTheFolderName() async throws {
        let rig = try await make()
        defer { Task { await cleanup(rig) } }
        let created = try ids(try await rig.registry.perform(.sessionNewClean, .press).message)
        let before = try #require(try await rig.store.session(id: created.session))
        _ = try await rig.registry.perform(.sessionRename, .select(created.session.uuidString))
        _ = try await rig.registry.perform(.sessionRename, .set("listings-oct"))
        let after = try #require(try await rig.store.session(id: created.session))
        #expect(after.title == "listings-oct")
        #expect(after.folderPath == before.folderPath)
        #expect(FileManager.default.fileExists(atPath: before.folderPath))
        let copied = try await rig.registry.perform(.itemCopyPath, .select(created.session.uuidString))
        #expect(copied.message == before.folderPath, "o caminho real continua acessível")
    }

    // MARK: Arquivar

    @Test func archiveAsksThenStopsAndKeepsTheFolder() async throws {
        let rig = try await make()
        defer { Task { await cleanup(rig) } }
        let created = try ids(try await rig.registry.perform(.sessionNewClean, .press).message)
        let folder = try #require(try await rig.store.session(id: created.session)).folderPath
        #expect(try await rig.registry.perform(.sessionArchive, .select(created.session.uuidString)).message == "confirming")
        #expect(rig.env.overlays.top?.spec.name == "confirmArchive")
        _ = try await rig.registry.perform(.dialogArchiveCancel, .press)
        #expect(try await rig.store.session(id: created.session)?.lifecycle == .active)
        _ = try await rig.registry.perform(.sessionArchive, .select(created.session.uuidString))
        _ = try await rig.registry.perform(.dialogArchiveConfirm, .press)
        let archived = try #require(try await rig.store.session(id: created.session))
        #expect(archived.lifecycle == .archived)
        #expect(archived.archivedAt != nil)
        #expect(FileManager.default.fileExists(atPath: folder))
        try await waitFor { rig.env.sidebar.selectedSession == nil }
        #expect(rig.env.sidebar.selectedSession == nil)
    }

    // MARK: AC-1108, AC-1105

    @Test func deleteMovesAManagedFolderToTheTrashAndKeepsRunFolders() async throws {
        let rig = try await make()
        defer { Task { await cleanup(rig) } }
        var trashed: [URL] = []
        rig.env.cleanSessions?.trashItem = { trashed.append($0) }
        let created = try ids(try await rig.registry.perform(.sessionNewClean, .press).message)
        let session = try #require(try await rig.store.session(id: created.session))
        let runs = rig.root.appendingPathComponent("Racky/runs/\(created.session.uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)

        #expect(try await rig.registry.perform(.sessionDelete, .select(created.session.uuidString)).message == "confirming")
        let dialog = try #require(rig.env.cleanSessions?.pendingDelete)
        #expect(dialog.managedFolder && dialog.trashFolder && !dialog.deleteRuns)
        #expect(dialog.message == "Stops its terminals and computers.")
        _ = try await rig.registry.perform(.dialogDeleteSessionConfirm, .press)

        #expect(try await rig.store.session(id: created.session) == nil)
        #expect(try await rig.store.tab(id: created.tab) == nil, "tabs saem em cascata")
        #expect(trashed.map(\.path) == [URL(fileURLWithPath: session.folderPath).standardizedFileURL.path])
        #expect(FileManager.default.fileExists(atPath: runs.path), "run folders ficam")
    }

    @Test func deleteCanAlsoRemoveRunFoldersAndSkipTheTrash() async throws {
        let rig = try await make()
        defer { Task { await cleanup(rig) } }
        var trashed: [URL] = []
        rig.env.cleanSessions?.trashItem = { trashed.append($0) }
        let created = try ids(try await rig.registry.perform(.sessionNewClean, .press).message)
        let runs = rig.root.appendingPathComponent("Racky/runs/\(created.session.uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
        _ = try await rig.registry.perform(.sessionDelete, .select(created.session.uuidString))
        _ = try await rig.registry.perform(.dialogDeleteSessionTrashFolder, .set("off"))
        _ = try await rig.registry.perform(.dialogDeleteSessionDeleteRuns, .set("on"))
        _ = try await rig.registry.perform(.dialogDeleteSessionConfirm, .press)
        #expect(trashed.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: runs.path))
    }

    @Test func deleteOfAChosenFolderLeavesItOnDisk() async throws {
        let rig = try await make()
        defer { Task { await cleanup(rig) } }
        var trashed: [URL] = []
        rig.env.cleanSessions?.trashItem = { trashed.append($0) }
        let chosen = rig.root.appendingPathComponent("chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        rig.picker.next = chosen
        let created = try ids(try await rig.registry.perform(.sessionNewCleanInFolder, .press).message)
        _ = try await rig.registry.perform(.sessionDelete, .select(created.session.uuidString))
        let dialog = try #require(rig.env.cleanSessions?.pendingDelete)
        #expect(!dialog.managedFolder)
        #expect(dialog.message == "Stops its terminals and computers. The folder stays on disk.")
        _ = try await rig.registry.perform(.dialogDeleteSessionConfirm, .press)
        #expect(try await rig.store.session(id: created.session) == nil)
        #expect(trashed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: chosen.path))
    }

    @Test func dontAskAgainTurnsTheConfirmationOff() async throws {
        let rig = try await make()
        defer { Task { await cleanup(rig) } }
        rig.env.cleanSessions?.trashItem = { _ in }
        let first = try ids(try await rig.registry.perform(.sessionNewClean, .press).message)
        _ = try await rig.registry.perform(.sessionDelete, .select(first.session.uuidString))
        _ = try await rig.registry.perform(.dialogDeleteSessionDontAsk, .set("on"))
        _ = try await rig.registry.perform(.dialogDeleteSessionConfirm, .press)
        #expect(rig.env.settings.settings.general.confirmDeleteSession == false)
        let second = try ids(try await rig.registry.perform(.sessionNewClean, .press).message)
        #expect(try await rig.registry.perform(.sessionDelete, .select(second.session.uuidString)).message == "deleted")
        #expect(try await rig.store.session(id: second.session) == nil)
    }

    // MARK: AC-1106

    @Test func moveToProjectLinksTheSessionWithoutMovingFiles() async throws {
        let rig = try await make()
        defer { Task { await cleanup(rig) } }
        let repo = rig.root.appendingPathComponent("acme-platform", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let projectID = try uuid(try await rig.registry.perform(.projectAdd, .set(repo.path)).message)
        let created = try ids(try await rig.registry.perform(.sessionNewClean, .press).message)
        let before = try #require(try await rig.store.session(id: created.session))
        try "x".write(to: URL(fileURLWithPath: before.folderPath).appendingPathComponent("data.csv"), atomically: true, encoding: .utf8)

        _ = try await rig.registry.perform(.sessionMoveToProject, .select(created.session.uuidString))
        #expect(rig.env.overlays.top?.spec.name == "moveToProject")
        // Sem escolha o botão está desabilitado com o motivo.
        await #expect(throws: (any Error).self) { try await rig.registry.perform(.dialogMoveToProjectConfirm, .press) }
        _ = try await rig.registry.perform(.dialogMoveToProjectSetProject, .select(projectID.uuidString))
        _ = try await rig.registry.perform(.dialogMoveToProjectConfirm, .press)

        let after = try #require(try await rig.store.session(id: created.session))
        #expect(after.id == before.id, "mesma sessão: o processo continua o mesmo")
        #expect(after.projectID == projectID)
        #expect(after.folderPath == before.folderPath)
        #expect(after.title == before.title)
        #expect(try await rig.store.tab(id: created.tab) != nil)
        #expect(try await rig.store.terminal(id: created.terminal)?.id == created.terminal)
        #expect(FileManager.default.fileExists(atPath: URL(fileURLWithPath: before.folderPath).appendingPathComponent("data.csv").path))
    }

    @Test func convertToProjectUsesTheFolderAsTheRoot() async throws {
        let rig = try await make()
        defer { Task { await cleanup(rig) } }
        let created = try ids(try await rig.registry.perform(.sessionNewClean, .press).message)
        let before = try #require(try await rig.store.session(id: created.session))
        _ = try await rig.registry.perform(.sessionConvertToProject, .select(created.session.uuidString))
        #expect(rig.env.cleanSessions?.pendingMove?.isConvert == true)
        _ = try await rig.registry.perform(.dialogMoveToProjectConfirm, .press)
        let after = try #require(try await rig.store.session(id: created.session))
        let projectID = try #require(after.projectID)
        let project = try #require(try await rig.store.project(id: projectID))
        #expect(project.rootPath == before.folderPath || URL(fileURLWithPath: project.rootPath).resolvingSymlinksInPath().path
            == URL(fileURLWithPath: before.folderPath).resolvingSymlinksInPath().path)
        #expect(project.kind == .folder, "pasta sem repositório vira projeto folder, sem git init")
        #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: before.folderPath).appendingPathComponent(".git").path))
    }

    @Test func onlyCleanSessionsCanBeMovedToAProject() async throws {
        let rig = try await make()
        defer { Task { await cleanup(rig) } }
        let repo = rig.root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let projectID = try uuid(try await rig.registry.perform(.projectAdd, .set(repo.path)).message)
        let session = Session(kind: .folder, projectID: projectID, folderPath: repo.path, title: "in-project")
        try await rig.store.save(session)
        try await waitFor { rig.env.sidebar.session(session.id) != nil }
        await #expect(throws: (any Error).self) { try await rig.registry.perform(.sessionMoveToProject, .select(session.id.uuidString)) }
    }

    // MARK: Quick Launch e ⌘T (AC-313)

    @Test func quickLaunchActionsOpenTabsInTheCurrentSession() async throws {
        let rig = try await make()
        defer { Task { await cleanup(rig) } }
        let created = try ids(try await rig.registry.perform(.sessionNewClean, .press).message)
        let model = rig.env.workspace
        try await waitFor { model.isLoaded }
        let cwd = try #require(try await rig.store.session(id: created.session)).folderPath
        #expect(model.tabs.count == 1)

        // ⌘T: shell na pasta da sessão.
        let shellTab = try uuid(try await rig.registry.perform(.tabNewTerminal, .press).message)
        var terminal = try primary(model, tab: shellTab)
        #expect(terminal.provider == .shell && terminal.cwd == cwd)

        // ⌥⌘T: agente padrão, sem seletor.
        let agentTab = try uuid(try await rig.registry.perform(.tabNewAgent, .press).message)
        terminal = try primary(model, tab: agentTab)
        #expect(terminal.provider == .claude && terminal.cwd == cwd)

        // "New Codex Tab".
        let codexTab = try uuid(try await rig.registry.perform(.tabNewWithAgent, .select("codex")).message)
        #expect(try primary(model, tab: codexTab).provider == .codex)

        // Start Claude Code with "<texto>" e perfil.
        let promptRequest = QuickLaunchRequest(provider: .claude, prompt: "reply OK").encoded()
        let promptTab = try uuid(try await rig.registry.perform(.tabNewWithPrompt, .set(promptRequest)).message)
        terminal = try primary(model, tab: promptTab)
        #expect(terminal.launchSpec.initialPrompt == "reply OK")
        let plan = BuiltinProfiles.claudePlan
        let profileRequest = QuickLaunchRequest(provider: .claude, profileID: plan.id).encoded()
        let profileTab = try uuid(try await rig.registry.perform(.tabNewWithPrompt, .set(profileRequest)).message)
        #expect(try primary(model, tab: profileTab).launchSpec.profileID == plan.id)
        #expect(model.tabs.count == 6)
        // As novas tabs entram à direita da ativa, uma depois da outra.
        #expect(model.activeTabID == profileTab)
    }

    @Test func quickLaunchSplitOpensToTheRightOfTheFocusedPane() async throws {
        let rig = try await make()
        defer { Task { await cleanup(rig) } }
        _ = try ids(try await rig.registry.perform(.sessionNewClean, .press).message)
        let model = rig.env.workspace
        try await waitFor { model.isLoaded }
        let request = QuickLaunchRequest(provider: .shell, split: true).encoded()
        let id = try uuid(try await rig.registry.perform(.tabNewWithPrompt, .set(request)).message)
        #expect(model.activeTab?.layout.leafCount == 2)
        #expect(model.terminal(id)?.provider == .shell)
        #expect(model.tabs.count == 1, "split não abre tab")
    }

    @Test func quickLaunchOpensAnchoredPopoverAndNeedsASession() async throws {
        let rig = try await make()
        defer { Task { await cleanup(rig) } }
        await #expect(throws: (any Error).self) { try await rig.registry.perform(.tabQuickLaunch, .press) }
        _ = try await rig.registry.perform(.sessionNewClean, .press)
        try await waitFor { rig.env.workspace.isLoaded }
        #expect(try await rig.registry.perform(.tabQuickLaunch, .press).message == "opened")
        #expect(rig.env.overlays.popover?.spec.name == "quickLaunch")
        #expect(rig.env.overlays.popover?.spec.id == .overlayQuickLaunch)
        rig.env.overlays.dismissPopover()
    }
}
