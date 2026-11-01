import RackyPlatform
import RackyProtocol
import RackyStore
import Foundation
import Testing

@testable import RackyCore

/// Roda trabalho bloqueante (transporte do helper, `waitUntilExit`) numa thread própria, como o helper real faria num
/// processo próprio. Nunca no pool do GCD: bloqueá-lo em paralelo impede o próprio `Process` de notificar o término.
func offPool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { c in Thread.detachNewThread { c.resume(returning: work()) } }
}

private func waitUntil(timeout: Duration = .seconds(5), _ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

@Suite struct ActivityServiceTests {
    private func setup() async throws -> (ActivityHome, RackyStore, ActivityService) {
        let home = try ActivityHome()
        let store = try await home.openStore()
        return (home, store, ActivityService(store: store, spoolDirectory: home.spoolDirectory))
    }

    @Test func aWorkerTerminalGetsTheAppWorkerLightKindAndStaysAMainRunOfItsTerminal() async throws {
        let (home, store, service) = try await setup(); defer { home.remove() }
        let run = UUID()
        let session = Session(kind: .clean, folderPath: "/tmp/x", title: "quiet-harbor")
        let tabID = UUID.v7()
        let terminal = Terminal(
            tabID: tabID, provider: .claude, title: "Claude \u{00B7} Houston", cwd: "/tmp/x", launchSpec: LaunchSpec(provider: .claude, workerChildID: "parent-a-a1"), state: .running)
        let tab = Tab(id: tabID, sessionID: session.id, title: "Agent", layout: .leaf(Pane(content: .terminal(terminal.id))))
        try await store.saveBundle(session: session, tabs: [tab], terminals: [terminal])
        #expect(try await store.isWorkerTerminal(terminal.id))
        for e in RealHooks.envelopes(try RealHooks.events(RealHooks.claudeBasic), runID: run, paneID: terminal.id) { try await service.ingest(e) }
        let row = try #require(try await store.agentRun(id: run))
        #expect(row.kind == .appWorkerLight && row.terminalID == terminal.id && row.parentRunID == nil)
        // As consultas por terminal (semeadura da UI) continuam achando a execução.
        #expect(try await store.latestMainRuns().contains { $0.id == run })
        let plain = try await home.seedTerminal(store)
        #expect(try await store.isWorkerTerminal(plain.id) == false)
        try await store.close()
    }

    @Test func realClaudeTurnProjectsIntoRunAndTerminal() async throws {
        let (home, store, service) = try await setup(); defer { home.remove() }
        let run = UUID()
        let terminal = try await home.seedTerminal(store)
        let envelopes = RealHooks.envelopes(try RealHooks.events(RealHooks.claudeBasic), runID: run, paneID: terminal.id)
        for e in envelopes { #expect(try await service.ingest(e) == .applied) }

        let row = try #require(try await store.agentRun(id: run))
        #expect(row.activity == .done)
        #expect(row.kind == .main && row.harness == .claude && row.terminalID == terminal.id)
        #expect(row.providerSessionID == envelopes[0].payload.sessionID)
        #expect(try await store.agentEventCount(runID: run) == 6)
        let t = try #require(try await store.terminal(id: terminal.id))
        #expect(t.lastMessage == "DONE")
        #expect(t.nativeConversationID == envelopes[0].payload.sessionID)
        try await store.close()
    }

    @Test func replayingTheSameEventsIsIdempotent() async throws {
        let (home, store, service) = try await setup(); defer { home.remove() }
        let run = UUID()
        let terminal = try await home.seedTerminal(store)
        let envelopes = RealHooks.envelopes(try RealHooks.events(RealHooks.claudeSubagents), runID: run, paneID: terminal.id)
        for e in envelopes { try await service.ingest(e) }
        let before = try #require(try await store.agentRun(id: run))
        let childrenBefore = try await store.childRuns(parentRunID: run)

        for e in envelopes { #expect(try await service.ingest(e) == .duplicate) }
        // Um serviço novo (sem cache, como depois de reabrir o app) também reconhece duplicados e não muda nada.
        let fresh = ActivityService(store: store, spoolDirectory: home.spoolDirectory)
        for e in envelopes { #expect(try await fresh.ingest(e) == .duplicate) }

        #expect(try await store.agentEventCount(runID: run) == envelopes.count)
        #expect(try await store.agentRun(id: run) == before)
        #expect(try await store.childRuns(parentRunID: run) == childrenBefore)
        #expect(childrenBefore.count == 2)
        try await store.close()
    }

    @Test func outOfOrderArrivalConvergesToTheOrderedResult() async throws {
        let (home, store, service) = try await setup(); defer { home.remove() }
        let raws = try RealHooks.events(RealHooks.claudeSubagents)
        let orderedRun = UUID(), shuffledRun = UUID()
        let base: Int64 = 1_800_000_000_000_000_000
        let ordered = RealHooks.envelopes(raws, runID: orderedRun, paneID: nil, baseNs: base)
        var shuffled = RealHooks.envelopes(raws, runID: shuffledRun, paneID: nil, baseNs: base)
        shuffled.reverse()  // pior caso: tudo chega ao contrário
        for e in ordered { try await service.ingest(e) }
        for e in shuffled { try await service.ingest(e) }

        let a = try #require(try await store.agentRun(id: orderedRun))
        let b = try #require(try await store.agentRun(id: shuffledRun))
        #expect(a.activity == .done && b.activity == .done)
        #expect(a.statusReason == b.statusReason && a.subtitle == b.subtitle)
        #expect(a.providerSessionID == b.providerSessionID)
        #expect(a.startedAt == b.startedAt && a.lastEventAt == b.lastEventAt)
        let ca = try await store.childRuns(parentRunID: orderedRun), cb = try await store.childRuns(parentRunID: shuffledRun)
        #expect(ca.count == 2 && cb.count == 2)
        #expect(ca.map(\.agentType) == cb.map(\.agentType))
        #expect(ca.map(\.activity) == cb.map(\.activity))
        try await store.close()
    }

    @Test func stopBeforeSubagentStopsLeavesParentWaitingUntilTheLast() async throws {
        let (home, store, service) = try await setup(); defer { home.remove() }
        var raws = try RealHooks.events(RealHooks.claudeSubagents)
        let stop = raws.remove(at: try #require(raws.lastIndex { $0.name == "Stop" }))
        raws.insert(stop, at: try #require(raws.firstIndex { $0.name == "SubagentStop" }))
        let run = UUID()
        let envelopes = RealHooks.envelopes(raws, runID: run, paneID: nil)
        var seen: [AgentActivity] = []
        for e in envelopes {
            try await service.ingest(e)
            seen.append(try #require(try await store.agentRun(id: run)).activity)
        }
        let stopAt = try #require(raws.firstIndex { $0.name == "Stop" })
        #expect(seen[stopAt] == .waitingOnSubagents)
        let lastSubStop = try #require(raws.lastIndex { $0.name == "SubagentStop" })
        #expect(seen[lastSubStop] == .done)
        try await store.close()
    }

    @Test func lateEventsOfAnOlderRunDoNotOverwriteTheTerminalMessage() async throws {
        let (home, store, service) = try await setup(); defer { home.remove() }
        let oldRun = UUID(), currentRun = UUID()
        let terminal = try await home.seedTerminal(store, currentRunID: currentRun)
        for e in RealHooks.envelopes(try RealHooks.events(RealHooks.claudeBasic), runID: oldRun, paneID: terminal.id) { try await service.ingest(e) }
        #expect(try await store.terminal(id: terminal.id)?.lastMessage == nil)
        #expect(try await store.agentRun(id: oldRun)?.activity == .done)
        for e in RealHooks.envelopes(try RealHooks.events(RealHooks.claudeBasic), runID: currentRun, paneID: terminal.id) { try await service.ingest(e) }
        #expect(try await store.terminal(id: terminal.id)?.lastMessage == "DONE")
        try await store.close()
    }

    @Test func unknownPaneStillRecordsTheRunWithoutATerminal() async throws {
        let (home, store, service) = try await setup(); defer { home.remove() }
        let run = UUID()
        for e in RealHooks.envelopes(try RealHooks.events(RealHooks.claudeBasic), runID: run, paneID: UUID()) { try await service.ingest(e) }
        let row = try #require(try await store.agentRun(id: run))
        #expect(row.terminalID == nil && row.activity == .done)
        try await store.close()
    }

    @Test func invalidRunIDIsRejected() async throws {
        let (home, store, service) = try await setup(); defer { home.remove() }
        let bad = HookEnvelope(provider: .claude, event: "Stop", runID: "../../etc/passwd", atNs: 1, payload: .init())
        await #expect(throws: ActivityService.IngestError.invalidRunID("../../etc/passwd")) { try await service.ingest(bad) }
        try await store.close()
    }

    @Test func daemonExitAndLostPTYAreRecordedAsEvents() async throws {
        let (home, store, service) = try await setup(); defer { home.remove() }
        let failing = UUID(), lost = UUID()
        let basic = try RealHooks.events(RealHooks.claudeBasic)
        for e in RealHooks.envelopes(Array(basic.prefix(3)), runID: failing, paneID: nil) { try await service.ingest(e) }
        for e in RealHooks.envelopes(Array(basic.prefix(3)), runID: lost, paneID: nil) { try await service.ingest(e) }
        let later: Int64 = 1_800_000_000_000_000_000 + 60_000_000_000  // depois dos eventos do fixture
        #expect(try await service.recordProcessExit(runID: failing, code: 3, atNs: later) == .applied)
        #expect(try await service.recordPtyLost(runID: lost, atNs: later) == .applied)
        #expect(try await service.recordProcessExit(runID: UUID(), code: 1, atNs: later) == nil)
        let f = try #require(try await store.agentRun(id: failing))
        #expect(f.activity == .failed && f.statusReason == "exited with 3" && f.endedAt != nil)
        #expect(try await store.agentRun(id: lost)?.activity == .interrupted)
        #expect(try await service.recordProcessExit(runID: failing, code: 3, atNs: later) == .duplicate)
        try await store.close()
    }

    @Test func updatesStreamReportsEachTransition() async throws {
        let (home, store, service) = try await setup(); defer { home.remove() }
        let run = UUID()
        let envelopes = RealHooks.envelopes(Array(try RealHooks.events(RealHooks.claudeBasic).prefix(5)), runID: run, paneID: nil)
        var iterator = service.updates.makeAsyncIterator()
        for e in envelopes { try await service.ingest(e) }
        var activities: [AgentActivity] = []
        for _ in envelopes { activities.append(try #require(await iterator.next()).activity) }
        #expect(activities == [.idle, .working, .working, .working, .done])
        try await store.close()
    }

    @Test func reconcileHealsAProjectionThatLaggedBehindItsEvents() async throws {
        let (home, store, service) = try await setup(); defer { home.remove() }
        let run = UUID()
        let terminal = try await home.seedTerminal(store)
        let envelopes = RealHooks.envelopes(try RealHooks.events(RealHooks.claudeBasic), runID: run, paneID: terminal.id)
        // Simula a queda entre gravar o evento e projetar: eventos gravados, `agent_run` ainda em `starting`.
        let seed = AgentRun(id: run, terminalID: terminal.id, harness: .claude, activity: .starting, startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        for e in envelopes {
            let json = String(decoding: try HookCodec.encoder().encode(e.payload), as: UTF8.self)
            _ = try await store.recordAgentEvent(NewAgentEvent(runID: run, eventID: e.id, type: e.event, payloadJSON: json, atNs: e.atNs), ensuringRun: seed)
        }
        #expect(try await store.agentRun(id: run)?.activity == .starting)
        #expect(try await store.runsNeedingReconcile() == [run])
        await service.reconcile()
        #expect(try await store.agentRun(id: run)?.activity == .done)
        #expect(try await store.runsNeedingReconcile().isEmpty)
        #expect(try await store.terminal(id: terminal.id)?.lastMessage == "DONE")
        try await store.close()
    }
}

@Suite struct SpoolIngestionTests {
    /// O que o helper faz com o app fechado: um append por evento.
    private func spoolAsHelper(_ envelopes: [HookEnvelope], in home: ActivityHome) throws {
        for e in envelopes {
            try HookSpool.append(try HookCodec.line(e), runID: e.runID, directory: home.spoolDirectory, nowNs: e.atNs)
        }
    }

    @Test func appClosedTurnIsRecoveredOnOpen() async throws {
        let home = try ActivityHome(); defer { home.remove() }
        let run = UUID()
        let paneID = UUID()
        let envelopes = RealHooks.envelopes(try RealHooks.events(RealHooks.claudeBasic), runID: run, paneID: paneID)
        try spoolAsHelper(envelopes, in: home)  // o app nem existe ainda
        let spoolFile = HookSpool.fileURL(directory: home.spoolDirectory, runID: run.uuidString)
        #expect(FileManager.default.fileExists(atPath: spoolFile.path))
        var st = stat()
        #expect(stat(spoolFile.path, &st) == 0 && st.st_mode & 0o777 == 0o600)
        #expect(stat(home.spoolDirectory.path, &st) == 0 && st.st_mode & 0o777 == 0o700)

        let store = try await home.openStore()
        let terminal = Terminal(id: paneID, tabID: UUID(), provider: .claude, title: "x", cwd: "/", launchSpec: LaunchSpec(provider: .claude))
        _ = terminal  // o terminal não existe: a execução nasce sem terminal; o estado e a mensagem vêm do spool
        let service = ActivityService(store: store, spoolDirectory: home.spoolDirectory)
        try await service.start()
        let row = try #require(try await store.agentRun(id: run))
        #expect(row.activity == .done)
        #expect(!FileManager.default.fileExists(atPath: spoolFile.path))
        #expect(try await store.agentEventCount(runID: run) == 6)
        await service.stop()
        try await store.close()
    }

    @Test func corruptedLinesNeverBlockTheOnesAfterThem() async throws {
        let home = try ActivityHome(); defer { home.remove() }
        let store = try await home.openStore()
        let service = ActivityService(store: store, spoolDirectory: home.spoolDirectory)
        let run = UUID()
        let e = RealHooks.envelopes(try RealHooks.events(RealHooks.claudeBasic), runID: run, paneID: nil)
        let badRun = HookEnvelope(provider: .claude, event: "Stop", runID: "not-a-uuid", atNs: 5, payload: .init())
        try HookSpool.ensureDirectory(home.spoolDirectory)
        let file = HookSpool.fileURL(directory: home.spoolDirectory, runID: run.uuidString)
        var content = Data()
        for line in [
            try HookCodec.line(e[0]), Data("this is not json".utf8), try HookCodec.line(e[1]), Data("{\"v\":1,\"truncated\":".utf8),
            try HookCodec.encoder().encode(HookSpoolMarker(dropped: 7, atNs: 3)), try HookCodec.line(badRun), try HookCodec.line(e[4]),
        ] { content.append(line); content.append(0x0A) }
        try content.write(to: file)

        let report = await service.drainSpool()
        #expect(report.files == 1)
        #expect(report.applied == 3)
        #expect(report.invalid == 3)  // texto solto, JSON cortado e run id inválido
        #expect(report.truncatedMarkers == 1)
        #expect(report.deferred == 0)
        #expect(try await store.agentRun(id: run)?.activity == .done)
        #expect(!FileManager.default.fileExists(atPath: file.path), "o cursor avança mesmo com linhas inválidas")
        #expect((await service.drainSpool()).files == 0)
        try await store.close()
    }

    @Test func spoolAndLiveEventsInterleavedOutOfOrderConverge() async throws {
        let home = try ActivityHome(); defer { home.remove() }
        let store = try await home.openStore()
        let service = ActivityService(store: store, spoolDirectory: home.spoolDirectory)
        let run = UUID()
        let e = RealHooks.envelopes(try RealHooks.events(RealHooks.claudeBasic), runID: run, paneID: nil)
        // O app voltou no meio do turno: os eventos novos chegam pelo socket antes de o spool antigo ser drenado.
        for ev in e[3...] { try await service.ingest(ev) }
        try spoolAsHelper(Array(e[0..<3]), in: home)
        let report = await service.drainSpool()
        #expect(report.applied == 3)
        let row = try #require(try await store.agentRun(id: run))
        #expect(row.activity == .done)
        #expect(row.startedAt == Date(timeIntervalSince1970: Double(e[0].atNs) / 1_000_000_000))
        try await store.close()
    }

    @Test func drainingFileLeftByACrashIsReprocessedIdempotently() async throws {
        let home = try ActivityHome(); defer { home.remove() }
        let store = try await home.openStore()
        let service = ActivityService(store: store, spoolDirectory: home.spoolDirectory)
        let run = UUID()
        let e = RealHooks.envelopes(try RealHooks.events(RealHooks.claudeBasic), runID: run, paneID: nil)
        for ev in e[0..<3] { try await service.ingest(ev) }
        try HookSpool.ensureDirectory(home.spoolDirectory)
        let leftover = home.spoolDirectory.appendingPathComponent("\(run.uuidString).jsonl.deadbeef.draining")
        var content = Data()
        for ev in e { content.append(try HookCodec.line(ev)); content.append(0x0A) }  // 3 já aplicados + 3 novos
        try content.write(to: leftover)
        let report = await service.drainSpool()
        #expect(report.duplicates == 3 && report.applied == 3)
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(try await store.agentEventCount(runID: run) == 6)
        try await store.close()
    }

    @Test func kqueueWatcherDrainsSpoolFilesWrittenWhileTheAppRuns() async throws {
        let home = try ActivityHome(); defer { home.remove() }
        let store = try await home.openStore()
        let service = ActivityService(store: store, spoolDirectory: home.spoolDirectory)
        try await service.start()
        let run = UUID()
        try spoolAsHelper(RealHooks.envelopes(try RealHooks.events(RealHooks.claudeBasic), runID: run, paneID: nil), in: home)
        let reached = await waitUntil { (try? await store.agentRun(id: run))?.activity == .done }
        #expect(reached, "o diretório é observado por kqueue, sem polling")
        await service.stop()
        try await store.close()
    }

    @Test func spoolFailureKeepsTheFileWhenTheDatabaseIsReadOnly() async throws {
        let home = try ActivityHome(); defer { home.remove() }
        let store = try await home.openStore()
        let service = ActivityService(store: store, spoolDirectory: home.spoolDirectory)
        let run = UUID()
        try spoolAsHelper(RealHooks.envelopes(Array(try RealHooks.events(RealHooks.claudeBasic).prefix(2)), runID: run, paneID: nil), in: home)
        try await store.close()  // fecha o banco: toda gravação falha
        let report = await service.drainSpool()
        #expect(report.deferred == 2 && report.applied == 0)
        let kept = try FileManager.default.contentsOfDirectory(atPath: home.spoolDirectory.path).filter { $0.hasSuffix(".draining") }
        #expect(kept.count == 1, "erro transitório não perde eventos")
    }
}
