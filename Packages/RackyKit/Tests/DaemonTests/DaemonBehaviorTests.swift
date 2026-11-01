@testable import RackyCore
import RackyProtocol
import Darwin
import Foundation
import Testing

@testable import RackyPlatform

@Suite(.serialized, .tags(.integration), .timeLimit(.minutes(1))) struct DaemonBehaviorTests {
    private func withDaemon(idleExit: Int = 0, sessionLeader: Bool = false, _ body: (DaemonHarness) async throws -> Void) async throws {
        let harness = try DaemonHarness()
        defer { harness.terminateNow() }
        try await harness.start(idleExit: idleExit, sessionLeader: sessionLeader)
        do {
            try await body(harness)
        } catch {
            await harness.stop()
            throw error
        }
        await harness.stop()
    }

    @Test func createAttachInputOutputAndIdempotentCreate() async throws {
        try await withDaemon { harness in
            let client = harness.makeClient()
            try await client.start()
            let create = makeCreate(["cat"])
            let created = try await client.create(create)
            #expect(created.spawned)
            #expect(created.session.state == .running)
            #expect(created.session.pgid == created.session.pid)
            let attachment = try await client.attach(sessionID: create.sessionID, cols: 100, rows: 30)
            #expect(attachment.snapshot.sessionID == create.sessionID)
            let collector = Collector()
            await collector.run(attachment)
            try await client.sendInput(sessionID: create.sessionID, origin: .key, bytes: data("hello-daemon\n"))
            try await eventually("echo") { await collector.text.contains("hello-daemon") }

            let again = try await client.create(create)
            #expect(!again.spawned)
            #expect(again.session.pid == created.session.pid)

            let listed = try await client.list()
            let summary = try #require(listed.first { $0.sessionID == create.sessionID })
            #expect(summary.inputBytesByOrigin[.key] == 13)
            #expect(summary.endSeq > 0)
            let text = try await client.textSnapshot(sessionID: create.sessionID, lines: 50)
            #expect(text.contains("hello-daemon"))
            let pong = try await client.ping()
            #expect(pong.activeSessions == 1)
            try await client.kill(sessionID: create.sessionID, mode: .force)
            await client.stop()
        }
    }

    @Test func outputSeqIsContinuousAcrossFrames() async throws {
        try await withDaemon { harness in
            let client = harness.makeClient()
            try await client.start()
            let create = makeCreate(["/bin/sh", "-c", "yes 0123456789 | head -c 600000; sleep 600"])
            _ = try await client.create(create)
            let attachment = try await client.attach(sessionID: create.sessionID, cols: 100, rows: 30)
            var validator = OutputSequenceValidator(expectedSeq: attachment.snapshot.startSeq)
            var received: UInt64 = 0
            var snapshots = 0
            for await update in attachment.updates {
                switch update {
                case .output(let frame):
                    #expect(validator.accept(frame) == .continuous)
                    #expect(frame.bytes.count <= ProtocolLimits.coalesceBytes)
                    received += UInt64(frame.bytes.count)
                case .snapshot: snapshots += 1
                default: break
                }
                // PTY transforma \n em \r\n: 600000 bytes de `yes` viram mais.
                if received >= 600_000 { break }
            }
            #expect(snapshots == 1)
            try await client.kill(sessionID: create.sessionID, mode: .force)
            await client.stop()
        }
    }

    @Test func killLeavesNoOrphans() async throws {
        try await withDaemon { harness in
            for mode in [KillMode.graceful, KillMode.force] {
                let client = harness.makeClient()
                try await client.start()
                let create = makeCreate(["/bin/sh", "-c", "sleep 600 & echo bg1:$!; sleep 600 & echo bg2:$!; echo fg:$$; wait"])
                _ = try await client.create(create)
                let attachment = try await client.attach(sessionID: create.sessionID, cols: 100, rows: 30)
                let collector = Collector()
                await collector.run(attachment)
                try await eventually("pids") { let t = await collector.text; return t.contains("fg:") && t.contains("bg2:") }
                let text = await collector.text
                let pids = text.components(separatedBy: .newlines).compactMap { line -> Int32? in
                    guard let colon = line.firstIndex(of: ":") else { return nil }
                    return Int32(line[line.index(after: colon)...])
                }
                #expect(pids.count == 3, "text: \(text.debugDescription)")
                for pid in pids { #expect(processIsAlive(pid)) }
                let events = EventBox()
                let watcher = Task {
                    for await event in client.events { await events.add(event) }
                }
                try await client.subscribe(.sessions([create.sessionID]), events: [.exit])
                try await client.kill(sessionID: create.sessionID, mode: mode)
                try await eventually("exit event") { await events.hasExit }
                try await eventually("all processes gone") { pids.allSatisfy { !processIsAlive($0) } }
                for pid in pids { #expect(!processIsAlive(pid), "pid \(pid) survived kill \(mode)") }
                watcher.cancel()
                let summary = try #require(try await client.list().first { $0.sessionID == create.sessionID })
                #expect(summary.state == .exited)
                #expect(summary.exit != nil)
                try await client.forget(sessionID: create.sessionID)
                await client.stop()
            }
        }
    }

    /// Cliente que não lê: a fila de 2 MiB estoura, o daemon manda `resyncRequired` e o cliente refaz `attach`.
    @Test func slowClientGetsResyncRequired() async throws {
        try await withDaemon { harness in
            let connection = try await UDSClient.connect(path: harness.socketPath)
            let framed = FramedConnection(connection)
            _ = try await framed.performHandshake(ClientHandshake(client: ClientInfo(kind: .app, build: "slow")))
            let create = makeCreate(["/bin/sh", "-c", "yes 'flood line of plain text 0123456789 abcdefghijklmnopqrstuvwxyz' | head -c 40000000; sleep 600"])
            try await framed.send(.control(.request(DaemonRequest(id: 2, command: .create(create)))))
            try await framed.send(.control(.request(DaemonRequest(id: 3, command: .attach(AttachRequest(sessionID: create.sessionID, cols: 100, rows: 30, mode: .snapshot))))))
            // Não lê por um tempo: o socket enche e a fila do daemon passa de 2 MiB.
            try await Task.sleep(for: .seconds(3))
            var sawResync = false
            var resyncAnswered = false
            var framesAfterResync = 0
            var nextID: UInt64 = 4
            let deadline = ContinuousClock.now + .seconds(30)
            while ContinuousClock.now < deadline, let frame = try await framed.receive() {
                switch frame {
                case .control(.event(let event)) where event.payload == .resyncRequired:
                    if !sawResync {
                        sawResync = true
                        let request = AttachRequest(sessionID: create.sessionID, cols: 100, rows: 30, mode: .snapshot)
                        try await framed.send(.control(.request(DaemonRequest(id: RequestID(rawValue: nextID), command: .attach(request)))))
                        nextID += 1
                    }
                case .control(.reply(.attachSnapshot)):
                    if sawResync { resyncAnswered = true }
                case .output:
                    if resyncAnswered { framesAfterResync += 1 }
                default: break
                }
                if resyncAnswered, framesAfterResync > 20 { break }
            }
            #expect(sawResync, "daemon must send resyncRequired when the 2 MiB client queue overflows")
            #expect(resyncAnswered)
            #expect(framesAfterResync > 20, "stream resumes after the snapshot attach")
            // O daemon continua atendendo outro cliente enquanto o lento existia.
            let other = harness.makeClient()
            try await other.start()
            _ = try await other.ping()
            try await other.kill(sessionID: create.sessionID, mode: .force)
            await other.stop()
            await framed.close()
        }
    }

    @Test func twoConnectionsSeeTheSameSessionIndependently() async throws {
        try await withDaemon { harness in
            let first = harness.makeClient()
            let second = harness.makeClient()
            try await first.start()
            try await second.start()
            let create = makeCreate(["cat"])
            _ = try await first.create(create)
            let a = try await first.attach(sessionID: create.sessionID, cols: 100, rows: 30)
            let b = try await second.attach(sessionID: create.sessionID, cols: 100, rows: 30)
            let collectorA = Collector()
            let collectorB = Collector()
            await collectorA.run(a)
            await collectorB.run(b)
            try await first.sendInput(sessionID: create.sessionID, origin: .key, bytes: data("from-first\n"))
            try await second.sendInput(sessionID: create.sessionID, origin: .userPaste, bytes: data("from-second\n"))
            try await eventually("both see both") {
                let ta = await collectorA.text, tb = await collectorB.text
                return ta.contains("from-first") && ta.contains("from-second") && tb.contains("from-first") && tb.contains("from-second")
            }
            let summary = try #require(try await first.list().first)
            #expect(summary.inputBytesByOrigin[.key] == 11)
            #expect(summary.inputBytesByOrigin[.userPaste] == 12)
            // Detach de um não afeta o outro.
            try await second.detach(sessionID: create.sessionID)
            try await first.sendInput(sessionID: create.sessionID, origin: .key, bytes: data("after-detach\n"))
            try await eventually("first still streams") { await collectorA.text.contains("after-detach") }
            #expect(await !collectorB.text.contains("after-detach"))
            try await first.kill(sessionID: create.sessionID, mode: .force)
            await first.stop()
            await second.stop()
        }
    }

    @Test func exitEventAndAttachToExitedSession() async throws {
        try await withDaemon { harness in
            let client = harness.makeClient()
            try await client.start()
            let create = makeCreate(["/bin/sh", "-c", "echo bye-bye; exit 3"])
            _ = try await client.create(create)
            try await eventually("exited") { (try? await client.list().first?.state) == .exited }
            let summary = try #require(try await client.list().first)
            #expect(summary.exit?.code == 3)
            let attachment = try await client.attach(sessionID: create.sessionID, cols: 100, rows: 30)
            let replica = Replica(cols: 100, rows: 30)
            await replica.run(attachment)
            await replica.waitQuiet(.milliseconds(300))
            #expect(await replica.screen().contains("bye-bye"))
            await #expect(throws: PTYClientError.self) { try await client.resize(sessionID: create.sessionID, cols: 80, rows: 24) }
            try await client.forget(sessionID: create.sessionID)
            #expect(try await client.list().isEmpty)
            await client.stop()
        }
    }

    /// O processo tem tty de controle: o resize vira SIGWINCH de verdade (o Claude só redesenha na largura nova se receber o
    /// sinal; medir o tamanho com `stty` não basta) e o `ps` mostra o tty, não `??`.
    @Test(arguments: [false, true]) func resizeDeliversSIGWINCHBecauseTheChildOwnsItsTTY(launchdLike: Bool) async throws {
        try await withDaemon(sessionLeader: launchdLike) { harness in
            let client = harness.makeClient()
            try await client.start()
            // O trap só marca; o laço lê o tamanho atual. Com `$(stty size)` dentro do trap, o SIGWINCH do attach ocupava o
            // handler e o `sh` descartava o do resize (o teste falhava em ~metade das vezes, sem bug no daemon).
            let script = "trap 'w=1' WINCH; echo TTY-$(ps -o tty= -p $$); "
                + "while :; do if [ -n \"$w\" ]; then w=; echo WINCH-$(stty size); fi; sleep 0.05; done"
            let create = makeCreate(["/bin/sh", "-c", script])
            _ = try await client.create(create)
            let attachment = try await client.attach(sessionID: create.sessionID, cols: 100, rows: 30)
            let replica = Replica(cols: 100, rows: 30)
            Task { await replica.run(attachment) }
            try await eventually("tty reported") { await replica.screen().contains("TTY-") }
            #expect(await !replica.screen().contains("TTY-??"), "sem tty de controle o kernel não entrega SIGWINCH")
            try await client.resize(sessionID: create.sessionID, cols: 132, rows: 40)
            try await eventually("SIGWINCH delivered") { await replica.screen().contains("WINCH-40 132") }
            try await client.kill(sessionID: create.sessionID, mode: .force)
            await client.stop()
        }
    }

    @Test func errorsAreTyped() async throws {
        try await withDaemon { harness in
            let client = harness.makeClient()
            try await client.start()
            do {
                _ = try await client.attach(sessionID: SessionID(), cols: 80, rows: 24)
                Issue.record("attach to unknown session must fail")
            } catch PTYClientError.daemon(let error) {
                #expect(error.code == .unknownSession)
            }
            do {
                _ = try await client.create(makeCreate(["/definitely/not/here"]))
                Issue.record("spawn of missing executable must fail")
            } catch PTYClientError.daemon(let error) {
                #expect(error.code == .spawnFailed)
                #expect(error.errnoValue == ENOENT)
                #expect(error.path == "/definitely/not/here")
            }
            do {
                _ = try await client.create(makeCreate(["cat"], cwd: "/definitely/not/a/dir"))
                Issue.record("spawn with missing cwd must fail")
            } catch PTYClientError.daemon(let error) {
                #expect(error.code == .spawnFailed)
                #expect(error.path == "/definitely/not/a/dir")
            }
            await client.stop()
        }
    }

    /// AR-105: sem cliente anexado o headless responde DA/DSR (origem `terminalReply`); nunca OSC 52 de leitura,
    /// cores (OSC 4/10/11) nem DECRQSS.
    @Test func headlessAnswersDeviceQueriesButNeverOSC52() async throws {
        try await withDaemon { harness in
            let client = harness.makeClient()
            try await client.start()
            let forbidden = "printf '\u{1b}]52;c;?\u{07}\u{1b}]11;?\u{07}\u{1b}]10;?\u{07}\u{1b}]4;1;?\u{07}\u{1b}P$qm\u{1b}\\\\'; sleep 600"
            let queries = makeCreate(["/bin/sh", "-c", forbidden])
            _ = try await client.create(queries)
            let device = makeCreate(["/bin/sh", "-c", "printf '\u{1b}[c\u{1b}[5n'; sleep 600"])
            _ = try await client.create(device)
            try await eventually("device query answered") {
                let sessions = (try? await client.list()) ?? []
                return sessions.first { $0.sessionID == device.sessionID }?.inputBytesByOrigin[.terminalReply] ?? 0 > 0
            }
            try await Task.sleep(for: .milliseconds(500))
            let sessions = try await client.list()
            let forbiddenSession = try #require(sessions.first { $0.sessionID == queries.sessionID })
            #expect(forbiddenSession.inputBytesByOrigin.total == 0, "nobody may answer OSC 52 read, color queries or DECRQSS")
            // Com cliente anexado o daemon não responde (responde o emulador da UI).
            let attached = makeCreate(["/bin/sh", "-c", "sleep 1; printf '\u{1b}[c'; sleep 600"])
            _ = try await client.create(attached)
            _ = try await client.attach(sessionID: attached.sessionID, cols: 100, rows: 30)
            try await Task.sleep(for: .seconds(2))
            let after = try await client.list()
            #expect(after.first { $0.sessionID == attached.sessionID }?.inputBytesByOrigin[.terminalReply] ?? 0 == 0)
            for id in [queries.sessionID, device.sessionID, attached.sessionID] { try await client.kill(sessionID: id, mode: .force) }
            await client.stop()
        }
    }

    @Test func coldLogKeepsOutputWithRotationAndNoEnvValues() async throws {
        try await withDaemon { harness in
            let client = harness.makeClient()
            try await client.start()
            let create = makeCreate(
                ["/bin/sh", "-c", "echo cold-log-marker; yes 'rotating cold log line 0123456789 abcdefghijklmnop' | head -c 18000000; echo end-marker"], coldLog: true,
                env: ["SECRET_TOKEN": "super-secret-value-123"])
            _ = try await client.create(create)
            try await eventually("exited", timeout: .seconds(120)) { (try? await client.list().first?.state) == .exited }
            let directory = harness.sessionsDirectory.appendingPathComponent(create.sessionID.description)
            try await eventually("cold log flushed") {
                let meta = try? String(contentsOf: directory.appendingPathComponent("meta.json"), encoding: .utf8)
                return meta?.contains("\"exit\"") ?? false
            }
            try await Task.sleep(for: .milliseconds(500))
            let current = directory.appendingPathComponent("output.log")
            let previous = directory.appendingPathComponent("output.log.1")
            let currentSize = try #require(try FileManager.default.attributesOfItem(atPath: current.path)[.size] as? Int)
            let previousSize = try #require(try FileManager.default.attributesOfItem(atPath: previous.path)[.size] as? Int)
            #expect(currentSize <= 8 << 20 && previousSize <= 8 << 20, "2 x 8 MiB rotation")
            #expect(previousSize == 8 << 20)
            let tail = try String(contentsOf: current, encoding: .utf8)
            #expect(tail.contains("end-marker"))
            let meta = try String(contentsOf: directory.appendingPathComponent("meta.json"), encoding: .utf8)
            #expect(meta.contains("SECRET_TOKEN"))
            #expect(!meta.contains("super-secret-value-123"), "meta.json stores env names only")
            var info = stat()
            #expect(stat(current.path, &info) == 0 && info.st_mode & 0o777 == 0o600)
            try await client.forget(sessionID: create.sessionID)
            try await eventually("cold log removed") { !FileManager.default.fileExists(atPath: directory.path) }
            await client.stop()
        }
    }

    @Test func sessionEnvIsExactlyWhatCreateSent() async throws {
        try await withDaemon { harness in
            let client = harness.makeClient()
            try await client.start()
            let create = makeCreate(["/usr/bin/env"], env: ["ONLY_FOR_CHILD": "yes"])
            _ = try await client.create(create)
            try await eventually("exited") { (try? await client.list().first?.state) == .exited }
            let attachment = try await client.attach(sessionID: create.sessionID, cols: 100, rows: 30)
            let collector = Collector()
            await collector.run(attachment)
            try await eventually("env printed") { await collector.text.contains("ONLY_FOR_CHILD=yes") }
            let text = await collector.text
            #expect(text.contains("TERM=xterm-256color"))
            #expect(!text.contains("RACKY_HOME"), "daemon env must not leak into sessions")
            await client.stop()
        }
    }

    @Test func clientReconnectsAndResumesWithSinceSeq() async throws {
        try await withDaemon { harness in
            let client = harness.makeClient()
            try await client.start()
            let create = makeCreate(["cat"])
            _ = try await client.create(create)
            let attachment = try await client.attach(sessionID: create.sessionID, cols: 100, rows: 30)
            let replica = Replica(cols: 100, rows: 30)
            await replica.run(attachment)
            try await client.sendInput(sessionID: create.sessionID, origin: .key, bytes: data("before-drop\n"))
            try await eventually("echo before") { await replica.screen().contains("before-drop") }

            await client.dropConnectionForTesting()
            // Enquanto desconectado, a sessão continua produzindo saída (o `cat` ecoa o que outro cliente digitar).
            let other = harness.makeClient()
            try await other.start()
            try await other.sendInput(sessionID: create.sessionID, origin: .ctl, bytes: data("while-away\n"))
            try await eventually("reconnected and resumed", timeout: .seconds(15)) {
                let resumed = await replica.resumedSnapshots
                let screen = await replica.screen()
                return resumed == 1 && screen.contains("while-away")
            }
            #expect(await replica.disconnects == 1)
            try await client.sendInput(sessionID: create.sessionID, origin: .key, bytes: data("after-resume\n"))
            try await eventually("live again") { await replica.screen().contains("after-resume") }
            let screen = await replica.screen()
            #expect(screen.components(separatedBy: "before-drop").count == 3, "echo + cat output, no duplicate replay")  // 2 ocorrências
            try await other.kill(sessionID: create.sessionID, mode: .force)
            await other.stop()
            await client.stop()
        }
    }

    @Test func clientSurvivesDaemonRestartAndReportsSessionGone() async throws {
        let harness = try DaemonHarness()
        defer { harness.terminateNow() }
        try await harness.start()
        let client = harness.makeClient()
        try await client.start()
        let create = makeCreate(["cat"])
        _ = try await client.create(create)
        let attachment = try await client.attach(sessionID: create.sessionID, cols: 100, rows: 30)
        let replica = Replica(cols: 100, rows: 30)
        await replica.run(attachment)
        await harness.kill()
        try await eventually("disconnected") { await replica.disconnects >= 1 }
        try await harness.start()
        try await eventually("session reported gone", timeout: .seconds(15)) { await replica.events.contains(.sessionGone) }
        _ = try await client.list()
        await client.stop()
        await harness.stop()
    }

    @Test func daemonExitsWhenIdle() async throws {
        let harness = try DaemonHarness()
        defer { harness.terminateNow() }
        try await harness.start(idleExit: 1)
        let client = harness.makeClient()
        try await client.start()
        _ = try await client.ping()
        await client.stop()
        await harness.waitForExit(timeout: .seconds(8))
        #expect(!harness.isRunning, "daemon must exit after the idle period without sessions or clients")
        await harness.stop()
    }

    @Test func drainWhenIdleExitsAfterLastSession() async throws {
        try await withDaemon { harness in
            let client = harness.makeClient()
            try await client.start()
            let create = makeCreate(["/bin/sh", "-c", "sleep 1"])
            _ = try await client.create(create)
            try await client.drainWhenIdle()
            await harness.waitForExit(timeout: .seconds(8))
            #expect(!harness.isRunning)
            await client.stop()
        }
    }
}

actor EventBox {
    private(set) var events: [DaemonEvent] = []
    func add(_ event: DaemonEvent) { events.append(event) }
    var hasExit: Bool {
        events.contains { if case .exit = $0.payload { true } else { false } }
    }
}
