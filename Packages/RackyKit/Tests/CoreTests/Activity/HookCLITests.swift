import RackyPlatform
import RackyProtocol
import RackyStore
import Foundation
import Testing

@testable import RackyCore

/// `racky` real (construído ao lado do bundle de testes) rodando como processo filho: é o que o Claude e o Codex chamam.
private func rackyBinary() -> URL {
    for bundle in Bundle.allBundles where bundle.bundleURL.pathExtension == "xctest" {
        return bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("racky")
    }
    return URL(fileURLWithPath: ".build/debug/racky")
}

private struct HookRun {
    var status: Int32
    var stdout: String
    var stderr: String
    var duration: Duration
}

private func runHook(
    arguments: [String] = ["hook", "--provider", "claude", "--event", "Stop"], stdin: Data, home: ActivityHome?,
    runID: String? = UUID().uuidString, paneID: String? = UUID().uuidString, extraEnv: [String: String] = [:], path: String? = nil,
    generousTimeout: Bool = false
) async throws -> HookRun {
    let process = Process()
    process.executableURL = rackyBinary()
    process.arguments = arguments
    var env = ["PATH": path ?? "/usr/bin:/bin", "HOME": home?.root.path ?? "/tmp"]
    if let home { env["RACKY_APP_SOCK"] = home.socketPath }
    if let runID { env["RACKY_RUN_ID"] = runID }
    if let paneID { env["RACKY_PANE_ID"] = paneID }
    env["RACKY_HOOK_TIMEOUT_MS"] = generousTimeout ? "5000" : nil
    env.merge(extraEnv) { _, new in new }
    process.environment = env
    let input = Pipe(), output = Pipe(), error = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = error
    let start = ContinuousClock.now
    signal(SIGPIPE, SIG_IGN)  // o helper pode sair sem ler o stdin (sem RACKY_RUN_ID): não derruba o teste
    try process.run()
    return await offPool {
        try? input.fileHandleForWriting.write(contentsOf: stdin)
        try? input.fileHandleForWriting.close()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return HookRun(
            status: process.terminationStatus, stdout: String(decoding: out, as: UTF8.self), stderr: String(decoding: err, as: UTF8.self),
            duration: start.duration(to: .now))
    }
}

private func rawPayload(_ raw: RealHooks.Raw) throws -> Data { try JSONSerialization.data(withJSONObject: raw.object) }

private func spooledLines(_ home: ActivityHome, run: String) throws -> [Data] {
    let file = HookSpool.fileURL(directory: home.spoolDirectory, runID: run)
    guard FileManager.default.fileExists(atPath: file.path) else { return [] }
    return try HookSpool.readLines(file)
}

@Suite(.tags(.integration)) struct HookCLITests {
    @Test func appClosedEventGoesToTheSpoolAndTheAgentSeesEmptyJSONAndExitZero() async throws {
        let home = try ActivityHome(); defer { home.remove() }
        let stop = try #require(try RealHooks.events(RealHooks.claudeBasic).first { $0.name == "Stop" })
        let run = UUID().uuidString, pane = UUID().uuidString
        let result = try await runHook(stdin: try rawPayload(stop), home: home, runID: run, paneID: pane)
        #expect(result.status == 0)
        #expect(result.stdout == "{}\n")
        let lines = try spooledLines(home, run: run)
        #expect(lines.count == 1)
        guard case .event(let e) = HookSpoolLine.parse(try #require(lines.first)) else { Issue.record("spool line is not an envelope"); return }
        #expect(e.event == "Stop" && e.provider == .claude && e.runID == run && e.paneID == pane)
        #expect(e.payload.lastAssistantMessage == "DONE")
        #expect(e.payload.sessionID == stop.object["session_id"] as? String)
        #expect(abs(Double(e.atNs) - Double(HookTransport.realtimeNs())) < 30e9)
    }

    @Test func spoolDoesNotLeakThePromptOrToolOutput() async throws {
        let home = try ActivityHome(); defer { home.remove() }
        let run = UUID().uuidString
        let payload: [String: Any] = [
            "session_id": "s1", "hook_event_name": "PostToolUse", "tool_name": "Bash",
            "tool_input": ["command": "echo super-secret-token"], "tool_response": ["stdout": "TOOL-OUTPUT-SECRET"],
            "prompt": "PRIVATE-PROMPT-TEXT",
        ]
        let result = try await runHook(
            arguments: ["hook", "--provider", "claude"], stdin: try JSONSerialization.data(withJSONObject: payload), home: home, runID: run)
        #expect(result.status == 0)
        let text = String(decoding: try Data(contentsOf: HookSpool.fileURL(directory: home.spoolDirectory, runID: run)), as: UTF8.self)
        #expect(text.contains("\"event\":\"PostToolUse\""), "evento tomado de hook_event_name quando --event falta")
        #expect(text.contains("echo super-secret-token"), "o alvo curto do comando é um campo da §3.3")
        #expect(!text.contains("TOOL-OUTPUT-SECRET") && !text.contains("PRIVATE-PROMPT-TEXT"))
    }

    @Test func hugeToolResponseIsReducedBeforeSpooling() async throws {
        let home = try ActivityHome(); defer { home.remove() }
        let run = UUID().uuidString
        let blob = String(repeating: "A", count: 3 * 1024 * 1024)
        let payload: [String: Any] = ["session_id": "s1", "tool_name": "Read", "tool_response": ["content": blob]]
        let result = try await runHook(
            arguments: ["hook", "--event", "PostToolUse"], stdin: try JSONSerialization.data(withJSONObject: payload), home: home, runID: run)
        #expect(result.status == 0 && result.stdout == "{}\n")
        let data = try Data(contentsOf: HookSpool.fileURL(directory: home.spoolDirectory, runID: run))
        #expect(data.count < 2048)
    }

    @Test func withoutRunIDTheHelperIsInertAndSilent() async throws {
        let home = try ActivityHome(); defer { home.remove() }
        let result = try await runHook(stdin: Data("{\"session_id\":\"x\"}".utf8), home: home, runID: nil, paneID: nil)
        #expect(result.status == 0 && result.stdout == "{}\n" && result.stderr.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: home.spoolDirectory.path))
        let empty = try await runHook(stdin: Data(), home: home, runID: "")
        #expect(empty.status == 0 && !FileManager.default.fileExists(atPath: home.spoolDirectory.path))
    }

    @Test func garbageOrEmptyStdinStillExitsZeroAndRecordsTheEvent() async throws {
        let home = try ActivityHome(); defer { home.remove() }
        let run = UUID().uuidString
        let result = try await runHook(stdin: Data("this is not json {{{".utf8), home: home, runID: run)
        #expect(result.status == 0 && result.stdout == "{}\n")
        #expect(try spooledLines(home, run: run).count == 1)
        let run2 = UUID().uuidString
        #expect(try await runHook(stdin: Data(), home: home, runID: run2).status == 0)
        #expect(try spooledLines(home, run: run2).count == 1)
    }

    @Test func unwritableSpoolStillExitsZero() async throws {
        let home = try ActivityHome(); defer { home.remove() }
        try Data().write(to: home.root.appendingPathComponent("run"))  // `run` é um arquivo: não há como criar o spool
        let result = try await runHook(stdin: Data("{}".utf8), home: home)
        #expect(result.status == 0 && result.stdout == "{}\n")
    }

    @Test func liveAppReceivesTheEventAndNothingIsSpooled() async throws {
        let home = try ActivityHome(); defer { home.remove() }
        let store = try await home.openStore()
        let activity = ActivityService(store: store, spoolDirectory: home.spoolDirectory)
        let hub = AppSockHub(socketPath: home.socketPath, providers: [HookServiceProvider(activity: activity)])
        try await hub.start()
        let run = UUID(), pane = UUID()
        let terminal = try await home.seedTerminal(store)
        _ = pane
        let raws = try RealHooks.events(RealHooks.claudeBasic)
        for raw in raws.prefix(5) {
            let r = try await runHook(
                arguments: ["hook", "--provider", "claude", "--event", raw.name], stdin: try rawPayload(raw), home: home,
                runID: run.uuidString, paneID: terminal.id.uuidString, generousTimeout: true)
            #expect(r.status == 0 && r.stdout == "{}\n")
        }
        #expect(try spooledLines(home, run: run.uuidString).isEmpty)
        let row = try #require(try await store.agentRun(id: run))
        #expect(row.activity == .done && row.terminalID == terminal.id)
        #expect(try await store.terminal(id: terminal.id)?.lastMessage == "DONE")
        await hub.stop()
        try await store.close()
    }

    @Test func hungAppDoesNotBlockTheHelperBeyondItsDeadline() async throws {
        struct Hung: AppSockServiceProvider {
            let service = AppSockService.hook
            func admit() -> CtlError? { nil }
            func makeHandler() -> AppSockServer.Handler { { _ in try? await Task.sleep(for: .seconds(10)); return AppSockReply() } }
        }
        let home = try ActivityHome(); defer { home.remove() }
        let hub = AppSockHub(socketPath: home.socketPath, providers: [Hung()])
        try await hub.start()
        let run = UUID().uuidString
        let result = try await runHook(stdin: Data("{\"session_id\":\"s\"}".utf8), home: home, runID: run)
        #expect(result.status == 0 && result.stdout == "{}\n")
        #expect(result.duration < .seconds(1), "200 ms de prazo mais a partida do processo: \(result.duration)")
        #expect(try spooledLines(home, run: run).count == 1, "sem resposta no prazo, o evento vai para o spool")
        await hub.stop()
    }

    @Test func noPythonNodeOrJQIsNeededOrTouched() async throws {
        // AR-540 / AC-T24: PATH reduzido e um python3 falso que registra qualquer chamada.
        let home = try ActivityHome(); defer { home.remove() }
        let fakeBin = home.root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        let marker = home.root.appendingPathComponent("python-was-called")
        for name in ["python3", "python", "node", "jq"] {
            let script = fakeBin.appendingPathComponent(name)
            try "#!/bin/sh\ntouch '\(marker.path)'\nexit 1\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }
        let store = try await home.openStore()
        let activity = ActivityService(store: store, spoolDirectory: home.spoolDirectory)
        let hub = AppSockHub(socketPath: home.socketPath, providers: [HookServiceProvider(activity: activity)])
        try await hub.start()
        let run = UUID()
        let stop = try #require(try RealHooks.events(RealHooks.claudeBasic).first { $0.name == "Stop" })
        let result = try await runHook(
            stdin: try rawPayload(stop), home: home, runID: run.uuidString, path: "\(fakeBin.path):/usr/bin:/bin", generousTimeout: true)
        #expect(result.status == 0)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(try await store.agentRun(id: run)?.activity == .done, "os eventos chegam sem nenhum interpretador do host")
        // E sem app, o spool também funciona sem eles.
        let run2 = UUID().uuidString
        await hub.stop()
        _ = try await runHook(stdin: try rawPayload(stop), home: home, runID: run2, path: "\(fakeBin.path):/usr/bin:/bin")
        #expect(try spooledLines(home, run: run2).count == 1)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        try await store.close()
    }

    @Test func helperLatencyStaysWellUnderTheDeadlineWithTheAppLiveAndClosed() async throws {
        let payload = Data("{\"session_id\":\"s\",\"tool_name\":\"Bash\"}".utf8)
        func percentiles(_ samples: [Double]) -> (p50: Double, p95: Double) {
            let sorted = samples.sorted()
            return (sorted[sorted.count / 2], sorted[Int(Double(sorted.count) * 0.95) - 1])
        }
        func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }

        // App fechado: connect falha na hora e o evento vai para o spool.
        let closed = try ActivityHome(); defer { closed.remove() }
        var closedSamples: [Double] = []
        for _ in 0..<60 {
            let r = try await runHook(arguments: ["hook", "--event", "PreToolUse"], stdin: payload, home: closed, runID: UUID().uuidString)
            #expect(r.status == 0)
            closedSamples.append(ms(r.duration))
        }
        // App aberto: entrega por app.sock com ack.
        let home = try ActivityHome(); defer { home.remove() }
        let store = try await home.openStore()
        let activity = ActivityService(store: store, spoolDirectory: home.spoolDirectory)
        let hub = AppSockHub(socketPath: home.socketPath, providers: [HookServiceProvider(activity: activity)])
        try await hub.start()
        let run = UUID().uuidString
        var liveSamples: [Double] = []
        for _ in 0..<60 {
            let r = try await runHook(arguments: ["hook", "--event", "PreToolUse"], stdin: payload, home: home, runID: run)
            #expect(r.status == 0)
            liveSamples.append(ms(r.duration))
        }
        await hub.stop()
        try await store.close()
        let c = percentiles(closedSamples), l = percentiles(liveSamples)
        print("racky hook latency, binary=\(rackyBinary().path)")
        print("racky hook latency (60 runs, app closed/spool): p50=\(c.p50) ms p95=\(c.p95) ms")
        print("racky hook latency (60 runs, app live/socket): p50=\(l.p50) ms p95=\(l.p95) ms")
        // Build Debug com `Process` do Foundation e a máquina carregada: só um teto grosso. O p95 de AR-707 (30 ms, Release
        // assinado) é medido à parte.
        #expect(c.p95 < 400 && l.p95 < 400, "p95 do helper incluindo a partida do processo")
    }
}
