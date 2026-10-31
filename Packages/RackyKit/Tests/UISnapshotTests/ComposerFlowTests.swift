import RackyCore
import RackyProtocol
import RackyStore
import Foundation
import Testing

@testable import RackyUI

/// Fluxo real do composer ⌘N (T1-20) ligado ao Store, à sidebar, ao launcher e a repositórios temporários: abrir, preencher
/// por ações do registro (as mesmas dos cliques), criar e ver o overlay fechar na hora com a linha pendente na sidebar.
/// Sem janela, o pane nunca tem tamanho: o agente não é lançado aqui (isso é coberto em `DaemonTests` e na evidência).
@MainActor
@Suite(.serialized, .offscreenAppKit) struct ComposerFlowTests {
    final class FakeFolderPicker: SessionFolderPicking {
        var next: URL?
        func chooseFolder(title: String, message: String, prompt: String) async -> URL? { next }
    }

    struct Rig {
        let env: AppEnvironment
        let root: URL
        let repo: URL
        let project: Project
        let picker: FakeFolderPicker
        var worktrees: URL { root.appendingPathComponent("wt", isDirectory: true) }
        var sessions: URL { root.appendingPathComponent("sessions", isDirectory: true) }
        var registry: ActionRegistry { env.registry }
    }

    func makeRig(withOrigin: Bool = true) async throws -> Rig {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("racky-composer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("home"), withIntermediateDirectories: true)
        let resolved = try #require(realpath(base.path, nil))
        defer { free(resolved) }
        let root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        let repo = root.appendingPathComponent("acme-platform", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try ProjectsControllerTests.git(["init", "-q", "-b", "main"], in: repo)
        try "hi\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try ProjectsControllerTests.git(["add", "."], in: repo)
        try ProjectsControllerTests.git(["commit", "-q", "-m", "init"], in: repo)
        if withOrigin {
            let origin = root.appendingPathComponent("origin.git", isDirectory: true)
            try ProjectsControllerTests.git(["init", "-q", "--bare", "-b", "main", origin.path], in: root)
            try ProjectsControllerTests.git(["remote", "add", "origin", origin.path], in: repo)
            try ProjectsControllerTests.git(["push", "-q", "-u", "origin", "main"], in: repo)
            try ProjectsControllerTests.git(["remote", "set-head", "origin", "main"], in: repo)
        }
        let env = AppEnvironment(environment: ["RACKY_HOME": root.appendingPathComponent("home").path, "RACKY_SKIP_ONBOARDING": "1"])
        await env.start()
        let picker = FakeFolderPicker()
        env.composer?.picker = picker
        let project = try await env.projects.addProject(folder: repo)
        // Pastas e prefixo isolados no temp: nada fora do temp nem em ~/Racky.
        _ = try await env.registry.perform(.settingsGeneralWorktreeFolder, .set(root.appendingPathComponent("wt").path))
        _ = try await env.registry.perform(.settingsGeneralCleanSessionFolder, .set(root.appendingPathComponent("sessions").path))
        _ = try await env.registry.perform(.settingsGeneralBranchPrefix, .set("custom"))
        _ = try await env.registry.perform(.settingsGeneralBranchPrefixCustom, .set("me"))
        let rig = Rig(env: env, root: root, repo: repo, project: project, picker: picker)
        try await wait("project visible") { env.sidebar.project(project.id) != nil }
        return rig
    }

    func finish(_ rig: Rig) async {
        await rig.env.stop()
        try? FileManager.default.removeItem(at: rig.root)
    }

    func wait(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(25)) }
        #expect(condition(), "\(what)")
    }

    func set(_ rig: Rig, _ id: ActionID, _ value: String) async throws {
        _ = try await rig.registry.perform(id, .set(value))
    }

    func select(_ rig: Rig, _ id: ActionID, _ value: String) async throws {
        _ = try await rig.registry.perform(id, .select(value))
    }

    var overlayOpen: (Rig) -> Bool { { $0.env.overlays.top?.spec.name == "composer" } }

    // MARK: Abrir e lembrar

    @Test func sessionNewOpensTheComposerOnTheLastProjectWithNewWorktreeAndTheDefaultAgent() async throws {
        let rig = try await makeRig()
        defer { Task { await finish(rig) } }
        let result = try await rig.registry.perform(.sessionNew, .press)
        #expect(result.message == "opened" && overlayOpen(rig))
        let model = try #require(rig.env.composer?.model)
        #expect(model.draft.projectID == rig.project.id && model.draft.whereChoice == .newWorktree)
        #expect(model.draft.provider == .claude && model.draft.profileID != nil)
        try await wait("branch prefix") { model.branchPrefix == "me" }
    }

    @Test func composerRemembersProjectAgentAndProfileAfterCreating() async throws {
        let rig = try await makeRig()
        defer { Task { await finish(rig) } }
        _ = try await rig.registry.perform(.sessionNew, .press)
        try await select(rig, .composerSetAgent, "shell")
        try await select(rig, .composerSetWhere, "mainCheckout")
        _ = try await rig.registry.perform(.composerSubmit, .press)
        try await wait("closed") { !overlayOpen(rig) }
        _ = try await rig.registry.perform(.sessionNew, .press)
        let model = try #require(rig.env.composer?.model)
        #expect(model.draft.projectID == rig.project.id && model.draft.provider == .shell)
    }

    /// Perfil que pula permissões + destino protegido: o primeiro Create só pede confirmação; Back volta; Create anyway cria.
    @Test func riskyCombinationAsksBeforeCreating() async throws {
        let rig = try await makeRig()
        defer { Task { await finish(rig) } }
        _ = try await rig.registry.perform(.sessionNew, .press)
        try await select(rig, .composerSetWhere, "mainCheckout")
        let model = try #require(rig.env.composer?.model)
        model.dataDestinations = {
            [ComposerDataDestination(key: "prod/public.listings", title: "public.listings", group: "Prod", production: true, explanation: "")]
        }
        model.draft.dataDestination = "prod/public.listings"
        try #require(model.summary.contains("--dangerously-skip-permissions"), "o perfil padrão do Claude pula as permissões")
        #expect(model.needsRiskConfirmation)

        let first = try await rig.registry.perform(.composerSubmit, .press)
        #expect(first.message == "confirming risk" && model.confirmingRisk && overlayOpen(rig))
        _ = try await rig.registry.perform(.composerKeepEditing, .press)
        #expect(!model.confirmingRisk && overlayOpen(rig))

        _ = try await rig.registry.perform(.composerSubmit, .press)
        #expect(model.confirmingRisk)
        // ⌘↵ de novo não confirma: só o botão "Create anyway".
        let again = try await rig.registry.perform(.composerSubmit, .press)
        #expect(again.message == "confirming risk" && overlayOpen(rig))
        _ = try await rig.registry.perform(.composerSubmit, .select("anyway"))
        try await wait("closed") { !overlayOpen(rig) }

        // Destino deste Mac: nada a confirmar.
        _ = try await rig.registry.perform(.sessionNew, .press)
        let next = try #require(rig.env.composer?.model)
        next.draft.dataDestination = "racky"
        #expect(!next.needsRiskConfirmation)
    }

    // MARK: Criar (P9)

    @Test func submitClosesTheOverlayAtOnceShowsAPendingRowAndThenCreatesTheWorktreeSession() async throws {
        let rig = try await makeRig()
        defer { Task { await finish(rig) } }
        _ = try await rig.registry.perform(.sessionNew, .press)
        try await set(rig, .composerSetPrompt, "fix search pagination")
        let submit = try await rig.registry.perform(.composerSubmit, .press)
        let pendingID = try #require(submit.message.flatMap(UUID.init(uuidString:)))
        #expect(rig.env.overlays.live.isEmpty, "o overlay fecha na hora (P9)")
        #expect(rig.env.sidebar.pending(pendingID) != nil && rig.env.sidebar.focusedPending == pendingID)

        try await wait("session selected") {
            guard let id = rig.env.sidebar.selectedSession, let s = rig.env.sidebar.session(id) else { return false }
            return s.title == "fix search pagination"
        }
        let session = try #require(rig.env.sidebar.selectedSession.flatMap { rig.env.sidebar.session($0) })
        #expect(session.kind == .worktree && session.projectID == rig.project.id)
        #expect(session.folderPath.hasSuffix("/wt/acme-platform/fix-search-pagination"))
        let wt = try #require(rig.env.sidebar.worktree(of: session))
        #expect(wt.branch == "me/fix-search-pagination" && wt.createdByApp)
        #expect(FileManager.default.fileExists(atPath: session.folderPath + "/README.md"))
        #expect(rig.env.sidebar.focusedPending == nil, "o centro troca da PhaseList para o pane")
        let snapshot = rig.env.sidebar.snapshot
        let tab = try #require(snapshot.tabs.first { $0.sessionID == session.id })
        #expect(snapshot.terminals.contains { $0.tabID == tab.id && $0.launchSpec.provider == .claude })
    }

    @Test func promptGoesToTheTerminalSpecAsTheInitialPromptArgument() async throws {
        let rig = try await makeRig()
        defer { Task { await finish(rig) } }
        _ = try await rig.registry.perform(.sessionNew, .press)
        try await set(rig, .composerSetPrompt, "reply OK")
        _ = try await rig.registry.perform(.composerSubmit, .press)
        try await wait("terminal saved") { rig.env.sidebar.snapshot.terminals.contains { $0.launchSpec.initialPrompt == "reply OK" } }
        let terminal = try #require(rig.env.sidebar.snapshot.terminals.first { $0.launchSpec.initialPrompt == "reply OK" })
        #expect(terminal.provider == .claude && terminal.cwd.hasSuffix("/wt/acme-platform/reply-ok"))
        #expect(terminal.launchSpec.profileID != nil)
    }

    @Test func createMoreKeepsTheOverlayAndClearsThePrompt() async throws {
        let rig = try await makeRig()
        defer { Task { await finish(rig) } }
        _ = try await rig.registry.perform(.sessionNew, .press)
        try await set(rig, .composerCreateMore, "on")
        try await set(rig, .composerSetPrompt, "first task")
        _ = try await rig.registry.perform(.composerSubmit, .press)
        #expect(overlayOpen(rig), "Create More mantém o overlay aberto")
        let model = try #require(rig.env.composer?.model)
        #expect(model.draft.prompt.isEmpty && model.draft.provider == .claude && model.draft.createMore && model.draft.projectID == rig.project.id)
        try await set(rig, .composerSetPrompt, "second task")
        _ = try await rig.registry.perform(.composerSubmit, .press)
        try await wait("two sessions") { rig.env.sidebar.snapshot.sessions.filter { ["first task", "second task"].contains($0.title) }.count == 2 }
        #expect(rig.env.sidebar.snapshot.sessions.contains { $0.folderPath.hasSuffix("/second-task") })
    }

    // MARK: Where

    @Test func mainCheckoutAndExistingWorktreeReuseTheNotStartedSessions() async throws {
        let rig = try await makeRig()
        defer { Task { await finish(rig) } }
        let outside = rig.worktrees.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: rig.worktrees, withIntermediateDirectories: true)
        try ProjectsControllerTests.git(["worktree", "add", "-q", "-b", "outside", outside.path], in: rig.repo)
        _ = try await rig.env.registry.perform(.itemRefreshGit, .select(rig.project.id.uuidString))
        try await wait("worktree listed") { rig.env.sidebar.snapshot.worktrees.contains { $0.branch == "outside" } }
        let wt = try #require(rig.env.sidebar.snapshot.worktrees.first { $0.branch == "outside" })
        let before = rig.env.sidebar.snapshot.sessions.count

        _ = try await rig.registry.perform(.sessionNew, .press)
        try await select(rig, .composerSetAgent, "shell")
        try await select(rig, .composerSetWhere, "existingWorktree")
        let model = try #require(rig.env.composer?.model)
        #expect(model.worktrees.contains { $0.id == wt.id } && model.draft.worktreeID == wt.id, "escolhe a primeira worktree que não é a principal")
        _ = try await rig.registry.perform(.composerSubmit, .press)
        try await wait("terminal on the worktree") { rig.env.sidebar.snapshot.terminals.contains { $0.cwd == wt.path } }
        #expect(rig.env.sidebar.snapshot.sessions.count == before, "reaproveitou a sessão não iniciada")

        _ = try await rig.registry.perform(.sessionNew, .press)
        try await select(rig, .composerSetAgent, "shell")
        try await select(rig, .composerSetWhere, "mainCheckout")
        _ = try await rig.registry.perform(.composerSubmit, .press)
        try await wait("terminal on the main checkout") { rig.env.sidebar.snapshot.terminals.contains { $0.cwd == rig.repo.path } }
        #expect(rig.env.sidebar.snapshot.sessions.count == before, "o checkout principal também já tinha sessão não iniciada")
    }

    @Test func noProjectCreatesAManagedFolderWithAnAutomaticName() async throws {
        let rig = try await makeRig()
        defer { Task { await finish(rig) } }
        _ = try await rig.registry.perform(.sessionNew, .press)
        try await select(rig, .composerSetProject, "none")
        let model = try #require(rig.env.composer?.model)
        #expect(model.draft.whereChoice == .newFolder && model.whereOptions == [.newFolder, .chooseFolder])
        try await select(rig, .composerSetAgent, "shell")
        _ = try await rig.registry.perform(.composerSubmit, .press)
        try await wait("clean session") { rig.env.sidebar.snapshot.sessions.contains { $0.kind == .clean } }
        let clean = try #require(rig.env.sidebar.snapshot.sessions.first { $0.kind == .clean })
        #expect(clean.managedFolder && clean.folderPath.hasPrefix(rig.sessions.path + "/") && clean.projectID == nil)
        let name = URL(fileURLWithPath: clean.folderPath).lastPathComponent
        #expect(name.split(separator: "-").count == 2 && clean.title == name)
        #expect(FileManager.default.fileExists(atPath: clean.folderPath))
    }

    @Test func chooseFolderUsesTheFolderAsIsAndNeedsOneBeforeSubmitting() async throws {
        let rig = try await makeRig()
        defer { Task { await finish(rig) } }
        _ = try await rig.registry.perform(.sessionNew, .press)
        try await select(rig, .composerSetProject, "none")
        try await select(rig, .composerSetWhere, "chooseFolder")
        try await select(rig, .composerSetAgent, "shell")
        let model = try #require(rig.env.composer?.model)
        #expect(!model.canSubmit)
        await #expect(throws: Error.self) { _ = try await rig.registry.perform(.composerSubmit, .press) }
        let folder = rig.root.appendingPathComponent("mine", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        rig.picker.next = folder
        _ = try await rig.registry.perform(.composerChooseFolder, .press)
        #expect(model.draft.folderPath == folder.path && model.canSubmit)
        _ = try await rig.registry.perform(.composerSubmit, .press)
        try await wait("session on the chosen folder") { rig.env.sidebar.snapshot.sessions.contains { $0.folderPath == folder.path } }
        let session = try #require(rig.env.sidebar.snapshot.sessions.first { $0.folderPath == folder.path })
        #expect(!session.managedFolder && session.kind == .clean)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty, "o app não criou nada na pasta escolhida")
    }

    @Test func newCleanSessionCreatesAFolderWithoutAnyDialogAndInFolderUsesTheChosenOne() async throws {
        let rig = try await makeRig()
        defer { Task { await finish(rig) } }
        let started = try await rig.registry.perform(.sessionNewClean, .press)
        #expect(started.message != nil && !overlayOpen(rig), "sem diálogo (AC-1101)")
        try await wait("managed clean session") { rig.env.sidebar.snapshot.sessions.contains { $0.managedFolder && $0.kind == .clean } }
        let folder = rig.root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        rig.picker.next = folder
        _ = try await rig.registry.perform(.sessionNewCleanInFolder, .press)
        try await wait("session in chosen folder") { rig.env.sidebar.snapshot.sessions.contains { $0.folderPath == folder.path } }
    }

    // MARK: Create from, Advanced, erros

    @Test func createFromRecognizesAnExistingBranchAndReusesIt() async throws {
        let rig = try await makeRig()
        defer { Task { await finish(rig) } }
        try ProjectsControllerTests.git(["branch", "release"], in: rig.repo)
        _ = try await rig.registry.perform(.sessionNew, .press)
        try await select(rig, .composerSetAgent, "shell")
        try await set(rig, .composerSetBase, "nope")
        let model = try #require(rig.env.composer?.model)
        try await wait("lookup finished") { model.createFromLookup == GitBranchLookup.none }
        #expect(!model.canSubmit && model.issue(for: .createFrom)?.message.contains("No branch named") == true)
        try await set(rig, .composerSetBase, "release")
        try await wait("branch found") { model.createFromLookup == .local }
        #expect(model.canSubmit && model.draft.reuseBranch)
        _ = try await rig.registry.perform(.composerSubmit, .press)
        try await wait("worktree on release") { rig.env.sidebar.snapshot.worktrees.contains { $0.branch == "release" } }
    }

    @Test func advancedBranchThatExistsShowsReuseItAndFailureOffersUseExistingBranch() async throws {
        let rig = try await makeRig()
        defer { Task { await finish(rig) } }
        try ProjectsControllerTests.git(["branch", "taken"], in: rig.repo)
        _ = try await rig.registry.perform(.sessionNew, .press)
        try await select(rig, .composerSetAgent, "shell")
        _ = try await rig.registry.perform(.composerToggleAdvanced, .press)
        try await set(rig, .composerSetBranchName, "taken")
        let model = try #require(rig.env.composer?.model)
        try await wait("existing branch error") { model.boxIssue?.recovery == .reuseBranch }
        #expect(model.boxIssue?.message == "Branch \"taken\" already exists.")
        _ = try await rig.registry.perform(.composerReuseBranch, .press)
        #expect(model.draft.createFrom == "taken" && model.draft.branchName.isEmpty)

        // Sem a checagem prévia (corrida), o erro chega pela linha pendente com as ações alternativas.
        try await set(rig, .composerSetBase, "")
        model.draft.branchName = "taken"
        let submit = try await rig.registry.perform(.composerSubmit, .press)
        let pendingID = try #require(submit.message.flatMap(UUID.init(uuidString:)))
        try await wait("pending failed") { rig.env.sidebar.pending(pendingID)?.failure != nil }
        let failed = try #require(rig.env.sidebar.pending(pendingID))
        #expect(failed.failure == "Couldn't create worktree" && failed.detail == "Branch \"taken\" already exists.")
        #expect(failed.recoveries.contains(.useExistingBranch("taken")) && rig.env.sidebar.focusedPending == pendingID)
        _ = try await rig.registry.perform(.sessionUseExistingBranch, .select(pendingID.uuidString))
        try await wait("worktree on taken") { rig.env.sidebar.snapshot.worktrees.contains { $0.branch == "taken" } }
        try await wait("pending selected the session") { rig.env.sidebar.focusedPending == nil }
    }

    @Test func failedFetchOffersCreateWithoutFetchingAndTryAgainRetries() async throws {
        let rig = try await makeRig()
        defer { Task { await finish(rig) } }
        try ProjectsControllerTests.git(["remote", "set-url", "origin", rig.root.appendingPathComponent("gone.git").path], in: rig.repo)
        _ = try await rig.registry.perform(.sessionNew, .press)
        try await set(rig, .composerSetPrompt, "offline work")
        let submit = try await rig.registry.perform(.composerSubmit, .press)
        let pendingID = try #require(submit.message.flatMap(UUID.init(uuidString:)))
        try await wait("fetch failed") { rig.env.sidebar.pending(pendingID)?.failure == "Couldn't fetch origin" }
        #expect(rig.env.sidebar.pending(pendingID)?.recoveries.contains(.createWithoutFetching) == true)
        _ = try await rig.registry.perform(.sessionRetryLaunch, .select(pendingID.uuidString))
        try await wait("failed again") { rig.env.sidebar.pending(pendingID)?.failure == "Couldn't fetch origin" }
        _ = try await rig.registry.perform(.sessionCreateWithoutFetch, .select(pendingID.uuidString))
        try await wait("created without fetching") { rig.env.sidebar.snapshot.worktrees.contains { $0.branch == "me/offline-work" } }
    }

    @Test func discardingAFailedPendingRemovesItAndLeavesNoSession() async throws {
        let rig = try await makeRig()
        defer { Task { await finish(rig) } }
        try ProjectsControllerTests.git(["remote", "set-url", "origin", rig.root.appendingPathComponent("gone.git").path], in: rig.repo)
        _ = try await rig.registry.perform(.sessionNew, .press)
        try await set(rig, .composerSetPrompt, "will fail")
        let submit = try await rig.registry.perform(.composerSubmit, .press)
        let pendingID = try #require(submit.message.flatMap(UUID.init(uuidString:)))
        try await wait("failed") { rig.env.sidebar.pending(pendingID)?.failure != nil }
        _ = try await rig.registry.perform(.sessionDiscardPending, .select(pendingID.uuidString))
        #expect(rig.env.sidebar.pending(pendingID) == nil && rig.env.sidebar.focusedPending == nil)
        #expect(!rig.env.sidebar.snapshot.sessions.contains { $0.title == "will fail" })
    }

    // MARK: Teclado

    @Test func escapeWithTextAsksToDiscardInlineAndWithoutTextClosesAtOnce() async throws {
        let rig = try await makeRig()
        defer { Task { await finish(rig) } }
        _ = try await rig.registry.perform(.sessionNew, .press)
        _ = try await rig.registry.perform(.composerCancel, .press)
        try await wait("closed") { !overlayOpen(rig) }

        _ = try await rig.registry.perform(.sessionNew, .press)
        try await set(rig, .composerSetPrompt, "something typed")
        let model = try #require(rig.env.composer?.model)
        #expect(!(rig.env.overlays.top?.spec.dismissOnScrim() ?? true), "com dados, o clique no scrim não fecha")
        #expect(try await rig.registry.perform(.composerCancel, .press).message == "confirming" && model.confirmingDiscard && overlayOpen(rig))
        _ = try await rig.registry.perform(.composerKeepEditing, .press)
        #expect(!model.confirmingDiscard && overlayOpen(rig) && model.draft.prompt == "something typed")
        _ = try await rig.registry.perform(.composerCancel, .press)
        _ = try await rig.registry.perform(.composerDiscard, .press)
        try await wait("discarded") { !overlayOpen(rig) }
        #expect(rig.env.sidebar.snapshot.sessions.filter { $0.title.contains("something") }.isEmpty)
    }

    @Test func projectPlusPreselectsThatProject() async throws {
        let rig = try await makeRig()
        defer { Task { await finish(rig) } }
        let result = try await rig.registry.perform(.projectNewSession, .select(rig.project.id.uuidString))
        #expect(result.message == "opened")
        #expect(rig.env.composer?.model?.draft.projectID == rig.project.id && rig.env.composer?.model?.draft.whereChoice == .newWorktree)
    }

    @Test func summaryLineMirrorsTheCommandAndTheDestination() async throws {
        let rig = try await makeRig()
        defer { Task { await finish(rig) } }
        _ = try await rig.registry.perform(.sessionNew, .press)
        try await set(rig, .composerSetPrompt, "Fix the search pagination")
        let model = try #require(rig.env.composer?.model)
        try await wait("prefix known") { model.branchPrefix == "me" }
        let text = model.summary
        #expect(text.hasPrefix("claude ") && text.contains("\"Fix the search pagination\""))
        #expect(text.hasSuffix("/wt/acme-platform/fix-the-search-pagination"))
        #expect(model.draft.defaultBranchName(model.context) == "me/fix-the-search-pagination")
    }
}
