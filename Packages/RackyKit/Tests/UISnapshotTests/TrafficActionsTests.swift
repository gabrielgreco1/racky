import Foundation
import RackyCore
import Testing

@testable import RackyUI

/// Aba Computers e tela Traffic: as ações leem o log do run (mesmo de um computador que já terminou), filtram, escolhem a request e
/// copiam o cURL sem o cookie.
@MainActor struct TrafficActionsTests {
    @Test func pickFilterSelectAndCopyCurl() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("traffic-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let run = home.appendingPathComponent("runs/demo/wiki-porto", isDirectory: true)
        let logs = run.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let now = Date().timeIntervalSince1970
        let lines = [
            #"{"id":"a","ts":\#(now - 20),"method":"GET","host":"pt.wikipedia.org","url":"https://pt.wikipedia.org/wiki/Porto","kind":"http","type":"document","source":"browser","via":"direct","status":200,"response_body_bytes":5000}"#,
            #"{"id":"b","ts":\#(now - 10),"method":"POST","host":"pt.wikipedia.org","url":"https://pt.wikipedia.org/api","kind":"http","type":"fetch","source":"browser","via":"zyte","status":500,"request_headers":[["cookie","s=1"],["content-type","application/json"]]}"#,
            #"{"id":"c","ts":\#(now - 5),"method":"CONNECT","host":"clients2.google.com","url":"clients2.google.com:443","kind":"tunnel","source":"egress","via":"direct","blocked":true,"blocked_reason":"noise"}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: logs.appendingPathComponent("requests.jsonl"), atomically: true, encoding: .utf8)
        let env = AppEnvironment(environment: ["RACKY_SKIP_ONBOARDING": "1", "RACKY_HOME": home.path, "RACKY_TEST_HEADLESS": "1"])
        let traffic = env.traffic
        traffic.sessionRuns = { ["wiki-porto": run] }
        traffic.proxySource = { ["zyte": .init(host: "api.zyte.com", pricePerRequestMicros: 2_000)] }
        var copied = ""
        traffic.copy = { copied = $0 }

        _ = try await env.registry.perform(.rightPanelComputersPick, .select("wiki-porto|errors"))
        #expect(traffic.shownComputer == "wiki-porto" && traffic.panelFilter == "errors")
        #expect(traffic.stats["wiki-porto"]?.total == 3 && traffic.stats["wiki-porto"]?.errors == 1 && traffic.stats["wiki-porto"]?.blocked == 1)
        #expect(traffic.panelEntries("wiki-porto").map(\.id) == ["c", "b"], "errors filter keeps failures and blocked, newest first")
        let zyte = try #require(traffic.stats["wiki-porto"]?.vias.first { $0.name == "zyte" })
        #expect(traffic.cost(zyte) == 0.002)

        _ = try await env.registry.perform(.trafficSet, .select("wiki-porto|filter=api"))
        #expect(traffic.visibleEntries("wiki-porto").map(\.id) == ["b"])
        _ = try await env.registry.perform(.trafficSet, .select("wiki-porto|filter=all"))
        _ = try await env.registry.perform(.trafficSet, .select("wiki-porto|query=porto"))
        #expect(traffic.visibleEntries("wiki-porto").map(\.id) == ["a"])
        _ = try await env.registry.perform(.trafficSet, .select("wiki-porto|select=b"))
        _ = try await env.registry.perform(.trafficSet, .select("wiki-porto|side=request"))
        #expect(traffic.state("wiki-porto").selected == "b" && traffic.state("wiki-porto").detailSide == "request")
        await #expect(throws: (any Error).self) { try await env.registry.perform(.trafficSet, .select("wiki-porto|nope=1")) }

        _ = try await env.registry.perform(.trafficCopyCurl, .select("wiki-porto|b"))
        #expect(copied.hasPrefix("curl -X POST 'https://pt.wikipedia.org/api'") && copied.contains("<redacted>") && !copied.contains("s=1"))
    }
}
