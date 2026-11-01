import RackyCore
import RackyDesignSystem
import RackyPlatform
import RackyProtocol
import RackyStore
import AppKit
import Foundation
import SnapshotTesting
import SwiftUI
import Testing

@testable import RackyUI

// MARK: Modelo do painel (sem janela)

private func repo(_ owner: String, _ name: String, private isPrivate: Bool = false, language: String? = nil, pushed: Date? = nil) -> GitHubRepository {
    GitHubRepository(owner: owner, name: name, isPrivate: isPrivate, language: language, summary: "desc of \(name)", pushedAt: pushed, updatedAt: pushed)
}

@MainActor
@Suite(.serialized, .offscreenAppKit) struct CloneRepoModelTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    func model() -> CloneRepoModel {
        let model = CloneRepoModel()
        model.now = { Self.now }
        model.setRepositories([
            repo("acme", "platform", private: true, language: "TypeScript", pushed: Self.now.addingTimeInterval(-3 * 86_400)),
            repo("me", "hello-tool", language: "Swift", pushed: Self.now.addingTimeInterval(-40 * 86_400)),
            repo("me", "notes", pushed: Self.now.addingTimeInterval(-400 * 86_400)),
        ])
        model.listing = .ready
        return model
    }

    @Test func emptyFieldListsRecentRepositoriesAndSelectsTheFirst() {
        let model = model()
        #expect(model.rows.map(\.id) == ["acme/platform", "me/hello-tool", "me/notes"])
        #expect(model.selectedID == "acme/platform" && model.sectionTitle == "Recent repositories")
        #expect(model.submitReference?.displayName == "acme/platform")
    }

    @Test func typingFiltersByKeyboardAndKeepsTheBestMatchSelected() {
        let model = model()
        model.setSource("hello")
        #expect(model.rows.map(\.id) == ["me/hello-tool"] && model.selectedID == "me/hello-tool")
        #expect(model.sectionTitle == "Results")
        model.setSource("swift")
        #expect(model.rows.map(\.id) == ["me/hello-tool"], "a linguagem também busca")
        model.setSource("nothing-like-this")
        #expect(model.rows.isEmpty && model.selectedID == nil && model.submitReference == nil)
    }

    @Test func aValidReferenceBecomesTheFirstRowAndWins() {
        let model = model()
        model.setSource("octocat/Hello-World")
        let first = model.rows.first
        #expect(first?.id.hasPrefix("typed:") == true && model.selectedID == first?.id)
        #expect(model.submitReference?.cloneURL == "https://github.com/octocat/Hello-World.git")
        model.setSource("https://github.com/me/notes")
        #expect(model.submitReference?.displayName == "me/notes")
        model.setSource("git@github.com:me/notes.git")
        #expect(model.submitReference?.isGitHub == true && model.submitReference?.usesHTTPS == false)
    }

    @Test func arrowKeysMoveAndClampTheSelection() {
        let model = model()
        model.move(1)
        #expect(model.selectedID == "me/hello-tool")
        model.move(1); model.move(1); model.move(1)
        #expect(model.selectedID == "me/notes", "não passa do fim")
        model.move(-5)
        #expect(model.selectedID == "acme/platform")
        model.select("me/notes")
        #expect(model.selectedID == "me/notes")
        model.select("nope/nope")
        #expect(model.selectedID == "me/notes")
        // Atualizar a lista (cache e depois rede) não tira a seleção do usuário.
        model.setRepositories(model.repositories)
        #expect(model.selectedID == "me/notes")
    }

    @Test func updatedTextIsRelativeToTheLastPush() {
        let model = model()
        #expect(model.updatedText(for: model.repositories[0]) == "Updated 3 days ago")
        #expect(model.updatedText(for: GitHubRepository(owner: "a", name: "b")) == nil)
    }

    @Test func cloningAndFailureStatesFollowTheProgress() throws {
        let model = model()
        let ref = try #require(RepoReferenceParser.parse("octocat/Hello-World"))
        model.beginCloning(ref)
        #expect(model.isCloning && model.cloningName == "octocat/Hello-World" && model.progress?.phase == .starting)
        model.update(CloneProgress(phase: .receiving, percent: 40))
        #expect(model.progress?.text == "Receiving objects 40%")
        model.fail("Repository not found. If it is private, log in to GitHub.")
        #expect(model.phase == .failed("Repository not found. If it is private, log in to GitHub.") && model.progress == nil)
        model.setSource("x")
        #expect(model.phase == .browsing, "digitar de novo limpa o erro")
    }

    @Test func listingErrorsMapToLoginInstallOrAMessage() {
        #expect(CloneRepoModel.listingMessage(for: GitHubError.ghNotInstalled) == .ghMissing)
        #expect(CloneRepoModel.listingMessage(for: GitHubError.notAuthenticated(host: "github.com")) == .loggedOut)
        #expect(CloneRepoModel.listingMessage(for: GitHubError.timedOut) == .failed("GitHub took too long to answer."))
    }
}

// MARK: Fluxo real: overlay, ações do registro, Store e git local

/// Clonador de mentira que clona de verdade um repositório local (sem rede): troca a URL do GitHub pela origem local, emite
/// progresso e pode ficar parado até o teste abrir o portão (para ver a linha pendente e o cancelamento).
final class LocalCloneRunner: GitCloneRunning, @unchecked Sendable { // SAFETY: estado protegido por `lock`.
    private let lock = NSLock()
    private let origin: URL
    private var _open: Bool
    private var _failures: [String]
    private var _calls = 0
    private var _destinations: [URL] = []
    init(origin: URL, gated: Bool = false, failures: [String] = []) {
        self.origin = origin
        _open = !gated
        _failures = failures
    }
    func openGate() { lock.withLock { _open = true } }
    var calls: Int { lock.withLock { _calls } }
    var destinations: [URL] { lock.withLock { _destinations } }

    func clone(arguments: [String], environment: [String: String], onStderr: @escaping @Sendable (String) -> Void) async throws -> GitCommandResult {
        let failure: String? = lock.withLock {
            _calls += 1
            return _failures.isEmpty ? nil : _failures.removeFirst()
        }
        let destination = URL(fileURLWithPath: arguments[arguments.count - 1], isDirectory: true)
        lock.withLock { _destinations.append(destination) }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        onStderr("Cloning into '\(destination.lastPathComponent)'...\nReceiving objects:  50% (1/2)\r")
        while !lock.withLock({ _open }) { try await Task.sleep(for: .milliseconds(10)) }
        if let failure { return GitCommandResult(exitCode: 128, stdout: "", stderr: failure) }
        var args = arguments
        if let dash = args.firstIndex(of: "--") { args[dash + 1] = origin.path }
        // Pasta pré-criada vazia: o git real aceita clonar nela.
        return try await GitCloneProcessRunner().clone(arguments: args, environment: environment, onStderr: onStderr)
    }
}

/// `gh` de mentira: responde por closure; nunca executa processo.
struct FakeGH: GitHubCommandRunning {
    let handler: @Sendable ([String]) -> GitCommandResult
    func run(_ arguments: [String], in directory: URL?, timeout: Duration) async throws -> GitCommandResult { handler(arguments) }
}

@MainActor
@Suite(.serialized, .offscreenAppKit) struct CloneRepoFlowTests {
    struct Rig {
        let env: AppEnvironment
        let root: URL
        let origin: URL
        let runner: LocalCloneRunner
        let projectsRoot: URL
        var controller: CloneRepoController { env.cloneRepo! }
        var registry: ActionRegistry { env.registry }
    }

    static let accountRepos = """
    [{"name":"Hello-World","owner":{"login":"octocat"},"isPrivate":false,"primaryLanguage":{"name":"Ruby"},"pushedAt":"2025-09-01T00:00:00Z","updatedAt":"2025-09-01T00:00:00Z","description":"My first repo"},
     {"name":"platform","owner":{"login":"acme"},"isPrivate":true,"primaryLanguage":{"name":"Go"},"pushedAt":"2025-10-01T00:00:00Z","updatedAt":"2025-10-01T00:00:00Z","description":null}]
    """

    func makeRig(gated: Bool = false, failures: [String] = [], loggedIn: Bool = true) async throws -> Rig {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("racky-clone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("home"), withIntermediateDirectories: true)
        let resolved = try #require(realpath(base.path, nil))
        defer { free(resolved) }
        let root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        let origin = root.appendingPathComponent("origin-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        try ProjectsControllerTests.git(["init", "-q", "-b", "main"], in: origin)
        try "hi\n".write(to: origin.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try ProjectsControllerTests.git(["add", "."], in: origin)
        try ProjectsControllerTests.git(["commit", "-q", "-m", "init"], in: origin)

        let env = AppEnvironment(environment: ["RACKY_HOME": root.appendingPathComponent("home").path, "RACKY_SKIP_ONBOARDING": "1"])
        await env.start()
        let projectsRoot = root.appendingPathComponent("projects", isDirectory: true)
        _ = try await env.registry.perform(.settingsGeneralProjectsFolder, .set(projectsRoot.path))
        let controller = try #require(env.cloneRepo)
        let account = Self.accountRepos
        controller.catalog = GitHubRepoCatalog(
            runner: FakeGH { args in
                guard loggedIn else {
                    return GitCommandResult(exitCode: 4, stdout: "", stderr: "To get started with GitHub CLI, please run:  gh auth login")
                }
                if args.first == "api" { return GitCommandResult(exitCode: 0, stdout: "", stderr: "") }
                return GitCommandResult(exitCode: 0, stdout: account, stderr: "")
            })
        let runner = LocalCloneRunner(origin: origin, gated: gated, failures: failures)
        controller.clonerFactory = { register in RepoCloner(runner: runner, git: GitService(), ghExecutable: nil, register: register) }
        return Rig(env: env, root: root, origin: origin, runner: runner, projectsRoot: projectsRoot)
    }

    func finish(_ rig: Rig) async {
        await rig.env.stop()
        try? FileManager.default.removeItem(at: rig.root)
    }

    func wait(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(25)) }
        #expect(condition(), "\(what)")
    }

    /// Depois do clone o composer abre com o projeto clonado escolhido (o próximo passo é a sessão nele); o teste o fecha.
    func expectComposerOnClonedProject(_ rig: Rig, named name: String) async throws {
        try await wait("composer opens on the cloned project") {
            guard let composer = rig.env.composer, let id = composer.model?.draft.projectID else { return false }
            return rig.env.sidebar.project(id)?.name == name
        }
        _ = try await rig.registry.perform(.composerCancel, .press)
        try await wait("composer closed") { rig.env.overlays.live.isEmpty }
    }

    func openPanel(_ rig: Rig) async throws -> CloneRepoModel {
        let result = try await rig.registry.perform(.projectCloneFromGitHub, .press)
        #expect(result.message == "opened" && rig.controller.isOpen && rig.env.overlays.top?.spec.id == .overlayCloneRepo)
        let model = try #require(rig.controller.model)
        try await wait("repositories loaded") { model.listing == .ready && model.rows.count == 2 }
        return model
    }

    @Test func panelListsAccountRepositoriesNewestFirstAndEnterClonesTheSelectedOne() async throws {
        let rig = try await makeRig(gated: true)
        defer { Task { await finish(rig) } }
        var cloned: [Project] = []
        rig.controller.onCloned = { cloned.append($0) }
        let model = try await openPanel(rig)
        #expect(model.rows.map(\.id) == ["acme/platform", "octocat/Hello-World"], "mais recente primeiro")
        _ = try await rig.registry.perform(.dialogCloneRepoSetSource, .set("hello"))
        #expect(model.rows.map(\.id) == ["octocat/Hello-World"] && model.selectedID == "octocat/Hello-World")

        let submit = try await rig.registry.perform(.dialogCloneRepoSubmit, .press)
        let pendingID = try #require(submit.message.flatMap(UUID.init(uuidString:)))
        #expect(model.isCloning && rig.env.overlays.top?.spec.id == .overlayCloneRepo, "o progresso fica no próprio painel")
        let pending = try #require(rig.env.sidebar.pending(pendingID))
        #expect(pending.isClone && pending.name == "Hello-World")
        try await wait("progress on the pending row") { rig.env.sidebar.pending(pendingID)?.phaseText == "Cloning… 50%" }
        #expect(model.progress == CloneProgress(phase: .receiving, percent: 50))
        let row = try #require(rig.env.sidebar.projection.cleanPending.first { $0.id == pendingID })
        #expect(row.phaseText == "Cloning… 50%" && !row.failed)

        rig.runner.openGate()
        try await wait("overlay closed") { rig.env.overlays.live.isEmpty }
        try await wait("pending row gone") { rig.env.sidebar.pending(pendingID) == nil }
        let project = try #require(cloned.first)
        #expect(project.name == "Hello-World" && project.rootPath == rig.projectsRoot.appendingPathComponent("Hello-World").path)
        #expect(FileManager.default.fileExists(atPath: rig.projectsRoot.appendingPathComponent("Hello-World/README.md").path))
        try await wait("project in sidebar") { rig.env.sidebar.project(project.id) != nil }
        #expect(rig.controller.model == nil)
    }

    @Test func cloneFromTheComposerComboboxSelectsTheNewProjectAndKeepsWhatWasTyped() async throws {
        let rig = try await makeRig()
        defer { Task { await finish(rig) } }
        _ = try await rig.registry.perform(.sessionNew, .press)
        let composer = try #require(rig.env.composer?.model)
        #expect(composer.projectEntries.contains { $0.item?.id == "clone" && $0.item?.action == .projectCloneFromGitHub && $0.item?.pinned == true })
        _ = try await rig.registry.perform(.composerSetPrompt, .set("fix the pagination"))

        _ = try await rig.registry.perform(.projectCloneFromGitHub, .press)
        #expect(rig.env.overlays.live.count == 2, "sub-overlay sobre o composer")
        let model = try #require(rig.controller.model)
        try await wait("repositories loaded") { model.listing == .ready && model.rows.count == 2 }
        _ = try await rig.registry.perform(.dialogCloneRepoSelect, .select("octocat/Hello-World"))
        _ = try await rig.registry.perform(.dialogCloneRepoSubmit, .press)
        try await wait("clone panel closed") { rig.env.overlays.live.count == 1 }
        #expect(rig.env.overlays.top?.spec.name == "composer")
        try await wait("project selected in the composer") {
            composer.draft.projectID.flatMap { rig.env.sidebar.project($0)?.name } == "Hello-World"
        }
        #expect(composer.draft.prompt == "fix the pagination", "o composer mantém o que foi digitado")
    }

    @Test func cancellingFromTheSidebarStopsTheCloneAndRemovesThePartialFolder() async throws {
        let rig = try await makeRig(gated: true)
        defer { Task { await finish(rig) } }
        let model = try await openPanel(rig)
        _ = try await rig.registry.perform(.dialogCloneRepoSubmit, .press)
        let pendingID = try #require(rig.env.sidebar.pending.first?.id)
        try await wait("partial folder exists") { !rig.runner.destinations.isEmpty }
        let partial = try #require(rig.runner.destinations.first)
        #expect(FileManager.default.fileExists(atPath: partial.path))

        #expect(rig.env.sidebar.cancel(pending: pendingID))
        try await wait("partial folder removed") { !FileManager.default.fileExists(atPath: partial.path) }
        #expect(rig.env.sidebar.pending.isEmpty && model.phase == .browsing && rig.controller.isOpen, "o painel volta à lista")
        #expect(rig.env.sidebar.snapshot.projects.isEmpty)
    }

    @Test func cancelActionDuringCloneClosesThePanelAndCleansUp() async throws {
        let rig = try await makeRig(gated: true)
        defer { Task { await finish(rig) } }
        _ = try await openPanel(rig)
        _ = try await rig.registry.perform(.dialogCloneRepoSubmit, .press)
        try await wait("partial folder exists") { !rig.runner.destinations.isEmpty }
        let partial = try #require(rig.runner.destinations.first)
        _ = try await rig.registry.perform(.dialogCloneRepoCancel, .press)
        try await wait("overlay closed") { rig.env.overlays.live.isEmpty }
        try await wait("partial folder removed") { !FileManager.default.fileExists(atPath: partial.path) }
        #expect(rig.env.sidebar.pending.isEmpty && rig.controller.model == nil)
    }

    @Test func failureShowsAClearMessageInThePanelAndRetryWorks() async throws {
        let rig = try await makeRig(failures: ["remote: Repository not found.\nfatal: repository 'https://github.com/acme/platform.git/' not found"])
        defer { Task { await finish(rig) } }
        let model = try await openPanel(rig)
        _ = try await rig.registry.perform(.dialogCloneRepoSubmit, .press)
        try await wait("error shown") { if case .failed = model.phase { true } else { false } }
        #expect(model.phase == .failed("Repository not found. If it is private, log in to GitHub."))
        #expect(rig.env.sidebar.pending.isEmpty, "a linha pendente some no erro")
        #expect(rig.controller.isOpen)

        let retry = try await rig.registry.perform(.dialogCloneRepoRetry, .press)
        #expect(retry.message.flatMap(UUID.init(uuidString:)) != nil)
        try await wait("project in sidebar") { rig.env.sidebar.snapshot.projects.contains { $0.name == "platform" } }
        try await expectComposerOnClonedProject(rig, named: "platform")
        #expect(rig.runner.calls == 2)
    }

    @Test func withoutGhLoginThePanelOffersLoginAndStillClonesAPublicURL() async throws {
        let rig = try await makeRig(loggedIn: false)
        defer { Task { await finish(rig) } }
        _ = try await rig.registry.perform(.projectCloneFromGitHub, .press)
        let model = try #require(rig.controller.model)
        try await wait("logged out detected") { model.listing == .loggedOut }
        #expect(model.rows.isEmpty)

        // O login abre uma tab com `gh auth login`.
        var argv: [String]?
        rig.controller.ghExecutable = URL(fileURLWithPath: "/opt/homebrew/bin/gh")
        rig.controller.canOpenLoginTerminal = { false }
        #expect(rig.registry.availability(of: .dialogCloneRepoLogIn) == .disabled(reason: "Select a session first."))
        rig.controller.canOpenLoginTerminal = { true }
        rig.controller.openLoginTerminal = { argv = $0; return true }
        #expect(rig.registry.availability(of: .dialogCloneRepoLogIn) == .enabled)

        // URL pública continua funcionando sem login.
        _ = try await rig.registry.perform(.dialogCloneRepoSetSource, .set("https://github.com/octocat/Hello-World"))
        #expect(model.submitReference?.displayName == "octocat/Hello-World")
        _ = try await rig.registry.perform(.dialogCloneRepoSubmit, .press)
        try await wait("project in sidebar") { rig.env.sidebar.snapshot.projects.contains { $0.name == "Hello-World" } }
        try await expectComposerOnClonedProject(rig, named: "Hello-World")
        #expect(argv == nil)

        _ = try await rig.registry.perform(.projectCloneFromGitHub, .press)
        _ = try await rig.registry.perform(.dialogCloneRepoLogIn, .press)
        #expect(argv == ["/opt/homebrew/bin/gh", "auth", "login"])
        #expect(rig.env.overlays.live.isEmpty, "o painel fecha para a tab aparecer")
    }

    @Test func submitWithNothingToCloneIsDisabledWithTheReason() async throws {
        let rig = try await makeRig(loggedIn: false)
        defer { Task { await finish(rig) } }
        _ = try await rig.registry.perform(.projectCloneFromGitHub, .press)
        let model = try #require(rig.controller.model)
        try await wait("logged out detected") { model.listing == .loggedOut }
        #expect(rig.registry.availability(of: .dialogCloneRepoSubmit) == .disabled(reason: "Choose a repository or paste a URL."))
        await #expect(throws: (any Error).self) { _ = try await rig.registry.perform(.dialogCloneRepoSubmit, .press) }
        _ = try await rig.registry.perform(.dialogCloneRepoSetSource, .set("-c core.sshCommand=evil"))
        #expect(model.submitReference == nil, "texto que parece opção do git não é aceito")
        _ = try await rig.registry.perform(.dialogCloneRepoSetSource, .set("octocat/Hello-World"))
        #expect(rig.registry.availability(of: .dialogCloneRepoSubmit) == .enabled)
    }

    @Test func existingFolderOfTheSameRepositoryIsOpenedAsProjectWithoutCloning() async throws {
        let rig = try await makeRig()
        defer { Task { await finish(rig) } }
        // `Hello-World` já clonado antes (mesmo remote).
        let existing = rig.projectsRoot.appendingPathComponent("Hello-World", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try ProjectsControllerTests.git(["init", "-q", "-b", "main"], in: existing)
        try "x\n".write(to: existing.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try ProjectsControllerTests.git(["add", "."], in: existing)
        try ProjectsControllerTests.git(["commit", "-q", "-m", "init"], in: existing)
        try ProjectsControllerTests.git(["remote", "add", "origin", "https://github.com/octocat/Hello-World.git"], in: existing)
        var cloned: [Project] = []
        rig.controller.onCloned = { cloned.append($0) }

        _ = try await openPanel(rig)
        _ = try await rig.registry.perform(.dialogCloneRepoSelect, .select("octocat/Hello-World"))
        _ = try await rig.registry.perform(.dialogCloneRepoSubmit, .press)
        try await wait("opened") { rig.env.overlays.live.isEmpty && !cloned.isEmpty }
        #expect(rig.runner.calls == 0, "não clona por cima")
        #expect(cloned.first?.rootPath == existing.path)
    }

    @Test func projectsFolderSettingDefaultsAndValidates() async throws {
        let rig = try await makeRig()
        defer { Task { await finish(rig) } }
        #expect(AppSettings().general.projectsFolder == "~/Racky/projects")
        await #expect(throws: (any Error).self) { _ = try await rig.registry.perform(.settingsGeneralProjectsFolder, .set("relative/path")) }
        let custom = rig.root.appendingPathComponent("elsewhere").path
        _ = try await rig.registry.perform(.settingsGeneralProjectsFolder, .set(custom))
        #expect(rig.env.settings.settings.general.projectsFolder == custom)
        #expect(CleanSessionPaths.projectsRoot(configured: "~/Racky/projects", isolatedHome: rig.root).path == rig.root.appendingPathComponent("Racky/projects").path)
        #expect(CleanSessionPaths.projectsRoot(configured: custom, isolatedHome: rig.root).path == custom)
    }

    @Test func entryPointsAreOffered() async throws {
        let rig = try await makeRig()
        defer { Task { await finish(rig) } }
        #expect(rig.registry.isOffered(.projectCloneFromGitHub))
        for id in [ActionID.dialogCloneRepoSetSource, .dialogCloneRepoSelect, .dialogCloneRepoSubmit, .dialogCloneRepoCancel, .dialogCloneRepoLogIn, .dialogCloneRepoRetry] {
            #expect(rig.registry.isOffered(id), "\(id.rawValue)")
        }
    }
}

// MARK: Snapshots do painel

@MainActor
@Suite(.serialized, .offscreenAppKit) struct CloneRepoSnapshotTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    func model(_ listing: CloneRepoModel.Listing = .ready) -> CloneRepoModel {
        let model = CloneRepoModel()
        model.now = { Self.now }
        model.setRepositories([
            repo("acme", "platform", private: true, language: "TypeScript", pushed: Self.now.addingTimeInterval(-3_600)),
            repo("octocat", "Hello-World", language: "Ruby", pushed: Self.now.addingTimeInterval(-3 * 86_400)),
            repo("me", "racky", private: true, language: "Swift", pushed: Self.now.addingTimeInterval(-9 * 86_400)),
            repo("me", "dotfiles", pushed: Self.now.addingTimeInterval(-120 * 86_400)),
        ])
        model.listing = listing
        return model
    }

    func snap(_ model: CloneRepoModel, name: String, height: CGFloat, line: UInt = #line) {
        DSFonts.registerIfNeeded()
        let env = ComponentSnapshotTests.env()
        for id in [ActionID.dialogCloneRepoSetSource, .dialogCloneRepoSelect, .dialogCloneRepoSubmit, .dialogCloneRepoCancel, .dialogCloneRepoLogIn, .dialogCloneRepoRetry] {
            try? env.registry.register(id) { _ in nil }
        }
        let size = CGSize(width: DS.Layout.dialogWidth + DS.Space.s8, height: height)
        let root = CloneRepoView(model: model, submit: {})
            .frame(width: DS.Layout.dialogWidth)
            .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Color.overlayCard))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Color.borderStrong))
            .environment(\.actionRegistry, env.registry)
            .environment(\.elementStore, env.elements)
            .padding(DS.Space.s4)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(DS.Color.chrome)
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        withSnapshotTesting(record: ComponentSnapshotTests.recording) {
            assertSnapshot(of: host, as: .image(precision: 0.98, perceptualPrecision: 0.97), named: name, testName: "clone", line: line)
        }
    }

    @Test func recentRepositories() { snap(model(), name: "recentRepositories", height: 480) }

    @Test func searchWithATypedReference() {
        let model = model()
        model.setSource("octocat/Hello")
        snap(model, name: "searchWithATypedReference", height: 340)
    }

    @Test func loggedOutStillAcceptsAPublicURL() {
        let model = CloneRepoModel()
        model.listing = .loggedOut
        model.setSource("https://github.com/octocat/Hello-World")
        snap(model, name: "loggedOut", height: 400)
    }

    @Test func ghMissing() {
        let model = CloneRepoModel()
        model.listing = .ghMissing
        snap(model, name: "ghMissing", height: 320)
    }

    @Test func cloningProgress() throws {
        let model = model()
        model.beginCloning(try #require(RepoReferenceParser.parse("octocat/Hello-World")))
        model.update(CloneProgress(phase: .receiving, percent: 42))
        snap(model, name: "cloningProgress", height: 260)
    }

    @Test func failure() {
        let model = model()
        model.fail("Repository not found. If it is private, log in to GitHub.")
        snap(model, name: "failure", height: 560)
    }
}
