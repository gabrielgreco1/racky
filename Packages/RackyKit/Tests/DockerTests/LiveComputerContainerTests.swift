import RackyProtocol
import Foundation
import Testing

@testable import RackyDocker

/// P24/F26 com o Docker real (`RACKY_TEST_DOCKER=1`): UM container por computador. Navegador, exec como `agent`, proxy com
/// reqlog, isolamento por uid/iptables, encadeamento para upstream HTTP e SOCKS5, viewer VNC. Só toca em `racky.test=1` + `test_run`.
@Suite("P24 - um container por computador (Docker real)", .serialized, .enabled(if: Live.enabled), .tags(.integration), .timeLimit(.minutes(15)))
struct LiveComputerContainerTests {
    static let file = "slice3/P24/live-computer-container.json"

    static var repoRoot: URL {
        var root = URL(fileURLWithPath: #filePath)
        while root.path != "/", !FileManager.default.fileExists(atPath: root.appendingPathComponent("runtime/computer/Dockerfile").path) {
            root.deleteLastPathComponent()
        }
        return root
    }

    static let socks5Server = """
    import asyncio
    async def pipe(r, w):
        try:
            while d := await r.read(65536):
                w.write(d); await w.drain()
        except Exception: pass
        finally: w.close()
    async def handle(r, w):
        try:
            _, n = await r.readexactly(2); m = await r.readexactly(n)
            if 2 not in m: w.write(b"\\x05\\xff"); w.close(); return
            w.write(b"\\x05\\x02")
            _, ul = await r.readexactly(2); u = await r.readexactly(ul); pl = (await r.readexactly(1))[0]; p = await r.readexactly(pl)
            if u != b"sockuser" or p != b"sock-pass-secret": w.write(b"\\x01\\x01"); w.close(); return
            w.write(b"\\x01\\x00")
            _, c, _, a = await r.readexactly(4)
            if a == 3: h = (await r.readexactly((await r.readexactly(1))[0])).decode()
            elif a == 1: h = ".".join(str(b) for b in await r.readexactly(4))
            else: w.close(); return
            port = int.from_bytes(await r.readexactly(2), "big")
            ur, uw = await asyncio.open_connection(h, port)
            w.write(b"\\x05\\x00\\x00\\x01\\x00\\x00\\x00\\x00\\x00\\x00"); await w.drain()
            await asyncio.gather(pipe(r, uw), pipe(ur, w))
        except Exception: w.close()
    async def main():
        s = await asyncio.start_server(handle, "0.0.0.0", 1080)
        async with s: await s.serve_forever()
    asyncio.run(main())
    """

    struct Fixture {
        var env: LiveEnv
        var computerImage: String
        var bridge: String
        var subnet: String
        var secrets: BoxSecretFiles
        var home: URL
        var originID: String
    }

    func makeFixture(_ env: LiveEnv) async throws -> Fixture {
        let images = ImageManager(client: env.client)
        let testLabels = [RackyLabel.test: "1", "racky.test_run": env.runID]
        let computer = try await images.ensure(ImageSource(
            repository: "racky-computer-test-\(env.runID)", contextDirectory: Self.repoRoot.appendingPathComponent("runtime/computer"), extraLabels: testLabels))
        let upstreamDir = FileManager.default.temporaryDirectory.appendingPathComponent("abx-upstream-\(env.runID)", isDirectory: true)
        try FileManager.default.createDirectory(at: upstreamDir, withIntermediateDirectories: true)
        try Data("FROM \(Live.alpine)\nRUN apk add --no-cache tinyproxy busybox-extras\n".utf8).write(to: upstreamDir.appendingPathComponent("Dockerfile"))
        let upstream = try await images.ensure(ImageSource(repository: "racky-upstream-test-\(env.runID)", contextDirectory: upstreamDir, extraLabels: testLabels))
        try? FileManager.default.removeItem(at: upstreamDir)

        // rede de teste (com DNS por nome) onde ficam o "site" e os proxies upstream; os computadores entram nela como a "rede padrão"
        let bridge = env.name("bridge")
        let bridgeID = try await env.client.createNetwork(name: bridge, isInternal: false, labels: env.baseLabels)
        let subnet = try #require(try await env.client.inspectNetwork(bridgeID).subnets.first)

        var origin = env.spec("origin", command: ["sh", "-c", """
            mkdir -p /tmp/www
            printf '<html><head><title>Origin P24</title></head><body>hello from origin %s</body></html>' "$$" > /tmp/www/index.html
            exec httpd -f -vv -p 8080 -h /tmp/www
            """])
        origin.image = upstream.tag
        origin.user = "65534"
        origin.network = ContainerNetworkAttachment(network: bridge, aliases: ["origin"])
        let originID = try await env.run(origin)

        var tiny = env.spec("tinyproxy", command: ["sh", "-c", """
            printf 'Port 8888\\nListen 0.0.0.0\\nTimeout 30\\nBasicAuth upuser up-pass-secret\\nConnectPort 8080\\nPidFile "/tmp/tp.pid"\\nLogLevel Info\\n' > /tmp/tp.conf
            exec tinyproxy -d -c /tmp/tp.conf
            """])
        tiny.image = upstream.tag
        tiny.user = "65534"
        tiny.network = ContainerNetworkAttachment(network: bridge, aliases: ["upstream-http"])
        _ = try await env.run(tiny)

        var socks = env.spec("socks")
        socks.command = nil
        socks.entrypoint = ["python", "-c", Self.socks5Server]
        socks.image = computer.tag  // a imagem do computador só serve de Python para o SOCKS5 de teste
        socks.user = "65534"
        socks.network = ContainerNetworkAttachment(network: bridge, aliases: ["upstream-socks"])
        _ = try await env.run(socks)

        let home = FileManager.default.temporaryDirectory.appendingPathComponent("abx-home-\(env.runID)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try await Task.sleep(for: .milliseconds(1500))
        return Fixture(env: env, computerImage: computer.tag, bridge: bridge, subnet: subnet, secrets: BoxSecretFiles(root: home), home: home, originID: originID)
    }

    func provision(_ fx: Fixture, name: String, config: EgressConfigFile, display: ComputerDisplay = .headless) async throws -> (computer: ProvisionedComputer, labels: ComputerLabels, logs: URL) {
        let labels = ComputerLabels(owner: "test-\(fx.env.runID)", computerID: UUID().uuidString.lowercased(), computerName: name, ephemeral: true, isTest: true)
        let token = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        let run = fx.home.appendingPathComponent("runs/\(name)", isDirectory: true)
        let computer = try await ComputerProvisioner(client: fx.env.client).provision(ComputerProvisionRequest(
            labels: labels, image: fx.computerImage, display: display, token: token, config: config, secrets: fx.secrets, runDirectory: run,
            network: fx.bridge, extraLabels: ["racky.test_run": fx.env.runID]))
        return (computer, labels, run.appendingPathComponent("logs"))
    }

    /// Roda um script como o usuário `agent` (o mesmo caminho do `exec` do app).
    func sh(_ fx: Fixture, _ computer: ProvisionedComputer, _ script: String) async throws -> (out: String, exit: Int) {
        let result = try await fx.env.client.run(in: computer.containerID, command: ["sh", "-c", script], user: ComputerProvisioner.agentUser, timeout: .seconds(40))
        return (result.stdoutString + result.stderrString, result.exitCode)
    }

    @Test func oneContainerPerComputerWithIsolationProxyChainingAndViewer() async throws {
        let e = Evidence.shared
        let file = Self.file
        try await Live.with { env in
            let client = env.client
            let fx = try await makeFixture(env)
            defer { try? FileManager.default.removeItem(at: fx.home) }
            let fixtureContainers = try await env.inventory().filter { $0.kind == .container }.count

            // ---------------------------------------------------------------- A) UM container, hardening, porta única
            let direct = try await provision(fx, name: "direct", config: EgressConfigFile.make(profile: nil, secret: nil, allowCIDRs: [fx.subnet]))
            let mine = try await GarbageCollector(client: client).inventory(labels: ["\(RackyLabel.computer)=\(direct.labels.computerID)"])
            #expect(mine.filter { $0.kind == .container }.count == 1, "um container por computador: \(mine.map(\.name))")
            #expect(mine.filter { $0.kind == .network }.isEmpty, "sem rede por computador (rede padrão)")
            let all = try await env.inventory().filter { $0.kind == .container }
            #expect(all.count == fixtureContainers + 1, "nenhum container extra: \(all.map(\.name))")
            let inspect = try await client.inspectContainer(direct.computer.containerID)
            #expect(inspect.readonlyRootfs && inspect.capDrop == ["ALL"] && inspect.securityOpt.contains("no-new-privileges") && inspect.usesInit)
            #expect(inspect.capAdd.sorted() == ["KILL", "NET_ADMIN", "SETGID", "SETPCAP", "SETUID"])
            #expect(inspect.ports.keys.sorted() == ["8790/tcp"] && inspect.ports["8790/tcp"]?.allSatisfy { $0.hostIP == "127.0.0.1" } == true)
            #expect(inspect.networks.keys.sorted() == [fx.bridge])
            #expect(!String(describing: inspect).contains("up-pass-secret"))
            await e.record(file, "one_container", "1 container (\(inspect.name)), porta única \(direct.computer.adminPort) em 127.0.0.1, sem rede por computador, caps: drop ALL + NET_ADMIN/SETUID/SETGID/SETPCAP/KILL")

            // ---------------------------------------------------------------- B) navegador abre a página local do teste
            let admin = direct.computer.admin
            let open = try await admin.runtimeCall("open", body: Data(#"{"url":"http://origin:8080/index.html","wait_s":0}"#.utf8))
            #expect(open.status == 200, "open: \(String(decoding: open.body, as: UTF8.self))")
            let page = try await admin.runtimeCall("read", body: Data(#"{"what":"text"}"#.utf8))
            #expect(String(decoding: page.body, as: UTF8.self).contains("hello from origin"))
            let procs = try await client.run(in: direct.computer.containerID, command: ["sh", "-c", "ps -eo user,args | grep -E 'chrome|Xvfb|racky_' | grep -v grep | cut -c1-60"]).stdoutString
            #expect(procs.contains("agent ") && procs.contains("egress") && !procs.split(separator: "\n").contains { $0.hasPrefix("root") && $0.contains("chrome") }, "\(procs)")
            await e.record(file, "browser_opens_local_page", "Chromium headed (uid agent) abriu http://origin:8080 e leu o texto; processos: \(procs.replacingOccurrences(of: "\n", with: " | "))")

            // ---------------------------------------------------------------- C) agente: sem privilégio, sem acesso aos segredos do proxy
            let who = try await sh(fx, direct.computer, "id -u; grep -E '^(CapEff|CapPrm|CapAmb):' /proc/self/status; grep NoNewPrivs /proc/self/status")
            #expect(who.out.hasPrefix("10001") && who.out.contains("CapEff:\t0000000000000000") && who.out.contains("NoNewPrivs:\t1"), Comment(rawValue: who.out))
            let secrets = try await sh(fx, direct.computer, "ls /run/racky 2>&1; cat /run/racky/token 2>&1; cat /run/racky/egress.json 2>&1; ls /run/racky/logs 2>&1; for p in /proc/[0-9]*; do cat $p/environ 2>/dev/null | tr '\\0' '\\n' | grep -i token; done; echo end")
            #expect(secrets.out.contains("Permission denied") && !secrets.out.contains("\"via\"") && !secrets.out.contains("requests.jsonl"), Comment(rawValue: secrets.out))
            let envDump = try await sh(fx, direct.computer, "env")
            #expect(envDump.out.contains("HTTP_PROXY=http://127.0.0.1:3128"))
            let su = try await sh(fx, direct.computer, "su egress -c id 2>&1 | head -1; python3 -c 'import os; os.setuid(10003)' 2>&1 | tail -1")
            #expect(su.out.contains("Operation not permitted") || su.out.contains("Authentication") || su.out.contains("failure") || su.out.contains("PermissionError"), Comment(rawValue: su.out))
            await e.record(file, "agent_isolated", "exec roda como uid 10001 sem capacidades e com no-new-privileges; /run/racky (0700 egress) negado: ls/cat do token, config e logs; nada de token no env; setuid(egress) negado")

            // ---------------------------------------------------------------- D) tráfego do agente passa pelo proxy (reqlog) e o resto falha
            let viaProxy = try await sh(fx, direct.computer, "curl -s -m 10 http://origin:8080/index.html")
            #expect(viaProxy.out.contains("hello from origin"), Comment(rawValue: viaProxy.out))
            let originIP = try #require(try await client.inspectContainer(fx.originID).networks[fx.bridge]?.ipAddress)
            let bypass = try await sh(fx, direct.computer, "curl -s -m 5 --noproxy '*' -o /dev/null -w '%{http_code}' http://\(originIP):8080/index.html; echo rc=$?")
            #expect(bypass.out.contains("000") && !bypass.out.contains("rc=0"), "ignorar o proxy precisa falhar: \(bypass.out)")
            let ctl = try await sh(fx, direct.computer, "for u in 127.0.0.1:8790 127.0.0.1:8765 127.0.0.1:5900 169.254.169.254:80 1.1.1.1:80; do curl -s -m 3 --noproxy '*' -o /dev/null -w \"$u %{http_code}\\n\" http://$u/; done")
            #expect(ctl.out.split(separator: "\n").allSatisfy { $0.hasSuffix(" 000") }, "portas de controle, metadata e internet direta fechadas ao agente: \(ctl.out)")
            let dns = try await sh(fx, direct.computer, "getent hosts example.com; echo rc=$?")
            #expect(dns.out.contains("rc=2") || dns.out.contains("rc=1"), "o agente não resolve DNS: \(dns.out)")
            try await Task.sleep(for: .milliseconds(600))
            let records = try await admin.reqlog()
            #expect(records.contains { $0.host == "origin" && $0.status == 200 && $0.via == "direct" && $0.kind == "http" }, "o tráfego do agente aparece no reqlog")
            #expect(records.contains { $0.host == "origin" && ($0.kind == "tunnel" || $0.kind == "http") })
            await e.record(file, "agent_traffic_through_proxy", "curl do agente -> reqlog (host=origin status=200); --noproxy falha (000); controle/metadata/internet direta rejeitados; sem DNS no agente")

            // ---------------------------------------------------------------- E) destino privado bloqueado (sem exceção)
            let strict = try await provision(fx, name: "strict", config: EgressConfigFile.make(profile: nil, secret: nil))
            let blocked = try await sh(fx, strict.computer, "curl -s -m 8 -o /dev/null -w '%{http_code}' http://origin:8080/index.html; for h in 169.254.169.254 127.0.0.1:8790 10.0.0.1 host.docker.internal; do curl -s -m 5 -o /dev/null -w \" $h %{http_code}\" http://$h/; done")
            #expect(blocked.out.hasPrefix("403") && !blocked.out.contains(" 200"), "destinos privados bloqueados pelo proxy: \(blocked.out)")
            try await Task.sleep(for: .milliseconds(500))
            let strictRecords = try await strict.computer.admin.reqlog()
            #expect(strictRecords.contains { $0.blocked && $0.blockedReason?.hasPrefix("private") == true && $0.host == "origin" })
            #expect(strictRecords.contains { $0.blocked && $0.host == "169.254.169.254" })
            await e.record(file, "private_destination_blocked", "origin (IP privado), metadata, loopback do admin e host.docker.internal: 403 pelo proxy com blocked_reason no reqlog")

            // ---------------------------------------------------------------- F) viewer: ticket + WebSocket VNC
            let ticketResponse = try await admin.runtimeCall("vnc_ticket", body: Data("{}".utf8))
            let ticket = try #require((try? JSONSerialization.jsonObject(with: ticketResponse.body) as? [String: Any])?["ticket"] as? String)
            let task = URLSession(configuration: .ephemeral).webSocketTask(with: URL(string: "ws://127.0.0.1:\(direct.computer.adminPort)/vnc?ticket=\(ticket)")!)
            task.resume()
            let banner = try await task.receive()
            task.cancel(with: .goingAway, reason: nil)
            if case .data(let data) = banner { #expect(String(decoding: data.prefix(4), as: UTF8.self) == "RFB ") } else if case .string(let text) = banner { #expect(text.hasPrefix("RFB ")) }
            await e.record(file, "viewer_vnc", "WebSocket /vnc?ticket=... conectou e recebeu o banner RFB do x11vnc (loopback do container)")

            // ---------------------------------------------------------------- G) encadeado: upstream HTTP (Basic) e SOCKS5
            let httpUp = ProxyProfile(name: "test-http", scheme: .http, host: "upstream-http", port: 8888, username: "upuser")
            let chained = try await provision(fx, name: "chained", config: EgressConfigFile.make(profile: httpUp, secret: "up-pass-secret", allowCIDRs: [fx.subnet]))
            let viaUp = try await sh(fx, chained.computer, "curl -s -m 10 http://origin:8080/index.html")
            #expect(viaUp.out.contains("hello from origin"), Comment(rawValue: viaUp.out))
            try await Task.sleep(for: .milliseconds(600))
            let upRecords = try await chained.computer.admin.reqlog()
            #expect(upRecords.contains { $0.via == "test-http" && $0.status == 200 })
            let tinyIP = try await client.inspectContainer(try #require(try await env.inventory().first { $0.name.hasSuffix("tinyproxy") }?.id)).networks[fx.bridge]?.ipAddress
            let originLogs = try await client.collectedLogs(fx.originID)
            #expect((originLogs.stdout + originLogs.stderr).contains(tinyIP ?? "?"), "o origin deveria ter visto o IP do tinyproxy")
            let chainedDump = String(describing: try await client.inspectContainer(chained.computer.containerID))
            let reqlogText = try String(contentsOf: chained.logs.appendingPathComponent("requests.jsonl"), encoding: .utf8)
            #expect(!chainedDump.contains("up-pass-secret") && !reqlogText.contains("up-pass-secret"))
            let leak = try await sh(fx, chained.computer, "env; cat /run/racky/egress.json 2>&1")
            #expect(!leak.out.contains("up-pass-secret"))
            await e.record(file, "chained_http_upstream", "origin viu o IP do tinyproxy (\(tinyIP ?? "?")); reqlog via=test-http; senha do upstream ausente de inspect, env do agente e reqlog")

            let socksProfile = ProxyProfile(name: "test-socks", scheme: .socks5, host: "upstream-socks", port: 1080, username: "sockuser")
            let socksBox = try await provision(fx, name: "socks", config: EgressConfigFile.make(profile: socksProfile, secret: "sock-pass-secret", allowCIDRs: [fx.subnet]))
            let viaSocks = try await sh(fx, socksBox.computer, "curl -s -m 10 http://origin:8080/index.html")
            #expect(viaSocks.out.contains("hello from origin"), Comment(rawValue: viaSocks.out))
            await e.record(file, "chained_socks5_upstream", "encadeamento SOCKS5 com usuário/senha funcionou; via=test-socks")

            // ---------------------------------------------------------------- H) troca de proxy: reescreve a config dentro do container e recarrega
            _ = try await sh(fx, chained.computer, "bash -c '(exec 3<>/dev/tcp/127.0.0.1/3128; printf \"CONNECT origin:8080 HTTP/1.1\\r\\n\\r\\n\" >&3; sleep 20) >/tmp/tun.out 2>&1 &' ; sleep 1; echo started")
            try await Task.sleep(for: .milliseconds(800))
            #expect(try await chained.computer.admin.usage().openTunnels >= 1)
            try await ComputerProvisioner(client: client).rewriteConfig(EgressConfigFile.make(profile: nil, secret: nil, allowCIDRs: [fx.subnet]), proxyCA: nil, computer: chained.computer)
            #expect(try await chained.computer.admin.reloadProxy() >= 1)
            let afterSwitch = try await chained.computer.admin.usage()
            #expect(afterSwitch.via == "direct" && afterSwitch.openTunnels == 0)
            let direct2 = try await sh(fx, chained.computer, "curl -s -m 10 http://origin:8080/index.html")
            #expect(direct2.out.contains("hello from origin"))
            await e.record(file, "proxy_switch", "rewriteConfig por exec + reload: túneis abertos fechados, via=direct, tráfego segue")

            // ---------------------------------------------------------------- I) teardown: nada sobra, nenhum container extra
            for item in [direct, strict, chained, socksBox] {
                let failures = try await ComputerProvisioner(client: client).teardown(item.computer, secrets: fx.secrets)
                #expect(failures.isEmpty)
            }
            let remaining = try await env.inventory().filter { $0.kind == .container }
            #expect(remaining.count == fixtureContainers, "só os containers do cenário restam: \(remaining.map(\.name))")
            await e.record(file, "teardown", "GC por label removeu 1 container + volume de perfil por computador; resta só o cenário de teste (removido pelo Live.with)")
        }
    }

    /// F29: CONNECT a hosts públicos reais. Só com `RACKY_TEST_NETWORK=1` (precisa de internet; não roda por padrão).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RACKY_TEST_NETWORK"] == "1"))
    func connectsToRealPublicHosts() async throws {
        let e = Evidence.shared
        try await Live.with { env in
            let fx = try await makeFixture(env)
            defer { try? FileManager.default.removeItem(at: fx.home) }
            let box = try await provision(fx, name: "net", config: EgressConfigFile.make(profile: nil, secret: nil), display: .http)
            var lines: [String] = []
            for host in ["www.google.com", "data.houstontx.gov", "www.houstontx.gov"] {
                let result = try await sh(fx, box.computer, "curl -s -m 25 -o /dev/null -w '%{http_code}' https://\(host)/")
                let status = result.out.trimmingCharacters(in: .whitespacesAndNewlines)
                if status.hasPrefix("2") || status.hasPrefix("3") || status.hasPrefix("4") {
                    lines.append("\(host)=\(status)")
                    continue
                }
                // Falhou pelo proxy: só é bug do proxy se o próprio Mac alcança o host; rede/ISP que derruba o TCP não é.
                let reachable = await Self.macCanConnect(host: host)
                lines.append("\(host)=FAIL(proxy \(status), mac-reachable=\(reachable))")
                #expect(!reachable, "\(host) responde ao Mac mas o CONNECT pelo proxy falhou: \(status)")
            }
            await e.record(Self.file, "real_public_hosts", lines.joined(separator: "; "))
            _ = try await ComputerProvisioner(client: env.client).teardown(box.computer, secrets: fx.secrets)
        }
    }

    static func macCanConnect(host: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.arguments = ["-s", "-m", "10", "-o", "/dev/null", "https://\(host)/"]
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus == 0) }
            do { try process.run() } catch { continuation.resume(returning: false) }
        }
    }
}
