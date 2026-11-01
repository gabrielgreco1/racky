import RackyDocker
import Foundation

extension ComputerToolService {
    static let textualTypes = ["text/", "json", "xml", "javascript", "x-www-form-urlencoded", "graphql", "csv"]

    static func isTextual(_ contentType: String?) -> Bool {
        guard let ct = contentType?.lowercased() else { return false }
        return textualTypes.contains { ct.contains($0) }
    }

    /// `http_request` (CS-240): executado no `work` com curl_cffi, saindo pelo egress, e registrado como `observed` porque o
    /// próprio app grava o registro (via ingest do egress, que redige e encadeia).
    func httpRequest(_ args: Args, _ c: ManagedComputer) async throws -> ToolResult {
        let method = (args.string("method") ?? "GET").uppercased()
        guard method.allSatisfy({ $0.isASCII && $0.isLetter }) else { throw ToolError.invalid("method must be an HTTP method token") }
        let url = args.string("url") ?? ""
        guard let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""), let host = parsed.host else {
            throw ToolError.invalid("url must be an absolute http(s) URL")
        }
        let timeout = min(args.double("timeout_s") ?? 30, 46)
        var spec: [String: JSON] = ["method": .string(method), "url": .string(url), "timeout_s": .double(timeout)]
        for key in ["headers", "query", "form", "json", "impersonate", "follow_redirects", "body"] { if let value = args.values[key] { spec[key] = value } }
        if args.bool("cookies_from_browser") == true, await c.display != .http {
            let jar = try await c.backend.runtime("cookies", ["action": "get"], timeout: 15)
            spec["cookies"] = .array((jar["cookies"]?.array ?? []).filter { Self.cookieMatches($0, host: host) })
        }
        let before = await Self.lastRecordID(c)
        let started = Date()
        let result = try await c.backend.httpRun(.object(spec), timeout: .milliseconds(Int((timeout + 4) * 1000)))

        // Falha de transporte (conexão recusada, túnel 403 do egress, timeout do curl).
        if let kind = result["error"]?.string {
            let message = result["message"]?.string ?? kind
            _ = try? await ingestHTTP(c, method: method, url: url, spec: spec, result: nil, error: message, started: started)
            if let blocked = try await blockedRecord(c, after: before, url: url) { throw Self.blockedError(blocked) }
            throw ToolError(kind == "timeout" ? .timeout : .proxyError, "request failed: \(message)")
        }

        let status = result["status"]?.int ?? 0
        let body = Data(base64Encoded: result["body_b64"]?.string ?? "") ?? Data()
        // `http://` bloqueado pelo egress chega como 403 com cabeçalho; o reqlog diz se foi política.
        if status == 403, let blocked = try await blockedRecord(c, after: before, url: url) { throw Self.blockedError(blocked) }

        let requestID = try await ingestHTTP(c, method: method, url: url, spec: spec, result: result, error: nil, started: started)
        let headers = Self.headerMap(result["headers"])
        var out: [String: JSON] = [
            "request_id": .string(requestID), "status": .int(status), "headers": .object(headers.mapValues { .string($0) }),
            "final_url": result["final_url"] ?? .string(url), "via": .string(await c.proxy),
            "truncated": .bool(result["truncated"]?.bool ?? false),
        ]
        let limit = args.int("max_inline_chars") ?? 20000
        let text = String(decoding: body, as: UTF8.self)
        if text.count > limit {
            out["body_inline"] = .string(String(text.prefix(limit)))
            out["truncated"] = true
        } else {
            out["body_inline"] = .string(text)
        }
        if let saveAs = args.string("save_body_as") { out["body_file"] = .string(try PathGuard.write(root: c.run.work, saveAs, body)) }
        return ToolResult(.object(out))
    }

    static func cookieMatches(_ cookie: JSON, host: String) -> Bool {
        guard let domain = cookie["domain"]?.string?.lowercased() else { return false }
        let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        let h = host.lowercased()
        return h == bare || h.hasSuffix("." + bare)
    }

    static func headerMap(_ json: JSON?) -> [String: String] {
        var map: [String: String] = [:]
        for pair in json?.array ?? [] {
            guard let items = pair.array, items.count == 2, let k = items[0].string, let v = items[1].string else { continue }
            map[k] = map[k].map { $0 + ", " + v } ?? v
        }
        return map
    }

    func ingestHTTP(_ c: ManagedComputer, method: String, url: String, spec: [String: JSON], result: JSON?, error: String?, started: Date) async throws -> String {
        var record: [String: JSON] = [
            "id": .string(ULID.generate()), "source": "work:python", "kind": "http", "method": .string(method), "url": .string(url),
            "host": .string(URL(string: url)?.host ?? ""), "duration_ms": .int(Int(Date().timeIntervalSince(started) * 1000)),
        ]
        if let imp = spec["impersonate"]?.string, imp != "none" { record["impersonate"] = .string(imp) }
        if let headers = spec["headers"]?.object { record["request_headers"] = .array(headers.sorted { $0.key < $1.key }.map { [.string($0.key), $0.value] }) }
        var payload: [String: JSON] = [:]
        if let body = spec["body"]?.string { payload["request_body"] = .string(body) }
        else if let json = spec["json"] { payload["request_body"] = .string(json.text) }
        else if let form = spec["form"]?.object {
            payload["request_body"] = .string(form.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.string ?? "")" }.joined(separator: "&"))
        }
        if let error { record["error"] = .string(error) }
        if let result {
            record["status"] = result["status"] ?? .null
            record["final_url"] = result["final_url"] ?? .null
            record["request_headers"] = record["request_headers"] ?? .null
            record["response_headers"] = result["headers"] ?? .null
            let headers = Self.headerMap(result["headers"])
            let contentType = headers.first { $0.key.lowercased() == "content-type" }?.value
            record["content_type"] = contentType.map { .string($0) } ?? .null
            if Self.isTextual(contentType) || contentType == nil, let data = Data(base64Encoded: result["body_b64"]?.string ?? "") {
                payload["response_body"] = .string(String(decoding: data, as: UTF8.self))
            }
        }
        record = record.filter { !$0.value.isNull }
        payload["record"] = .object(record)
        return try await c.backend.ingest(.object(payload))
    }
}
