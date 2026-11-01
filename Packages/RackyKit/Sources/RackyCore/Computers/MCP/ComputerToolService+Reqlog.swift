import Foundation

/// Reqlog lido do host (`logs/requests.jsonl`): só o egress escreve ali, o agente não alcança (CS-149).
extension ComputerToolService {
    static func records(_ c: ManagedComputer) -> [[String: JSON]] { ChainedLog.read(c.run.requestsFile) }

    /// Corpo salvo (`bodies/<id>.<kind>.txt`), confinado a `logs/bodies/`.
    static func bodyData(_ c: ManagedComputer, _ record: [String: JSON], kind: String) -> Data? {
        guard let relative = record["\(kind)_body_file"]?.string, relative.hasPrefix("bodies/"), !relative.contains("..") else { return nil }
        let file = c.run.logs.appendingPathComponent(relative)
        guard file.standardizedFileURL.path.hasPrefix(c.run.logs.appendingPathComponent("bodies").standardizedFileURL.path + "/") else { return nil }
        return try? Data(contentsOf: file)
    }

    static func matchesStatus(_ record: [String: JSON], _ wanted: String) -> Bool {
        guard let status = record["status"]?.int else { return false }
        let w = wanted.lowercased()
        if w.count == 3, w.hasSuffix("xx"), let digit = w.first?.wholeNumberValue { return status / 100 == digit }
        return String(status) == w
    }

    static func isXHR(_ record: [String: JSON]) -> Bool {
        if record["kind"]?.string == "tunnel" { return false }
        let type = (record["content_type"]?.string ?? "").lowercased()
        return type.contains("json") || type.contains("xml") || (record["method"]?.string ?? "GET").uppercased() != "GET"
    }

    static func isError(_ record: [String: JSON]) -> Bool {
        if record["blocked"]?.bool == true || record["error"]?.string?.isEmpty == false { return true }
        if record["kind"]?.string == "tunnel" { return false }
        guard let status = record["status"]?.int else { return true }
        return status >= 400
    }

    func reqlogQuery(_ args: Args, _ c: ManagedComputer) throws -> ToolResult {
        var all = Self.records(c)
        if let since = args.string("since_id") {
            if let index = all.firstIndex(where: { $0["id"]?.string == since }) { all = Array(all[(index + 1)...]) }
            else { all = all.filter { ($0["id"]?.string ?? "") > since } }
        }
        let grep = args.string("grep")?.lowercased()
        let host = args.string("host")?.lowercased()
        let filtered = all.filter { record in
            if args.bool("xhr") == true, !Self.isXHR(record) { return false }
            if args.bool("errors") == true, !Self.isError(record) { return false }
            if let source = args.string("source") {
                let s = record["source"]?.string ?? ""
                if !(s == source || (source != "egress" && s.hasPrefix(source))) { return false }
            }
            if let host {
                let h = (record["host"]?.string ?? "").lowercased()
                if !(h == host || h.hasSuffix("." + host)) { return false }
            }
            if let method = args.string("method"), (record["method"]?.string ?? "").uppercased() != method.uppercased() { return false }
            if let status = args.string("status"), !Self.matchesStatus(record, status) { return false }
            if let grep {
                var haystack = [record["url"]?.string, record["host"]?.string, record["error"]?.string].compactMap { $0 }.joined(separator: " ").lowercased()
                for kind in ["request", "response"] {
                    if let data = Self.bodyData(c, record, kind: kind) { haystack += " " + String(decoding: data.prefix(262_144), as: UTF8.self).lowercased() }
                }
                if !haystack.contains(grep) { return false }
            }
            return true
        }
        let last = args.int("last") ?? 30
        let rows = filtered.suffix(last).map { record -> JSON in
            var row: [String: JSON] = [
                "id": record["id"] ?? .null, "ts": record["ts"] ?? .null, "status": record["status"] ?? .null, "method": record["method"] ?? .null,
                "source": record["source"] ?? .null, "via": record["via"] ?? .null, "url": record["url"] ?? .null, "trust": record["trust"] ?? "observed",
            ]
            if let body = Self.bodyData(c, record, kind: "request") { row["req_body_snippet"] = .string(String(String(decoding: body, as: UTF8.self).prefix(200))) }
            if let error = record["error"] { row["error"] = error }
            if record["blocked"]?.bool == true { row["blocked"] = record["blocked_reason"] ?? true }
            if record["unconfirmed"]?.bool == true { row["unconfirmed"] = true }
            return .object(row)
        }
        return ToolResult(["records": .array(Array(rows)), "total": .int(filtered.count)])
    }

    private func record(_ id: String, _ c: ManagedComputer) throws -> [String: JSON] {
        guard let record = Self.records(c).first(where: { $0["id"]?.string == id }) else { throw ToolError(.notFound, "no request \(id) in this computer's log") }
        return record
    }

    func reqlogGet(_ args: Args, _ c: ManagedComputer) throws -> ToolResult {
        var record = try record(args.string("id") ?? "", c)
        record["prev_sha256"] = nil
        var out: [String: JSON] = [:]
        if let requestBody = Self.bodyData(c, record, kind: "request") { record["request_body"] = .string(String(String(decoding: requestBody, as: UTF8.self).prefix(20000))) }
        if args.bool("include_body") != false, let data = Self.bodyData(c, record, kind: "response") {
            let text = String(decoding: data, as: UTF8.self)
            let offset = min(args.int("body_offset") ?? 0, text.count)
            let max = args.int("body_max") ?? 20000
            let start = text.index(text.startIndex, offsetBy: offset)
            let end = text.index(start, offsetBy: min(max, text.distance(from: start, to: text.endIndex)))
            out["body"] = .string(String(text[start..<end]))
            let truncated = end < text.endIndex
            out["body_truncated"] = .bool(truncated)
            if truncated { out["next_offset"] = .int(offset + max) }
        } else {
            out["body_truncated"] = false
        }
        out["record"] = .object(record)
        return ToolResult(.object(out))
    }

    private static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    func reqlogAsCurl(_ args: Args, _ c: ManagedComputer) throws -> ToolResult {
        let record = try record(args.string("id") ?? "", c)
        let method = (record["method"]?.string ?? "GET").uppercased()
        guard let url = record["url"]?.string, method != "CONNECT" else { throw ToolError.invalid("this record is a tunnel; it has no replayable request") }
        let impersonate = args.bool("impersonate") == true
        // Cabeçalhos redigidos (cookies, Authorization...) ficam de fora: quem replica injeta os seus.
        var headers: [(String, String)] = []
        for pair in record["request_headers"]?.array ?? [] {
            guard let p = pair.array, p.count == 2, let k = p[0].string, let v = p[1].string, v != "[redacted]", !k.hasPrefix(":") else { continue }
            if ["host", "content-length", "connection", "accept-encoding"].contains(k.lowercased()) { continue }
            headers.append((k, v))
        }
        let body = Self.bodyData(c, record, kind: "request").map { String(decoding: $0, as: UTF8.self) }
        var curl = (impersonate ? "# replay with curl-impersonate (e.g. curl_chrome) to keep the TLS fingerprint\n" : "") + "curl -sS -X \(method) \(Self.shellQuote(url))"
        for (k, v) in headers { curl += " \\\n  -H \(Self.shellQuote("\(k): \(v)"))" }
        if let body, !body.isEmpty { curl += " \\\n  --data-raw \(Self.shellQuote(body))" }
        func py(_ s: String) -> String { JSON.string(s).text }
        var python = "from curl_cffi import requests\n\nresponse = requests.request(\(py(method)), \(py(url))"
        if !headers.isEmpty { python += ",\n    headers={" + headers.map { "\(py($0.0)): \(py($0.1))" }.joined(separator: ", ") + "}" }
        if let body, !body.isEmpty { python += ",\n    data=\(py(body))" }
        if impersonate { python += ",\n    impersonate=\"chrome\"" }
        python += ")\nprint(response.status_code, response.text[:500])\n"
        return ToolResult(["curl": .string(curl), "python_curl_cffi": .string(python)])
    }
}
