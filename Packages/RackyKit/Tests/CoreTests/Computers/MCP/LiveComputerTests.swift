import RackyDocker
import RackyPlatform
import RackyProtocol
import CryptoKit
import Foundation
import Testing

@testable import RackyCore

/// T3-03 com o Docker real (`RACKY_TEST_DOCKER=1`): sobe um computador de verdade (rede interna, egress, runtime com Chromium
/// headed em Xvfb, work) e exercita as ferramentas MCP de ponta a ponta contra uma página servida pelo próprio teste, numa
/// rede de teste (sem internet externa obrigatória). Só toca em recursos `racky.test=1` + `racky.test_run=<id>`.
enum LiveC {
    static let enabled = ProcessInfo.processInfo.environment["RACKY_TEST_DOCKER"] == "1"
    static let evidenceRoot: URL? = ProcessInfo.processInfo.environment["RACKY_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0) }

    static var repoRoot: URL {
        var root = URL(fileURLWithPath: #filePath)
        while root.path != "/", !FileManager.default.fileExists(atPath: root.appendingPathComponent("runtime/computer/Dockerfile").path) {
            root.deleteLastPathComponent()
        }
        return root
    }
}

actor LiveEvidenceC {
    static let shared = LiveEvidenceC()
    private var values: [String: JSON] = [:]

    func record(_ key: String, _ value: JSON) { values[key] = value }

    func flush(to file: String) {
        guard let root = LiveC.evidenceRoot else { return }
        let url = root.appendingPathComponent(file)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSON.object(values).data(pretty: true).write(to: url)
    }
}

/// O "site" da cena: página com formulário, botão que dispara XHR, download, upload, cookie e eco de POST; mais um falso modo
/// API/render (Zyte) que confere a chave Basic.
let liveOriginScript = #"""
import base64, http.server, json, urllib.parse

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def out(self, body, ctype="text/html", code=200, extra=None):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(b)))
        for k, v in (extra or {}).items(): self.send_header(k, v)
        self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        p = urllib.parse.urlparse(self.path); q = urllib.parse.parse_qs(p.query)
        if p.path == "/":
            self.out("<html><head><title>Origin Page</title></head><body><h1 id=t>Hello Origin</h1><a href='/form'>form</a>"
                     "<button id=go onclick=\"fetch('/api/data').then(r=>r.json()).then(d=>{document.getElementById('t').innerText='clicked '+d.items.length})\">Go</button>"
                     "<div style='height:3000px'></div></body></html>")
        elif p.path == "/api/data": self.out(json.dumps({"items": [1, 2, 3], "note": "needle-xyz"}), "application/json")
        elif p.path == "/form":
            self.out("<html><head><title>Form</title></head><body><form action='/submit' method='get'><input id=q name=q type=text>"
                     "<input id=pw name=pw type=password value='hunter2'><select id=s name=s><option value=a>A</option><option value=b>B</option></select>"
                     "<button id=send type=submit>Send</button></form></body></html>")
        elif p.path == "/submit": self.out("<html><body><p id=r>Submitted q=%s s=%s</p></body></html>" % (q.get("q", [""])[0], q.get("s", [""])[0]))
        elif p.path == "/set-cookie": self.out("<html><body>cookie set</body></html>", extra={"Set-Cookie": "sid=abc123; Path=/"})
        elif p.path == "/needs-cookie":
            ok = "sid=abc123" in (self.headers.get("Cookie") or "")
            self.out(json.dumps({"ok": ok}), "application/json", 200 if ok else 401)
        elif p.path == "/dl": self.out("<html><body><a id=dl href='/download.txt' download>get</a></body></html>")
        elif p.path == "/download.txt": self.out("downloaded-content-42", "application/octet-stream", extra={"Content-Disposition": "attachment; filename=download.txt"})
        elif p.path == "/upload":
            self.out("<html><body><input type=file id=f onchange=\"document.getElementById('name').innerText=this.files[0].name+':'+this.files[0].size\"><span id=name></span></body></html>")
        else: self.out("not found", "text/plain", 404)
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0); body = self.rfile.read(n).decode("utf-8", "replace")
        if self.path == "/echo":
            self.out(json.dumps({"method": "POST", "content_type": self.headers.get("Content-Type"), "body": body, "x_test": self.headers.get("X-Test")}), "application/json")
        elif self.path == "/zyte":
            want = "Basic " + base64.b64encode(b"fake-render-key-123456:").decode()
            if self.headers.get("Authorization") != want: return self.out(json.dumps({"detail": "bad key"}), "application/json", 401)
            self.out(json.dumps({"browserHtml": "<html><body><h1>rendered listings</h1></body></html>", "networkCapture": [
                {"url": "http://origin:8080/api/listings", "method": "GET", "statusCode": 200,
                 "httpResponseBody": base64.b64encode(b'{"listings":[7,8,9]}').decode()}]}), "application/json")
        else: self.out("not found", "text/plain", 404)

http.server.ThreadingHTTPServer(("0.0.0.0", 8080), H).serve_forever()
"""#

@Suite("T3-03 - computador real com ferramentas MCP", .serialized, .enabled(if: LiveC.enabled), .tags(.integration), .timeLimit(.minutes(10)))
struct LiveComputerTests {
    static let evidenceFile = "slice3/T3-03/live-mcp.json"

    struct Rig {
        let hub: ComputerHub
        let service: ComputerToolService
        let server: ComputerMCPServer
        let computer: ManagedComputer
        let provisioned: ProvisionedComputer
        let client: DockerClient
        let secrets: BoxSecretFiles
        let token: String
        var work: URL { computer.run.work }
        var maxCallSeconds: Locked<Double>

        @discardableResult
        func call(_ tool: String, _ args: JSON = [:], child: String = "child-live") async -> (isError: Bool, json: JSON, outcome: ToolOutcome) {
            let started = ContinuousClock.now
            let outcome = await service.call(tool, arguments: args, child: child)
            let elapsed = started.duration(to: .now)
            maxCallSeconds.update { $0 = max($0, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18) }
            let text = outcome.content.first?["text"]?.string ?? "null"
            return (outcome.isError, (try? JSON.parse(text)) ?? .null, outcome)
        }

        func ok(_ tool: String, _ args: JSON = [:]) async -> JSON {
            let result = await call(tool, args)
            #expect(!result.isError, "\(tool) \(args.text) failed: \(result.json.text)")
            return result.json
        }

        func sh(_ script: String, timeout: Double = 40, stdin: String? = nil) async -> JSON {
            var args: [String: JSON] = ["shell": .string(script), "timeout_s": .double(timeout)]
            if let stdin { args["stdin"] = .string(stdin) }
            return await ok("exec", .object(args))
        }

        func records() -> [[String: JSON]] { ChainedLog.read(computer.run.requestsFile) }
    }

    final class Locked<T: Sendable>: @unchecked Sendable {  // SAFETY: teste; NSLock protege o valor.
        private let lock = NSLock()
        private var value: T
        init(_ value: T) { self.value = value }
        func update(_ body: (inout T) -> Void) { lock.lock(); body(&value); lock.unlock() }
        func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    }

    static func shortID() -> String { String(UUID().uuidString.lowercased().prefix(8)) }

    @Test func realComputerWithBrowserExecHttpEvidenceAndHelp() async throws {
        let runID = Self.shortID()
        let detected = try await RuntimeDetector().detect()
        let client = DockerClient(runtime: detected.runtime, defaultTimeout: .seconds(60))
        let testLabels = [RackyLabel.test: "1", "racky.test_run": runID]
        let labelFilter = ["\(RackyLabel.test)=1", "racky.test_run=\(runID)"]
        let e = LiveEvidenceC.shared
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("abx-live-\(runID)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        func cleanup() async {
            let gc = GarbageCollector(client: client)
            if let items = try? await gc.inventory(labels: labelFilter) { await gc.remove(items) }
            if let images = try? await client.listImages(filters: ["label": labelFilter]) { for image in images { try? await client.removeImage(image.id, force: true) } }
            try? FileManager.default.removeItem(at: home)
        }

        do {
            try await runScenario(runID: runID, detected: detected, client: client, testLabels: testLabels, home: home, e: e)
        } catch {
            await cleanup()
            await e.flush(to: Self.evidenceFile)
            throw error
        }
        await cleanup()
        let leftovers = (try? await GarbageCollector(client: client).inventory(labels: labelFilter)) ?? []
        #expect(leftovers.isEmpty, "the cleanup left resources behind: \(leftovers.map(\.name))")
        let images = (try? await client.listImages(filters: ["label": labelFilter])) ?? []
        #expect(images.isEmpty, "the cleanup left images behind")
        await e.record("cleanup", ["leftover_resources": .int(leftovers.count), "leftover_images": .int(images.count)])
        await e.flush(to: Self.evidenceFile)
    }

    func runScenario(runID: String, detected: DetectedRuntime, client: DockerClient, testLabels: [String: String], home: URL, e: LiveEvidenceC) async throws {
        await e.record("runtime", .string("\(detected.runtime.kind.rawValue): Engine \(detected.version.version), \(detected.info.architecture)"))

        // ---- imagens: contexto REAL de runtime/computer, rótulos de teste
        let images = ImageManager(client: client)
        let t0 = ContinuousClock.now
        let computerImage = try await images.ensure(ImageSource(repository: "racky-computer-test-\(runID)", contextDirectory: LiveC.repoRoot.appendingPathComponent("runtime/computer"), extraLabels: testLabels))
        await e.record("images", ["image": .string(computerImage.tag), "build_seconds": .int(Int(t0.duration(to: .now).components.seconds))])

        // ---- cena: bridge de saída de teste + "site" (origin), servido pelo próprio teste
        let bridge = "abx-t-\(runID)-bridge"
        let bridgeID = try await client.createNetwork(name: bridge, isInternal: false, labels: testLabels)
        let subnet = try #require(try await client.inspectNetwork(bridgeID).subnets.first)
        var origin = ContainerSpec(name: "abx-t-\(runID)-origin", image: computerImage.tag)
        origin.entrypoint = ["python"]
        origin.command = ["-c", liveOriginScript]
        origin.labels = testLabels.merging([RackyLabel.owner: "test-\(runID)", RackyLabel.computer: "c-origin-\(runID)", RackyLabel.ephemeral: "true"]) { $1 }
        origin.user = "65534"
        origin.tmpfs = ["/tmp": "rw,nosuid,size=16m"]
        origin.resources = ContainerResources(memoryBytes: 128 << 20, cpus: 0.5, pidsLimit: 128)
        origin.network = ContainerNetworkAttachment(network: bridge, aliases: ["origin"])
        let originID = try await client.createContainer(origin)
        try await client.startContainer(originID)

        // ---- computador de verdade
        let labels = ComputerLabels(owner: "test-\(runID)", computerID: UUID().uuidString.lowercased(), computerName: "live-a", ephemeral: true, isTest: true)
        let token = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        let secrets = BoxSecretFiles(root: home)
        let config = EgressConfigFile.make(profile: nil, secret: nil, allowCIDRs: [subnet])  // exceção SÓ para a bridge de teste
        let runDirectory = home.appendingPathComponent("runs/live/live-a", isDirectory: true)
        let provisioner = ComputerProvisioner(client: client)
        let t1 = ContinuousClock.now
        let provisioned = try await provisioner.provision(ComputerProvisionRequest(
            labels: labels, image: computerImage.tag, display: .headless, token: token, config: config, secrets: secrets,
            runDirectory: runDirectory, network: bridge, extraLabels: ["racky.test_run": runID]))
        await e.record("provision_seconds", .int(Int(t1.duration(to: .now).components.seconds)))
        // o origin precisa estar de pé antes da primeira navegação
        try await Task.sleep(for: .milliseconds(1500))

        let resolver: ProxyConfigResolver = { name, _ in
            if name == "zyte-fake" {
                return (EgressConfigFile(via: "zyte-fake", upstream: nil, render: EgressRender(endpoint: "http://origin:8080/zyte", apiKey: "fake-render-key-123456"), internalSubnet: ""), nil)
            }
            return (EgressConfigFile.make(profile: nil, secret: nil), nil)
        }
        let backend = DockerComputerBackend(client: client, computer: provisioned, secrets: secrets, baseConfig: config, resolver: resolver)
        let computer = try ManagedComputer(
            name: "live-a", display: .headless, run: RunFolder(root: runDirectory), backend: backend, proxiesAllowed: ["zyte-fake"], profile: nil)
        let hub = ComputerHub()
        await hub.register(computer)
        await hub.registerChild(id: "child-live", capability: "cap-live")
        let service = ComputerToolService(hub: hub)
        let rig = Rig(hub: hub, service: service, server: ComputerMCPServer(tools: service), computer: computer, provisioned: provisioned, client: client, secrets: secrets,
                      token: token, maxCallSeconds: Locked(0))

        // =========================================================== claim
        let claim = await rig.ok("box_claim", ["name": "live-a", "wait_s": 5])
        #expect(claim["state"] == "in_use" && claim["display"] == "headless" && claim["work_path_box"] == "/work")
        #expect(claim["work_path_host"]?.string == rig.work.path)

        // =========================================================== browser: navegar, ler, screenshot, clicar
        let open = await rig.ok("browser_open", ["url": "http://origin:8080/", "wait_s": 0])
        #expect(open["status"] == 200 && open["title"] == "Origin Page" && open["url"] == "http://origin:8080/")
        let openID = try #require(open["request_id"]?.string)
        let openRecord = try #require(rig.records().first { $0["id"]?.string == openID })
        #expect(openRecord["source"] == "browser" && openRecord["trust"] == "observed" && openRecord["status"] == 200 && openRecord["method"] == "GET")
        await e.record("browser_open", ["status": 200, "request_id": .string(openID), "record_source": openRecord["source"] ?? .null, "record_trust": openRecord["trust"] ?? .null])

        let text = await rig.ok("browser_read", ["what": "text"])
        #expect(text["content"]?.string?.contains("Hello Origin") == true && text["truncated"] == false)
        let html = await rig.ok("browser_read", ["what": "html"])
        #expect(html["content"]?.string?.contains("<button id=\"go\"") == true || html["content"]?.string?.contains("<button id=go") == true)
        let links = await rig.ok("browser_read", ["what": "links"])
        #expect(links["content"]?.string?.contains("http://origin:8080/form") == true)
        let aria = await rig.ok("browser_read", ["what": "accessibility"])
        #expect(aria["content"]?.string?.contains("Go") == true)
        let paged = await rig.ok("browser_read", ["what": "text", "max_chars": 5, "offset": 0])
        #expect(paged["truncated"] == true && paged["next_offset"] == 5 && paged["content"]?.string?.count == 5)

        let shot = await rig.call("browser_screenshot", ["save_as": "shots/home.png"])
        #expect(!shot.isError)
        let png = try #require(shot.outcome.content.dropFirst().first?["data"]?.string.flatMap { Data(base64Encoded: $0) })
        #expect(Array(png.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] && png.count > 2000)
        #expect(try Data(contentsOf: rig.work.appendingPathComponent("shots/home.png")) == png)
        #expect(!(await rig.call("browser_screenshot", ["selector": "#t"])).isError)
        #expect(errorCode(await rig.call("browser_screenshot", ["save_as": "../x.png"])) == "path_rejected")
        await e.record("screenshot", ["png_bytes": .int(png.count), "file": "/work/shots/home.png"])

        let click = await rig.ok("browser_click", ["selector": "#go", "wait_s": 0.2])
        #expect(click["navigated"] == false)
        let waited = await rig.ok("browser_wait", ["for": ["text": "clicked 3"], "timeout_s": 10])
        #expect(waited["matched"] == true)
        #expect((await rig.ok("browser_read", ["what": "text", "selector": "#t"]))["content"] == "clicked 3")
        #expect((await rig.ok("browser_wait", ["for": ["text": "never-appears"], "timeout_s": 1]))["matched"] == false)
        #expect(errorCode(await rig.call("browser_click", ["selector": "#does-not-exist", "wait_s": 0])) == "timeout")
        let coordinate = await rig.ok("browser_click", ["x": 5, "y": 5, "wait_s": 0])
        #expect(coordinate["navigated"] == false)

        // o XHR da página está no reqlog (browser, observed), com o corpo
        let xhr = await rig.ok("reqlog_query", ["xhr": true, "source": "browser"])
        let xhrRecords = xhr["records"]?.array ?? []
        let api = try #require(xhrRecords.first { $0["url"]?.string?.hasSuffix("/api/data") == true })
        #expect(api["status"] == 200 && api["trust"] == "observed")
        let apiBody = await rig.ok("reqlog_get", ["id": api["id"] ?? .null])
        #expect(apiBody["body"]?.string?.contains("needle-xyz") == true)
        let grep = await rig.ok("reqlog_query", ["grep": "needle-xyz"])
        #expect((grep["records"]?.array ?? []).contains { $0["id"] == api["id"] })
        await e.record("xhr_in_reqlog", ["id": api["id"] ?? .null, "source": "browser", "trust": "observed"])

        // formulário: digitar, selecionar, enviar
        _ = await rig.ok("browser_open", ["url": "http://origin:8080/form", "wait_s": 0])
        let forms = await rig.ok("browser_read", ["what": "forms"])
        #expect(forms["content"]?.string?.contains("********") == true && forms["content"]?.string?.contains("hunter2") == false)  // senha mascarada
        _ = await rig.ok("browser_type", ["selector": "#q", "text": "phoenix az"])
        #expect((await rig.ok("browser_select", ["selector": "#s", "values": ["b"]]))["selected"] == ["b"])
        let sent = await rig.ok("browser_click", ["selector": "#send", "wait_s": 5])
        #expect(sent["navigated"] == true)
        #expect((await rig.ok("browser_read", ["what": "text"]))["content"]?.string?.contains("Submitted q=phoenix az s=b") == true)
        // history, scroll, eval, abas, teclas
        #expect((await rig.ok("browser_back"))["url"] == "http://origin:8080/form")
        #expect((await rig.ok("browser_forward"))["url"]?.string?.contains("/submit") == true)
        #expect((await rig.ok("browser_reload"))["status"] == 200)
        _ = await rig.ok("browser_open", ["url": "http://origin:8080/", "wait_s": 0])
        #expect((await rig.ok("browser_scroll", ["dy": 500]))["scroll_y"]?.double == 500)
        #expect((await rig.ok("browser_eval", ["js": "document.title"]))["result_json"] == "\"Origin Page\"")
        #expect(errorCode(await rig.call("browser_eval", ["js": "this is not js ("])) == "invalid_argument")
        _ = await rig.ok("browser_press", ["keys": "Tab"])
        let tabs = await rig.ok("browser_tabs", ["action": "new", "url": "http://origin:8080/form"])
        #expect(tabs["tabs"]?.array?.count == 2)
        #expect((await rig.ok("browser_tabs", ["action": "switch", "index": 0]))["tabs"]?.array?.first?["active"] == true)
        #expect((await rig.ok("browser_tabs", ["action": "close", "index": 1]))["tabs"]?.array?.count == 1)

        // cookies: jar para curl_cffi
        _ = await rig.ok("browser_open", ["url": "http://origin:8080/set-cookie", "wait_s": 0])
        let jar = await rig.ok("browser_cookies", ["action": "get"])
        #expect((jar["cookies"]?.array ?? []).contains { $0["name"] == "sid" && $0["value"] == "abc123" })
        #expect(await rig.ok("browser_cookies", ["action": "export"])["file"] == "/work/cookies.json")
        #expect(try JSON.parse(try Data(contentsOf: rig.work.appendingPathComponent("cookies.json"))).array?.isEmpty == false)

        // AC-412 (a parte do runtime): headless <-> desktop não reabre o browser nem recarrega a página (marcador no DOM e cookie ficam)
        _ = await rig.ok("browser_open", ["url": "http://origin:8080/", "wait_s": 0])
        _ = await rig.ok("browser_eval", ["js": "document.body.dataset.marker = 'kept-through-mode-switch'; 1"])
        let recordsBeforeMode = rig.records().count
        let toDesktop = await rig.ok("computer_mode", ["display": "desktop"])
        #expect(toDesktop["display"] == "desktop" && toDesktop["reloaded"] == false)
        #expect((await rig.ok("browser_eval", ["js": "document.body.dataset.marker"]))["result_json"] == "\"kept-through-mode-switch\"")
        #expect(((await rig.ok("browser_cookies", ["action": "get"]))["cookies"]?.array ?? []).contains { $0["name"] == "sid" })
        #expect((await rig.ok("computer_mode", ["display": "headless"]))["reloaded"] == false)
        #expect((await rig.ok("browser_eval", ["js": "document.body.dataset.marker"]))["result_json"] == "\"kept-through-mode-switch\"")
        #expect(rig.records().count == recordsBeforeMode, "the mode switch caused a navigation")  // o reqlog não registra navegação nova
        #expect(errorCode(await rig.call("computer_mode", ["display": "http"])) == "not_supported")
        await e.record("mode_switch", ["page_marker_kept": true, "cookie_kept": true, "reloaded": false, "new_requests": 0])

        // download e upload com arquivos em /work
        _ = await rig.ok("browser_open", ["url": "http://origin:8080/dl", "wait_s": 0])
        let download = await rig.ok("browser_download", ["selector": "#dl", "timeout_s": 20])
        #expect(download["file"] == "/work/downloads/download.txt" && download["bytes"] == 21)
        #expect(try String(contentsOf: rig.work.appendingPathComponent("downloads/download.txt"), encoding: .utf8) == "downloaded-content-42")
        try Data("12345".utf8).write(to: rig.work.appendingPathComponent("up.txt"))
        _ = await rig.ok("browser_open", ["url": "http://origin:8080/upload", "wait_s": 0])
        #expect(await rig.ok("browser_upload", ["selector": "#f", "file": "up.txt"])["uploaded"] == true)
        _ = await rig.ok("browser_wait", ["for": ["text": "up.txt:5"], "timeout_s": 5])
        #expect((await rig.ok("browser_read", ["what": "text", "selector": "#name"]))["content"] == "up.txt:5")

        // =========================================================== http_request pelo egress (curl_cffi no work)
        let get = await rig.ok("http_request", ["method": "GET", "url": "http://origin:8080/api/data", "impersonate": "chrome"])
        #expect(get["status"] == 200 && get["body_inline"]?.string?.contains("needle-xyz") == true && get["via"] == "direct")
        let getID = try #require(get["request_id"]?.string)
        let getRecord = try #require(rig.records().first { $0["id"]?.string == getID })
        #expect(getRecord["source"] == "work:python" && getRecord["trust"] == "observed" && getRecord["impersonate"] == "chrome")
        let post = await rig.ok("http_request", ["method": "POST", "url": "http://origin:8080/echo", "headers": ["X-Test": "1"], "json": ["a": 1, "b": "two"]])
        let echoed = try JSON.parse(try #require(post["body_inline"]?.string))
        #expect(echoed["method"] == "POST" && echoed["x_test"] == "1" && echoed["content_type"]?.string?.contains("application/json") == true)
        #expect(try JSON.parse(try #require(echoed["body"]?.string)) == ["a": 1, "b": "two"])
        let form = await rig.ok("http_request", ["method": "POST", "url": "http://origin:8080/echo", "form": ["k": "v w"]])
        #expect(try JSON.parse(try #require(form["body_inline"]?.string))["content_type"]?.string?.contains("x-www-form-urlencoded") == true)
        // o egress registrou a mesma chamada por conta própria (o agente não forja isso)
        let egressRows = rig.records().filter { $0["source"]?.string == "egress" && $0["host"] == "origin" && $0["kind"] == "http" }
        #expect(egressRows.count >= 3)
        let cookieGet = await rig.ok("http_request", ["method": "GET", "url": "http://origin:8080/needs-cookie", "cookies_from_browser": true])
        #expect(cookieGet["status"] == 200)
        let noCookie = await rig.ok("http_request", ["method": "GET", "url": "http://origin:8080/needs-cookie"])
        #expect(noCookie["status"] == 401)
        // as credenciais do cookie não aparecem no reqlog
        #expect(!((try? String(contentsOf: rig.computer.run.requestsFile, encoding: .utf8)) ?? "").contains("abc123"))
        // CA-106 / SSRF: destinos internos recusados com motivo no reqlog
        for (tool, args) in [
            ("browser_open", ["url": "http://169.254.169.254/latest", "wait_s": 0]), ("browser_open", ["url": "http://host.docker.internal/", "wait_s": 0]),
            ("browser_open", ["url": "http://10.0.0.1/", "wait_s": 0]), ("http_request", ["method": "GET", "url": "http://169.254.169.254/latest"]),
            ("http_request", ["method": "GET", "url": "http://192.168.0.1/"]),
        ] as [(String, JSON)] {
            let r = await rig.call(tool, args)
            #expect(errorCode(r) == "blocked_by_policy", "\(tool) \(args.text) -> \(r.json.text)")
            #expect(r.json["details"]?["reason"]?.string?.isEmpty == false)
        }
        let blocked = await rig.ok("reqlog_query", ["errors": true, "source": "egress"])
        #expect((blocked["records"]?.array ?? []).contains { $0["blocked"] == "link-local" })
        await e.record("ssrf_blocked", ["metadata_ip": "blocked_by_policy(link-local)", "host.docker.internal": "blocked_by_policy", "rfc1918": "blocked_by_policy"])

        // =========================================================== exec no work (separação control/work, stdin, log)
        let cat = await rig.ok("exec", ["argv": ["cat"], "stdin": "hello from stdin\nsecond line\n"])
        #expect(cat["exit_code"] == 0 && cat["stdout_tail"] == "hello from stdin\nsecond line\n")
        let ident = await rig.sh("id -u; pwd; echo to-stderr >&2; exit 3")
        #expect(ident["exit_code"] == 3 && ident["stdout_tail"] == "10001\n/work\n" && ident["stderr_tail"] == "to-stderr\n")
        _ = await rig.sh("echo from-work > /work/out.txt; mkdir -p /work/sub && echo nested > /work/sub/n.txt")
        #expect(try String(contentsOf: rig.work.appendingPathComponent("out.txt"), encoding: .utf8) == "from-work\n")  // /work é o bind do host
        #expect((await rig.ok("exec", ["argv": ["cat", "n.txt"], "cwd": "/work/sub"]))["stdout_tail"] == "nested\n")
        #expect(errorCode(await rig.call("exec", ["argv": ["ls"], "cwd": "../../etc"])) == "path_rejected")
        // sem rota para fora; o proxy é o único caminho
        #expect((await rig.sh("curl -sS -m 4 --noproxy '*' http://1.1.1.1/ >/dev/null 2>&1; echo rc=$?"))["stdout_tail"] != "rc=0\n")
        #expect((await rig.sh("curl -sS -m 5 --noproxy '*' http://origin:8080/ >/dev/null 2>&1; echo rc=$?"))["stdout_tail"] != "rc=0\n")  // origin só existe na bridge
        #expect((await rig.sh("curl -sS -m 10 http://origin:8080/api/data"))["stdout_tail"]?.string?.contains("needle-xyz") == true)  // pelo proxy: funciona
        // AC-416: o `curl` do work também está no reqlog (registro do egress, com corpo) e o "Copy as cURL" reproduz o request
        let curlRows = await rig.ok("reqlog_query", ["source": "egress", "grep": "needle-xyz", "host": "origin"])
        #expect((curlRows["records"]?.array ?? []).count >= 1)
        let asCurl = await rig.ok("reqlog_as_curl", ["id": api["id"] ?? .null])
        let replay = await rig.sh(try #require(asCurl["curl"]?.string))
        #expect(replay["exit_code"] == 0 && replay["stdout_tail"]?.string?.contains("needle-xyz") == true, "replay: \(replay.text)")
        #expect(asCurl["python_curl_cffi"]?.string?.contains("from curl_cffi import requests") == true)
        await e.record("reqlog_as_curl_replay", ["status": "reproduced the browser XHR from the work container"])

        // CA-105: nada de segredo, token nem API de controle no work
        let environment = await rig.sh("env")
        #expect(environment["stdout_tail"]?.string?.contains(rig.token) == false)
        #expect((await rig.sh("ls /run/racky/token /run/racky/egress.json 2>&1; echo rc=$?"))["stdout_tail"]?.string?.contains("rc=0") == false)
        #expect((await rig.sh("curl -s -m 4 --noproxy '*' -o /dev/null -w '%{http_code}' -X POST -d '{}' http://127.0.0.1:8765/v1/open"))["stdout_tail"] == "000")  // firewall por uid: o agente nem alcança a API de controle
        #expect((await rig.sh("curl -s -m 4 --noproxy '*' -o /dev/null -w '%{http_code}' http://127.0.0.1:8790/v1/usage"))["stdout_tail"] == "000")
        #expect((await rig.sh("curl -s -m 3 --noproxy '*' http://127.0.0.1:9222/json/version >/dev/null 2>&1; echo rc=$?"))["stdout_tail"] != "rc=0\n")  // CDP não é alcançável
        // ferramentas do work
        #expect((await rig.sh("python3 -c 'import curl_cffi, requests, httpx, lxml, bs4, openpyxl, playwright; print(curl_cffi.__version__)'"))["exit_code"] == 0)
        #expect((await rig.sh("which abx-http curl jq python3"))["exit_code"] == 0)
        // segredo de tarefa: arquivo só leitura, exportado só naquele processo, valor nunca em log nem inspect
        try secrets.write(Data("s3cret-value-777".utf8), named: "API_KEY", computerID: labels.computerID, role: .work)
        let withSecret = await rig.ok("exec", ["shell": "echo \"key=$API_KEY\"", "secret_env": ["API_KEY"]])
        #expect(withSecret["stdout_tail"] == "key=s3cret-value-777\n")
        #expect((await rig.sh("echo \"key=$API_KEY\""))["stdout_tail"] == "key=\n")
        let commandLogText = try String(contentsOf: rig.computer.commands.file, encoding: .utf8)
        #expect(commandLogText.contains("API_KEY") && !commandLogText.contains("s3cret-value-777") == true || commandLogText.contains("key=s3cret") == false)
        // timeout mata o grupo; exec_start/exec_cancel termina em ≤ 6 s (CA-204)
        let timeoutStarted = ContinuousClock.now
        let timedOut = await rig.call("exec", ["shell": "sleep 100", "timeout_s": 2])
        #expect(errorCode(timedOut) == "timeout")
        #expect(timeoutStarted.duration(to: .now) < .seconds(12))
        // o `sleep infinity` do entrypoint do container continua; o `sleep 100` do exec que estourou o prazo não pode sobrar
        let survivors = await rig.sh("cat /proc/[0-9]*/cmdline 2>/dev/null | tr '\\0' '\\n' | grep -c '^100$'; true")
        #expect(survivors["stdout_tail"] == "0\n", "the `sleep 100` survived the timeout: \(survivors.text)")
        let job = try #require(await rig.ok("exec_start", ["shell": "sleep 600"])["job_id"]?.string)
        #expect((await rig.ok("exec_poll", ["job_id": .string(job), "wait_s": 0.2]))["running"] == true)
        let cancelStarted = ContinuousClock.now
        let cancelled = await rig.ok("exec_cancel", ["job_id": .string(job)])
        let cancelElapsed = cancelStarted.duration(to: .now).components
        let cancelSeconds = ((Double(cancelElapsed.seconds) + Double(cancelElapsed.attoseconds) / 1e18) * 10).rounded() / 10
        #expect(cancelled["cancelled"] == true && cancelSeconds <= 6, "cancel took \(cancelSeconds) s")
        #expect([143, 137].contains(cancelled["exit_code"]?.int ?? -1), "exit code \(cancelled["exit_code"]?.text ?? "nil")")
        let commands = ChainedLog.read(rig.computer.commands.file)
        #expect(commands.contains { $0["tool"] == "exec_start" && [143, 137].contains($0["exit"]?.int ?? -1) })
        #expect(try ReqlogIntegrity.verify(file: rig.computer.commands.file) == .ok(lines: commands.count))
        #expect(FileManager.default.fileExists(atPath: rig.computer.run.commandsDirectory.appendingPathComponent("0001.log").path))
        await e.record("exec", ["uid": 10001, "stdin_roundtrip": true, "cancel_seconds": .double(cancelSeconds), "commands_logged": .int(commands.count)])

        // =========================================================== CA-207: symlinks criados pelo agente dentro de /work
        _ = await rig.sh("ln -s /etc/passwd /work/a; ln -s ../../../../.ssh/id_rsa /work/b; ln -s /etc /work/dir")
        #expect(errorCode(await rig.call("browser_upload", ["selector": "#f", "file": "a"])) == "path_rejected")
        #expect(errorCode(await rig.call("browser_upload", ["selector": "#f", "file": "b"])) == "path_rejected")
        #expect(errorCode(await rig.call("browser_screenshot", ["save_as": "a"])) == "path_rejected")
        #expect(errorCode(await rig.call("browser_screenshot", ["save_as": "dir/x.png"])) == "path_rejected")
        #expect(errorCode(await rig.call("result_submit", ["result": ["x": 1], "evidence": ["/x": ["b"]]])) == "path_rejected")
        #expect(errorCode(await rig.call("http_request", ["method": "GET", "url": "http://origin:8080/", "save_body_as": "a"])) == "path_rejected")
        #expect(errorCode(await rig.call("exec", ["argv": ["ls"], "cwd": "dir"])) == "path_rejected")
        #expect(errorCode(await rig.call("browser_cookies", ["action": "export", "file": "dir/jar.json"])) == "path_rejected")
        await e.record("path_rejected", ["symlink_file": "path_rejected", "symlink_dir": "path_rejected", "dotdot": "path_rejected"])

        // =========================================================== diário, evidência validada, timeline
        _ = await rig.ok("journal", ["kind": "PLAN", "text": "find the listings API"])
        _ = await rig.ok("journal", ["kind": "DOING", "text": "reading the XHR of the portal"])
        let found = await rig.ok("journal", ["kind": "FOUND", "text": "listings API is /api/data", "evidence": [api["id"] ?? .null]])
        #expect(found["entry_id"]?.string?.count == 26)
        let fake = ULID.generate()
        try Data("a,b\n1,2\n".utf8).write(to: rig.work.appendingPathComponent("data.csv"))
        let submitted = await rig.ok("result_submit", [
            "result": ["api": "/api/data", "count": 3, "owner": "ACME", "rows": 1],
            "evidence": ["/api": [api["id"] ?? .null], "/owner": [.string(fake)], "/rows": ["/work/data.csv"]],
        ])
        #expect(submitted["file"] == "/work/result.json")
        let summary = try #require(submitted["validation"]?["summary"])
        #expect(summary["verified"] == 2 && summary["cited_missing"] == 1 && summary["not_verified"] == 1)
        let statuses = Dictionary(uniqueKeysWithValues: (submitted["validation"]?["fields"]?.array ?? []).compactMap { f in f["pointer"]?.string.map { ($0, f["status"]?.string ?? "") } })
        #expect(statuses["/api"] == "verified" && statuses["/owner"] == "cited_missing" && statuses["/count"] == "not_verified" && statuses["/rows"] == "verified")
        let verifiedCitation = try #require((submitted["validation"]?["fields"]?.array ?? []).first { $0["pointer"] == "/api" }?["citations"]?.array?.first)
        #expect(verifiedCitation["trust"] == "observed" && verifiedCitation["kind"] == "request")
        let resultFile = try JSON.parse(try Data(contentsOf: rig.work.appendingPathComponent("result.json")))
        #expect(resultFile["count"] == 3)
        await e.record("result_submit", ["summary": summary, "fields": .object(statuses.mapValues { .string($0) })])
        let timeline = await rig.ok("timeline")
        let timelineText = try #require(timeline["content"]?.string)
        for needle in ["PLAN", "DOING", "FOUND", "find the listings API", "CMD", "HTTP", "http://origin:8080/api/data", "NOTE"] { #expect(timelineText.contains(needle), "timeline lacks \(needle)") }

        // =========================================================== ajuda humana sem bloquear > 50 s
        _ = await rig.ok("browser_open", ["url": "http://origin:8080/", "wait_s": 0])
        let helpID = try #require(await rig.ok("help_request", ["kind": "captcha", "reason": "challenge on the portal", "url": "http://origin:8080/"])["request_id"]?.string)
        #expect(await rig.ok("help_request", ["kind": "captcha", "reason": "again", "url": "http://origin:8080/"])["request_id"] == .string(helpID))
        #expect(errorCode(await rig.call("browser_click", ["selector": "#go"])) == "waiting_help")
        #expect((await rig.call("browser_read", ["what": "text"])).isError == false)
        #expect((await rig.call("exec", ["argv": ["true"]])).isError == false)
        let waitStarted = ContinuousClock.now
        #expect(await rig.ok("help_wait", ["request_id": .string(helpID), "wait_s": 1])["status"] == "open")
        #expect(waitStarted.duration(to: .now) < .seconds(5))
        try await computer.resolveHelp(helpID, note: "captcha solved by me")
        let resolved = await rig.ok("help_wait", ["request_id": .string(helpID), "wait_s": 5])
        #expect(resolved["status"] == "resolved" && resolved["human_note"] == "captcha solved by me")
        #expect(resolved["state"]?["url"]?.string?.hasPrefix("http://origin:8080") == true, "state: \(resolved.text)")
        #expect((await rig.call("browser_click", ["selector": "#go", "wait_s": 0])).isError == false)

        // =========================================================== proxy e render (adaptador falso do Zyte, chave só no egress)
        #expect(errorCode(await rig.call("render", ["url": "http://origin:8080/"])) == "not_supported")  // direct não tem render
        #expect(errorCode(await rig.call("proxy_set", ["proxy": "not-allowed"])) == "blocked_by_policy")
        let set = await rig.ok("proxy_set", ["proxy": "zyte-fake"])
        #expect(set["applied"] == true && set["closed_tunnels"]?.int != nil)
        let pstatus = await rig.ok("proxy_status")
        #expect(pstatus["proxy"] == "zyte-fake" && pstatus["render_supported"] == true && pstatus["usage"]?["box"]?["renders"] == 0)
        let rendered = await rig.ok("render", ["url": "http://origin:8080/", "capture": ["/api/"]])
        #expect(rendered["status"] == 200 && rendered["content"]?.string?.contains("rendered listings") == true && rendered["blocked"] == nil)
        let capture = try #require(rendered["captures"]?.array?.first)
        let renderRecords = await rig.ok("reqlog_query", ["source": "render-api"])
        let renderIDs = (renderRecords["records"]?.array ?? []).compactMap { $0["id"]?.string }
        #expect(renderIDs.contains(rendered["request_id"]?.string ?? "?") && renderIDs.contains(capture["id"]?.string ?? "?"))  // CA-206
        #expect(await rig.ok("proxy_status")["usage"]?["box"]?["renders"] == 1)
        #expect((await rig.ok("reqlog_get", ["id": capture["id"] ?? .null]))["body"]?.string?.contains("listings") == true)
        // a chave do modo render só existe no arquivo do egress
        let afterSwitch = await rig.ok("http_request", ["method": "GET", "url": "http://origin:8080/api/data"])
        let afterRecord = try #require(rig.records().first { $0["id"] == afterSwitch["request_id"] })
        #expect(afterRecord["via"] == "zyte-fake" && afterSwitch["via"] == "zyte-fake")
        let reloaded = await rig.ok("browser_reload")
        #expect(reloaded["status"] == 200, "reload: \(reloaded.text)")  // o browser continua funcionando pelo novo caminho
        #expect(await rig.ok("proxy_set", ["proxy": "direct"])["applied"] == true)
        #expect(errorCode(await rig.call("render", ["url": "http://origin:8080/"])) == "not_supported")
        await e.record("proxy_render", ["render_via": "zyte-fake", "render_capture_in_reqlog": true, "usage_renders": 1])

        // =========================================================== segurança: nada de token/chave em env, argv ou inspect
        let secretValues = [token, "fake-render-key-123456", "s3cret-value-777"]
        let computerInspect = try await client.inspectContainer(provisioned.containerID)
        let dump = String(describing: computerInspect)
        for secret in secretValues { #expect(!dump.contains(secret), "computer inspect leaks a secret") }
        #expect(computerInspect.env.allSatisfy { e in secretValues.allSatisfy { !e.contains($0) } })
        #expect(computerInspect.readonlyRootfs && computerInspect.capDrop == ["ALL"], "computer hardening")
        #expect(computerInspect.capAdd.sorted() == ["KILL", "NET_ADMIN", "SETGID", "SETPCAP", "SETUID"])
        #expect(computerInspect.securityOpt.contains("no-new-privileges"))
        #expect(computerInspect.ports.keys.sorted() == ["8790/tcp"], "only the control port is published")
        #expect(computerInspect.ports["8790/tcp"]?.allSatisfy { $0.hostIP == "127.0.0.1" } == true)
        #expect(computerInspect.networks.keys.sorted() == [bridge], "one container on one network")
        let own = try await GarbageCollector(client: client).inventory(labels: ["\(RackyLabel.computer)=\(labels.computerID)"])
        #expect(own.filter { $0.kind == .container }.count == 1, "exactly one container per computer: \(own.map(\.name))")
        #expect(try secrets.permissionViolations(computerID: labels.computerID).isEmpty)
        // a pasta de logs não é montada no work nem no runtime
        let mounts = try await client.run(in: provisioned.containerID, command: ["sh", "-c", "cat /proc/mounts"], user: "agent").stdoutString
        #expect(mounts.contains(" /work "))
        // o agente não alcança a pasta dos segredos, do token nem dos logs
        let probe = try await client.run(in: provisioned.containerID, command: ["sh", "-c", "ls /run/racky /run/racky/logs 2>&1; cat /run/racky/token 2>&1"], user: "agent").stdoutString
        #expect(probe.contains("Permission denied") && !probe.contains(token), "agent must not reach /run/racky: \(probe)")
        // cadeia de hash íntegra mesmo com registros do egress, do browser e do app (ingest)
        let integrity = try ReqlogIntegrity.verify(file: rig.computer.run.requestsFile)
        #expect(integrity.message == "Log integrity: OK", "\(integrity)")
        #expect(try ReqlogIntegrity.verify(file: rig.computer.journal.file).message == "Log integrity: OK")
        await e.record("security", ["inspect_leaks": 0, "work_networks": "internal only", "requests_chain": .string(integrity.message)])
        let maxCall = rig.maxCallSeconds.get()
        #expect(maxCall < 50, "a tool call took \(maxCall) s")
        await e.record("max_tool_call_seconds", .double((maxCall * 10).rounded() / 10))

        // =========================================================== release: coleta e limpeza; o run fica no host
        #expect(await rig.ok("box_release")["released"] == true)
        #expect(errorCode(await rig.call("browser_read", ["what": "text"])) == "box_released")
        let failures = try await provisioner.teardown(provisioned, secrets: secrets)
        #expect(failures.isEmpty, "teardown failures: \(failures.map { $0.0.name })")
        #expect(FileManager.default.fileExists(atPath: rig.work.appendingPathComponent("result.json").path))
        #expect(FileManager.default.fileExists(atPath: rig.computer.run.timelineFile.path))
        #expect(!FileManager.default.fileExists(atPath: try secrets.computerDirectory(labels.computerID).path))
        let remaining = try await GarbageCollector(client: client).inventory(labels: ["\(RackyLabel.computer)=\(labels.computerID)"])
        #expect(remaining.isEmpty, "resources left for the computer: \(remaining.map(\.name))")
        await e.record("release", ["resources_left": .int(remaining.count), "result_json_kept": true, "timeline_md": true, "secrets_dir_removed": true])
    }
}
