import RackyProtocol
import RackyStore
import Foundation
import Testing
@testable import RackyCore

/// Criação de sessão com repositório temporário e Store real em pasta temporária (nada do usuário é tocado).
struct CreationHarness {
    let sandbox: GitSandbox
    let store: RackyStore
    let projects: ProjectService
    let service: SessionCreationService
    let worktreeRoot: URL
    let repo: URL
    let project: Project

    init(withOrigin: Bool = true) async throws {
        sandbox = try GitSandbox()
        let home = try sandbox.dir("racky-home")
        store = try await RackyStore.open(paths: StorePaths(root: home))
        worktreeRoot = sandbox.root.appendingPathComponent("wt", isDirectory: true)
        projects = ProjectService(store: store, git: sandbox.service, worktreeBase: worktreeRoot)
        service = SessionCreationService(store: store, git: sandbox.service)
        repo = withOrigin ? try await sandbox.makeRepoWithOrigin("acme-platform").repo : try await sandbox.makeRepo("acme-platform")
        project = try await projects.addProject(folder: repo).project
    }

    func newWorktree(
        _ source: GitWorktreeSource, fetch: GitFetchPolicy = .fetchFirst, title: String = "t", spec: LaunchSpec = LaunchSpec(provider: .shell)
    ) -> SessionCreationRequest {
        SessionCreationRequest(
            title: title, target: .newWorktree(NewWorktreeSpec(projectID: project.id, source: source, worktreeRoot: worktreeRoot, fetch: fetch)), spec: spec)
    }
}

@Suite struct SessionCreationTests {
    @Test func newWorktreeFetchesCreatesTheCheckoutAndSavesSessionTabAndTerminal() async throws {
        let h = try await CreationHarness()
        let phases = PhaseLog()
        let spec = LaunchSpec(provider: .claude, initialPrompt: "reply OK")
        let output = try await h.service.create(
            h.newWorktree(.newBranch(slug: "fix-search-pagination", prefix: .custom("me"), baseRef: nil), title: "fix search pagination", spec: spec),
            progress: { phases.add($0) })

        let expectedPath = h.worktreeRoot.canonicalPath.appendingPathComponent("acme-platform/fix-search-pagination").path
        #expect(output.session.folderPath == expectedPath && output.session.kind == .worktree && !output.adoptedExisting)
        #expect(output.worktree?.branch == "me/fix-search-pagination" && output.worktree?.createdByApp == true)
        #expect(FileManager.default.fileExists(atPath: expectedPath + "/README.md"))
        #expect(phases.all == [.preparing, .fetching, .creatingWorktree])
        #expect(output.terminal.cwd == expectedPath && output.terminal.launchSpec.initialPrompt == "reply OK" && output.terminal.state == .notStarted)
        #expect(output.terminal.title == "Claude Code")

        #expect(try await h.sandbox.git(["rev-parse", "--abbrev-ref", "HEAD"], in: URL(fileURLWithPath: expectedPath)) == "me/fix-search-pagination")
        let stored = try await h.store.session(id: output.session.id)
        #expect(stored?.title == "fix search pagination" && stored?.worktreeID == output.worktree?.id)
        #expect(try await h.store.tabs(sessionID: output.session.id).map(\.id) == [output.tab.id])
        #expect(try await h.store.terminal(id: output.terminal.id)?.tabID == output.tab.id)
    }

    @Test func collidingNamesGetASuffixAndTheUserRepoIsNeverTouched() async throws {
        let h = try await CreationHarness()
        let source = GitWorktreeSource.newBranch(slug: "same", prefix: .custom("me"), baseRef: nil)
        let first = try await h.service.create(h.newWorktree(source))
        let second = try await h.service.create(h.newWorktree(source))
        #expect(first.session.folderPath.hasSuffix("/acme-platform/same") && second.session.folderPath.hasSuffix("/acme-platform/same-2"))
        #expect(second.worktree?.branch == "me/same-2")
        #expect(try await h.sandbox.git(["status", "--porcelain"], in: h.repo).isEmpty)
    }

    @Test func afterASyncAlreadyListedTheWorktreeTheNotStartedSessionIsAdopted() async throws {
        let h = try await CreationHarness()
        let before = try await h.service.create(h.newWorktree(.newBranch(slug: "a", prefix: .none, baseRef: nil)))
        // O sync vê a worktree nova; como a sessão já tem tab, não cria outra e não perde nada.
        _ = try await h.projects.syncWorktrees(projectID: h.project.id)
        let sessions = try await h.store.sessions().filter { $0.projectID == h.project.id }
        #expect(sessions.filter { $0.worktreeID == before.worktree?.id }.count == 1)

        // Worktree criada fora do app: o sync gera a sessão "não iniciada"; criar nela reaproveita a mesma sessão.
        let outside = h.worktreeRoot.appendingPathComponent("outside", isDirectory: true)
        try await h.sandbox.git(["worktree", "add", "-q", "-b", "outside", outside.path], in: h.repo)
        _ = try await h.projects.syncWorktrees(projectID: h.project.id)
        let notStarted = try #require(try await h.store.sessions().first { $0.folderPath == outside.canonicalPath.path })
        let wt = try #require(try await h.store.worktrees(projectID: h.project.id).first { $0.path == outside.canonicalPath.path })
        let output = try await h.service.create(SessionCreationRequest(title: "x", target: .existingCheckout(worktreeID: wt.id), spec: LaunchSpec(provider: .shell)))
        #expect(output.adoptedExisting && output.session.id == notStarted.id)
        #expect(try await h.store.sessions().filter { $0.worktreeID == wt.id }.count == 1)
        // Segunda sessão no mesmo worktree: agora ele está em uso e nasce outra.
        let again = try await h.service.create(SessionCreationRequest(title: "y", target: .existingCheckout(worktreeID: wt.id), spec: LaunchSpec(provider: .shell)))
        #expect(!again.adoptedExisting && again.session.id != notStarted.id)
    }

    @Test func mainCheckoutOpensTheProjectRootWithoutCreatingFolders() async throws {
        let h = try await CreationHarness()
        let main = try #require(try await h.store.worktrees(projectID: h.project.id).first(where: \.isMain))
        let output = try await h.service.create(SessionCreationRequest(title: "main", target: .existingCheckout(worktreeID: main.id), spec: LaunchSpec(provider: .shell)))
        #expect(output.session.kind == .checkout && output.session.folderPath == h.repo.path)
        #expect(!FileManager.default.fileExists(atPath: h.worktreeRoot.path), "nenhuma worktree nova")
    }

    @Test func existingBranchIsReusedAndABranchAlreadyCheckedOutIsReported() async throws {
        let h = try await CreationHarness()
        try await h.sandbox.git(["branch", "release"], in: h.repo)
        let output = try await h.service.create(h.newWorktree(.existingBranch("release")))
        #expect(output.worktree?.branch == "release" && output.session.folderPath.hasSuffix("/acme-platform/release"))
        do {
            _ = try await h.service.create(h.newWorktree(.existingBranch("release")))
            Issue.record("must fail: branch in use")
        } catch let failure as SessionCreationFailure {
            #expect(failure.message == "Couldn't create worktree" && failure.detail.contains("already checked out") && failure.recoveries == [.tryAgain])
        }
    }

    @Test func existingExactBranchOffersUseExistingBranch() async throws {
        let h = try await CreationHarness()
        try await h.sandbox.git(["branch", "taken"], in: h.repo)
        do {
            _ = try await h.service.create(h.newWorktree(.newBranchExact(name: "taken", baseRef: nil)))
            Issue.record("must fail: branch exists")
        } catch let failure as SessionCreationFailure {
            #expect(failure.recoveries.contains(.useExistingBranch("taken")))
        }
        let nothing = try await h.store.sessions().filter { $0.title == "t" }
        #expect(nothing.isEmpty, "falha não deixa sessão para trás")
    }

    @Test func failedFetchOffersCreateWithoutFetchingAndThenWorks() async throws {
        let h = try await CreationHarness()
        try await h.sandbox.git(["remote", "set-url", "origin", h.sandbox.root.appendingPathComponent("gone.git").path], in: h.repo)
        let source = GitWorktreeSource.newBranch(slug: "offline", prefix: .none, baseRef: nil)
        do {
            _ = try await h.service.create(h.newWorktree(source))
            Issue.record("must fail: fetch")
        } catch let failure as SessionCreationFailure {
            #expect(failure.message == "Couldn't fetch origin" && failure.recoveries == [.tryAgain, .createWithoutFetching])
        }
        let output = try await h.service.create(h.newWorktree(source, fetch: .skipFetch))
        #expect(output.worktree?.branch == "offline")
    }

    @Test func cleanManagedFolderIsCreatedWithAUniqueName() async throws {
        let h = try await CreationHarness()
        let root = h.sandbox.root.appendingPathComponent("sessions", isDirectory: true)
        let path = root.appendingPathComponent("quiet-harbor", isDirectory: true).path
        let first = try await h.service.create(SessionCreationRequest(title: "quiet-harbor", target: .cleanFolder(path: path, managed: true), spec: LaunchSpec(provider: .shell)))
        let second = try await h.service.create(SessionCreationRequest(title: "quiet-harbor", target: .cleanFolder(path: path, managed: true), spec: LaunchSpec(provider: .shell)))
        #expect(first.session.folderPath == path && second.session.folderPath == path + "-2")
        #expect(first.session.kind == .clean && first.session.managedFolder && first.session.projectID == nil)
        #expect(FileManager.default.fileExists(atPath: path + "-2"))
        #expect(first.terminal.title == URL(fileURLWithPath: path).lastPathComponent, "terminal de shell leva o nome da pasta")
    }

    @Test func chosenFolderIsUsedAsIsAndNeverCreated() async throws {
        let h = try await CreationHarness()
        let folder = try h.sandbox.dir("mine")
        try h.sandbox.write("keep.txt", "x", in: folder)
        let output = try await h.service.create(SessionCreationRequest(title: "mine", target: .cleanFolder(path: folder.path, managed: false), spec: LaunchSpec(provider: .shell)))
        #expect(output.session.folderPath == folder.path && !output.session.managedFolder)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["keep.txt"])
        do {
            _ = try await h.service.create(SessionCreationRequest(title: "gone", target: .cleanFolder(path: folder.path + "/nope", managed: false), spec: LaunchSpec(provider: .shell)))
            Issue.record("must fail: missing folder")
        } catch let failure as SessionCreationFailure {
            #expect(failure.message == "Couldn't open the folder")
        }
    }

    @Test func builtinProfileIsKeptOnlyInTheSpecBecauseOfTheForeignKey() async throws {
        let h = try await CreationHarness()
        var spec = LaunchSpec(provider: .claude)
        spec.profileID = BuiltinProfiles.claudePlan.id
        let output = try await h.service.create(h.newWorktree(.newBranch(slug: "p", prefix: .none, baseRef: nil), spec: spec))
        #expect(output.terminal.profileID == nil && output.terminal.launchSpec.profileID == BuiltinProfiles.claudePlan.id)
    }
}

final class PhaseLog: @unchecked Sendable { // SAFETY: acesso serializado pelo lock.
    private let lock = NSLock() // LOCK: protege `items`; seções curtas, sem await.
    private var items: [SessionCreationPhase] = []
    func add(_ phase: SessionCreationPhase) { lock.lock(); items.append(phase); lock.unlock() }
    var all: [SessionCreationPhase] { lock.lock(); defer { lock.unlock() }; return items }
}
