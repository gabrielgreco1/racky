import RackyCore
import RackyDocker
import RackyProtocol
import Foundation
import Testing

@testable import RackyUI

/// Backend mínimo (T3-05): lease por ACK programável, resto vazio.
actor LeaseBackend: ComputerBackend {
    var calls: [String] = []
    var ack = true

    func setAck(_ value: Bool) { ack = value }

    func runtime(_ operation: String, _ args: JSON, timeout: TimeInterval) async throws -> JSON {
        calls.append(operation + (args["action"]?.string.map { ":" + $0 } ?? ""))
        if operation == "lease" { return ["lease": .string(ack ? "human" : "revoking"), "ack": .bool(ack)] }
        if operation == "frame" { return ["jpeg_b64": .string(Data([0xFF, 0xD8, 9]).base64EncodedString()), "url": "http://aca.example.test/search"] }
        return ["ok": true, "url": "http://aca.example.test/search", "title": "t", "cookies": [], "tabs": []]
    }
    func execRun(_ request: BackendExec, timeout: Duration) async throws -> BackendExecOutcome { BackendExecOutcome() }
    func execStart(_ request: BackendExec) async throws -> String { "job" }
    func execPoll(jobID: String, wait: Duration) async throws -> BackendExecOutcome { BackendExecOutcome() }
    func execCancel(jobID: String) async throws -> BackendExecOutcome { BackendExecOutcome() }
    func ingest(_ payload: JSON) async throws -> String { "id" }
    func switchProxy(to proxy: String, country: String?) async throws -> Int { 0 }
    func proxyInfo() async throws -> JSON { [:] }
    func usage() async throws -> JSON { [:] }
    func render(_ payload: JSON) async throws -> JSON { [:] }
    func vncEndpoint() async throws -> URL { URL(string: "ws://127.0.0.1:1/vnc?ticket=t")! }
}

@MainActor
@Suite("T3-05 - controlador de computadores e ações", .serialized, .offscreenAppKit)
struct ComputersControllerTests {
    struct Fixture {
        let controller = ComputersController()
        let registry: ActionRegistry
        let backend: LeaseBackend
        let notifier = RecordingHelpNotifier()
        let computer: ManagedComputer
        let folder: URL
    }

    func make() async throws -> Fixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("abx-ctl-\(UUID().uuidString.lowercased())", isDirectory: true)
        let flags = SliceFlags(current: .slice3)
        let registry = ActionRegistry(flags: flags, surface: FakeSurface())
        let backend = LeaseBackend()
        let computer = try ManagedComputer(name: "phoenix-az", display: .headless, run: RunFolder(root: folder), backend: backend)
        let fixture = Fixture(registry: registry, backend: backend, computer: computer, folder: folder)
        try fixture.controller.register(in: registry)
        fixture.controller.notifier = fixture.notifier
        return fixture
    }

    @Test func actionsAreDisabledWithAReasonUntilThereIsAComputer() async throws {
        let f = try await make()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        if case .disabled(let reason) = f.registry.availability(of: .computerTakeOver) { #expect(reason == "No computers yet.") } else { Issue.record("takeOver should be disabled") }
        if case .disabled(let reason) = f.registry.availability(of: .computerHandBack) { #expect(reason == "Open a computer first.") } else { Issue.record("handBack should be disabled") }
        if case .disabled(let reason) = f.registry.availability(of: .computerPaste) { #expect(reason == "Take over first.") } else { Issue.record("paste should be disabled") }
        await f.controller.add(f.computer)
        #expect(f.registry.availability(of: .computerTakeOver).isEnabled)
        #expect(f.registry.availability(of: .computerOpenViewer).isEnabled)
    }

    @Test func openingTheViewerAndClosingItNeverTouchesLeaseOrComputer() async throws {
        let f = try await make()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        await f.controller.add(f.computer)
        _ = try await f.registry.perform(.computerOpenViewer, .select("phoenix-az"))
        #expect(f.controller.page == .viewer("phoenix-az") && f.controller.activeViewer?.name == "phoenix-az")
        _ = try await f.registry.perform(.pageClose, nil)
        #expect(f.controller.page == .workspace && f.controller.activeViewer == nil)
        #expect(await f.computer.lease == .agent)  // CS-405
        #expect(await f.computer.state == .ready)
        let calls = await f.backend.calls
        #expect(!calls.contains { $0.hasPrefix("lease") })
    }

    /// Bug real: o Take Over do "Needs You" (sidebar) num computador de sessão abria o pane, que só nasce no próximo layout, e a
    /// ação não achava viewer nenhum. Agora o viewer é criado na hora e o controle passa para você.
    @Test func takeOverFromTheSidebarWorksForASessionComputer() async throws {
        let f = try await make()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        await f.controller.add(f.computer)
        f.controller.model.sessionIDs["phoenix-az"] = UUID()
        var openedInSession: [String] = []
        f.controller.openInSession = { name, _ in openedInSession.append(name); return true }
        let taken = try await f.registry.perform(.computerTakeOver, .select("phoenix-az"))
        #expect(taken.message == "human" && openedInSession == ["phoenix-az"])
        #expect(f.controller.page == .workspace, "abre como tab da sessão, não na página Computers")
        #expect(await f.computer.lease == .human)
    }

    /// Bug real: com o computador como pane da sessão (a página continua o workspace), o Take Over não achava viewer "ativo" e
    /// falhava com "no viewer is open". O botão passa o nome, e o ⇧⌘R/Hand Back sem argumento usam o viewer desse pane.
    @Test func takeOverWorksFromAViewerPaneInsideTheSession() async throws {
        let f = try await make()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        await f.controller.add(f.computer)
        let pane = try #require(f.controller.ensureViewer("phoenix-az"))
        #expect(f.controller.page == .workspace)
        let taken = try await f.registry.perform(.computerTakeOver, .select("phoenix-az"))
        #expect(taken.message == "human" && f.controller.page == .workspace, "o pane continua na sessão, sem abrir a página")
        #expect(await f.computer.lease == .human)
        #expect(f.controller.activeViewer === pane)
        // ⇧⌘R de novo (sem argumento) devolve pelo mesmo viewer.
        _ = try await f.registry.perform(.computerHandBack, nil)
        #expect(pane.model.handBackNoteVisible)
    }

    @Test func takeOverFromOutsideOpensTheViewerThenTakesControlAndHandBackReturnsIt() async throws {
        let f = try await make()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        await f.controller.add(f.computer)
        let result = try await f.registry.perform(.computerTakeOver, .select("phoenix-az"))
        #expect(result.message == "human")
        #expect(f.controller.page == .viewer("phoenix-az"))
        #expect(await f.computer.lease == .human)
        // Hand Back abre o campo de nota; a confirmação devolve com a nota
        _ = try await f.registry.perform(.computerHandBack, nil)
        #expect(f.controller.activeViewer?.model.handBackNoteVisible == true)
        f.controller.activeViewer?.model.handBackNote = "continue from page 3"
        let back = try await f.registry.perform(.computerHandBack, .select("confirm"))
        #expect(back.message == "agent")
        #expect(await f.computer.lease == .agent)
        let calls = await f.backend.calls
        #expect(calls.filter { $0.hasPrefix("lease") } == ["lease:force_take", "lease:give"])
    }

    @Test func helpRequestReachesInboxBadgeAndNotificationOnceAndOpeningMarksItRead() async throws {
        let f = try await make()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        await f.controller.add(f.computer)
        await f.controller.hub.registerChild(id: "c1", capability: "cap")
        let service = ComputerToolService(hub: f.controller.hub)
        _ = await service.call("box_claim", arguments: ["name": "phoenix-az", "wait_s": 0], child: "c1")
        func ask(_ reason: String) async -> String {
            let out = await service.call("help_request", arguments: ["kind": "captcha", "reason": .string(reason), "url": "http://aca-prod.accela.com/search"], child: "c1")
            return (try? JSON.parse(out.content.first?["text"]?.string ?? ""))?["request_id"]?.string ?? ""
        }
        let requestID = await ask("hCaptcha")
        for _ in 0..<100 where f.controller.model.inbox.isEmpty { try await Task.sleep(for: .milliseconds(30)) }
        #expect(f.controller.model.inbox.count == 1 && f.notifier.delivered.count == 1)
        #expect(f.notifier.delivered[0].content.body == "CAPTCHA on aca-prod.accela.com")
        #expect(await ask("again") == requestID)
        try await Task.sleep(for: .milliseconds(150))
        #expect(f.notifier.delivered.count == 1)
        // clique na notificação: abre o viewer e marca lido; o Inbox lista o pedido
        #expect(f.controller.model.unreadCount == 1)
        f.controller.openViewer("phoenix-az")
        #expect(f.controller.model.unreadCount == 0 && f.controller.page == .viewer("phoenix-az"))
        await f.controller.activeViewer?.model.refresh()
        #expect(f.controller.activeViewer?.model.help?.id == requestID)
        // resolver: o help_wait do filho retorna
        try await f.computer.resolveHelp(requestID, note: "done")
        for _ in 0..<100 where f.controller.model.attentionCount != 0 { try await Task.sleep(for: .milliseconds(30)) }
        #expect(f.controller.model.attentionCount == 0)
        #expect(await f.computer.help(requestID)?.status == .resolved)
    }

    @Test func pagesTogglePanelOpensAndTheCloseHookWorks() async throws {
        let f = try await make()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        _ = try await f.registry.perform(.pageComputers, nil)
        #expect(f.controller.page == .computers)
        // Clicar de novo no item não volta para a sessão: a página continua aberta (page.close fecha).
        _ = try await f.registry.perform(.pageComputers, nil)
        #expect(f.controller.page == .computers)
        _ = try await f.registry.perform(.pageClose, nil)
        #expect(f.controller.page == .workspace)
        var opened: [Bool] = []
        f.controller.onPanelChange = { opened.append($0) }
        _ = try await f.registry.perform(.panelComputers, nil)
        _ = try await f.registry.perform(.panelComputers, nil)
        #expect(opened == [true, false])
    }

    // MARK: F28 - sair do viewer com o controle na mão

    @Test func leavingTheViewerWhileHoldingControlAsksBeforeClosingOnEveryPath() async throws {
        let f = try await make()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        await f.controller.add(f.computer)
        _ = try await f.registry.perform(.computerTakeOver, .select("phoenix-az"))
        #expect(await f.computer.lease == .human)
        // tab, sidebar, Esc, ⌘W e ← chegam todos por show/closePage
        for leave in [{ f.controller.closePage() }, { f.controller.show(.workspace) }, { f.controller.show(.computers) }] {
            leave()
            #expect(f.controller.page == .viewer("phoenix-az"))
            #expect(f.controller.pendingExit?.computer == "phoenix-az")
            _ = try await f.registry.perform(.computerHandBack, .select("exit-stay"))  // Esc no overlay
            #expect(f.controller.pendingExit == nil && f.controller.page == .viewer("phoenix-az") && f.controller.activeViewer?.model.control == .human)
        }
        // Keep control: sai, o lease continua com o humano
        f.controller.closePage()
        let kept = try await f.registry.perform(.computerHandBack, .select("exit-keep"))
        #expect(kept.message == "left" && f.controller.page == .workspace && f.controller.pendingExit == nil)
        #expect(await f.computer.lease == .human)
    }

    @Test func handBackOnExitReturnsControlThenLeaves() async throws {
        let f = try await make()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        await f.controller.add(f.computer)
        _ = try await f.registry.perform(.computerTakeOver, .select("phoenix-az"))
        f.controller.show(.computers)
        #expect(f.controller.pendingExit?.target == .computers)
        let done = try await f.registry.perform(.computerHandBack, .select("exit-handback"))
        #expect(done.message == "left" && f.controller.page == .computers)
        #expect(await f.computer.lease == .agent)
        let calls = await f.backend.calls
        #expect(calls.filter { $0.hasPrefix("lease") } == ["lease:force_take", "lease:give"])
    }

    @Test func removingTheComputerDismissesTheViewerChromeAndClosesThePage() async throws {
        let f = try await make()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        await f.controller.add(f.computer)
        _ = try await f.registry.perform(.computerTakeOver, .select("phoenix-az"))
        f.controller.show(.workspace)  // pergunta `Hand back to <Agent>?`
        #expect(f.controller.pendingExit?.computer == "phoenix-az")
        // O subagente liberou o computador com o humano no controle: nada de diálogo por cima de outra aba.
        f.controller.computerRemoved("phoenix-az")
        #expect(f.controller.pendingExit == nil && f.controller.page == .workspace && f.controller.viewers["phoenix-az"] == nil)
        // Saída pendente para outro destino, estando o viewer aberto: o pedido some e a página fecha.
        await f.controller.add(f.computer)
        _ = try await f.registry.perform(.computerTakeOver, .select("phoenix-az"))
        f.controller.show(.computers)
        #expect(f.controller.pendingExit?.target == .computers)
        f.controller.computerRemoved("phoenix-az")
        #expect(f.controller.pendingExit == nil && f.controller.page == .workspace)
        // Outro computador removido não mexe na página aberta.
        await f.controller.add(f.computer)
        f.controller.openViewer("phoenix-az")
        f.controller.computerRemoved("other")
        #expect(f.controller.page == .viewer("phoenix-az"))
    }

    @Test func theViewerNamesTheParentAgent() async throws {
        let f = try await make()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        await f.controller.add(f.computer)
        #expect(f.controller.agentName(forComputer: "phoenix-az") == "Claude")
        f.controller.model.agentNames["phoenix-az"] = "Codex"
        #expect(f.controller.agentName(forComputer: "phoenix-az") == "Codex")
        f.controller.openViewer("phoenix-az")
        #expect(f.controller.viewers["phoenix-az"]?.model.agentName == "Codex")
    }

    @Test func leavingWithTheAgentInControlNeverAsks() async throws {
        let f = try await make()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        await f.controller.add(f.computer)
        f.controller.openViewer("phoenix-az")
        f.controller.closePage()
        #expect(f.controller.pendingExit == nil && f.controller.page == .workspace)
    }

    @Test func handBackNowWorksWithoutOpeningTheViewerAndIdleControlReturnsWithAToast() async throws {
        let f = try await make()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        await f.controller.add(f.computer)
        _ = try await f.registry.perform(.computerTakeOver, .select("phoenix-az"))
        f.controller.show(.workspace)  // pergunta
        await f.controller.resolveExit(handBack: false)  // sai com o controle
        #expect(f.controller.page == .workspace && f.controller.viewers["phoenix-az"] == nil)
        await f.controller.model.refresh()
        #expect(f.controller.model.rows.first?.snapshot.control == .human)  // a linha do subagente mostra "You have control"
        // 3 min sem input: volta sozinho e avisa
        let returned = await f.controller.model.returnIdleControl(now: Date().addingTimeInterval(181))
        #expect(returned == ["phoenix-az"] && f.controller.agentName(forComputer: "phoenix-az") == "Claude")
        #expect(await f.computer.lease == .agent)
        // Hand Back direto (linha do subagente) quando o humano pegou de novo
        _ = try await f.registry.perform(.computerTakeOver, .select("phoenix-az"))
        f.controller.show(.workspace)
        await f.controller.resolveExit(handBack: false)
        await f.controller.model.refresh()
        let back = try await f.registry.perform(.computerHandBack, .select("now:phoenix-az"))
        #expect(back.message == "agent")
        #expect(await f.computer.lease == .agent)
    }
}
