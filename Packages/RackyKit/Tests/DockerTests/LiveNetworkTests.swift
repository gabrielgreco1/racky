import Foundation
import Testing

@testable import RackyDocker

/// Spike S2 (07 §9, CS-110/111/112): rede `internal`, DNS entre containers, porta publicada só pelo egress.
/// Roda no runtime detectado (aqui, Docker Desktop). OrbStack e Colima não estão instalados nesta máquina.
@Suite("Spike S2 - rede internal e publicação pelo egress", .serialized, .enabled(if: Live.enabled), .tags(.integration), .timeLimit(.minutes(10)))
struct LiveNetworkTests {
    @Test func s2InternalNetworkDNSAndPortPublishedOnlyByEgress() async throws {
        try await Live.with { env in
            let file = "spikes/S2/results.json"
            let e = Evidence.shared
            await e.record(file, "runtime", "\(env.runtime.runtime.kind.rawValue): \(env.runtime.info.operatingSystem), Engine \(env.runtime.version.version), API \(env.runtime.version.apiVersion), \(env.runtime.info.architecture)")
            await e.record(file, "not_tested", "OrbStack e Colima: não instalados nesta máquina (07 CS-105: testados na verificação local quando instalados)")

            let internalName = env.name("internal"), bridgeName = env.name("egress")
            _ = try await env.client.createNetwork(name: internalName, isInternal: true, labels: env.baseLabels)
            _ = try await env.client.createNetwork(name: bridgeName, isInternal: false, labels: env.baseLabels)

            // runtime: só na rede internal, serve HTTP na 9000 (busybox nc), sem publicar nada.
            let runtimeScript = "while true; do nc -l -p 9000 -e /bin/sh -c 'printf \"HTTP/1.1 200 OK\\r\\nContent-Length: 13\\r\\nConnection: close\\r\\n\\r\\nfrom-runtime\\n\"'; done"
            var runtimeSpec = env.spec("runtime", command: ["sh", "-c", runtimeScript], role: .runtime)
            runtimeSpec.network = ContainerNetworkAttachment(network: internalName, aliases: ["runtime"])
            let runtimeID = try await env.run(runtimeSpec)

            // egress: internal + bridge, publica 127.0.0.1:<aleatória> -> 8080; o handler faz de reverse proxy para runtime:9000.
            let egressScript = """
            cat > /tmp/h.sh <<'EOS'
            #!/bin/sh
            read line
            case "$line" in
              *p.cgi*) body=$(wget -T3 -qO- http://runtime:9000/ 2>/dev/null) ;;
              *) body=egress-ok ;;
            esac
            printf "HTTP/1.1 200 OK\\r\\nContent-Length: %s\\r\\nConnection: close\\r\\n\\r\\n%s\\n" $(( ${#body} + 1 )) "$body"
            EOS
            chmod +x /tmp/h.sh
            while true; do nc -l -p 8080 -e /tmp/h.sh; done
            """
            var egressSpec = env.spec("egress", command: ["sh", "-c", egressScript], role: .egress)
            egressSpec.network = ContainerNetworkAttachment(network: internalName, aliases: ["egress"])
            egressSpec.publishedPorts = [PublishedPort(containerPort: "8080/tcp", hostIP: "127.0.0.1", hostPort: "")]
            let egressID = try await env.client.createContainer(egressSpec)
            try await env.client.connectNetwork(bridgeName, container: egressID)
            try await env.client.startContainer(egressID)

            // work: só na rede internal.
            var workSpec = env.spec("work", role: .work)
            workSpec.network = ContainerNetworkAttachment(network: internalName, aliases: ["work"])
            let workID = try await env.run(workSpec)

            try await Task.sleep(for: .milliseconds(1000))  // servidores subirem

            // (1) Nada publicado no runtime e no work; egress publica só em 127.0.0.1.
            let runtimeInspect = try await env.client.inspectContainer(runtimeID)
            let workInspect = try await env.client.inspectContainer(workID)
            let egressInspect = try await env.client.inspectContainer(egressID)
            #expect(runtimeInspect.ports.isEmpty && workInspect.ports.isEmpty)
            let port = try #require(egressInspect.publishedHostPort(for: "8080/tcp"))
            #expect(egressInspect.ports["8080/tcp"]?.allSatisfy { $0.hostIP == "127.0.0.1" } == true)
            await e.record(file, "published_ports", "runtime=\(runtimeInspect.ports.count) work=\(workInspect.ports.count) egress=127.0.0.1:\(port)->8080")
            #expect(egressInspect.networks.keys.contains(internalName) && egressInspect.networks.keys.contains(bridgeName))
            #expect(runtimeInspect.networks.keys.sorted() == [internalName])
            #expect(try await env.client.inspectNetwork(internalName).isInternal)

            // (2) DNS por alias na rede internal: work resolve egress e runtime; fala HTTP com eles.
            let dns = try await env.client.run(in: workID, command: ["sh", "-c", "nslookup egress 2>&1 | tail -3; nslookup runtime 2>&1 | tail -3"])
            #expect(dns.stdoutString.contains("Address") && !dns.stdoutString.contains("NXDOMAIN"), "DNS: \(dns.stdoutString)")
            let toRuntime = try await env.client.run(in: workID, command: ["wget", "-T3", "-qO-", "http://runtime:9000/"])
            let toEgress = try await env.client.run(in: workID, command: ["wget", "-T3", "-qO-", "http://egress:8080/"])
            #expect(toRuntime.stdoutString == "from-runtime\n" && toEgress.stdoutString == "egress-ok\n")
            await e.record(file, "dns_in_internal_network", "work resolve e alcança runtime:9000 e egress:8080 por alias")

            // (3) Sem rota para fora: work e runtime não alcançam a internet, nem por IP.
            let workOut = try await env.client.run(in: workID, command: ["sh", "-c", "wget -T3 -qO- http://1.1.1.1/ >/dev/null 2>&1; echo wget=$?; ping -c1 -W2 8.8.8.8 >/dev/null 2>&1; echo ping=$?; ip route | head -3"])
            #expect(workOut.stdoutString.contains("wget=1") && !workOut.stdoutString.contains("ping=0"), "work: \(workOut.stdoutString)")
            let runtimeOut = try await env.client.run(in: runtimeID, command: ["sh", "-c", "wget -T3 -qO- http://1.1.1.1/ >/dev/null 2>&1; echo wget=$?"])
            #expect(runtimeOut.stdoutString.contains("wget=1") || runtimeOut.stdoutString.contains("wget=4"))
            await e.record(file, "no_route_out_work", workOut.stdoutString.replacingOccurrences(of: "\n", with: " | "))
            await e.record(file, "no_route_out_runtime", runtimeOut.stdoutString.replacingOccurrences(of: "\n", with: " | "))

            // (4) Egress tem saída pela bridge (informativo: depende de internet no host).
            let egressOut = try await env.client.run(in: egressID, command: ["sh", "-c", "wget -T5 -qO- http://example.com >/dev/null 2>&1; echo wget=$?"])
            await e.record(file, "egress_out_via_bridge", egressOut.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines))

            // (5) Do host: a porta publicada do egress responde e o reverse proxy chega no runtime pela rede internal.
            let direct = try await http("http://127.0.0.1:\(port)/")
            let proxied = try await http("http://127.0.0.1:\(port)/p.cgi")
            #expect(direct == "egress-ok\n" && proxied == "from-runtime\n", "host->egress: \(direct) / \(proxied)")
            await e.record(file, "host_to_egress_published_port", "GET / -> egress-ok; GET /p.cgi -> from-runtime (egress -> runtime:9000 pela rede internal)")
            await e.record(file, "result", "PASS no \(env.runtime.runtime.kind.rawValue)")
        }
    }

    private func http(_ url: String) async throws -> String {
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 5)
        request.setValue("close", forHTTPHeaderField: "Connection")
        let (data, _) = try await URLSession.shared.data(for: request)
        return String(decoding: data, as: UTF8.self)
    }
}
