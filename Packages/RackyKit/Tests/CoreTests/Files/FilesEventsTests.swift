import RackyPlatform
import RackyProtocol
import RackyStore
import Foundation
import Testing

@testable import RackyCore

private actor CwdRecorder {
    private(set) var events: [(UUID, String)] = []
    func add(_ terminal: UUID, _ path: String) { events.append((terminal, path)) }
}

@Suite struct FilesEventFilterTests {
    private let root = "/work/proj"

    @Test func projectFilesAreTreeEvents() {
        #expect(FilesEventFilter.classify("/work/proj/src/a.swift", root: root, showIgnored: false) == .tree)
        #expect(FilesEventFilter.classify("/work/proj", root: root, showIgnored: false) == .tree)
    }

    @Test func gitInternalsOnlyMatterForHeadIndexAndRefs() {
        #expect(FilesEventFilter.classify("/work/proj/.git/index", root: root, showIgnored: false) == .gitOnly)
        #expect(FilesEventFilter.classify("/work/proj/.git/HEAD", root: root, showIgnored: false) == .gitOnly)
        #expect(FilesEventFilter.classify("/work/proj/.git/refs/heads/main", root: root, showIgnored: false) == .gitOnly)
        #expect(FilesEventFilter.classify("/work/proj/.git/objects/ab/cdef", root: root, showIgnored: false) == .ignored)
        #expect(FilesEventFilter.classify("/work/proj/.git/index.lock", root: root, showIgnored: false) == .ignored)
        #expect(FilesEventFilter.classify("/work/proj/.git/logs/HEAD", root: root, showIgnored: false) == .ignored)
    }

    @Test func nodeModulesAreNoiseUnlessIgnoredFilesAreShown() {
        #expect(FilesEventFilter.classify("/work/proj/node_modules/x/index.js", root: root, showIgnored: false) == .ignored)
        #expect(FilesEventFilter.classify("/work/proj/packages/a/node_modules/x.js", root: root, showIgnored: false) == .ignored)
        #expect(FilesEventFilter.classify("/work/proj/node_modules/x/index.js", root: root, showIgnored: true) == .tree)
        #expect(FilesEventFilter.classify("/work/proj/src/.DS_Store", root: root, showIgnored: false) == .ignored)
    }

    @Test func eventsOutsideTheRootAreIgnored() {
        #expect(FilesEventFilter.classify("/work/other/a.txt", root: root, showIgnored: false) == .ignored)
        #expect(FilesEventFilter.classify("/work/project-two/a.txt", root: root, showIgnored: false) == .ignored, "prefixo de nome não é pasta pai")
    }

    @Test func summaryCollectsWhatNeedsARefresh() {
        let summary = FilesEventFilter.summarize(
            ["/work/proj/.git/objects/x", "/work/proj/.git/index", "/work/proj/a.txt", "/work/proj/node_modules/z.js"], root: root, showIgnored: false)
        #expect(summary.tree)
        #expect(summary.git)
        #expect(summary.paths == ["/work/proj/a.txt"])
        let gitOnly = FilesEventFilter.summarize(["/work/proj/.git/HEAD"], root: root, showIgnored: false)
        #expect(!gitOnly.tree)
        #expect(gitOnly.git)
        let noise = FilesEventFilter.summarize(["/work/proj/.git/objects/x"], root: root, showIgnored: false)
        #expect(!noise.tree && !noise.git)
    }
}

@Suite struct HookCwdObserverTests {
    @Test func hookCwdReachesTheObserverPerTerminal() async throws {
        let home = try ActivityHome()
        defer { home.remove() }
        let store = try await home.openStore()
        let service = ActivityService(store: store, spoolDirectory: home.spoolDirectory)
        let recorder = CwdRecorder()
        await service.setCwdObserver { terminal, path in await recorder.add(terminal, path) }
        let terminal = try await home.seedTerminal(store)
        let run = UUID()
        func envelope(_ id: String, event: String, cwd: String?, at ns: Int64) -> HookEnvelope {
            HookEnvelope(
                id: id, provider: .claude, event: event, runID: run.uuidString, paneID: terminal.id.uuidString, atNs: ns,
                payload: ReducedHookPayload(cwd: cwd))
        }
        let base: Int64 = 1_800_000_000_000_000_000
        _ = try await service.ingest(envelope("e1", event: "SessionStart", cwd: "/work/proj", at: base))
        _ = try await service.ingest(envelope("e2", event: "PreToolUse", cwd: nil, at: base + 1_000_000))
        _ = try await service.ingest(envelope("e3", event: "PostToolUse", cwd: "/work/proj/packages/api", at: base + 2_000_000))
        // O mesmo evento duas vezes (socket e spool) não repete.
        _ = try await service.ingest(envelope("e3", event: "PostToolUse", cwd: "/work/proj/packages/api", at: base + 2_000_000))
        let events = await recorder.events
        #expect(events.map(\.1) == ["/work/proj", "/work/proj/packages/api"])
        #expect(events.allSatisfy { $0.0 == terminal.id })
    }
}
