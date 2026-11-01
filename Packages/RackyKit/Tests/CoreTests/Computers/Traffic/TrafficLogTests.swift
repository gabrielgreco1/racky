import Foundation
import Testing

@testable import RackyCore

/// A aba Computers e a tela Traffic leem o log de requests do run aos poucos: só o que chegou desde a última leitura, nunca uma
/// linha pela metade, e as contas (erros, bloqueadas, proxies e custo) batem com o arquivo.
struct TrafficLogTests {
    private func line(_ id: String, ts: Double, host: String, status: Int? = 200, type: String = "fetch", via: String = "direct",
                      bytes: Int = 100, blocked: Bool = false) -> String {
        var o: [String: Any] = ["id": id, "ts": ts, "method": "GET", "host": host, "url": "https://\(host)/api?q=1", "kind": "http",
                                "type": type, "source": "browser", "via": via, "response_body_bytes": bytes]
        if let status { o["status"] = status }
        if blocked { o["blocked"] = true; o["blocked_reason"] = "noise" }
        return String(decoding: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), as: UTF8.self) + "\n"
    }

    @Test func readsOnlyWhatArrivedAndWaitsForTheRestOfALine() throws {
        let logs = FileManager.default.temporaryDirectory.appendingPathComponent("traffic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: logs) }
        let file = logs.appendingPathComponent("requests.jsonl")
        let now = Date().timeIntervalSince1970
        try (line("a", ts: now - 60, host: "www.booking.com") + line("b", ts: now - 30, host: "www.booking.com", status: 403)).write(to: file, atomically: true, encoding: .utf8)
        let log = TrafficLog(logs: logs)
        #expect(log.poll() == 2)
        #expect(log.entries.map(\.path) == ["/api?q=1", "/api?q=1"])
        // Uma linha pela metade fica para depois.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        let next = line("c", ts: now, host: "proxy.example", via: "zyte", bytes: 2048)
        try handle.write(contentsOf: Data(next.prefix(20).utf8))
        #expect(log.poll() == 0)
        try handle.write(contentsOf: Data(next.dropFirst(20).utf8))
        try handle.write(contentsOf: Data(line("d", ts: now, host: "clients2.google.com", status: nil, blocked: true).utf8))
        try handle.close()
        #expect(log.poll() == 2)
        let stats = TrafficStats.compute(log.entries, now: Date(timeIntervalSince1970: now))
        #expect(stats.total == 4 && stats.errors == 1 && stats.blocked == 1 && stats.recent == 4)
        #expect(stats.hosts.first?.host == "www.booking.com")
        let zyte = try #require(stats.vias.first { $0.name == "zyte" })
        #expect(zyte.requests == 1 && zyte.bytes == 2048)
        #expect(stats.vias.contains { $0.name == "direct" && $0.requests == 2 }, "blocked requests don't count as proxy traffic")
        #expect(TrafficStats.cost(zyte, pricePerRequestMicros: 1500) == 0.0015)
        #expect(TrafficStats.cost(zyte, pricePerRequestMicros: nil) == nil)
    }

    @Test func curlRedactsCookiesAndKeepsTheBody() {
        var e = TrafficEntry(id: "x", at: Date(), method: "POST", host: "www.booking.com", path: "/dml/graphql")
        e.requestHeaders = [["cookie", "secret=1"], ["content-type", "application/json"]]
        let curl = e.curl(body: Data(#"{"q":1}"#.utf8))
        #expect(curl.contains("'cookie: <redacted>'") && !curl.contains("secret=1"))
        #expect(curl.contains(#"--data-raw '{"q":1}'"#) && curl.hasPrefix("curl -X POST 'https://www.booking.com/dml/graphql'"))
    }
}
