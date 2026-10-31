import RackyDocker
import RackyPlatform
import RackyProtocol
import Foundation
import Testing

@testable import RackyCore

/// Cliente RFB mínimo sobre WebSocket, só para o teste (sem UI): handshake, Raw, requisições incrementais, KeyEvent e PointerEvent.
actor RFBConnection {
    struct Update { var rects: Int; var bytes: Int; var at: ContinuousClock.Instant; var distinctSample: Int }

    let task: URLSessionWebSocketTask
    private var buffer = Data()
    private(set) var width = 0
    private(set) var height = 0
    private var bytesPerPixel = 4

    init(url: URL) {
        var request = URLRequest(url: url)
        request.setValue("binary", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        task = URLSession(configuration: .ephemeral).webSocketTask(with: request)
    }

    func close() { pump?.cancel(); task.cancel(with: .normalClosure, reason: nil) }

    private var pump: Task<Void, Never>?
    private(set) var lastArrival = ContinuousClock.now

    private func append(_ data: Data) { buffer.append(data); lastArrival = .now }

    /// Uma tarefa lê o WebSocket e enche o buffer; quem lê espera por polling curto (`receive()` não é cancelável).
    private func startPump() {
        let socket = task
        pump = Task { [weak self] in
            while !Task.isCancelled {
                guard let message = try? await socket.receive() else { return }
                if case .data(let data) = message { await self?.append(data) }
            }
        }
    }

    private func fill(_ n: Int, timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        while buffer.count < n {
            guard ContinuousClock.now < deadline else { throw ToolError(.timeout, "rfb read timeout") }
            try await Task.sleep(for: .microseconds(400))
        }
    }

    func read(_ n: Int, timeout: Duration = .seconds(10)) async throws -> Data {
        try await fill(n, timeout: timeout)
        let chunk = Data(buffer.prefix(n))  // copia: índices a partir de 0
        buffer = Data(buffer.dropFirst(n))
        return chunk
    }

    func send(_ bytes: [UInt8]) async throws { try await task.send(.data(Data(bytes))) }

    /// RFB 3.8, segurança None, ClientInit shared. Pede só Raw (fácil de analisar; o noVNC real usa Tight/ZRLE).
    func handshake() async throws {
        task.resume()
        startPump()
        let version = try await read(12)
        guard String(decoding: version, as: UTF8.self).hasPrefix("RFB 003.") else { throw ToolError(.invalidArgument, "bad RFB version") }
        try await send(Array("RFB 003.008\n".utf8))
        let count = try await read(1)[0]
        let types = try await read(Int(count))
        guard types.contains(1) else { throw ToolError(.invalidArgument, "security None not offered: \(Array(types))") }
        try await send([1])
        let result = try await read(4)
        guard result == Data([0, 0, 0, 0]) else { throw ToolError(.invalidArgument, "security result failed") }
        try await send([1])  // shared
        let head = try await read(24)
        width = Int(head[0]) << 8 | Int(head[1])
        height = Int(head[2]) << 8 | Int(head[3])
        bytesPerPixel = Int(head[4]) / 8
        let nameLength = Int(head[20]) << 24 | Int(head[21]) << 16 | Int(head[22]) << 8 | Int(head[23])
        _ = try await read(nameLength)
        try await send([2, 0, 0, 1, 0, 0, 0, 0])  // SetEncodings: [Raw]
    }

    func requestUpdate(incremental: Bool, x: Int = 0, y: Int = 0, w: Int? = nil, h: Int? = nil) async throws {
        let w = w ?? width, h = h ?? height
        try await send([3, incremental ? 1 : 0, UInt8(x >> 8), UInt8(x & 255), UInt8(y >> 8), UInt8(y & 255), UInt8(w >> 8), UInt8(w & 255), UInt8(h >> 8), UInt8(h & 255)])
    }

    func key(_ keysym: UInt32, down: Bool) async throws {
        try await send([4, down ? 1 : 0, 0, 0, UInt8(keysym >> 24), UInt8((keysym >> 16) & 255), UInt8((keysym >> 8) & 255), UInt8(keysym & 255)])
    }

    func pointer(x: Int, y: Int, buttons: UInt8 = 0) async throws {
        try await send([5, buttons, UInt8(x >> 8), UInt8(x & 255), UInt8(y >> 8), UInt8(y & 255)])
    }

    /// Lê um FramebufferUpdate completo (Raw). `distinctSample`: quantas cores distintas entre os primeiros pixels (tela não vazia).
    func readUpdate(timeout: Duration = .seconds(10)) async throws -> Update {
        while true {
            let type = try await read(1, timeout: timeout)[0]
            switch type {
            case 0:
                let header = try await read(3, timeout: timeout)
                let rects = Int(header[1]) << 8 | Int(header[2])
                var total = 0
                var colors = Set<UInt32>()
                for _ in 0..<rects {
                    let rect = try await read(12, timeout: timeout)
                    let w = Int(rect[4]) << 8 | Int(rect[5]), h = Int(rect[6]) << 8 | Int(rect[7])
                    let encoding = Int32(bitPattern: UInt32(rect[8]) << 24 | UInt32(rect[9]) << 16 | UInt32(rect[10]) << 8 | UInt32(rect[11]))
                    guard encoding == 0 else { throw ToolError(.invalidArgument, "unexpected encoding \(encoding)") }
                    let pixels = try await read(w * h * bytesPerPixel, timeout: timeout)
                    total += pixels.count
                    var offset = 0
                    while offset + 4 <= pixels.count, colors.count < 8 {
                        colors.insert(UInt32(pixels[offset]) | UInt32(pixels[offset + 1]) << 8 | UInt32(pixels[offset + 2]) << 16)
                        offset += max(4, pixels.count / 64 / 4 * 4)
                    }
                }
                return Update(rects: rects, bytes: total, at: .now, distinctSample: colors.count)
            case 2: continue  // Bell
            case 1:
                let head = try await read(5, timeout: timeout)
                let n = Int(head[3]) << 8 | Int(head[4])
                _ = try await read(n * 6, timeout: timeout)
            default: throw ToolError(.invalidArgument, "unexpected server message \(type)")
            }
        }
    }

    /// Descarta o que já chegou e espera a tela ficar parada por `quiet`.
    func drain(quiet: Duration = .milliseconds(150)) async {
        while true {
            try? await requestUpdate(incremental: true)
            guard (try? await readUpdate(timeout: quiet)) != nil else { return }
        }
    }
}

@Suite("T3-05 - viewer com o Docker real", .serialized, .enabled(if: LiveC.enabled), .tags(.integration), .timeLimit(.minutes(10)))
struct LiveViewerTests {
    static let evidenceFile = "slice3/T3-05/live-viewer.json"
    static let spikeFile = "spikes/S3/ws-results.json"

    static func shortID() -> String { String(UUID().uuidString.lowercased().prefix(8)) }

    static let animationHTML = """
    <body style="margin:0;background:#fff"><canvas id=c width=640 height=400></canvas><script>
    const c=document.getElementById('c'),x=c.getContext('2d');let n=0;
    function f(){n++;for(let i=0;i<8;i++){x.fillStyle='hsl('+((n*4+i*40)%360)+',80%,50%)';x.fillRect(i*80,(n*3)%400,80,40)}
    x.fillStyle='#000';x.fillRect(0,0,200,30);x.fillStyle='#fff';x.font='20px monospace';x.fillText('frame '+n,10,22);requestAnimationFrame(f)}f()
    </script></body>
    """

    static let inputHTML = """
    <body style="margin:0"><input id=t style="font-size:24px;width:600px;margin:10px"><div id=box style="width:700px;height:400px;background:#00f"></div><script>
    let m=0;document.body.dataset.moves=0;
    document.addEventListener('mousemove',e=>{m++;window.__last=[e.clientX,e.clientY];document.getElementById('box').style.background=m%2?'#f00':'#00f';document.body.dataset.moves=m});
    window.__keys=[];window.__ev=[];document.addEventListener('keydown',e=>window.__keys.push(e.key));
    for (const t of ['mousedown','focusin','focus']) window.addEventListener(t,e=>window.__ev.push(t+':'+(e.target.id||e.target.nodeName)),true);
    </script></body>
    """

    static func install(_ html: String) -> JSON {
        let quoted = String(decoding: (try? JSONSerialization.data(withJSONObject: [html])) ?? Data(), as: UTF8.self).dropFirst().dropLast()
        return ["js": .string("document.open();document.write(\(quoted));document.close();1")]
    }

    @Test func realComputerStreamsFramesAcceptsHumanInputAndHonoursTheLease() async throws {
        let runID = Self.shortID()
        let detected = try await RuntimeDetector().detect()
        let client = DockerClient(runtime: detected.runtime, defaultTimeout: .seconds(60))
        let testLabels = [RackyLabel.test: "1", "racky.test_run": runID]
        let labelFilter = ["\(RackyLabel.test)=1", "racky.test_run=\(runID)"]
        let e = LiveEvidenceC.shared
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("abx-viewer-\(runID)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        func cleanup() async {
            let gc = GarbageCollector(client: client)
            if let items = try? await gc.inventory(labels: labelFilter) { await gc.remove(items) }
            if let images = try? await client.listImages(filters: ["label": labelFilter]) { for image in images { try? await client.removeImage(image.id, force: true) } }
            try? FileManager.default.removeItem(at: home)
        }
        do {
            try await scenario(runID: runID, detected: detected, client: client, testLabels: testLabels, home: home, e: e)
        } catch {
            await cleanup()
            await e.flush(to: Self.evidenceFile)
            throw error
        }
        await cleanup()
        let leftovers = (try? await GarbageCollector(client: client).inventory(labels: labelFilter)) ?? []
        #expect(leftovers.isEmpty, "the cleanup left resources behind: \(leftovers.map(\.name))")
        await e.record("cleanup", ["leftover_resources": .int(leftovers.count)])
        await e.flush(to: Self.evidenceFile)
    }

    func scenario(runID: String, detected: DetectedRuntime, client: DockerClient, testLabels: [String: String], home: URL, e: LiveEvidenceC) async throws {
        await e.record("runtime", .string("\(detected.runtime.kind.rawValue): Engine \(detected.version.version), \(detected.info.architecture)"))
        let images = ImageManager(client: client)
        let computerImage = try await images.ensure(ImageSource(repository: "racky-computer-test-\(runID)", contextDirectory: LiveC.repoRoot.appendingPathComponent("runtime/computer"), extraLabels: testLabels))
        let bridge = "abx-t-\(runID)-bridge"
        _ = try await client.createNetwork(name: bridge, isInternal: false, labels: testLabels)
        let labels = ComputerLabels(owner: "test-\(runID)", computerID: UUID().uuidString.lowercased(), computerName: "viewer-a", ephemeral: true, isTest: true)
        let token = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        let secrets = BoxSecretFiles(root: home)
        let config = EgressConfigFile.make(profile: nil, secret: nil)
        let runDirectory = home.appendingPathComponent("runs/live/viewer-a", isDirectory: true)
        let provisioned = try await ComputerProvisioner(client: client).provision(ComputerProvisionRequest(
            labels: labels, image: computerImage.tag, display: .headless, token: token, config: config, secrets: secrets,
            runDirectory: runDirectory, network: bridge, extraLabels: ["racky.test_run": runID]))
        let backend = DockerComputerBackend(client: client, computer: provisioned, secrets: secrets, baseConfig: config)
        let computer = try ManagedComputer(name: "viewer-a", display: .headless, run: RunFolder(root: runDirectory), backend: backend)
        let hub = ComputerHub()
        await hub.register(computer)
        await hub.registerChild(id: "child-v", capability: "cap-v")
        let service = ComputerToolService(hub: hub)

        func call(_ tool: String, _ args: JSON = [:]) async -> (isError: Bool, json: JSON) {
            let outcome = await service.call(tool, arguments: args, child: "child-v")
            let text = outcome.content.first?["text"]?.string ?? "null"
            return (outcome.isError, (try? JSON.parse(text)) ?? .null)
        }
        // Leitura direta do runtime (não é escrita do agente): funciona com o humano no controle.
        func eval(_ js: String) async throws -> String {
            let out = try await backend.runtime("eval", ["js": .string(js)], timeout: 15)
            return out["result_json"]?.string ?? ""
        }
        #expect(!(await call("box_claim", ["name": "viewer-a", "wait_s": 5])).isError)

        // ---- ticket e conexão: o ticket vale uma vez
        let url = try await backend.vncEndpoint()
        #expect(url.host == "127.0.0.1" && url.path == "/vnc" && url.query?.hasPrefix("ticket=") == true)
        let conn = RFBConnection(url: url)
        try await conn.handshake()
        let size = (await conn.width, await conn.height)
        #expect(size == (1440, 900))
        let reused = RFBConnection(url: url)
        await #expect(throws: (any Error).self) { try await reused.handshake() }  // ticket já consumido (CS-401)
        let plain = try await rawGet(port: provisioned.adminPort, path: "/vnc?ticket=nope")
        #expect(plain.hasPrefix("HTTP/1.1 400"))  // sem upgrade: recusado no egress
        await e.record("ticket", ["single_use": true, "server_init": "1440x900", "no_upgrade": "400"])

        // ---- frames: tela real, animação contínua
        _ = try await eval("1")
        _ = await call("browser_eval", Self.install(Self.animationHTML))
        try await Task.sleep(for: .milliseconds(800))
        try await conn.requestUpdate(incremental: false)
        let first = try await conn.readUpdate()
        #expect(first.bytes > 100_000 && first.distinctSample > 1, "the first frame is blank: \(first)")
        var frames = 0
        var bytes = 0
        let started = ContinuousClock.now
        var steadyStart: ContinuousClock.Instant?
        while started.duration(to: .now) < .seconds(8) {
            try await conn.requestUpdate(incremental: true)
            let update = try await conn.readUpdate()
            if steadyStart == nil, started.duration(to: .now) > .seconds(2) { steadyStart = update.at; frames = 0; bytes = 0 }
            if steadyStart != nil { frames += 1; bytes += update.bytes }
        }
        let steadySeconds = Double((steadyStart ?? started).duration(to: .now).components.seconds) + Double((steadyStart ?? started).duration(to: .now).components.attoseconds) / 1e18
        let fps = Double(frames) / max(0.1, steadySeconds)
        await e.record("ws_fps_raw_640x400_animation", ["fps": .double((fps * 10).rounded() / 10), "frames": .int(frames), "seconds": .double((steadySeconds * 10).rounded() / 10),
                                                        "mb_per_s": .double((Double(bytes) / steadySeconds / 1_000_000 * 10).rounded() / 10), "encoding": "Raw (worst case for the bridge)"])
        #expect(fps >= 20, "WebSocket frame rate \(fps) fps is below the 20 fps target (CS-401)")

        // ---- agente no controle: o VNC é view-only (CS-402), os cliques não chegam à página
        _ = await call("browser_eval", Self.install(Self.inputHTML))
        try await Task.sleep(for: .milliseconds(500))
        await conn.drain()
        try await conn.pointer(x: 500, y: 450)
        try await conn.pointer(x: 520, y: 470)
        try await Task.sleep(for: .milliseconds(500))
        #expect(try await eval("document.body.dataset.moves") == "\"0\"", "input reached the page while the agent had the lease")
        #expect(await computer.lease == .agent)

        // ---- Take Over: < 500 ms sem escrita em curso (CS-410)
        let tookStart = ContinuousClock.now
        #expect(try await computer.requestTakeOver())
        let takeOverMs = Double(tookStart.duration(to: .now).components.attoseconds) / 1e15 + Double(tookStart.duration(to: .now).components.seconds) * 1000
        #expect(takeOverMs < 500, "Take Over took \(takeOverMs) ms")
        #expect(await ctl(computer) == (.human, .human))
        try await conn.pointer(x: 500, y: 450)
        try await conn.pointer(x: 560, y: 480)
        try await Task.sleep(for: .milliseconds(500))
        let moves = Int(try await eval("document.body.dataset.moves").trimmingCharacters(in: CharacterSet(charactersIn: "\""))) ?? 0
        #expect(moves > 0, "input did not reach the page under the human lease")
        // o agente recebe human_in_control com retry_after_s (CS-412)
        let blocked = await call("browser_click", ["x": 5, "y": 5, "wait_s": 0])
        #expect(blocked.json["error"] == "human_in_control" && blocked.json["retry_after_s"] == 5)

        // ---- teclado ABNT2 por keysym (CA-403) e Unicode
        // Clique real do humano no campo (o runtime não tem gerenciador de janelas: o clique ativa a página).
        // O desvio entre a tela do X e o viewport do Chromium sai de um mousemove real: (tela - clientX/Y).
        try await conn.pointer(x: 600, y: 500)
        try await Task.sleep(for: .milliseconds(400))
        let last = (try? JSONSerialization.jsonObject(with: Data(try await eval("window.__last").utf8)) as? [Int]) ?? [0, 0]
        let target = try await eval("(() => { const r = document.getElementById('t').getBoundingClientRect(); return [Math.round(r.left + 40), Math.round(r.top + 12)]; })()")
        let inField = (try? JSONSerialization.jsonObject(with: Data(target.utf8)) as? [Int]) ?? [40, 22]
        let coords = [600 - last[0] + inField[0], 500 - last[1] + inField[1]]
        try await conn.pointer(x: coords[0], y: coords[1])
        try await conn.pointer(x: coords[0], y: coords[1], buttons: 1)
        try await Task.sleep(for: .milliseconds(60))
        try await conn.pointer(x: coords[0], y: coords[1], buttons: 0)
        try await Task.sleep(for: .milliseconds(300))
        let typed: [(UInt32, String)] = [(0x61, "a"), (0xE7, "ç"), (0xE3, "ã"), (0x6F, "o"), (0x20, " "), (0xE7, "ç"), (0x20, " "), (0xE3, "ã"), (0x20, " "), (0xE9, "é"), (0x20, " "), (0x20AC, "€")]
        for (keysym, _) in typed {
            let sym = keysym > 0xFF ? 0x0100_0000 + keysym : keysym
            try await conn.key(sym, down: true)
            try await conn.key(sym, down: false)
            try await Task.sleep(for: .milliseconds(30))
        }
        try await Task.sleep(for: .milliseconds(400))
        let diag = try await eval("JSON.stringify({keys: window.__keys, ev: window.__ev, active: document.activeElement && document.activeElement.id, focus: document.hasFocus(), spot: [window.screenX, window.screenY, window.outerWidth, window.innerWidth, window.outerHeight, window.innerHeight]})")
        await e.record("abnt2_diag", .string(diag))
        let value = try await eval("document.getElementById('t').value")
        #expect(value == "\"ação ç ã é €\"", "keyboard produced \(value)")
        await e.record("abnt2_typing", ["typed": "ação ç ã é €", "page_value": .string(value)])

        // ---- latência de input (CA-401): o clique muda a tela, o tempo até o quadro seguinte
        _ = try await eval("document.getElementById('t').blur(); 1")
        await conn.drain()
        var samples: [Double] = []
        for i in 0..<40 {
            await conn.drain(quiet: .milliseconds(120))
            try await conn.requestUpdate(incremental: true)
            let t0 = ContinuousClock.now
            try await conn.pointer(x: 400 + (i % 2) * 120, y: 480 + i)
            let update = try await conn.readUpdate(timeout: .seconds(3))
            let delta = t0.duration(to: update.at).components
            samples.append((Double(delta.seconds) * 1000 + Double(delta.attoseconds) / 1e15 * 1).rounded())
        }
        samples.sort()
        let p50 = samples[samples.count / 2], p95 = samples[Int(Double(samples.count) * 0.95) - 1]
        await e.record("ws_input_latency_ms", ["samples": .int(samples.count), "p50": .double(p50), "p95": .double(p95), "max": .double(samples.last ?? 0)])
        #expect(p95 < 100, "input latency p95 \(p95) ms (p50 \(p50))")

        // ---- Hand Back com nota: o agente volta, o input humano para, a nota segue na próxima chamada
        try await conn.key(0x61, down: true)  // tecla pressionada na hora da devolução
        try await Task.sleep(for: .milliseconds(100))
        try await computer.handBack(note: "Signed in, continue from page 3")
        #expect(await computer.lease == .agent)
        let status = await call("box_status")
        #expect(status.json["lease"] == "agent" && status.json["human_handback"]?["note"] == "Signed in, continue from page 3")
        let before = try await eval("document.body.dataset.moves")
        try await conn.pointer(x: 300, y: 500)
        try await Task.sleep(for: .milliseconds(400))
        #expect(try await eval("document.body.dataset.moves") == before, "input still reached the page after Hand Back")

        // ---- escrita do agente que falha não muda o lease nem derruba o viewer (CA-405)
        #expect(await call("browser_click", ["selector": "#does-not-exist", "wait_s": 0]).json["error"] == "timeout")
        #expect(await computer.lease == .agent)
        try await conn.requestUpdate(incremental: false, w: 100, h: 100)
        _ = try await conn.readUpdate()  // o stream continua

        // ---- CA-402: Take Over durante um browser_wait longo
        let waiting = Task { await call("browser_wait", ["for": ["text": "never-appears-anywhere"], "timeout_s": 6]) }
        try await Task.sleep(for: .milliseconds(1200))
        let revokeStart = ContinuousClock.now
        let acked = try await computer.requestTakeOver()
        let revokeSeconds = Double(revokeStart.duration(to: .now).components.seconds) + Double(revokeStart.duration(to: .now).components.attoseconds) / 1e18
        #expect(acked)
        #expect(revokeSeconds > 3 && revokeSeconds < 6.5, "ACK only after the write in flight ended: \(revokeSeconds) s")
        let waitResult = await waiting.value
        #expect(waitResult.json["error"] == "human_in_control", "the in-flight call answered \(waitResult.json.text)")
        #expect(await computer.lease == .human)  // o lease não voltou para o agente
        await e.record("take_over_during_write", ["ack_after_seconds": .double((revokeSeconds * 10).rounded() / 10), "agent_call_result": waitResult.json["error"] ?? .null, "lease_after": "human"])
        try await computer.handBack(note: nil)

        // ---- miniatura (CS-403) e isolamento do VNC
        let thumb = try #require(await computer.thumbnail())
        #expect(Array(thumb.prefix(2)) == [0xFF, 0xD8] && thumb.count > 1500)
        await e.record("thumbnail", ["jpeg_bytes": .int(thumb.count)])
        let probe = await service.call("exec", arguments: ["shell": "(echo > /dev/tcp/runtime/5900) 2>&1; echo rc=$?", "timeout_s": 8], child: "child-v")
        let probeText = probe.content.first?["text"]?.string ?? ""
        #expect(!probeText.contains("rc=0"), "x11vnc is reachable from the work container: \(probeText)")
        await e.record("x11vnc_from_work", "not reachable (listens on the runtime loopback only)")
        await conn.close()
        await e.flush(to: Self.spikeFile)
    }

    func rawGet(port: Int, path: String) async throws -> String {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.timeoutInterval = 5
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        return "HTTP/1.1 \((response as? HTTPURLResponse)?.statusCode ?? 0) \(String(decoding: data, as: UTF8.self))"
    }
}
