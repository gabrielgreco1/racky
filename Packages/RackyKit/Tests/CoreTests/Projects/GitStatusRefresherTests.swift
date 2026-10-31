import Foundation
import Testing
@testable import RackyCore

private actor Recorder {
    private(set) var updates: [(String, GitStatus)] = []
    func add(_ path: String, _ status: GitStatus) { updates.append((path, status)) }
    var count: Int { updates.count }
    var last: GitStatus? { updates.last?.1 }
}

private func waitUntil(timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

@Suite struct GitStatusRefresherTests {
    @Test func burstOfRequestsCoalescesIntoOneStatus() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepo()
        let recorder = Recorder()
        let refresher = GitStatusRefresher(git: sandbox.service, debounce: .milliseconds(150), minInterval: .milliseconds(0)) {
            await recorder.add($0, $1)
        }
        for _ in 0..<20 { await refresher.request(repo.path) }
        #expect(await waitUntil { await recorder.count == 1 })
        try await Task.sleep(for: .milliseconds(400))
        #expect(await recorder.count == 1)
        #expect(await refresher.runCount == 1)
        #expect(await recorder.last?.branch == "main")
        await refresher.stop()
    }

    @Test func seesChangesAndRespectsMinInterval() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepo()
        let recorder = Recorder()
        let refresher = GitStatusRefresher(git: sandbox.service, debounce: .milliseconds(20), minInterval: .milliseconds(500)) {
            await recorder.add($0, $1)
        }
        let start = ContinuousClock.now
        await refresher.request(repo.path)
        #expect(await waitUntil { await recorder.count == 1 })
        #expect(await recorder.last?.isDirty == false)

        try sandbox.write("new.txt", "x", in: repo)
        await refresher.request(repo.path)
        #expect(await waitUntil { await recorder.count == 2 })
        #expect(ContinuousClock.now - start >= .milliseconds(480), "no máximo um status por minInterval")
        #expect(await recorder.last?.untrackedFiles == 1)
        await refresher.stop()
    }

    @Test func immediateSkipsDebounceAndNeverRunsInParallel() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepo()
        let recorder = Recorder()
        let refresher = GitStatusRefresher(git: sandbox.service, debounce: .seconds(30), minInterval: .seconds(30)) {
            await recorder.add($0, $1)
        }
        await refresher.request(repo.path, immediate: true)
        #expect(await waitUntil { await recorder.count == 1 })
        await refresher.stop()
    }

    @Test func failingStatusDoesNotNotifyOrCrash() async throws {
        let sandbox = try GitSandbox()
        let recorder = Recorder()
        let refresher = GitStatusRefresher(git: sandbox.service, debounce: .milliseconds(10), minInterval: .milliseconds(0)) {
            await recorder.add($0, $1)
        }
        await refresher.request(sandbox.root.appendingPathComponent("gone").path)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await recorder.count == 0)
        await refresher.stop()
    }

    @Test func statusReadUsesOptionalLocksZero() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepo()
        let indexBefore = try Data(contentsOf: repo.appendingPathComponent(".git/index"))
        let status = try await sandbox.service.status(at: repo)
        #expect(status.branch == "main")
        #expect(try Data(contentsOf: repo.appendingPathComponent(".git/index")) == indexBefore)
        #expect(!FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git/index.lock").path))
    }
}

@Suite struct GitChangeWatcherTests {
    @Test func reportsFileChangesInsideWatchedFolder() async throws {
        let sandbox = try GitSandbox()
        let repo = try await sandbox.makeRepo()
        let seen = Recorder2()
        let watcher = GitChangeWatcher(paths: [repo.path], latency: 0.1) { events in Task { await seen.add(events) } }
        #expect(watcher.start())
        try await Task.sleep(for: .milliseconds(300))
        try sandbox.write("touched.txt", "x", in: repo)
        #expect(await waitUntil { await seen.contains(repo.appendingPathComponent("touched.txt").path) })
        watcher.stop()
    }

    @Test func emptyPathListDoesNotStart() {
        let watcher = GitChangeWatcher(paths: [], handler: { _ in })
        #expect(!watcher.start())
    }
}

private actor Recorder2 {
    private var all: [String] = []
    func add(_ events: [String]) { all += events }
    func contains(_ path: String) -> Bool { all.contains(path) }
}

@Suite struct GitEventRouterTests {
    let main = GitEventRouter.Target(worktreePath: "/r/proj", mainRoot: "/r/proj")
    let side = GitEventRouter.Target(worktreePath: "/w/side", mainRoot: "/r/proj")
    let other = GitEventRouter.Target(worktreePath: "/r/other", mainRoot: "/r/other")

    @Test func workingTreeEventSelectsOnlyThatWorktree() {
        let targets = [main, side, other]
        #expect(GitEventRouter.worktrees(for: ["/w/side/src/a.swift"], targets: targets) == ["/w/side"])
        #expect(GitEventRouter.worktrees(for: ["/r/proj/README.md"], targets: targets) == ["/r/proj"])
        #expect(GitEventRouter.worktrees(for: ["/r/projection/x"], targets: targets).isEmpty)
    }

    @Test func gitMetadataEventsSelectEveryWorktreeOfTheProject() {
        let targets = [main, side, other]
        let expected: Set = ["/r/proj", "/w/side"]
        for rel in ["HEAD", "index", "refs/heads/main", "packed-refs", "worktrees/side/HEAD"] {
            #expect(GitEventRouter.worktrees(for: ["/r/proj/.git/\(rel)"], targets: targets) == expected, "\(rel)")
        }
    }

    @Test func noiseIsIgnored() {
        let targets = [main, side]
        for path in ["/r/proj/.git/index.lock", "/r/proj/.git/objects/ab/cdef", "/r/proj/.git/logs/HEAD",
                     "/r/proj/.git/FETCH_HEAD", "/w/side/.git", "/w/side/src/x.lock"] {
            #expect(GitEventRouter.worktrees(for: [path], targets: targets).isEmpty, "\(path)")
        }
    }
}
