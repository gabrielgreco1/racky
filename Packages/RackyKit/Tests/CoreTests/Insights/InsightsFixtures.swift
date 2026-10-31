import Foundation

@testable import RackyCore

/// Fixtures 100% sintéticas de transcripts e rollouts (nenhum dado real do usuário).
enum InsightsFixtures {
    static func iso(_ date: Date) -> String {
        let c = Calendar(identifier: .gregorian)
        var cal = c
        cal.timeZone = TimeZone(identifier: "UTC")!
        let p = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let ms = Int((date.timeIntervalSince1970 - floor(date.timeIntervalSince1970)) * 1000)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", p.year!, p.month!, p.day!, p.hour!, p.minute!, p.second!, ms)
    }

    static func claudeLine(
        id: String, request: String = "req_1", session: String = "sess-a", model: String = "claude-opus-4-5", at date: Date,
        input: Int = 10, output: Int = 20, cacheRead: Int = 0, cache5m: Int = 0, cache1h: Int = 0, sidechain: Bool = false,
        cwd: String = "/work/alpha", breakdown: Bool = true
    ) -> String {
        var usage = "\"input_tokens\":\(input),\"output_tokens\":\(output),\"cache_read_input_tokens\":\(cacheRead),\"cache_creation_input_tokens\":\(cache5m + cache1h)"
        if breakdown { usage += ",\"cache_creation\":{\"ephemeral_5m_input_tokens\":\(cache5m),\"ephemeral_1h_input_tokens\":\(cache1h)}" }
        return "{\"type\":\"assistant\",\"uuid\":\"u-\(id)\",\"sessionId\":\"\(session)\",\"requestId\":\"\(request)\",\"isSidechain\":\(sidechain),"
            + "\"cwd\":\"\(cwd)\",\"timestamp\":\"\(iso(date))\",\"message\":{\"id\":\"\(id)\",\"model\":\"\(model)\",\"role\":\"assistant\","
            + "\"content\":[{\"type\":\"text\",\"text\":\"SYNTHETIC-CONTENT-NEVER-LOGGED\"}],\"usage\":{\(usage)}}}"
    }

    static let userLine = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"hello\"},\"timestamp\":\"2026-10-17T08:00:00.000Z\"}"
    static let corruptLines = ["{\"type\":\"assistant\",\"message\":{\"usage\":", "not json at all \"usage\" \"assistant\"", "{}", ""]

    static func codexMeta(id: String, cwd: String = "/work/beta", at date: Date) -> String {
        "{\"timestamp\":\"\(iso(date))\",\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\",\"cwd\":\"\(cwd)\"}}"
    }

    static func codexTurn(model: String, at date: Date) -> String {
        "{\"timestamp\":\"\(iso(date))\",\"type\":\"turn_context\",\"payload\":{\"model\":\"\(model)\"}}"
    }

    static func codexTokens(
        input: Int, cached: Int, output: Int, at date: Date, primary: (Double, Int, Double)? = nil, secondary: (Double, Int, Double)? = nil,
        plan: String? = nil
    ) -> String {
        func win(_ w: (Double, Int, Double)?) -> String {
            guard let w else { return "null" }
            return "{\"used_percent\":\(w.0),\"window_minutes\":\(w.1),\"resets_at\":\(Int(w.2))}"
        }
        let planJSON = plan.map { "\"\($0)\"" } ?? "null"
        return "{\"timestamp\":\"\(iso(date))\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":"
            + "{\"input_tokens\":\(input),\"cached_input_tokens\":\(cached),\"output_tokens\":\(output),\"reasoning_output_tokens\":0,\"total_tokens\":\(input + output)}},"
            + "\"rate_limits\":{\"primary\":\(win(primary)),\"secondary\":\(win(secondary)),\"plan_type\":\(planJSON)}}}"
    }

    static func tempDirectory(_ name: String = "insights") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("racky-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func write(_ lines: [String], to url: URL, append: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        if append, let h = try? FileHandle(forWritingTo: url) {
            try h.seekToEnd()
            try h.write(contentsOf: data)
            try h.close()
        } else {
            try data.write(to: url)
        }
    }

    /// Instante fixo (UTC 2026-10-17 12:00) para os testes de janela.
    static let now = Date(timeIntervalSince1970: 1_792_238_400)

    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
}
