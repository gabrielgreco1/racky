import RackyPlatform
import RackyProtocol
import RackyStore
import Foundation
import Testing

@testable import RackyCore

/// Serviço `hook` que demora a responder (ou recusa), para os testes de prazo.
private struct SlowHookProvider: AppSockServiceProvider {
    let service = AppSockService.hook
    var delay: Duration = .seconds(3)
    var refuse: CtlError?
    func admit() -> CtlError? { refuse }
    func makeHandler() -> AppSockServer.Handler {
        let delay = delay
        return { _ in
            try? await Task.sleep(for: delay)
            return AppSockReply(frames: [(try? HookCodec.encoder().encode(HookAck(ok: true))) ?? Data()], close: true)
        }
    }
}

/// Prazo folgado para os testes funcionais: com a suíte inteira rodando em paralelo o app de teste pode demorar mais que 200 ms.
private let generous = 5_000

private let emptyTree = UITreeSnapshot(window: UIWindowInfo(title: "Racky", width: 100, height: 100, scale: 2, isKey: true), roots: [])

private func sampleEnvelope(run: UUID = UUID(), id: String = UUID().uuidString.lowercased()) -> HookEnvelope {
    HookEnvelope(id: id, provider: .claude, event: "Stop", runID: run.uuidString, atNs: HookTransport.realtimeNs(), payload: .init(lastAssistantMessage: "DONE"))
}

@Suite(.tags(.integration)) struct HookTransportTests {
    @Test func hookAndCtlServicesShareOneAppSock() async throws {
        let home = try ActivityHome(); defer { home.remove() }
        let store = try await home.openStore()
        let activity = ActivityService(store: store, spoolDirectory: home.spoolDirectory)
        let hub = AppSockHub(socketPath: home.socketPath, providers: [
            HookServiceProvider(activity: activity), CtlServiceProvider(dispatcher: FakeDispatcher(tree: emptyTree)),
        ])
        try await hub.start()

        let envelope = sampleEnvelope()
        let line = try HookCodec.line(envelope)
        let socket = home.socketPath
        #expect(await offPool { HookTransport.deliver(line, socketPath: socket, timeoutMs: generous) } == .delivered(duplicate: false))
        #expect(await offPool { HookTransport.deliver(line, socketPath: socket, timeoutMs: generous) } == .delivered(duplicate: true))
        let run = try #require(UUID(uuidString: envelope.runID))
        #expect(try await store.agentRun(id: run)?.activity == .done)

        // O `ctl` continua funcionando no mesmo socket.
        let conn = try AppSockClient.connect(path: socket)
        try await conn.send(try CtlCodec.encoder().encode(AppSockHello(service: .ctl)))
        #expect(try CtlCodec.decoder().decode(AppSockHelloReply.self, from: try await conn.receive()).ok)
        try await conn.send(try CtlCodec.encoder().encode(CtlRequest(command: .state)))
        #expect(try CtlCodec.decoder().decode(CtlResponse.self, from: try await conn.receive()).ok)
        await conn.close()

        // `mcp` ainda não existe: recusa com erro claro, sem derrubar o hub.
        let mcp = try AppSockClient.connect(path: socket)
        try await mcp.send(try CtlCodec.encoder().encode(AppSockHello(service: .mcp)))
        let refused = try CtlCodec.decoder().decode(AppSockHelloReply.self, from: try await mcp.receive())
        #expect(!refused.ok && refused.error?.code == "service_unavailable")
        await mcp.close()

        await hub.stop()
        try await store.close()
    }

    @Test func disabledCtlDoesNotAffectTheHookService() async throws {
        let home = try ActivityHome(); defer { home.remove() }
        let store = try await home.openStore()
        let activity = ActivityService(store: store, spoolDirectory: home.spoolDirectory)
        let hub = AppSockHub(socketPath: home.socketPath, providers: [
            HookServiceProvider(activity: activity),
            CtlServiceProvider(dispatcher: FakeDispatcher(tree: emptyTree), isEnabled: { false }),
        ])
        try await hub.start()
        let line = try HookCodec.line(sampleEnvelope()), socket = home.socketPath
        #expect(await offPool { HookTransport.deliver(line, socketPath: socket, timeoutMs: generous) }.isDelivered)
        let ctl = try AppSockClient.connect(path: socket)
        try await ctl.send(try CtlCodec.encoder().encode(AppSockHello(service: .ctl)))
        #expect(try CtlCodec.decoder().decode(AppSockHelloReply.self, from: try await ctl.receive()).error?.code == "ctl_disabled")
        await ctl.close()
        await hub.stop()
        try await store.close()
    }

    @Test func noSocketIsUnavailableAlmostImmediately() async throws {
        let home = try ActivityHome(); defer { home.remove() }
        let line = try HookCodec.line(sampleEnvelope()), socket = home.socketPath
        let (outcome, elapsedNs) = await offPool { () -> (HookTransport.Outcome, UInt64) in
            let start = HookTransport.monotonicNs()
            let outcome = HookTransport.deliver(line, socketPath: socket)
            return (outcome, HookTransport.monotonicNs() - start)
        }
        guard case .unavailable = outcome else { Issue.record("expected unavailable, got \(outcome)"); return }
        #expect(elapsedNs < 100_000_000, "sem socket não espera nada: \(elapsedNs) ns")
    }

    @Test func appThatAcceptsButNeverAnswersHitsTheTwoHundredMillisecondDeadline() async throws {
        let home = try ActivityHome(); defer { home.remove() }
        let hub = AppSockHub(socketPath: home.socketPath, providers: [SlowHookProvider()])
        try await hub.start()
        let line = try HookCodec.line(sampleEnvelope()), socket = home.socketPath
        // O tempo é medido dentro da thread do helper: agendamento do pool do teste sob carga não conta.
        let (outcome, elapsedNs) = await offPool { () -> (HookTransport.Outcome, UInt64) in
            let start = HookTransport.monotonicNs()
            let outcome = HookTransport.deliver(line, socketPath: socket)
            return (outcome, HookTransport.monotonicNs() - start)
        }
        guard case .unavailable = outcome else { Issue.record("expected unavailable, got \(outcome)"); return }
        #expect(elapsedNs >= 190_000_000, "esperou o prazo inteiro antes de desistir: \(elapsedNs) ns")
        #expect(elapsedNs < 260_000_000, "mas nunca muito além dele: \(elapsedNs) ns")
        await hub.stop()
    }

    @Test func refusedHandshakeIsReportedAsRejected() async throws {
        let home = try ActivityHome(); defer { home.remove() }
        let hub = AppSockHub(socketPath: home.socketPath, providers: [SlowHookProvider(refuse: CtlError(code: "x", message: "busy"))])
        try await hub.start()
        let line = try HookCodec.line(sampleEnvelope()), socket = home.socketPath
        #expect(await offPool { HookTransport.deliver(line, socketPath: socket, timeoutMs: generous) } == .rejected("busy"))
        await hub.stop()
    }

    @Test func invalidAndOversizedFramesAreAckedAsErrors() async throws {
        let home = try ActivityHome(); defer { home.remove() }
        let store = try await home.openStore()
        let hub = AppSockHub(socketPath: home.socketPath, providers: [
            HookServiceProvider(activity: ActivityService(store: store, spoolDirectory: home.spoolDirectory))
        ])
        try await hub.start()
        let socket = home.socketPath
        guard case .rejected(let m1) = await offPool({ HookTransport.deliver(Data("nope".utf8), socketPath: socket, timeoutMs: generous) }) else {
            Issue.record("garbage must be rejected"); return
        }
        #expect(m1 == "not a hook envelope")
        let big = Data(repeating: 0x20, count: HookLimits.maxFrameBytes + 1)
        guard case .rejected(let m2) = await offPool({ HookTransport.deliver(big, socketPath: socket, timeoutMs: generous) }) else {
            Issue.record("oversized must be rejected"); return
        }
        #expect(m2 == "frame too large")
        let badRun = try HookCodec.line(HookEnvelope(provider: .claude, event: "Stop", runID: "zzz", atNs: 1, payload: .init()))
        guard case .rejected = await offPool({ HookTransport.deliver(badRun, socketPath: socket, timeoutMs: generous) }) else {
            Issue.record("bad run id must be rejected"); return
        }
        await hub.stop()
        try await store.close()
    }
}

@Suite struct HookSpoolTests {
    private func tempDir() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/abs-\(UInt32.random(in: 0 ... 0xFFFFFF))/run/spool/hooks", isDirectory: true)
        return url
    }

    @Test func appendCreatesOwnerOnlyFileAndOneLinePerEvent() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        let run = UUID().uuidString
        try HookSpool.append(Data("{\"a\":1}".utf8), runID: run, directory: dir, nowNs: 1)
        try HookSpool.append(Data("{\"b\":\n2}".utf8), runID: run, directory: dir, nowNs: 2)  // quebra interna é removida
        let file = HookSpool.fileURL(directory: dir, runID: run)
        let lines = try HookSpool.readLines(file)
        #expect(lines.count == 2)
        var st = stat()
        #expect(stat(file.path, &st) == 0 && st.st_mode & 0o777 == 0o600)
        #expect(stat(dir.path, &st) == 0 && st.st_mode & 0o777 == 0o700)
    }

    @Test func unsafeRunIDsNeverBecomeFilenames() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        for bad in ["", "../x", "a/b", "a b", String(repeating: "a", count: 65), "é"] {
            #expect(throws: HookSpool.Failure.unsafeRunID) { try HookSpool.append(Data("{}".utf8), runID: bad, directory: dir, nowNs: 1) }
        }
        #expect(HookSpool.isSafeRunID(UUID().uuidString))
    }

    @Test func overTheLimitDropsOldestAndWritesATruncatedMarker() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        let run = UUID().uuidString
        let payload = String(repeating: "x", count: 90)
        for i in 0..<300 {
            try HookSpool.append(Data("{\"i\":\(i),\"p\":\"\(payload)\"}".utf8), runID: run, directory: dir, nowNs: Int64(i), limitBytes: 16_384, keepBytes: 12_288)
        }
        let file = HookSpool.fileURL(directory: dir, runID: run)
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as! Int
        #expect(size <= 16_384)
        let lines = try HookSpool.readLines(file)
        guard case .marker(let marker) = HookSpoolLine.parse(lines[0]) else { Issue.record("first line must be the truncated marker"); return }
        #expect(marker.dropped > 0)
        // O marcador é único e o total de linhas + descartados fecha com os 300 eventos escritos.
        let events = lines.dropFirst().filter { if case .invalid = HookSpoolLine.parse($0) { true } else { false } }
        let kept = lines.count - 1
        #expect(events.count == kept)
        #expect(kept + marker.dropped == 300)
        // Os mais novos sobrevivem.
        let last = try #require(String(data: lines.last!, encoding: .utf8))
        #expect(last.contains("\"i\":299"))
        var markers = 0
        for l in lines { if case .marker = HookSpoolLine.parse(l) { markers += 1 } }
        #expect(markers == 1)
    }

    @Test func concurrentWritersAndADrainerLoseNothing() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        try HookSpool.ensureDirectory(dir)
        let run = UUID().uuidString
        let writers = 6, perWriter = 120
        let collected = Collector()
        await withTaskGroup(of: Void.self) { group in
            for w in 0..<writers {
                group.addTask {
                    await offPool {
                        for i in 0..<perWriter {
                            try? HookSpool.append(Data("{\"w\":\(w),\"i\":\(i)}".utf8), runID: run, directory: dir, nowNs: Int64(i))
                        }
                    }
                }
            }
            group.addTask {
                await offPool {
                    for _ in 0..<60 {
                        for file in (try? HookSpool.takeAll(directory: dir)) ?? [] {
                            collected.add((try? HookSpool.readLines(file)) ?? [])
                            HookSpool.discard(file)
                        }
                    }
                }
            }
        }
        for file in try HookSpool.takeAll(directory: dir) {
            collected.add(try HookSpool.readLines(file))
            HookSpool.discard(file)
        }
        let seen = collected.lines
        #expect(seen.count == writers * perWriter, "nenhuma linha perdida ou duplicada com leitura concorrente")
        #expect(Set(seen).count == seen.count)
    }

    @Test func takeAllIgnoresTemporariesAndReturnsLeftoverDrainingFiles() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        try HookSpool.ensureDirectory(dir)
        try Data("{}\n".utf8).write(to: dir.appendingPathComponent(".r.123.tmp"))
        try Data("{}\n".utf8).write(to: dir.appendingPathComponent("r.jsonl.cafe.draining"))
        try HookSpool.append(Data("{\"n\":1}".utf8), runID: "r2", directory: dir, nowNs: 1)
        let files = try HookSpool.takeAll(directory: dir)
        #expect(files.map(\.lastPathComponent).contains("r.jsonl.cafe.draining"))
        #expect(files.count == 2)
        #expect(!files.contains { $0.lastPathComponent.hasSuffix(".tmp") })
        #expect(try HookSpool.takeAll(directory: dir.appendingPathComponent("missing")).isEmpty)
    }
}

final class Collector: @unchecked Sendable {  // SAFETY: todo acesso passa por `queue`.
    private let queue = DispatchQueue(label: "collector")
    private var storage: [Data] = []
    func add(_ lines: [Data]) { queue.sync { storage.append(contentsOf: lines) } }
    var lines: [Data] { queue.sync { storage } }
}
