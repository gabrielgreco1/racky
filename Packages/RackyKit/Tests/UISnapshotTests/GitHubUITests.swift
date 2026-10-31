import RackyCore
import RackyDesignSystem
import RackyProtocol
import AppKit
import Foundation
import SnapshotTesting
import SwiftUI
import Testing

@testable import RackyUI

// T2-05 (UI): chip de PR, Source Control, Checks, "Create Pull Request…" e a nota da sessão. Nenhum `gh`, `git` nem rede de
// verdade: os runners são fakes que gravam as chamadas (AC-503: nada é enviado antes de confirmar).

/// `gh` de mentira que grava as chamadas.
nonisolated final class PRFakeGH: GitHubCommandRunning, @unchecked Sendable {  // SAFETY: estado protegido por `lock`.
    private let lock = NSLock()
    private var _calls: [[String]] = []
    private var handler: @Sendable ([String]) -> GitCommandResult

    init(_ handler: @escaping @Sendable ([String]) -> GitCommandResult) { self.handler = handler }

    var calls: [[String]] { lock.withLock { _calls } }
    var graphQL: Int { calls.filter { $0.prefix(2) == ["api", "graphql"] }.count }
    var creates: [[String]] { calls.filter { $0.prefix(2) == ["pr", "create"] } }
    func set(_ new: @escaping @Sendable ([String]) -> GitCommandResult) { lock.withLock { handler = new } }

    func run(_ arguments: [String], in directory: URL?, timeout: Duration) async throws -> GitCommandResult {
        let current = lock.withLock { () -> @Sendable ([String]) -> GitCommandResult in
            _calls.append(arguments)
            return handler
        }
        return current(arguments)
    }
}

/// `git` de mentira: remote, base, status, diffs e push respondem por tabela; grava as chamadas.
nonisolated final class PRFakeGit: GitCommandRunning, @unchecked Sendable {  // SAFETY: estado protegido por `lock`.
    private let lock = NSLock()
    private var _calls: [[String]] = []
    var remote: String
    var status: String
    var nameStatus = ""
    var numstat = ""
    var untracked = ""

    init(remote: String = "https://github.com/acme/widgets.git", status: String = "") {
        self.remote = remote
        self.status = status
    }

    var calls: [[String]] { lock.withLock { _calls } }
    var pushes: [[String]] { calls.filter { $0.first == "push" } }

    func run(_ arguments: [String], in directory: URL?, kind: GitCommandKind, timeout: Duration) async throws -> GitCommandResult {
        lock.withLock { _calls.append(arguments) }
        func ok(_ text: String) -> GitCommandResult { GitCommandResult(exitCode: 0, stdout: text, stderr: "") }
        let args = arguments.filter { $0 != "-c" && $0 != "core.quotepath=false" }
        switch args.first {
        case "config": return remote.isEmpty ? GitCommandResult(exitCode: 1, stdout: "", stderr: "") : ok(remote + "\n")
        case "symbolic-ref": return ok("origin/main\n")
        case "log": return ok("Fix search pagination\n")
        case "status": return ok(status)
        case "merge-base": return ok("abc123\n")
        case "diff": return ok(args.contains("--name-status") ? nameStatus : numstat)
        case "ls-files": return ok(untracked)
        case "push": return ok("")
        default: return ok("")
        }
    }
}

nonisolated enum PRFixture {
    static let repoPath = "/tmp/racky-t205/worktree"

    /// Resposta GraphQL de uma branch com um PR aberto e três checks (falhando, pendente, passando).
    static func graphQL(state: String = "OPEN", draft: Bool = false, remaining: Int = 4900) -> String {
        """
        {"data":{"rateLimit":{"cost":1,"remaining":\(remaining),"resetAt":"2026-10-17T18:00:00Z"},"repository":{"b0":{"nodes":[
          {"number":412,"title":"Fix search pagination","url":"https://github.com/acme/widgets/pull/412","state":"\(state)","isDraft":\(draft),
           "reviewDecision":"REVIEW_REQUIRED","mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED","headRefName":"feature","headRefOid":"abc",
           "baseRefName":"main","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"FAILURE","contexts":{"totalCount":3,"nodes":[
             {"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"https://github.com/acme/widgets/actions/runs/1/job/2","databaseId":2,"checkSuite":{"workflowRun":{"databaseId":1}}},
             {"__typename":"CheckRun","name":"lint","status":"IN_PROGRESS","conclusion":null,"detailsUrl":"https://github.com/acme/widgets/actions/runs/1/job/3","databaseId":3,"checkSuite":{"workflowRun":{"databaseId":1}}},
             {"__typename":"CheckRun","name":"unit-tests","status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":"https://github.com/acme/widgets/actions/runs/1/job/4","databaseId":4,"checkSuite":{"workflowRun":{"databaseId":1}}}
           ]}}}}]}}
        ]}}}}
        """
    }

    static let noPullRequest = #"{"data":{"rateLimit":{"cost":1,"remaining":4900,"resetAt":"2026-10-17T18:00:00Z"},"repository":{"b0":{"nodes":[]}}}}"#

    static func handler(graphQL body: @escaping @Sendable () -> String, create: @escaping @Sendable () -> GitCommandResult = {
        GitCommandResult(exitCode: 0, stdout: "https://github.com/acme/widgets/pull/9\n", stderr: "")
    }) -> @Sendable ([String]) -> GitCommandResult {
        { args in
            switch (args.first, args.dropFirst().first) {
            case ("auth", _): return GitCommandResult(exitCode: 0, stdout: "", stderr: "github.com\n  ✓ Logged in to github.com account octocat (keyring)\n  - Token scopes: 'repo', 'read:org'\n")
            case ("api", "graphql"): return GitCommandResult(exitCode: 0, stdout: body(), stderr: "")
            case ("pr", "create"): return create()
            default: return GitCommandResult(exitCode: 0, stdout: "", stderr: "")
            }
        }
    }
}

@MainActor
final class PRSessionBox {
    var selected: GitHubSessionRef?
    var all: [GitHubSessionRef] = []
    init(_ session: GitHubSessionRef? = nil) {
        selected = session
        all = session.map { [$0] } ?? []
    }
}

@MainActor
final class PRLog {
    var opened: [URL] = []
    var copied: [String] = []
    var files: [URL] = []
}

@MainActor
struct PRRig {
    let github: GitHubController
    let gh: PRFakeGH
    let git: PRFakeGit
    let overlays: OverlayRouter
    let toasts: ToastCenter
    let registry: ActionRegistry
    let box: PRSessionBox
    let log: PRLog
    let session: GitHubSessionRef
    let tmp: URL

    static func make(
        remote: String = "https://github.com/acme/widgets.git", status: String = "", graphQL: @escaping @Sendable () -> String = { PRFixture.graphQL() },
        create: @escaping @Sendable () -> GitCommandResult = { GitCommandResult(exitCode: 0, stdout: "https://github.com/acme/widgets/pull/9\n", stderr: "") },
        sessionStatus: GitStatus? = nil
    ) throws -> PRRig {
        let session = GitHubSessionRef(
            id: UUID(), title: "fix search pagination", folderPath: PRFixture.repoPath, branch: "feature",
            status: sessionStatus ?? GitStatus(branch: "feature", headOID: "abc", upstream: "origin/feature", ahead: 3, behind: 0, changedFiles: 1, untrackedFiles: 0, conflictedFiles: 0))
        let box = PRSessionBox(session)
        let git = PRFakeGit(remote: remote, status: status)
        let gh = PRFakeGH(PRFixture.handler(graphQL: graphQL, create: create))
        let overlays = OverlayRouter()
        let toasts = ToastCenter()
        let log = PRLog()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("racky-t205-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let service = GitHubService(runner: gh, git: GitService(runner: git))
        let github = GitHubController(
            service: service, git: GitService(runner: git), gitRunner: git, ghRunner: gh,
            source: GitHubSource(selected: { box.selected }, sessions: { box.all }), overlays: overlays, toasts: toasts,
            openURL: { log.opened.append($0) })
        github.copyText = { log.copied.append($0) }
        github.openFile = { log.files.append($0) }
        github.temporaryDirectory = tmp
        github.clock = { Date(timeIntervalSince1970: 1_900_000_000) }
        let elements = UIElementStore()
        let flags = SliceFlags(current: .slice2, restricted: true)
        let registry = ActionRegistry(flags: flags, surface: WindowAutomation(store: elements, flags: flags, fixture: nil, automationEnabled: false))
        try github.register(in: registry)
        return PRRig(github: github, gh: gh, git: git, overlays: overlays, toasts: toasts, registry: registry, box: box, log: log, session: session, tmp: tmp)
    }
}

@MainActor
@Suite(.serialized, .offscreenAppKit) struct GitHubControllerTests {
    @Test func tickShowsChipWithChecksAndBatchesOneQuery() async throws {
        let rig = try PRRig.make()
        // Segunda sessão na mesma branch/repositório: continua sendo uma única consulta.
        var other = rig.session
        other.id = UUID()
        rig.box.all.append(other)
        await rig.github.tick()
        let chip = try #require(rig.github.chips[rig.session.id])
        #expect(chip.number == 412 && chip.state == .open)
        #expect(chip.failing == 1 && chip.pending == 1 && chip.passing == 1 && chip.checks == .failure)
        #expect(PullRequestText.detailLine(chip) == "Open · 1 check failing · Review required")
        #expect(rig.gh.graphQL == 1)
        // Dentro do TTL o serviço não volta à rede (AC-504: no máximo uma consulta por repositório a cada 30–60 s).
        await rig.github.tick()
        await rig.github.tick()
        #expect(rig.gh.graphQL == 1)
    }

    @Test func noGitHubRemoteMeansNoGhCalls() async throws {
        let rig = try PRRig.make(remote: "")
        await rig.github.tick()
        #expect(rig.gh.calls.isEmpty)
        #expect(rig.github.chips.isEmpty)
        #expect(rig.github.notOnGitHub.contains(PRFixture.repoPath))
        // "Create Pull Request…" explica por que não está disponível.
        #expect(rig.registry.availability(of: .gitCreatePR) == .disabled(reason: "This repository isn't on GitHub."))
    }

    @Test func rateLimitKeepsLastStateWithPausedHint() async throws {
        let rig = try PRRig.make()
        await rig.github.tick()
        rig.gh.set { args in
            args.first == "api"
                ? GitCommandResult(exitCode: 1, stdout: "", stderr: "gh: HTTP 403: API rate limit exceeded")
                : GitCommandResult(exitCode: 0, stdout: "", stderr: "github.com\n  ✓ Logged in to github.com account octocat (keyring)\n")
        }
        await rig.github.tick(force: true)
        let chip = try #require(rig.github.chips[rig.session.id])
        #expect(chip.number == 412)
        #expect(chip.pausedReason == "Paused · rate limit")
        #expect(PullRequestText.tooltip(chip).contains("Paused · rate limit"))
    }

    @Test func notLoggedInMakesNoGraphQLCalls() async throws {
        let rig = try PRRig.make()
        rig.gh.set { _ in GitCommandResult(exitCode: 1, stdout: "", stderr: "You are not logged into any GitHub hosts. To log in, run: gh auth login") }
        await rig.github.tick()
        #expect(rig.gh.graphQL == 0)
        #expect(rig.github.access == .loggedOut)
    }

    @Test func openAndCopyActionsUseTheInjectedSinks() async throws {
        let rig = try PRRig.make()
        await rig.github.tick()
        _ = try await rig.registry.perform(.gitOpenPR, .select(rig.session.id.uuidString))
        #expect(rig.log.opened.map(\.absoluteString) == ["https://github.com/acme/widgets/pull/412"])
        _ = try await rig.registry.perform(.gitCopyPRURL, nil)
        #expect(rig.log.copied == ["https://github.com/acme/widgets/pull/412"])
        _ = try await rig.registry.perform(.gitOpenCheck, .select("build"))
        #expect(rig.log.opened.last?.absoluteString == "https://github.com/acme/widgets/actions/runs/1/job/2")
    }

    @Test func createPRIsRefusedWhileAnOpenPullRequestExists() async throws {
        let rig = try PRRig.make()
        await rig.github.tick()
        #expect(rig.registry.availability(of: .gitCreatePR) == .disabled(reason: "This branch already has a pull request."))
        await #expect(throws: ActionError.self) { _ = try await rig.registry.perform(.gitCreatePR, nil) }
    }

    @Test func createPRPrefillsAndSendsNothingUntilConfirmed() async throws {
        let rig = try PRRig.make(graphQL: { PRFixture.noPullRequest }, sessionStatus: GitStatus(branch: "feature", headOID: "abc", upstream: nil, ahead: nil, behind: nil, changedFiles: 0, untrackedFiles: 0, conflictedFiles: 0))
        await rig.github.tick()
        #expect(rig.github.chips.isEmpty)
        _ = try await rig.registry.perform(.gitCreatePR, nil)
        let model = try #require(rig.github.createModel)
        #expect(rig.overlays.top?.spec.name == "createPR")
        #expect(model.title == "Fix search pagination" && model.base == "main" && model.draft == false && model.body.isEmpty)
        #expect(model.push == .push)
        #expect(model.preview.contains("git push -u origin feature"))
        #expect(model.preview.contains("gh pr create --base main --head feature --title 'Fix search pagination'"))
        // AC-503: o overlay só mostra; nada de push nem de `gh pr create` até o "Create".
        #expect(rig.git.pushes.isEmpty)
        #expect(rig.gh.creates.isEmpty)
        // Cancelar também não envia nada.
        _ = try await rig.registry.perform(.dialogCreatePRCancel, nil)
        #expect(rig.git.pushes.isEmpty && rig.gh.creates.isEmpty)
        #expect(rig.github.createModel == nil)
    }

    @Test func createPRConfirmedPushesCreatesAndRefreshesTheChip() async throws {
        let rig = try PRRig.make(graphQL: { PRFixture.noPullRequest }, sessionStatus: GitStatus(branch: "feature", headOID: "abc", upstream: nil, ahead: nil, behind: nil, changedFiles: 0, untrackedFiles: 0, conflictedFiles: 0))
        await rig.github.tick()
        _ = try await rig.registry.perform(.gitCreatePR, nil)
        _ = try await rig.registry.perform(.dialogCreatePRSetTitle, .set("Add retry logic"))
        _ = try await rig.registry.perform(.dialogCreatePRSetBody, .set("Body text"))
        _ = try await rig.registry.perform(.dialogCreatePRSetDraft, .set("on"))
        // Depois do Create o GitHub passa a devolver o PR.
        rig.gh.set(PRFixture.handler(graphQL: { PRFixture.graphQL(draft: true) }))
        let result = try await rig.registry.perform(.dialogCreatePRSubmit, nil)
        #expect(result.message == "https://github.com/acme/widgets/pull/9")
        #expect(rig.git.pushes == [["push", "-u", "origin", "feature"]])
        let create = try #require(rig.gh.creates.first)
        #expect(create.contains("--draft") && create.contains("Add retry logic") && create.contains("--body-file"))
        #expect(create.contains("--repo") && create.contains("acme/widgets"))
        #expect(rig.overlays.top == nil, "o overlay fecha no sucesso")
        #expect(rig.github.chips[rig.session.id]?.state == .draft, "o chip aparece com o número")
        #expect(rig.toasts.visible.first?.title == "Opened PR #9.")
        // O arquivo do corpo é apagado ao final.
        #expect((try? FileManager.default.contentsOfDirectory(atPath: rig.tmp.path))?.isEmpty == true)
    }

    @Test func createPRFailureKeepsTheOverlayWithTextAndRetries() async throws {
        let failing = Box(true)
        let rig = try PRRig.make(
            graphQL: { PRFixture.noPullRequest },
            create: {
                failing.value
                    ? GitCommandResult(exitCode: 1, stdout: "", stderr: "GraphQL: A pull request already exists for acme:feature. ghp_abcdefghijklmnopqrstuvwxyz0123")
                    : GitCommandResult(exitCode: 0, stdout: "https://github.com/acme/widgets/pull/10\n", stderr: "")
            })
        await rig.github.tick()
        _ = try await rig.registry.perform(.gitCreatePR, nil)
        await #expect(throws: ActionError.self) { _ = try await rig.registry.perform(.dialogCreatePRSubmit, nil) }
        let model = try #require(rig.github.createModel)
        guard case .failed(let text) = model.phase else { Issue.record("esperava falha"); return }
        #expect(text.contains("already exists") && !text.contains("ghp_"), "o texto aparece e o token nunca")
        #expect(rig.overlays.top?.spec.name == "createPR")
        failing.value = false
        let retried = try await rig.registry.perform(.dialogCreatePRRetry, nil)
        #expect(retried.message == "https://github.com/acme/widgets/pull/10")
        #expect(rig.overlays.top == nil)
    }

    @Test func createPREmptyTitleIsDisabledWithReason() async throws {
        let rig = try PRRig.make(graphQL: { PRFixture.noPullRequest })
        await rig.github.tick()
        _ = try await rig.registry.perform(.gitCreatePR, nil)
        _ = try await rig.registry.perform(.dialogCreatePRSetTitle, .set("   "))
        #expect(rig.registry.availability(of: .dialogCreatePRSubmit) == .disabled(reason: "Add a title."))
        #expect(rig.gh.creates.isEmpty)
    }

    @Test func openCompareRunsTheWebAlternativeWithoutPushing() async throws {
        let rig = try PRRig.make(graphQL: { PRFixture.noPullRequest })
        await rig.github.tick()
        _ = try await rig.registry.perform(.gitCreatePR, nil)
        _ = try await rig.registry.perform(.dialogCreatePROpenCompare, nil)
        #expect(rig.gh.creates.count == 1 && rig.gh.creates[0].contains("--web"))
        #expect(rig.git.pushes.isEmpty)
    }

    @Test func changesListComesFromTheMergeBaseDiff() async throws {
        let rig = try PRRig.make()
        rig.git.nameStatus = "M\0Sources/App/main.swift\0A\0docs/new.md\0D\0old.txt\0"
        rig.git.numstat = "3\t1\tSources/App/main.swift\0" + "10\t0\tdocs/new.md\0" + "0\t4\told.txt\0"
        rig.git.untracked = "notes.md\0"
        await rig.github.tick()
        await rig.github.loadChanges(for: rig.session)
        #expect(rig.github.changesLoad == .loaded)
        #expect(rig.github.baseRef == "origin/main")
        #expect(rig.github.changes.map(\.path) == ["docs/new.md", "notes.md", "old.txt", "Sources/App/main.swift"])
        let main = try #require(rig.github.changes.first { $0.name == "main.swift" })
        #expect(main.kind == .modified && main.additions == 3 && main.deletions == 1 && main.directory == "Sources/App")
        #expect(rig.github.changes.first { $0.path == "notes.md" }?.kind == .untracked)
        // O diff é feito contra o merge-base (não contra o HEAD) e só lê.
        #expect(rig.git.calls.contains { $0.contains("diff") && $0.contains("abc123") })
        #expect(rig.git.pushes.isEmpty)
        // Abrir uma mudança só vale para caminhos da lista.
        _ = try await rig.registry.perform(.gitOpenChange, .select("Sources/App/main.swift"))
        #expect(rig.log.files.map(\.path) == [PRFixture.repoPath + "/Sources/App/main.swift"])
        await #expect(throws: ActionError.self) { _ = try await rig.registry.perform(.gitOpenChange, .select("../../etc/passwd")) }
        await #expect(throws: ActionError.self) { _ = try await rig.registry.perform(.gitOpenChange, .select("old.txt")) }
    }

    @Test func pushDetectionRules() {
        func status(upstream: String?, ahead: Int?, oid: String = "a") -> GitStatus {
            GitStatus(branch: "f", headOID: oid, upstream: upstream, ahead: ahead, behind: 0, changedFiles: 0, untrackedFiles: 0, conflictedFiles: 0)
        }
        #expect(GitHubController.looksLikePush(from: status(upstream: nil, ahead: nil), to: status(upstream: "origin/f", ahead: 0)))
        #expect(GitHubController.looksLikePush(from: status(upstream: "origin/f", ahead: 3), to: status(upstream: "origin/f", ahead: 0)))
        #expect(!GitHubController.looksLikePush(from: status(upstream: "origin/f", ahead: 3), to: status(upstream: "origin/f", ahead: 0, oid: "b")), "reset/rebase não é push")
        #expect(!GitHubController.looksLikePush(from: status(upstream: "origin/f", ahead: 0), to: status(upstream: "origin/f", ahead: 1)))
    }

    @Test func changedFilesParserHandlesBinariesAndLimit() {
        let parsed = GitChangedFilesParser.parse(nameStatus: "M\0img.png\0", numstat: "-\t-\timg.png\0", untracked: "")
        #expect(parsed == [GitFileChange(path: "img.png", kind: .modified, additions: nil, deletions: nil)])
    }
}

nonisolated final class Box<T>: @unchecked Sendable {  // SAFETY: usado em testes seriais, escrita antes da leitura.
    var value: T
    init(_ value: T) { self.value = value }
}

// MARK: Sidebar: chip, ↑n, ponto e nota (AC-501, AC-208)

@MainActor
@Suite(.offscreenAppKit) struct GitHubSidebarTests {
    static let now = Date(timeIntervalSince1970: 1_900_000_000)

    func cardInput(_ edit: (inout SidebarInput, Session) -> Void) -> (SessionCardData, Session) {
        let cast = SidebarFixtures.full(now: Self.now, home: "/Users/test")
        let session = cast.sessions.first { $0.worktreeID != nil && $0.kind == .worktree }!
        var input = SidebarInput(snapshot: cast.snapshot, now: Self.now, home: "/Users/test")
        input.selectedSession = session.id
        input.showMoreOpen = Set(cast.projects.map(\.id))
        edit(&input, session)
        let projection = SidebarProjector.build(input)
        let card = (projection.projects.flatMap(\.sessions) + projection.cleanSessions).first { $0.id == session.id }!
        return (card, session)
    }

    static let chip = PullRequestChipModel(
        number: 412, title: "Fix search pagination", url: "https://github.com/acme/widgets/pull/412", state: .open,
        counts: CheckCounts(success: 9, failure: 2, pending: 0), reviewDecision: .reviewRequired)

    @Test func cardShowsAheadDotAndPullRequestChip() {
        let (card, _) = cardInput { input, session in
            input.gitStatus[session.folderPath] = GitStatus(
                branch: "x", headOID: "a", upstream: "origin/x", ahead: 3, behind: 0, changedFiles: 1, untrackedFiles: 0, conflictedFiles: 0)
            input.pullRequests[session.id] = Self.chip
        }
        #expect(card.ahead == 3 && card.dirty)
        #expect(card.pr?.number == 412)
        #expect(card.a11yLabel.contains("Pull request #412"))
        #expect(PullRequestText.detailLine(Self.chip) == "Open · 2 checks failing · Review required")
        #expect(PullRequestText.checksSummary(Self.chip) == "2 failing · 9 passing")
    }

    @Test func cardWithoutGitStateShowsNothingExtra() {
        let (card, _) = cardInput { _, _ in }
        #expect(card.ahead == 0 && !card.dirty && card.pr == nil)
    }

    @Test func noteEditCommitAndRemove() async throws {
        let model = SidebarModel()
        model.clock = { Self.now }
        let cast = SidebarFixtures.full(now: Self.now, home: "/Users/test")
        model.apply(cast.snapshot)
        let session = try #require(cast.sessions.first { $0.statusNote == nil })
        #expect(model.beginEditNote(session.id))
        #expect(model.editingNote == session.id)
        try await model.commitNote("Reproduced the bug; testing fix")
        #expect(model.editingNote == nil)
        #expect(model.session(session.id)?.statusNote?.text == "Reproduced the bug; testing fix")
        #expect(model.session(session.id)?.statusNote?.author == "user")
        let card = SidebarProjector.build(model.input).projects.flatMap(\.sessions).first { $0.id == session.id }
        #expect(card?.note == "Reproduced the bug; testing fix")
        #expect(card?.noteDetail == "You · now")
        // Texto vazio remove a nota.
        try await model.commitNote("   ", to: session.id)
        #expect(model.session(session.id)?.statusNote == nil)
    }

    @Test func panelActionsOpenSourceControlAndChecks() async throws {
        let env = AppEnvironment(environment: ["RACKY_SLICE": "2", "RACKY_SCREEN": SidebarFixtures.screenID])
        _ = try await env.registry.perform(.panelSourceControl, nil)
        #expect(env.rightPanel.layout.isVisible(.sourceControl))
        _ = try await env.registry.perform(.panelChecks, nil)
        #expect(env.rightPanel.layout.isVisible(.checks))
        // Sem sessão selecionada, o Refresh explica por que está desabilitado.
        #expect(env.registry.availability(of: .panelRefresh) == .disabled(reason: "Select a session first."))
    }

    @Test func editNoteActionDrivesTheSameFlow() async throws {
        let env = AppEnvironment(environment: ["RACKY_SLICE": "2", "RACKY_SCREEN": SidebarFixtures.screenID])
        let cast = SidebarFixtures.full(now: Self.now, home: "/Users/test")
        env.sidebar.apply(cast.snapshot)
        let session = try #require(cast.sessions.first { $0.statusNote == nil })
        _ = try await env.registry.perform(.sessionEditNote, .select(session.id.uuidString))
        #expect(env.sidebar.editingNote == session.id)
        _ = try await env.registry.perform(.sessionEditNote, .set("Opened PR #412; fixing tests"))
        #expect(env.sidebar.session(session.id)?.statusNote?.text == "Opened PR #412; fixing tests")
        // Sem edição aberta, `set` grava na sessão selecionada (CLI: `ctl ui action session.editNote set:<texto>`); vazio remove.
        env.sidebar.select(session.id)
        _ = try await env.registry.perform(.sessionEditNote, .set(""))
        #expect(env.sidebar.session(session.id)?.statusNote == nil)
    }
}

// MARK: Snapshots offscreen (PNG na pasta temporária ao gravar)

@MainActor
@Suite(.serialized, .offscreenAppKit) struct GitHubSnapshotTests {
    static let now = Date(timeIntervalSince1970: 1_900_000_000)

    func host<V: View>(_ view: V, size: CGSize, registry: ActionRegistry, elements: UIElementStore = UIElementStore()) -> NSHostingView<some View> {
        let root = view
            .environment(\.actionRegistry, registry)
            .environment(\.elementStore, elements)
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        return host
    }

    func snap<V: View>(_ host: NSHostingView<V>, _ name: String, line: UInt = #line) {
        withSnapshotTesting(record: ComponentSnapshotTests.recording) {
            assertSnapshot(of: host, as: .image(precision: 0.9, perceptualPrecision: 0.9), named: name, testName: "github", line: line)
        }
        Self.writeEvidence(host, name)
    }

    /// PNG de evidência ao gravar (`RACKY_RECORD_SNAPSHOTS=1`), junto da spec do núcleo.
    static func writeEvidence(_ host: NSView, _ name: String) {
        guard ProcessInfo.processInfo.environment["RACKY_RECORD_SNAPSHOTS"] == "1",
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)
        else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("racky-github-snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? png.write(to: dir.appendingPathComponent("\(name).png"))
    }

    func panel(_ rig: PRRig, size: CGSize) -> NSHostingView<some View> {
        let controller = RightPanelController()
        controller.register(SourceControlModule(controller: rig.github))
        controller.register(ChecksModule(controller: rig.github))
        controller.isContentVisible = true
        controller.updateWindow(width: 1440, sidebarWidth: 280)
        controller.show(.sourceControl)
        controller.show(.checks)
        return host(RightPanelView(controller: controller), size: size, registry: rig.registry)
    }

    func seeded(graphQL: @escaping @Sendable () -> String = { PRFixture.graphQL() }) async throws -> PRRig {
        let rig = try PRRig.make(graphQL: graphQL)
        rig.git.nameStatus = "M\0Sources/App/main.swift\0A\0docs/new.md\0D\0old.txt\0"
        rig.git.numstat = "12\t3\tSources/App/main.swift\0" + "40\t0\tdocs/new.md\0" + "0\t18\told.txt\0"
        rig.git.untracked = "notes.md\0"
        await rig.github.tick()
        await rig.github.loadChanges(for: rig.session)
        return rig
    }

    @Test func sourceControlAndChecksPanel() async throws {
        DSFonts.registerIfNeeded()
        let rig = try await seeded()
        snap(panel(rig, size: CGSize(width: 380, height: 760)), "sourceControlAndChecks")
    }

    @Test func sourceControlWithoutPullRequestShowsCreateButton() async throws {
        DSFonts.registerIfNeeded()
        let rig = try await seeded(graphQL: { PRFixture.noPullRequest })
        snap(panel(rig, size: CGSize(width: 380, height: 520)), "sourceControlCreatePR")
    }

    @Test func checksCompactWidth() async throws {
        DSFonts.registerIfNeeded()
        let rig = try await seeded()
        snap(panel(rig, size: CGSize(width: 280, height: 480)), "panelCompact")
    }

    @Test func createPullRequestOverlay() async throws {
        DSFonts.registerIfNeeded()
        let rig = try PRRig.make(graphQL: { PRFixture.noPullRequest }, sessionStatus: GitStatus(branch: "feature", headOID: "abc", upstream: nil, ahead: nil, behind: nil, changedFiles: 0, untrackedFiles: 0, conflictedFiles: 0))
        await rig.github.tick()
        _ = try await rig.registry.perform(.gitCreatePR, nil)
        let model = try #require(rig.github.createModel)
        model.body = "Fixes the off-by-one on the last search page."
        let card = CreatePRView(model: model)
            .frame(width: GitHubMetrics.overlayWidth)
            .background(DS.Color.chrome)
        snap(host(card, size: CGSize(width: GitHubMetrics.overlayWidth, height: 520), registry: rig.registry), "createPullRequest")
        model.phase = .failed("GraphQL: A pull request already exists for acme:feature.")
        snap(host(CreatePRView(model: model).frame(width: GitHubMetrics.overlayWidth).background(DS.Color.chrome), size: CGSize(width: GitHubMetrics.overlayWidth, height: 600), registry: rig.registry), "createPullRequestError")
    }

    @Test func sidebarCardWithChipAheadDotAndNote() async {
        DSFonts.registerIfNeeded()
        let env = AppEnvironment(environment: ["RACKY_SLICE": "2", "RACKY_SCREEN": SidebarFixtures.screenID])
        env.sidebar.clock = { Self.now }
        let cast = SidebarFixtures.full(now: Self.now, home: "/Users/test")
        env.sidebar.apply(cast.snapshot)
        if let selected = cast.selectedSessionID { env.sidebar.select(selected) }
        // As três sessões de worktree visíveis (com branch de verdade) do cenário padrão.
        let titles = ["Fix pagination", "main", "shop-pr-checkout-with-a-very-long-name-that-truncates"]
        let withBranch = titles.compactMap { title in cast.sessions.first { $0.title.hasPrefix(String(title.prefix(10))) && $0.worktreeID != nil } }
        #expect(withBranch.count == 3)
        for (index, session) in withBranch.enumerated() {
            env.sidebar.setGitStatus(
                GitStatus(branch: "b", headOID: "a", upstream: "origin/b", ahead: index == 1 ? 0 : 3, behind: 0, changedFiles: index == 2 ? 0 : 2, untrackedFiles: 0, conflictedFiles: 0),
                at: session.folderPath)
        }
        var chips: [UUID: PullRequestChipModel] = [:]
        let states: [(PullRequestChipModel.State, CheckCounts)] = [
            (.open, CheckCounts(success: 9, failure: 2)), (.draft, CheckCounts(success: 3, pending: 1)), (.merged, CheckCounts(success: 5)),
        ]
        for (session, state) in zip(withBranch, states) {
            chips[session.id] = PullRequestChipModel(number: 400 + chips.count, title: "PR", url: "https://github.com/a/b/pull/1", state: state.0, counts: state.1, items: [])
        }
        // Nota na primeira (linha 3) e outra em edição inline.
        try? await env.sidebar.commitNote("Opened PR #400; fixing tests", to: withBranch[0].id)
        env.sidebar.setPullRequests(chips)
        let size = CGSize(width: 280, height: 640)
        snap(host(SidebarView(model: env.sidebar), size: size, registry: env.registry, elements: env.elements), "sidebarChipAheadNote")
    }
}
