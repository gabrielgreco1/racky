import RackyDocker
import Foundation

extension ComputerToolService {
    // MARK: G. Proxy e render

    func proxySet(_ args: Args, _ c: ManagedComputer) async throws -> ToolResult {
        let proxy = args.string("proxy") ?? "direct"
        guard proxy == "direct" || c.proxiesAllowed.contains(proxy) else {
            throw ToolError(.blockedByPolicy, "proxy \(proxy) is not allowed for this computer", details: ["allowed": .array((["direct"] + c.proxiesAllowed).map { .string($0) })])
        }
        let country = args.string("country")
        let closed: Int
        do {
            closed = try await c.backend.switchProxy(to: proxy, country: country)
        } catch let error as ToolError {
            throw error
        } catch let error as DockerError {
            throw Self.map(error)
        } catch {
            throw ToolError(.proxyError, "could not apply the proxy: \(error.localizedDescription)")
        }
        await c.setProxy(proxy, country: country)
        let text = "proxy -> \(proxy)\(country.map { " (\($0))" } ?? ""): closed \(closed) open tunnels"
        _ = try? await c.appendJournal(kind: "NOTE", text: text, evidence: [], system: true)
        await c.logEvent("proxy", text)
        var out: [String: JSON] = ["proxy": .string(proxy), "applied": true, "closed_tunnels": .int(closed)]
        if let country { out["country"] = .string(country) }
        return ToolResult(.object(out))
    }

    func proxyStatus(_ c: ManagedComputer) async throws -> ToolResult {
        let info = try? await c.backend.proxyInfo()
        let usage = (try? await c.backend.usage()) ?? Self.emptyUsage
        var out: [String: JSON] = [
            "proxy": .string(await c.proxy), "proxies_allowed": .array(c.proxiesAllowed.map { .string($0) }),
            "render_supported": .bool(info?["render_supported"]?.bool ?? false),
            // O egress de um computador só vive o tempo do run, então `today` coincide com o uso do computador até a T4-01 agregar.
            "usage": ["box": usage, "today": usage],
        ]
        if let country = await c.country { out["country"] = .string(country) }
        return ToolResult(.object(out))
    }

    func render(_ args: Args, _ c: ManagedComputer) async throws -> ToolResult {
        do {
            var reply = try await c.backend.render(args.json)
            guard case .object(var object) = reply else { throw ToolError(.proxyError, "render returned no object") }
            if object["error"]?.string != nil { throw RuntimeErrorMapper.map(status: 502, body: reply) }
            object["usage"] = (try? await c.backend.usage()) ?? Self.emptyUsage
            reply = .object(object)
            return ToolResult(reply)
        } catch let error as DockerError {
            throw Self.map(error)
        }
    }

    // MARK: H. Diário, timeline, resultado

    func journal(_ args: Args, _ c: ManagedComputer) async throws -> ToolResult {
        let entry = try await c.appendJournal(kind: args.string("kind") ?? "NOTE", text: args.string("text") ?? "", evidence: args.strings("evidence") ?? [])
        return ToolResult(["entry_id": entry["id"] ?? .null])
    }

    struct TimelineRow {
        var ts: Double
        var kind: String
        var text: String
    }

    static func timelineRows(_ c: ManagedComputer, include: Set<String>) -> [TimelineRow] {
        var rows: [TimelineRow] = []
        func ts(_ e: [String: JSON]) -> Double { e["ts"]?.double ?? 0 }
        if include.contains("journal") {
            for e in ChainedLog.read(c.journal.file) {
                let evidence = (e["evidence"]?.array ?? []).compactMap(\.string)
                rows.append(TimelineRow(ts: ts(e), kind: e["kind"]?.string ?? "NOTE", text: (e["text"]?.string ?? "") + (evidence.isEmpty ? "" : "  [evidence: \(evidence.joined(separator: ", "))]")))
            }
            for e in ChainedLog.read(c.events.file) { rows.append(TimelineRow(ts: ts(e), kind: "EVENT", text: "\(e["kind"]?.string ?? ""): \(e["text"]?.string ?? "")")) }
        }
        if include.contains("commands") {
            for e in ChainedLog.read(c.commands.file) {
                let what = e["argv"]?.array?.compactMap(\.string).joined(separator: " ") ?? e["shell"]?.string ?? ""
                let exit = e["exit"]?.int.map(String.init) ?? (e["timed_out"]?.bool == true ? "timeout" : "?")
                rows.append(TimelineRow(ts: ts(e), kind: "CMD", text: "#\(e["command"]?.int ?? 0) exit=\(exit) \(e["ms"]?.int ?? 0)ms  \(String(what.prefix(300)))"))
            }
        }
        if include.contains("requests") {
            for e in ChainedLog.read(c.run.requestsFile) {
                let status = e["status"]?.int.map(String.init) ?? "ERR"
                var text = "\(status) \(e["method"]?.string ?? "") \(e["source"]?.string ?? "") \(e["via"]?.string ?? "") \(String((e["url"]?.string ?? "").prefix(180)))"
                if let error = e["error"]?.string { text += " error=\(error)" }
                if let blocked = e["blocked_reason"]?.string { text += " BLOCKED=\(blocked)" }
                rows.append(TimelineRow(ts: ts(e), kind: "HTTP", text: text))
            }
        }
        if include.contains("help") {
            for e in ChainedLog.read(c.helpLog.file) {
                rows.append(TimelineRow(ts: ts(e), kind: "HELP", text: "\(e["event"]?.string ?? "") \(e["kind"]?.string ?? "") \(e["reason"]?.string ?? e["note"]?.string ?? "")".trimmingCharacters(in: .whitespaces)))
            }
        }
        if include.contains("messages") {
            for e in ChainedLog.read(c.messages.file) { rows.append(TimelineRow(ts: ts(e), kind: "MSG", text: e["text"]?.string ?? "")) }
        }
        if include.contains("transcript") {
            for e in ChainedLog.read(c.run.transcript.appendingPathComponent("agent.jsonl")) {
                rows.append(TimelineRow(ts: ts(e), kind: (e["type"]?.string ?? "agent").uppercased(), text: String((e["text"]?.string ?? "").prefix(600))))
            }
        }
        return rows.sorted { $0.ts < $1.ts }
    }

    static func timelineTime(_ ts: Double) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date(timeIntervalSince1970: ts))
    }

    static let allSections: Set<String> = ["journal", "commands", "requests", "help", "messages", "transcript"]

    func timeline(_ args: Args, _ c: ManagedComputer) async throws -> ToolResult {
        let include = Set(args.strings("include") ?? Array(Self.allSections))
        var rows = Self.timelineRows(c, include: include)
        if let since = args.string("since") {
            var cutoff: Double?
            if ResultValidator.looksLikeRequestID(since) {
                cutoff = ChainedLog.read(c.run.requestsFile).first { $0["id"]?.string == since }?["ts"]?.double
                if cutoff == nil { throw ToolError(.notFound, "no request \(since) in this computer's log") }
            } else if let date = Self.parseISO(since) {
                cutoff = date.timeIntervalSince1970
            } else {
                throw ToolError.invalid("since must be an ISO 8601 timestamp or a request id")
            }
            if let cutoff { rows = rows.filter { $0.ts > cutoff } }
        }
        let limit = 60_000
        let content: String
        if args.string("format") == "json" {
            content = JSON.array(rows.map { ["ts": .double($0.ts), "kind": .string($0.kind), "text": .string($0.text)] }).text
        } else {
            content = Self.timelineMarkdown(box: c.name, rows: rows)
        }
        return ToolResult(["content": .string(String(content.prefix(limit))), "truncated": .bool(content.count > limit)])
    }

    static func parseISO(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        plain.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: text)
    }

    static func timelineMarkdown(box: String, rows: [TimelineRow]) -> String {
        let lines = rows.map { row in
            "\(timelineTime(row.ts))  \(row.kind + String(repeating: " ", count: max(0, 7 - row.kind.count))) \(String(row.text.replacingOccurrences(of: "\n", with: " ").prefix(600)))"
        }
        return "# Timeline: \(box)\n\n```\n" + lines.joined(separator: "\n") + "\n```\n"
    }

    /// `logs/timeline.md`, gerado ao coletar (CS-261). Quem chama é o app (release, `box_collect`).
    public static func writeTimelineFile(_ c: ManagedComputer) {
        let markdown = timelineMarkdown(box: c.name, rows: timelineRows(c, include: allSections))
        try? Data(markdown.utf8).write(to: c.run.timelineFile)
    }

    func resultSubmit(_ args: Args, _ c: ManagedComputer) async throws -> ToolResult {
        guard let result = args.values["result"], result.object != nil else { throw ToolError.invalid("result must be an object") }
        var evidence: [String: [String]] = [:]
        for (pointer, refs) in args.values["evidence"]?.object ?? [:] { evidence[pointer] = refs.array?.compactMap(\.string) ?? [] }
        // Falha cedo se as citações de arquivo tentam sair de /work (symlink, `..`): path_rejected, nunca "cited_missing".
        for ref in evidence.values.joined() where !ResultValidator.looksLikeRequestID(ref) {
            try PathGuard.rejectSymlinks(root: c.run.work, try PathGuard.components(ref))
        }
        let validator = ResultValidator(requests: ResultValidator.index(requestsFile: c.run.requestsFile)) { [work = c.run.work] ref in
            PathGuard.exists(root: work, ref)
        }
        let validation = try validator.validate(result: result, evidence: evidence)
        let resultData = result.data(pretty: true)
        let file = try PathGuard.write(root: c.run.work, "/work/result.json", resultData)
        // A validação mora em `logs/` (fora do alcance do agente) para o app mostrar as marcas ao lado de cada campo. O hash do
        // `result.json` diz, ao coletar, se ele foi reescrito à mão depois (então a validação é refeita pelo padrão de ids).
        var stored = validation.json.object ?? [:]
        stored["result_sha256"] = .string(RunCollector.sha256(resultData))
        try? JSON.object(stored).data(pretty: true).write(to: c.run.validationFile)
        _ = try? await c.appendJournal(
            kind: "NOTE", text: "result submitted: \(validation.verified) verified, \(validation.citedMissing) cited_missing, \(validation.notVerified) not_verified", evidence: [], system: true)
        return ToolResult(["file": .string(file), "validation": validation.json])
    }

    // MARK: I. Ajuda humana

    func helpRequest(_ args: Args, _ c: ManagedComputer) async throws -> ToolResult {
        guard let kind = args.string("kind").flatMap(HelpKind.init(rawValue:)) else { throw ToolError.invalid("kind is invalid") }
        let request = try await c.requestHelp(
            kind: kind, reason: args.string("reason") ?? "", url: args.string("url"), question: args.string("question"), options: args.strings("options") ?? [])
        return ToolResult(["request_id": .string(request.id), "status": .string(request.status.rawValue)])
    }

    func helpWait(_ args: Args, _ c: ManagedComputer) async throws -> ToolResult {
        let wait = min(max(args.double("wait_s") ?? 45, 0), 50)
        let request = try await c.waitHelp(args.string("request_id") ?? "", wait: .milliseconds(Int(wait * 1000)))
        var out: [String: JSON] = ["status": .string(request.status.rawValue)]
        if let note = request.humanNote { out["human_note"] = .string(note) }
        if let choice = request.choice { out["choice"] = .string(choice) }
        if let reason = request.declineReason { out["decline_reason"] = .string(reason) }
        if request.status == .resolved, let state = request.resolvedState { out["state"] = state }
        return ToolResult(.object(out))
    }

    func helpCancel(_ args: Args, _ c: ManagedComputer) async throws -> ToolResult {
        let request = try await c.cancelHelp(args.string("request_id") ?? "")
        return ToolResult(["status": .string(request.status.rawValue)])
    }
}
