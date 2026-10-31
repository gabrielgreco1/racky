import RackyPlatform
import RackyProtocol
import Darwin
import Foundation
import Testing

@testable import RackyCore

/// Despachante falso: modela o registro sem UI.
actor FakeDispatcher: ActionDispatching {
    private var tree: UITreeSnapshot
    private(set) var performed: [ActionID] = []
    private(set) var recording = false
    /// Quantas vezes a árvore foi consultada: marca que o `ui wait` já está em curso no servidor.
    private(set) var treeQueries = 0

    init(tree: UITreeSnapshot) { self.tree = tree }

    func setTree(_ t: UITreeSnapshot) { tree = t }

    func perform(_ id: ActionID, _ arg: ActionArgument?) async throws -> ActionResult {
        switch id {
        case .sessionNew:
            performed.append(id)
            return ActionResult(actionID: id, message: "arg=\(arg?.kind.rawValue ?? "nil")" + (arg?.value.map { ":\($0)" } ?? ""))
        case .tabClose: throw ActionError.disabled(id, reason: "Select a session first.")
        case .viewToggleRightPanel: throw ActionError.notAvailable(id, slice: .slice2)
        case .appQuit: throw ActionError.failed(id, message: "boom")
        default: throw ActionError.notRegistered(id)
        }
    }

    func actionID(forControl id: A11yID) async -> ActionID? { tree.find(id)?.action }

    func boundArgument(forControl id: A11yID) async -> ActionArgument? { tree.find(id)?.argument }

    func uiTree(root: A11yID?) async -> UITreeSnapshot {
        treeQueries += 1
        guard let root else { return tree }
        guard let node = tree.find(root) else { return UITreeSnapshot(window: tree.window, roots: []) }
        return UITreeSnapshot(window: tree.window, roots: [node])
    }

    func screenshot(_ target: ScreenshotTarget) async throws -> ScreenshotResult {
        if case .element(let id) = target, tree.find(id) == nil { throw CtlError(code: "unknown_target", message: "no \(id)") }
        var size = 0
        if case .window(let s?) = target { size = Int(s.width) }
        return ScreenshotResult(fidelity: "appkit", pixelWidth: size, pixelHeight: 2, scale: 2, note: "fake", png: Data([0x89, 0x50, 0x4E, 0x47]))
    }

    func record(_ command: RecordingCommand) async throws -> RecordingResult {
        switch command {
        case .start(let p):
            recording = true
            return RecordingResult(state: "recording", path: p)
        case .stop:
            recording = false
            return RecordingResult(state: "stopped", path: "/x.mov")
        }
    }

    func appState() async -> AppStateSnapshot {
        AppStateSnapshot(
            app: "Racky", version: "test", pid: 1, slice: .slice1, fixture: nil, automation: true, window: tree.window,
            registeredActions: [.sessionNew], visibleControls: tree.flattened().count)
    }
}

private let sampleTree = UITreeSnapshot(
    window: UIWindowInfo(title: "Racky", width: 1440, height: 900, scale: 2, isKey: true),
    roots: [
        UITreeNode(
            id: .windowMain, kind: "window", children: [
                UITreeNode(id: .windowTitlebar, kind: "container", children: [
                    UITreeNode(id: .windowAppName, kind: "text", label: "Racky"),
                    UITreeNode(id: .tabsNew, kind: "button", label: "New Tab", action: .sessionNew),
                    UITreeNode(id: .windowSidebarToggle, kind: "button", label: "Carries an argument", action: .sessionNew, argument: .select("supabase")),
                ])
            ])
    ])

private func tempSocketPath() -> String {
    // Caminho curto: sockaddr_un limita a 103 bytes.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("abx-\(UUID().uuidString.prefix(8))")
    return dir.appendingPathComponent("app.sock").path
}

/// Cliente de teste: handshake + uma requisição.
private func ctl(_ path: String, _ request: CtlRequest, service: AppSockService = .ctl) async throws -> (hello: AppSockHelloReply, response: CtlResponse?) {
    let conn = try AppSockClient.connect(path: path)
    defer { Task { await conn.close() } }
    try await conn.send(try CtlCodec.encoder().encode(AppSockHello(service: service)))
    let hello = try CtlCodec.decoder().decode(AppSockHelloReply.self, from: try await conn.receive())
    guard hello.ok else { return (hello, nil) }
    try await conn.send(try CtlCodec.encoder().encode(request))
    return (hello, try CtlCodec.decoder().decode(CtlResponse.self, from: try await conn.receive()))
}

@Suite struct CtlServerTests {
    private func withServer(
        dispatcher: FakeDispatcher? = nil, enabled: @escaping @Sendable () -> Bool = { true },
        _ body: (String, FakeDispatcher) async throws -> Void
    ) async throws {
        let path = tempSocketPath()
        let d = dispatcher ?? FakeDispatcher(tree: sampleTree)
        let server = CtlServer(socketPath: path, dispatcher: d, isEnabled: enabled)
        try await server.start()
        do { try await body(path, d) } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }

    @Test func handshakeThenState() async throws {
        try await withServer { path, _ in
            let (hello, res) = try await ctl(path, CtlRequest(command: .state))
            #expect(hello.ok)
            #expect(res?.state?.app == "Racky")
            #expect(res?.state?.registeredActions == [.sessionNew])
        }
    }

    @Test func socketIsOwnerOnlyAndRemovedOnStop() async throws {
        let path = tempSocketPath()
        let server = CtlServer(socketPath: path, dispatcher: FakeDispatcher(tree: sampleTree))
        try await server.start()
        var st = stat()
        #expect(stat(path, &st) == 0)
        #expect(st.st_mode & 0o777 == 0o600)
        await server.stop()
        #expect(stat(path, &st) != 0)
    }

    @Test func secondServerOnSamePathIsRefused() async throws {
        try await withServer { path, d in
            let other = CtlServer(socketPath: path, dispatcher: d)
            await #expect(throws: AppSockError.self) { try await other.start() }
        }
    }

    @Test func disabledChannelRefusesAtHandshake() async throws {
        try await withServer(enabled: { false }) { path, _ in
            let (hello, res) = try await ctl(path, CtlRequest(command: .state))
            #expect(!hello.ok)
            #expect(hello.error?.code == "ctl_disabled")
            #expect(res == nil)
        }
    }

    @Test func otherServicesAreNotAvailableYet() async throws {
        try await withServer { path, _ in
            let (hello, _) = try await ctl(path, CtlRequest(command: .state), service: .mcp)
            #expect(!hello.ok)
            #expect(hello.error?.code == "service_unavailable")
        }
    }

    @Test func uiTreeWholeAndSubtree() async throws {
        try await withServer { path, _ in
            let whole = try await ctl(path, CtlRequest(command: .uiTree)).response
            #expect(whole?.tree?.find(.windowAppName)?.label == "Racky")
            #expect(whole?.tree?.window?.width == 1440)
            let sub = try await ctl(path, CtlRequest(command: .uiTree, root: .windowTitlebar)).response
            #expect(sub?.tree?.roots.first?.id == .windowTitlebar)
            let missing = try await ctl(path, CtlRequest(command: .uiTree, root: .sidebar)).response
            #expect(missing?.ok == false)
            #expect(missing?.error?.code == "unknown_target")
        }
    }

    @Test func actionByActionIDAndByControl() async throws {
        try await withServer { path, d in
            let byAction = try await ctl(path, CtlRequest(command: .uiAction, target: "session.new", argument: .press)).response
            #expect(byAction?.ok == true)
            #expect(byAction?.action?.message == "arg=press")
            let byControl = try await ctl(path, CtlRequest(command: .uiAction, target: "tabs.new")).response
            #expect(byControl?.action?.actionID == .sessionNew)
            #expect(await d.performed == [.sessionNew, .sessionNew])
        }
    }

    /// Bug do teste completo: `ui action data.connect.kind.supabase` ia sem o "supabase" e o formulário não abria.
    @Test func actionByControlUsesTheArgumentTheControlCarries() async throws {
        try await withServer { path, _ in
            let carried = try await ctl(path, CtlRequest(command: .uiAction, target: "window.sidebarToggle")).response
            #expect(carried?.action?.message == "arg=select:supabase")
            let explicit = try await ctl(path, CtlRequest(command: .uiAction, target: "window.sidebarToggle", argument: .select("postgres"))).response
            #expect(explicit?.action?.message == "arg=select:postgres", "argumento explícito vence o do controle")
        }
    }

    @Test func actionFailuresMapToStableCodes() async throws {
        try await withServer { path, _ in
            func code(_ target: String) async throws -> CtlError? {
                try await ctl(path, CtlRequest(command: .uiAction, target: target)).response?.error
            }
            let disabled = try await code("tab.close")
            #expect(disabled?.code == "action_disabled")
            #expect(disabled?.reason == "Select a session first.")
            #expect(try await code("view.toggleRightPanel")?.code == "action_unavailable")
            #expect(try await code("page.library")?.code == "action_not_registered")
            #expect(try await code("app.quit")?.code == "action_failed")
            #expect(try await code("nope.nope")?.code == "unknown_target")
            #expect(try await code("window.titlebar")?.code == "unknown_target")  // controle sem ação
            #expect(try await ctl(path, CtlRequest(command: .uiAction)).response?.error?.code == "bad_request")
        }
    }

    @Test func waitAppearsWhenElementShowsUp() async throws {
        try await withServer(dispatcher: FakeDispatcher(tree: UITreeSnapshot(window: nil, roots: []))) { path, d in
            // Ordem, não tempo: o elemento só aparece depois que o servidor já consultou a árvore ao menos uma vez
            // (o wait está em curso e viu o elemento ausente). O prazo de 30 s só existe para não travar a suíte.
            let appearer = Task {
                let end = ContinuousClock.now + .seconds(30)
                while await d.treeQueries == 0, ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(5)) }
                await d.setTree(sampleTree)
            }
            let res = try await ctl(path, CtlRequest(command: .uiWait, element: .windowAppName, waitState: .appear, timeoutMs: 30_000)).response
            await appearer.value
            #expect(res?.ok == true)
            #expect(res?.waited?.id == .windowAppName)
            #expect(res?.waitedMs != nil)
        }
    }

    @Test func waitGoneAndTimeout() async throws {
        try await withServer { path, _ in
            let gone = try await ctl(path, CtlRequest(command: .uiWait, element: .sidebar, waitState: .gone, timeoutMs: 500)).response
            #expect(gone?.ok == true)
            let timeout = try await ctl(path, CtlRequest(command: .uiWait, element: .sidebar, timeoutMs: 200)).response
            #expect(timeout?.ok == false)
            #expect(timeout?.error?.code == "timeout")
        }
    }

    @Test func waitEnabledStates() async throws {
        try await withServer { path, _ in
            let enabled = try await ctl(path, CtlRequest(command: .uiWait, element: .tabsNew, waitState: .enabled, timeoutMs: 300)).response
            #expect(enabled?.ok == true)
            let disabled = try await ctl(path, CtlRequest(command: .uiWait, element: .tabsNew, waitState: .disabled, timeoutMs: 150)).response
            #expect(disabled?.error?.code == "timeout")
        }
    }

    @Test func screenshotAndRecord() async throws {
        try await withServer { path, d in
            let shot = try await ctl(path, CtlRequest(command: .screenshot, size: UISize(width: 760, height: 480))).response
            #expect(shot?.screenshot?.pixelWidth == 760)
            #expect(shot?.screenshot?.png == Data([0x89, 0x50, 0x4E, 0x47]))
            let missing = try await ctl(path, CtlRequest(command: .screenshot, screenshotElement: .sidebar)).response
            #expect(missing?.error?.code == "unknown_target")
            let noOut = try await ctl(path, CtlRequest(command: .recordStart)).response
            #expect(noOut?.error?.code == "bad_request")
            let start = try await ctl(path, CtlRequest(command: .recordStart, outPath: "/x.mov")).response
            #expect(start?.recording?.state == "recording")
            #expect(await d.recording)
            let stop = try await ctl(path, CtlRequest(command: .recordStop)).response
            #expect(stop?.recording?.state == "stopped")
        }
    }

    @Test func malformedRequestIsBadRequestNotACrash() async throws {
        try await withServer { path, _ in
            let conn = try AppSockClient.connect(path: path)
            try await conn.send(try CtlCodec.encoder().encode(AppSockHello(service: .ctl)))
            _ = try await conn.receive()
            try await conn.send(Data("{not json".utf8))
            let res = try CtlCodec.decoder().decode(CtlResponse.self, from: try await conn.receive())
            #expect(res.error?.code == "bad_request")
            await conn.close()
            // o servidor continua de pé
            let ok = try await ctl(path, CtlRequest(command: .state)).response
            #expect(ok?.ok == true)
        }
    }

    @Test func oversizedFrameClosesTheConnection() async throws {
        try await withServer { path, _ in
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            defer { close(fd) }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            path.withCString { src in
                withUnsafeMutableBytes(of: &addr.sun_path) { dst in dst.copyBytes(from: UnsafeRawBufferPointer(start: src, count: strlen(src) + 1)) }
            }
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            #expect(rc == 0)
            var header: [UInt8] = [0x7F, 0xFF, 0xFF, 0xFF]  // ~2 GiB declarados
            #expect(write(fd, &header, 4) == 4)
            var buf = [UInt8](repeating: 0, count: 8)
            #expect(read(fd, &buf, 8) == 0)  // EOF: o servidor fechou sem alocar nada
        }
    }

    @Test func concurrentClientsAreServed() async throws {
        try await withServer { path, _ in
            try await withThrowingTaskGroup(of: Bool.self) { group in
                for _ in 0..<12 {
                    group.addTask { try await ctl(path, CtlRequest(command: .state)).response?.ok == true }
                }
                var okCount = 0
                for try await ok in group where ok { okCount += 1 }
                #expect(okCount == 12)
            }
        }
    }
}
