import RackyDocker
import RackyPlatform
import RackyProtocol
import RackyStore
import Foundation
import Testing

@testable import RackyCore

// F29 com o Docker real (`RACKY_TEST_DOCKER=1`): `boxes_reserve(proxy: "test-up")` sobe o computador encadeado ao upstream de teste
// (um proxy HTTP CONNECT em Python, na bridge de teste) e o reqlog mostra `via == "test-up"`; sem `proxy` vale o padrão global de
// Settings; `proxy: "direct"` ignora os padrões. O upstream conta os CONNECT que recebeu. Só toca `racky.test=1` + `test_run`.

private let connectUpstreamScript = #"""
import asyncio, sys
async def pipe(r, w):
    try:
        while d := await r.read(65536):
            w.write(d); await w.drain()
    except Exception: pass
    finally: w.close()
async def handle(r, w):
    try:
        head = await r.readuntil(b"\r\n\r\n")
        first = head.split(b"\r\n")[0].decode()
        method, target, _ = first.split(" ", 2)
        if method != "CONNECT":
            # proxy de encaminhamento (URL absoluta): reescreve a linha de pedido e repassa ao site
            import urllib.parse
            u = urllib.parse.urlparse(target)
            ur, uw = await asyncio.open_connection(u.hostname, u.port or 80)
            print("FORWARD " + u.hostname + ":" + str(u.port or 80), flush=True)
            path = (u.path or "/") + ("?" + u.query if u.query else "")
            lines = head.split(b"\r\n")
            lines[0] = (method + " " + path + " HTTP/1.1").encode()
            lines = [l for l in lines if not l.lower().startswith(b"proxy-") and not l.lower().startswith(b"connection:")]
            uw.write(b"\r\n".join(lines[:-2]) + b"\r\nConnection: close\r\n\r\n"); await uw.drain()
            await asyncio.gather(pipe(r, uw), pipe(ur, w))
            return
        host, port = target.rsplit(":", 1)
        ur, uw = await asyncio.open_connection(host, int(port))
        print("CONNECT " + target, flush=True)
        w.write(b"HTTP/1.1 200 Connection established\r\n\r\n"); await w.drain()
        await asyncio.gather(pipe(r, uw), pipe(ur, w))
    except Exception: w.close()
async def main():
    s = await asyncio.start_server(handle, "0.0.0.0", 3128)
    async with s: await s.serve_forever()
asyncio.run(main())
"""#

@Suite("F29 - proxy na reserva (Docker real)", .serialized, .enabled(if: LiveC.enabled), .timeLimit(.minutes(30)))
struct LiveProxyReserveTests {
    @Test func reserveAppliesTheNamedProxyAndTheDefaultsFollowSettings() async throws {
        let runID = LiveComputerTests.shortID()
        let detected = try await RuntimeDetector().detect()
        let client = DockerClient(runtime: detected.runtime, defaultTimeout: .seconds(60))
        let testLabels = [RackyLabel.test: "1", "racky.test_run": runID]
        let labelFilter = ["\(RackyLabel.test)=1", "racky.test_run=\(runID)"]
        let home = URL(fileURLWithPath: "/tmp/abx-f29-\(runID)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let evidence = LiveEvidenceC()

        func cleanup() async {
            let gc = GarbageCollector(client: client)
            if let items = try? await gc.inventory(labels: labelFilter) { _ = await gc.remove(items) }
            if let images = try? await client.listImages(filters: ["label": labelFilter]) { for image in images { try? await client.removeImage(image.id, force: true) } }
            try? FileManager.default.removeItem(at: home)
        }
        do {
            try await scenario(runID: runID, client: client, testLabels: testLabels, home: home, evidence: evidence)
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
        let leftovers = (try? await GarbageCollector(client: client).inventory(labels: labelFilter)) ?? []
        let images = (try? await client.listImages(filters: ["label": labelFilter])) ?? []
        #expect(leftovers.isEmpty && images.isEmpty, "cleanup left \(leftovers.count) resources and \(images.count) images")
        await evidence.record("cleanup", ["leftover_resources": .int(leftovers.count), "leftover_images": .int(images.count)])
        await evidence.flush(to: "fixes/proxy-on-reserve/live-proxy-reserve.json")
    }

    func scenario(runID: String, client: DockerClient, testLabels: [String: String], home: URL, evidence: LiveEvidenceC) async throws {
        let runtimeRoot = LiveC.repoRoot.appendingPathComponent("runtime", isDirectory: true)
        let bridge = "abx-t-\(runID)-bridge"
        let bridgeID = try await client.createNetwork(name: bridge, isInternal: false, labels: testLabels)
        let subnet = try #require(try await client.inspectNetwork(bridgeID).subnets.first)

        // ---- store, proxy salvo e o resolvedor do app (o mesmo de ComputersWiring)
        let store = try await RackyStore.open(paths: StorePaths(root: home.appendingPathComponent("store", isDirectory: true)))
        let vault = SecretVault(store: store, keyring: VaultKeyring(backend: InMemoryMasterKeyBackend()))
        let proxyService = ProxyService(store: store, vault: vault)
        let saved = try await proxyService.save(ProxyProfile(name: "test-up", scheme: .http, host: "upstream", port: 3128))
        var config = AppComputerProvisioning.Config(runtimeRoot: runtimeRoot, secretsRoot: home, owner: "test-\(runID)")
        config.isTest = true
        config.repositorySuffix = "-test-\(runID)"
        config.extraLabels = testLabels
        config.network = bridge
        config.allowCIDRs = [subnet]
        config.resolver = { name, _ in
            guard let profile = try await store.proxy(named: name) else { throw ProxyServiceError.unknownProxy(name) }
            return try await proxyService.egressConfig(for: profile.id, allowCIDRs: [subnet])
        }
        let provisioning = AppComputerProvisioning(config: config)
        let tag = try await provisioning.ensureImages()  // primeira vez: constrói a imagem do computador (marcada como de teste)

        // ---- o "site" e o upstream de teste na bridge de teste (a imagem do computador só serve de Python)
        func start(_ name: String, alias: String, script: String) async throws -> String {
            var spec = ContainerSpec(name: "abx-t-\(runID)-\(name)", image: tag)
            spec.entrypoint = ["python"]
            spec.command = ["-c", script]
            spec.labels = testLabels.merging([RackyLabel.owner: "test-\(runID)", RackyLabel.computer: "c-\(name)-\(runID)", RackyLabel.ephemeral: "true"]) { $1 }
            spec.user = "65534"
            spec.tmpfs = ["/tmp": "rw,nosuid,size=16m"]
            spec.resources = ContainerResources(memoryBytes: 128 << 20, cpus: 0.5, pidsLimit: 128)
            spec.network = ContainerNetworkAttachment(network: bridge, aliases: [alias])
            let id = try await client.createContainer(spec)
            try await client.startContainer(id)
            return id
        }
        _ = try await start("origin", alias: "origin", script: liveOriginScript)
        let upstreamID = try await start("upstream", alias: "upstream", script: connectUpstreamScript)
        try await Task.sleep(for: .milliseconds(1500))

        // ---- scheduler com o diretório de proxies do Store (o app usa o mesmo)
        let hub = ComputerHub()
        let scheduler = ComputerScheduler(
            hub: hub, provisioning: provisioning, capacity: { await provisioning.vmCapacity() },
            runDirectory: { p, n in home.appendingPathComponent("runs/\(p.prefix(8))/\(n)", isDirectory: true) }, store: store, fixedEstimates: true,
            proxies: StoreProxyDirectory(store: store))
        await scheduler.attach()
        let service = ComputerToolService(hub: hub, orchestrator: scheduler)
        let parent = "parent-f29-\(runID)"
        let bundle = try OrchestrationInjectionBuilder.make(
            parentID: parent, helperPath: "/usr/local/bin/racky", options: { var o = OrchestrationInjectionBuilder.Options(); o.workerSlots = 2; return o }(),
            parentCapability: "cap-parent", workerCapability: { "cap-w\($0)" })
        await OrchestrationInjectionBuilder.register(bundle, hub: hub, scheduler: scheduler)

        func call(_ tool: String, _ args: JSON = [:], as id: String) async -> JSON {
            let outcome = await service.call(tool, arguments: args, child: id)
            return (try? JSON.parse(outcome.content.first?["text"]?.string ?? "null")) ?? .null
        }

        /// Reserva (com ou sem `proxy`), o worker reivindica, busca a página e devolve o `via` do reqlog do computador.
        func via(of name: String, proxy: String?) async throws -> String? {
            var args: [String: JSON] = ["names": [.string(name)]]
            if let proxy { args["proxy"] = .string(proxy) }
            let reserved = await call("boxes_reserve", .object(args), as: parent)
            let box = try #require(reserved["boxes"]?.array?.first)
            #expect(box["state"]?.string != "unavailable", Comment(rawValue: "\(reserved)"))
            let child = try #require(box["child_id"]?.string)
            var ready = false
            for _ in 0..<600 where !ready {
                if let c = await hub.computer(named: name) { let state = await c.state; ready = state == .ready || state == .inUse }
                if !ready { try await Task.sleep(for: .milliseconds(500)) }
            }
            #expect(ready, "computer \(name) did not become ready")
            let claim = await call("box_claim", ["name": .string(name), "wait_s": 5], as: child)
            #expect(claim["proxy"]?.string != nil || claim["state"]?.string == "in_use", Comment(rawValue: "\(claim)"))
            let got = await call("http_request", ["method": "GET", "url": "http://origin:8080/", "timeout_s": 20], as: child)
            #expect(got["status"] == 200, Comment(rawValue: "\(got)"))
            try await Task.sleep(for: .milliseconds(600))
            let log = await call("reqlog_query", ["host": "origin"], as: child)
            let record = log["records"]?.array?.last
            _ = await call("boxes_release", ["names": [.string(name)]], as: parent)
            return record?["via"]?.string
        }

        // 1) `proxy` explícito
        let explicit = try await via(of: "via-explicit", proxy: "test-up")
        #expect(explicit == "test-up")
        // 2) sem `proxy` e sem padrão global: direct
        let none = try await via(of: "via-none", proxy: nil)
        #expect(none == "direct")
        // 3) sem `proxy`, com o padrão global de Settings
        try await store.setDefaultProxy(id: saved.id)
        let global = try await via(of: "via-global", proxy: nil)
        #expect(global == "test-up")
        // 4) `proxy: "direct"` ignora o padrão global
        let forcedDirect = try await via(of: "via-direct", proxy: "direct")
        #expect(forcedDirect == "direct")
        // 5) nome desconhecido
        let unknown = await call("boxes_reserve", ["names": ["via-unknown"], "proxy": "nope"], as: parent)
        #expect(unknown["boxes"]?.array?.first?["reason"] == "unknown_proxy")

        // o upstream viu exatamente os dois computadores que usaram o proxy
        let upstreamLogs = try await client.collectedLogs(upstreamID)
        let connects = upstreamLogs.stdout.split(separator: "\n").filter { $0.contains("origin:8080") }.count
        #expect(connects == 2, "o upstream deveria ter recebido 2 pedidos para origin:8080, recebeu \(connects)")
        await evidence.record("via_explicit", .string(explicit ?? "nil"))
        await evidence.record("via_none", .string(none ?? "nil"))
        await evidence.record("via_global_default", .string(global ?? "nil"))
        await evidence.record("via_forced_direct", .string(forcedDirect ?? "nil"))
        await evidence.record("upstream_connects", .int(connects))
        try await store.close()
    }
}
