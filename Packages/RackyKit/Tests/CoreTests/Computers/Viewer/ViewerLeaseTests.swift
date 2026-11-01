import RackyDocker
import Foundation
import Testing

@testable import RackyCore

/// T3-05: Take Over / Hand Back com o lease no runtime (07 §5.2) e o modelo do viewer (CS-404). Sem Docker: o backend é falso.
func ctl(_ computer: ManagedComputer) async -> (Lease, ControlPhase) { (await computer.lease, await computer.controlPhase) }

@Suite("T3-05 - lease e controle humano")
struct ViewerLeaseTests {
    @Test func takeOverAsksTheRuntimeAndPausesTheAgent() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        await rig.claim()
        await rig.backend.setRuntime("lease", ["lease": "human", "ack": true])
        let acked = try await rig.computer.requestTakeOver()
        #expect(acked)
        #expect(await ctl(rig.computer) == (.human, .human))
        let calls = await rig.backend.runtimeCalls.filter { $0.op == "lease" }
        #expect(calls.count == 1 && calls[0].args["action"] == "take" && calls[0].args["wait_s"]?.double == 10)
        #expect(errorCode(await rig.call("browser_click", ["x": 1, "y": 2])) == "human_in_control")
        #expect(await rig.call("box_status").json["lease"] == "human")
    }

    @Test func withoutAckTheComputerStaysRevokingAndForceCancelsTheWrite() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        await rig.claim()
        await rig.backend.setRuntime("lease", ["lease": "revoking", "ack": false])
        #expect(try await rig.computer.requestTakeOver() == false)
        #expect(await ctl(rig.computer) == (.agent, .revoking))
        await rig.backend.setRuntime("lease", ["lease": "human", "ack": true])
        #expect(try await rig.computer.requestTakeOver(force: true))
        let actions = await rig.backend.runtimeCalls.filter { $0.op == "lease" }.compactMap { $0.args["action"]?.string }
        #expect(actions == ["take", "force_take"])
        #expect(await ctl(rig.computer).1 == .human)
    }

    @Test func runtimeFailureOnTakeOverLeavesTheAgentInControl() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        await rig.backend.setRuntimeError("lease", ToolError(.boxRestarted, "gone"))
        await #expect(throws: ToolError.self) { _ = try await rig.computer.requestTakeOver() }
        #expect(await ctl(rig.computer) == (.agent, .agent))
    }

    @Test func takingOverWithoutARequestWorksAndHandBackDeliversTheNoteOnTheNextCall() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        await rig.claim()
        await rig.backend.setRuntime("lease", ["lease": "human", "ack": true])
        _ = try await rig.computer.requestTakeOver()  // CS-414: sem pedido do agente
        await rig.backend.setRuntime("status", ["ready": true, "url": "http://x/page3", "title": "Page 3"])
        try await rig.computer.handBack(note: "  Signed in, continue from page 3  ")
        #expect(await ctl(rig.computer) == (.agent, .agent))
        let give = await rig.backend.runtimeCalls.last { $0.op == "lease" }
        #expect(give?.args["action"] == "give" && give?.args["note"] == "Signed in, continue from page 3")
        let next = await rig.call("box_status")
        #expect(next.json["human_handback"]?["note"] == "Signed in, continue from page 3")
        #expect(next.json["human_handback"]?["state"]?["url"] == "http://x/page3")
        #expect(await rig.call("box_status").json["human_handback"] == nil)  // entregue uma vez
    }

    @Test func handBackResolvesTheOpenHelpRequestAndHelpWaitReturns() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        await rig.claim()
        let id = try #require(await rig.call("help_request", ["kind": "captcha", "reason": "hCaptcha", "url": "http://aca.example/search"]).json["request_id"]?.string)
        await rig.backend.setRuntime("lease", ["lease": "human", "ack": true])
        _ = try await rig.computer.requestTakeOver()
        #expect(await rig.computer.help(id)?.status == .takenOver)
        let waiter = Task { await rig.call("help_wait", ["request_id": .string(id), "wait_s": 5]) }
        try await Task.sleep(for: .milliseconds(250))
        await rig.backend.setRuntime("status", ["ready": true, "url": "http://aca.example/results", "title": "Results"])
        try await rig.computer.handBack(note: "solved")
        let done = await waiter.value
        #expect(done.json["status"] == "resolved" && done.json["human_note"] == "solved")
        #expect(done.json["state"]?["url"] == "http://aca.example/results")
        #expect(await ctl(rig.computer).0 == .agent)
        #expect(await rig.call("box_status").json["human_handback"] == nil)  // o pedido já carregou a nota
    }

    @Test @MainActor func closingTheViewerNeverChangesLeaseOrRequest() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        await rig.claim()
        let id = try #require(await rig.call("help_request", ["kind": "login", "reason": "sign in"]).json["request_id"]?.string)
        let model = ComputerViewerModel(computer: rig.computer)
        await model.refresh()
        model.streamState("live")
        model.streamState("disconnected")  // viewer fechado ou stream caído
        #expect(await ctl(rig.computer).0 == .agent)
        #expect(await rig.computer.help(id)?.status == .open)
        #expect(model.help?.id == id)
    }

    @Test func humanInControlErrorKeepsRetryAfterFromTheRuntime() {
        let error = RuntimeErrorMapper.map(status: 409, body: ["error": "human_in_control", "message": "x", "details": ["retry_after_s": 5, "completed": true]])
        #expect(error.code == .humanInControl && error.retryAfterS == 5 && error.details?["completed"] == true)
    }

    @Test func thumbnailDecodesTheRuntimeJPEGAndRemembersTheURL() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
        await rig.backend.setRuntime("frame", ["jpeg_b64": .string(bytes.base64EncodedString()), "url": "http://x/y"])
        #expect(await rig.computer.thumbnail() == bytes)
        #expect(await rig.computer.pageURL == "http://x/y")
        let http = try await Rig.make(display: .http)
        defer { http.cleanup() }
        #expect(await http.computer.thumbnail() == nil)  // HTTP não tem tela
    }

    @Test func takeOverOnAnHTTPComputerNeedsNoRuntime() async throws {
        let rig = try await Rig.make(display: .http)
        defer { rig.cleanup() }
        #expect(try await rig.computer.requestTakeOver())
        try await rig.computer.handBack(note: nil)
        #expect(await rig.backend.runtimeCalls.isEmpty)
    }
}

/// Computador falso para o modelo do viewer: grava o que foi pedido e deixa o teste decidir quando o ACK chega.
actor FakeViewerComputer: ViewerComputer {
    nonisolated let computerName = "phoenix-az"
    var takeOverResults: [Result<Bool, ToolError>] = [.success(true)]
    var calls: [String] = []
    var handBackNotes: [String?] = []
    var snap = ViewerSnapshot(name: "phoenix-az", state: .inUse, display: "headless", control: .agent, proxy: "direct")
    var gate: CheckedContinuation<Void, Never>?
    var holdTakeOver = false

    func setHold(_ value: Bool) { holdTakeOver = value }
    func setResults(_ values: [Result<Bool, ToolError>]) { takeOverResults = values }
    func setSnapshot(_ value: ViewerSnapshot) { snap = value }
    func open() { gate?.resume(); gate = nil }

    func requestTakeOver(force: Bool, wait: TimeInterval) async throws -> Bool {
        calls.append(force ? "force" : "take")
        if holdTakeOver { await withCheckedContinuation { gate = $0 } }
        let result = takeOverResults.count > 1 ? takeOverResults.removeFirst() : takeOverResults[0]
        let acked = try result.get()
        if acked { snap.control = .human }
        return acked
    }

    func handBack(note: String?) async throws {
        calls.append("handBack")
        handBackNotes.append(note)
        snap.control = .agent
    }

    func vncEndpoint() async throws -> URL { URL(string: "ws://127.0.0.1:1/vnc?ticket=t")! }
    func declineHelp(_ id: String, reason: String?) async { calls.append("decline:\(id):\(reason ?? "")"); snap.help = nil }
    func viewerSnapshot() async -> ViewerSnapshot { snap }
}

@Suite("T3-05 - modelo do viewer")
@MainActor
struct ViewerModelTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func startsConnectingGoesLiveAndInputNeedsHumanPlusLiveStream() async {
        let model = ComputerViewerModel(computer: FakeViewerComputer())
        #expect(model.connection == .connecting && !model.inputEnabled)
        model.streamState("live", now: t0)
        #expect(model.connection == .live && !model.inputEnabled)  // agente no controle: view-only (CS-402)
        #expect(await model.takeOver(now: t0))
        #expect(model.control == .human && model.inputEnabled && model.canHandBack && !model.canTakeOver)
        model.streamState("disconnected")
        #expect(!model.inputEnabled, "stream down suspends human input (CS-404)")
        #expect(model.control == .human, "a dropped stream never hands control back")
        model.streamState("live")
        #expect(model.inputEnabled)
    }

    @Test func beforeTheFirstFrameFailuresStayConnectingNeverReconnecting() {
        let model = ComputerViewerModel(computer: FakeViewerComputer())
        for _ in 0..<(ComputerViewerModel.maxFirstConnectAttempts / 2) {
            model.ticketFailed("the computer has no containers yet")
            #expect(model.connection == .connecting, "não houve conexão: a tela diz Starting/Connecting, nunca Reconnecting")
            model.streamState("disconnected")
            #expect(model.connection == .connecting)
        }
        model.ticketFailed("still nothing")
        #expect(model.connection == .error("still nothing"))
        model.reconnectRequested()
        #expect(model.connection == .connecting)
    }

    @Test func ticketFailuresReconnectWithBackoffThenShowTheErrorAndALiveStreamResetsTheCount() {
        let model = ComputerViewerModel(computer: FakeViewerComputer())
        model.streamState("live", now: t0)
        for attempt in 1 ... ComputerViewerModel.maxReconnects {
            model.ticketFailed("runtime down")
            #expect(model.connection == .reconnecting(attempt: attempt), "o ticket que falhou vira tentativa de reconexão, não 'Disconnected'")
        }
        model.ticketFailed("runtime down")
        #expect(model.connection == .error("runtime down"))
        model.reconnectRequested()
        model.streamState("live", now: t0)
        model.ticketFailed("blip")
        #expect(model.connection == .reconnecting(attempt: 1))
    }

    @Test func takeOverIsImmediateAlwaysForcing() async {
        let fake = FakeViewerComputer()
        let model = ComputerViewerModel(computer: fake)
        model.streamState("live", now: t0)
        #expect(await model.takeOver(now: t0))
        #expect(model.control == .human && model.inputEnabled && !model.forceAvailable)
        #expect(await fake.calls == ["force"], "Take Over não pede: assume na hora (cancela a ação em curso do agente)")
    }

    @Test func revokingIsVisibleWhileWaitingForTheAck() async throws {
        let fake = FakeViewerComputer()
        await fake.setHold(true)
        let model = ComputerViewerModel(computer: fake)
        model.streamState("live", now: t0)
        let task = Task { @MainActor in await model.takeOver(now: t0) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.control == .revoking && model.revokingSince == t0 && !model.inputEnabled)
        await model.refresh()  // um snapshot do runtime ainda em `agent` não desfaz o `revoking`
        #expect(model.control == .revoking)
        model.tick(now: t0.addingTimeInterval(9))
        #expect(!model.forceAvailable)
        model.tick(now: t0.addingTimeInterval(10))
        #expect(model.forceAvailable)
        await fake.open()
        #expect(await task.value)
        #expect(model.control == .human)
    }

    @Test func failedTakeOverGoesBackToAgentWithTheError() async {
        let fake = FakeViewerComputer()
        await fake.setResults([.failure(ToolError(.boxRestarted, "gone"))])
        let model = ComputerViewerModel(computer: fake)
        model.streamState("live")
        #expect(await model.takeOver() == false)
        #expect(model.control == .agent && model.lastError != nil)
    }

    @Test func handBackWithNoteReleasesKeyboardAndClearsTheField() async {
        let fake = FakeViewerComputer()
        let model = ComputerViewerModel(computer: fake)
        model.streamState("live")
        _ = await model.takeOver()
        model.keyboard(captured: true)
        #expect(model.keyboardCaptured)
        model.showHandBackNote()
        model.handBackNote = "Signed in, continue from page 3"
        await model.handBack()
        #expect(model.control == .agent && !model.keyboardCaptured && !model.handBackNoteVisible && model.handBackNote.isEmpty)
        #expect(await fake.handBackNotes == ["Signed in, continue from page 3"])
        model.showHandBackNote()
        #expect(!model.handBackNoteVisible, "the note field only opens while the human controls")
    }

    @Test func keyboardIsOnlyCapturedWithHumanControl() async {
        let model = ComputerViewerModel(computer: FakeViewerComputer())
        model.streamState("live")
        model.keyboard(captured: true)
        #expect(!model.keyboardCaptured)  // agente no controle: nada de captura
        _ = await model.takeOver()
        model.keyboard(captured: true)
        #expect(model.keyboardCaptured)
        model.releaseKeyboard()
        #expect(!model.keyboardCaptured)
    }

    @Test func silenceOverTwoSecondsIsSlowConnectionAndRecovers() {
        let model = ComputerViewerModel(computer: FakeViewerComputer())
        model.streamState("live", now: t0)
        model.streamStats(fps: 24, frames: 100, silentMs: 300, now: t0)
        #expect(model.connection == .live)
        model.streamStats(fps: 0, frames: 100, silentMs: 2500, now: t0.addingTimeInterval(2.5))
        #expect(model.connection == .delayed(since: t0))
        model.streamStats(fps: 20, frames: 120, silentMs: 100, now: t0.addingTimeInterval(4))
        #expect(model.connection == .live && model.stats.fps == 20)
    }

    @Test func reconnectingEscalatesToDisconnectedAndNeverTouchesControlOrHelp() async {
        let fake = FakeViewerComputer()
        await fake.setSnapshot(ViewerSnapshot(
            name: "phoenix-az", state: .inUse, display: "headless", control: .agent, proxy: "direct",
            help: HelpSummary(id: "h1", kind: .captcha, reason: "x", host: "aca.example")))
        let model = ComputerViewerModel(computer: fake)
        await model.refresh()
        model.streamState("live")
        for attempt in 1...ComputerViewerModel.maxReconnects {
            model.streamState("disconnected")
            #expect(model.connection == .reconnecting(attempt: attempt))
        }
        model.streamState("disconnected")
        #expect(model.connection == .disconnected && model.needsReconnect)
        #expect(model.control == .agent && model.help?.id == "h1" && model.help?.headline == "CAPTCHA on aca.example")
        model.reconnectRequested()
        #expect(model.connection == .connecting)
        model.streamState("live")
        #expect(model.connection == .live)
        #expect(await fake.calls.isEmpty, "reconnecting never resolves the request or hands control back")
    }

    @Test func stoppedComputerShowsStoppedAndCannotBeTakenOver() async {
        let fake = FakeViewerComputer()
        await fake.setSnapshot(ViewerSnapshot(name: "phoenix-az", state: .stopped, display: "headless", control: .agent, proxy: "direct"))
        let model = ComputerViewerModel(computer: fake)
        await model.refresh()
        #expect(model.connection == .stopped && !model.canTakeOver)
        #expect(await model.takeOver() == false)
        #expect(await fake.calls.isEmpty)
    }

    @Test func clickWhileTheAgentControlsIsReported() {
        let model = ComputerViewerModel(computer: FakeViewerComputer())
        model.blockedClick(now: t0)
        #expect(model.blockedClickAt == t0)
    }

    @Test func toggleControlTakesOverThenOpensTheNoteField() async {
        let model = ComputerViewerModel(computer: FakeViewerComputer())
        model.streamState("live")
        await model.toggleControl()
        #expect(model.control == .human)
        await model.toggleControl()
        #expect(model.handBackNoteVisible && model.control == .human)  // ⇧⌘R de novo abre o Hand Back; a confirmação devolve
    }

    @Test func declineGoesToTheComputerAndClearsTheBanner() async {
        let fake = FakeViewerComputer()
        await fake.setSnapshot(ViewerSnapshot(
            name: "phoenix-az", state: .inUse, display: "headless", control: .agent, proxy: "direct",
            help: HelpSummary(id: "h9", kind: .login, reason: "x", host: nil)))
        let model = ComputerViewerModel(computer: fake)
        await model.refresh()
        await model.decline(reason: "skip this city")
        #expect(await fake.calls == ["decline:h9:skip this city"] && model.help == nil)
    }

    @Test func helpHeadlinesFollowTheNotificationFormat() {
        #expect(HelpSummary(id: "1", kind: .captcha, reason: "", host: "aca-prod.accela.com").headline == "CAPTCHA on aca-prod.accela.com")
        #expect(HelpSummary(id: "2", kind: .mfa, reason: "", host: nil).headline == "Verification code")
        #expect(HelpSummary(id: "3", kind: .login, reason: "page text must never appear", host: "x.test").headline == "Sign-in on x.test")
    }

    // MARK: F28 - lease humano esquecido

    @Test func idleHumanLeaseReturnsToTheAgentAfterThreeMinutesWithTheNote() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        await rig.claim()
        await rig.backend.setRuntime("lease", ["lease": "human", "ack": true])
        _ = try await rig.computer.requestTakeOver()
        let start = Date()
        await rig.computer.noteHumanActivity(at: start)
        #expect(await rig.computer.returnIdleControl(now: start.addingTimeInterval(179)) == false)
        #expect(await ctl(rig.computer).0 == .human)
        // input recomeça o prazo
        await rig.computer.noteHumanActivity(at: start.addingTimeInterval(170))
        #expect(await rig.computer.returnIdleControl(now: start.addingTimeInterval(300)) == false)
        #expect(await rig.computer.returnIdleControl(now: start.addingTimeInterval(170 + 180)) == true)
        #expect(await ctl(rig.computer) == (.agent, .agent))
        let give = await rig.backend.runtimeCalls.last { $0.op == "lease" }
        #expect(give?.args["action"] == "give")
        #expect(give?.args["note"]?.string?.contains("automatically") == true)
        // o agente volta a escrever e recebe a nota na próxima chamada
        #expect(await rig.call("box_status").json["human_handback"]?["note"]?.string?.contains("3 min") == true)
        // com o agente no controle nada acontece
        #expect(await rig.computer.returnIdleControl(now: start.addingTimeInterval(9999)) == false)
    }

    @Test func humanInControlErrorTellsTheAgentToWaitNotToAskForHelp() async throws {
        let rig = try await Rig.make()
        defer { rig.cleanup() }
        await rig.claim()
        await rig.backend.setRuntime("lease", ["lease": "human", "ack": true])
        _ = try await rig.computer.requestTakeOver()
        let result = await rig.call("browser_click", ["x": 1, "y": 2])
        #expect(errorCode(result) == "human_in_control")
        // F43: o usuário já está na tela; mandar pedir ajuda fazia todo Take Over virar um help_request.
        #expect(result.json["message"]?.string?.contains("do not open a help_request") == true)
        #expect(result.json["details"]?["hint"] == "wait; poll box_status")
        #expect(result.json["retry_after_s"]?.int == 20)
        // o erro que nasce no runtime (corrida) ganha a mesma dica
        let mapped = RuntimeErrorMapper.map(status: 409, body: ["error": "human_in_control", "message": "x", "details": ["retry_after_s": 5]])
        #expect(mapped.code == .humanInControl && mapped.message.contains("do not open a help_request"))
    }
}
